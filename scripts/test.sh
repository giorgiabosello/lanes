#!/bin/zsh
# Release checks: builds the app (skip with --no-build), verifies the bundle,
# then installs the zip the way a download arrives (quarantined) into a
# throwaway HOME and runs the app's first-launch setup there. The real
# ~/Applications, profiles and watchdog are never touched; Claude.app is only
# read for its icon.
set -uo pipefail
cd "${0:A:h:h}"

fails=0
check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    print -- "ok   $name"
  else
    print -- "FAIL $name"
    fails=$((fails + 1))
  fi
}

APP="build/Lanes.app"
HELPER_REL="Contents/Resources/Lanes Helper.app/Contents/MacOS/Lanes Helper"
version=$(zsh bin/lanes version)

check "lanes parses" zsh -n bin/lanes
if [[ "${1:-}" != "--no-build" ]]; then
  scripts/build.sh >/dev/null 2>&1 || { print -- "FAIL build"; exit 1 }
fi

universal() { [[ "$(lipo -archs "$1")" == *arm64* && "$(lipo -archs "$1")" == *x86_64* ]] }
check "app binary is universal" universal "$APP/Contents/MacOS/Lanes"
check "helper binary is universal" universal "$APP/$HELPER_REL"
WIDGET="$APP/Contents/PlugIns/LanesWidget.appex"
check "widget binary is universal" universal "$WIDGET/Contents/MacOS/LanesWidget"
check "widget is a WidgetKit extension" test "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$WIDGET/Contents/Info.plist")" = com.apple.widgetkit-extension
check "widget enters at NSExtensionMain" sh -c '"$1" 2>&1 | grep -q "XPC Service cannot be run directly"' _ "$WIDGET/Contents/MacOS/LanesWidget"
check "widget is sandboxed" sh -c 'codesign -d --entitlements - "$1" 2>/dev/null | grep -q com.apple.security.app-sandbox' _ "$WIDGET"
check "signature verifies" codesign --verify --deep --strict "$APP"
check "Info.plist version is $version" test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$version"
check "bundled lanes is bin/lanes" cmp bin/lanes "$APP/Contents/Resources/lanes"
check "app has its icon" cmp app/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# ---- first launch of a downloaded copy, in a sandbox HOME -------------------

sandbox=${$(mktemp -d):A}
label="io.github.pego.lanes.test-$$"
trap 'launchctl bootout "gui/$(id -u)/$label" 2>/dev/null; rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/Applications" "$sandbox/Library/Application Support/Lanes/profiles/Test" "$sandbox/Applications/Claude Test.app"
cp build/Lanes.zip "$sandbox/"
xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;$(uuidgen)" "$sandbox/Lanes.zip"
ditto -x -k "$sandbox/Lanes.zip" "$sandbox/Applications"
installed="$sandbox/Applications/Lanes.app"
cached="$sandbox/Library/Caches/Lanes/Lanes Helper.app"
launcher="$sandbox/Applications/Claude Test.app"

quarantined() { xattr -p com.apple.quarantine "$1" }
not_quarantined() { ! xattr -rl "$1" | grep -q com.apple.quarantine }
# Exit 3 = no app with that pid; a quarantined helper is SIGKILLed instead.
helper_runs() { "$1" focus 999999; [[ $? == 3 ]] }
setup() { HOME="$sandbox" LANES_WATCH_LABEL="$label" zsh "$installed/Contents/Resources/lanes" setup "$@" }

check "download is quarantined" quarantined "$installed/$HELPER_REL"
check "setup succeeds" setup --if-needed
check "setup records version and location" grep -qxF "$version $installed/Contents/Resources/lanes" "$sandbox/Library/Caches/Lanes/setup"
check "cached helper is not quarantined" not_quarantined "$cached"
check "cached helper runs" helper_runs "$cached/Contents/MacOS/Lanes Helper"
check "launcher rebuilt as an applet" test -x "$launcher/Contents/MacOS/applet"
check "launcher bundles this lanes" cmp bin/lanes "$launcher/Contents/Resources/lanes"
check "launcher lanes is not quarantined" not_quarantined "$launcher/Contents/Resources/lanes"
check "launcher signature verifies" codesign --verify "$launcher"
check "watchdog points at the app's lanes" grep -qF "$installed/Contents/Resources/lanes" "$sandbox/Library/LaunchAgents/$label.plist"
check "launcher has a Lanes bundle id" test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$launcher/Contents/Info.plist")" = io.github.pego.lanes.profile.test
check "setup leaves the app's signature intact" codesign --verify --deep --strict "$installed"
touch -t 200001010000 "$launcher"
setup --if-needed >/dev/null 2>&1
check "setup --if-needed skips when current" test "$(stat -f %Sm -t %Y "$launcher")" = 2000

(( fails == 0 )) && print -- "all passed" || { print -- "$fails failed"; exit 1 }
