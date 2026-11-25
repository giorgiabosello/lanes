// Shared by the Lanes app and its widget extension (compiled into
// both): the color palette and the usage snapshot the app publishes for the
// widget and for `lanes usage`.

import SwiftUI

// Mirrors the HUES palette in bin/lanes — names must stay in sync.
struct ProfileColor: Identifiable, Hashable {
    let name: String
    let hue: Double        // degrees of hue rotation applied to Claude's icon
    let swatch: Color      // matching UI accent

    var id: String { name }

    static let all: [ProfileColor] = [
        ProfileColor(name: "orange", hue: 0,   swatch: Color(red: 0.85, green: 0.47, blue: 0.34)),
        ProfileColor(name: "red",    hue: -25, swatch: Color(red: 0.86, green: 0.34, blue: 0.32)),
        ProfileColor(name: "yellow", hue: 40,  swatch: Color(red: 0.80, green: 0.63, blue: 0.25)),
        ProfileColor(name: "green",  hue: 110, swatch: Color(red: 0.36, green: 0.69, blue: 0.42)),
        ProfileColor(name: "teal",   hue: 160, swatch: Color(red: 0.27, green: 0.65, blue: 0.62)),
        ProfileColor(name: "blue",   hue: 200, swatch: Color(red: 0.33, green: 0.56, blue: 0.83)),
        ProfileColor(name: "purple", hue: 250, swatch: Color(red: 0.62, green: 0.47, blue: 0.83)),
        ProfileColor(name: "pink",   hue: 310, swatch: Color(red: 0.83, green: 0.42, blue: 0.62)),
    ]

    static func named(_ name: String) -> ProfileColor {
        all.first { $0.name == name } ?? all[0]
    }
}

// Bar color for a usage percentage: the profile's color, orange from 75%, red from 90%.
func usageColor(_ value: Double?, tint: Color) -> Color {
    guard let value else { return .secondary }
    if value >= 90 { return .red }
    if value >= 75 { return .orange }
    return tint
}

// The two rolling limits claude.ai reports, and how long each window runs.
enum LimitWindow {
    static let fiveHour: TimeInterval = 5 * 3600
    static let week: TimeInterval = 7 * 86400
}

// How far through its window a limit is (0…1), worked out from its reset
// time. Drawn as the pace marker on a meter: usage left of the marker is
// burning slower than the clock.
func elapsedFraction(reset: Date?, window: TimeInterval, now: Date = Date()) -> Double? {
    guard let reset else { return nil }
    let remaining = reset.timeIntervalSince(now)
    guard remaining > 0, remaining <= window else { return nil }
    return 1 - remaining / window
}

// A lane-style usage meter: a track, the used share in the profile's color
// (orange/red near the limit), and an optional pace marker.
struct LaneMeter: View {
    let value: Double?
    let tint: Color
    var pace: Double? = nil
    var height: CGFloat = 6

    private var fraction: Double { min(max((value ?? 0) / 100, 0), 1) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                if fraction > 0 {
                    Capsule().fill(usageColor(value, tint: tint))
                        .frame(width: max(height, w * fraction))
                }
                if let pace {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.7))
                        .frame(width: 2, height: height + 6)
                        .offset(x: min(max(w * pace - 1, 0), w - 2))
                }
            }
            .frame(height: height)
        }
        .frame(height: height)
    }
}

// Written by the app after every usage refresh; read by the widget (sandboxed,
// with a read-only exception for this folder) and by `lanes usage --json`.
struct UsageSnapshot: Codable {
    struct Entry: Codable, Identifiable {
        var name: String
        var color: String
        var running: Bool
        var fiveHour: Double?
        var sevenDay: Double?
        var fiveHourReset: Date?
        var sevenDayReset: Date?
        var error: String?
        var id: String { name }
    }
    var updated: Date
    var profiles: [Entry]

    // The real home, not the sandbox container NSHomeDirectory() returns in the widget.
    static var directory: String {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return home + "/Library/Application Support/Lanes"
    }
    static var path: String { directory + "/usage.json" }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static func load() -> UsageSnapshot? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(UsageSnapshot.self, from: data)
    }
}
