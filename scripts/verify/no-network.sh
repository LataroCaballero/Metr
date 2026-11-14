#!/usr/bin/env bash
# Usage: scripts/verify/no-network.sh [app]                         static gate (default: $METR_APP_RELEASE)
#        scripts/verify/no-network.sh --self-test                    negative controls: the gate must FAIL them
#        scripts/verify/no-network.sh --runtime [--release APP] [--relhooks APP]
# DIST-04 / D-15: Metr makes no network connection, proven twice.
#
# Static (on the executable <app>/Contents/MacOS/Metr only, never on the system frameworks it links):
#   - otool -L lists none of the Network, CFNetwork, NetworkExtension or WebKit frameworks;
#   - nm -u imports none of the BSD socket, name lookup, CFSocket / CFStream / CFHost / CFNetwork, nw_,
#     URL session and URL connection, Network.framework or SystemConfiguration reachability and
#     network-connection symbols. The five SCDynamicStore / SCNetworkInterface calls NetworkCollector uses
#     read local configuration and open no socket: they are allowed, and the SystemConfiguration framework
#     is deliberately not banned as a whole;
#   - every http(s) URL literal in the executable is a github.com/LataroCaballero/Metr link or an exact
#     entry of URL_ALLOW below (a non-request identifier, each with its reason). Apple domains are not
#     allow-listed as a whole: a request target at apple.com would still fail.
# Prints "SCANNED undefined_symbols=<n>" and "NO-NETWORK OK libs=0 symbols=0 urls=<n> allowed=<n>",
# or "FAIL: <what>" with exit 1.
#
# --self-test builds two throwaway programs in a temporary directory (one uses URLSession, one uses
# Network.framework), runs the static checks on them and prints "NO-NETWORK SELF-TEST OK" only when they
# FAIL both (each for its own reason) and the real app passes.
#
# --runtime (defaults $METR_APP_RELEASE and $METR_APP_RELHOOKS; both must exist):
#   (a) idle, on the Release app, launched exactly as users launch it (no hooks, no window script): at 4 s
#       and 10 s `lsof -a -i -p <pid>` shows no Internet socket and `nettop -P -L 1 -p <pid>` shows no data
#       row; its CDHash is recorded as idle_cdhash;
#   (b) Processes open, on the relhooks app (Release optimization with the DEBUG hooks, the only build a
#       script can drive to open a window): the static checks first run on its binary, then the window
#       script opens Processes at 1 s and closes at 14 s, and at 4 s and 10 s lsof and nettop are checked
#       for Metr and for its top child. The top child must be seen at least once, so the check cannot pass
#       by looking at nothing.
# Prints "NO-NETWORK RUNTIME OK idle=0 processes=0 idle_cdhash=<40 hex> processes_build=relhooks".
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh
# shellcheck source=../perf/lib.sh
source scripts/perf/lib.sh

fail() { echo "FAIL: $1"; exit 1; }

# Literals are split so that this script never matches its own patterns.
DENY_LIBS='Network\.fra''mework|CFNetwork\.fra''mework|NetworkExtension|WebKit'
DENY_SYMS='^_(socket|connect|connectx|getaddrinfo|gethostbyname|getnameinfo|CFSocket|CFStreamCreate|CFHost|CFNetwork|CFNetServ|nw_|NSURLSession|NSURLConnection|NSStream|NSNetService)'
DENY_SYMS+='|OBJC_CLASS_\$_(NSURLSession|NSURLConnection|NSURLDownload|NWConnection|NWPathMonitor|NSNetService|NSInputStream|NSOutputStream)'
DENY_SYMS+='|10Foundation10URL''Session|10Foundation13URL''Connection|\$s7Network'
DENY_SYMS+='|SCNetworkReach''ability|SCNetworkConn''ection'

REPO_URL_RE='^https://github\.com/LataroCaballero/Metr(/[A-Za-z0-9._/-]*)?$'

# Exact non-request identifiers allowed in Metr's own executable, one per line as "literal<TAB>reason".
# Empty: the first Release build carried only the repository link.
URL_ALLOW=()

# static_checks BINARY: sets S_LIBS, S_SYMS, S_URLS, S_ALLOWED, S_SCANNED and S_WHY (the reasons it failed).
# Returns 0 when every check passes, 1 otherwise.
static_checks() {
  local bin="$1" libs syms urls line entry
  S_LIBS=0; S_SYMS=0; S_URLS=0; S_ALLOWED=0; S_SCANNED=0; S_WHY=""

  libs="$(otool -L "$bin" | grep -E "$DENY_LIBS" || true)"
  if [ -n "$libs" ]; then
    S_LIBS="$(printf '%s\n' "$libs" | grep -c .)"
    S_WHY+="links a networking framework: $(printf '%s' "$libs" | tr -s ' \t\n' ' '); "
  fi

  # Capture first: a pipe closing early would SIGPIPE nm under pipefail.
  local nm_out
  nm_out="$(nm -u "$bin" | sed 's/^[[:space:]]*//')"
  S_SCANNED="$(printf '%s\n' "$nm_out" | grep -c .)"
  syms="$(printf '%s\n' "$nm_out" | grep -E "$DENY_SYMS" || true)"
  if [ -n "$syms" ]; then
    S_SYMS="$(printf '%s\n' "$syms" | grep -c .)"
    S_WHY+="imports a networking symbol: $(printf '%s' "$syms" | head -n 3 | tr '\n' ' '); "
  fi

  local str_out
  str_out="$(strings -a "$bin")"
  urls="$(printf '%s\n' "$str_out" | grep -Eo 'https?://[^" ]+' | sort -u || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    S_URLS=$((S_URLS + 1))
    if [[ "$line" =~ $REPO_URL_RE ]]; then
      continue
    fi
    local ok=0
    for entry in ${URL_ALLOW[@]+"${URL_ALLOW[@]}"}; do
      if [ "$line" = "${entry%%$'\t'*}" ]; then ok=1; break; fi
    done
    if [ "$ok" = "1" ]; then
      S_ALLOWED=$((S_ALLOWED + 1))
    else
      S_WHY+="URL literal outside the repository prefix and the allowlist: $line; "
    fi
  done <<< "$urls"

  [ -z "$S_WHY" ]
}

app_binary() {
  local app="$1"
  [ -d "$app" ] || fail "app not found at $app"
  [ -x "$app/Contents/MacOS/Metr" ] || fail "no executable at $app/Contents/MacOS/Metr"
  printf '%s\n' "$app/Contents/MacOS/Metr"
}

# ---------------------------------------------------------------------------------------------------------
# Runtime helpers
# ---------------------------------------------------------------------------------------------------------

# sockets_of PID...: prints any Internet socket line held by those processes (empty when none).
sockets_of() {
  local list
  list="$(IFS=,; printf '%s' "$*")"
  lsof -a -i -p "$list" 2>/dev/null || true
}

# traffic_of PID: prints any nettop data row for the process (the header is the first line).
traffic_of() {
  local out
  out="$(nettop -P -L 1 -p "$1" 2>/dev/null || true)"
  printf '%s\n' "$out" | sed '1d' | grep -E '[^[:space:]]' || true
}

wait_for_pid() {
  # wait_for_pid APP: the pid of the instance launched from APP, within 15 s.
  local app="$1" pid="" i
  for i in $(seq 1 150); do
    pid="$(metr_pid "$app")"
    [ -n "$pid" ] && { printf '%s\n' "$pid"; return 0; }
    sleep 0.1
  done
  return 1
}

SCRIPT_SUITE="io.github.latarocaballero.Metr.script"
cleanup() {
  metr_kill >/dev/null 2>&1 || true
  defaults delete "$SCRIPT_SUITE" >/dev/null 2>&1 || true
}

cdhash_of() {
  local info
  info="$(codesign -dvvv "$1" 2>&1)"
  printf '%s\n' "$info" | sed -n 's/^CDHash=//p' | head -n 1
}

run_runtime() {
  local release="$METR_APP_RELEASE" relhooks="$METR_APP_RELHOOKS"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --release)  [ "$#" -ge 2 ] || { echo "usage: --release APP" >&2; exit 2; }; release="$2"; shift 2 ;;
      --relhooks) [ "$#" -ge 2 ] || { echo "usage: --relhooks APP" >&2; exit 2; }; relhooks="$2"; shift 2 ;;
      *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
  done
  [ -d "$release" ]  || fail "$release missing (build release and relhooks first)"
  [ -d "$relhooks" ] || fail "$relhooks missing (build release and relhooks first)"

  trap cleanup EXIT
  metr_kill

  # (a) idle, the Release app exactly as users launch it. -MetrDidPresentWelcome is the argument-domain
  # override that keeps the first-launch window out; it is not persisted.
  local pid sockets traffic
  open -g -n "$release" --args -MetrDidPresentWelcome YES
  pid="$(wait_for_pid "$release")" || fail "the Release app did not start"
  local t0=$SECONDS
  local idle_cdhash
  idle_cdhash="$(cdhash_of "$release")"
  [[ "$idle_cdhash" =~ ^[0-9a-f]{40}$ ]] || fail "could not read the CDHash of $release"
  local mark
  for mark in 4 10; do
    while [ $((SECONDS - t0)) -lt "$mark" ]; do sleep 0.2; done
    kill -0 "$pid" 2>/dev/null || fail "the idle Release app (pid $pid) exited before ${mark} s"
    sockets="$(sockets_of "$pid")"
    [ -z "$sockets" ] || { printf '%s\n' "$sockets"; fail "idle Release app holds an Internet socket at ${mark} s"; }
    traffic="$(traffic_of "$pid")"
    [ -z "$traffic" ] || { printf '%s\n' "$traffic"; fail "idle Release app shows nettop traffic at ${mark} s"; }
    if pgrep -P "$pid" -x top >/dev/null 2>&1; then fail "idle Release app has a top child at ${mark} s"; fi
  done
  metr_kill
  echo "IDLE OK pid=$pid app=$release"

  # (b) Processes open, on the relhooks app. The static checks come first: they are what lets this
  # result carry over to the shipped binary (the DEBUG hooks add no networking symbol).
  local rh_bin
  rh_bin="$(app_binary "$relhooks")"
  static_checks "$rh_bin" || fail "relhooks binary is not network-free: $S_WHY"
  echo "RELHOOKS STATIC OK undefined_symbols=$S_SCANNED urls=$S_URLS"

  defaults delete "$SCRIPT_SUITE" >/dev/null 2>&1 || true
  open -g -n --env 'METR_DEBUG_WINDOW_SCRIPT=processes@1;close@14' "$relhooks" --args -MetrDidPresentWelcome YES
  pid="$(wait_for_pid "$relhooks")" || fail "the relhooks app did not start"
  t0=$SECONDS
  local top_pid seen_top=0
  for mark in 4 10; do
    while [ $((SECONDS - t0)) -lt "$mark" ]; do sleep 0.2; done
    kill -0 "$pid" 2>/dev/null || fail "the relhooks app (pid $pid) exited before ${mark} s"
    top_pid="$(pgrep -P "$pid" -x top 2>/dev/null | head -n 1 || true)"
    local pids=("$pid")
    if [ -n "$top_pid" ]; then seen_top=1; pids+=("$top_pid"); fi
    sockets="$(sockets_of "${pids[@]}")"
    [ -z "$sockets" ] || { printf '%s\n' "$sockets"; fail "Metr or its top child holds an Internet socket at ${mark} s with Processes open"; }
    local p
    for p in "${pids[@]}"; do
      traffic="$(traffic_of "$p")"
      [ -z "$traffic" ] || { printf '%s\n' "$traffic"; fail "nettop shows traffic for pid $p at ${mark} s with Processes open"; }
    done
  done
  [ "$seen_top" = "1" ] || fail "the top child was never seen with Processes open: the check observed nothing"
  metr_kill
  defaults delete "$SCRIPT_SUITE" >/dev/null 2>&1 || true
  echo "PROCESSES OK pid=$pid top_seen=1 app=$relhooks"

  echo "NO-NETWORK RUNTIME OK idle=0 processes=0 idle_cdhash=$idle_cdhash processes_build=relhooks"
}

# ---------------------------------------------------------------------------------------------------------
# Self-test: the gate must be able to fail
# ---------------------------------------------------------------------------------------------------------

run_self_test() {
  tmp="$(mktemp -d)"
  SELF_TMP="$tmp"
  trap 'rm -rf -- "$SELF_TMP"' EXIT

  cat > "$tmp/neg_session.swift" <<'SWIFT'
import Foundation
let task = URLSession.shared.dataTask(with: URL(string: "https://example.com/x")!)
task.resume()
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
SWIFT
  cat > "$tmp/neg_framework.swift" <<'SWIFT'
import Network
let monitor = NWPathMonitor()
monitor.start(queue: .main)
SWIFT
  swiftc -o "$tmp/neg_session" "$tmp/neg_session.swift" 2>/dev/null || fail "could not compile the URLSession control"
  swiftc -o "$tmp/neg_framework" "$tmp/neg_framework.swift" 2>/dev/null || fail "could not compile the Network control"

  if static_checks "$tmp/neg_session"; then fail "self-test: the gate passed a program that uses a URL session"; fi
  [ "$S_SYMS" -ge 1 ] || fail "self-test: the symbol check did not catch the URL session program"
  [ "$S_URLS" -ge 1 ] || fail "self-test: the URL check did not see the program's URL literal"
  echo "CONTROL url-session FAILED as expected: symbols=$S_SYMS urls=$S_URLS"

  if static_checks "$tmp/neg_framework"; then fail "self-test: the gate passed a program that links Network.framework"; fi
  [ "$S_LIBS" -ge 1 ] || fail "self-test: the library check did not catch the Network.framework program"
  echo "CONTROL network-framework FAILED as expected: libs=$S_LIBS symbols=$S_SYMS"

  local bin
  bin="$(app_binary "$METR_APP_RELEASE")"
  static_checks "$bin" || fail "self-test: the real app fails the gate: $S_WHY"
  echo "NO-NETWORK SELF-TEST OK"
}

# ---------------------------------------------------------------------------------------------------------

case "${1:-}" in
  --self-test) run_self_test ;;
  --runtime)   shift; run_runtime "$@" ;;
  -*)          echo "usage: no-network.sh [app] | --self-test | --runtime [--release APP] [--relhooks APP]" >&2; exit 2 ;;
  *)
    APP="${1:-$METR_APP_RELEASE}"
    BIN="$(app_binary "$APP")"
    if ! static_checks "$BIN"; then
      echo "FAIL: $S_WHY"
      exit 1
    fi
    echo "SCANNED undefined_symbols=$S_SCANNED"
    echo "NO-NETWORK OK libs=0 symbols=0 urls=$S_URLS allowed=$S_ALLOWED"
    ;;
esac
