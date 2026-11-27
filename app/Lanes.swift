// Lanes for Claude — a menu bar app for running several Claude Desktop
// accounts side by side.
//
// This file holds the model: usage fetching, system integrations, the
// profile store and the app's scenes. The views live in Window.swift,
// MenuBar.swift, Settings.swift and Components.swift.
//
// This app is a frontend only: profile creation and removal shell out to the
// copy of `lanes` bundled in Resources, so the CLI, the AppleScript chooser,
// and this app share one implementation. Profiles are discovered from the
// filesystem (~/Library/Application Support/Lanes/profiles/<Name>) on every refresh;
// there is no registry to sync. Running instances are detected by reading
// each Claude process's --user-data-dir argument out of `ps`, because all
// instances share one binary and differ only in that flag.

import SwiftUI
import AppKit
import Combine
import CommonCrypto
import UserNotifications
import ServiceManagement
import Carbon.HIToolbox
import WidgetKit
import UniformTypeIdentifiers

// MARK: - Shared helpers

let claudeAppPath: String = {
    let candidates = ["/Applications/Claude.app",
                      NSHomeDirectory() + "/Applications/Claude.app"]
    return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
}()

// Read once: every lane, sheet and preview draws it, tinted per profile.
let claudeIcon: NSImage = NSWorkspace.shared.icon(forFile: claudeAppPath)

// Read fresh every call (NOT via Bundle(path:), which caches infoDictionary
// and would miss a re-clone). Returns nil if the bundle/plist is absent.
func bundleVersion(_ appPath: String) -> String? {
    guard let dict = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist") else { return nil }
    return dict["CFBundleShortVersionString"] as? String
}

// True when `a` is strictly older than `b` (ordered dotted-numeric compare).
// Mirrors version_lt in bin/lanes — a plain != would wrongly flag a profile
// that self-updated AHEAD of the default as "behind".
func versionLessThan(_ a: String, _ b: String) -> Bool {
    if a == b { return false }
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x != y { return x < y }
    }
    return false
}

@discardableResult
func runTool(_ tool: String, _ args: [String], env: [String: String] = [:]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    if !env.isEmpty {
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        p.environment = e
    }
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    try p.run()
    // Read before waiting so a chatty child can't fill the pipe and deadlock.
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(data: outData, encoding: .utf8) ?? ""
    let errText = String(data: errData, encoding: .utf8) ?? ""
    if p.terminationStatus != 0 {
        throw NSError(domain: "lanes", code: Int(p.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: errText.isEmpty ? out : errText])
    }
    return out
}

// MARK: - Usage (claude.ai)

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
private func modelLimitLabel(_ key: String) -> String {
    let suffix = String(key.dropFirst("seven_day_".count))
    let known = ["opus": "Opus", "sonnet": "Sonnet", "haiku": "Haiku", "oauth_apps": "Apps"]
    return known[suffix] ?? suffix.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
}

private func parseISODate(_ v: Any?) -> Date? {
    guard let str = v as? String else { return nil }
    let frac = ISO8601DateFormatter()
    frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return frac.date(from: str) ?? ISO8601DateFormatter().date(from: str)
}

private func chromiumKey() throws -> Data {
    // Same Keychain item for every profile (clones share Claude's signature).
    // macOS asks once; "Always Allow" makes it silent afterwards.
    let pw = try runTool("/usr/bin/security", ["find-generic-password", "-w", "-s", "Claude Safe Storage"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    var key = Data(count: 16)
    let status = key.withUnsafeMutableBytes { k in
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.utf8.count, Array("saltysalt".utf8), 9,
                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                             k.bindMemory(to: UInt8.self).baseAddress, 16)
    }
    guard status == kCCSuccess else { throw usageError("key derivation failed") }
    return key
}

private func decryptCookie(_ blob: Data, key: Data) -> String? {
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
    return String(data: plain.dropFirst(32), encoding: .utf8)
}

// Code 2 marks a failure that points at claude.ai's side having changed (an
// endpoint gone, a reply in another shape) rather than at this Mac.
private func usageError(_ m: String, formatChanged: Bool = false) -> NSError {
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
    let key = try chromiumKey()
    var pairs: [String] = []
    for row in rows.split(separator: "\n") {
        let f = row.split(separator: "|", maxSplits: 1).map(String.init)
        guard f.count == 2, let blob = Data(hexString: f[1]), let v = decryptCookie(blob, key: key) else { continue }
        pairs.append("\(f[0])=\(v)")
    }
    guard pairs.contains(where: { $0.hasPrefix("sessionKey=") }) else { throw usageError("not signed in") }
    return pairs.joined(separator: "; ")
}

private extension Data {
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

func fetchUsage(dataDir: String) async throws -> Usage {
    let cookie = try claudeCookieHeader(dataDir: dataDir)
    func get(_ path: String) async throws -> Any {
        var r = URLRequest(url: URL(string: "https://claude.ai/api" + path)!)
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
    guard let orgs = try await get("/organizations") as? [[String: Any]], !orgs.isEmpty
    else { throw usageError("no organization") }
    func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
    // An account can belong to several organizations (API/Console, team, personal);
    // only some carry chat usage limits, so try each until one reports numbers.
    var raw: [[String: Any]] = []
    var best: Usage?
    for o in orgs {
        guard let id = o["uuid"] as? String,
              let j = try? await get("/organizations/\(id)/usage") as? [String: Any] else { continue }
        func pct(_ k: String) -> Double? { number((j[k] as? [String: Any])?["utilization"]) }
        func reset(_ k: String) -> Date? { parseISODate((j[k] as? [String: Any])?["resets_at"]) }
        // Per-model weekly limits ("seven_day_opus", …), read generically so a
        // new model family shows up without a Lanes update. Null when unused.
        let models = j.keys.sorted().filter { $0.hasPrefix("seven_day_") }.compactMap { k -> ModelLimit? in
            guard let v = pct(k) else { return nil }
            return ModelLimit(key: k, label: modelLimitLabel(k), used: v, reset: reset(k))
        }
        let u = Usage(fiveHour: pct("five_hour"), sevenDay: pct("seven_day"),
                      fiveHourReset: reset("five_hour"), sevenDayReset: reset("seven_day"), error: nil,
                      models: models)
        raw.append(["org": id, "name": o["name"] ?? "", "capabilities": o["capabilities"] ?? [], "usage": j])
        if u.fiveHour != nil || u.sevenDay != nil { return u }
        best = best ?? u
    }
    writeUsageDebug(dataDir: dataDir, raw: raw)
    // Not one organization answered: the endpoint itself is likely gone.
    return best ?? Usage(fiveHour: nil, sevenDay: nil, error: "unexpected response", formatChanged: true)
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

// MARK: - System integrations

// Shows banners even while the app is frontmost (the default is to suppress them).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    func setUp() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    // Fires at `date` even if the app has quit by then; posting again with the
    // same identifier replaces the pending one.
    func schedule(_ identifier: String, at date: Date, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
    func cancel(_ identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

// Global shortcuts: ⌥⌘P opens the menu bar panel, ⌥⌘B opens the profile with
// the most headroom. Each can be turned off on its own.
enum GlobalShortcut {
    enum Key: UInt32 { case panel = 1, best = 2 }
    private static var refs: [Key: EventHotKeyRef] = [:]
    private static var handlerInstalled = false

    static func setEnabled(_ key: Key, _ on: Bool) {
        if on {
            if !handlerInstalled {
                var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
                InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                    var hk = EventHotKeyID()
                    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                      nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                    DispatchQueue.main.async {
                        if hk.id == Key.best.rawValue { ProfileStore.shared.launchBest() } else { GlobalShortcut.togglePanel() }
                    }
                    return noErr
                }, 1, &spec, nil, nil)
                handlerInstalled = true
            }
            guard refs[key] == nil else { return }
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key == .panel ? kVK_ANSI_P : kVK_ANSI_B), UInt32(optionKey | cmdKey),
                                EventHotKeyID(signature: OSType(0x43445052), id: key.rawValue),
                                GetApplicationEventTarget(), 0, &ref)
            refs[key] = ref
        } else if let r = refs[key] {
            UnregisterEventHotKey(r)
            refs[key] = nil
        }
    }

    // Clicks the app's status item, which SwiftUI offers no API to open.
    static func togglePanel() {
        func button(in v: NSView?) -> NSButton? {
            guard let v else { return nil }
            if let b = v as? NSButton { return b }
            for sub in v.subviews { if let b = button(in: sub) { return b } }
            return nil
        }
        for w in NSApp.windows where String(describing: type(of: w)).contains("StatusBarWindow") {
            if let b = button(in: w.contentView) { b.performClick(nil); return }
        }
    }
}

// MARK: - Model

struct Profile: Identifiable, Hashable {
    let name: String
    let dataDir: String?          // nil = the default Claude install
    let colorName: String
    var id: String { name }
    var isDefault: Bool { dataDir == nil }
    var color: ProfileColor { ProfileColor.named(colorName) }
}

final class ProfileStore: ObservableObject {
    // One instance: the app delegate routes claude:// links into it, and those
    // can arrive before any scene exists (the link is what launched the app).
    static let shared = ProfileStore()

    @Published var profiles: [Profile] = [Profile(name: "Default", dataDir: nil, colorName: "orange")]
    @Published var running: Set<String> = []
    @Published var errorMessage: String?
    // Version of the installed Claude.app (the single update source) and the
    // profiles whose clone is behind it. Drives the update banner.
    @Published var installedVersion: String = ""
    @Published var outdatedProfiles: [String] = []
    @Published var showAdd = false                 // set from the menu bar, shown by the window
    @Published var usage: [String: Usage] = [:]    // keyed by Profile.id
    @Published var lastUsageUpdate: Date?
    @Published var isRefreshingUsage = false
    @Published var removeRequest: Profile?         // set from the menu bar, confirmed by the window

    // Preferences, persisted in UserDefaults.
    @Published var alertsEnabled = UserDefaults.standard.object(forKey: "alertsEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(alertsEnabled, forKey: "alertsEnabled")
            if alertsEnabled { Notifier.shared.setUp() }
        }
    }
    // The two alert levels, in percent of a limit. The second is kept above the first.
    static let warnLevels: [Double] = [50, 60, 70, 75, 80, 85, 90]
    static let urgentLevels: [Double] = [80, 85, 90, 95, 98]
    @Published var alertWarn: Double = UserDefaults.standard.object(forKey: "alertWarn") as? Double ?? 80 {
        didSet {
            UserDefaults.standard.set(alertWarn, forKey: "alertWarn")
            if alertUrgent <= alertWarn {
                alertUrgent = Self.urgentLevels.first { $0 > alertWarn } ?? 98
            }
        }
    }
    @Published var alertUrgent: Double = UserDefaults.standard.object(forKey: "alertUrgent") as? Double ?? 95 {
        didSet { UserDefaults.standard.set(alertUrgent, forKey: "alertUrgent") }
    }
    @Published var paceAlertsEnabled = UserDefaults.standard.object(forKey: "paceAlertsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(paceAlertsEnabled, forKey: "paceAlertsEnabled") }
    }
    @Published var shortcutEnabled = UserDefaults.standard.object(forKey: "shortcutEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(shortcutEnabled, forKey: "shortcutEnabled")
            GlobalShortcut.setEnabled(.panel, shortcutEnabled)
        }
    }
    @Published var bestShortcutEnabled = UserDefaults.standard.object(forKey: "bestShortcutEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(bestShortcutEnabled, forKey: "bestShortcutEnabled")
            GlobalShortcut.setEnabled(.best, bestShortcutEnabled)
        }
    }
    @Published var history: [String: [UsageSample]] = UsageHistory.load()
    @Published var usageInterval: Double = {
        let v = UserDefaults.standard.double(forKey: "usageInterval")
        return v > 0 ? v : 300
    }() {
        didSet {
            UserDefaults.standard.set(usageInterval, forKey: "usageInterval")
            scheduleUsageTimer()
        }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var autoUpdate = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoUpdate, forKey: "autoUpdate")
            if autoUpdate { checkForUpdate() }
        }
    }

    // Lanes' own updates (not Claude's): the newer release on GitHub, if any.
    @Published var availableUpdate: String?
    @Published var isUpdating = false
    @Published var isCheckingForUpdate = false
    @Published var lastUpdateCheck: Date?
    @Published var updateError: String?
    // A version whose install failed isn't retried automatically this session.
    private var failedUpdate: String?
    private var updateTimer: Timer?

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { errorMessage = error.localizedDescription }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // Last alert level sent per profile and limit ("Work/5h", "Work/7d"):
    // 0 below the first level, 1 from it, 2 from the second.
    private var alertLevel: [String: Int] = [:]
    // The reset (epoch) each pace alert was sent for, per "Work/5h": one per
    // window. Persisted so relaunching Lanes doesn't repeat it.
    private var paceAlerted: [String: Double] = UserDefaults.standard.dictionary(forKey: "paceAlerted") as? [String: Double] ?? [:] {
        didSet { UserDefaults.standard.set(paceAlerted, forKey: "paceAlerted") }
    }

    // Owned by the store (not a view) so the menu bar stays live with the window closed.
    private var timers: [Timer] = []
    private var usageTimer: Timer?
    // A non-live store (the screenshot renderer) holds sample data and never
    // touches processes, the network, hotkeys or link handling.
    let live: Bool

    init(live: Bool = true) {
        self.live = live
        guard live else { return }
        refresh()
        timers = [Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshRunning()
            self?.claimLinksIfNeeded()
        }]
        scheduleUsageTimer()
        if alertsEnabled { Notifier.shared.setUp() }
        GlobalShortcut.setEnabled(.panel, shortcutEnabled)
        GlobalShortcut.setEnabled(.best, bestShortcutEnabled)
        refreshUsage()
        startLinkRouting()
        // Not only from the window: an auto-update relaunches straight into
        // the menu bar, and the new version must still repoint launchers.
        setUp()
        // First check shortly after launch, then every 6 hours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkForUpdate() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // Asks GitHub for the latest release: releases/latest redirects to
    // …/releases/tag/v<version>. Nothing about this Mac is sent.
    func checkForUpdate() {
        guard live, !isCheckingForUpdate, !isUpdating else { return }
        isCheckingForUpdate = true
        var req = URLRequest(url: URL(string: "https://github.com/pego/lanes/releases/latest")!,
                             cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: req) { [weak self] _, response, _ in
            let tag = (response as? HTTPURLResponse)?.url?.lastPathComponent ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCheckingForUpdate = false
                guard tag.hasPrefix("v"), tag.dropFirst().first?.isNumber == true else { return }
                self.lastUpdateCheck = Date()
                let latest = String(tag.dropFirst())
                self.availableUpdate = versionLessThan(self.appVersion, latest) ? latest : nil
                if let v = self.availableUpdate, self.autoUpdate, v != self.failedUpdate {
                    self.installUpdate()
                }
            }
        }.resume()
    }

    // Hands the install to the bundled `lanes update`, which quits this app,
    // swaps the bundle and reopens it. Detached from us, output to a log
    // file: a pipe back to this process would break when it is quit.
    func installUpdate() {
        guard live, !isUpdating, let lanes = scriptPath else { return }
        let target = availableUpdate
        isUpdating = true
        updateError = nil
        let logDir = NSHomeDirectory() + "/Library/Caches/Lanes"
        let logPath = logDir + "/update.log"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [lanes, "update", "--relaunch"]
        p.standardInput = FileHandle.nullDevice
        let log = FileHandle(forWritingAtPath: logPath)
        p.standardOutput = log ?? FileHandle.nullDevice
        p.standardError = log ?? FileHandle.nullDevice
        // Only reached when the update didn't happen: on success, this app is
        // quit and the new version opens.
        p.terminationHandler = { proc in
            DispatchQueue.main.async {
                self.isUpdating = false
                if proc.terminationStatus != 0 {
                    self.failedUpdate = target
                    let detail = (try? String(contentsOfFile: logPath, encoding: .utf8))?
                        .split(separator: "\n").last { $0.hasPrefix("✗") }
                        .map { String($0.dropFirst(2)) }
                    self.updateError = detail ?? "The update failed. Details: ~/Library/Caches/Lanes/update.log"
                }
            }
        }
        do { try p.run() } catch {
            isUpdating = false
            failedUpdate = target
            updateError = error.localizedDescription
        }
    }

    private func scheduleUsageTimer() {
        usageTimer?.invalidate()
        usageTimer = Timer.scheduledTimer(withTimeInterval: usageInterval, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }
    }

    // Called when the menu bar panel opens: skip the network if the data is fresh.
    func refreshUsageIfStale() {
        if let t = lastUsageUpdate, Date().timeIntervalSince(t) < 30 { return }
        refreshUsage()
    }

    func refreshUsage() {
        guard live, !isRefreshingUsage else { return }
        isRefreshingUsage = true
        let targets = profiles.map { ($0.id, $0.dataDir ?? appSupport + "/Claude") }
        Task.detached {
            for (id, dir) in targets {
                let u: Usage
                do { u = try await fetchUsage(dataDir: dir) }
                catch {
                    u = Usage(fiveHour: nil, sevenDay: nil, error: error.localizedDescription,
                              formatChanged: isFormatError(error))
                }
                await MainActor.run { self.apply(u, for: id) }
            }
            await MainActor.run {
                self.lastUsageUpdate = Date()
                self.isRefreshingUsage = false
                self.publishUsage()
            }
        }
    }

    // How long a failed check may keep showing the previous numbers.
    private static let staleGrace: TimeInterval = 3600

    private func apply(_ fresh: Usage, for id: String) {
        var u = fresh
        if u.error == nil {
            let samples = history[id] ?? []
            u.fiveHourPace = Forecast.pace(value: u.fiveHour, reset: u.fiveHourReset, window: LimitWindow.fiveHour,
                                           samples: samples.compactMap { s in s.h.map { (s.t, $0) } },
                                           lookback: 3600, minSpan: 15 * 60)
            u.sevenDayPace = Forecast.pace(value: u.sevenDay, reset: u.sevenDayReset, window: LimitWindow.week,
                                           samples: samples.compactMap { s in s.w.map { (s.t, $0) } },
                                           lookback: 86400, minSpan: 3 * 3600)
        } else if !u.needsSignIn, let prev = usage[id], prev.error == nil, !prev.hasNoData {
            // A failed check (network, claude.ai having a moment) keeps the
            // last numbers for a while, marked as stale, instead of blanking
            // the lane. Signing out still clears it at once.
            let since = prev.staleSince ?? lastUsageUpdate ?? Date()
            if Date().timeIntervalSince(since) < Self.staleGrace {
                u = prev
                u.staleError = fresh.error
                u.staleSince = since
                u.formatChanged = fresh.formatChanged
            }
        }
        if usage[id] != u { usage[id] = u }
        guard u.staleError == nil else { return }
        scheduleResetAlerts(u, for: id)
        thresholdAlerts(u, for: id)
        paceAlerts(u, for: id)
    }

    private func limits(_ u: Usage) -> [(key: String, label: String, value: Double?, reset: Date?, pace: Pace?)] {
        [("5h", "5-hour limit", u.fiveHour, u.fiveHourReset, u.fiveHourPace),
         ("7d", "weekly limit", u.sevenDay, u.sevenDayReset, u.sevenDayPace)]
    }

    // " Most room: Personal (88% left)." when another profile is a better bet.
    private func alternative(to id: String) -> String {
        guard let b = bestProfile(), b.id != id, let h = usage[b.id]?.fiveHour, h < 50 else { return "" }
        return " Most room: \(b.name) (\(max(0, 100 - Int(h.rounded())))% left)."
    }

    // An alert when a limit crosses the first or second level, for the
    // 5-hour and the weekly limit alike.
    private func thresholdAlerts(_ u: Usage, for id: String) {
        for l in limits(u) {
            guard let v = l.value else { continue }
            let level = v >= alertUrgent ? 2 : (v >= alertWarn ? 1 : 0)
            let key = "\(id)/\(l.key)"
            // First sample after launch only records the level, so restarting the
            // app at 85% doesn't fire a stale alert.
            guard let prev = alertLevel[key] else { alertLevel[key] = level; continue }
            alertLevel[key] = level
            guard level > prev, alertsEnabled else { continue }
            var body = "\(Int(v.rounded()))% of the \(l.label) used."
            if let r = resetText(l.reset) { body += " Limit \(r)." }
            body += alternative(to: id)
            Notifier.shared.post(title: "\(id): \(level == 2 ? "almost at" : "getting close to") the \(l.label)",
                                 body: body)
        }
    }

    // A heads-up when a limit, at its recent rate, will be used up well
    // before it resets: within 45 minutes for the 5-hour limit (with at least
    // 15 to spare), within a day for the weekly one (with at least 6 hours to
    // spare). Once per window.
    private func paceAlerts(_ u: Usage, for id: String) {
        guard alertsEnabled, paceAlertsEnabled else { return }
        let now = Date()
        for l in limits(u) {
            guard let v = l.value, v < alertUrgent, let reset = l.reset, let out = l.pace?.runsOutAt else { continue }
            let weekly = l.key == "7d"
            let soon: TimeInterval = weekly ? 86400 : 45 * 60
            let spare: TimeInterval = weekly ? 6 * 3600 : 15 * 60
            guard out.timeIntervalSince(now) <= soon, reset.timeIntervalSince(out) >= spare else { continue }
            let key = "\(id)/\(l.key)"
            // The same window, even if claude.ai nudged its reset time a little.
            if let sent = paceAlerted[key], abs(sent - reset.timeIntervalSince1970) < 3600 { continue }
            paceAlerted[key] = reset.timeIntervalSince1970
            let early = Int(reset.timeIntervalSince(out))
            let gap = early >= 86400 ? "\(early / 86400) day\(early >= 2 * 86400 ? "s" : "")"
                : early >= 3600 ? "\(early / 3600)h \(early % 3600 / 60)m" : "\(early / 60) min"
            Notifier.shared.post(
                title: "\(id) is on pace to run out",
                body: "At this rate, the \(l.label) is used up around \(clockText(out)), \(gap) before it resets."
                    + alternative(to: id))
        }
        // Forget windows that have long reset.
        let cutoff = now.timeIntervalSince1970 - 86400
        if paceAlerted.values.contains(where: { $0 < cutoff }) { paceAlerted = paceAlerted.filter { $0.value >= cutoff } }
    }

    // Every profile that should report usage fails in a way that points at
    // claude.ai having changed its usage endpoint, not at a network blip.
    var usageLooksBroken: Bool {
        let us = profiles.compactMap { usage[$0.id] }.filter { !$0.needsSignIn && !$0.hasNoData }
        return !us.isEmpty && us.allSatisfy { ($0.error != nil || $0.staleError != nil) && $0.formatChanged }
    }

    // A limit that's nearly used up (past the first alert level) gets a
    // notification at its exact reset time, scheduled with the system so it
    // fires even if this app has quit. Re-scheduled on every refresh (same
    // identifier), so a moved reset time or a drop back under it is picked up.
    private func scheduleResetAlerts(_ u: Usage, for id: String) {
        for l in limits(u) {
            let ident = "reset-\(l.key)-\(id)"
            guard alertsEnabled, let v = l.value, v >= alertWarn, let r = l.reset, r > Date() else {
                Notifier.shared.cancel([ident]); continue
            }
            Notifier.shared.schedule(ident, at: r, title: "\(id): \(l.label) reset",
                                     body: "\(id) has its full \(l.label) again. You're good to go.")
        }
    }

    // MARK: Usage snapshot, history, best profile

    // Writes usage.json (widget, `lanes usage --json`) and usage.tsv (`lanes usage`,
    // `lanes launch --best`), records history, and asks WidgetKit to redraw.
    func publishUsage() {
        let now = Date()
        let entries = profiles.map { p -> UsageSnapshot.Entry in
            let u = usage[p.id]
            return .init(name: p.name, color: p.colorName, running: running.contains(p.id),
                         fiveHour: u?.fiveHour, sevenDay: u?.sevenDay,
                         fiveHourReset: u?.fiveHourReset, sevenDayReset: u?.sevenDayReset, error: u?.error,
                         fiveHourRunsOut: u?.fiveHourPace?.runsOutAt, sevenDayRunsOut: u?.sevenDayPace?.runsOutAt,
                         limits: u.flatMap { $0.models.isEmpty ? nil : $0.models },
                         staleSince: u?.staleSince)
        }
        let dir = UsageSnapshot.directory
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? UsageSnapshot.encoder.encode(UsageSnapshot(updated: now, profiles: entries)) {
            try? data.write(to: URL(fileURLWithPath: UsageSnapshot.path), options: .atomic)
        }
        // One line per profile, tab-separated, for the shell: name color running
        // 5h% 5h-reset 7d% 7d-reset error 5h-runs-out 7d-runs-out models stale-since.
        // Empty field = unknown; times are epoch; models is
        // "Opus=12@<reset>,Sonnet=3@<reset>". New columns only ever go at the end.
        func n(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "" }
        func t(_ d: Date?) -> String { d.map { String(Int($0.timeIntervalSince1970)) } ?? "" }
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        var tsv = "# updated \(Int(now.timeIntervalSince1970))\n"
        for e in entries {
            let models = (e.limits ?? []).map {
                clean($0.label).replacingOccurrences(of: ",", with: " ") + "=" + n($0.used) + "@" + t($0.reset)
            }.joined(separator: ",")
            tsv += [e.name, e.color, e.running ? "1" : "0", n(e.fiveHour), t(e.fiveHourReset),
                    n(e.sevenDay), t(e.sevenDayReset), clean(e.error ?? ""),
                    t(e.fiveHourRunsOut), t(e.sevenDayRunsOut), models, t(e.staleSince)]
                .joined(separator: "\t") + "\n"
        }
        try? tsv.write(toFile: dir + "/usage.tsv", atomically: true, encoding: .utf8)

        // Stale numbers are a repeat of an older reading, not a new one.
        var h = history
        for e in entries where e.error == nil && e.staleSince == nil && (e.fiveHour != nil || e.sevenDay != nil) {
            UsageHistory.append(UsageSample(t: now, h: e.fiveHour, w: e.sevenDay), to: &h[e.name, default: []])
        }
        UsageHistory.prune(&h, profiles: Set(entries.map(\.name)))
        if h != history { history = h; UsageHistory.save(h) }

        WidgetCenter.shared.reloadAllTimelines()
    }

    // Most 5-hour headroom, weekly as the tie-breaker; a profile whose weekly
    // limit is used up only wins if every one is.
    func bestProfile() -> Profile? {
        let scored = profiles.compactMap { p -> (Profile, Double, Double)? in
            guard let u = usage[p.id], u.error == nil, let h = u.fiveHour else { return nil }
            return (p, h, u.sevenDay ?? 0)
        }
        let usable = scored.filter { $0.2 < 100 }
        return (usable.isEmpty ? scored : usable).min { ($0.1, $0.2) < ($1.1, $1.2) }?.0
    }

    // The best profile, but only when there's a real choice: two or more
    // profiles with usage numbers. Drives the "most room" callouts.
    func roomiestProfile() -> Profile? {
        let withData = profiles.filter { usage[$0.id]?.fiveHour != nil && usage[$0.id]?.error == nil }
        return withData.count >= 2 ? bestProfile() : nil
    }

    // "3 profiles · 1 running · most room in Work (92% left)"
    var summary: String {
        let n = profiles.count, r = running.count
        var parts = ["\(n) profile\(n == 1 ? "" : "s")", r == 0 ? "none running" : "\(r) running"]
        if let b = roomiestProfile(), let h = usage[b.id]?.fiveHour {
            parts.append("most room in \(b.name) (\(max(0, 100 - Int(h.rounded())))% left)")
        }
        return parts.joined(separator: " · ")
    }

    // The Claude version a profile runs: its own clone, or the installed app.
    func claudeVersion(of p: Profile) -> String? {
        bundleVersion(bundlePath(for: p))
    }

    func dataPath(of p: Profile) -> String { p.dataDir ?? appSupport + "/Claude" }

    func launchBest() {
        if let p = bestProfile() {
            launch(p)
        } else {
            NSSound.beep()
            Notifier.shared.post(title: "No usage data yet", body: "Lanes can't tell which profile is most free until usage loads.")
        }
    }

    private let appSupport = NSHomeDirectory() + "/Library/Application Support"
    private let clonesDir = UsageSnapshot.directory + "/apps"
    private let profilesDir = UsageSnapshot.directory + "/profiles"
    private var scriptPath: String? { Bundle.main.path(forResource: "lanes", ofType: nil) }

    func refresh() {
        guard live else { return }
        var list = [Profile(name: "Default", dataDir: nil, colorName: "orange")]
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(atPath: profilesDir) {
            for entry in entries.sorted() where !entry.hasPrefix(".") {
                var isDir: ObjCBool = false
                let full = profilesDir + "/" + entry
                if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                    let color = (try? String(contentsOfFile: full + "/.lanes-color", encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "orange"
                    list.append(Profile(name: entry, dataDir: full, colorName: color))
                }
            }
        }
        // Only publish on actual change: every @Published assignment re-renders
        // the cards, which dismisses any open Menu mid-interaction.
        if list != profiles { profiles = list }
        refreshRunning()
    }

    func refreshRunning() {
        guard live, let out = try? runTool("/bin/ps", ["-axo", "command"]) else { return }
        var found = Set<String>()
        for lineSub in out.split(separator: "\n") {
            let line = String(lineSub)
            // Match the main binary of the original bundle OR a profile clone
            // ("Claude Work.app/Contents/MacOS/Claude"). Helper (Renderer/
            // GPU/…) processes inherit the flag; skip them so one instance
            // doesn't show up five times.
            guard line.contains("/Contents/MacOS/Claude"),
                  !line.contains("Helper") else { continue }
            if let r = line.range(of: "--user-data-dir=") {
                let rest = String(line[r.upperBound...])
                // The whole path, not a prefix: "Work" must not match "Workshop".
                for p in profiles {
                    if let d = p.dataDir, rest == d || rest.hasPrefix(d + " ") { found.insert(p.id) }
                }
            } else if line.contains("Claude.app/Contents/MacOS/Claude") {
                found.insert("Default")
            }
        }
        // Same deal as refresh(): the 2s poller must not republish an
        // unchanged set, or it closes menus the user is currently using.
        if found != running { running = found }

        // Version drift, informational only. Profiles self-update on their
        // own; a profile whose clone is strictly OLDER than the installed
        // default will also catch up (re-clone forward) on its next launch.
        // We surface just those — never a clone that self-updated AHEAD of
        // the default, which is fine and must not read as "behind".
        let installed = bundleVersion(claudeAppPath) ?? ""
        if installed != installedVersion { installedVersion = installed }
        var behind: [String] = []
        if !installed.isEmpty {
            for p in profiles where !p.isDefault {
                if let v = bundleVersion(clonesDir + "/Claude \(p.name).app"),
                   versionLessThan(v, installed) {
                    behind.append(p.name)
                }
            }
        }
        if behind != outdatedProfiles { outdatedProfiles = behind }
    }

    func launch(_ p: Profile) {
        if p.isDefault {
            do { try runTool("/usr/bin/open", ["-a", claudeAppPath]) }
            catch { errorMessage = error.localizedDescription }
        } else {
            // lanes launch runs the profile from its own Claude.app clone (the
            // Dock tile wears the profile color and owns the window) or
            // focuses the running instance without spawning a new window.
            callCdp(["launch", p.name])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.refreshRunning() }
    }

    func add(_ name: String, color: String) {
        callCdp(["add", "--color", color, "--", name])
    }

    func setColor(_ p: Profile, color: String) {
        callCdp(["color", p.name, color])
    }

    func remove(_ p: Profile, deleteData: Bool) {
        callCdp(["remove", p.name, deleteData ? "--delete-data" : "--keep-data"])
    }

    // A new version's first launch points launchers, watchdog and helper at
    // this app's lanes. Off the main thread: rebuilding launchers takes seconds.
    private var didSetUp = false
    func setUp() {
        guard live, !didSetUp, let lanes = scriptPath else { return }
        didSetUp = true
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do { try runTool("/bin/zsh", [lanes, "setup", "--if-needed"], env: ["LANES_FROM_CHOOSER": "1"]) }
            catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                if let failure { self.errorMessage = failure }
                self.refresh()
            }
        }
    }

    private func callCdp(_ args: [String]) {
        guard let lanes = scriptPath else {
            errorMessage = "Bundled lanes script is missing from the app. Rebuild with: lanes gui"
            return
        }
        do {
            // LANES_FROM_CHOOSER stops lanes from rebuilding the app bundle
            // that is currently running us.
            try runTool("/bin/zsh", [lanes] + args, env: ["LANES_FROM_CHOOSER": "1"])
        } catch { errorMessage = error.localizedDescription }
        refresh()
    }

    func revealData(_ p: Profile) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dataPath(of: p))
    }

    // Saves a profile's usage history as CSV wherever the user picks.
    func exportHistory(_ p: Profile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Lanes \(p.name) usage.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "The last 30 days of \(p.name)'s usage, one reading every ten minutes."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try UsageHistory.csv(history[p.name] ?? []).write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = error.localizedDescription }
    }

    // MARK: claude:// link routing
    //
    // macOS hands a claude:// link (the sign-in token, "open in app" links)
    // to whichever Claude is running, since every clone shares one bundle id.
    // When routing is on, this app is the scheme's default handler instead and
    // forwards each link to one profile: NSWorkspace.open(_:withApplicationAt:)
    // with that profile's clone delivers it to the running instance of exactly
    // that bundle. Claude re-registers itself as the handler on every launch,
    // so the 2 s poller claims it back.

    @Published var routeLinks = UserDefaults.standard.object(forKey: "routeLinks") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(routeLinks, forKey: "routeLinks")
            lastClaim = nil
            if routeLinks { claimLinksIfNeeded() } else { releaseLinks() }
        }
    }
    // The profile whose Claude window was frontmost most recently: the one
    // that just opened the browser to sign in, so it's the picker's default.
    private var lastActive: String?
    private var lastClaim: Date?
    private var activationObserver: NSObjectProtocol?
    private static let claudeBundleID = "com.anthropic.claudefordesktop"
    private static let probeURL = URL(string: "claude://")!

    func bundlePath(for p: Profile) -> String {
        p.isDefault ? claudeAppPath : clonesDir + "/Claude \(p.name).app"
    }

    private func profileID(forBundle url: URL?) -> String? {
        guard let path = url?.standardizedFileURL.path else { return nil }
        return profiles.first { URL(fileURLWithPath: bundlePath(for: $0)).standardizedFileURL.path == path }?.id
    }

    private func runningApp(for p: Profile) -> NSRunningApplication? {
        let want = URL(fileURLWithPath: bundlePath(for: p)).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == Self.claudeBundleID && $0.bundleURL?.standardizedFileURL.path == want
        }
    }

    func startLinkRouting() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Self.claudeBundleID,
                  let id = self.profileID(forBundle: app.bundleURL) else { return }
            self.lastActive = id
        }
        claimLinksIfNeeded()
    }

    // Cheap enough for the 2 s poller: one LaunchServices lookup, and a write
    // only when Claude took the scheme back (throttled in case it fails).
    func claimLinksIfNeeded() {
        guard routeLinks, !Bundle.main.bundlePath.contains("/AppTranslocation/") else { return }
        // Compared by bundle id, the key LaunchServices stores the default
        // under: with a second copy installed it may resolve to that path.
        let me = Bundle.main.bundleURL.standardizedFileURL
        if let cur = NSWorkspace.shared.urlForApplication(toOpen: Self.probeURL),
           Bundle(url: cur)?.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        if let t = lastClaim, Date().timeIntervalSince(t) < 10 { return }
        lastClaim = Date()
        NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: "claude") { _ in }
    }

    private func releaseLinks() {
        NSWorkspace.shared.setDefaultApplication(at: URL(fileURLWithPath: claudeAppPath),
                                                 toOpenURLsWithScheme: "claude") { _ in }
    }

    func route(_ url: URL) {
        refresh()
        let live = profiles.filter { running.contains($0.id) }
        if live.count == 1 { deliver(url, to: live[0]); return }
        // None running: pick which to start. Several: the frontmost-most-recently
        // one is preselected, so Return confirms the usual case.
        let preselect = live.first { $0.id == lastActive }?.id ?? live.first?.id ?? profiles.first?.id
        if let p = pickProfile(for: url, preselect: preselect) { deliver(url, to: p) }
    }

    private func pickProfile(for url: URL, preselect: String?) -> Profile? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Open this Claude link in which profile?"
        // Never show the query: a sign-in link carries its token there.
        let where_ = [url.host, url.path.isEmpty ? nil : url.path].compactMap { $0 }.joined()
        alert.informativeText = (where_.isEmpty ? "" : "claude://\(where_)\n\n")
            + "Sign-in links belong to the profile you clicked \"Log in\" in."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        for p in profiles {
            let item = NSMenuItem(title: p.name + (running.contains(p.id) ? "" : "  (not running)"),
                                  action: nil, keyEquivalent: "")
            item.representedObject = p.id
            item.image = Self.swatchImage(NSColor(p.color.swatch))
            popup.menu?.addItem(item)
            if p.id == preselect { popup.select(item) }
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              let id = popup.selectedItem?.representedObject as? String else { return nil }
        return profiles.first { $0.id == id }
    }

    private static func swatchImage(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r).fill()
            return true
        }
    }

    private func deliver(_ url: URL, to p: Profile) {
        lastActive = p.id
        if p.isDefault || running.contains(p.id) && runningApp(for: p) != nil {
            open(url, in: p)
            return
        }
        // Never open a link with a clone that isn't running: LaunchServices
        // would start it without --user-data-dir, on the DEFAULT account. Start
        // it isolated through lanes, then forward once both ps (the flag) and
        // LaunchServices (the bundle) see it, so the link can't spawn a copy.
        guard let lanes = scriptPath else { linkFailed("The bundled lanes script is missing from the app."); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do { try runTool("/bin/zsh", [lanes, "launch", p.name], env: ["LANES_FROM_CHOOSER": "1"]) }
            catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                if let failure { self.linkFailed(failure); return }
                self.waitForLaunch(of: p, deadline: Date().addingTimeInterval(30)) { self.open(url, in: p) }
            }
        }
    }

    private func waitForLaunch(of p: Profile, deadline: Date, then: @escaping () -> Void) {
        refreshRunning()
        if running.contains(p.id), runningApp(for: p) != nil {
            // Electron queues open-url until it's ready, but give LaunchServices
            // a beat to finish the check-in it just reported.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: then)
        } else if Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.waitForLaunch(of: p, deadline: deadline, then: then) }
        } else {
            linkFailed("\(p.name) didn't start in time, so the Claude link wasn't opened. Click it again.")
        }
    }

    // The window (and its error alert) is usually closed while routing.
    private func linkFailed(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't open the Claude link"
        alert.informativeText = message
        alert.runModal()
    }

    private func open(_ url: URL, in p: Profile) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: bundlePath(for: p)),
                                configuration: cfg) { _, error in
            if let error { DispatchQueue.main.async { self.linkFailed(error.localizedDescription) } }
        }
    }
}

// MARK: - App

// A menu bar app: no Dock icon (LSUIElement), and the window is only a
// utility surface for adding/removing profiles. Opening the app again (Spotlight,
// Finder) pops the menu bar panel instead of a window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Our own GetURL handler rather than SwiftUI's onOpenURL, which would also
    // bring up the window scene. Installed before launch finishes so the link
    // that cold-starts the app isn't dropped.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: s) else { return }
        // lanes:// comes from the widget: launch?profile=<name>, or open.
        if url.scheme?.lowercased() == "lanes" {
            DispatchQueue.main.async {
                let store = ProfileStore.shared
                let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "profile" }?.value
                if url.host == "launch", let name, let p = store.profiles.first(where: { $0.name == name }) {
                    store.launch(p)
                } else {
                    GlobalShortcut.togglePanel()
                }
            }
            return
        }
        guard url.scheme?.lowercased() == "claude" else { return }
        // Let the Apple Event return before the (modal) picker runs.
        DispatchQueue.main.async { ProfileStore.shared.route(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { GlobalShortcut.togglePanel() }
        return flag
    }
}

// The screenshot renderer (scripts/snapshots.sh) compiles these sources with
// its own entry point.
#if !LANES_SNAPSHOT
@main
#endif
struct LanesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = ProfileStore.shared

    var body: some Scene {
        // Window (not WindowGroup): openWindow from the menu bar must reuse it.
        Window("Lanes", id: "main") {
            LanesWindow(store: store)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 780, height: 540)

        Window("Lanes Settings", id: "settings") {
            SettingsView(store: store)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuPanel(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Usage history

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
