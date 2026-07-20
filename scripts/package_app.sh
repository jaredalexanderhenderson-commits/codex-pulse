#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
WORKSPACE_ROOT="${PROJECT_ROOT:h}"
APP="$PROJECT_ROOT/build/Codex Pulse.app"
ZIP="$PROJECT_ROOT/build/Codex Pulse.zip"
OUTPUTS="$WORKSPACE_ROOT/outputs"
BACKUPS="$WORKSPACE_ROOT/work/previous-codex-pulse-deliverables"

if [[ ! -d "$APP" || ! -f "$ZIP" ]]; then
  echo "Build the app first with: make app" >&2
  exit 1
fi

mkdir -p "$OUTPUTS" "$BACKUPS"
STAMP="$(date +%Y%m%d-%H%M%S)"
if [[ -e "$OUTPUTS/Codex Pulse.zip" ]]; then
  mv "$OUTPUTS/Codex Pulse.zip" "$BACKUPS/Codex Pulse.$STAMP.zip"
fi

cp "$ZIP" "$OUTPUTS/Codex Pulse.zip"
cp "$PROJECT_ROOT/INSTALL.md" "$OUTPUTS/Codex Pulse Installation.md"

echo "$OUTPUTS/Codex Pulse.zip"
