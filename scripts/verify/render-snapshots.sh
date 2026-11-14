#!/usr/bin/env bash
# Usage: scripts/verify/render-snapshots.sh
# Launches the Debug app twice (EN, ES) with METR_DEBUG_RENDER_DIR set, so it renders every panel
# fixture (idle, stress, elevated, ...), the welcome window (default and fallback tip) and the Metr
# window's detail column (CPU fixtures, 03-03) in light and dark to PNG files and exits.
# Data-driven: the renderer logs "rendered-total panel=<n> welcome=<m> window=<w> settings=<s>" per language run.
# The gate fails when that line is missing, when the PNGs on disk differ from the logged totals, when
# fewer than 12 panel PNGs exist, when the welcome count is not exactly 8, when fewer than
# WINDOW_MIN window PNGs exist (the whole window matrix: 29 fixtures x 2 schemes x 2 languages = 116,
# 03-15) or when a window PNG is under 680 x 520 pt.
# Settings (04-03): the real Settings view in an off-screen window, 6 states (off, on, approval, failure,
# energysaver, location) x 2 schemes x 2 languages = exactly 24 settings-*.png. Each is exactly 480 pt
# wide and at most 360 pt tall (UI-SPEC tallest-state ceiling; exactly 360 passes), and the logged
# `fitting` height equals the PNG height (the window never scrolls or clips).
# Window PNGs are the detail column of the real window (assumption A7: the full NavigationSplitView
# window does not draw off screen), so their floor is the minimum window 900 x 520 minus the 220 pt
# sidebar. The 700 pt ceiling below applies to panel-*.png only.
# Height gate (UI-SPEC "Height budget"): every panel PNG is at most 700 pt tall (pixelHeight / 2, the
# renderer draws at scale 2), except panel-*-apps-partial-confirm-*.png (the partial notice, a group open
# and a Force Quit confirmation) which may reach 720 pt. The collapsed Top Apps list
# (panel-*-apps-{light,dark}.png and panel-*-apps-partial-{light,dark}.png, the latter with its 20 pt
# notice, 579 pt expected) is at most 583 pt: the budget plus the margin past which a taller list is a
# layout bug.
# Prints "RENDER-SNAPSHOTS OK dir=<path> panel=<n> welcome=<m> window=<w> window_min=<k> max_height=<pt> settings=<s>".
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

# The window matrix: one PNG per fixture, scheme and language. Raise it when a fixture is added; the
# gate then notices a renderer that silently drops fixtures.
WINDOW_MIN=116

DIR="$METR_PREVIEWS/snapshots"
mkdir -p "$DIR"
rm -f "$DIR"/panel-*.png "$DIR"/welcome-*.png "$DIR"/window-*.png "$DIR"/settings-*.png

bash scripts/verify/run-debug.sh 60 render-en \
  --env "METR_DEBUG_RENDER_DIR=$DIR" \
  --expect 'rendered-total panel=[0-9]+ welcome=[0-9]+ window=[0-9]+ settings=[0-9]+' \
  --args -AppleLanguages '(en)' -AppleLocale en_US -MetrDidPresentWelcome YES

bash scripts/verify/run-debug.sh 60 render-es \
  --env "METR_DEBUG_RENDER_DIR=$DIR" \
  --expect 'rendered-total panel=[0-9]+ welcome=[0-9]+ window=[0-9]+ settings=[0-9]+' \
  --args -AppleLanguages '(es)' -AppleLocale es_ES -MetrDidPresentWelcome YES

panel_sum=0
welcome_sum=0
window_sum=0
settings_sum=0
for lang in en es; do
  line="$(grep -E 'rendered-total panel=[0-9]+ welcome=[0-9]+ window=[0-9]+ settings=[0-9]+' "$METR_LOGS/render-$lang.log" | tail -n 1 || true)"
  [ -n "$line" ] || { echo "FAIL: no rendered-total line in $METR_LOGS/render-$lang.log" >&2; exit 1; }
  p="$(echo "$line" | sed -E 's/.*panel=([0-9]+).*/\1/')"
  w="$(echo "$line" | sed -E 's/.*welcome=([0-9]+).*/\1/')"
  win="$(echo "$line" | sed -E 's/.*window=([0-9]+).*/\1/')"
  panel_sum=$((panel_sum + p))
  welcome_sum=$((welcome_sum + w))
  window_sum=$((window_sum + win))
  st="$(echo "$line" | sed -E 's/.*settings=([0-9]+).*/\1/')"
  settings_sum=$((settings_sum + st))
done

count="$(find "$DIR" -name 'panel-*.png' -size +0 | wc -l | tr -d ' ')"
[ "$count" = "$panel_sum" ] || { echo "FAIL: renderer logged $panel_sum panel PNGs but $DIR holds $count" >&2; exit 1; }
[ "$panel_sum" -ge 12 ] || { echo "FAIL: expected at least 12 panel PNGs, the renderer wrote $panel_sum" >&2; exit 1; }

welcome="$(find "$DIR" -name 'welcome-*.png' -size +0 | wc -l | tr -d ' ')"
[ "$welcome" = "$welcome_sum" ] || { echo "FAIL: renderer logged $welcome_sum welcome PNGs but $DIR holds $welcome" >&2; exit 1; }
[ "$welcome_sum" = "8" ] || { echo "FAIL: expected exactly 8 welcome PNGs, the renderer wrote $welcome_sum" >&2; exit 1; }

window="$(find "$DIR" -name 'window-*.png' -size +0 | wc -l | tr -d ' ')"
[ "$window" = "$window_sum" ] || { echo "FAIL: renderer logged $window_sum window PNGs but $DIR holds $window" >&2; exit 1; }
[ "$window_sum" -ge "$WINDOW_MIN" ] || { echo "FAIL: expected at least $WINDOW_MIN window PNGs (the whole matrix), the renderer wrote $window_sum" >&2; exit 1; }

settings="$(find "$DIR" -name 'settings-*.png' -size +0 | wc -l | tr -d ' ')"
[ "$settings" = "$settings_sum" ] || { echo "FAIL: renderer logged $settings_sum settings PNGs but $DIR holds $settings" >&2; exit 1; }
[ "$settings_sum" = "24" ] || { echo "FAIL: expected exactly 24 settings PNGs, the renderer wrote $settings_sum" >&2; exit 1; }

# Settings size gate: 480 pt wide, at most 360 pt tall, and the host's fitting height equals the frame.
SETTINGS_MAX=360
settings_tallest=0
for lang in en es; do
  for f in "$DIR"/settings-$lang-*.png; do
    base="$(basename "$f")"
    wpx="$(sips -g pixelWidth "$f" | awk '/pixelWidth/ {print $2}')"
    hpx="$(sips -g pixelHeight "$f" | awk '/pixelHeight/ {print $2}')"
    [ -n "$wpx" ] && [ -n "$hpx" ] || { echo "FAIL: could not read the size of $f" >&2; exit 1; }
    [ $(( wpx / 2 )) -eq 480 ] || { echo "FAIL: $base is $(( wpx / 2 )) pt wide, expected 480" >&2; exit 1; }
    pt=$(( (hpx + 1) / 2 ))
    [ "$pt" -le "$SETTINGS_MAX" ] || { echo "FAIL: $base is $pt pt tall, over the $SETTINGS_MAX pt ceiling" >&2; exit 1; }
    [ "$pt" -le "$settings_tallest" ] || settings_tallest="$pt"
    entry="$(grep -E "rendered $base " "$METR_LOGS/render-$lang.log" | tail -n 1 || true)"
    [ -n "$entry" ] || { echo "FAIL: no render log line for $base" >&2; exit 1; }
    frame="$(echo "$entry" | sed -E 's/.* height=([0-9]+) .*/\1/')"
    fitting="$(echo "$entry" | sed -E 's/.* fitting=([0-9]+).*/\1/')"
    [ "$frame" = "$fitting" ] || { echo "FAIL: $base frame height $frame differs from its fitting height $fitting (the window would scroll or clip)" >&2; exit 1; }
    echo "settings $base height=$pt"
  done
done

# Increase Contrast must reach SwiftUI's environment in the high-contrast fixtures (3 fixtures x 2
# schemes per language) and in no other fixture: the renderer logs what each rendered view read.
for lang in en es; do
  raised="$(grep -Ec 'render contrast=increased fixture=(cpu|memory|disk)-contrast' "$METR_LOGS/render-$lang.log" || true)"
  stray="$(grep -E 'render contrast=increased' "$METR_LOGS/render-$lang.log" | grep -Evc 'fixture=(cpu|memory|disk)-contrast' || true)"
  [ "$raised" = "6" ] || { echo "FAIL: $lang run: $raised high-contrast renders read Increase Contrast, expected 6" >&2; exit 1; }
  [ "$stray" = "0" ] || { echo "FAIL: $lang run: $stray other renders read Increase Contrast" >&2; exit 1; }
done

# Window size floor (detail column of the 900 x 520 minimum window). `sips` reports pixels, scale 2.
for f in "$DIR"/window-*.png; do
  wpx="$(sips -g pixelWidth "$f" | awk '/pixelWidth/ {print $2}')"
  hpx="$(sips -g pixelHeight "$f" | awk '/pixelHeight/ {print $2}')"
  [ -n "$wpx" ] && [ -n "$hpx" ] || { echo "FAIL: could not read the size of $f" >&2; exit 1; }
  if [ $(( wpx / 2 )) -lt 680 ] || [ $(( hpx / 2 )) -lt 520 ]; then
    echo "FAIL: $(basename "$f") is $(( wpx / 2 )) x $(( hpx / 2 )) pt, under the 680 x 520 floor" >&2
    exit 1
  fi
done

# Height ceiling. `sips` reports pixels; the images are drawn at scale 2.
CEILING=700
CONFIRM_CEILING=720
COLLAPSED_BUDGET=583
max_height=0
for f in "$DIR"/panel-*.png; do
  px="$(sips -g pixelHeight "$f" | awk '/pixelHeight/ {print $2}')"
  [ -n "$px" ] || { echo "FAIL: could not read pixelHeight of $f" >&2; exit 1; }
  pt=$(( (px + 1) / 2 ))
  [ "$pt" -le "$max_height" ] || max_height="$pt"
  limit="$CEILING"
  case "$(basename "$f")" in
    panel-*-apps-partial-confirm-*.png) limit="$CONFIRM_CEILING" ;;
  esac
  if [ "$pt" -gt "$limit" ]; then
    echo "FAIL: $(basename "$f") is $pt pt, over the $limit pt ceiling" >&2
    exit 1
  fi
  case "$(basename "$f")" in
    panel-*-apps-light.png|panel-*-apps-dark.png|panel-*-apps-partial-light.png|panel-*-apps-partial-dark.png)
      if [ "$pt" -gt "$COLLAPSED_BUDGET" ]; then
        echo "FAIL: $(basename "$f") is $pt pt, over the $COLLAPSED_BUDGET pt collapsed-list budget" >&2
        exit 1
      fi ;;
  esac
done

echo "RENDER-SNAPSHOTS OK dir=$DIR panel=$count welcome=$welcome window=$window window_min=$WINDOW_MIN max_height=$max_height settings=$settings settings_max_height=$settings_tallest"
