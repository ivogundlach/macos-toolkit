#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICONSET="$ROOT/Resources/AppIcon.iconset"
ICNS="$ROOT/Resources/AppIcon.icns"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/kinetics-icon.XXXXXX")"
trap 'rm -rf "$TMP" "$ICONSET"' EXIT
mkdir -p "$ICONSET"

cat > "$TMP/IconGenerator.swift" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sizes: [(Int, String)] = [(16, "16x16"), (32, "32x32"), (128, "128x128"), (256, "256x256"), (512, "512x512")]

func writePNG(size: Int, scale: Int, name: String) throws {
    let pixels = size * scale
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                  bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "KineticsIcon", code: 1)
    }
    let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    context.setFillColor(CGColor(red: 0.055, green: 0.075, blue: 0.09, alpha: 1))
    context.fill(rect)

    let center = CGPoint(x: CGFloat(pixels) * 0.5, y: CGFloat(pixels) * 0.5)
    let radius = CGFloat(pixels) * 0.29
    context.setStrokeColor(CGColor(red: 0.18, green: 0.82, blue: 0.76, alpha: 1))
    context.setLineWidth(CGFloat(pixels) * 0.075)
    context.setLineCap(.round)
    context.addArc(center: center, radius: radius, startAngle: -0.82, endAngle: 0.82, clockwise: false)
    context.strokePath()

    context.setStrokeColor(CGColor(red: 0.32, green: 0.91, blue: 0.86, alpha: 1))
    context.setLineWidth(CGFloat(pixels) * 0.06)
    context.move(to: CGPoint(x: CGFloat(pixels) * 0.27, y: CGFloat(pixels) * 0.5))
    context.addLine(to: CGPoint(x: CGFloat(pixels) * 0.38, y: CGFloat(pixels) * 0.42))
    context.addLine(to: CGPoint(x: CGFloat(pixels) * 0.38, y: CGFloat(pixels) * 0.58))
    context.move(to: CGPoint(x: CGFloat(pixels) * 0.73, y: CGFloat(pixels) * 0.5))
    context.addLine(to: CGPoint(x: CGFloat(pixels) * 0.62, y: CGFloat(pixels) * 0.42))
    context.addLine(to: CGPoint(x: CGFloat(pixels) * 0.62, y: CGFloat(pixels) * 0.58))
    context.strokePath()

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL,
                                                            UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "KineticsIcon", code: 2)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "KineticsIcon", code: 3) }
}

for (size, stem) in sizes {
    try writePNG(size: size, scale: 1, name: "icon_\(stem).png")
    try writePNG(size: size, scale: 2, name: "icon_\(stem)@2x.png")
}
SWIFT

xcrun swiftc -swift-version 5 -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macosx15.0 \
    -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers \
    "$TMP/IconGenerator.swift" -o "$TMP/icon-generator"
"$TMP/icon-generator" "$ICONSET"
iconutil --convert icns --output "$ICNS" "$ICONSET"
test -s "$ICNS"
echo "Generated $ICNS"
