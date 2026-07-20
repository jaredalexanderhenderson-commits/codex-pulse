#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
ZIP="$PROJECT_ROOT/build/Codex Pulse.zip"
VERIFY_ROOT="$(mktemp -d /private/tmp/codex-pulse-verify.XXXXXX)"

ditto -x -k "$ZIP" "$VERIFY_ROOT"
APP="$VERIFY_ROOT/Codex Pulse.app"

plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
otool -L "$APP/Contents/MacOS/CodexPulse"
file "$APP/Contents/Resources/AppIcon.icns"
