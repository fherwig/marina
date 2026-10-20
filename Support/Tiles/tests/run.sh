#!/bin/sh
# The tile view's keys and clicks, without a window: keys only reach a pane
# that has the keyboard, which a test cannot give it. From the repository root:
#   Support/Tiles/tests/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
# top-level code is only allowed in a file called main.swift
cp "$here/TileSelectionTests.swift" "$out/main.swift"
swiftc -o "$out/tiles" "$here/../../../Sources/Marina/Models/TileSelection.swift" "$out/main.swift"
"$out/tiles"
