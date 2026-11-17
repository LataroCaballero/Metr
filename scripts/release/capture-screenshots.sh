#!/usr/bin/env bash
# Usage: scripts/release/capture-screenshots.sh panel|light|dark [--out DIR] [--dry-run]
#        scripts/release/capture-screenshots.sh audit rt-light|rt-dark|ic-light|ic-dark [--out DIR] [--dry-run]
#        scripts/release/capture-screenshots.sh l10n [--out DIR] [--dry-run]
#
# Produces the README images and the evidence captures from DEMO DATA (D-18, T-04-23): the Debug app runs
# with METR_DEBUG_DEMO=1, so the real menu bar item, panel and window show fixture data (Safari, Finder,
# Notes, Terminal, Music, ...) and never a process, volume or name of this Mac. The Disk section is never
# captured. Everything is written under --out and nowhere else (logs go to $METR_LOGS).
#
#   panel   copies the render harness's `readme` panel fixture (scripts/verify/render-snapshots.sh) to
#           <out>/<lang>/panel-<scheme>.png for en and es, light and dark (4 files; panel is 640 px wide)
#   light / dark
#           needs the system appearance to match. For each language runs the demo app and captures the real
#           window on CPU and on Processes (<out>/<lang>/window-cpu-<scheme>.png, window-processes-<scheme>.png,
#           2000 x 1280 px) and, in the English run, the menu bar close-up (<out>/menubar-<scheme>.png: 480 x
#           80 pt from 24 pt left of the rings, so about 960 x 160 px; the owner's neighbouring menu bar items
#           can fall in it, so 04-11 reviews it before commit). 5 files
#   audit LABEL
#           (04-11 accessibility evidence) English only, demo data: the real popover, Settings window and main
#           window on CPU and Processes in whatever appearance and accessibility state the system is in now.
#           The appearance half of LABEL must match; reduceTransparency (rt-*) or increaseContrast (ic-*) must
#           read 1 when readable. Writes <out>/<surface>-<LABEL>.png for panel, settings, window-cpu,
#           window-processes (4 files; default out is the git-ignored audit directory of the phase)
#   l10n    (UI-SPEC L10N-01 gate 3) the surfaces the render harness cannot draw, in en and es, in the current
#           appearance: the About panel and the right-click menu from the demo app, the move-to-Applications
#           offer and its failure alert from a copy of the app outside every development path. Writes
#           <out>/about-<lang>.png, menu-<lang>.png, move-<lang>.png, move-<lang>-failure.png (8 files, the
#           language is always the second dash-separated field, as 04-06's l10n-render.sh --dir expects). The
#           alerts only show: nothing is moved, and only the `.script` preferences suite is touched (deleted on exit)
#
# --dry-run runs the same launches and window discovery, skips the appearance and accessibility checks and
# Screen Recording, captures nothing and prints one `CAPTURE TARGET <file>` line per target (path relative
# to <out>) and `CAPTURE DRY-RUN mode=<m> targets=<n>`.
# Prints `CAPTURE OK mode=<m> files=<n>` (mode is audit-<LABEL> for audit) or `FAIL: <reason>` with exit 1.
# Every PNG for the README is held to 400 KB (it fails naming the file); metadata is stripped with sips.
# Real captures need Screen Recording permission for the terminal and an active, unlocked desktop.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh
# shellcheck source=../perf/lib.sh
source scripts/perf/lib.sh

fail() { echo "FAIL: $1" >&2; exit 1; }
usage() {
  echo "usage: capture-screenshots.sh panel|light|dark|l10n | audit rt-light|rt-dark|ic-light|ic-dark  [--out DIR] [--dry-run]" >&2
  exit 2
}

SUITE="io.github.latarocaballero.Metr.script"
MODE="${1:-}"; [ -n "$MODE" ] || usage; shift
LABEL=""
case "$MODE" in
  panel|light|dark|l10n) ;;
  audit)
    LABEL="${1:-}"; [ -n "$LABEL" ] || usage; shift
    case "$LABEL" in rt-light|rt-dark|ic-light|ic-dark) ;; *) usage ;; esac ;;
  *) usage ;;
esac
OUT=""
DRY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) [ "$#" -ge 2 ] || usage; OUT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) usage ;;
  esac
done
if [ -z "$OUT" ]; then
  case "$MODE" in
    audit) OUT="$METR_ROOT/.planning/phases/04-native-polish-and-public-release/audit" ;;
    l10n) OUT="$METR_ROOT/.planning/phases/04-native-polish-and-public-release/audit/l10n" ;;
    *) OUT="$METR_ROOT/docs/screenshots" ;;
  esac
fi
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac

MODE_NAME="$MODE"; [ "$MODE" != "audit" ] || MODE_NAME="audit-$LABEL"
mkdir -p "$METR_LOGS"

# ------------------------------------------------------------------------------------------ cleanup

TMPDIRS=()
cleanup() {
  metr_kill >/dev/null 2>&1 || true
  local d
  for d in ${TMPDIRS[@]+"${TMPDIRS[@]}"}; do [ -n "$d" ] && [ -e "$d" ] && rm -rf "$d"; done
  defaults delete "$SUITE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ----------------------------------------------------------------------------------- window listing

WL="$METR_BUILD_ROOT/bin/window-list"
build_window_list() {
  local src="$METR_ROOT/scripts/release/window-list.swift"
  if [ ! -x "$WL" ] || [ "$src" -nt "$WL" ]; then
    mkdir -p "$METR_BUILD_ROOT/bin"
    swiftc -O -o "$WL" "$src" >&2 || fail "could not compile window-list.swift"
  fi
}
build_window_list

# Lines "id<TAB>layer<TAB>w<TAB>h" of the on-screen windows owned by pid $1 (bounds split into w and h).
windows_of() {
  "$WL" | awk -F'\t' -v p="$1" '$4 == p { split($3, b, ","); print $1 "\t" $2 "\t" b[3] "\t" b[4] }'
}

# The id of the largest window of pid $1 that is not in the id file $2 and is at least $3 x $4 pt (empty
# when there is none). Prints "id layer w h".
new_window() {
  local pid="$1" seen="$2" minw="$3" minh="$4"
  windows_of "$pid" | awk -F'\t' -v seen="$seen" -v mw="$minw" -v mh="$minh" '
    BEGIN { while ((getline line < seen) > 0) known[line] = 1 }
    !($1 in known) && $3 >= mw && $4 >= mh { area = $3 * $4; if (area > best) { best = area; out = $1 " " $2 " " $3 " " $4 } }
    END { if (out != "") print out }'
}

# Records every window id of pid $1 in the file $2.
remember_windows() { windows_of "$1" | cut -f1 > "$2"; }

# The real main window of pid $1: layer 0 and at least 800 x 500 pt. Prints "id w h".
main_window() {
  windows_of "$1" | awk -F'\t' '$2 == 0 && $3 >= 800 && $4 >= 500 { print $1 " " $3 " " $4; exit }'
}

# Ids of on-screen status item windows (layer 25), one per line.
layer25_ids() { "$WL" | awk -F'\t' '$2 == 25 { print $1 }' | sort; }

# ----------------------------------------------------------------------------------------- launching

APP="$METR_APP_DEBUG"
PID=""
LAST_LOG=""

wait_log() {
  local log="$1" re="$2" secs="$3" i
  for i in $(seq 1 $((secs * 5))); do
    grep -Eq -- "$re" "$log" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

# launch_app APP LANG LOGNAME [KEY=VALUE]...: starts the app (in front, so its windows look active), with
# the language and locale arguments, the welcome window suppressed and the log hook. Sets PID and LAST_LOG.
launch_app() {
  local app="$1" lang="$2" name="$3"; shift 3
  local locale="en_US"; [ "$lang" != "es" ] || locale="es_ES"
  LAST_LOG="$METR_LOGS/$name.log"
  : > "$LAST_LOG"
  local args=(-n --env "METR_DEBUG_LOG=$LAST_LOG") e
  for e in "$@"; do args+=(--env "$e"); done
  metr_kill
  open "${args[@]}" "$app" --args -AppleLanguages "($lang)" -AppleLocale "$locale" -MetrDidPresentWelcome YES
  local i
  PID=""
  for i in $(seq 1 60); do
    PID="$(metr_pid "$app")"
    [ -z "$PID" ] || return 0
    sleep 0.2
  done
  fail "Metr did not start from $app"
}

# Sleeps until $2 seconds after the epoch second $1.
sleep_until() {
  local remaining=$(( $2 - ($(date +%s) - $1) ))
  [ "$remaining" -le 0 ] || sleep "$remaining"
}

# ----------------------------------------------------------------------------------------- captures

FILES=0
TARGETS=0

# Pixel size of a PNG as "w h".
png_size() {
  local w h
  w="$(sips -g pixelWidth "$1" | awk '/pixelWidth/ {print $2}')"
  h="$(sips -g pixelHeight "$1" | awk '/pixelHeight/ {print $2}')"
  [ -n "$w" ] && [ -n "$h" ] || fail "could not read the size of $1"
  echo "$w $h"
}

# check_png FILE KIND: strips metadata and asserts the size. KIND: window (2000 x 1280), hero (about 960 x
# 160), panel (640 wide), any (non-empty). README kinds also hold the 400 KB cap.
check_png() {
  local file="$1" kind="$2" w h kb
  [ -s "$file" ] || fail "$file was not written (is Screen Recording allowed for this terminal?)"
  sips -s format png "$file" --out "$file.tmp" >/dev/null 2>&1 && mv "$file.tmp" "$file" || rm -f "$file.tmp"
  read -r w h < <(png_size "$file")
  case "$kind" in
    window) [ "$w" = "2000" ] && [ "$h" = "1280" ] || fail "$file is ${w} x ${h} px, expected 2000 x 1280 (is the display scaled at 2x?)" ;;
    hero) [ "$w" -ge 900 ] && [ "$w" -le 1020 ] && [ "$h" -ge 140 ] && [ "$h" -le 180 ] || fail "$file is ${w} x ${h} px, expected about 960 x 160" ;;
    panel) [ "$w" = "640" ] || fail "$file is ${w} px wide, expected 640" ;;
    any) ;;
  esac
  case "$kind" in
    window|hero|panel)
      kb=$(( ($(stat -f %z "$file") + 1023) / 1024 ))
      [ "$kb" -le 400 ] || fail "$file is $kb KB, over 400 KB" ;;
  esac
}

# target REL: announces one target (counted in dry runs and real ones).
target() {
  TARGETS=$((TARGETS + 1))
  [ "$DRY" = "0" ] || echo "CAPTURE TARGET $1"
}

# shoot_window ID REL KIND: captures window ID into <out>/REL (a dry run only announces it).
shoot_window() {
  local id="$1" rel="$2" kind="$3"
  target "$rel"
  [ "$DRY" = "0" ] || return 0
  mkdir -p "$(dirname "$OUT/$rel")"
  screencapture -x -o -l "$id" "$OUT/$rel"
  check_png "$OUT/$rel" "$kind"
  FILES=$((FILES + 1))
  echo "CAPTURED $rel"
}

# ------------------------------------------------------------------------------------ appearance gates

system_appearance() {
  if [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null || true)" = "Dark" ]; then echo dark; else echo light; fi
}

require_appearance() {
  [ "$DRY" = "0" ] || return 0
  local want="$1" now
  now="$(system_appearance)"
  [ "$now" = "$want" ] || fail "the system appearance is $now, this capture needs $want (System Settings > Appearance)"
}

require_accessibility() {
  [ "$DRY" = "0" ] || return 0
  local key value
  case "$1" in rt-*) key=reduceTransparency ;; ic-*) key=increaseContrast ;; esac
  if value="$(defaults read com.apple.universalaccess "$key" 2>/dev/null)"; then
    [ "$value" = "1" ] || fail "$key reads $value, label $1 needs it on (System Settings > Accessibility > Display)"
  else
    echo "CAPTURE NOTE accessibility state not readable, label trusted"
  fi
}

# ------------------------------------------------------------------------------------------- panel

mode_panel() {
  local lang scheme
  if [ "$DRY" = "1" ]; then
    for lang in en es; do for scheme in light dark; do target "$lang/panel-$scheme.png"; done; done
    return 0
  fi
  [ -d "$APP" ] || fail "Debug app not found at $APP (run scripts/build.sh debug)"
  bash scripts/verify/render-snapshots.sh >/dev/null || fail "render-snapshots.sh failed"
  for lang in en es; do
    for scheme in light dark; do
      local src="$METR_PREVIEWS/snapshots/panel-$lang-readme-$scheme.png"
      [ -s "$src" ] || fail "the harness did not write $src"
      mkdir -p "$OUT/$lang"
      cp "$src" "$OUT/$lang/panel-$scheme.png"
      target "$lang/panel-$scheme.png"
      check_png "$OUT/$lang/panel-$scheme.png" panel
      FILES=$((FILES + 1))
    done
  done
}

# ------------------------------------------------------------------------------------ light and dark

mode_scheme() {
  local scheme="$MODE" lang before after waited
  [ -d "$APP" ] || fail "Debug app not found at $APP (run scripts/build.sh debug)"
  require_appearance "$scheme"
  for lang in en es; do
    before=""
    [ "$lang" != "en" ] || before="$(layer25_ids)"
    launch_app "$APP" "$lang" "capture-$scheme-$lang" METR_DEBUG_DEMO=1 \
      "METR_DEBUG_WINDOW_SCRIPT=cpu@7;processes@14"
    local started
    started="$(date +%s)"
    if [ "$lang" = "en" ]; then
      # The hero: the status item is the new on-screen layer-25 window; capture it before the window opens.
      local item="" i
      for i in $(seq 1 40); do
        after="$(layer25_ids)"
        item="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -n 1)"
        [ -z "$item" ] || break
        sleep 0.25
      done
      [ -n "$item" ] || fail "the status item never appeared as a new layer-25 window (is Metr turned on in System Settings > Menu Bar?)"
      sleep 1
      local bounds x
      bounds="$("$WL" | awk -F'\t' -v id="$item" '$1 == id { print $3 }')"
      [ -n "$bounds" ] || fail "the status item window $item has no bounds"
      x="${bounds%%,*}"
      target "menubar-$scheme.png"
      if [ "$DRY" = "0" ]; then
        local left=$(( x - 24 )); [ "$left" -ge 0 ] || left=0
        mkdir -p "$OUT"
        screencapture -x -R "$left,0,480,80" "$OUT/menubar-$scheme.png"
        check_png "$OUT/menubar-$scheme.png" hero
        FILES=$((FILES + 1))
        echo "CAPTURED menubar-$scheme.png"
      fi
    fi
    local win
    wait_log "$LAST_LOG" 'window shown section=cpu' 25 || fail "the window never showed CPU (LOG=$LAST_LOG)"
    sleep_until "$started" 10
    win=""
    for waited in $(seq 1 20); do win="$(main_window "$PID")"; [ -z "$win" ] || break; sleep 0.25; done
    [ -n "$win" ] || fail "no main window of pid $PID (LOG=$LAST_LOG)"
    shoot_window "${win%% *}" "$lang/window-cpu-$scheme.png" window
    wait_log "$LAST_LOG" 'window shown section=processes' 25 || fail "the window never showed Processes (LOG=$LAST_LOG)"
    sleep_until "$started" 17
    win="$(main_window "$PID")"
    [ -n "$win" ] || fail "no main window of pid $PID on Processes (LOG=$LAST_LOG)"
    shoot_window "${win%% *}" "$lang/window-processes-$scheme.png" window
    metr_kill
  done
}

# ---------------------------------------------------------------------------------------------- audit

mode_audit() {
  local scheme="${LABEL#*-}"
  [ -d "$APP" ] || fail "Debug app not found at $APP (run scripts/build.sh debug)"
  require_appearance "$scheme"
  require_accessibility "$LABEL"
  launch_app "$APP" en "capture-audit-$LABEL" METR_DEBUG_DEMO=1 \
    "METR_DEBUG_WINDOW_SCRIPT=panel@3;settings@9;cpu@15;processes@22"
  local started seen found win
  started="$(date +%s)"
  seen="$(mktemp "${TMPDIR:-/tmp}/metr-capture-seen.XXXXXX")"
  TMPDIRS+=("$seen")
  remember_windows "$PID" "$seen"

  sleep_until "$started" 6
  found="$(new_window "$PID" "$seen" 100 100)"
  [ -n "$found" ] || fail "no popover window appeared after the panel step (LOG=$LAST_LOG)"
  shoot_window "${found%% *}" "panel-$LABEL.png" any
  remember_windows "$PID" "$seen"

  sleep_until "$started" 12
  found="$(new_window "$PID" "$seen" 300 150)"
  [ -n "$found" ] || fail "no Settings window appeared after the settings step (LOG=$LAST_LOG)"
  shoot_window "${found%% *}" "settings-$LABEL.png" any
  remember_windows "$PID" "$seen"

  sleep_until "$started" 19
  win="$(main_window "$PID")"
  [ -n "$win" ] || fail "no main window after the cpu step (LOG=$LAST_LOG)"
  shoot_window "${win%% *}" "window-cpu-$LABEL.png" any

  sleep_until "$started" 26
  win="$(main_window "$PID")"
  [ -n "$win" ] || fail "no main window after the processes step (LOG=$LAST_LOG)"
  shoot_window "${win%% *}" "window-processes-$LABEL.png" any
  metr_kill
}

# ---------------------------------------------------------------------------------------------- l10n

mode_l10n() {
  [ -d "$APP" ] || fail "Debug app not found at $APP (run scripts/build.sh debug)"
  local lang started seen found work copy dest
  for lang in en es; do
    # (a) About panel and right-click menu, from the demo app.
    launch_app "$APP" "$lang" "capture-l10n-$lang" METR_DEBUG_DEMO=1 "METR_DEBUG_WINDOW_SCRIPT=about@3;menu@9"
    started="$(date +%s)"
    seen="$(mktemp "${TMPDIR:-/tmp}/metr-capture-seen.XXXXXX")"
    TMPDIRS+=("$seen")
    remember_windows "$PID" "$seen"
    sleep_until "$started" 6
    found="$(new_window "$PID" "$seen" 150 100)"
    [ -n "$found" ] || fail "no About window appeared ($lang, LOG=$LAST_LOG)"
    shoot_window "${found%% *}" "about-$lang.png" any
    remember_windows "$PID" "$seen"
    sleep_until "$started" 11
    found="$(new_window "$PID" "$seen" 100 60)"
    [ -n "$found" ] || fail "no menu window appeared ($lang, LOG=$LAST_LOG)"
    echo "CAPTURE NOTE menu-$lang window layer=$(printf '%s' "$found" | cut -d' ' -f2)"
    shoot_window "${found%% *}" "menu-$lang.png" any
    metr_kill

    # (b) and (c): the move offer and its failure alert, from a copy outside every development path.
    work="$(mktemp -d "${TMPDIR:-/tmp}/metr-capture-XXXXXX")"
    TMPDIRS+=("$work")
    work="$(cd "$work" && pwd -P)"   # the process list shows the resolved path
    copy="$work/Metr.app"
    ditto "$APP" "$copy"
    dest="$(mktemp -d "${TMPDIR:-/tmp}/metr-capture-dest-XXXXXX")"
    TMPDIRS+=("$dest")
    local confirm kind rel
    for confirm in present present-failure; do
      if [ "$confirm" = "present" ]; then kind=offer; rel="move-$lang.png"; else kind=failure; rel="move-$lang-failure.png"; fi
      launch_app "$copy" "$lang" "capture-l10n-$lang-$confirm" \
        "METR_DEBUG_MOVE_DESTINATION=$dest" "METR_DEBUG_MOVE_CONFIRM=$confirm"
      wait_log "$LAST_LOG" "move alert shown kind=$kind" 20 || fail "no 'move alert shown kind=$kind' line ($lang, LOG=$LAST_LOG)"
      sleep 1.5
      : > "$seen"
      found="$(new_window "$PID" "$seen" 150 80)"
      [ -n "$found" ] || fail "the $kind alert has no window ($lang, LOG=$LAST_LOG)"
      shoot_window "${found%% *}" "$rel" any
      metr_kill
      [ -z "$(ls -A "$dest")" ] || fail "something was written to the move destination ($lang, $confirm)"
    done
    rm -rf "$work" "$dest"
  done
}

case "$MODE" in
  panel) mode_panel ;;
  light|dark) mode_scheme ;;
  audit) mode_audit ;;
  l10n) mode_l10n ;;
esac

if [ "$DRY" = "1" ]; then
  echo "CAPTURE DRY-RUN mode=$MODE_NAME targets=$TARGETS"
else
  echo "CAPTURE OK mode=$MODE_NAME files=$FILES"
fi
