# The `lanes` command

Everything Lanes does goes through one zsh script, `lanes`. The window, the
menu bar, the Spotlight launchers and the widget all call it, and so can
you.

[← Back to the README](../README.md)

---

## Put it on your PATH

The script ships inside the app:

```sh
sudo mkdir -p /usr/local/bin
sudo ln -sf /Applications/Lanes.app/Contents/Resources/lanes /usr/local/bin/lanes
```

(A source install with `./install.sh` links it for you.)

## Everyday

```sh
lanes add work --color blue     # a new profile, with its Spotlight launcher
lanes launch work               # launch it, or bring it forward if it's running
lanes launch --best             # the profile with the most 5-hour room
lanes usage                     # 5-hour and weekly usage, with reset times
lanes list                      # every profile, and whether its launcher is healthy
lanes color work teal           # recolor its Dock tile and launcher
lanes remove work               # remove it; asks before touching its data
```

Names are forgiving: `lanes add "client acme"` creates **Client Acme**, and
its launcher is **Claude Client Acme**. The colors are `orange`, `red`,
`yellow`, `green`, `teal`, `blue`, `purple` and `pink`.

## All commands

| Command | What it does |
|---|---|
| `lanes add <name> [--color <c>]` | Creates a profile and its Spotlight launcher, and installs the watchdog. Running it again on an existing profile rebuilds the launcher and keeps the color unless you pass a new one. |
| `lanes launch <name>` | Launches the profile from its own clone of Claude.app, or focuses it if it's already running. |
| `lanes launch --best` | Launches the profile with the most 5-hour headroom. A profile whose weekly limit is used up is skipped, unless they all are. |
| `lanes usage [--json]` | The latest usage per profile, as last loaded by the menu bar app. `●` marks running profiles. |
| `lanes list` | Profiles, their data folders, and whether each launcher is in place. |
| `lanes color <name> <color>` | Changes a profile's color. A running profile picks it up on its next launch. |
| `lanes remove <name> [--keep-data \| --delete-data]` | Removes the launcher, and optionally the data folder. Without a flag, it asks. |
| `lanes watchdog [install \| uninstall \| status]` | Manages the LaunchAgent that puts profiles back on their own data after an update relaunches them. `status` also lists any strays. |
| `lanes watch [--once]` | What the watchdog runs every three seconds. |
| `lanes update [--check]` | Installs the latest release of Lanes.app in place of the installed one, and reopens it if it was running. `--check` only reports whether there is one. The app does the same on its own unless **Settings → Updates** says otherwise. |
| `lanes setup [--if-needed]` | Points the launchers, the watchdog and the helper at this copy of `lanes`. The app runs it the first time a new version opens. |
| `lanes gui` | Builds the app from a repo checkout and installs it into `~/Applications`. Needs the Xcode Command Line Tools. |
| `lanes chooser [--force]` | Builds a dialog-based AppleScript picker instead, with no build tools needed. It won't replace the full app without `--force`. |
| `lanes version` | Prints the version. |
| `lanes help` | Prints a short summary of all of the above. |

## Usage data for scripts

`lanes usage` never calls the network. It reads the files the menu bar app
writes after every check in `~/Library/Application Support/Lanes/`, so it
needs the app running to stay fresh. When the data is more than 30 minutes
old, it says so.

### `usage.json`

What `lanes usage --json` prints:

```json
{
  "profiles" : [
    {
      "color" : "blue",
      "fiveHour" : 86,
      "fiveHourReset" : "2026-11-24T18:40:00Z",
      "name" : "Work",
      "running" : true,
      "sevenDay" : 63,
      "sevenDayReset" : "2026-11-27T05:00:00Z"
    },
    {
      "color" : "purple",
      "error" : "not signed in",
      "name" : "Personal",
      "running" : false
    }
  ],
  "updated" : "2026-11-24T18:01:54Z"
}
```

Percentages are the share of each limit used. A field the app doesn't know
is left out. `error` is set when a profile has no numbers: `not signed in`,
`session expired`, or a short network error.

### `usage.tsv`

One line per profile, tab-separated, after a `# updated <epoch>` header:

```
name  color  running(1/0)  5h%  5h-reset-epoch  week%  week-reset-epoch  error
```

Empty fields mean unknown.

### Example: a status line

The usage of every signed-in profile on one line, for a prompt, tmux or a
Claude Code status line:

```sh
lanes usage --json | jq -r '
  [.profiles[] | select(.fiveHour != null) | "\(.name) \(.fiveHour | round)%"]
  | join(" · ")'
# Default 23% · Work 86% · Studio 7%
```
