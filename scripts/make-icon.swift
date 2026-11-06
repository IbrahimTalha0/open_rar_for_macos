// Uygulama simgesini çizer: scripts/make-icon.swift <çıktı.png>
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(
  starting: NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.95, alpha: 1),
  ending: NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.62, alpha: 1)
)!.draw(in: shape, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: 460, weight: .medium)
  .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: nil)?
  .withSymbolConfiguration(config)
{
  let origin = NSPoint(x: (size - symbol.size.width) / 2, y: (size - symbol.size.height) / 2)
  symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
}
image.unlockFocus()

let tiff = image.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
