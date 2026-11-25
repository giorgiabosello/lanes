// Settings: what used to be the panel's gear menu, as a proper window.

import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var store: ProfileStore

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        Form {
            Section {
                Picker("Check usage every", selection: $store.usageInterval) {
                    ForEach([60.0, 120, 300, 600, 900], id: \.self) { s in
                        Text("\(Int(s / 60)) min").tag(s)
                    }
                }
                Toggle(isOn: $store.alertsEnabled) {
                    described("Usage alerts",
                              "At 80% and 95% of the 5-hour limit, and the minute a nearly used limit resets.")
                }
            } header: {
                Text("Usage")
            }

            Section {
                Toggle(isOn: $store.shortcutEnabled) {
                    shortcut("Show the menu bar panel", "⌥⌘P")
                }
                Toggle(isOn: $store.bestShortcutEnabled) {
                    shortcut("Open the profile with the most room", "⌥⌘B")
                }
            } header: {
                Text("Shortcuts")
            }

            Section {
                Toggle(isOn: $store.routeLinks) {
                    described("Send claude:// links to the right profile",
                              "Sign-in and “open in app” links go to the profile they belong to. Off, macOS hands them to whichever Claude is running.")
                }
                Toggle(isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) })) {
                    described("Open Lanes at login", "Keeps usage, alerts and link routing running.")
                }
            } header: {
                Text("General")
            } footer: {
                HStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 16, height: 16)
                    Text("Lanes \(version) · No telemetry. Usage is read from claude.ai with each profile's own session.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func described(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
            KeyCap(keys: keys)
        }
    }
}
