// Reading usage: claude.ai's usage endpoint, called with each profile's own
// session cookies, and the local file Claude Desktop keeps as a fallback.

import Foundation
import CommonCrypto

// Reads the same numbers as Settings > Usage by calling claude.ai with the
// profile's own session cookies, decrypted from its Electron cookie jar.
// shortcut: undocumented endpoint, may change without notice; the cookies are
// only read, never stored, and only sent to claude.ai.
struct Usage: Equatable {
    var fiveHour: Double?   // percent of the 5-hour limit used
    var sevenDay: Double?   // percent of the weekly limit used
    var fiveHourReset: Date?
    var sevenDayReset: Date?
    var error: String?
    // Weekly limits for single model families, when the account has them.
    var models: [ModelLimit] = []
    // Where each limit is heading at the current rate (see Forecast).
    var fiveHourPace: Pace? = nil
    var sevenDayPace: Pace? = nil
    // The last check failed (staleError), so these are the numbers from
    // staleSince: still shown, for up to an hour, rather than blanked.
    var staleError: String? = nil
    var staleSince: Date? = nil
    // Those older numbers come from Claude Desktop's own record (LocalUsage),
    // not from Lanes' last reading.
    var fromClaudeDesktop = false
    // The failure looks like claude.ai changed its usage endpoint rather than
    // a network hiccup: drives the "can't read usage" banner.
    var formatChanged = false

    var needsSignIn: Bool { error == "not signed in" || error == "session expired" }
    var hasNoData: Bool { error == nil && fiveHour == nil && sevenDay == nil }
}

// Where a limit is heading if usage keeps its recent rate.
struct Pace: Equatable {
    var atReset: Double     // projected percent when the window resets (capped at 100)
    var runsOutAt: Date?    // when it hits 100%, if that's before the reset
}

// "resets in 2h 10m" within a day, "resets Mon 09:30" beyond that.
func resetText(_ date: Date?) -> String? {
    guard let date else { return nil }
    let secs = date.timeIntervalSinceNow
    guard secs > 0 else { return nil }
    if secs < 3600 { return "resets in \(max(1, Int((secs / 60).rounded(.up)))) min" }
    if secs < 24 * 3600 {
        let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
        return m == 0 ? "resets in \(h)h" : "resets in \(h)h \(m)m"
    }
    return "resets " + clockText(date)
}

// "15:40" today, "Thu 15:40" on another day. English day names, like the rest
// of the app, whatever the system locale.
func clockText(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
    return f.string(from: date)
}

// "Opus" for "seven_day_opus".
func modelLimitLabel(_ key: String) -> String {
    let suffix = String(key.dropFirst("seven_day_".count))
    let known = ["opus": "Opus", "sonnet": "Sonnet", "haiku": "Haiku", "oauth_apps": "Apps"]
    return known[suffix] ?? suffix.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
}

func parseISODate(_ v: Any?) -> Date? {
    guard let str = v as? String else { return nil }
    let frac = ISO8601DateFormatter()
    frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return frac.date(from: str) ?? ISO8601DateFormatter().date(from: str)
}


// MARK: Session cookies

// The key that decrypts Claude's cookies, derived from the "Claude Safe
// Storage" Keychain item. Every profile shares it (clones share Claude's
// signature), so it's read once and kept in memory: profiles checked in
// parallel would otherwise each ask the Keychain, and each could prompt.
// A failed read (the prompt denied) is remembered for a minute, so one
// refresh can't stack a prompt per profile.
enum ChromiumKey {
    private static let lock = NSLock()
    private static var cached: Data?
    private static var failure: (error: Error, at: Date)?
    static let retryAfter: TimeInterval = 60

    static func get() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if let failure, Date().timeIntervalSince(failure.at) < retryAfter { throw failure.error }
        do {
            // macOS asks once; "Always Allow" makes it silent afterwards.
            let pw = try runTool("/usr/bin/security", ["find-generic-password", "-w", "-s", "Claude Safe Storage"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let key = try derive(password: pw)
            cached = key
            failure = nil
            return key
        } catch {
            failure = (error, Date())
            throw error
        }
    }

    // Dropped when it no longer decrypts anything (the Keychain item changed).
    static func forget() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    static func derive(password pw: String) throws -> Data {
        var key = Data(count: 16)
        let status = key.withUnsafeMutableBytes { k in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.utf8.count, Array("saltysalt".utf8), 9,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                 k.bindMemory(to: UInt8.self).baseAddress, 16)
        }
        guard status == kCCSuccess else { throw usageError("key derivation failed") }
        return key
    }
}

func decryptCookie(_ blob: Data, key: Data) -> String? {
    guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { return nil }
    let body = blob.dropFirst(3)
    var out = Data(count: body.count + kCCBlockSizeAES128)
    var n = 0
    let iv = [UInt8](repeating: 0x20, count: 16)
    let outCap = out.count
    let status = out.withUnsafeMutableBytes { o in
        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                [UInt8](key), 16, iv, [UInt8](body), body.count, o.baseAddress, outCap, &n)
    }
    guard status == kCCSuccess else { return nil }
    let plain = out.prefix(n)
    // Newer Chromium prepends a 32-byte host hash; random bytes are not valid UTF-8.
    if let s = String(data: plain, encoding: .utf8) { return s }
    // Too short to hold that hash: garbage from a wrong key, not a value.
    guard plain.count > 32 else { return nil }
    return String(data: plain.dropFirst(32), encoding: .utf8)
}

// Code 2 marks a failure that points at claude.ai's side having changed (an
// endpoint gone, a reply in another shape) rather than at this Mac.
func usageError(_ m: String, formatChanged: Bool = false) -> NSError {
    NSError(domain: "usage", code: formatChanged ? 2 : 1, userInfo: [NSLocalizedDescriptionKey: m])
}

func isFormatError(_ error: Error) -> Bool {
    let ns = error as NSError
    return (ns.domain == "usage" && ns.code == 2) || ns.domain == NSCocoaErrorDomain
}

private func claudeCookieHeader(dataDir: String) throws -> String {
    let fm = FileManager.default
    guard let src = [dataDir + "/Network/Cookies", dataDir + "/Cookies"].first(where: fm.fileExists)
    else { throw usageError("not signed in") }
    // Copy first: Claude keeps the live database locked while it runs.
    let tmp = NSTemporaryDirectory() + "lanes-cookies-\(UUID().uuidString)"
    defer { for e in ["", "-wal", "-journal"] { try? fm.removeItem(atPath: tmp + e) } }
    for e in ["", "-wal", "-journal"] where fm.fileExists(atPath: src + e) { try fm.copyItem(atPath: src + e, toPath: tmp + e) }
    let rows = try runTool("/usr/bin/sqlite3", [tmp, "SELECT name || '|' || hex(encrypted_value) FROM cookies WHERE host_key LIKE '%claude.ai'"])
        .split(separator: "\n").compactMap { row -> (String, Data)? in
            let f = row.split(separator: "|", maxSplits: 1).map(String.init)
            guard f.count == 2, let blob = Data(hexString: f[1]) else { return nil }
            return (f[0], blob)
        }
    func decrypted(with key: Data) -> [String] {
        rows.compactMap { name, blob in decryptCookie(blob, key: key).map { "\(name)=\($0)" } }
    }
    var pairs = decrypted(with: try ChromiumKey.get())
    // Cookies there, yet none decrypts: the remembered key is out of date.
    if pairs.isEmpty, !rows.isEmpty {
        ChromiumKey.forget()
        pairs = decrypted(with: try ChromiumKey.get())
    }
    guard pairs.contains(where: { $0.hasPrefix("sessionKey=") }) else { throw usageError("not signed in") }
    return pairs.joined(separator: "; ")
}

extension Data {
    init?(hexString h: String) {
        guard h.count % 2 == 0 else { return nil }
        var d = Data(), i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
            d.append(b); i = j
        }
        self = d
    }
}

// MARK: claude.ai

// How long one profile's check may take, end to end, before it counts as
// failed: one slow or stuck profile must not hold up the others.
let usageTimeout: TimeInterval = 30

func fetchUsage(dataDir: String) async throws -> Usage {
    // The cookie read shells out (sqlite3, and the Keychain, which may wait
    // on a prompt): kept off Swift's cooperative threads.
    let cookie = try await offCooperativePool { try claudeCookieHeader(dataDir: dataDir) }
    func get(_ path: String) async throws -> Any {
        var r = URLRequest(url: URL(string: "https://claude.ai/api" + path)!, timeoutInterval: 20)
        r.setValue(cookie, forHTTPHeaderField: "Cookie")
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
                   forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw usageError(code == 401 || code == 403 ? "session expired" : "HTTP \(code)", formatChanged: code == 404)
        }
        return try JSONSerialization.jsonObject(with: data)
    }
    let result = try await usage(organizations: try await get("/organizations")) { id in
        try await get("/organizations/\(id)/usage")
    }
    if result.usage.error != nil || result.usage.hasNoData { writeUsageDebug(dataDir: dataDir, raw: result.raw) }
    return result.usage
}

// Picks the usage out of claude.ai's replies: the organization list, then
// each organization's usage until one reports numbers. Separate from the
// network so the parsing can be tested against saved replies.
func usage(organizations: Any,
           reply: (String) async throws -> Any) async throws -> (usage: Usage, raw: [[String: Any]]) {
    guard let orgs = organizations as? [[String: Any]], !orgs.isEmpty else { throw usageError("no organization") }
    // An account can belong to several organizations (API/Console, team, personal);
    // only some carry chat usage limits, so try each until one reports numbers.
    var raw: [[String: Any]] = []
    var best: Usage?
    for o in orgs {
        guard let id = o["uuid"] as? String,
              let j = try? await reply(id) as? [String: Any] else { continue }
        let u = parseUsageReply(j)
        raw.append(["org": id, "name": o["name"] ?? "", "capabilities": o["capabilities"] ?? [], "usage": j])
        if u.fiveHour != nil || u.sevenDay != nil { return (u, raw) }
        best = best ?? u
    }
    // Not one organization answered: the endpoint itself is likely gone.
    return (best ?? Usage(fiveHour: nil, sevenDay: nil, error: "unexpected response", formatChanged: true), raw)
}

// One organization's /usage reply.
func parseUsageReply(_ j: [String: Any]) -> Usage {
    func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
    func pct(_ k: String) -> Double? { number((j[k] as? [String: Any])?["utilization"]) }
    func reset(_ k: String) -> Date? { parseISODate((j[k] as? [String: Any])?["resets_at"]) }
    // Per-model weekly limits ("seven_day_opus", …), read generically so a
    // new model family shows up without a Lanes update. Null when unused.
    let models = j.keys.sorted().filter { $0.hasPrefix("seven_day_") }.compactMap { k -> ModelLimit? in
        guard let v = pct(k) else { return nil }
        return ModelLimit(key: k, label: modelLimitLabel(k), used: v, reset: reset(k))
    }
    return Usage(fiveHour: pct("five_hour"), sevenDay: pct("seven_day"),
                 fiveHourReset: reset("five_hour"), sevenDayReset: reset("seven_day"), error: nil,
                 models: models)
}

// When no organization reports usage, keep the raw replies (no cookies) so the
// cause can be inspected: ~/Library/Logs/Lanes/usage-debug.json
private func writeUsageDebug(dataDir: String, raw: [[String: Any]]) {
    let dir = NSHomeDirectory() + "/Library/Logs/Lanes"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let payload: [String: Any] = ["dataDir": dataDir, "date": ISO8601DateFormatter().string(from: Date()), "orgs": raw]
    if let d = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: URL(fileURLWithPath: dir + "/usage-debug-\((dataDir as NSString).lastPathComponent).json"))
    }
}

// MARK: Claude Desktop's own record

// Claude Desktop keeps a short history of the same percentages in each data
// folder (plan-usage-history.json), written whenever it checks usage itself.
// It has no reset times and only a handful of readings a day, so it is never
// the source, only a fallback: when claude.ai can't be reached, a reading
// there that's newer than Lanes' last one is better than nothing.
// shortcut: undocumented, internal format; anything unexpected reads as nil.
enum LocalUsage {
    struct Reading: Equatable {
        var t: Date
        var fiveHour: Double?
        var sevenDay: Double?
    }

    static func path(dataDir: String) -> String { dataDir + "/plan-usage-history.json" }

    static func latest(dataDir: String) -> Reading? {
        guard let data = FileManager.default.contents(atPath: path(dataDir: dataDir)) else { return nil }
        return latest(json: data)
    }

    // {"version":2,"samples":[{"t":<epoch ms>,"org":"…","u":{"fh":12,"sd":40}}, …]}
    static func latest(json data: Data) -> Reading? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let samples = root["samples"] as? [[String: Any]] else { return nil }
        func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        let readings = samples.compactMap { s -> Reading? in
            guard let ms = number(s["t"]), let u = s["u"] as? [String: Any] else { return nil }
            let r = Reading(t: Date(timeIntervalSince1970: ms / 1000), fiveHour: number(u["fh"]), sevenDay: number(u["sd"]))
            return r.fiveHour == nil && r.sevenDay == nil ? nil : r
        }
        return readings.max { $0.t < $1.t }
    }
}

// MARK: Concurrency helpers

// True for the first caller only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// Runs blocking work (a child process, a Keychain prompt) on a GCD thread.
func offCooperativePool<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { c in
        DispatchQueue.global(qos: .utility).async { c.resume(with: Result { try work() }) }
    }
}

// The result of `op`, or a "timed out" error after `seconds`, whichever
// comes first. The operation isn't cancelled (blocking work can't be); its
// late result is dropped.
func withTimeout<T>(_ seconds: TimeInterval, _ op: @escaping () async throws -> T) async throws -> T {
    let once = Once()
    return try await withCheckedThrowingContinuation { c in
        Task {
            let r: Result<T, Error>
            do { r = .success(try await op()) } catch { r = .failure(error) }
            if once.claim() { c.resume(with: r) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() { c.resume(throwing: usageError("timed out")) }
        }
    }
}
