#!/usr/bin/env bash
# Renders Resources/AppIcon.icns from the PerchMark SwiftUI view.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Perch >/dev/null
BIN="$(swift build -c release --show-bin-path)/Perch"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$BIN" --render-icon "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
echo "✓ Wrote Resources/AppIcon.icns"
