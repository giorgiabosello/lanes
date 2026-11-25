# Development

[← Back to the README](../README.md)

---

## Build from source

You need the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/pego/lanes.git
cd lanes
./install.sh
```

The installer builds the app into `~/Applications` and links `lanes` onto
your PATH. Without a Swift toolchain, it builds the dialog-based AppleScript
picker instead. After that:

- `lanes gui` rebuilds and reinstalls the app;
- `lanes chooser` builds the AppleScript picker.

## The layout

```
bin/lanes             the whole engine: profiles, clones, launchers, watchdog, CLI
app/Lanes.swift       the app's model: profiles, usage, alerts, link routing, scenes
app/Window.swift      the window: lanes, drawers, history chart, new-profile sheet
app/MenuBar.swift     the menu bar glyph and panel
app/Settings.swift    settings
app/Components.swift  shared views: meters, lane markings, tinted icons
app/Shared.swift      compiled into both app and widget: colors, usage snapshot, meter
app/Widget.swift      the WidgetKit extension
scripts/              release build, tests, screenshots, the app icon
```

The app is a front end. Creating, launching, recoloring and removing a
profile all shell out to the copy of `lanes` inside the app bundle. The CLI,
the launchers and the app therefore share one implementation, and the
script is the place to change behavior.

Lanes builds with plain `swiftc`, with no Xcode project. `lanes gui` and the
release build compile every file in `app/` except `Widget.swift` into the
app, and `Widget.swift` with `Shared.swift` into the extension. The app
targets macOS 13 and the widget macOS 14.

## Release and tests

```sh
scripts/build.sh     # build/Lanes.app and build/Lanes.zip, universal
scripts/test.sh      # builds, checks the bundle, then runs a quarantined
                     # copy's first-launch setup in a throwaway HOME
```

The tests never touch your real `~/Applications`, profiles or watchdog.

The version lives in one place, `LANES_VERSION` at the top of `bin/lanes`.
The app's `Info.plist` is written from it.

## Screenshots

```sh
scripts/snapshots.sh            # renders into docs/images
```

The README's screenshots are rendered, not captured. `scripts/snapshots.swift`
compiles the app's views with sample profiles (Default, Work, Studio,
Personal) and draws the window, the panel, the new-profile sheet and the
menu bar icon, each in light and dark mode. It never reads real
profiles or calls the network, and the pictures never show anyone's real
account. Run it after any visual change.

## The app icon

```sh
swift scripts/make-icon.swift app/AppIcon.icns
```

It draws two lanes with Clawd's eyes in the profile colors, and
holds up in a single color.
