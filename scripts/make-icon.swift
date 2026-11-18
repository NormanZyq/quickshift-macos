import AppKit

let output = CommandLine.arguments[1]
let destination = URL(fileURLWithPath: output)
let iconset = destination.deletingLastPathComponent().appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
var iconChunks = Data()

func appendChunk(type: String, png: Data, to output: inout Data) {
    output.append(contentsOf: type.utf8)
    var length = UInt32(png.count + 8).bigEndian
    withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
    output.append(png)
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
        let gradient = NSGradient(starting: NSColor(calibratedRed: 0.15, green: 0.56, blue: 1, alpha: 1),
                                  ending: NSColor(calibratedRed: 0.12, green: 0.23, blue: 0.66, alpha: 1))!
        gradient.draw(in: background, angle: -65)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let back = NSBezierPath(roundedRect: NSRect(x: 195, y: 440, width: 400, height: 265), xRadius: 24, yRadius: 24)
        back.lineWidth = 30
        back.stroke()
        NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.85, alpha: 1).setFill()
        let front = NSBezierPath(roundedRect: NSRect(x: 414, y: 308, width: 400, height: 265), xRadius: 24, yRadius: 24)
        front.fill()
        NSColor.white.setStroke()
        front.lineWidth = 30
        front.stroke()
        let arrows = NSBezierPath()
        arrows.move(to: NSPoint(x: 255, y: 230))
        arrows.line(to: NSPoint(x: 755, y: 230))
        arrows.move(to: NSPoint(x: 320, y: 290))
        arrows.line(to: NSPoint(x: 255, y: 230))
        arrows.line(to: NSPoint(x: 320, y: 170))
        arrows.move(to: NSPoint(x: 690, y: 290))
        arrows.line(to: NSPoint(x: 755, y: 230))
        arrows.line(to: NSPoint(x: 690, y: 170))
        arrows.lineWidth = 28
        arrows.lineCapStyle = .round
        arrows.lineJoinStyle = .round
        arrows.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 1 ? "" : "@2x"
        let url = iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: url)
        let types: [Int: [String]] = [
            16: ["icp4", "ic11"], 32: ["icp5", "ic12"], 128: ["ic07", "ic13"],
            256: ["ic08", "ic14"], 512: ["ic09", "ic10"],
        ]
        appendChunk(type: types[size]![scale - 1], png: png, to: &iconChunks)
    }
}
var icon = Data("icns".utf8)
var totalLength = UInt32(iconChunks.count + 8).bigEndian
withUnsafeBytes(of: &totalLength) { icon.append(contentsOf: $0) }
icon.append(iconChunks)
try icon.write(to: destination, options: .atomic)
guard NSImage(contentsOf: destination) != nil else {
    throw NSError(domain: "QuickShift.Icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot decode generated icon"])
}
