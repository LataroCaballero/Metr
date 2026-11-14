#!/usr/bin/env bash
# Usage: scripts/spikes/login-item.sh [--settings]
# ROADMAP Phase 1 spike for Phase 4 (SET-01): what SMAppService.mainApp does for an ad-hoc signed
# Metr that lives in /Applications. Installs a temporary copy of the Debug app, runs register,
# status, unregister, status (one launch each, through the DEBUG-only METR_DEBUG_LOGIN_ITEM hook),
# then unregisters again and removes the copy, always (trap).
#
# Prints "LOGIN-ITEM-SPIKE register_status=<n> status_after_register=<n> status_after_unregister=<n>
# errors=<summary>" and "LOGIN-ITEM-SPIKE DONE". Raw status: 0 notRegistered, 1 enabled,
# 2 requiresApproval, 3 notFound. Exit 0 when all four ops were logged and the cleanup worked,
# whatever the outcome (the outcome is data); exit 1 otherwise.
#
# --settings (04-03, SET-01): drives the Settings Open at login path (the `login:<on|off>` window-script
# step, which calls the same LoginItemModel.setEnabled the switch calls) instead of the raw spike hook.
# First one launch of the Debug app where it was built, outside /Applications (D-13: the request must
# be refused, nothing registered), printing
#   LOGIN-ITEM-ELSEWHERE status=<raw> shown=<on|off> message=<m>
# then, on the temporary /Applications copy, on / on again / off / off again / on then off 0.1 s apart:
#   LOGIN-ITEM-SETTINGS on=<raw> on_again=<raw> off=<raw> off_again=<raw> fast=<raw>
#   LOGIN-ITEM-SETTINGS DONE
# plus an informational count of `sfltool dumpbtm` lines naming the bundle identifier (assumption A10).
# Same refusal, same cleanup (final unregister, copy removed, the .script preferences suite deleted).
set -euo pipefail

MODE="spike"
case "${1:-}" in
  "") ;;
  --settings) MODE="settings" ;;
  *) echo "FAIL: unknown argument '$1'"; exit 1 ;;
esac

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

DEST="/Applications/Metr.app"
LOG="$METR_LOGS/login-item.log"
INSTALLED=0

fail() { echo "FAIL: $1"; exit 1; }

# Refuse to touch a real install: the precondition of T-01-18.
[ ! -e "$DEST" ] || fail "$DEST already exists; this spike never overwrites or removes a real install"

run_op() {
  local op="$1"
  open -g -n --env "METR_DEBUG_LOG=$LOG" --env "METR_DEBUG_LOGIN_ITEM=$op" "$DEST" \
    --args -MetrDidPresentWelcome YES
  sleep 5
  metr_kill
}

cleanup() {
  local rc=$?
  metr_kill || true
  if [ "$INSTALLED" = "1" ]; then
    # Final unregister attempt, so no login item outlives the spike.
    run_op unregister >/dev/null 2>&1 || true
    rm -rf /Applications/Metr.app
  fi
  defaults delete io.github.latarocaballero.Metr.script >/dev/null 2>&1 || true
  if [ -e "$DEST" ]; then
    echo "FAIL: $DEST is still present after cleanup"
    rc=1
  fi
  exit "$rc"
}

bash scripts/build.sh debug >/dev/null
[ -d "$METR_APP_DEBUG" ] || fail "Debug app not found at $METR_APP_DEBUG"

mkdir -p "$METR_LOGS"
: > "$LOG"
metr_kill
trap cleanup EXIT

if [ "$MODE" = "settings" ]; then
  # Outside /Applications first, before anything is copied there: the request must be refused.
  run_script() { # APP SCRIPT SECONDS
    open -g -n --env "METR_DEBUG_LOG=$LOG" --env "METR_DEBUG_WINDOW_SCRIPT=$2" "$1" \
      --args -MetrDidPresentWelcome YES
    sleep "$3"
    metr_kill
  }
  field() { # LINE FIELD
    printf '%s\n' "$1" | sed -E "s/.*[ ]$2=([^ ]*).*/\\1/"
  }
  run_script "$METR_APP_DEBUG" 'settings@1;login:on@3;settings-close@5' 8
  elsewhere="$(grep -E 'settings login request=' "$LOG" || true)"
  [ "$(printf '%s\n' "$elsewhere" | grep -c 'settings login request=' || true)" = "1" ] \
    || fail "expected one settings login line outside /Applications (log: $LOG)"
  printf '%s\n' "$elsewhere"
  echo "LOGIN-ITEM-ELSEWHERE status=$(field "$elsewhere" status) shown=$(field "$elsewhere" shown) message=$(field "$elsewhere" message)"
  : > "$LOG"
fi

ditto "$METR_APP_DEBUG" "$DEST"
INSTALLED=1
echo "SIGNATURE: $(codesign -dv "$DEST" 2>&1 | grep -E '^(Signature|CDHash|TeamIdentifier)' | tr '\n' ' ')"

if [ "$MODE" = "settings" ]; then
  run_script "$DEST" \
    'settings@1;login:on@3;login:on@5;login:off@7;login:off@9;login:on@11;login:off@11.1;settings-close@13' 16
  lines="$(grep -E 'settings login request=' "$LOG" || true)"
  printf '%s\n' "$lines"
  count="$(printf '%s\n' "$lines" | grep -c 'settings login request=' || true)"
  [ "$count" -eq 6 ] || fail "expected 6 settings login lines, found $count (log: $LOG)"
  grep -E 'settings login error=' "$LOG" || true
  nth() { printf '%s\n' "$lines" | sed -n "${1}p"; }
  # sfltool needs no root for the count; informational only (A10).
  btm="$(sfltool dumpbtm 2>/dev/null | grep -c 'io.github.latarocaballero.Metr' || true)"
  echo "LOGIN-ITEM-SETTINGS sfltool_lines=$btm (after the run, informational)"
  echo "LOGIN-ITEM-SETTINGS on=$(field "$(nth 1)" status) on_again=$(field "$(nth 2)" status) off=$(field "$(nth 3)" status) off_again=$(field "$(nth 4)" status) fast=$(field "$(nth 6)" status)"
  echo "LOGIN-ITEM-SETTINGS DONE"
  exit 0
fi

for op in register status unregister status; do
  run_op "$op"
done

# One "loginitem op=<op> status=<raw> error=<text>" line per launch, in order.
lines="$(grep -E 'loginitem op=' "$LOG" || true)"
count="$(printf '%s\n' "$lines" | grep -c 'loginitem op=' || true)"
printf '%s\n' "$lines"
[ "$count" -ge 4 ] || fail "expected 4 loginitem lines, found $count (log: $LOG)"

field() { # LINE_NUMBER FIELD
  printf '%s\n' "$lines" | sed -n "${1}p" | sed -E "s/.*[ ]$2=([^ ]*).*/\\1/"
}
register_status="$(field 1 status)"
status_after_register="$(field 2 status)"
status_after_unregister="$(field 4 status)"
errors="$({ printf '%s\n' "$lines" | sed -E 's/^[0-9.]+ //' | grep -v 'error=none$' || true; } | sed -E 's/loginitem op=([a-z]+) status=[0-9]+ error=/\1: /' | tr '\n' ';' | sed 's/;$//')"
[ -n "$errors" ] || errors="none"

echo "LOGIN-ITEM-SPIKE register_status=$register_status status_after_register=$status_after_register status_after_unregister=$status_after_unregister errors=$errors"
echo "LOGIN-ITEM-SPIKE DONE"
