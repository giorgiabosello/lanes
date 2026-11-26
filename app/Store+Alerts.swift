// ProfileStore: threshold, pace and reset notifications.

import Foundation

extension ProfileStore {
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
    func thresholdAlerts(_ u: Usage, for id: String) {
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
    func scheduleResetAlerts(_ u: Usage, for id: String) {
        for l in limits(u) {
            let ident = "reset-\(l.key)-\(id)"
            guard alertsEnabled, let v = l.value, v >= alertWarn, let r = l.reset, r > Date() else {
                Notifier.shared.cancel([ident]); continue
            }
            Notifier.shared.schedule(ident, at: r, title: "\(id): \(l.label) reset",
                                     body: "\(id) has its full \(l.label) again. You're good to go.")
        }
    }
}
