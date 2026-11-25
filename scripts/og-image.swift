// Draws site/og.png, the 1200x630 card social networks show for the landing
// page: the lanes motif, the logo, the headline and the app window.
//   swift scripts/og-image.swift site/og.png
import AppKit

let out = CommandLine.arguments[1]
let W: CGFloat = 1200, H: CGFloat = 630
let plum = NSColor(deviceRed: 0x24 / 255, green: 0x1A / 255, blue: 0x28 / 255, alpha: 1)
let coral = NSColor(deviceRed: 0xF4 / 255, green: 0x73 / 255, blue: 0x69 / 255, alpha: 1)
let azure = NSColor(deviceRed: 0x88 / 255, green: 0xDC / 255, blue: 0xFF / 255, alpha: 1)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
plum.setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

// The two lanes, bending out of the bottom-left corner behind everything.
func lane(_ color: NSColor, radius: CGFloat, width: CGFloat, alpha: CGFloat) {
    let p = NSBezierPath()
    let cx: CGFloat = 330 + radius, cy: CGFloat = 40 + radius
    p.move(to: NSPoint(x: cx - radius, y: H + 20))
    p.line(to: NSPoint(x: cx - radius, y: cy))
    p.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: radius, startAngle: 180, endAngle: 270)
    p.line(to: NSPoint(x: W + 20, y: cy - radius))
    p.lineWidth = width
    color.withAlphaComponent(alpha).setStroke()
    p.stroke()
}
lane(coral, radius: 230, width: 74, alpha: 0.11)
lane(azure, radius: 110, width: 74, alpha: 0.11)

// App window, tilted off the right edge.
if let shot = NSImage(contentsOfFile: "docs/images/window-dark.png") {
    let w: CGFloat = 760
    let h = w * shot.size.height / shot.size.width
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    shadow.shadowBlurRadius = 40
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    shadow.set()
    shot.draw(in: NSRect(x: 610, y: -60, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
}

// Logo and words.
if let logo = NSImage(contentsOfFile: "docs/images/logo.svg") {
    logo.draw(in: NSRect(x: 64, y: H - 64 - 96, width: 96, height: 96))
}
func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at p: NSPoint) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
    NSAttributedString(string: s, attributes: [.font: rounded, .foregroundColor: color]).draw(at: p)
}
text("Every Claude", size: 70, weight: .heavy, color: .white, at: NSPoint(x: 64, y: 300))
text("account in its", size: 70, weight: .heavy, color: .white, at: NSPoint(x: 64, y: 226))
text("own lane.", size: 70, weight: .heavy, color: coral, at: NSPoint(x: 64, y: 152))
text("Lanes for Mac", size: 28, weight: .semibold, color: azure, at: NSPoint(x: 64, y: 70))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
