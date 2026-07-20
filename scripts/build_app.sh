#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
BUILD_ROOT="$PROJECT_ROOT/build"
TEMP_ROOT="$(mktemp -d /private/tmp/codex-pulse-build.XXXXXX)"
APP_NAME="Codex Pulse.app"
STAGED_APP="$TEMP_ROOT/$APP_NAME"
CONTENTS="$STAGED_APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
MODULE_CACHE="/private/tmp/codex-pulse-clang-cache"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$BUILD_ROOT" "$MODULE_CACHE"

clang \
  -fobjc-arc -fblocks -O2 -mmacosx-version-min=13.0 \
  -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations \
  -fmodules-cache-path="$MODULE_CACHE" \
  -I "$PROJECT_ROOT/Sources" \
  "$PROJECT_ROOT/Sources/main.m" \
  "$PROJECT_ROOT/Sources/AppDelegate.m" \
  "$PROJECT_ROOT/Sources/CPFileWatcher.m" \
  "$PROJECT_ROOT/Sources/CPLogCollector.m" \
  "$PROJECT_ROOT/Sources/CPPricingEngine.m" \
  -framework AppKit -framework WebKit -framework CoreServices \
  -o "$MACOS_DIR/CodexPulse"

cp "$PROJECT_ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$PROJECT_ROOT/Resources/dashboard.html" "$RESOURCES_DIR/dashboard.html"
cp "$PROJECT_ROOT/Resources/dashboard.css" "$RESOURCES_DIR/dashboard.css"
cp "$PROJECT_ROOT/Resources/dashboard.js" "$RESOURCES_DIR/dashboard.js"
cp "$PROJECT_ROOT/Resources/pricing.json" "$RESOURCES_DIR/pricing.json"

ICONSET="$TEMP_ROOT/AppIcon.iconset"
mkdir -p "$ICONSET"
clang -fobjc-arc -O2 -fmodules-cache-path="$MODULE_CACHE" \
  "$PROJECT_ROOT/scripts/generate_icon.m" -framework AppKit -o "$TEMP_ROOT/generate_icon"
"$TEMP_ROOT/generate_icon" "$ICONSET" "$RESOURCES_DIR/AppIcon.icns"

codesign --force --deep --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

TARGET_APP="$BUILD_ROOT/$APP_NAME"
if [[ -e "$TARGET_APP" ]]; then
  BACKUP_NAME="Codex Pulse.previous.$(date +%Y%m%d-%H%M%S).app"
  mv "$TARGET_APP" "$BUILD_ROOT/$BACKUP_NAME"
fi
ditto "$STAGED_APP" "$TARGET_APP"

TARGET_ZIP="$BUILD_ROOT/Codex Pulse.zip"
if [[ -e "$TARGET_ZIP" ]]; then
  mv "$TARGET_ZIP" "$BUILD_ROOT/Codex Pulse.previous.$(date +%Y%m%d-%H%M%S).zip"
fi
ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" "$TARGET_ZIP"

echo "$TARGET_APP"
echo "$TARGET_ZIP"
