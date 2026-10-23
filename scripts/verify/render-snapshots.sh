#!/usr/bin/env bash
# Usage: scripts/verify/render-snapshots.sh
# Launches the Debug app twice (EN, ES) with METR_DEBUG_RENDER_DIR set, so it renders the panel
# fixtures (idle, stress, unavailable) in light and dark to PNG files and exits.
# Expects 12 PNGs. Prints "RENDER-SNAPSHOTS OK dir=<path>".
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

DIR="$METR_PREVIEWS/snapshots"
mkdir -p "$DIR"
rm -f "$DIR"/panel-*.png

bash scripts/verify/run-debug.sh 8 render-en \
  --env "METR_DEBUG_RENDER_DIR=$DIR" \
  --expect 'rendered panel-' --min 6 \
  --args -AppleLanguages '(en)' -AppleLocale en_US

bash scripts/verify/run-debug.sh 8 render-es \
  --env "METR_DEBUG_RENDER_DIR=$DIR" \
  --expect 'rendered panel-' --min 6 \
  --args -AppleLanguages '(es)' -AppleLocale es_ES

count="$(find "$DIR" -name 'panel-*.png' -size +0 | wc -l | tr -d ' ')"
[ "$count" = "12" ] || { echo "FAIL: expected 12 panel PNGs in $DIR, found $count" >&2; exit 1; }

echo "RENDER-SNAPSHOTS OK dir=$DIR"
