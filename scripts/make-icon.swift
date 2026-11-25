// Draws app/AppIcon.icns, the manager app's own icon: two lanes, coral and
// azure, bending together into an L on a dark plate. The geometry is the
// logo in docs/images/logo.svg (a 1024 canvas, y down), fitted to the macOS
// icon grid.
//   swift scripts/make-icon.swift app/AppIcon.icns
import AppKit

let out = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Same swatches as Brand in app/Shared.swift (its dark-mode values).
let coral = NSColor(deviceRed: 0xF4 / 255, green: 0x73 / 255, blue: 0x69 / 255, alpha: 1)
let azure = NSColor(deviceRed: 0x88 / 255, green: 0xDC / 255, blue: 0xFF / 255, alpha: 1)
let plateColor = NSColor(deviceRed: 0x24 / 255, green: 0x1A / 255, blue: 0x28 / 255, alpha: 1)

// The logo's own plate spans 64...960; the macOS grid wants 100...924.
let k: CGFloat = 824 / 896
func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    NSPoint(x: 512 + (x - 512) * k, y: 512 - (y - 512) * k)
}

// A lane: straight down, a quarter turn around (536, 488), straight along.
func lane(top: (CGFloat, CGFloat), radius r: CGFloat, end: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: pt(top.0, top.1))
    p.line(to: pt(top.0, 488))
    p.appendArc(withCenter: pt(536, 488), radius: r * k, startAngle: 180, endAngle: 270)
    p.line(to: pt(end, 488 + r))
    p.lineWidth = 112 * k
    p.lineCapStyle = .butt
    return p
}
let lanes: [(NSBezierPath, NSColor)] = [
    (lane(top: (264, 208), radius: 272, end: 816), coral),
    (lane(top: (432, 336), radius: 104, end: 688), azure),
]

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: s, y: s)
    // macOS icon grid: an 824pt rounded square centered on a 1024 canvas.
    plateColor.setFill()
    NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()
    for (path, color) in lanes {
        color.setStroke()
        path.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! draw(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try! draw(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(p.terminationStatus)
