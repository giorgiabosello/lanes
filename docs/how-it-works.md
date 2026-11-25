# How Lanes works

Claude Desktop supports one signed-in account. Lanes gets around that
without patching anything. This page explains how, from the single flag it
all rests on to the small fixes that make the result feel like a native Mac
app.

[← Back to the README](../README.md)

---

### One flag

Claude Desktop is an Electron app, and Electron honors Chromium's
`--user-data-dir` flag. Point it at a different folder and Claude starts
with a different everything: login, chats, settings, projects, MCP
connectors. That folder is a profile. The rest of Lanes is about making
"launch Claude with this flag" behave like a real app.

### A profile is a folder

```
~/Library/Application Support/Lanes/
├── profiles/
│   ├── Work/                 ← Claude's data for the Work profile
│   │   ├── .lanes-color      ← "blue"
│   │   └── claude-config/    ← its own Claude Code config
│   └── Personal/
├── apps/                     ← per-profile clones of Claude.app
├── usage.json · usage.tsv    ← the latest usage, for the widget and CLI
└── usage-history.json        ← a week of readings, for the chart
```

There's no registry, database or state file. The window, the menu bar, the
widget and the CLI all discover profiles by listing `profiles/` when they
need to. The color lives inside the profile folder, so it travels with it.

### Clones, not copies

Every profile runs from its own copy of Claude.app in `apps/`, made with
`cp -c`. That's an APFS copy-on-write clone: it takes about half a second
and almost no disk, because the clone shares its blocks with the original
until one of them changes.

A clone per profile is what makes each profile a separate app to macOS,
with its own Dock tile, its own window list and its own color. The clones
live outside Spotlight's index, so nobody can open one by accident without
its `--user-data-dir`.

### Color without breaking the signature

Changing a signed app's icon file breaks its code signature. Keychain then
stops handing over "Claude Safe Storage", and the profile is logged out.

Lanes doesn't edit the bundle. It sets a **Finder custom icon**
(`NSWorkspace.setIcon`), a hue-shifted copy of Claude's icon made with
Core Image's `CIHueAdjust`. A Finder icon is metadata outside the code seal,
so `codesign --verify` still passes and logins survive. The Dock honors it
too. The window draws its lane icons with the same filter, so what you see
in Lanes is exactly what you'll find in the Dock.

### Launching

Everything ends up calling `lanes launch <name>`: the window, the menu bar,
the Spotlight launchers and the widget. If the profile is already running,
Lanes brings its process forward with `NSRunningApplication` instead of
launching again. Claude's second-instance handler would otherwise open a new
window on every click.

If it isn't running, Lanes starts the clone directly, not through `open`.
It passes `--user-data-dir` and a clean, launchd-like environment that
includes `CLAUDE_CONFIG_DIR=<profile>/claude-config`.

That last variable matters more than it looks. `--user-data-dir` only
scopes Electron's own data. The Claude Code that Desktop embeds for its
Code and Cowork tabs would otherwise share `~/.claude`, `~/.claude.json` and
the CLI's Keychain item with every other profile, and with the `claude` in
your terminal. Without the variable, one profile's account can show up in
unrelated CLI sessions.

Lanes finds running profiles by reading each Claude process's
`--user-data-dir` from `ps`. All the instances share one binary, so the flag
is the only thing that tells them apart.

### Strays and the watchdog

Claude's self-update relaunches the app through Squirrel's ShipIt, by
bundle path, with no arguments and no environment. A clone relaunched that
way comes back on the *default* data folder. That means the default account
and the default orange icon, in a window still titled "Claude Work".
Reopening a clone from the Dock's recent items does the same.

`lanes add` installs a LaunchAgent that runs `lanes watch` every three
seconds. It quits any clone running without its `--user-data-dir` and
relaunches it on its own profile, so an update's restart lands on the right
account within moments. `lanes launch` does the same sweep first, and
`lanes watchdog status` shows both the agent and any strays.

### Updates only move forward

Each profile updates itself. Squirrel installs the update into that
profile's own clone, so profiles stay current on their own schedule,
independent of your main Claude and of each other.

On launch, `lanes` only ever moves a clone **forward**:

- **Missing, or older than `/Applications/Claude.app`:** clone it again
  from the original.
- **Newer than the original (it updated itself):** leave it alone. Cloning
  again from an older original would undo the update and trap the app
  downloading it forever. An early version of this tool did exactly that.
- **Same version as the original again** (your main Claude caught up):
  clone it again once. This restores APFS block sharing and the profile
  color, which an update wipes.

### Links find their way home

Claude's sign-in hands its token back to the app over a `claude://` link,
and "open in the desktop app" links use the same scheme. Every clone shares
Claude's bundle identifier, so macOS would deliver those links to whichever
Claude it sees first.

The Lanes menu bar app registers itself as the handler for `claude://`
instead. Claude claims the scheme back every time it starts, so a two-second
check claims it again. Each link is then forwarded with
`NSWorkspace.open(_:withApplicationAt:)`, pointed at one profile's clone.
LaunchServices delivers it to the running process of exactly that bundle.

A link is only sent to a clone that is already running on its profile.
Opening a link with a stopped clone would start it bare, on the default
account. So a stopped profile is started through `lanes launch` first, and
the link follows once the profile is up. Link contents are never logged or
shown, because a sign-in link carries its token in the query.

### Reading usage

The numbers are the same ones as Claude's *Settings → Usage*. The menu bar
app reads each profile's claude.ai session cookie from its cookie jar. It
copies the SQLite file first, because Claude keeps the live one locked, and
decrypts the cookie with the "Claude Safe Storage" Keychain key. macOS asks
for that key once. Lanes then calls claude.ai's usage endpoint for each of
the account's organizations until one reports limits.

That endpoint is undocumented and could change without notice. The cookies
are only read: never stored, and never sent anywhere but claude.ai.

After every check, the app writes `usage.json` and `usage.tsv` and asks
WidgetKit to redraw. The widget, `lanes usage` and `lanes launch --best`
only read those files, so they cost no network calls and need no Keychain
access. The widget is a sandboxed extension whose only file access is
read-only access to that one folder.

Every ten minutes or so, a reading also goes into `usage-history.json`,
which keeps a week of them. That file drives the chart in each lane's
drawer.

### Spotlight launchers

The "Claude Work" you find in Spotlight is a tiny `osacompile` applet in
`~/Applications` that runs `lanes launch Work`. Each one gets:

- a unique `CFBundleIdentifier`, or LaunchServices treats every applet as
  the same app;
- a tinted icon, with the applet's bundled `Assets.car` removed, because it
  would otherwise override the icon of the running app;
- a fresh ad-hoc signature after these edits.

### Installing and updating Lanes itself

Lanes is ad-hoc signed, not notarized: notarization needs a paid Apple
developer account. Gatekeeper only stops apps that carry the
`com.apple.quarantine` attribute, which browsers add to what they download
and curl doesn't. So:

- **The DMG**, downloaded in a browser, is quarantined, and its first launch
  needs Open Anyway.
- **The curl installer** (`site/install`, served at lanes.pego.tech/install)
  downloads `Lanes.zip` from the latest GitHub release, checks the bundle id
  and that `codesign --verify --deep --strict` passes, then moves the app
  into Applications. Nothing is quarantined, so there's no prompt.
- **Updates** work the same way. The app asks GitHub where
  `releases/latest` redirects (`…/tag/v0.8.0`) shortly after launch and
  every six hours. When there's a newer version, it runs its bundled
  `lanes update`, detached and logging to `~/Library/Caches/Lanes/update.log`.
  That downloads and checks the zip, quits Lanes, moves the old bundle aside
  (putting it back if the swap fails), runs the new version's `lanes setup`
  to repoint launchers and the watchdog, and reopens it.

The check sends nothing but the request for that one URL.

### What's never touched

Your main Claude keeps using `~/Library/Application Support/Claude`. Lanes
reads that folder only to show the default profile's usage, and never
writes to it. Profiles start empty and never copy credentials: each one
signs in on its own.
