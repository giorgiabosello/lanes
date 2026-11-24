// Claude Profiles — a SwiftUI window for managing Claude Desktop profiles.
//
// This app is a frontend only: profile creation and removal shell out to the
// copy of `cdp` bundled in Resources, so the CLI, the AppleScript chooser,
// and this app share one implementation. Profiles are discovered from the
// filesystem (~/Library/Application Support/Claude-<Name>) on every refresh;
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

// MARK: - Shared helpers

let claudeAppPath: String = {
    let candidates = ["/Applications/Claude.app",
                      NSHomeDirectory() + "/Applications/Claude.app"]
    return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
}()

var claudeIcon: NSImage { NSWorkspace.shared.icon(forFile: claudeAppPath) }

// Read fresh every call (NOT via Bundle(path:), which caches infoDictionary
// and would miss a re-clone). Returns nil if the bundle/plist is absent.
func bundleVersion(_ appPath: String) -> String? {
    guard let dict = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist") else { return nil }
    return dict["CFBundleShortVersionString"] as? String
}

// True when `a` is strictly older than `b` (ordered dotted-numeric compare).
// Mirrors version_lt in bin/cdp — a plain != would wrongly flag a profile
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
        throw NSError(domain: "cdp", code: Int(p.terminationStatus),
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

    var needsSignIn: Bool { error == "not signed in" || error == "session expired" }
    var hasNoData: Bool { error == nil && fiveHour == nil && sevenDay == nil }
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
    let f = DateFormatter()
    f.dateFormat = "EEE HH:mm"
    return "resets " + f.string(from: date)
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

private func usageError(_ m: String) -> NSError {
    NSError(domain: "usage", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
}

private func claudeCookieHeader(dataDir: String) throws -> String {
    let fm = FileManager.default
    guard let src = [dataDir + "/Network/Cookies", dataDir + "/Cookies"].first(where: fm.fileExists)
    else { throw usageError("not signed in") }
    // Copy first: Claude keeps the live database locked while it runs.
    let tmp = NSTemporaryDirectory() + "cdp-cookies-\(UUID().uuidString)"
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
        guard code == 200 else { throw usageError(code == 401 || code == 403 ? "session expired" : "HTTP \(code)") }
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
        let u = Usage(fiveHour: pct("five_hour"), sevenDay: pct("seven_day"),
                      fiveHourReset: reset("five_hour"), sevenDayReset: reset("seven_day"), error: nil)
        raw.append(["org": id, "name": o["name"] ?? "", "capabilities": o["capabilities"] ?? [], "usage": j])
        if u.fiveHour != nil || u.sevenDay != nil { return u }
        best = best ?? u
    }
    writeUsageDebug(dataDir: dataDir, raw: raw)
    return best ?? Usage(fiveHour: nil, sevenDay: nil, error: "unexpected response")
}

// When no organization reports usage, keep the raw replies (no cookies) so the
// cause can be inspected: ~/Library/Logs/Claude Profiles/usage-debug.json
private func writeUsageDebug(dataDir: String, raw: [[String: Any]]) {
    let dir = NSHomeDirectory() + "/Library/Logs/Claude Profiles"
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
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

// Global shortcut (⌥⌘P) that opens the menu bar panel.
enum GlobalShortcut {
    private static var ref: EventHotKeyRef?
    private static var handlerInstalled = false

    static func setEnabled(_ on: Bool) {
        if on {
            if !handlerInstalled {
                var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
                InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                    DispatchQueue.main.async { GlobalShortcut.togglePanel() }
                    return noErr
                }, 1, &spec, nil, nil)
                handlerInstalled = true
            }
            guard ref == nil else { return }
            RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(optionKey | cmdKey),
                                EventHotKeyID(signature: OSType(0x43445052), id: 1),
                                GetApplicationEventTarget(), 0, &ref)
        } else if let r = ref {
            UnregisterEventHotKey(r)
            ref = nil
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

struct Profile: Identifiable, Hashable {
    let name: String
    let dataDir: String?          // nil = the default Claude install
    let colorName: String
    var id: String { name }
    var isDefault: Bool { dataDir == nil }
    var color: ProfileColor { ProfileColor.named(colorName) }
}

final class ProfileStore: ObservableObject {
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
    @Published var shortcutEnabled = UserDefaults.standard.object(forKey: "shortcutEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(shortcutEnabled, forKey: "shortcutEnabled")
            GlobalShortcut.setEnabled(shortcutEnabled)
        }
    }
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

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { errorMessage = error.localizedDescription }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // Last alert level sent per profile for the 5-hour limit: 0 below 80%, 1 from 80%, 2 from 95%.
    private var alertLevel: [String: Int] = [:]

    // Owned by the store (not a view) so the menu bar stays live with the window closed.
    private var timers: [Timer] = []
    private var usageTimer: Timer?
    init() {
        refresh()
        timers = [Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshRunning() }]
        scheduleUsageTimer()
        if alertsEnabled { Notifier.shared.setUp() }
        GlobalShortcut.setEnabled(shortcutEnabled)
        refreshUsage()
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
        guard !isRefreshingUsage else { return }
        isRefreshingUsage = true
        let targets = profiles.map { ($0.id, $0.dataDir ?? appSupport + "/Claude") }
        Task.detached {
            for (id, dir) in targets {
                let u: Usage
                do { u = try await fetchUsage(dataDir: dir) }
                catch { u = Usage(fiveHour: nil, sevenDay: nil, error: error.localizedDescription) }
                await MainActor.run { self.apply(u, for: id) }
            }
            await MainActor.run {
                self.lastUsageUpdate = Date()
                self.isRefreshingUsage = false
            }
        }
    }

    private func apply(_ u: Usage, for id: String) {
        if usage[id] != u { usage[id] = u }
        guard let v = u.fiveHour else { return }
        let level = v >= 95 ? 2 : (v >= 80 ? 1 : 0)
        // First sample after launch only records the level, so restarting the
        // app at 85% doesn't fire a stale alert.
        guard let prev = alertLevel[id] else { alertLevel[id] = level; return }
        if level > prev {
            alertLevel[id] = level
            if alertsEnabled {
                var body = "\(Int(v.rounded()))% of the 5-hour limit used."
                if let r = resetText(u.fiveHourReset) { body += " Limit \(r)." }
                Notifier.shared.post(title: "\(id): \(level == 2 ? "almost at the limit" : "getting close to the limit")", body: body)
            }
        } else if level < prev && v < 30 {
            alertLevel[id] = level
            if alertsEnabled {
                Notifier.shared.post(title: "\(id): 5-hour limit reset", body: "Usage is back to \(Int(v.rounded()))%. You're good to go.")
            }
        } else if level < prev {
            alertLevel[id] = level
        }
    }

    private let appSupport = NSHomeDirectory() + "/Library/Application Support"
    private let clonesDir = NSHomeDirectory() + "/Library/Application Support/claude-desktop-profiles/apps"
    private var cdpPath: String? { Bundle.main.path(forResource: "cdp", ofType: nil) }

    func refresh() {
        var list = [Profile(name: "Default", dataDir: nil, colorName: "orange")]
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(atPath: appSupport) {
            for entry in entries.sorted() where entry.hasPrefix("Claude-") {
                var isDir: ObjCBool = false
                let full = appSupport + "/" + entry
                if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                    let color = (try? String(contentsOfFile: full + "/.cdp-color", encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "orange"
                    list.append(Profile(name: String(entry.dropFirst("Claude-".count)),
                                        dataDir: full, colorName: color))
                }
            }
        }
        // Only publish on actual change: every @Published assignment re-renders
        // the cards, which dismisses any open Menu mid-interaction.
        if list != profiles { profiles = list }
        refreshRunning()
    }

    func refreshRunning() {
        guard let out = try? runTool("/bin/ps", ["-axo", "command"]) else { return }
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
                for p in profiles {
                    if let d = p.dataDir, rest.hasPrefix(d) { found.insert(p.id) }
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
            // cdp launch runs the profile from its own Claude.app clone (the
            // Dock tile wears the profile color and owns the window) or
            // focuses the running instance without spawning a new window.
            callCdp(["launch", p.name])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.refreshRunning() }
    }

    func add(_ name: String, color: String) {
        callCdp(["add", name, "--color", color])
    }

    func setColor(_ p: Profile, color: String) {
        callCdp(["color", p.name, color])
    }

    func remove(_ p: Profile, deleteData: Bool) {
        callCdp(["remove", p.name, deleteData ? "--delete-data" : "--keep-data"])
    }

    // A new version's first launch points launchers, watchdog and helper at
    // this app's cdp. Off the main thread: rebuilding launchers takes seconds.
    func setUp() {
        guard let cdp = cdpPath else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do { try runTool("/bin/zsh", [cdp, "setup", "--if-needed"], env: ["CDP_FROM_CHOOSER": "1"]) }
            catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                if let failure { self.errorMessage = failure }
                self.refresh()
            }
        }
    }

    private func callCdp(_ args: [String]) {
        guard let cdp = cdpPath else {
            errorMessage = "Bundled cdp script is missing from the app. Rebuild with: cdp gui"
            return
        }
        do {
            // CDP_FROM_CHOOSER stops cdp from rebuilding the app bundle
            // that is currently running us.
            try runTool("/bin/zsh", [cdp] + args, env: ["CDP_FROM_CHOOSER": "1"])
        } catch { errorMessage = error.localizedDescription }
        refresh()
    }

    func revealData(_ p: Profile) {
        let dir = p.dataDir ?? (appSupport + "/Claude")
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir)
    }
}

// MARK: - App

// A menu bar app: no Dock icon (LSUIElement), and the window is only a
// utility surface for adding/removing profiles. Opening the app again (Spotlight,
// Finder) pops the menu bar panel instead of a window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { GlobalShortcut.togglePanel() }
        return flag
    }
}

@main
struct ClaudeProfilesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = ProfileStore()

    var body: some Scene {
        // Window (not WindowGroup): openWindow from the menu bar must reuse it.
        Window("Claude Profiles", id: "main") {
            ContentView(store: store)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: ProfileStore

    var body: some View {
        let top = store.usage.values.compactMap(\.fiveHour).max()
        if let img = menuBarImage(percent: top) {
            Image(nsImage: img)
        } else {
            Image(systemName: "gauge.with.needle")
        }
    }

    // Rendered to an image so it can be colored when a limit is close; plain
    // levels stay a template image that follows the menu bar's light/dark tint.
    @MainActor private func menuBarImage(percent: Double?) -> NSImage? {
        let warn: Color? = percent.map { $0 >= 90 ? Color.red : ($0 >= 75 ? Color.orange : nil) } ?? nil
        let name: String
        switch percent ?? 0 {
        case ..<17: name = "gauge.with.dots.needle.0percent"
        case ..<42: name = "gauge.with.dots.needle.33percent"
        case ..<59: name = "gauge.with.dots.needle.50percent"
        case ..<84: name = "gauge.with.dots.needle.67percent"
        default: name = "gauge.with.dots.needle.100percent"
        }
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : "gauge.with.needle"
        let view = HStack(spacing: 4) {
            Image(systemName: symbol)
            if let percent { Text("\(Int(percent.rounded()))%").monospacedDigit() }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(warn ?? Color.black)
        .padding(.horizontal, 2)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let img = renderer.nsImage else { return nil }
        img.isTemplate = (warn == nil)
        return img
    }
}

struct MenuContent: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.openWindow) private var openWindow

    // The profile with the most 5-hour headroom, when the gap is worth pointing out.
    private var mostFreeID: String? {
        let vals = store.profiles.compactMap { p -> (String, Double)? in
            guard let v = store.usage[p.id]?.fiveHour else { return nil }
            return (p.id, v)
        }
        guard vals.count >= 2, let lo = vals.min(by: { $0.1 < $1.1 }),
              let hi = vals.max(by: { $0.1 < $1.1 }), hi.1 - lo.1 >= 15 else { return nil }
        return lo.0
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 2) {
                ForEach(store.profiles) { p in
                    MenuProfileRow(
                        profile: p,
                        isRunning: store.running.contains(p.id),
                        usage: store.usage[p.id],
                        isMostFree: p.id == mostFreeID,
                        launch: { store.launch(p); closePanel() },
                        reveal: { store.revealData(p) },
                        setColor: p.isDefault ? nil : { store.setColor(p, color: $0) },
                        remove: p.isDefault ? nil : { store.removeRequest = p; showWindow() }
                    )
                }
            }
            .padding(.horizontal, 6)

            Divider().padding(.vertical, 8)

            VStack(spacing: 0) {
                MenuAction(title: "New Profile…", symbol: "plus.circle") {
                    store.showAdd = true
                    showWindow()
                }
                MenuAction(title: "Open Claude Profiles", symbol: "macwindow") { showWindow() }
                MenuAction(title: "Quit", symbol: "power") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .frame(width: 300)
        .onAppear { store.refreshUsageIfStale() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            store.refreshUsageIfStale()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Profiles").font(.headline)
                if let t = store.lastUsageUpdate {
                    Text("Updated \(Text(t, style: .relative)) ago")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Fetching usage…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { store.refresh(); store.refreshUsage() } label: {
                if store.isRefreshingUsage {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .frame(width: 20, height: 20)
            .help("Refresh usage")
            settingsMenu
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var settingsMenu: some View {
        Menu {
            Toggle("Usage alerts (80% and 95%)", isOn: $store.alertsEnabled)
            Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin },
                                                    set: { store.setLaunchAtLogin($0) }))
            Toggle("Shortcut ⌥⌘P opens this panel", isOn: $store.shortcutEnabled)
            Menu("Refresh usage every") {
                Picker("Refresh usage every", selection: $store.usageInterval) {
                    ForEach([60.0, 120, 300, 600, 900], id: \.self) { Text("\(Int($0 / 60)) min").tag($0) }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 20)
        .help("Settings")
    }

    private func closePanel() { NSApp.keyWindow?.orderOut(nil) }

    private func showWindow() {
        closePanel()
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}

struct MenuProfileRow: View {
    let profile: Profile
    let isRunning: Bool
    let usage: Usage?
    let isMostFree: Bool
    let launch: () -> Void
    let reveal: () -> Void
    let setColor: ((String) -> Void)?
    let remove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        Button(action: launch) {
            VStack(alignment: .leading, spacing: 7) {
                titleRow
                usageBody
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(isRunning ? "Focus" : "Launch") { launch() }
            Button("Reveal Data Folder in Finder") { reveal() }
            if let setColor {
                Menu("Change Color") {
                    ForEach(ProfileColor.all) { c in
                        Button(c.name.capitalized) { setColor(c.name) }
                    }
                }
            }
            if let remove {
                Divider()
                Button("Remove…", role: .destructive) { remove() }
            }
        }
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Circle().fill(profile.color.swatch).frame(width: 10, height: 10)
            Text(profile.name).font(.system(size: 13, weight: .semibold))
            if isMostFree {
                Text("Most free")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(profile.color.swatch)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(profile.color.swatch.opacity(0.18)))
            }
            Spacer()
            if hovering {
                HStack(spacing: 3) {
                    Text(isRunning ? "Focus" : "Launch")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if isRunning {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("Running")
                }
                .font(.caption)
                .foregroundStyle(Color.green)
            }
        }
    }

    @ViewBuilder private var usageBody: some View {
        if let usage {
            if usage.needsSignIn {
                note("Not signed in. Launch it and sign in to see usage.", symbol: "person.crop.circle.badge.exclamationmark")
            } else if let error = usage.error {
                note("Usage unavailable: \(error)", symbol: "exclamationmark.triangle")
            } else if usage.hasNoData {
                note("No usage data yet.", symbol: "chart.bar")
            } else {
                HStack(alignment: .top, spacing: 14) {
                    UsageBar(label: "5 hours", value: usage.fiveHour, reset: usage.fiveHourReset, tint: profile.color.swatch)
                    UsageBar(label: "Week", value: usage.sevenDay, reset: usage.sevenDayReset, tint: profile.color.swatch)
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading usage…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func note(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct UsageBar: View {
    let label: String
    let value: Double?
    let reset: Date?
    let tint: Color

    private var fraction: Double { min(max((value ?? 0) / 100, 0), 1) }
    private var barColor: Color {
        guard let value else { return .secondary }
        if value >= 90 { return .red }
        if value >= 75 { return .orange }
        return tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(value.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.caption.monospacedDigit().weight(.medium))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(barColor).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 5)
            if let text = resetText(reset) {
                Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct MenuAction: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Views

struct ContentView: View {
    @ObservedObject var store: ProfileStore
    @State private var removing: Profile?
    @State private var confirmWipe: Profile?
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 14)]

    // SwiftUI opens the window at launch; a menu bar app shouldn't. Only the
    // first appearance is swallowed, and only if nothing asked for the window.
    private static var launchHandled = false
    private func hideLaunchWindow() {
        guard !Self.launchHandled else { return }
        Self.launchHandled = true
        guard !store.showAdd, store.removeRequest == nil else { return }
        DispatchQueue.main.async {
            NSApp.windows.first { $0.title == "Claude Profiles" }?.close()
        }
    }

    private func takeRemoveRequest() {
        if let p = store.removeRequest {
            removing = p
            store.removeRequest = nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            UpdateBar(installedVersion: store.installedVersion, outdated: store.outdatedProfiles)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(store.profiles) { p in
                        ProfileCard(
                            profile: p,
                            isRunning: store.running.contains(p.id),
                            launch: { store.launch(p) },
                            reveal: { store.revealData(p) },
                            setColor: p.isDefault ? nil : { store.setColor(p, color: $0) },
                            remove: p.isDefault ? nil : { removing = p }
                        )
                    }
                    AddCard { store.showAdd = true }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 580, idealWidth: 640, minHeight: 380, idealHeight: 420)
        .background(WindowBackground())
        .onAppear {
            store.setUp()
            takeRemoveRequest()
            hideLaunchWindow()
        }
        .onReceive(store.$removeRequest) { _ in takeRemoveRequest() }
        .sheet(isPresented: $store.showAdd) {
            AddSheet { name, color in store.add(name, color: color) }
        }
        .confirmationDialog(
            "Remove “\(removing?.name ?? "")”?",
            isPresented: Binding(get: { removing != nil },
                                 set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { p in
            Button("Remove Launcher Only") { store.remove(p, deleteData: false) }
            Button("Delete Everything…", role: .destructive) { confirmWipe = p }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("“Launcher Only” deletes the Spotlight app but keeps chats, login, and settings on disk — the profile stays in this window and can be fully removed later.")
        }
        .alert(
            "Delete all data for “\(confirmWipe?.name ?? "")”?",
            isPresented: Binding(get: { confirmWipe != nil },
                                 set: { if !$0 { confirmWipe = nil } }),
            presenting: confirmWipe
        ) { p in
            Button("Delete", role: .destructive) { store.remove(p, deleteData: true) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Chats, login, and settings will be permanently erased. This cannot be undone.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { store.errorMessage != nil },
                                 set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Profiles").font(.title2.bold())
                Text("Isolated Claude Desktop accounts, side by side")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.showAdd = true
            } label: {
                Label("New Profile", systemImage: "plus")
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// Profiles self-update on their own, so there's no update chore to nag about.
// The only thing worth surfacing is a purely informational note: a profile
// whose clone is behind the installed default will catch up on its next
// launch. Shown only when such a profile exists; otherwise the bar collapses
// to nothing. A clone that self-updated AHEAD of the default is never listed.
struct UpdateBar: View {
    let installedVersion: String
    let outdated: [String]

    var body: some View {
        if outdated.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                    Text(driftText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                Divider()
            }
        }
    }

    private var driftText: String {
        let names = outdated.joined(separator: ", ")
        let ver = installedVersion.isEmpty ? "" : " \(installedVersion)"
        let many = outdated.count > 1
        return "\(names) \(many ? "are" : "is") behind your default Claude\(ver) — \(many ? "they'll" : "it'll") update on \(many ? "their" : "its") next launch."
    }
}

struct WindowBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(nsColor: .windowBackgroundColor),
                     Color(nsColor: .underPageBackgroundColor)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

struct ProfileCard: View {
    let profile: Profile
    let isRunning: Bool
    let launch: () -> Void
    let reveal: () -> Void
    let setColor: ((String) -> Void)?
    let remove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: claudeIcon)
                .resizable()
                .frame(width: 54, height: 54)
                .hueRotation(.degrees(profile.color.hue))
                .shadow(color: .black.opacity(hovering ? 0.25 : 0.1),
                        radius: hovering ? 7 : 3, y: 2)
            Text(profile.name)
                .font(.headline)
                .lineLimit(1)
            Text(profile.isDefault ? "your main install" : "isolated profile")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Circle()
                    .fill(isRunning ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                Text(isRunning ? "Running" : "Stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isRunning {
                Button(action: launch) {
                    Text("Focus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button(action: launch) {
                    Text("Launch").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(profile.color.swatch)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(hovering ? 1.0 : 0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            // Discoverable stand-in for the right-click context menu.
            Menu {
                cardActions
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(7)
            .opacity(hovering ? 1.0 : 0.4)
        }
        .scaleEffect(hovering ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            cardActions
        }
    }

    // Shared between the right-click context menu and the ellipsis button.
    @ViewBuilder
    private var cardActions: some View {
        Button("Launch") { launch() }
        Button("Reveal Data Folder in Finder") { reveal() }
        if let setColor {
            Menu("Change Color") {
                ForEach(ProfileColor.all) { c in
                    Button {
                        setColor(c.name)
                    } label: {
                        if c.name == profile.colorName {
                            Label(c.name.capitalized, systemImage: "checkmark")
                        } else {
                            Text(c.name.capitalized)
                        }
                    }
                }
            }
        }
        if let remove {
            Divider()
            Button("Remove…", role: .destructive) { remove() }
        }
    }
}

struct AddCard: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
                Text("New profile")
                    .font(.headline)
                    .foregroundStyle(hovering ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(hovering ? 0.65 : 0.25))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(nsColor: .separatorColor),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

struct AddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colorName = "orange"
    let create: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New profile").font(.title3.bold())
            TextField("personal, client-acme…", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack(spacing: 10) {
                Image(nsImage: claudeIcon)
                    .resizable()
                    .frame(width: 30, height: 30)
                    .hueRotation(.degrees(ProfileColor.named(colorName).hue))
                ForEach(ProfileColor.all) { c in
                    Circle()
                        .fill(c.swatch)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().strokeBorder(.primary.opacity(c.name == colorName ? 0.8 : 0),
                                                  lineWidth: 2)
                        )
                        .onTapGesture { colorName = c.name }
                        .help(c.name.capitalized)
                }
            }
            Text("Creates a fully isolated Claude — its own login, chats, and settings — plus a Spotlight launcher (“Claude <Name>”).\n\nBefore its first sign-in, quit every other Claude window: the login link lands on whichever instance is running.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func submit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        create(n, colorName)
        dismiss()
    }
}
