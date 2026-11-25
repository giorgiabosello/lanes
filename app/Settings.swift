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
                              "When the 5-hour or weekly limit passes each level below, and the minute a limit past the first level resets.")
                }
                Group {
                    Picker("First alert at", selection: $store.alertWarn) {
                        ForEach(ProfileStore.warnLevels, id: \.self) { Text("\(Int($0))%").tag($0) }
                    }
                    Picker("Second alert at", selection: $store.alertUrgent) {
                        ForEach(ProfileStore.urgentLevels.filter { $0 > store.alertWarn }, id: \.self) {
                            Text("\(Int($0))%").tag($0)
                        }
                    }
                    Toggle(isOn: $store.paceAlertsEnabled) {
                        described("Warn when on pace to run out",
                                  "When, at its recent rate, a limit will be used up well before it resets: within 45 minutes for the 5-hour limit, within a day for the weekly one.")
                    }
                }
                .disabled(!store.alertsEnabled)
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
            }

            Section {
                Toggle(isOn: $store.autoUpdate) {
                    described("Install updates automatically",
                              "Lanes checks GitHub for a new version every few hours, installs it and reopens. Off, it only tells you in the menu bar panel.")
                }
                HStack {
                    updateStatus
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let v = store.availableUpdate, !store.isUpdating {
                        Button("Install \(v)") { store.installUpdate() }
                    } else {
                        Button("Check Now") { store.checkForUpdate() }
                            .disabled(store.isCheckingForUpdate || store.isUpdating)
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                HStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 16, height: 16)
                    Text("Lanes \(version) · No telemetry. Usage is read from claude.ai with each profile's own session; update checks only ask GitHub for the latest version.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .tint(Brand.coral)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var updateStatus: some View {
        if store.isUpdating {
            Text("Installing the update…")
        } else if let error = store.updateError {
            Text(error).foregroundStyle(.red)
        } else if store.isCheckingForUpdate {
            Text("Checking…")
        } else if let v = store.availableUpdate {
            Text("Lanes \(v) is available.")
        } else if let date = store.lastUpdateCheck {
            Text("Up to date · checked \(date.formatted(date: .omitted, time: .shortened))")
        } else {
            Text("Lanes \(version)")
        }
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
