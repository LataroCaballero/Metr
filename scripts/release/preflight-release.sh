#!/usr/bin/env bash
# Usage: scripts/release/preflight-release.sh TAG                  the releasable-commit gate (TAG like v1.0.0)
#        scripts/release/preflight-release.sh --list [--root DIR]   only the coverage check (seconds)
#
# One command that runs every unattended Phase 1-4 gate on the current commit, as the 41 steps named in
# STEP_NAMES below, in that order, and prints as its LAST line
#   RELEASE-PREFLIGHT OK tag=<t> commit=<40-hex HEAD> gates=<n> skipped=<n> known=<n>
# only when all of them pass. Nothing is committed, tagged or pushed by it.
#
# RUN TIME: about 45 to 70 minutes (the Phase 1-3 accuracy scripts, the release build, the DMG, the
# 300 s idle measurement, the window and soak checks, and the CI wait). A foreground tool call stops at
# 10 minutes, so callers start it detached and read its log:
#   ( source scripts/env.sh; bash scripts/release/preflight-release.sh v1.0.0 > "$METR_LOGS/preflight-v1.0.0.out" 2>&1 )
# Each step's own output goes to $METR_LOGS/preflight/<NN>-<step>.log; the main log carries only the step
# names, the PREFLIGHT lines and real failures (window-cost.sh cycles prints a FAIL: line of its own while
# its known failure is accepted, which is why step output never reaches the main log on success).
#
# Before the first gate: the tree must be committed (tracked files) and HEAD must be the head of the work
# branch on origin; HEAD is recorded as C and checked again after every step, and C is named in the OK
# line, so the tag is placed on exactly the commit that passed. Any fix restarts the sequence
# (commit, push, wait for CI, run this again).
#
# Coverage check (before the first gate): every regular file in scripts/verify and scripts/perf (dotfiles
# ignored) must be run by a step, listed in SKIP_TABLE with its reason, or listed in DATA_TABLE with its
# reader; otherwise "FAIL: unclassified <path>". A listed file that does not exist fails as
# "FAIL: listed but missing <path>". The scripts a step runs are read from the step's own function body,
# so a new script can never be silently left out.
#
# Known failure (budget.env KNOWN_ISSUE_WINDOW_CYCLES, owner decision C, 03-15): step 38 accepts
# `window-cost.sh cycles` only as exit 3 with its `KNOWN-FAILURE cycles:` line, while the variable is set.
# It is then listed as PREFLIGHT KNOWN-FAILURE and counted in known=; exit 0 prints a PREFLIGHT NOTE.
#
# Owner skip (04-12, owner decision 2026-11-17, single run): METR_PREFLIGHT_OWNER_SKIP=login-item makes step
# 10 not run, because scripts/spikes/login-item.sh refuses while the owner's own /Applications/Metr.app
# exists. Only the step named login-item is accepted (any other name fails with exit 2). The script itself
# checks that the login-item sources are unchanged since OWNER_SKIP_BASE (git diff is empty) and fails when
# they changed. The step is printed as a `PREFLIGHT SKIP <NN> login-item: ...` line and counted in skipped=;
# it is never silent. The variable is read from the environment of one run and is never set by a script.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GH_REPO="LataroCaballero/Metr"

# Owner skip support (see the header). The login-item code is these files; DebugHooks.swift also holds the
# login-item hook names, so a diff of it counts only when a changed line mentions "login".
OWNER_SKIP_ALLOWED=(login-item)
OWNER_SKIP_BASE="681663b"
LOGIN_ITEM_SOURCES=(
  Metr/AppDelegate.swift
  Metr/Settings/SettingsView.swift
  Metr/Settings/LoginItemModel.swift
  Metr/Settings/SettingsWindowController.swift
  Metr/Debug/DebugSnapshotRenderer.swift
  Packages/MetrKit/Sources/MetrCore/LoginItemProjection.swift
  Packages/MetrKit/Tests/MetrCoreTests/LoginItemProjectionTests.swift
  scripts/spikes/login-item.sh
)

# ---------------------------------------------------------------------------------------------------
# The steps, in order. A step "foo-bar" is the function step_foo_bar below. Every function runs in its own
# `bash -euo pipefail`, from the repository root, with scripts/env.sh sourced by this script (exported).
# ---------------------------------------------------------------------------------------------------
STEP_NAMES=(
  test build-debug render-snapshots l10n-render design glyph-previews idle-cadence settings-window
  move-offer login-item window-deeplink cpu-vs-top memory-vs-system procs-vs-top proc-diskio disk-live
  diskio-live volumes-vs-diskutil gpu-vs-ioreg net-vs-netstat no-network-self-test public-content
  build-release-app bundle status-item no-network-static l10n build-release-dist dmg build-relhooks
  no-network-runtime table-stress measure panel-cost window-cost-cpu window-cost-processes window-cost-after-close
  window-cost-cycles soak-quick readme ci-and-defaults
)

step_test() { bash scripts/test.sh; }
step_build_debug() { bash scripts/build.sh debug; }
step_render_snapshots() { bash scripts/verify/render-snapshots.sh; }
step_l10n_render() { bash scripts/verify/l10n-render.sh; }
step_design() { bash scripts/verify/design.sh; }
step_glyph_previews() { bash scripts/verify/glyph-previews.sh; }
step_idle_cadence() {
  # -MetrDidPresentWelcome YES keeps the first-launch Welcome window away and writes nothing to the
  # owner's preferences domain (step 41 fails on a written domain).
  bash scripts/verify/run-debug.sh 9 idle --expect 'tier=idle base=2\.0' --expect 'tick dt=' --min 4 \
    --args -MetrDidPresentWelcome YES
  bash scripts/verify/tick-intervals.sh idle 2.0 0.3
}
step_settings_window() { bash scripts/verify/settings-window.sh; }
step_move_offer() { bash scripts/verify/move-offer.sh; }
step_login_item() {
  local out
  out="$(bash scripts/spikes/login-item.sh --settings)"
  printf '%s\n' "$out"
  printf '%s\n' "$out" | grep -qE '^LOGIN-ITEM-ELSEWHERE status=(0|3) shown=off message=location' \
    || { echo "FAIL: no LOGIN-ITEM-ELSEWHERE line with status=<0|3> shown=off message=location"; return 1; }
  printf '%s\n' "$out" | grep -qE '^LOGIN-ITEM-SETTINGS on=1 on_again=1 off=0 off_again=0 fast=0' \
    || { echo "FAIL: no LOGIN-ITEM-SETTINGS on=1 on_again=1 off=0 off_again=0 fast=0 line"; return 1; }
}
step_window_deeplink() { bash scripts/verify/window-deeplink.sh; }
step_cpu_vs_top() { bash scripts/verify/cpu-vs-top.sh; }
step_memory_vs_system() { bash scripts/verify/memory-vs-system.sh; }
step_procs_vs_top() { bash scripts/verify/procs-vs-top.sh; }
step_proc_diskio() { bash scripts/verify/proc-diskio.sh; }
step_disk_live() { bash scripts/verify/disk-live.sh; }
step_diskio_live() { bash scripts/verify/diskio-live.sh; }
step_volumes_vs_diskutil() { bash scripts/verify/volumes-vs-diskutil.sh; }
step_gpu_vs_ioreg() { bash scripts/verify/gpu-vs-ioreg.sh; }
step_net_vs_netstat() { bash scripts/verify/net-vs-netstat.sh; }
step_no_network_self_test() { bash scripts/verify/no-network.sh --self-test; }
step_public_content() { bash scripts/verify/public-content.sh; }
step_build_release_app() { bash scripts/build.sh release; }
step_bundle() { bash scripts/verify/bundle.sh; }
step_status_item() { bash scripts/verify/status-item.sh; }
step_no_network_static() { bash scripts/verify/no-network.sh; }
step_l10n() { bash scripts/verify/l10n.sh; }
step_build_release_dist() {
  rm -rf "${METR_BUILD_ROOT:?}/dist-preflight"
  bash scripts/release/build-release.sh "$PREFLIGHT_TAG" --out "$METR_BUILD_ROOT/dist-preflight"
}
step_dmg() {
  local v="${PREFLIGHT_TAG#v}"
  bash scripts/verify/dmg.sh "$METR_BUILD_ROOT/dist-preflight/Metr-$v.dmg" "$METR_RELEASE_STAGE/$v/Metr.app"
}
step_build_relhooks() { bash scripts/build.sh relhooks; }
step_no_network_runtime() { bash scripts/verify/no-network.sh --runtime; }
# The Processes table's refresh race (04-12): 120 churning refreshes, the outline checked after each.
step_table_stress() { bash scripts/verify/table-stress.sh 120 1; }
step_measure() { bash scripts/perf/measure.sh 300; }
step_panel_cost() { bash scripts/perf/panel-cost.sh 15; }
step_window_cost_cpu() { bash scripts/perf/window-cost.sh cpu 15; }
step_window_cost_processes() { bash scripts/perf/window-cost.sh processes 15; }
step_window_cost_after_close() { bash scripts/perf/window-cost.sh after-close; }
step_window_cost_cycles() { bash scripts/perf/window-cost.sh cycles 10; }
step_soak_quick() { bash scripts/perf/soak.sh --quick 60; }
step_readme() { bash scripts/verify/readme.sh; }
step_ci_and_defaults() {
  # shellcheck source=../env.sh
  source scripts/env.sh
  local id status conclusion d
  id="$(gh run list --repo "$GH_REPO" --workflow CI --commit "$PREFLIGHT_C" --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
  [ -n "$id" ] || { echo "FAIL: no CI run for HEAD (push first)"; return 1; }
  # Returns only when the run has completed; non-zero when it failed.
  gh run watch "$id" --repo "$GH_REPO" --exit-status || { echo "FAIL: CI run $id did not succeed"; return 1; }
  conclusion="$(gh run view "$id" --repo "$GH_REPO" --json conclusion --jq .conclusion)"
  status="$(gh run view "$id" --repo "$GH_REPO" --json status --jq .status)"
  [ "$status" = completed ] && [ "$conclusion" = success ] \
    || { echo "FAIL: CI run $id is $status/$conclusion, not completed/success"; return 1; }
  echo "CI OK run=$id commit=$PREFLIGHT_C"
  # The scripted runs must never write the owner's preferences or leave the script suite behind.
  for d in "$(metr_bundle_id)" "io.github.latarocaballero.Metr.script"; do
    if defaults read "$d" >/dev/null 2>&1; then echo "FAIL: preferences domain $d exists"; return 1; fi
  done
  echo "DEFAULTS OK no preferences domain written"
}

# ---------------------------------------------------------------------------------------------------
# Files in scripts/verify and scripts/perf that no step runs (path|reason) and data files (path|reader).
# ---------------------------------------------------------------------------------------------------
SKIP_TABLE=(
  "scripts/verify/status-item.swift|helper run by status-item.sh (step 25)"
  "scripts/verify/ocr.swift|helper compiled by l10n-render.sh (step 04)"
  "scripts/perf/lib.sh|library sourced by measure.sh, soak.sh, panel-cost.sh and window-cost.sh (steps 32 to 38)"
  "scripts/perf/rusage.swift|helper compiled by lib.sh"
  "scripts/verify/suspend-resume.sh|HUMAN-RUN per its header: it turns the display off for about 20 s"
)
DATA_TABLE=(
  "scripts/perf/budget.env|thresholds and KNOWN_ISSUE_WINDOW_CYCLES, read by the perf steps"
  "scripts/verify/l10n-render-allow.txt|allowlist read by l10n-render.sh"
)

table_paths() { local e; for e in "$@"; do printf '%s\n' "${e%%|*}"; done; }

# The scripts/verify and scripts/perf files the steps run, read from the step function bodies.
step_scripts() {
  local n
  for n in "${STEP_NAMES[@]}"; do declare -f "step_${n//-/_}"; done \
    | grep -oE 'scripts/(verify|perf)/[A-Za-z0-9._-]+' | LC_ALL=C sort -u
}

# coverage ROOT: prints FAIL lines and returns 1 when a file is unclassified or a listed one is missing.
coverage() {
  local root="$1" bad=0 f p n present steps skips datas
  if ! present="$(cd "$root" && find scripts/verify scripts/perf -type f ! -name '.*' | LC_ALL=C sort)"; then
    echo "FAIL: cannot list scripts/verify and scripts/perf under $root" >&2
    return 1
  fi
  steps="$(step_scripts)"
  skips="$(table_paths "${SKIP_TABLE[@]}")"
  datas="$(table_paths "${DATA_TABLE[@]}")"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=0
    if grep -qxF "$f" <<<"$steps"; then n=$((n + 1)); fi
    if grep -qxF "$f" <<<"$skips"; then n=$((n + 1)); fi
    if grep -qxF "$f" <<<"$datas"; then n=$((n + 1)); fi
    if [ "$n" = 0 ]; then
      echo "FAIL: unclassified $f (add it to a step, the SKIP table or the DATA table)" >&2
      bad=1
    elif [ "$n" -gt 1 ]; then
      echo "FAIL: $f is classified more than once" >&2
      bad=1
    fi
  done <<<"$present"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ ! -f "$root/$p" ]; then echo "FAIL: listed but missing $p" >&2; bad=1; fi
  done <<<"$steps
$skips
$datas"
  return "$bad"
}

print_plan() {
  local nsteps nscripts e i
  nsteps="${#STEP_NAMES[@]}"
  nscripts="$(step_scripts | grep -c . || true)"
  echo "PREFLIGHT PLAN steps=$nsteps scripts=$nscripts skips=${#SKIP_TABLE[@]} data=${#DATA_TABLE[@]}"
  for e in "${SKIP_TABLE[@]}"; do echo "PREFLIGHT SKIP ${e%%|*}: ${e#*|}"; done
  PLAN_STEPS="$nsteps"
}

usage() {
  echo "usage: scripts/release/preflight-release.sh TAG | --list [--root DIR]" >&2
  exit 2
}

# ---------------------------------------------------------------------------------------------------
# --list [--root DIR]
# ---------------------------------------------------------------------------------------------------
if [ "${1:-}" = "--list" ]; then
  shift
  LIST_ROOT="$REPO_ROOT"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root) [ "$#" -ge 2 ] || usage; LIST_ROOT="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  coverage "$LIST_ROOT" || exit 1
  print_plan
  i=0
  for name in "${STEP_NAMES[@]}"; do i=$((i + 1)); printf 'PREFLIGHT STEP %02d %s\n' "$i" "$name"; done
  exit 0
fi

# ---------------------------------------------------------------------------------------------------
# TAG: the full preflight
# ---------------------------------------------------------------------------------------------------
[ "$#" -eq 1 ] || usage
TAG="$1"
if ! [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]]; then
  echo "FAIL: tag '$TAG' is not v<major>.<minor>.<patch> with an optional -rc.<n>" >&2
  exit 2
fi

cd "$REPO_ROOT"
START_EPOCH="$(date +%s)"
C="$(git rev-parse HEAD)"
BRANCH="$(git branch --show-current)"
[ -n "$BRANCH" ] || { echo "FAIL: HEAD is detached"; exit 1; }
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then echo "FAIL: uncommitted changes"; exit 1; fi
REMOTE_LINE="$(git ls-remote origin "refs/heads/$BRANCH")"
if [ "${REMOTE_LINE%%[[:space:]]*}" != "$C" ]; then echo "FAIL: HEAD not pushed"; exit 1; fi

coverage "$REPO_ROOT" || exit 1
print_plan
echo "PREFLIGHT START tag=$TAG commit=$C branch=$BRANCH"

# Owner skips: validated before the first gate. Unknown names and changed sources fail the run.
OWNER_SKIPS=()
if [ -n "${METR_PREFLIGHT_OWNER_SKIP:-}" ]; then
  IFS=',' read -r -a requested <<<"$METR_PREFLIGHT_OWNER_SKIP"
  for s in "${requested[@]}"; do
    ok=0
    for a in "${OWNER_SKIP_ALLOWED[@]}"; do if [ "$s" = "$a" ]; then ok=1; fi; done
    [ "$ok" = 1 ] || { echo "FAIL: METR_PREFLIGHT_OWNER_SKIP names '$s'; only ${OWNER_SKIP_ALLOWED[*]} can be skipped" >&2; exit 2; }
    OWNER_SKIPS+=("$s")
  done
  for s in "${OWNER_SKIPS[@]}"; do
    git merge-base --is-ancestor "$OWNER_SKIP_BASE" HEAD \
      || { echo "FAIL: owner skip $s: $OWNER_SKIP_BASE is not an ancestor of HEAD"; exit 1; }
    if ! git diff --quiet "$OWNER_SKIP_BASE..HEAD" -- "${LOGIN_ITEM_SOURCES[@]}"; then
      echo "FAIL: owner skip $s refused: the login-item sources changed since $OWNER_SKIP_BASE:"
      git diff --stat "$OWNER_SKIP_BASE..HEAD" -- "${LOGIN_ITEM_SOURCES[@]}" | sed 's/^/  | /'
      exit 1
    fi
    if git diff -U0 "$OWNER_SKIP_BASE..HEAD" -- Metr/Debug/DebugHooks.swift | grep -iE '^[+-].*login' >/dev/null; then
      echo "FAIL: owner skip $s refused: a changed line in Metr/Debug/DebugHooks.swift mentions login"
      exit 1
    fi
  done
fi
owner_skipped=0

# shellcheck source=../env.sh
source scripts/env.sh
LOGDIR="$METR_LOGS/preflight"
mkdir -p "$LOGDIR"
find "$LOGDIR" -maxdepth 1 -type f -name '[0-9][0-9]-*.log' -delete

KNOWN_ISSUE="$( (set +u; . scripts/perf/budget.env >/dev/null 2>&1; printf '%s' "${KNOWN_ISSUE_WINDOW_CYCLES:-}") )"

export PREFLIGHT_TAG="$TAG" PREFLIGHT_C="$C" GH_REPO
for n in "${STEP_NAMES[@]}"; do export -f "step_${n//-/_}"; done

known=0
gates=0
idx=0
for name in "${STEP_NAMES[@]}"; do
  idx=$((idx + 1))
  nn="$(printf '%02d' "$idx")"
  log="$LOGDIR/$nn-$name.log"
  fn="step_${name//-/_}"
  echo "PREFLIGHT STEP $nn $name"
  skip_owner=0
  for s in ${OWNER_SKIPS[@]+"${OWNER_SKIPS[@]}"}; do if [ "$s" = "$name" ]; then skip_owner=1; fi; done
  if [ "$skip_owner" = 1 ]; then
    echo "PREFLIGHT SKIP $nn $name: owner decision 2026-11-17, /Applications/Metr.app is the owner's install; login-item code unchanged since $OWNER_SKIP_BASE (git diff $OWNER_SKIP_BASE..HEAD -- <login-item sources> is empty)"
    echo "$nn $name SKIPPED (owner)" >>"$LOGDIR/timing.txt"
    owner_skipped=$((owner_skipped + 1))
    continue
  fi
  t0="$(date +%s)"
  rc=0
  bash -c 'set -euo pipefail; cd "$1"; "$2"' _ "$REPO_ROOT" "$fn" >"$log" 2>&1 </dev/null || rc=$?
  echo "$nn $name rc=$rc seconds=$(( $(date +%s) - t0 ))" >>"$LOGDIR/timing.txt"

  if [ "$name" = "window-cost-cycles" ]; then
    if [ "$rc" = 3 ] && [ -n "$KNOWN_ISSUE" ] && grep -q '^KNOWN-FAILURE cycles:' "$log"; then
      growth="$(sed -n 's/^WINDOW-COST cycles=[0-9]* growth_mb=\([^ ]*\).*/\1/p' "$log" | tail -n 1)"
      echo "PREFLIGHT KNOWN-FAILURE window-cost.sh cycles: $KNOWN_ISSUE growth_mb=$growth"
      known=$((known + 1))
      rc=0
    elif [ "$rc" = 0 ] && [ -n "$KNOWN_ISSUE" ]; then
      echo "PREFLIGHT NOTE window-cost.sh cycles passed this run; KNOWN_ISSUE_WINDOW_CYCLES stays until the owner retires it"
    fi
  fi

  if [ "$rc" != 0 ]; then
    echo "FAIL: $nn $name (see $log)"
    tail -n 20 "$log" | sed 's/^/  | /'
    exit 1
  fi
  gates=$((gates + 1))

  if [ "$name" = "volumes-vs-diskutil" ]; then
    echo "PREFLIGHT NOTE volumes-vs-diskutil.sh --mount not run: harness race"
  fi

  if [ "$(git rev-parse HEAD)" != "$C" ]; then echo "FAIL: HEAD moved during the preflight (step $nn $name)"; exit 1; fi
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "FAIL: step $nn $name changed tracked files:"
    git status --porcelain --untracked-files=no | sed 's/^/  | /'
    exit 1
  fi
done

[ $((gates + owner_skipped)) = "$PLAN_STEPS" ] || { echo "FAIL: ran $gates gates and skipped $owner_skipped, the plan has $PLAN_STEPS"; exit 1; }
echo "PREFLIGHT ELAPSED seconds=$(( $(date +%s) - START_EPOCH ))"
echo "RELEASE-PREFLIGHT OK tag=$TAG commit=$C gates=$gates skipped=$(( ${#SKIP_TABLE[@]} + owner_skipped )) known=$known"
