import AppKit

// Reproducible artwork for the app bundle and the README. This renders static assets;
// it does not add runtime Liquid Glass appearances to the app.
guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: swift scripts/make-icon.swift OUTPUT.icns [--preview-dir DIRECTORY]\n", stderr)
    exit(1)
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let pngDestination = destination.deletingPathExtension().appendingPathExtension("png")
let previewIndex = CommandLine.arguments.firstIndex(of: "--preview-dir")
let previewDirectory = previewIndex.flatMap { index in
    index + 1 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[index + 1]) : nil
}
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
if let previewDirectory {
    try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    NSColor(deviceRed: red, green: green, blue: blue, alpha: alpha).cgColor
}

func gradient(_ context: CGContext, path: CGPath, colors: [CGColor], locations: [CGFloat], start: CGPoint, end: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let value = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations)!
    context.drawLinearGradient(value, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func superellipse(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    for step in 0...512 {
        let angle = CGFloat(step) / 512 * .pi * 2
        let x = cos(angle), y = sin(angle)
        let point = CGPoint(x: rect.midX + rect.width / 2 * (x < 0 ? -1 : 1) * pow(abs(x), 2 / 4.4),
                            y: rect.midY + rect.height / 2 * (y < 0 ? -1 : 1) * pow(abs(y), 2 / 4.4))
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

func panel(_ context: CGContext, rect: CGRect, front: Bool, small: Bool) {
    let outline = CGPath(roundedRect: rect, cornerWidth: 40, cornerHeight: 40, transform: nil)
    let border: CGFloat = small ? 28 : 16
    let inside = rect.insetBy(dx: border, dy: border)
    let screen = CGPath(roundedRect: inside, cornerWidth: 25, cornerHeight: 25, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: front ? 22 : 16,
                      color: color(0.04, 0.14, 0.40, front ? 0.2 : 0.13))
    context.setFillColor(color(0.5, 0.76, 1, small ? 0.75 : 0.16))
    context.addPath(outline)
    context.fillPath()
    context.restoreGState()
    if small {
        // Keep the same silhouette with stronger separation in toolbar-sized artwork.
        gradient(context, path: outline,
                 colors: [color(1, 1, 1, front ? 1 : 0.88), color(0.8, 0.93, 1, front ? 0.98 : 0.72)],
                 locations: [0, 1], start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY))
        gradient(context, path: screen,
                 colors: [color(0.45, 0.77, 1), color(0.24, 0.49, 0.94)],
                 locations: [0, 1], start: CGPoint(x: inside.minX, y: inside.maxY), end: CGPoint(x: inside.maxX, y: inside.minY))
        return
    }
    gradient(context, path: outline,
             colors: front ? [color(0.95, 0.985, 1, 0.84), color(0.64, 0.84, 1, 0.63)]
                           : [color(0.78, 0.94, 1, 0.62), color(0.42, 0.76, 1, 0.32)],
             locations: [0, 1], start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY))
    let rim = CGMutablePath()
    rim.addPath(outline)
    rim.addPath(screen)
    context.saveGState()
    context.addPath(rim)
    context.clip(using: .evenOdd)
    let rimGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [color(1, 1, 1, front ? 0.94 : 0.75), color(0.8, 0.95, 1, front ? 0.68 : 0.4)] as CFArray,
                                 locations: [0, 1])!
    context.drawLinearGradient(rimGradient, start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    context.restoreGState()
    context.saveGState()
    context.addPath(outline)
    context.setStrokeColor(color(1, 1, 1, front ? 0.6 : 0.25))
    context.setLineWidth(1.5)
    context.strokePath()
    context.restoreGState()
}

func drawIcon(_ context: CGContext, small: Bool) {
    let tile = superellipse(in: CGRect(x: 64, y: 64, width: 896, height: 896))
    gradient(context, path: tile, colors: [color(0.18, 0.65, 1), color(0.14, 0.43, 0.93), color(0.19, 0.24, 0.75)],
             locations: [0, 0.52, 1], start: CGPoint(x: 180, y: 960), end: CGPoint(x: 820, y: 64))
    context.saveGState()
    context.addPath(tile)
    context.setLineWidth(2)
    context.setStrokeColor(color(1, 1, 1, 0.1))
    context.strokePath()
    context.restoreGState()

    panel(context, rect: CGRect(x: 192, y: 460, width: 420, height: 286), front: false, small: small)
    panel(context, rect: CGRect(x: 412, y: 346, width: 420, height: 286), front: true, small: small)

    let arrows = CGMutablePath()
    let left: CGFloat = 292, right: CGFloat = 732, baseline: CGFloat = 234, head: CGFloat = small ? 56 : 46
    arrows.move(to: CGPoint(x: left, y: baseline))
    arrows.addLine(to: CGPoint(x: right, y: baseline))
    arrows.move(to: CGPoint(x: left + head, y: baseline + head))
    arrows.addLine(to: CGPoint(x: left, y: baseline))
    arrows.addLine(to: CGPoint(x: left + head, y: baseline - head))
    arrows.move(to: CGPoint(x: right - head, y: baseline + head))
    arrows.addLine(to: CGPoint(x: right, y: baseline))
    arrows.addLine(to: CGPoint(x: right - head, y: baseline - head))
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -4), blur: 8, color: color(0.03, 0.12, 0.43, 0.18))
    context.setStrokeColor(color(0.98, 0.995, 1))
    context.setLineWidth(small ? 40 : 28)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(arrows)
    context.strokePath()
    context.restoreGState()
}

func bitmap(width: Int, height: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

func render(pixels: Int) -> Data {
    let renderingPixels = pixels < 128 ? pixels * 4 : pixels
    let artwork = bitmap(width: renderingPixels, height: renderingPixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: artwork)
    let context = NSGraphicsContext.current!.cgContext
    context.clear(CGRect(x: 0, y: 0, width: renderingPixels, height: renderingPixels))
    context.setAllowsAntialiasing(true)
    context.scaleBy(x: CGFloat(renderingPixels) / 1024, y: CGFloat(renderingPixels) / 1024)
    drawIcon(context, small: pixels <= 32)
    NSGraphicsContext.restoreGraphicsState()
    if renderingPixels == pixels { return artwork.representation(using: .png, properties: [:])! }
    let output = bitmap(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
    let outputContext = NSGraphicsContext.current!.cgContext
    outputContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    outputContext.interpolationQuality = .high
    outputContext.draw(artwork.cgImage!, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return output.representation(using: .png, properties: [:])!
}

var pngs: [Int: Data] = [:]
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let png = render(pixels: pixels)
    pngs[pixels] = png
    if let previewDirectory { try png.write(to: previewDirectory.appendingPathComponent("icon-\(pixels).png")) }
}
try pngs[1024]!.write(to: pngDestination, options: .atomic)

var chunks = Data()
let types = [16: ["icp4", "ic11"], 32: ["icp5", "ic12"], 128: ["ic07", "ic13"],
             256: ["ic08", "ic14"], 512: ["ic09", "ic10"]]
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let png = pngs[size * scale]!
        chunks.append(contentsOf: types[size]![scale - 1].utf8)
        var length = UInt32(png.count + 8).bigEndian
        withUnsafeBytes(of: &length) { chunks.append(contentsOf: $0) }
        chunks.append(png)
    }
}
var icon = Data("icns".utf8)
var length = UInt32(chunks.count + 8).bigEndian
withUnsafeBytes(of: &length) { icon.append(contentsOf: $0) }
icon.append(chunks)
try icon.write(to: destination, options: .atomic)
guard NSImage(contentsOf: destination) != nil else {
    throw NSError(domain: "QuickShift.Icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot decode generated icon"])
}
print("Wrote \(destination.path) and \(pngDestination.path)")
