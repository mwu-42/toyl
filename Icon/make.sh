#!/bin/bash
# Draws toyl's icon (Icon.swift) and makes Icon/toyl.icns from it.
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -O Icon.swift -o "$work/draw"
"$work/draw" toyl.png
set_dir="$work/toyl.iconset"
mkdir -p "$set_dir"
for s in 16 32 128 256 512; do
    sips -z $s $s toyl.png --out "$set_dir/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) toyl.png --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o toyl.icns
echo "Made Icon/toyl.icns"
