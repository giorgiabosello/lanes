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
    var id: String { version }
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
            }))
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
            w.contentView = NSHostingView(rootView: WhatsNewView(entries: Changelog.entries))
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
    var current: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

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
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(e.version)
                    .font(.system(size: 13, weight: .semibold).monospaced())
                if isCurrent {
                    Text("Installed")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.green.opacity(0.15)))
                }
                if let d = e.date {
                    Text(Self.dateFormat.string(from: d))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(e.title)
                .font(.system(size: 17, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
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
