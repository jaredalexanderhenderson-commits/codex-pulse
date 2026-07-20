#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
TEST_ROOT="$(mktemp -d /private/tmp/codex-pulse-tests.XXXXXX)"
MODULE_CACHE="/private/tmp/codex-pulse-clang-cache"
mkdir -p "$MODULE_CACHE"

clang \
  -fobjc-arc -fblocks -O0 -g -mmacosx-version-min=13.0 \
  -Wall -Wextra -Wno-unused-parameter \
  -fmodules-cache-path="$MODULE_CACHE" \
  -I "$PROJECT_ROOT/Sources" \
  "$PROJECT_ROOT/Tests/TestRunner.m" \
  "$PROJECT_ROOT/Sources/CPLogCollector.m" \
  "$PROJECT_ROOT/Sources/CPPricingEngine.m" \
  "$PROJECT_ROOT/Sources/CPUpdater.m" \
  -framework Foundation -framework AppKit \
  -o "$TEST_ROOT/TestRunner"

"$TEST_ROOT/TestRunner" "$PROJECT_ROOT/Tests/Fixtures" "$PROJECT_ROOT/Resources/pricing.json"
