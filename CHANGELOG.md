# Changelog

What changed in each version of Lanes. This file is the source for the
release notes on GitHub, the changelog on [lanes.pego.tech](https://lanes.pego.tech/changelog.html)
and the What's New window in the app.

<!--
Each release is a "## <version> — <title>" heading, then its date as
"_YYYY-MM-DD_", then paragraphs and "- " bullets. Inline Markdown only:
**bold**, *italic*, `code` and [links](https://…). Newest first. Add the
entry before running scripts/release.sh, which refuses a version without one.
-->

## 0.9.1 — What's New, and updates that restart properly
_2026-11-25_

- **What's New**: after an update, Lanes tells you what changed, with a notification and a strip in the menu bar panel. The whole changelog is in **Settings → What's New**, and on the website.
- **Updates restart Lanes again**: installing an update from the app could leave the old version running on top of the new one, with an **Install** button that kept coming back. If that happened to you, click **Install** once more (or wait for the next check): Lanes restarts on the new version.

## 0.9.0 — Forecasts, pace alerts, 30 days of history
_2026-11-25_

- **Forecasts**: every meter now shows where its limit is heading at the current pace, as a faint extension of the bar. When a limit will run out before it resets, the window says so: *Used up ~15:40 at this pace*.
- **Pace alerts**: a heads-up when the 5-hour limit will run out within 45 minutes, or the weekly one within a day, well before it resets.
- **Weekly alerts, your levels**: alerts now cover the weekly limit too, suggest the profile with the most room, and fire at levels you pick in **Settings** (80% and 95% by default).
- **Per-model limits**: weekly limits for a single model, such as Opus, appear in the lane's drawer, in `lanes usage` and in `usage.json`.
- **30 days of history**: the drawer's chart switches between Day, Week and Month, and exports CSV. From the Terminal: `lanes history [name] [--days N] [--json]`.
- **Sturdier usage readings**: a failed check keeps the previous numbers for up to an hour, marked *As of …*, instead of blanking the lane. If claude.ai changes how it reports usage, Lanes says so and offers to check for an update.

`usage.json` gains `fiveHourRunsOut`, `sevenDayRunsOut`, `limits` and `staleSince`; `usage.tsv` gains four columns at the end. Existing scripts keep working.

## 0.8.0 — Install with curl, updates itself
_2026-11-25_

**Coming from 0.7.0?** Run the curl command once. From here on, Lanes updates itself.

- **One-line install**: the curl installer downloads the latest release, checks its signature, installs Lanes into Applications, links the `lanes` command and opens the app. No Open Anyway step.
- **Automatic updates**: Lanes checks GitHub every few hours, installs new versions and reopens. Turn it off in **Settings → Updates** to get an **Update** button in the menu bar panel instead.
- **`lanes update [--check]`**: the same from the Terminal.
- **DMG download** for the website, with the usual drag-to-Applications window.

Update checks only ask GitHub for the latest version number; nothing about your Mac is sent.

## 0.7.0 — Lanes for Claude
_2026-11-24_

The first release as **Lanes for Claude**: several Claude Desktop accounts side by side, each in its own lane.

- **Isolated profiles**: each with its own login, chats, settings, Claude Code config and color, a launcher in Spotlight, and a colored Dock tile. Profiles update themselves; a watchdog keeps them on their own account.
- **Menu bar app**: 5-hour and weekly usage per profile with reset times and a 24-hour sparkline; click to launch or focus.
- **Desktop widget**: per-profile usage bars and live reset countdowns.
- **Sign in without quitting other profiles**: `claude://` links go to the right profile.
- **Open the most free profile**: ⌥⌘B, or `lanes launch --best`.
- **Usage alerts** at 80% and 95%, plus a notification when a nearly-used limit resets.
- **`lanes` CLI**: `lanes add`, `lanes launch`, `lanes usage [--json]`, and more.

Everything Lanes keeps lives in `~/Library/Application Support/Lanes`. No telemetry; the only network calls are the usage checks to claude.ai, made with each profile's own session.
