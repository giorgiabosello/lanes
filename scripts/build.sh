#!/bin/sh
# Builds the release: build/Lanes.app (universal, ad-hoc signed) and the two
# assets attached to the GitHub release:
#   build/Lanes.zip  what the curl installer and `lanes update` download
#   build/Lanes.dmg  the website's download: drag Lanes into Applications
set -eu
cd "$(dirname "$0")/.."

APP="build/Lanes.app"
LANES_ARCHS="arm64 x86_64" bin/lanes build "$APP"
rm -f build/Lanes.zip build/Lanes.dmg
ditto -c -k --keepParent "$APP" build/Lanes.zip

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$APP" "$stage/Lanes.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname Lanes -srcfolder "$stage" -fs HFS+ -format UDZO -ov build/Lanes.dmg

echo "Built $APP, build/Lanes.zip and build/Lanes.dmg ($(bin/lanes version))"
