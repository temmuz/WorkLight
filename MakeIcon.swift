import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Worklight.iconset")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 210, yRadius: 210).fill()
        let gold = NSColor(calibratedRed: 1, green: 0.81, blue: 0.27, alpha: 1)
        gold.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 260, y: 230, width: 504, height: 504))
        ring.lineWidth = 47; ring.stroke()
        let hands = NSBezierPath()
        hands.move(to: NSPoint(x: 512, y: 650)); hands.line(to: NSPoint(x: 512, y: 482)); hands.line(to: NSPoint(x: 619, y: 407))
        hands.lineWidth = 45; hands.lineCapStyle = .round; hands.lineJoinStyle = .round; hands.stroke()
        gold.setFill()
        NSBezierPath(roundedRect: NSRect(x: 437, y: 781, width: 150, height: 46), xRadius: 23, yRadius: 23).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(base)x\(base)\(suffix).png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name))
    }
}

// ICNS supports PNG payloads directly. Write the container without depending on
// iconutil's image conversion service, which is unavailable in some build hosts.
var chunks = Data()
for (tag, filename) in [("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")] {
    let png = try Data(contentsOf: root.appendingPathComponent(filename))
    chunks.append(Data(tag.utf8))
    var length = UInt32(png.count + 8).bigEndian
    withUnsafeBytes(of: &length) { chunks.append(contentsOf: $0) }
    chunks.append(png)
}
var icon = Data("icns".utf8)
var length = UInt32(chunks.count + 8).bigEndian
withUnsafeBytes(of: &length) { icon.append(contentsOf: $0) }
icon.append(chunks)
try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
