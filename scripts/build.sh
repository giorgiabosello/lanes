#!/bin/sh
# Builds the release: build/Lanes.app (universal, ad-hoc signed) and
# build/Lanes.zip, the asset attached to the GitHub release.
set -eu
cd "$(dirname "$0")/.."

APP="build/Lanes.app"
LANES_ARCHS="arm64 x86_64" bin/lanes build "$APP"
rm -f build/Lanes.zip
ditto -c -k --keepParent "$APP" build/Lanes.zip
echo "Built $APP and build/Lanes.zip ($(bin/lanes version))"
