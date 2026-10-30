#!/usr/bin/env bash
# Usage: scripts/verify/render-snapshots.sh
# Launches the Debug app twice (EN, ES) with METR_DEBUG_RENDER_DIR set, so it renders every panel
# fixture (idle, stress, elevated, ...) and the welcome window (default and fallback tip) in light
# and dark to PNG files and exits.
# Data-driven: the renderer logs "rendered-total panel=<n> welcome=<m>" per language run. The gate
# fails when that line is missing, when the PNGs on disk differ from the logged totals, when fewer
# than 12 panel PNGs exist or when the welcome count is not exactly 8.
# Prints "RENDER-SNAPSHOTS OK dir=<path> panel=<n> welcome=<m>".
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

DIR="$METR_PREVIEWS/snapshots"
mkdir -p "$DIR"
rm -f "$DIR"/panel-*.png "$DIR"/welcome-*.png

bash scripts/verify/run-debug.sh 8 render-en \
  --env "METR_DEBUG_RENDER_DIR=$DIR" \
  --expect 'rendered-total panel=[0-9]+ welcome=[0-9]+' \
  --args -AppleLanguages '(en)' -AppleLocale en_US -MetrDidPresentWelcome YES

bash scripts/verify/run-debug.sh 8 render-es \
  --env "METR_DEBUG_RENDER_DIR=$DIR" \
  --expect 'rendered-total panel=[0-9]+ welcome=[0-9]+' \
  --args -AppleLanguages '(es)' -AppleLocale es_ES -MetrDidPresentWelcome YES

panel_sum=0
welcome_sum=0
for lang in en es; do
  line="$(grep -E 'rendered-total panel=[0-9]+ welcome=[0-9]+' "$METR_LOGS/render-$lang.log" | tail -n 1 || true)"
  [ -n "$line" ] || { echo "FAIL: no rendered-total line in $METR_LOGS/render-$lang.log" >&2; exit 1; }
  p="$(echo "$line" | sed -E 's/.*panel=([0-9]+).*/\1/')"
  w="$(echo "$line" | sed -E 's/.*welcome=([0-9]+).*/\1/')"
  panel_sum=$((panel_sum + p))
  welcome_sum=$((welcome_sum + w))
done

count="$(find "$DIR" -name 'panel-*.png' -size +0 | wc -l | tr -d ' ')"
[ "$count" = "$panel_sum" ] || { echo "FAIL: renderer logged $panel_sum panel PNGs but $DIR holds $count" >&2; exit 1; }
[ "$panel_sum" -ge 12 ] || { echo "FAIL: expected at least 12 panel PNGs, the renderer wrote $panel_sum" >&2; exit 1; }

welcome="$(find "$DIR" -name 'welcome-*.png' -size +0 | wc -l | tr -d ' ')"
[ "$welcome" = "$welcome_sum" ] || { echo "FAIL: renderer logged $welcome_sum welcome PNGs but $DIR holds $welcome" >&2; exit 1; }
[ "$welcome_sum" = "8" ] || { echo "FAIL: expected exactly 8 welcome PNGs, the renderer wrote $welcome_sum" >&2; exit 1; }

echo "RENDER-SNAPSHOTS OK dir=$DIR panel=$count welcome=$welcome"
