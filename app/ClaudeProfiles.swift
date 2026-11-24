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
    var error: String?
    var summary: String {
        if let error { return error }
        func pct(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "—" }
        return "5h \(pct(fiveHour)) · 7d \(pct(sevenDay))"
    }
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
    guard let orgs = try await get("/organizations") as? [[String: Any]],
          let org = orgs.first?["uuid"] as? String
    else { throw usageError("no organization") }
    guard let j = try await get("/organizations/\(org)/usage") as? [String: Any]
    else { throw usageError("unexpected response") }
    func pct(_ k: String) -> Double? { (j[k] as? [String: Any])?["utilization"] as? Double }
    return Usage(fiveHour: pct("five_hour"), sevenDay: pct("seven_day"), error: nil)
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

    // Owned by the store (not a view) so the menu bar stays live with the window closed.
    private var timers: [Timer] = []
    init() {
        refresh()
        timers = [
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshRunning() },
            Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refreshUsage() },
        ]
        refreshUsage()
    }

    func refreshUsage() {
        let targets = profiles.map { ($0.id, $0.dataDir ?? appSupport + "/Claude") }
        Task.detached {
            for (id, dir) in targets {
                let u: Usage
                do { u = try await fetchUsage(dataDir: dir) }
                catch { u = Usage(fiveHour: nil, sevenDay: nil, error: error.localizedDescription) }
                await MainActor.run { self.usage[id] = u }
            }
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

@main
struct ClaudeProfilesApp: App {
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
            let top = store.usage.values.compactMap(\.fiveHour).max()
            Image(systemName: "gauge.with.needle")
            if let top { Text("\(Int(top.rounded()))%") }
        }
    }
}

struct MenuContent: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(store.profiles) { p in
            let running = store.running.contains(p.id)
            // launch() focuses an already-running instance instead of opening another.
            Button("\(running ? "●" : "○") \(p.name)   \(store.usage[p.id]?.summary ?? "…")") { store.launch(p) }
        }
        Divider()
        Button("New Profile…") {
            store.showAdd = true
            showWindow()
        }
        Button("Open Claude Profiles") { showWindow() }
        Button("Refresh Usage") { store.refresh(); store.refreshUsage() }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }

    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}

// MARK: - Views

struct ContentView: View {
    @ObservedObject var store: ProfileStore
    @State private var removing: Profile?
    @State private var confirmWipe: Profile?
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 14)]

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
        .onAppear { store.setUp() }
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
