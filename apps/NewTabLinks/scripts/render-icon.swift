// Renders the app/extension icon: rounded teal square with a link emoji.
// Usage: swift render-icon.swift <output-1024.png>
import AppKit

let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 60, y: 60, width: size - 120, height: size - 120)
let path = NSBezierPath(roundedRect: rect, xRadius: 180, yRadius: 180)
NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.55, alpha: 1).setFill()
path.fill()
let para = NSMutableParagraphStyle()
para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 560),
    .paragraphStyle: para,
]
("🔗" as NSString).draw(in: NSRect(x: 0, y: 140, width: size, height: 760), withAttributes: attrs)
img.unlockFocus()
let tiff = img.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
