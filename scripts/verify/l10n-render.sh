#!/usr/bin/env bash
# Usage: scripts/verify/l10n-render.sh [--only settings] [--dir DIR]
# L10N-01 render gate (UI-SPEC "Audit Contracts", gates 2 and 3): reads the real renders back with
# on-device text recognition (Vision, no network) and fails on
#   leftover       an EN catalog phrase on an ES image, or an ES catalog phrase on an EN image
#   truncation     a recognized ellipsis that is not a designed one (a catalog value containing ...)
#   number-format  a decimal point with one or two decimals on an ES image, or a decimal comma with
#                  one or two decimals on an EN image; and, for harness renders, an EN fixture that
#                  shows a decimal number whose ES twin shows no decimal-comma number
# The phrase sets come from Metr/Localizable.xcstrings and Metr/InfoPlist.xcstrings, so a new key is
# covered without editing this script. A phrase counts when it is at least 8 characters long, carries no
# format specifier and differs between EN and ES; recognition noise therefore produces misses, never
# false alarms. Before any real image is read, the gate runs `metr-ocr --self-test` and its own rules over
# the four planted PNGs and fails unless they report exactly the four planted findings (leftover,
# truncation, number-format twice): a detector that cannot fail is not trusted.
#
# Default: every panel-, welcome-, window- and settings- PNG in $METR_PREVIEWS/snapshots (left there by
# render-snapshots.sh). --only settings restricts to settings-*.png.
# --dir DIR: the same leftover, truncation and single-image number rules over every
# <surface>-<lang>[-<rest>].png in DIR (the language is the second dash-separated field, en or es; any
# other name fails as "unnamed language"). The EN/ES pairing rule applies only to harness renders, so
# numbers= is 0 in this mode. Nothing outside DIR (and the OCR scratch directory) is read or written.
#
# scripts/verify/l10n-render-allow.txt: one "<file-glob>\t<exact recognized text>\t<reason>" per line.
# Prints "L10N-RENDER OK images=<n> en=<n> es=<n> allowed=<n> numbers=<n>" or
# "FAIL: <file>: <text> (<leftover|truncation|number-format>)".
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

fail() { echo "FAIL: $1"; exit 1; }

ONLY=""
DIR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --only) [ "${2:-}" = "settings" ] || fail "--only takes: settings"; ONLY="settings"; shift 2 ;;
    --dir) [ -n "${2:-}" ] || fail "--dir takes a directory"; DIR="$2"; shift 2 ;;
    *) fail "unknown argument $1" ;;
  esac
done
[ -z "$ONLY" ] || [ -z "$DIR" ] || fail "--only and --dir cannot be combined"

ALLOW="scripts/verify/l10n-render-allow.txt"
[ -f "$ALLOW" ] || fail "$ALLOW not found"

# Compile the recognizer once into the build root; rebuild when the source is newer.
SRC="$METR_ROOT/scripts/verify/ocr.swift"
BIN="$METR_BUILD_ROOT/bin/metr-ocr"
if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
  mkdir -p "$METR_BUILD_ROOT/bin"
  swiftc -O -o "$BIN" "$SRC" >&2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The rules, in one python3 -I script that both the self-test and the real run use.
cat > "$WORK/analyze.py" <<'PY'
import fnmatch, json, os, re, sys

mode, allow_path, ocr_path = sys.argv[1], sys.argv[2], sys.argv[3]
images = sys.argv[4:]

SPEC = re.compile(r"%(?:\d+\$)?(?:l{0,2}[dux]|[@fs])")

def norm(s):
    s = s.replace("’", "'").replace("‘", "'").replace("…", "...")
    return re.sub(r"\s+", " ", s).strip().lower()

def leaves(loc):
    """path -> value for a localization, plural variation leaves included."""
    out = {}
    if not isinstance(loc, dict):
        return out
    unit = loc.get("stringUnit")
    if isinstance(unit, dict) and isinstance(unit.get("value"), str):
        out[()] = unit["value"]
    variations = loc.get("variations")
    if isinstance(variations, dict):
        for kind, group in variations.items():
            if isinstance(group, dict):
                for category, sub in group.items():
                    for path, value in leaves(sub).items():
                        out[((kind, category),) + path] = value
    return out

pairs = []  # (en value, es value)
for catalog_path in ("Metr/Localizable.xcstrings", "Metr/InfoPlist.xcstrings"):
    catalog = json.load(open(catalog_path, encoding="utf-8"))
    for key, entry in catalog.get("strings", {}).items():
        if entry.get("extractionState") == "stale" or entry.get("shouldTranslate") is False:
            continue
        localizations = entry.get("localizations", {})
        es = leaves(localizations.get("es"))
        en = leaves(localizations.get("en")) if "en" in localizations else {(): key}
        for path, es_value in es.items():
            en_value = en.get(path)
            if en_value is None and "en" not in localizations:
                en_value = key
            if en_value is not None:
                pairs.append((en_value, es_value))

all_es_norm = [norm(es) for _, es in pairs]
all_en_norm = [norm(en) for en, _ in pairs]

def usable(value, other):
    return len(value) >= 8 and "%" not in value and norm(value) != norm(other)

en_phrases = sorted({norm(en) for en, es in pairs if usable(en, es)})
es_phrases = sorted({norm(es) for en, es in pairs if usable(es, en)})
# An EN phrase that is a substring of a legitimate ES value (and the reverse) is explained by that text.
en_phrases = [p for p in en_phrases if not any(p in v for v in all_es_norm)]
es_phrases = [p for p in es_phrases if not any(p in v for v in all_en_norm)]

designed = []
for en, es in pairs:
    for value in (en, es):
        if "…" in value:
            pieces = SPEC.split(norm(value))
            designed.append(".*?".join(re.escape(p) for p in pieces))
designed = sorted(set(designed))
designed_res = [re.compile(p + "$") for p in designed]

allow = []
for raw in open(allow_path, encoding="utf-8"):
    if not raw.strip() or raw.lstrip().startswith("#"):
        continue
    fields = raw.rstrip("\n").split("\t")
    if len(fields) != 3 or not all(f.strip() for f in fields):
        print("BADALLOW\t" + raw.strip())
        sys.exit(0)
    allow.append((fields[0], fields[1]))

# Decimal point with one or two decimals (not a longer dotted run, not thousands groups of three);
# decimal comma likewise.
POINT = re.compile(r"(?<![\d.,])\d+\.\d{1,2}(?!\d|\.\d)")
COMMA = re.compile(r"(?<![\d.,])\d+,\d{1,2}(?!\d|,\d)")

ocr = {}
for raw in open(ocr_path, encoding="utf-8"):
    raw = raw.rstrip("\n")
    if not raw:
        continue
    path, _, text = raw.partition("\t")
    ocr.setdefault(path, []).append(text)

def lang_of(path):
    fields = os.path.basename(path)[:-4].split("-")
    return fields[1] if len(fields) > 1 and fields[1] in ("en", "es") else None

def allowed(path, text):
    base = os.path.basename(path)
    return any(fnmatch.fnmatch(base, glob) and text == exact for glob, exact in allow)

findings = []
allowed_count = 0
counts = {"en": 0, "es": 0}
dec_point = {}   # basename -> has an EN-style decimal number (en images)
dec_comma = {}   # basename -> has a decimal-comma number (es images)

for path in images:
    base = os.path.basename(path)
    lang = lang_of(path)
    if lang is None:
        findings.append((base, "", "unnamed language"))
        continue
    counts[lang] += 1
    lines = ocr.get(path, [])
    if not lines:
        findings.append((base, "", "no text recognized"))
        continue
    joined = norm(" ".join(lines))
    other = en_phrases if lang == "es" else es_phrases
    visible = []
    for text in lines:
        if allowed(path, text):
            continue
        visible.append(text)
    # leftover: whole phrases of the other language, over the joined text so wrapped lines are covered
    joined_visible = norm(" ".join(visible))
    for phrase in other:
        if phrase in joined_visible:
            # name the recognized line that carries it, or the phrase itself when it wraps
            carrier = next((t for t in visible if phrase in norm(t)), phrase)
            findings.append((base, carrier, "leftover"))
    for text in lines:
        if allowed(path, text):
            n = norm(text)
            if "..." in n or POINT.search(text) or COMMA.search(text) or any(p in n for p in other):
                allowed_count += 1
            continue
        n = norm(text)
        for m in re.finditer(r"\.\.\.", n):
            prefix = n[: m.end()]
            if not any(r.search(prefix) for r in designed_res):
                findings.append((base, text, "truncation"))
                break
        if lang == "es" and POINT.search(text):
            findings.append((base, text, "number-format"))
        if lang == "en" and COMMA.search(text):
            findings.append((base, text, "number-format"))
    if lang == "en":
        dec_point[base] = any(POINT.search(t) for t in visible)
    else:
        dec_comma[base] = any(COMMA.search(t) for t in visible)

numbers = 0
if mode == "render":
    for base, has in dec_point.items():
        if not has:
            continue
        numbers += 1
        parts = base[:-4].split("-")
        parts[1] = "es"
        twin = "-".join(parts) + ".png"
        if twin not in dec_comma:
            findings.append((base, "", "number-format (no ES twin image)"))
        elif not dec_comma[twin]:
            findings.append((twin, "", "number-format (EN shows a decimal number, ES shows no decimal comma)"))

# Deduplicate while keeping order.
seen = set()
for f in findings:
    if f in seen:
        continue
    seen.add(f)
    print("FINDING\t%s\t%s\t%s" % f)
print("STATS\timages=%d en=%d es=%d allowed=%d numbers=%d phrases=%d/%d" % (
    len(images), counts["en"], counts["es"], allowed_count, numbers, len(en_phrases), len(es_phrases)))
PY

analyze() {  # analyze MODE OCR_TSV IMAGE...
  local mode="$1" tsv="$2"; shift 2
  python3 -I "$WORK/analyze.py" "$mode" "$ALLOW" "$tsv" "$@"
}

# 1. Self-test: the recognizer reads the planted text back, and the rules report exactly the four
#    planted findings. Only then are real images read.
SELF="$WORK/selftest"
mkdir -p "$SELF"
"$BIN" --self-test "$SELF" >"$WORK/selftest.log" || { cat "$WORK/selftest.log"; fail "metr-ocr --self-test did not read back the planted text"; }
# Self-test PNGs are checked with an empty allowlist so a stray allowlist line cannot hide a planted case.
: > "$WORK/empty-allow.txt"
"$BIN" "$SELF"/selftest-*.png > "$WORK/selftest.tsv"
self_out="$(python3 -I "$WORK/analyze.py" selftest "$WORK/empty-allow.txt" "$WORK/selftest.tsv" "$SELF"/selftest-*.png)"
echo "$self_out" | grep -q '^BADALLOW' && fail "malformed allowlist line"
expect_finding() {  # expect_finding FILE CATEGORY
  printf '%s\n' "$self_out" | awk -F'\t' -v f="$1" -v c="$2" '$1=="FINDING" && $2==f && $4==c {n++} END{exit n==1?0:1}' \
    || fail "self-test: the gate did not report a $2 finding for the planted $1 (the gate cannot fail)"
}
expect_finding selftest-es-leftover.png leftover
expect_finding selftest-es-truncation.png truncation
expect_finding selftest-es-number.png number-format
expect_finding selftest-en-number.png number-format
self_count="$(printf '%s\n' "$self_out" | grep -c '^FINDING' || true)"
[ "$self_count" = "4" ] || fail "self-test: the gate reported $self_count findings for the four planted cases, expected exactly 4"
echo "self-test: leftover, truncation, number-format x2 all detected" >&2

# 2. The real images.
if [ -n "$DIR" ]; then
  [ -d "$DIR" ] || fail "$DIR is not a directory"
  shopt -s nullglob
  images=("$DIR"/*.png)
  mode="dir"
else
  SNAP="$METR_PREVIEWS/snapshots"
  [ -d "$SNAP" ] || fail "$SNAP not found (run scripts/verify/render-snapshots.sh first)"
  shopt -s nullglob
  if [ "$ONLY" = "settings" ]; then
    images=("$SNAP"/settings-*.png)
  else
    images=("$SNAP"/panel-*.png "$SNAP"/welcome-*.png "$SNAP"/window-*.png "$SNAP"/settings-*.png)
  fi
  mode="render"
fi
[ "${#images[@]}" -gt 0 ] || fail "no PNG images to check"

# Names first: an unnamed language is a failure before any recognition runs.
bad=0
for f in "${images[@]}"; do
  base="$(basename "$f")"
  lang="$(printf '%s' "${base%.png}" | awk -F- '{print $2}')"
  if [ "$lang" != "en" ] && [ "$lang" != "es" ]; then
    echo "FAIL: $base: unnamed language"
    bad=1
  fi
done
[ "$bad" = "0" ] || exit 1

"$BIN" "${images[@]}" > "$WORK/ocr.tsv"
out="$(analyze "$mode" "$WORK/ocr.tsv" "${images[@]}")"
echo "$out" | grep -q '^BADALLOW' && fail "malformed allowlist line: $(echo "$out" | grep '^BADALLOW' | cut -f2)"

findings="$(printf '%s\n' "$out" | awk -F'\t' '$1=="FINDING" {printf "FAIL: %s: %s (%s)\n", $2, $3, $4}')"
if [ -n "$findings" ]; then
  printf '%s\n' "$findings"
  exit 1
fi

stats="$(printf '%s\n' "$out" | awk -F'\t' '$1=="STATS" {print $2}')"
# Print the OK line without the phrase-count diagnostic, which goes to stderr.
echo "phrases: ${stats##* phrases=}" >&2
echo "L10N-RENDER OK ${stats% phrases=*}"
