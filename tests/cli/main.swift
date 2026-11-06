// Motor testi için arayüzsüz çalıştırıcı.
// Kullanım: engine-cli <arşiv> [--passwords a,b,c] [--cancel-on-progress]
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
let archive = URL(fileURLWithPath: args.removeFirst())
var passwords: [String] = []
var cancelOnProgress = false
while !args.isEmpty {
  let flag = args.removeFirst()
  if flag == "--passwords" { passwords = args.removeFirst().components(separatedBy: ",") }
  if flag == "--cancel-on-progress" { cancelOnProgress = true }
}

var prompts = 0
var extractor: RarExtractor!
extractor = RarExtractor(
  archive: archive,
  askPassword: { wasWrong in
    prompts += 1
    print("PROMPT wrong=\(wasWrong)")
    return passwords.isEmpty ? nil : passwords.removeFirst()
  },
  onProgress: { progress in
    if cancelOnProgress && (progress.fraction ?? 0) > 0 { extractor.cancel() }
  }
)

do {
  let start = Date()
  let result = try extractor.run()
  print("OK \(result.path)")
  print("SKIPPED \(extractor.skippedLinks)")
  print(String(format: "TIME %.3f", Date().timeIntervalSince(start)))
} catch ExtractionError.cancelled {
  print("CANCELLED")
} catch {
  print("ERR \(error.localizedDescription)")
}
