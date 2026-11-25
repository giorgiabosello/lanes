#!/bin/zsh
# Renders the README screenshots into docs/images (or the folder given) from
# sample data, so they stay in step with the UI and never show a real account.
#   scripts/snapshots.sh [out-dir]
set -eu
cd "${0:A:h:h}"

out="${1:-docs/images}"
mkdir -p "$out" build
srcs=(app/*.swift(N))
srcs=(${srcs:#app/Widget.swift})
swiftc -D LANES_SNAPSHOT -parse-as-library -target "$(uname -m)-apple-macos13.0" \
  -o build/snapshots $srcs scripts/snapshots.swift
build/snapshots "$out"
