import AppKit
import UniformTypeIdentifiers

private let archiveExtension = #"^(rar|[rs]\d{2})$"#

private func isArchive(_ url: URL) -> Bool {
  url.pathExtension.range(of: archiveExtension, options: [.regularExpression, .caseInsensitive]) != nil
}

// MARK: - Sürükle bırak alanı

final class DropView: NSView {
  var onDrop: (([URL]) -> Void)?
  private var highlighted = false { didSet { needsDisplay = true } }

  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) { fatalError() }

  private func archives(in info: NSDraggingInfo) -> [URL] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
    return (urls ?? []).filter(isArchive)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard !archives(in: sender).isEmpty else { return [] }
    highlighted = true
    return .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    highlighted = false
    let urls = archives(in: sender)
    guard !urls.isEmpty else { return false }
    onDrop?(urls)
    return true
  }

  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
    if highlighted {
      NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
      path.fill()
    }
    (highlighted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
    path.lineWidth = 1.5
    path.setLineDash([6, 4], count: 2, phase: 0)
    path.stroke()
  }
}

// MARK: - İlerleme çubuğu

/// Animasyonsuz ve hafif ilerleme çubuğu. Toplam henüz bilinmiyorsa yalnızca zemin çizilir.
final class BarView: NSView {
  var fraction: Double? { didSet { needsDisplay = true } }

  override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }

  override func draw(_ dirtyRect: NSRect) {
    let radius = bounds.height / 2
    NSColor.quaternaryLabelColor.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    guard let fraction, fraction > 0 else { return }
    var filled = bounds
    filled.size.width = max(bounds.height, bounds.width * min(1, fraction))
    NSColor.controlAccentColor.setFill()
    NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
  }
}

// MARK: - Uygulama

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var window: NSWindow!
  private let dropStack = NSStackView()
  private let progressStack = NSStackView()
  private let hintLabel = NSTextField(labelWithString: "RAR dosyasını buraya bırak")
  private let archiveLabel = NSTextField(labelWithString: "")
  private let fileLabel = NSTextField(labelWithString: "")
  private let statusLabel = NSTextField(labelWithString: "")
  private let progressBar = BarView()

  private var queue: [URL] = []
  private var results: [URL] = []
  private var failed = false
  private var current: RarExtractor?
  private var showWindowTask: DispatchWorkItem?
  private var launchedWithFile = false
  private var didFinishLaunching = false
  private var pendingTermination = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    buildMenu()
    buildWindow()
    didFinishLaunching = true
    #if SNAPSHOT
    if runSnapshotMode() { return }
    #endif
    if !launchedWithFile {
      showWindow()
    }
    processNext()
  }

  #if SNAPSHOT
  // Yalnızca test derlemesinde: arayüzü ekran izni olmadan PNG'ye çizer ve şifre penceresini sürer.
  private var snapshotDir: String { ProcessInfo.processInfo.environment["RARAC_SNAP_DIR"]! }

  private func snapshot(_ view: NSView, _ name: String) {
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    let image = NSImage(size: view.bounds.size)
    image.lockFocus()
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
      NSColor.windowBackgroundColor.setFill()
      view.bounds.fill()
    }
    rep.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    image.unlockFocus()
    let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    try? png.write(to: URL(fileURLWithPath: "\(snapshotDir)/\(name).png"))
  }

  private func runSnapshotMode() -> Bool {
    let env = ProcessInfo.processInfo.environment
    if let path = env["RARAC_TEST_OPEN"] {
      launchedWithFile = true
      enqueue([URL(fileURLWithPath: path)])
      return true
    }
    showWindow()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    snapshot(window.contentView!, "idle")
    showProgress(for: URL(fileURLWithPath: "/tmp/uzun_bir_arsiv_adi_ornek.part1.rar"))
    current = RarExtractor(archive: URL(fileURLWithPath: "/tmp/x.rar"), askPassword: { _ in nil }, onProgress: { _ in })
    update(ExtractionProgress(fraction: 0.42, fileName: "klasör/alt klasör/şarkılar/çiğdem.mp3", bytesPerSecond: 512_000_000))
    current = nil
    snapshot(window.contentView!, "progress")
    NSApp.terminate(nil)
    return true
  }

  private func scheduleModalDriver() {
    let answer = ProcessInfo.processInfo.environment["RARAC_TEST_PASSWORD"] ?? ""
    let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] timer in
      guard let panel = NSApp.modalWindow, let content = panel.contentView else { return }
      timer.invalidate()
      self?.snapshot(content, "password")
      var stack = content.subviews
      while let view = stack.popLast() {
        if let field = view as? NSSecureTextField { field.stringValue = answer }
        stack += view.subviews
      }
      NSApp.stopModal(withCode: .alertFirstButtonReturn)
    }
    RunLoop.main.add(timer, forMode: .common)
  }
  #endif

  func application(_ application: NSApplication, open urls: [URL]) {
    if !didFinishLaunching { launchedWithFile = true }
    enqueue(urls)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { showWindow() }
    return true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let current else { return .terminateNow }
    // Geçici dosyalar temizlendikten sonra kapanıyoruz.
    queue.removeAll()
    pendingTermination = true
    current.cancel()
    return .terminateLater
  }

  func windowWillClose(_ notification: Notification) {
    NSApp.terminate(nil)
  }

  // MARK: Kuyruk

  private func enqueue(_ urls: [URL]) {
    // Aynı arşivin birden çok parçası seçildiyse tek kez açıyoruz.
    var seen = Set(queue.map(\.path))
    for url in urls {
      let first = (try? RarExtractor.firstVolume(of: url)) ?? url
      if seen.insert(first.path).inserted { queue.append(first) }
    }
    if didFinishLaunching { processNext() }
  }

  private func processNext() {
    guard current == nil else { return }
    guard !queue.isEmpty else {
      finishBatch()
      return
    }
    let archive = queue.removeFirst()

    let extractor: RarExtractor = RarExtractor(
      archive: archive,
      askPassword: { [weak self] wasWrong in
        var answer: String?
        DispatchQueue.main.sync {
          answer = self?.promptForPassword(archive: archive, wasWrong: wasWrong)
        }
        return answer
      },
      onProgress: { [weak self] progress in
        DispatchQueue.main.async { self?.update(progress) }
      }
    )
    current = extractor
    showProgress(for: archive)

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let outcome = Result { try extractor.run() }
      DispatchQueue.main.async { self?.finish(archive: archive, outcome: outcome) }
    }
  }

  private func finish(archive: URL, outcome: Result<URL, Error>) {
    let skippedLinks = current?.skippedLinks ?? 0
    current = nil
    if pendingTermination {
      NSApp.reply(toApplicationShouldTerminate: true)
      return
    }
    switch outcome {
    case .success(let url):
      results.append(url)
      if skippedLinks > 0 { showSkippedLinks(skippedLinks, archive: archive) }
    case .failure(ExtractionError.cancelled):
      // Kullanıcı vazgeçti, hata göstermiyoruz.
      break
    case .failure(let error):
      failed = true
      showError(error, archive: archive)
    }
    processNext()
  }

  private func finishBatch() {
    showWindowTask?.cancel()
    showWindowTask = nil
    let opened = results
    results = []
    #if !SNAPSHOT
    if !opened.isEmpty {
      NSWorkspace.shared.activateFileViewerSelecting(opened)
    }
    #endif
    if launchedWithFile {
      NSApp.terminate(nil)
      return
    }
    progressStack.isHidden = true
    dropStack.isHidden = false
    if opened.isEmpty {
      hintLabel.stringValue = failed ? "Açılamadı. Başka bir dosya deneyebilirsin." : "RAR dosyasını buraya bırak"
    } else {
      hintLabel.stringValue = "Bitti: \(opened.last!.lastPathComponent)"
    }
    failed = false
  }

  // MARK: Arayüz güncellemeleri

  private func showProgress(for archive: URL) {
    archiveLabel.stringValue = archive.lastPathComponent
    fileLabel.stringValue = " "
    statusLabel.stringValue = "Hazırlanıyor…"
    progressBar.fraction = nil
    dropStack.isHidden = true
    progressStack.isHidden = false

    // Küçük arşivler anında biter, boşuna pencere yanıp sönmesin.
    guard launchedWithFile, !window.isVisible else { return }
    showWindowTask?.cancel()
    let task = DispatchWorkItem { [weak self] in self?.showWindow() }
    showWindowTask = task
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
  }

  private func update(_ progress: ExtractionProgress) {
    guard current != nil else { return }
    fileLabel.stringValue = progress.fileName.isEmpty ? " " : progress.fileName
    let speed = ByteCountFormatter.string(fromByteCount: Int64(progress.bytesPerSecond), countStyle: .file)
    progressBar.fraction = progress.fraction
    if let fraction = progress.fraction {
      statusLabel.stringValue = "%\(Int(fraction * 100))  ·  \(speed)/sn"
    } else {
      statusLabel.stringValue = "\(speed)/sn"
    }
  }

  private func showWindow() {
    if !window.isVisible { window.center() }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func showError(_ error: Error, archive: URL) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "\(archive.lastPathComponent) açılamadı"
    alert.informativeText = error.localizedDescription
    alert.runModal()
  }

  private func showSkippedLinks(_ count: Int, archive: URL) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "\(archive.lastPathComponent) açıldı, \(count) bağlantı atlandı"
    alert.informativeText = "Bu sembolik bağlantılar çıkarılan klasörün dışını gösteriyor veya bu disk onları desteklemiyor. Diğer dosyalar açıldı."
    alert.runModal()
  }

  private func promptForPassword(archive: URL, wasWrong: Bool) -> String? {
    NSApp.activate(ignoringOtherApps: true)
    #if SNAPSHOT
    scheduleModalDriver()
    #endif
    let alert = NSAlert()
    alert.messageText = wasWrong ? "Şifre yanlış" : "Bu arşiv şifreli"
    alert.informativeText = wasWrong
      ? "\(archive.lastPathComponent) için şifreyi tekrar dene. Şifren doğruysa arşiv bozuk olabilir."
      : "\(archive.lastPathComponent) için şifreyi gir."
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    alert.accessoryView = field
    alert.addButton(withTitle: "Aç")
    alert.addButton(withTitle: "Vazgeç")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue
  }

  // MARK: Kurulum

  @objc private func chooseFile(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [UTType(filenameExtension: "rar") ?? .data]
    panel.begin { [weak self] response in
      if response == .OK { self?.enqueue(panel.urls) }
    }
  }

  @objc private func cancelExtraction(_ sender: Any?) {
    queue.removeAll()
    current?.cancel()
    statusLabel.stringValue = "İptal ediliyor…"
  }

  private func buildWindow() {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 230),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: true
    )
    window.title = "RarAç"
    window.isReleasedWhenClosed = false
    window.delegate = self

    let drop = DropView(frame: .zero)
    drop.onDrop = { [weak self] urls in self?.enqueue(urls) }
    drop.translatesAutoresizingMaskIntoConstraints = false
    window.contentView = NSView()
    window.contentView!.addSubview(drop)

    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 34, weight: .light)
    icon.contentTintColor = .secondaryLabelColor
    hintLabel.font = .systemFont(ofSize: 14, weight: .medium)
    hintLabel.lineBreakMode = .byTruncatingMiddle
    let choose = NSButton(title: "Dosya Seç…", target: self, action: #selector(chooseFile(_:)))
    dropStack.orientation = .vertical
    dropStack.spacing = 12
    dropStack.setViews([icon, hintLabel, choose], in: .center)

    archiveLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    archiveLabel.lineBreakMode = .byTruncatingMiddle
    fileLabel.font = .systemFont(ofSize: 12)
    fileLabel.textColor = .secondaryLabelColor
    fileLabel.lineBreakMode = .byTruncatingMiddle
    statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    statusLabel.textColor = .secondaryLabelColor
    let cancel = NSButton(title: "İptal", target: self, action: #selector(cancelExtraction(_:)))
    let row = NSStackView(views: [statusLabel, NSView(), cancel])
    row.orientation = .horizontal
    progressStack.orientation = .vertical
    progressStack.alignment = .leading
    progressStack.spacing = 10
    progressStack.setViews([archiveLabel, fileLabel, progressBar, row], in: .center)
    progressStack.isHidden = true

    for stack in [dropStack, progressStack] {
      stack.translatesAutoresizingMaskIntoConstraints = false
      drop.addSubview(stack)
    }
    progressBar.translatesAutoresizingMaskIntoConstraints = false
    row.translatesAutoresizingMaskIntoConstraints = false
    let content = window.contentView!
    archiveLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    NSLayoutConstraint.activate([
      drop.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
      drop.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      drop.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
      drop.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
      dropStack.centerXAnchor.constraint(equalTo: drop.centerXAnchor),
      dropStack.centerYAnchor.constraint(equalTo: drop.centerYAnchor),
      dropStack.widthAnchor.constraint(lessThanOrEqualTo: drop.widthAnchor, constant: -32),
      progressStack.leadingAnchor.constraint(equalTo: drop.leadingAnchor, constant: 20),
      progressStack.trailingAnchor.constraint(equalTo: drop.trailingAnchor, constant: -20),
      progressStack.centerYAnchor.constraint(equalTo: drop.centerYAnchor),
      progressBar.widthAnchor.constraint(equalTo: progressStack.widthAnchor),
      row.widthAnchor.constraint(equalTo: progressStack.widthAnchor),
    ])
  }

  private func buildMenu() {
    let main = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "RarAç Hakkında", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "RarAç'tan Çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let fileItem = NSMenuItem()
    let fileMenu = NSMenu(title: "Dosya")
    let open = fileMenu.addItem(withTitle: "Aç…", action: #selector(chooseFile(_:)), keyEquivalent: "o")
    open.target = self
    fileMenu.addItem(withTitle: "Pencereyi Kapat", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    fileItem.submenu = fileMenu
    main.addItem(fileItem)

    // Şifre alanına yapıştırabilmek için Düzen menüsü gerekiyor.
    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Düzen")
    editMenu.addItem(withTitle: "Kes", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Kopyala", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Yapıştır", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Tümünü Seç", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu
    main.addItem(editItem)

    NSApp.mainMenu = main
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
