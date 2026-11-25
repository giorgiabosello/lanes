#!/bin/zsh
# Publishes the version in bin/lanes (LANES_VERSION) as a GitHub release, with
# its notes taken from CHANGELOG.md:
#   scripts/release.sh             check, build, test, push main, publish
#   scripts/release.sh --notes     only print the release notes it would use
#   scripts/release.sh --yes       publish without asking (no terminal needed)
#
# Before running it: bump LANES_VERSION, add the version's entry at the top of
# CHANGELOG.md, and commit both on main. Publishing is what ships the update:
# every installed Lanes picks it up within a few hours, and the website's
# changelog follows from the push (the Pages workflow).
set -eu
cd "${0:A:h:h}"

fail() { print -u2 -- "✗ $*"; exit 1 }

version=$(zsh bin/lanes version)
title=$(python3 scripts/changelog.py title "$version") || exit 1

if [[ "${1:-}" == --notes ]]; then
  python3 scripts/changelog.py notes "$version"
  exit 0
fi

python3 scripts/changelog.py html site/changelog.html /dev/null ||
  fail "The website's changelog page doesn't build."
[[ "$(git branch --show-current)" == main ]] || fail "Release from main."
[[ -z "$(git status --porcelain)" ]] || fail "Commit or stash your changes first."
gh release view "v$version" >/dev/null 2>&1 && fail "v$version is already released. Bump LANES_VERSION in bin/lanes."
git fetch -q origin main
git merge-base --is-ancestor origin/main HEAD || fail "origin/main has commits you don't. Pull first."

print -- "Building and testing $version…"
scripts/test.sh || fail "Tests failed; nothing was published."

notes=build/release-notes.md
python3 scripts/changelog.py notes "$version" > "$notes"
print -- "\nv$version — $title\n"
cat "$notes"
print
if [[ "${1:-}" != --yes ]]; then
  read -q "?Push main and publish v$version for every Lanes user? [y/N] " || { print; fail "Cancelled; nothing was published." }
  print
fi

git push -q origin main
gh release create "v$version" build/Lanes.zip build/Lanes.dmg \
  --target "$(git rev-parse HEAD)" --title "v$version — $title" --notes-file "$notes"
print -- "✓ Published v$version. Installed copies update within a few hours."
