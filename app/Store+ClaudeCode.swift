// ProfileStore: Claude Code's status line in each profile (`lanes statusline`).
// The script does the reading and writing of settings.json; the app shows
// where it's on, and turns it on or off after asking.

import AppKit

struct StatusLineState: Identifiable, Equatable {
    enum State: String { case on, off, other, invalid, failed }
    let profile: String
    let state: State
    let file: String
    var id: String { profile }

    // `lanes statusline --tsv`: profile, state, settings file. "added" and
    // "removed" are what `on` and `off` just did, so they read as on and off.
    static func parse(tsv: String) -> [StatusLineState] {
        tsv.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3 else { return nil }
            let raw = f[1] == "added" ? "on" : f[1] == "removed" ? "off" : f[1]
            guard let s = State(rawValue: raw) else { return nil }
            return StatusLineState(profile: f[0], state: s, file: f[2])
        }
    }
}

extension ProfileStore {
    var statusLineOn: [StatusLineState] { statusLine.filter { $0.state == .on } }
    var statusLineOff: [StatusLineState] { statusLine.filter { $0.state == .off } }

    // One line for Settings and What's New.
    var statusLineSummary: String {
        if statusLine.isEmpty { return "No profile uses Claude Code yet." }
        let on = statusLineOn.count, all = statusLine.count
        var s = on == 0 ? "Off" : on == all ? "On for every profile" : "On for \(on) of \(all) profiles"
        let own = statusLine.filter { $0.state == .other }.map(\.profile)
        if !own.isEmpty { s += ". " + Self.joined(own) + (own.count == 1 ? " has its own" : " have their own") }
        let bad = statusLine.filter { $0.state == .invalid }.map(\.profile)
        if !bad.isEmpty { s += ". Can't read the settings of " + Self.joined(bad) }
        return s + "."
    }

    // "Work", "Work and Studio", "Work, Studio and Acme": the app is in English.
    static func joined(_ names: [String]) -> String {
        names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    func checkStatusLine() {
        runStatusLine(["--tsv"])
    }

    // Asks first, naming the profiles whose settings.json changes.
    func confirmStatusLine(on: Bool) {
        let targets = on ? statusLineOff : statusLineOn
        guard !targets.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = on ? "Add usage to Claude Code's status line?" : "Remove Lanes' status line?"
        let names = Self.joined(targets.map(\.profile))
        alert.informativeText = on
            ? "Lanes adds a statusLine setting to the Claude Code settings of \(names). Nothing else in those files changes, and a copy of each is kept beside it."
            : "Lanes removes its statusLine setting from the Claude Code settings of \(names)."
        alert.addButton(withTitle: on ? "Add" : "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runStatusLine([on ? "on" : "off", "--tsv"] + targets.map(\.profile))
    }

    private func runStatusLine(_ args: [String]) {
        guard live, let lanes = scriptPath else { return }
        isUpdatingStatusLine = true
        DispatchQueue.global(qos: .userInitiated).async {
            // With --tsv the script always exits 0; a file it couldn't
            // write comes back as a "failed" row.
            let out = (try? runTool("/bin/zsh", [lanes, "statusline"] + args, env: ["LANES_FROM_CHOOSER": "1"])) ?? ""
            DispatchQueue.main.async {
                self.isUpdatingStatusLine = false
                let rows = StatusLineState.parse(tsv: out)
                if args.first == "--tsv" {
                    self.statusLine = rows
                } else {
                    // Only the named profiles came back: merge them in.
                    var all = self.statusLine
                    for r in rows {
                        if let i = all.firstIndex(where: { $0.profile == r.profile }) { all[i] = r } else { all.append(r) }
                    }
                    self.statusLine = all
                    if rows.contains(where: { $0.state == .failed }) {
                        self.errorMessage = "Lanes couldn't write some Claude Code settings. Run lanes statusline in the Terminal to see which."
                    }
                }
            }
        }
    }

    // Opens Settings on a tab, from places that can't call openWindow (the
    // What's New window is plain AppKit): MenuBarLabel, always alive, does.
    func openSettings(_ tab: SettingsView.Tab) {
        UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab")
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("settings") == true }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            settingsRequest += 1
        }
    }
}
