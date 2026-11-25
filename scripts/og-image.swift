// Draws site/og.png, the 1200x630 card social networks show for the landing
// page: the lanes motif, the logo, the headline and the app window. The type
// matches the page: Inter from site/fonts, with the hero's weight, tracking
// and coral "lane" with its azure full stop.
//   swift scripts/og-image.swift site/og.png
import AppKit
import CoreText

let out = CommandLine.arguments[1]
let W: CGFloat = 1200, H: CGFloat = 630

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let bg = rgb(0x1B1320), ink = rgb(0xF6F1F7), muted = rgb(0xB6A9BB)
let coral = rgb(0xF47369), peach = rgb(0xFFA48A), azure = rgb(0x88DCFF)

// Inter, straight from the page's own font file, at a given weight. The
// optical size follows the point size, as the browser does (14–32).
let fontURL = URL(fileURLWithPath: "site/fonts/Inter.woff2") as CFURL
guard let base = (CTFontManagerCreateFontDescriptorsFromURL(fontURL) as? [CTFontDescriptor])?.first else {
    fatalError("Can't read site/fonts/Inter.woff2")
}
func inter(_ size: CGFloat, _ weight: CGFloat) -> CTFont {
    let axes: [NSNumber: NSNumber] = [
        NSNumber(value: 0x77676874): NSNumber(value: Double(weight)),            // wght
        NSNumber(value: 0x6F70737A): NSNumber(value: Double(min(32, max(14, size)))), // opsz
    ]
    let d = CTFontDescriptorCreateCopyWithAttributes(base, [kCTFontVariationAttribute: axes] as CFDictionary)
    return CTFontCreateWithFontDescriptor(d, size, nil)
}
func line(_ s: String, _ font: CTFont, _ color: CGColor, tracking: CGFloat) -> CTLine {
    let size = CTFontGetSize(font)
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        NSAttributedString.Key(kCTKernAttributeName as String): size * tracking,
    ]
    return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
}
func width(_ l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

// Background and the two glows of the hero.
ctx.setFillColor(bg)
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
func glow(_ c: CGColor, at p: CGPoint, radius: CGFloat, alpha: CGFloat) {
    let g = CGGradient(colorsSpace: cs, colors: [c.copy(alpha: alpha)!, c.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
}
glow(coral, at: CGPoint(x: 220, y: H - 190), radius: 620, alpha: 0.20)
glow(azure, at: CGPoint(x: 1020, y: 120), radius: 560, alpha: 0.12)

// The two lanes, bending out of the top-left corner behind everything.
func lane(_ color: CGColor, x: CGFloat, radius: CGFloat, bottom: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    ctx.setStrokeColor(color.copy(alpha: alpha)!)
    ctx.setLineWidth(84)
    ctx.move(to: CGPoint(x: x, y: H + 20))
    ctx.addLine(to: CGPoint(x: x, y: bottom + radius))
    ctx.addArc(center: CGPoint(x: x + radius, y: bottom + radius), radius: radius,
               startAngle: .pi, endAngle: .pi * 1.5, clockwise: false)
    ctx.addLine(to: CGPoint(x: W + 20, y: bottom))
    ctx.strokePath()
    ctx.restoreGState()
}
lane(coral, x: 300, radius: 240, bottom: 40, alpha: 0.13)
lane(azure, x: 440, radius: 100, bottom: 180, alpha: 0.10)

// App window, off the right edge.
if let shot = NSImage(contentsOfFile: "docs/images/window-dark.png") {
    let w: CGFloat = 740
    let h = w * shot.size.height / shot.size.width
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: rgb(0x000000, 0.6))
    shot.draw(in: NSRect(x: 628, y: -40, width: w, height: h))
    ctx.restoreGState()
}

// Logo and wordmark.
let left: CGFloat = 68
if let logo = NSImage(contentsOfFile: "docs/images/logo.svg") {
    logo.draw(in: NSRect(x: left - 8, y: H - 66 - 64, width: 64, height: 64))
}
let mark = line("Lanes", inter(34, 750), ink, tracking: -0.02)
ctx.textPosition = CGPoint(x: left + 66, y: H - 66 - 44)
CTLineDraw(mark, ctx)

// Headline: Inter 800, the hero's -0.035em, three lines at 0.98 leading.
let size: CGFloat = 78
let font = inter(size, 800)
let lead = size * 0.98
let top = H - 236
func draw(_ s: String, _ color: CGColor, x: CGFloat, y: CGFloat) -> CGFloat {
    let l = line(s, font, color, tracking: -0.035)
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(l, ctx)
    return width(l)
}
_ = draw("Every Claude", ink, x: left, y: top)
_ = draw("account in its", ink, x: left, y: top - lead)
let y3 = top - lead * 2
var x = left + draw("own ", ink, x: left, y: y3)

// "lane" in the coral-to-peach sweep, clipped to its glyphs.
let laneLine = line("lane", font, ink, tracking: -0.035)
let laneW = width(laneLine)
ctx.saveGState()
ctx.setTextDrawingMode(.clip)
ctx.textPosition = CGPoint(x: x, y: y3)
CTLineDraw(laneLine, ctx)
let sweep = CGGradient(colorsSpace: cs, colors: [coral, peach] as CFArray, locations: [0.15, 0.85])!
ctx.drawLinearGradient(sweep, start: CGPoint(x: x, y: 0), end: CGPoint(x: x + laneW, y: 0), options: [])
ctx.restoreGState()
ctx.setTextDrawingMode(.fill)
x += laneW
_ = draw(".", azure, x: x, y: y3)

// Footnote.
let foot = line("For Claude Desktop on macOS · Free and open source", inter(22, 500), muted, tracking: 0)
ctx.textPosition = CGPoint(x: left, y: 68)
CTLineDraw(foot, ctx)

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
