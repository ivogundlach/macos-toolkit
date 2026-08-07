// Renders the app/extension icon or a gray toolbar variant that Safari will not tint.
// Usage: swift render-icon.swift <output-1024.png>
//        swift render-icon.swift --off <input.png> <output.png>
import AppKit
import CoreImage

if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--off" {
    let input = CommandLine.arguments[2]
    let output = CommandLine.arguments[3]
    let image = CIImage(contentsOf: URL(fileURLWithPath: input))!
    let gray = image.applyingFilter("CIColorControls", parameters: [
        kCIInputSaturationKey: 0,
    ])
    let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
        "inputCenter": CIVector(x: 0, y: 0),
        "inputColor0": CIColor(red: 1, green: 0, blue: 0, alpha: 0.12),
        "inputColor1": CIColor(red: 0, green: 1, blue: 1, alpha: 0.12),
        "inputWidth": 1,
        "inputSharpness": 1,
    ])!.outputImage!.cropped(to: gray.extent)
    let nonTemplateGray = checker.applyingFilter("CISourceAtopCompositing", parameters: [
        kCIInputBackgroundImageKey: gray,
    ])
    let context = CIContext(options: [.workingColorSpace: NSColorSpace.sRGB.cgColorSpace!])
    let rendered = context.createCGImage(nonTemplateGray, from: nonTemplateGray.extent)!
    let bitmap = NSBitmapImageRep(cgImage: rendered)
    let png = bitmap.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: output))
} else {
    let out = CommandLine.arguments[1]
    let size: CGFloat = 1024
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let rect = NSRect(x: 60, y: 60, width: size - 120, height: size - 120)
    let path = NSBezierPath(roundedRect: rect, xRadius: 180, yRadius: 180)
    NSColor(calibratedRed: 0.28, green: 0.32, blue: 0.90, alpha: 1).setFill()
    path.fill()
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 560),
        .paragraphStyle: para,
    ]
    ("📋" as NSString).draw(in: NSRect(x: 0, y: 140, width: size, height: 760), withAttributes: attrs)
    img.unlockFocus()
    let tiff = img.tiffRepresentation!
    let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: out))
}
