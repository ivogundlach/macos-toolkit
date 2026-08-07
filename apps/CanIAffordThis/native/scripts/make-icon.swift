import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let inset = size * 0.09
let rect = NSRect(
    x: inset,
    y: inset,
    width: size - 2 * inset,
    height: size - 2 * inset
)
let tile = NSBezierPath(
    roundedRect: rect,
    xRadius: size * 0.19,
    yRadius: size * 0.19
)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.06, green: 0.35, blue: 0.25, alpha: 1),
    NSColor(calibratedRed: 0.16, green: 0.70, blue: 0.48, alpha: 1),
])!
gradient.draw(in: tile, angle: 55)

NSColor.white.setStroke()
NSColor.white.setFill()

let calendarRect = NSRect(
    x: size * 0.27,
    y: size * 0.25,
    width: size * 0.46,
    height: size * 0.49
)
let calendar = NSBezierPath(
    roundedRect: calendarRect,
    xRadius: size * 0.055,
    yRadius: size * 0.055
)
calendar.lineWidth = size * 0.052
calendar.stroke()

let headerY = calendarRect.maxY - size * 0.13
let header = NSBezierPath()
header.move(to: NSPoint(x: calendarRect.minX, y: headerY))
header.line(to: NSPoint(x: calendarRect.maxX, y: headerY))
header.lineWidth = size * 0.052
header.stroke()

for x in [calendarRect.minX + size * 0.12, calendarRect.maxX - size * 0.12] {
    let tab = NSBezierPath()
    tab.move(to: NSPoint(x: x, y: calendarRect.maxY + size * 0.045))
    tab.line(to: NSPoint(x: x, y: calendarRect.maxY - size * 0.065))
    tab.lineWidth = size * 0.052
    tab.lineCapStyle = .round
    tab.stroke()
}

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let dollar = NSAttributedString(
    string: "$",
    attributes: [
        .font: NSFont.systemFont(ofSize: size * 0.25, weight: .bold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph,
    ]
)
dollar.draw(
    in: NSRect(
        x: calendarRect.minX,
        y: calendarRect.minY + size * 0.025,
        width: calendarRect.width,
        height: size * 0.28
    )
)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render icon")
}
try png.write(to: URL(fileURLWithPath: "Resources/icon-1024.png"))
