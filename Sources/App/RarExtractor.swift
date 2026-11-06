import Foundation
import os

struct ExtractionProgress {
  /// Toplam boyut bilinmiyorsa nil.
  var fraction: Double?
  var fileName: String
  var bytesPerSecond: Double
}

enum ExtractionError: LocalizedError {
  case cancelled
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .cancelled: return "İşlem iptal edildi."
    case .failed(let message): return message
    }
  }
}

/// Tek bir RAR arşivini açar. Dosyalar önce gizli bir geçici klasöre yazılır,
/// başarıyla bitince yerine taşınır. Böylece yarım kalan işlem ortada dosya bırakmaz.
final class RarExtractor: @unchecked Sendable {
  private let archive: URL
  private let askPassword: (_ previousWasWrong: Bool) -> String?
  private let onProgress: (ExtractionProgress) -> Void

  /// Güvenlik nedeniyle veya disk desteklemediği için atlanan bağlantı sayısı.
  private(set) var skippedLinks = 0

  private let cancelFlag = OSAllocatedUnfairLock(initialState: false)
  private var password: String?
  private var passwordWasWrong = false
  private var missingVolume: String?
  private var total: Int64 = 0
  private var done: Int64 = 0
  private var startTime: UInt64 = 0
  private var lastReport: UInt64 = 0
  private var currentName: UnsafePointer<wchar_t>?

  init(
    archive: URL,
    askPassword: @escaping (_ previousWasWrong: Bool) -> String?,
    onProgress: @escaping (ExtractionProgress) -> Void
  ) {
    self.archive = archive
    self.askPassword = askPassword
    self.onProgress = onProgress
  }

  func cancel() {
    cancelFlag.withLock { $0 = true }
  }

  private var isCancelled: Bool {
    cancelFlag.withLock { $0 }
  }

  /// Açılan ana öğenin konumunu döndürür.
  func run() throws -> URL {
    let first = try Self.firstVolume(of: archive)
    let parent = Self.outputDirectory(for: first)
    let temp = parent.appendingPathComponent(".rarac-\(UUID().uuidString)", isDirectory: true)
    let fm = FileManager.default
    defer { try? fm.removeItem(at: temp) }

    let context = Unmanaged.passUnretained(self).toOpaque()
    var callbacks = RarAcCallbacks(
      user: context,
      password: { user, buffer, capacity in
        Unmanaged<RarExtractor>.fromOpaque(user!).takeUnretainedValue()
          .providePassword(buffer!, capacity: Int(capacity))
      },
      progress: { user, bytes in
        Unmanaged<RarExtractor>.fromOpaque(user!).takeUnretainedValue().advance(by: bytes)
      },
      entry: { user, name in
        Unmanaged<RarExtractor>.fromOpaque(user!).takeUnretainedValue().beginEntry(name!)
      },
      missingVolume: { user, name in
        Unmanaged<RarExtractor>.fromOpaque(user!).takeUnretainedValue().missingVolume =
          RarExtractor.string(from: name!)
      },
      skippedLink: { user in
        Unmanaged<RarExtractor>.fromOpaque(user!).takeUnretainedValue().skippedLinks += 1
      }
    )

    while true {
      if isCancelled { throw ExtractionError.cancelled }
      try? fm.removeItem(at: temp)
      do {
        try fm.createDirectory(at: temp, withIntermediateDirectories: false)
      } catch {
        throw ExtractionError.failed(
          "Şu klasöre yazılamıyor: \(parent.path)\n\(error.localizedDescription)")
      }

      missingVolume = nil
      skippedLinks = 0
      done = 0
      total = 0
      startTime = DispatchTime.now().uptimeNanoseconds
      lastReport = 0

      var code = first.withUnsafeFileSystemRepresentation { path in
        rarac_scan(path, &callbacks, &total)
      }
      if code == 0 {
        code = first.withUnsafeFileSystemRepresentation { path in
          temp.withUnsafeFileSystemRepresentation { dest in
            rarac_extract(path, dest, &callbacks)
          }
        }
      }

      if isCancelled || code == RARAC_CANCELLED { throw ExtractionError.cancelled }
      if code == 0 { break }

      if isPasswordFailure(Int(code)) {
        password = nil
        passwordWasWrong = true
        continue
      }
      throw ExtractionError.failed(message(for: Int(code)))
    }

    let entries = try fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)
    guard !entries.isEmpty else {
      throw ExtractionError.failed("Arşivin içinde açılacak dosya yok.")
    }
    Self.propagateQuarantine(from: first, to: temp)

    // Arşivde tek bir üst öğe varsa ekstra klasörle sarmıyoruz.
    if entries.count == 1 {
      return try Self.moveWithoutOverwriting(entries[0], into: parent, name: entries[0].lastPathComponent)
    }
    return try Self.moveWithoutOverwriting(temp, into: parent, name: Self.baseName(of: first))
  }

  // MARK: - UnRAR geri çağrıları

  private func providePassword(_ buffer: UnsafeMutablePointer<wchar_t>, capacity: Int) -> Int32 {
    if password == nil {
      guard let answer = askPassword(passwordWasWrong) else {
        cancel()
        return 0
      }
      password = answer
    }
    let scalars = password!.unicodeScalars.prefix(capacity - 1)
    var index = 0
    for scalar in scalars {
      buffer[index] = wchar_t(scalar.value)
      index += 1
    }
    buffer[index] = 0
    return 1
  }

  private func advance(by bytes: Int64) -> Int32 {
    done += bytes
    reportIfNeeded()
    return isCancelled ? 1 : 0
  }

  private func beginEntry(_ name: UnsafePointer<wchar_t>) -> Int32 {
    currentName = name
    reportIfNeeded()
    return isCancelled ? 1 : 0
  }

  /// Arayüzü en fazla saniyede 10 kez günceller, böylece açma hızı etkilenmez.
  private func reportIfNeeded() {
    let now = DispatchTime.now().uptimeNanoseconds
    guard now - lastReport >= 100_000_000 else { return }
    lastReport = now
    let elapsed = Double(now - startTime) / 1_000_000_000
    onProgress(
      ExtractionProgress(
        fraction: total > 0 ? min(1, Double(done) / Double(total)) : nil,
        fileName: currentName.map(Self.string(from:)) ?? "",
        bytesPerSecond: elapsed > 0 ? Double(done) / elapsed : 0
      ))
  }

  // MARK: - Hata yönetimi

  private func isPasswordFailure(_ code: Int) -> Bool {
    if code == Int(RARAC_BAD_PASSWORD) || code == Int(RARAC_MISSING_PASSWORD) { return true }
    // RAR4'te yanlış şifre, bozuk veri gibi görünür.
    return password != nil && (code == Int(RARAC_BAD_DATA) || code == Int(RARAC_BAD_ARCHIVE))
  }

  private func message(for code: Int) -> String {
    if let missingVolume {
      return "Arşivin bir parçası eksik: \((missingVolume as NSString).lastPathComponent)"
    }
    switch code {
    case Int(RARAC_UNKNOWN_FORMAT): return "Bu dosya geçerli bir RAR arşivi değil."
    case Int(RARAC_BAD_ARCHIVE): return "Arşiv bozuk veya eksik görünüyor."
    case Int(RARAC_BAD_DATA): return "Arşivdeki veri bozuk, sağlama kontrolü başarısız oldu."
    case Int(RARAC_EOPEN), Int(RARAC_EREAD): return "Arşiv okunamadı."
    case Int(RARAC_ECREATE): return "Dosya oluşturulamadı. Klasör iznini kontrol et."
    case Int(RARAC_EWRITE), Int(RARAC_ECLOSE): return "Dosya yazılamadı. Disk dolu olabilir."
    case Int(RARAC_NO_MEMORY): return "Bu arşivi açmak için yeterli bellek yok."
    case Int(RARAC_LARGE_DICT): return "Bu arşiv çok fazla bellek istediği için açılmadı."
    default: return "Arşiv açılamadı (hata kodu \(code))."
    }
  }

  // MARK: - Yardımcılar

  private static func string(from pointer: UnsafePointer<wchar_t>) -> String {
    var result = String.UnicodeScalarView()
    var cursor = pointer
    while cursor.pointee != 0 {
      if let scalar = Unicode.Scalar(UInt32(bitPattern: cursor.pointee)) { result.append(scalar) }
      cursor += 1
    }
    return String(result)
  }

  private static func match(_ pattern: String, _ text: String) -> [String]? {
    guard
      let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
      let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return nil }
    return (0..<found.numberOfRanges).map { i in
      Range(found.range(at: i), in: text).map { String(text[$0]) } ?? ""
    }
  }

  /// Çok parçalı arşivlerde hangi parça seçilirse seçilsin ilk parçayı bulur.
  static func firstVolume(of url: URL) throws -> URL {
    let name = url.lastPathComponent
    let folder = url.deletingLastPathComponent()
    let fm = FileManager.default

    if let parts = match(#"^(.*)\.part(\d+)\.rar$"#, name) {
      let digits = parts[2]
      if Int(digits) == 1 { return url }
      let firstName = "\(parts[1]).part\(String(repeating: "0", count: max(0, digits.count - 1)))1.rar"
      let first = folder.appendingPathComponent(firstName)
      guard fm.fileExists(atPath: first.path) else {
        throw ExtractionError.failed("Arşivin ilk parçası bulunamadı: \(firstName)")
      }
      return first
    }
    if let parts = match(#"^(.*)\.[rs]\d{2}$"#, name) {
      let first = folder.appendingPathComponent("\(parts[1]).rar")
      guard fm.fileExists(atPath: first.path) else {
        throw ExtractionError.failed("Arşivin ilk parçası bulunamadı: \(parts[1]).rar")
      }
      return first
    }
    return url
  }

  private static func baseName(of first: URL) -> String {
    let name = first.lastPathComponent
    if let parts = match(#"^(.*)\.part\d+\.rar$"#, name) { return parts[1] }
    return first.deletingPathExtension().lastPathComponent
  }

  /// Arşivin yanına yazılamıyorsa (ör. salt okunur disk) İndirilenler'e açar.
  private static func outputDirectory(for first: URL) -> URL {
    let parent = first.deletingLastPathComponent()
    if access(parent.path, W_OK) == 0 { return parent }
    return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
  }

  /// İnternetten inen arşivin karantina etiketini açılan dosyalara taşır,
  /// böylece macOS içindeki uygulamaları Gatekeeper ile denetlemeye devam eder.
  private static func propagateQuarantine(from archive: URL, to folder: URL) {
    let attribute = "com.apple.quarantine"
    let size = getxattr(archive.path, attribute, nil, 0, 0, 0)
    guard size > 0 else { return }
    var value = [UInt8](repeating: 0, count: size)
    guard getxattr(archive.path, attribute, &value, size, 0, 0) == size else { return }
    guard let walker = FileManager.default.enumerator(atPath: folder.path) else { return }
    for case let relative as String in walker {
      let path = folder.appendingPathComponent(relative).path
      _ = setxattr(path, attribute, value, size, 0, XATTR_NOFOLLOW)
    }
  }

  /// Var olan dosyanın üzerine yazmadan taşır; ad doluysa "ad 2" dener.
  private static func moveWithoutOverwriting(_ source: URL, into parent: URL, name: String) throws -> URL {
    let ext = (name as NSString).pathExtension
    let stem = (name as NSString).deletingPathExtension
    let isFolderName = source.hasDirectoryPath
    var attempt = 1
    while attempt < 10_000 {
      var candidate = name
      if attempt > 1 {
        candidate = ext.isEmpty || isFolderName ? "\(name) \(attempt)" : "\(stem) \(attempt).\(ext)"
      }
      let target = parent.appendingPathComponent(candidate)
      var result = renamex_np(source.path, target.path, UInt32(RENAME_EXCL))
      if result != 0 && errno == ENOTSUP {
        // exFAT gibi disklerde RENAME_EXCL yok, önce varlığını kontrol ediyoruz.
        var info = stat()
        if lstat(target.path, &info) == 0 {
          errno = EEXIST
        } else {
          result = rename(source.path, target.path)
        }
      }
      if result == 0 { return target }
      if errno != EEXIST && errno != ENOTEMPTY {
        throw ExtractionError.failed(
          "Açılan dosyalar yerine taşınamadı: \(String(cString: strerror(errno)))")
      }
      attempt += 1
    }
    throw ExtractionError.failed("Uygun bir klasör adı bulunamadı.")
  }
}
