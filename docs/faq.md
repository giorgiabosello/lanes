# FAQ

[← Back to the README](../README.md)

---

### Does Lanes touch my existing Claude?

No. Your main Claude keeps its own data in
`~/Library/Application Support/Claude`, and Lanes never writes there. It
only reads that folder's session to show the main install's usage. In
Lanes, that install is the **Default** lane.

### Is this against Anthropic's terms?

Lanes runs the same app: byte-identical APFS clones with their signature
intact, launched with a documented Chromium flag, signed in to accounts you
own. Nothing is patched, injected or intercepted. Usage is read the same way
Claude's own Settings page reads it, with your own session.

### How much disk do the clones take?

A fresh clone is close to free, thanks to APFS copy-on-write. A clone
becomes a full copy (about 750 MB) once it **updates itself**, because the
update rewrites the bundle and breaks the sharing. That's temporary: as soon
as your main Claude reaches the same version, the profile's next launch
clones it again and the sharing comes back.

### How do I update Claude?

You don't have to do anything. Each profile installs Claude's updates by
itself, into its own clone, on its own schedule. If a profile says "Update
available", let it restart as usual. The watchdog makes sure it comes back
on the right account. A profile whose clone falls behind your main Claude
catches up the next time it launches, and the window's footer tells you
when that's the case.

### Claude updated while I was using it, and came back on the wrong account

That's the update's relaunch landing on the default data folder. The
watchdog notices within about three seconds, quits that instance and
relaunches the profile properly, which also restores its color. If it
didn't, check `lanes watchdog status`.

### The sign-in link opened in the wrong Claude

Make sure **Send claude:// links to the right profile** is on in Settings
and that Lanes is running. Without it, macOS hands the link to whichever
Claude is running, so quit the others (<kbd>⌘Q</kbd>) before a profile's
first sign-in. If a token ever lands in the wrong place, no data is lost:
sign that instance back in to its own account.

### macOS keeps asking for "Claude Safe Storage"

That's the Keychain key Lanes needs to read a profile's session cookie, and
it's the same key for every profile. Choose **Always Allow** and it won't
ask again. If you'd rather not grant it, profiles still work; you just
won't see their usage.

### What is the line on each meter?

The pace marker: how much of that window has already passed. With 38
minutes left of a 5-hour window, the marker sits near 87%. A bar that ends
before its marker means you're using the limit more slowly than time is
passing.

### Where does "most room" come from?

The profile with the lowest 5-hour usage, with the weekly limit breaking
ties. A profile whose weekly limit is used up only wins if every profile's
is. The callout appears once at least two profiles report numbers.

### Can it do this for Claude Code in the terminal?

That's out of scope by design. Set `CLAUDE_CONFIG_DIR` per account, or use
a tool like claude-swap. The Code and Cowork tabs *inside* each Desktop
profile are isolated by Lanes already.

### iPhone or Android?

Not solvable from the outside: the mobile apps keep one session and offer
no way around it. On a phone, the app plus claude.ai in the browser is the
only two-account setup.

### I don't have the Xcode tools. Does that matter?

Not for the downloaded app. It ships everything prebuilt, including the
small helper that tints icons and focuses windows. Only building from
source needs them.

### How do I remove Lanes completely?

1. In the window, remove each profile and choose **Delete Everything**
   (or run `lanes remove <name> --delete-data`).
2. Run `lanes watchdog uninstall`.
3. Delete Lanes from Applications, and
   `~/Library/Application Support/Lanes` if anything is left.
