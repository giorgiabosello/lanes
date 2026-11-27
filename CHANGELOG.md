# Changelog

What changed in each version of Lanes. This file is the source for the
release notes on GitHub, the changelog on [lanes.pego.tech](https://lanes.pego.tech/changelog.html)
and the What's New window in the app.

<!--
Each release is a "## <version> — <title>" heading, then its date as
"_YYYY-MM-DD_", then paragraphs and "- " bullets. Inline Markdown only:
**bold**, *italic*, `code` and [links](https://…). Newest first. Add the
entry before running scripts/release.sh, which refuses a version without one.

What's New can offer a "Try it" card: under the date, a comment line that
starts with "<!-- try:" and lists actions separated by "|": copy <command>,
statusline, test-alert, settings <general|alerts|shortcuts|updates|status>.
Only the app reads it; GitHub and the website drop comments.
-->

## 0.10.0 — Every lane in your terminal
_2026-11-27_
<!-- try: copy lanes claude --best | statusline | test-alert | settings status -->

- **Claude Code on any account**: `lanes claude work` runs Claude Code in your terminal on that profile's own account, settings and history, the same ones its Code and Cowork tabs use. `lanes claude --best` picks the profile with the most room; your plain `claude` stays on Default. Arguments go straight through, so `lanes claude work -p "…"` works too.
- **Usage in Claude Code's status line**: `lanes usage --statusline` prints one line for the session's profile, such as *Work · 5h 86% resets in 1h 10m · week 41%*. It turns orange and red as limits fill, and warns when one will run out before it resets. Turn it on for every profile in **Settings → General**, or with `lanes statusline on`.
- **Notifications you can act on**: usage alerts now have buttons. **Open** switches to the profile with the most room, and **Mute Until Reset** silences that limit. Pace alerts add **Notify Me at Reset**. Click an alert anywhere else to open the menu bar panel. **Settings → Alerts** can send a test alert.
- **Settings → Status**: Lanes checks what it depends on, including Claude Desktop, launchers, the watchdog, the Keychain item and each profile's sign-in. It offers one-click fixes, and an orange dot on the gear means something needs a look. From the Terminal: `lanes doctor [--fix]`.
- **A welcome on first launch**: three short steps. The Keychain and notification prompts wait for the step that explains why Lanes needs them.
- **Clearer empty lanes**: a lane without usage now has a **Sign In** or **Retry** button and says what went wrong, for example the Keychain was declined, or a profile isn't signed in yet.
- **What's New you can try**: the What's New window marks the releases you haven't seen yet, and lets you try their features right there. The Terminal gets a one-line heads-up after an update, and `lanes whats-new` prints the notes.
- **Tidier Settings**: General, Alerts, Shortcuts, Updates and Status are tabs now, instead of one long scrolling form.

## 0.9.2 — Faster, sturdier usage readings
_2026-11-26_

- **All lanes at once**: usage is now checked for every profile in parallel, and a profile that hangs gives up after 30 seconds instead of holding up the others.
- **One Keychain prompt**: Lanes asks the Keychain for Claude's cookie key once, not once per profile, and if you decline it doesn't ask again straight away.
- **Numbers even offline**: when claude.ai can't be reached, a lane shows the last usage Claude Desktop recorded itself if that's newer than Lanes' own, marked *As of …* as before. Handy right after starting Lanes without a connection.
- Under the hood: the app's code is split into smaller pieces and has its first unit tests, which already caught a cookie-decryption edge case.

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
