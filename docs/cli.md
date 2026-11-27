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
lanes claude work               # Claude Code in this terminal, on Work's account
lanes usage                     # 5-hour and weekly usage, with reset times
lanes history work --days 7     # a week of usage readings, as CSV
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
| `lanes usage --statusline [<name>]` | One line of usage for Claude Code's status line. See [below](#claude-code-in-the-terminal). |
| `lanes usage [--json]` | The latest usage per profile, as last loaded by the menu bar app. `●` marks running profiles. Per-model weekly limits (such as Opus) are listed under their profile, followed by a warning for any limit on pace to run out before it resets. |
| `lanes history [<name>] [--days N] [--json]` | The usage readings behind the drawer's chart, one every ten minutes, for up to 30 days: every profile, or just one. CSV by default (`profile,time,five_hour,weekly`, times in UTC), JSON with `--json`. |
| `lanes claude <name> [--] [<args>]` | Runs Claude Code (`claude`) in this terminal on the profile's own config dir, the same one its Code and Cowork tabs use, so it shares their sign-in, settings and history. `--best` picks the profile with the most 5-hour room, and `default` runs it on your usual `~/.claude`. Every other argument goes to `claude`. Put a `--` before them if one would clash with Lanes' own arguments: `lanes claude work -- -p "…"`. |
| `lanes statusline [status \| on \| off] [<name>…]` | Shows, adds or removes Lanes' status line in Claude Code's settings, for every profile or the ones you name. See [The status line](#the-status-line). |
| `lanes list` | Profiles, their data folders, and whether each launcher is in place. |
| `lanes color <name> <color>` | Changes a profile's color. A running profile picks it up on its next launch. |
| `lanes remove <name> [--keep-data \| --delete-data]` | Removes the launcher, and optionally the data folder. Without a flag, it asks. |
| `lanes doctor [--fix] [--tsv]` | Checks what Lanes depends on: Claude Desktop, the app and its setup, the watchdog, Claude's Keychain item, each profile's launcher and sign-in, and how fresh usage is. Says how to fix what's off; `--fix` repairs what it can from the Terminal (setup, watchdog, missing launchers). Exits 1 when something failed. `--tsv` prints `status, id, title, detail, fix` per line, as **Settings → Status** reads it. It never asks for the Keychain password. |
| `lanes watchdog [install \| uninstall \| status]` | Manages the LaunchAgent that puts profiles back on their own data after an update relaunches them. `status` also lists any strays. |
| `lanes watch [--once]` | What the watchdog runs every three seconds. |
| `lanes update [--check]` | Installs the latest release of Lanes.app in place of the installed one, and reopens it if it was running. `--check` only reports whether there is one. The app does the same on its own unless **Settings → Updates** says otherwise. |
| `lanes setup [--if-needed]` | Points the launchers, the watchdog and the helper at this copy of `lanes`. The app runs it the first time a new version opens. |
| `lanes gui` | Builds the app from a repo checkout and installs it into `~/Applications`. Needs the Xcode Command Line Tools. |
| `lanes chooser [--force]` | Builds a dialog-based AppleScript picker instead, with no build tools needed. It won't replace the full app without `--force`. |
| `lanes whats-new [<version>]` | The release notes for this version, or the one you name. After an update, the first `lanes` command you run in a terminal mentions what's new, once. |
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
      "fiveHourRunsOut" : "2026-11-24T18:25:00Z",
      "limits" : [
        {
          "key" : "seven_day_opus",
          "label" : "Opus",
          "reset" : "2026-11-27T05:00:00Z",
          "used" : 48
        }
      ],
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

- `fiveHourRunsOut` and `sevenDayRunsOut`: when that limit will be used up
  at its recent pace, present only when that's before it resets.
- `limits`: weekly limits for a single model family, when the account has
  any.
- `staleSince`: the last check failed, and the numbers are the ones read at
  this time. Lanes keeps them for up to an hour.

### `usage.tsv`

One line per profile, tab-separated, after a `# updated <epoch>` header:

```
name  color  running(1/0)  5h%  5h-reset-epoch  week%  week-reset-epoch  error
5h-runs-out-epoch  week-runs-out-epoch  models  stale-since-epoch
```

(one line per profile; wrapped here). Empty fields mean unknown. `models` is
a comma-separated list of `Label=percent@reset-epoch`, such as
`Opus=48@1764219600`. New columns are only ever added at the end.

## Claude Code in the terminal

`lanes claude <name>` runs the terminal `claude` on the config dir of the
profile you name, which is
`~/Library/Application Support/Lanes/profiles/<Name>/claude-config`. The
profile's Code and Cowork tabs use the same dir. If you already signed in
there, the terminal is signed in too. If not, `/login` once in either
place. Your plain `claude` keeps using `~/.claude`, the Default lane.

```sh
lanes claude work                   # interactive session on Work
lanes claude --best                 # on whichever profile has the most room
lanes claude work -- -p "summarize CHANGELOG.md" > summary.txt
alias cw='lanes claude work'        # a shortcut per account
```

Lanes prints which profile it picked on stderr, so piped output stays clean.

### The status line

`lanes usage --statusline` prints the usage of the profile a session runs
on. It takes the profile from `CLAUDE_CONFIG_DIR`, so the same setting works
in every lane:

```
Work · 5h 86% resets in 1h 10m · week 41% · out ~15:40
```

Percentages turn orange at 75% and red at 90%. *out ~15:40* means the
limit runs out before it resets, at the current pace. *(stale)* means the
numbers are old. Set `NO_COLOR` to drop the colors, and pass a name to show
a different profile. Like `lanes usage`, it reads the snapshot saved by the
app, so it never calls the network.

Turn it on for every profile with **Settings → General → Turn On**, or:

```sh
lanes statusline on          # every profile, and Default if you use the terminal claude
lanes statusline on work     # just one
lanes statusline             # where it's on
lanes statusline off         # take it out again
```

This adds a `statusLine` setting to the `settings.json` in each profile's
`claude-config` (and in `~/.claude` for Default) and leaves the rest of the
file as it was. The first change to a file keeps a copy beside it, as
`settings.json.lanes-backup`. A profile that already has a status line of
its own is left alone. To set one up by hand instead:

```json
{
  "statusLine": { "type": "command", "command": "lanes usage --statusline" }
}
```

### Example: every profile on one line

The usage of every signed-in profile on one line, for a prompt, tmux or a
Claude Code status line:

```sh
lanes usage --json | jq -r '
  [.profiles[] | select(.fiveHour != null) | "\(.name) \(.fiveHour | round)%"]
  | join(" · ")'
# Default 23% · Work 86% · Studio 7%
```
