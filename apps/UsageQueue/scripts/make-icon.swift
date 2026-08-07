// Renders Resources/AppIcon.icns source PNG (1024px): gradient squircle + queue glyph.
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

let inset: CGFloat = size * 0.09
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.185, yRadius: size * 0.185)
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.55, alpha: 1),
    NSColor(calibratedRed: 0.45, green: 0.25, blue: 0.85, alpha: 1),
])!
grad.draw(in: path, angle: 60)

// glyph: paperplane over a clock arc
let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .medium)
if let sym = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let tinted = NSImage(size: sym.size)
    tinted.lockFocus()
    NSColor.white.set()
    let r = NSRect(origin: .zero, size: sym.size)
    sym.draw(in: r)
    r.fill(using: .sourceAtop)
    tinted.unlockFocus()
    let gs = size * 0.46
    tinted.draw(in: NSRect(x: (size - gs) / 2 + size * 0.02, y: (size - gs) / 2 + size * 0.05,
                           width: gs, height: gs * sym.size.height / sym.size.width))
}
// small clock badge, bottom-right
let badgeR = size * 0.13
let bc = NSPoint(x: rect.maxX - badgeR * 1.4, y: rect.minY + badgeR * 1.4)
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: bc.x - badgeR, y: bc.y - badgeR, width: badgeR * 2, height: badgeR * 2)).fill()
let ccfg = NSImage.SymbolConfiguration(pointSize: badgeR * 1.5, weight: .bold)
if let clk = NSImage(systemSymbolName: "clock.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(ccfg) {
    let tinted = NSImage(size: clk.size)
    tinted.lockFocus()
    NSColor(calibratedRed: 0.30, green: 0.23, blue: 0.70, alpha: 1).set()
    let r = NSRect(origin: .zero, size: clk.size)
    clk.draw(in: r)
    r.fill(using: .sourceAtop)
    tinted.unlockFocus()
    let cs = badgeR * 1.6
    tinted.draw(in: NSRect(x: bc.x - cs / 2, y: bc.y - cs / 2, width: cs, height: cs * clk.size.height / clk.size.width))
}
img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("render failed") }
try! png.write(to: URL(fileURLWithPath: "Resources/icon-1024.png"))
print("wrote Resources/icon-1024.png")
