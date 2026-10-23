#!/usr/bin/env bash
# Usage: scripts/verify/render-snapshots.sh
# Launches the Debug app twice (EN, ES) with METR_DEBUG_RENDER_DIR set, so it renders the panel
# fixtures (idle, stress, unavailable) and the welcome window (default and fallback tip) in light
# and dark to PNG files and exits.
# Expects 20 PNGs (12 panel + 8 welcome). Prints "RENDER-SNAPSHOTS OK dir=<path>".
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

DIR="$METR_PREVIEWS/snapshots"
mkdir -p "$DIR"
rm -f "$DIR"/panel-*.png "$DIR"/welcome-*.png

bash scripts/verify/run-debug.sh 8 render-en \
  --env "METR_DEBUG_RENDER_DIR=$DIR" \
  --expect 'rendered panel-' --min 6 \
  --expect 'rendered welcome-' --min 4 \
  --args -AppleLanguages '(en)' -AppleLocale en_US

bash scripts/verify/run-debug.sh 8 render-es \
  --env "METR_DEBUG_RENDER_DIR=$DIR" \
  --expect 'rendered panel-' --min 6 \
  --expect 'rendered welcome-' --min 4 \
  --args -AppleLanguages '(es)' -AppleLocale es_ES

count="$(find "$DIR" -name 'panel-*.png' -size +0 | wc -l | tr -d ' ')"
[ "$count" = "12" ] || { echo "FAIL: expected 12 panel PNGs in $DIR, found $count" >&2; exit 1; }

welcome="$(find "$DIR" -name 'welcome-*.png' -size +0 | wc -l | tr -d ' ')"
[ "$welcome" = "8" ] || { echo "FAIL: expected 8 welcome PNGs in $DIR, found $welcome" >&2; exit 1; }
[ "$((count + welcome))" = "20" ] || { echo "FAIL: expected 20 PNGs in total" >&2; exit 1; }

echo "RENDER-SNAPSHOTS OK dir=$DIR"
