// ProfileStore: threshold, pace and reset notifications, and the buttons
// on them: open the profile with the most room, mute a limit until it
// resets, get a heads-up when it does.

import AppKit
import UserNotifications

// What a notification's buttons do, and the categories that carry them.
enum AlertAction {
    static let openBest = "open-best"     // launch userInfo["best"]
    static let open = "open"              // launch userInfo["profile"]
    static let mute = "mute"              // no more warnings for this limit until it resets
    static let remind = "remind"          // a notification when this limit resets

    enum Kind: String { case threshold, pace, reset }

    // "threshold|Personal": a threshold alert offering to open Personal.
    // Reset notifications name the profile that reset; alerts name the
    // alternative, or nothing when there isn't one.
    static func category(_ kind: Kind, _ profile: String?) -> String {
        kind.rawValue + "|" + (profile ?? "")
    }

    // Every category the given profiles can need.
    static func categories(for names: [String]) -> Set<UNNotificationCategory> {
        func button(_ id: String, _ title: String) -> UNNotificationAction {
            UNNotificationAction(identifier: id, title: title, options: [])
        }
        let mute = button(Self.mute, "Mute Until Reset")
        let remind = button(Self.remind, "Notify Me at Reset")
        var out = Set<UNNotificationCategory>()
        for best in [nil] + names.map(Optional.some) {
            let open = best.map { [button(openBest, "Open \($0)")] } ?? []
            out.insert(UNNotificationCategory(identifier: category(.threshold, best), actions: open + [mute],
                                              intentIdentifiers: []))
            out.insert(UNNotificationCategory(identifier: category(.pace, best), actions: open + [remind, mute],
                                              intentIdentifiers: []))
        }
        for name in names {
            out.insert(UNNotificationCategory(identifier: category(.reset, name), actions: [button(Self.open, "Open \(name)")],
                                              intentIdentifiers: []))
        }
        return out
    }
}

extension ProfileStore {
    private func limits(_ u: Usage) -> [(key: String, label: String, value: Double?, reset: Date?, pace: Pace?)] {
        [("5h", "5-hour limit", u.fiveHour, u.fiveHourReset, u.fiveHourPace),
         ("7d", "weekly limit", u.sevenDay, u.sevenDayReset, u.sevenDayPace)]
    }

    // Another profile that's a better bet: the one with the most room, if
    // it has at least half its 5-hour limit left.
    func alternative(to id: String) -> Profile? {
        guard let b = bestProfile(), b.id != id, let h = usage[b.id]?.fiveHour, h < 50 else { return nil }
        return b
    }

    // " Most room: Personal (88% left)."
    private func alternativeText(_ b: Profile?) -> String {
        guard let b, let h = usage[b.id]?.fiveHour else { return "" }
        return " Most room: \(b.name) (\(max(0, 100 - Int(h.rounded())))% left)."
    }

    private func info(_ id: String, _ limit: String, reset: Date?, best: Profile?) -> [String: Any] {
        var i: [String: Any] = ["profile": id, "limit": limit]
        if let reset { i["reset"] = reset.timeIntervalSince1970 }
        if let best { i["best"] = best.name }
        return i
    }

    func registerAlertCategories() {
        guard live else { return }
        Notifier.shared.registerCategories(AlertAction.categories(for: profiles.map(\.name)))
    }

    // MARK: Muting and reminders

    // Muted until that limit's reset ("Work/5h" → epoch).
    func isMuted(_ key: String, now: Date = Date()) -> Bool {
        (alertMutedUntil[key] ?? 0) > now.timeIntervalSince1970
    }

    // A notification's click or button. A plain click opens the menu bar panel.
    func handleNotification(action: String, info: [AnyHashable: Any]) {
        let id = info["profile"] as? String
        let limit = info["limit"] as? String
        let reset = (info["reset"] as? Double).map { Date(timeIntervalSince1970: $0) }
        switch action {
        case AlertAction.openBest:
            if let name = info["best"] as? String, let p = profiles.first(where: { $0.name == name }) { launch(p) }
        case AlertAction.open:
            if let id, let p = profiles.first(where: { $0.id == id }) { launch(p) }
        case AlertAction.mute:
            guard let id, let limit else { return }
            mute("\(id)/\(limit)", until: reset, window: limit == "7d" ? LimitWindow.week : LimitWindow.fiveHour)
        case AlertAction.remind:
            guard let id, let limit, let reset, reset > Date() else { return }
            remindAtReset["\(id)/\(limit)"] = reset.timeIntervalSince1970
            if let u = usage[id] { scheduleResetAlerts(u, for: id) }
        case UNNotificationDefaultActionIdentifier:
            if live { GlobalShortcut.togglePanel() }
        default:
            break
        }
    }

    // Until the limit resets; without a known reset, for one whole window.
    func mute(_ key: String, until reset: Date?, window: TimeInterval, now: Date = Date()) {
        let until = reset.flatMap { $0 > now ? $0 : nil } ?? now.addingTimeInterval(window)
        alertMutedUntil[key] = until.timeIntervalSince1970
        pruneAlertState(now: now)
    }

    private func pruneAlertState(now: Date) {
        let t = now.timeIntervalSince1970
        if alertMutedUntil.values.contains(where: { $0 <= t }) { alertMutedUntil = alertMutedUntil.filter { $0.value > t } }
        if remindAtReset.values.contains(where: { $0 <= t - 3600 }) { remindAtReset = remindAtReset.filter { $0.value > t - 3600 } }
    }

    // MARK: The alerts

    // An alert when a limit crosses the first or second level, for the
    // 5-hour and the weekly limit alike.
    func thresholdAlerts(_ u: Usage, for id: String) {
        for l in limits(u) {
            guard let v = l.value else { continue }
            let level = v >= alertUrgent ? 2 : (v >= alertWarn ? 1 : 0)
            let key = "\(id)/\(l.key)"
            // First sample after launch only records the level, so restarting the
            // app at 85% doesn't fire a stale alert.
            guard let prev = alertLevel[key] else { alertLevel[key] = level; continue }
            alertLevel[key] = level
            guard level > prev, alertsEnabled, !isMuted(key) else { continue }
            let best = alternative(to: id)
            var body = "\(Int(v.rounded()))% of the \(l.label) used."
            if let r = resetText(l.reset) { body += " Limit \(r)." }
            body += alternativeText(best)
            Notifier.shared.post(title: "\(id): \(level == 2 ? "almost at" : "getting close to") the \(l.label)",
                                 body: body,
                                 category: AlertAction.category(.threshold, best?.name),
                                 info: info(id, l.key, reset: l.reset, best: best))
        }
    }

    // A heads-up when a limit, at its recent rate, will be used up well
    // before it resets: within 45 minutes for the 5-hour limit (with at least
    // 15 to spare), within a day for the weekly one (with at least 6 hours to
    // spare). Once per window.
    func paceAlerts(_ u: Usage, for id: String) {
        guard alertsEnabled, paceAlertsEnabled else { return }
        let now = Date()
        for l in limits(u) {
            guard let v = l.value, v < alertUrgent, let reset = l.reset, let out = l.pace?.runsOutAt else { continue }
            let weekly = l.key == "7d"
            let soon: TimeInterval = weekly ? 86400 : 45 * 60
            let spare: TimeInterval = weekly ? 6 * 3600 : 15 * 60
            guard out.timeIntervalSince(now) <= soon, reset.timeIntervalSince(out) >= spare else { continue }
            let key = "\(id)/\(l.key)"
            guard !isMuted(key, now: now) else { continue }
            // The same window, even if claude.ai nudged its reset time a little.
            if let sent = paceAlerted[key], abs(sent - reset.timeIntervalSince1970) < 3600 { continue }
            paceAlerted[key] = reset.timeIntervalSince1970
            let early = Int(reset.timeIntervalSince(out))
            let gap = early >= 86400 ? "\(early / 86400) day\(early >= 2 * 86400 ? "s" : "")"
                : early >= 3600 ? "\(early / 3600)h \(early % 3600 / 60)m" : "\(early / 60) min"
            let best = alternative(to: id)
            Notifier.shared.post(
                title: "\(id) is on pace to run out",
                body: "At this rate, the \(l.label) is used up around \(clockText(out)), \(gap) before it resets."
                    + alternativeText(best),
                category: AlertAction.category(.pace, best?.name),
                info: info(id, l.key, reset: reset, best: best))
        }
        // Forget windows that have long reset.
        let cutoff = now.timeIntervalSince1970 - 86400
        if paceAlerted.values.contains(where: { $0 < cutoff }) { paceAlerted = paceAlerted.filter { $0.value >= cutoff } }
        pruneAlertState(now: now)
    }

    // From Settings: a sample threshold alert for the busiest profile, with
    // the real buttons, to check that alerts get through and how they look.
    // Its Mute button is a no-op (no limit behind it).
    func sendTestAlert() {
        Notifier.shared.setUp()
        let busiest = profiles.max { (usage[$0.id]?.fiveHour ?? -1) < (usage[$1.id]?.fiveHour ?? -1) }
        let id = busiest?.id ?? "Default"
        let best = alternative(to: id) ?? profiles.first { $0.id != id }
        Notifier.shared.post(title: "Test: \(id) is getting close to the 5-hour limit",
                             body: "This is what a Lanes alert looks like." + alternativeText(best),
                             category: AlertAction.category(.threshold, best?.name),
                             info: info("", "5h", reset: nil, best: best))
    }

    // Every profile that should report usage fails in a way that points at
    // claude.ai having changed its usage endpoint, not at a network blip.
    var usageLooksBroken: Bool {
        let us = profiles.compactMap { usage[$0.id] }.filter { !$0.needsSignIn && !$0.hasNoData }
        return !us.isEmpty && us.allSatisfy { ($0.error != nil || $0.staleError != nil) && $0.formatChanged }
    }

    // Whether a limit gets a notification when it resets: when it's past the
    // first alert level, or someone asked for one ("Notify Me at Reset") for
    // this window.
    func wantsResetAlert(_ key: String, value: Double?, reset: Date?, now: Date = Date()) -> Bool {
        guard alertsEnabled, let reset, reset > now else { return false }
        if let v = value, v >= alertWarn { return true }
        if let asked = remindAtReset[key], abs(asked - reset.timeIntervalSince1970) < 3600 { return true }
        return false
    }

    // Scheduled with the system so it fires even if this app has quit.
    // Re-scheduled on every refresh (same identifier), so a moved reset time
    // or a drop back under the level is picked up.
    func scheduleResetAlerts(_ u: Usage, for id: String) {
        for l in limits(u) {
            let ident = "reset-\(l.key)-\(id)"
            guard wantsResetAlert("\(id)/\(l.key)", value: l.value, reset: l.reset), let r = l.reset else {
                Notifier.shared.cancel([ident]); continue
            }
            Notifier.shared.schedule(ident, at: r, title: "\(id): \(l.label) reset",
                                     body: "\(id) has its full \(l.label) again. You're good to go.",
                                     category: AlertAction.category(.reset, id),
                                     info: info(id, l.key, reset: r, best: nil))
        }
    }
}
