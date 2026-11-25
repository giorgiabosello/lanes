// The small pieces the window, the menu bar panel and settings share. The
// visual idea throughout: each profile is a lane on a track, painted in its
// color, with dashed lane markings between them.

import SwiftUI
import AppKit
import CoreImage

// Claude's own icon, hue-shifted to the profile's color with the same
// CIHueAdjust the helper uses for the Dock tiles and launchers, so the
// window shows exactly the icon you'll find in the Dock.
struct TintedClaudeIcon: View {
    let color: ProfileColor
    var size: CGFloat = 40

    var body: some View {
        Image(nsImage: tintedClaudeIcon(hue: color.hue))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

private var tintCache: [Double: NSImage] = [:]

func tintedClaudeIcon(hue: Double) -> NSImage {
    if let hit = tintCache[hue] { return hit }
    let px = 256
    guard hue != 0,
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return claudeIcon }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    claudeIcon.draw(in: CGRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    guard let ci = CIImage(bitmapImageRep: rep), let f = CIFilter(name: "CIHueAdjust") else { return claudeIcon }
    f.setValue(ci, forKey: kCIInputImageKey)
    f.setValue(hue * .pi / 180, forKey: kCIInputAngleKey)
    guard let out = f.outputImage,
          let cg = CIContext().createCGImage(out, from: CGRect(x: 0, y: 0, width: px, height: px))
    else { return claudeIcon }
    let img = NSImage(cgImage: cg, size: NSSize(width: px, height: px))
    tintCache[hue] = img
    return img
}

// "Updated 2 min ago", kept current. Written out rather than a relative date
// style so it stays in the app's language whatever the system locale.
struct UpdatedAgo: View {
    let date: Date?
    var prefix = "Updated"

    var body: some View {
        if let date {
            TimelineView(.periodic(from: date, by: 10)) { ctx in
                Text("\(prefix) \(agoText(ctx.date.timeIntervalSince(date)))")
            }
        } else {
            Text("Fetching usage…")
        }
    }

    private func agoText(_ s: TimeInterval) -> String {
        if s < 15 { return "just now" }
        if s < 60 { return "\(Int(s)) s ago" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        return "\(Int(s / 3600)) h ago"
    }
}

// A horizontal track line: dashed between lanes, solid at the track's edges.
struct LaneMarking: View {
    var dashed = true
    var opacity: Double = 0.16

    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0.5))
                p.addLine(to: CGPoint(x: geo.size.width, y: 0.5))
            }
            .stroke(Color.primary.opacity(opacity),
                    style: StrokeStyle(lineWidth: 1, dash: dashed ? [7, 5] : []))
        }
        .frame(height: 1)
    }
}

// The lane's painted edge: bright while the profile is running.
struct LaneStripe: View {
    let tint: Color
    let lit: Bool
    var width: CGFloat = 4

    var body: some View {
        Capsule()
            .fill(tint.opacity(lit ? 1 : 0.35))
            .frame(width: width)
    }
}

// "5H 42%" over a meter, with when the limit resets underneath.
struct MeterCell: View {
    let label: String
    let value: Double?
    let reset: Date?
    let window: TimeInterval
    let tint: Color
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: compact ? 12 : 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(value.map { $0 >= 75 } == true ? usageColor(value, tint: tint) : Color.primary)
            }
            LaneMeter(value: value, tint: tint,
                      pace: elapsedFraction(reset: reset, window: window),
                      height: compact ? 5 : 6)
            Text(resetText(reset) ?? " ")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .help(paceHelp)
    }

    private var paceHelp: String {
        guard let e = elapsedFraction(reset: reset, window: window) else { return "" }
        return "The marker shows how much of this window has passed (\(Int((e * 100).rounded()))%). Usage left of it is on pace."
    }
}

// Why a lane has no meters: not signed in, an error, or nothing loaded yet.
struct LaneNote: View {
    let usage: Usage?

    var body: some View {
        HStack(spacing: 6) {
            if let usage {
                Image(systemName: symbol(usage))
                Text(text(usage))
            } else {
                ProgressView().controlSize(.mini)
                Text("Loading usage…")
            }
        }
        .font(.caption)
        .foregroundStyle(usage?.needsSignIn == true ? Color.orange : Color.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func symbol(_ u: Usage) -> String {
        if u.needsSignIn { return "person.crop.circle.badge.exclamationmark" }
        if u.error != nil { return "exclamationmark.triangle" }
        return "chart.bar"
    }

    private func text(_ u: Usage) -> String {
        if u.needsSignIn { return "Sign in to see usage" }
        if let e = u.error { return "Usage unavailable: \(e)" }
        return "No usage yet"
    }
}

// Shows a usage pair when there are numbers, otherwise why there aren't.
struct UsagePair: View {
    let usage: Usage?
    let tint: Color
    var compact = false
    var spacing: CGFloat = 16

    var body: some View {
        if let u = usage, u.error == nil, !u.hasNoData {
            HStack(alignment: .top, spacing: spacing) {
                MeterCell(label: "5 hours", value: u.fiveHour, reset: u.fiveHourReset,
                          window: LimitWindow.fiveHour, tint: tint, compact: compact)
                MeterCell(label: "Week", value: u.sevenDay, reset: u.sevenDayReset,
                          window: LimitWindow.week, tint: tint, compact: compact)
            }
        } else {
            LaneNote(usage: usage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// "● Running" in green, or a quiet "Stopped".
struct RunState: View {
    let running: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(running ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(running ? "Running" : "Stopped")
        }
        .font(.caption)
        .foregroundStyle(running ? Color.green : Color.secondary)
    }
}

// A keyboard shortcut drawn as a key cap.
struct KeyCap: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 10.5, weight: .medium).monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
    }
}

// A borderless button that lights up on hover: panel actions, icon buttons.
struct HoverButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 7
    var padding = EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8)

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, cornerRadius: cornerRadius, padding: padding)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        let padding: EdgeInsets
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(padding)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (hovering ? 0.08 : 0)))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

// Mirrors slugify + displayify in bin/lanes: "client acme" → "Client Acme".
// Used to preview the launcher name and catch duplicates before creating.
func profileDisplayName(_ raw: String) -> String {
    raw.lowercased()
        .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

func tildePath(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
