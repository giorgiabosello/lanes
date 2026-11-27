// Usage history (the drawer's chart, CSV export) and the forecast built on it.

import Foundation

// One usage reading. Short keys: the file holds a week of them per profile.
struct UsageSample: Codable, Equatable {
    var t: Date
    var h: Double?   // 5-hour %
    var w: Double?   // weekly %
}

// 30 days of readings per profile in usage-history.json, at most one every
// ~10 minutes whatever the refresh interval (about 200 KB per profile).
// Local only, never sent anywhere.
enum UsageHistory {
    static let keep: TimeInterval = 30 * 86400
    static var path: String { UsageSnapshot.directory + "/usage-history.json" }

    static func load() -> [String: [UsageSample]] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return (try? d.decode([String: [UsageSample]].self, from: data)) ?? [:]
    }

    static func save(_ h: [String: [UsageSample]]) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        if let data = try? e.encode(h) { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }

    static func append(_ s: UsageSample, to list: inout [UsageSample]) {
        if let last = list.last, s.t.timeIntervalSince(last.t) < 9 * 60 { return }
        list.append(s)
    }

    static func prune(_ h: inout [String: [UsageSample]], profiles: Set<String>) {
        let cutoff = Date().addingTimeInterval(-keep)
        for k in h.keys {
            if !profiles.contains(k) { h[k] = nil; continue }
            h[k]?.removeAll { $0.t < cutoff }
        }
    }

    // time,five_hour,weekly: ISO 8601 UTC times, empty when unknown.
    // Same columns as `lanes history`, minus the profile.
    static func csv(_ samples: [UsageSample]) -> String {
        let f = ISO8601DateFormatter()
        func n(_ v: Double?) -> String { v.map { String(format: "%g", $0) } ?? "" }
        return "time,five_hour,weekly\n" + samples.map { "\(f.string(from: $0.t)),\(n($0.h)),\(n($0.w))\n" }.joined()
    }
}

// Where a limit is heading: its rate over the recent past (the last hour for
// the 5-hour limit, the last day for the weekly one), but only within the
// current window, so the drop at the last reset never counts. Needs a
// reading at least `minSpan` old to say anything. Usage that went down
// (a reset the readings straddle) counts as no usage.
enum Forecast {
    static func pace(value: Double?, reset: Date?, window: TimeInterval, samples: [(Date, Double)],
                     lookback: TimeInterval, minSpan: TimeInterval, now: Date = Date()) -> Pace? {
        guard let value, let reset, value < 100 else { return nil }
        let left = reset.timeIntervalSince(now)
        guard left > 0, left <= window else { return nil }
        let from = max(reset.addingTimeInterval(-window), now.addingTimeInterval(-lookback))
        guard let first = samples.first(where: { $0.0 >= from && $0.0 < now }) else { return nil }
        let span = now.timeIntervalSince(first.0)
        guard span >= minSpan else { return nil }
        let rate = max(0, (value - first.1) / span)          // percent per second
        let runsOut = rate > 0 ? (100 - value) / rate : .infinity
        return Pace(atReset: min(100, value + rate * left),
                    runsOutAt: runsOut < left ? now.addingTimeInterval(runsOut) : nil)
    }
}
