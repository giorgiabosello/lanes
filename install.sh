#!/bin/sh
# Lanes installer.
#
# Builds the "Lanes" app into ~/Applications (SwiftUI when the
# Swift toolchain is available, AppleScript dialog otherwise) and links the
# lanes CLI onto your PATH when possible. Everything is built locally on your
# machine — nothing is downloaded, nothing needs notarization.

set -e
cd "$(dirname "$0")"

LANES="$PWD/bin/lanes"
chmod +x "$LANES"

if command -v swiftc >/dev/null 2>&1; then
    "$LANES" gui
else
    echo "swiftc not found — installing the dialog-based chooser instead."
    echo "For the full GUI: xcode-select --install, then re-run ./install.sh"
    "$LANES" chooser
fi

# Best-effort CLI symlink into the first writable bin dir already on PATH;
# the GUI is fully usable without it.
linked=""
for dir in /usr/local/bin /opt/homebrew/bin "$HOME/.local/bin"; do
    case ":$PATH:" in *":$dir:"*) ;; *) continue ;; esac
    [ -d "$dir" ] && [ -w "$dir" ] || continue
    ln -sf "$LANES" "$dir/lanes" && linked="$dir" && break
done
if [ -n "$linked" ]; then
    echo "✓ lanes linked into $linked"
else
    echo "ℹ No writable bin dir on PATH. For the CLI, add to PATH:"
    echo "    export PATH=\"$PWD/bin:\$PATH\""
fi

echo ""
echo "Done. Hit ⌘Space and type: Lanes"
