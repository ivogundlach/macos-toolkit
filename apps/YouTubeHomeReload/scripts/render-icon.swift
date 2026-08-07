// Renders the 1024px extension icon: YouTube-red rounded square with a
// white reload glyph. Usage: swift render-icon.swift /path/to/icon-1024.png
import AppKit

let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let bg = NSBezierPath(roundedRect: rect.insetBy(dx: 40, dy: 40), xRadius: 200, yRadius: 200)
NSColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0).setFill()
bg.fill()

let glyph = "↻" as NSString
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 620, weight: .bold),
    .foregroundColor: NSColor.white,
]
let gsize = glyph.size(withAttributes: attrs)
glyph.draw(at: NSPoint(x: (size - gsize.width) / 2, y: (size - gsize.height) / 2), withAttributes: attrs)

img.unlockFocus()

let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
