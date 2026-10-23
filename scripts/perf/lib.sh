#!/usr/bin/env bash
# Sourced by measure.sh and soak.sh (after scripts/env.sh). Shared helpers for the FND-03 harness.

# Compile scripts/perf/rusage.swift once into the build root and print the binary path.
# The interpreter ("swift rusage.swift") costs seconds of CPU per call; the soak calls this every
# minute, so it is built once and reused. Rebuilt whenever the source is newer.
metr_rusage_bin() {
  local src="$METR_ROOT/scripts/perf/rusage.swift"
  local bin="$METR_BUILD_ROOT/bin/rusage"
  if [ ! -x "$bin" ] || [ "$src" -nt "$bin" ]; then
    mkdir -p "$METR_BUILD_ROOT/bin"
    swiftc -O -o "$bin" "$src" >&2
  fi
  printf '%s\n' "$bin"
}

# Pid of the running Metr, or empty. With an app path, only the instance launched from that bundle
# matches (a Debug and a Release copy share the process name, so the name alone is ambiguous).
metr_pid() {
  if [ -n "${1:-}" ]; then
    pgrep -f "^$1/Contents/MacOS/Metr( |\$)" 2>/dev/null | head -n 1 || true
  else
    pgrep -x Metr 2>/dev/null | head -n 1 || true
  fi
}

# Number of running Metr processes of any build.
metr_count() {
  pgrep -x Metr 2>/dev/null | grep -c . || true
}

# Replace the value of the named KEY=VALUE lines in a budget file, touching nothing else.
# Usage: budget_set FILE KEY VALUE [KEY VALUE]...
# Writes through a temporary file in the same directory, then mv (atomic on the same volume).
budget_set() {
  local file="$1"; shift
  local tmp
  tmp="$(mktemp "$(dirname "$file")/.budget.XXXXXX")"
  cp "$file" "$tmp"
  local key value
  while [ "$#" -ge 2 ]; do
    key="$1"; value="$2"; shift 2
    grep -q "^${key}=" "$tmp" || { rm -f "$tmp"; echo "budget_set: no such key $key" >&2; return 1; }
    awk -v k="$key" -v v="$value" 'BEGIN { p = k "=" } index($0, p) == 1 { print p v; next } { print }' \
      "$tmp" > "$tmp.new"
    mv "$tmp.new" "$tmp"
  done
  chmod 644 "$tmp"
  mv "$tmp" "$file"
}

# Float comparison: prints 1 when $1 > $2.
metr_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN { print (a + 0 > b + 0) ? 1 : 0 }'
}
