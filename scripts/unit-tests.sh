#!/bin/zsh
# Unit tests: compiles the app's sources (not the widget's) with
# tests/UnitTests.swift as the entry point and runs them against the saved
# claude.ai replies in tests/fixtures. Needs only swiftc.
set -eu
cd "${0:A:h:h}"

mkdir -p build
srcs=()
for f in app/*.swift; do
  [[ "$f" == app/Widget.swift ]] || srcs+=("$f")
done
swiftc -D LANES_TESTS -parse-as-library -target "$(uname -m)-apple-macos13.0" \
  -o build/unit-tests "${srcs[@]}" tests/UnitTests.swift
build/unit-tests tests/fixtures
