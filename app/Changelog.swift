// What's New: CHANGELOG.md, bundled into Resources at build time, parsed
// and shown in its own window. The same file makes the GitHub release notes
// and the website's changelog (scripts/changelog.py, which documents the
// format). The window opens from Settings, from the panel after an update,
// and from the "Lanes updated" notification.

import SwiftUI
import AppKit

struct ChangelogEntry: Identifiable {
    enum Block { case paragraph(AttributedString), bullet(AttributedString) }
    let version: String
    let title: String
    let date: Date?
    let blocks: [Block]
    var actions: [TryAction] = []
    var id: String { version }
}

// What a release lets you try from What's New, declared in CHANGELOG.md as
// `<!-- try: copy lanes claude --best | statusline | test-alert | settings status -->`
// under its heading. An HTML comment, so the GitHub notes and the website
// never show it. Unknown actions are skipped, so older builds ignore new ones.
enum TryAction: Hashable {
    case copy(String)                    // a command, with a Copy button
    case statusLine                      // turn on Claude Code's status line
    case testAlert                       // Settings > Alerts' test alert
    case settings(SettingsView.Tab)      // open Settings on a tab

    static func parse(_ list: String) -> [TryAction] {
        list.split(separator: "|").compactMap { part in
            let words = part.trimmingCharacters(in: .whitespaces)
            let (name, arg) = words.firstIndex(of: " ").map {
                (String(words[..<$0]), words[$0...].trimmingCharacters(in: .whitespaces))
            } ?? (words, "")
            switch name {
            case "copy": return arg.isEmpty ? nil : .copy(arg)
            case "statusline": return .statusLine
            case "test-alert": return .testAlert
            case "settings": return SettingsView.Tab(rawValue: arg).map { .settings($0) }
            default: return nil
            }
        }
    }
}

enum Changelog {
    static let siteURL = URL(string: "https://lanes.pego.tech/changelog.html")!

    static let entries: [ChangelogEntry] = {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }()

    static func entry(_ version: String) -> ChangelogEntry? { entries.first { $0.version == version } }

    // "## 0.9.0 — Title", then "_2026-11-25_", then paragraphs and "- "
    // bullets; a line that isn't blank continues the block above it.
    static func parse(_ text: String) -> [ChangelogEntry] {
        // Try-it actions live in comments, so read them before those go.
        var actions: [String: [TryAction]] = [:]
        var current: String?
        for raw in text.components(separatedBy: .newlines) {
            if raw.hasPrefix("## "), let dash = raw.range(of: " — ") {
                current = String(raw[raw.index(raw.startIndex, offsetBy: 3)..<dash.lowerBound])
            } else if let v = current, raw.hasPrefix("<!-- try:"), let end = raw.range(of: "-->") {
                let list = raw[raw.index(raw.startIndex, offsetBy: 9)..<end.lowerBound]
                actions[v, default: []] += TryAction.parse(String(list))
            }
        }
        var src = text
        while let open = src.range(of: "<!--"), let close = src.range(of: "-->", range: open.upperBound..<src.endIndex) {
            src.removeSubrange(open.lowerBound..<close.upperBound)
        }
        let dateFormat = DateFormatter()
        dateFormat.locale = Locale(identifier: "en_US_POSIX")
        dateFormat.dateFormat = "yyyy-MM-dd"

        var out: [ChangelogEntry] = []
        var version: String?, title = "", date: Date?
        var blocks: [(bullet: Bool, text: String)] = []
        var open = false   // the last block can still take a wrapped line

        func flush() {
            guard let v = version else { return }
            out.append(ChangelogEntry(version: v, title: title, date: date, blocks: blocks.map {
                let s = inline($0.text)
                return $0.bullet ? .bullet(s) : .paragraph(s)
            }, actions: actions[v] ?? []))
        }

        for raw in src.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("## "), let dash = raw.range(of: " — ") {
                flush()
                version = String(raw[raw.index(raw.startIndex, offsetBy: 3)..<dash.lowerBound])
                title = String(raw[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
                date = nil; blocks = []; open = false
                continue
            }
            guard version != nil else { continue }
            if line.isEmpty {
                open = false
            } else if blocks.isEmpty, date == nil, line.hasPrefix("_"), line.hasSuffix("_"),
                      let d = dateFormat.date(from: String(line.dropFirst().dropLast())) {
                date = d
            } else if raw.hasPrefix("- ") {
                blocks.append((true, String(raw.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                open = true
            } else if open, !blocks.isEmpty {
                blocks[blocks.count - 1].text += " " + line
            } else {
                blocks.append((false, line))
                open = true
            }
        }
        flush()
        return out
    }

    private static func inline(_ md: String) -> AttributedString {
        (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(md)
    }
}

// MARK: - Window

// An AppKit window rather than a SwiftUI scene, so a notification click or
// the panel can open it without a view's openWindow.
enum WhatsNewWindow {
    private static var window: NSWindow?

    static func show() {
        ProfileStore.shared.updatedTo = nil
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "What's New in Lanes"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 440, height: 360)
            w.contentView = NSHostingView(rootView: WhatsNewView(entries: Changelog.entries, store: .shared))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - View

struct WhatsNewView: View {
    let entries: [ChangelogEntry]
    @ObservedObject var store: ProfileStore
    var current: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    // The version Lanes was on before the last update: newer releases are new
    // to this user. Unset after a fresh install, when only this one is.
    var since: String? = UserDefaults.standard.string(forKey: ProfileStore.whatsNewSinceKey)
    @State private var copied: String?

    private func isNew(_ e: ChangelogEntry) -> Bool {
        guard !versionLessThan(current, e.version) else { return false }
        if let since { return versionLessThan(since, e.version) }
        return e.version == current
    }

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMMM yyyy"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if entries.isEmpty {
                Text("This build doesn't include the changelog.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                            release(e)
                            if i < entries.count - 1 { LaneMarking().padding(.vertical, 22) }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                }
            }
            footer
        }
        .frame(minWidth: 440, minHeight: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if entries.contains(where: { $0.actions.contains(.statusLine) }) { store.checkStatusLine() } }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("What's New")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(current.isEmpty ? "Lanes" : "You're on Lanes \(current)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 16)
    }

    private func release(_ e: ChangelogEntry) -> some View {
        let isCurrent = e.version == current
        let new = isNew(e)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(e.version)
                    .font(.system(size: 13, weight: .semibold).monospaced())
                if isCurrent { pill("Installed", .green) }
                if new { pill("New", Brand.coral) }
                if let d = e.date {
                    Text(Self.dateFormat.string(from: d))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(e.title)
                .font(.system(size: 17, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            // First, so it's seen without scrolling through the notes.
            if !e.actions.isEmpty, !versionLessThan(current, e.version) { tryCard(e.actions) }
            ForEach(Array(e.blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .paragraph(let s):
                    Text(s).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Brand.azure).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                        Text(s).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.callout)
            .textSelection(.enabled)
        }
        .opacity(new || since == nil || isCurrent ? 1 : 0.72)
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    // MARK: Try it

    private func tryCard(_ actions: [TryAction]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Try it", systemImage: "sparkles")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Brand.azure)
            ForEach(actions, id: \.self) { a in
                switch a {
                case .copy(let command): copyRow(command)
                case .statusLine: statusLineRow
                case .testAlert:
                    actionRow("See what an alert looks like, with its buttons.", "Send Test Alert") {
                        store.sendTestAlert()
                    }
                case .settings(let tab):
                    actionRow(settingsBlurb(tab), "Open \(tab.title)") { store.openSettings(tab) }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.azure.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.azure.opacity(0.22)))
        .padding(.vertical, 4)
    }

    private func copyRow(_ command: String) -> some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(size: 12).monospaced())
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
            Spacer()
            Button(copied == command ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = command
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if copied == command { copied = nil } }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private var statusLineRow: some View {
        let off = store.statusLineOff
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage in Claude Code's status line")
                Text(store.statusLineSummary).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if store.isUpdatingStatusLine {
                ProgressView().controlSize(.small)
            } else if !off.isEmpty {
                Button(store.statusLineOn.isEmpty ? "Set Up" : "Add to the Rest") { store.confirmStatusLine(on: true) }
                    .controlSize(.small)
            } else if !store.statusLineOn.isEmpty {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    private func actionRow(_ text: String, _ button: String, _ action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(button, action: action).controlSize(.small)
        }
    }

    private func settingsBlurb(_ tab: SettingsView.Tab) -> String {
        switch tab {
        case .status: "See what Lanes depends on, and fix what's off."
        case .alerts: "Pick the levels your alerts fire at."
        case .shortcuts: "Keyboard shortcuts that work from any app."
        case .updates: "How Lanes keeps itself up to date."
        case .general: "Login, usage checks and link routing."
        }
    }

    private var footer: some View {
        HStack {
            Link("Changelog on the website", destination: Changelog.siteURL)
            Spacer()
            Link("All releases", destination: URL(string: "https://github.com/pego/lanes/releases")!)
        }
        .font(.caption)
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.035))
        .overlay(alignment: .top) { Divider() }
    }
}
