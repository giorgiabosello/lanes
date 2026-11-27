// ProfileStore: Lanes' own updates (checking GitHub, installing, relaunching)
// and the one-time "updated to" announcement.

import AppKit

extension ProfileStore {
    static let whatsNewSinceKey = "whatsNewSince"

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // After an update (this version is newer than the last one that ran),
    // announce it once: a notification that opens What's New, and a strip in
    // the panel. A first install or a downgrade only records the version.
    func noteVersionChange() {
        let key = "lastRunVersion", d = UserDefaults.standard
        // 0.9.0 and earlier didn't record it; usage history means Lanes has
        // run here before, so this launch is an update, not a first install.
        let last = d.string(forKey: key)
            ?? (FileManager.default.fileExists(atPath: UsageHistory.path) ? "0.0.0" : nil)
        d.set(appVersion, forKey: key)
        guard let last, versionLessThan(last, appVersion), let entry = Changelog.entry(appVersion) else { return }
        // What's New marks every release after this one as new.
        if last != "0.0.0" { d.set(last, forKey: Self.whatsNewSinceKey) }
        updatedTo = appVersion
        Notifier.shared.setUp()
        Notifier.shared.post(title: "Lanes updated to \(appVersion)",
                             body: "\(entry.title). Click to see what's new.",
                             identifier: Notifier.whatsNewID)
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
                // Still running, yet the bundle holds another version: the
                // swap happened but this process was never quit. Restart.
                if proc.terminationStatus == 0, let onDisk = bundleVersion(Bundle.main.bundlePath),
                   onDisk != self.appVersion {
                    self.relaunch()
                    return
                }
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

    // Quits and reopens this app from its bundle path: a detached shell
    // waits for this process to exit, then opens the (new) bundle.
    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                       Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { updateError = error.localizedDescription; return }
        NSApp.terminate(nil)
    }
}
