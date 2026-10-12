#!/bin/sh
# Build FSearchPanel.app from source.
# Usage: panel/build.sh [output-app-path]   (default: ~/Applications/FSearchPanel.app)
set -e
here=$(cd "$(dirname "$0")" && pwd)
app=${1:-"$HOME/Applications/FSearchPanel.app"}
mkdir -p "$app/Contents/MacOS"
swiftc -O "$here/main.swift" -o "$app/Contents/MacOS/FSearchPanel"
cp "$here/Info.plist" "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "built $app"
