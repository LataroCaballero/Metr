#!/usr/bin/env bash
# Usage: scripts/test.sh [filter]
# Runs the MetrKit package tests. Fails when the filter matches zero tests.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"
bash "$SCRIPT_DIR/preflight.sh"

mkdir -p "$METR_SPM" "$METR_LOGS"
LOG="$METR_LOGS/test-$(date +%Y%m%d-%H%M%S).log"

args=(test --package-path Packages/MetrKit --scratch-path "$METR_SPM")
if [ -n "${1:-}" ]; then
  args+=(--filter "$1")
fi

status=0
swift "${args[@]}" 2>&1 | tee "$LOG" || status=$?

if [ "$status" -ne 0 ]; then
  echo "FAIL: swift test exited with status $status" >&2
  exit 1
fi
if grep -q "Test run with 0 tests" "$LOG"; then
  echo "FAIL: 'Test run with 0 tests' (the filter matched nothing)" >&2
  exit 1
fi
