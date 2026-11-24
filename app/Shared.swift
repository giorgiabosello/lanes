// Shared by the Claude Profiles app and its widget extension (compiled into
// both): the color palette and the usage snapshot the app publishes for the
// widget and for `cdp usage`.

import SwiftUI

// Mirrors the HUES palette in bin/cdp — names must stay in sync.
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

// Written by the app after every usage refresh; read by the widget (sandboxed,
// with a read-only exception for this folder) and by `cdp usage --json`.
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
        return home + "/Library/Application Support/claude-desktop-profiles"
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
