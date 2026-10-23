#!/usr/bin/env bash
# Usage: scripts/spikes/login-item.sh
# ROADMAP Phase 1 spike for Phase 4 (SET-01): what SMAppService.mainApp does for an ad-hoc signed
# Metr that lives in /Applications. Installs a temporary copy of the Debug app, runs register,
# status, unregister, status (one launch each, through the DEBUG-only METR_DEBUG_LOGIN_ITEM hook),
# then unregisters again and removes the copy, always (trap).
#
# Prints "LOGIN-ITEM-SPIKE register_status=<n> status_after_register=<n> status_after_unregister=<n>
# errors=<summary>" and "LOGIN-ITEM-SPIKE DONE". Raw status: 0 notRegistered, 1 enabled,
# 2 requiresApproval, 3 notFound. Exit 0 when all four ops were logged and the cleanup worked,
# whatever the outcome (the outcome is data); exit 1 otherwise.
set -euo pipefail

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

ditto "$METR_APP_DEBUG" "$DEST"
INSTALLED=1
echo "SIGNATURE: $(codesign -dv "$DEST" 2>&1 | grep -E '^(Signature|CDHash|TeamIdentifier)' | tr '\n' ' ')"

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
