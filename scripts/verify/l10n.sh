#!/usr/bin/env bash
# Usage: scripts/verify/l10n.sh
# Fails when any String Catalog key lacks a translated, non-empty ES value.
# When METR_APP_RELEASE exists, also requires es.lproj/Localizable.strings in the bundle.
# Also requires every key of Metr/InfoPlist.xcstrings to have a translated ES value, the project's
# knownRegions to list en and es, and (when the Release app exists) en.lproj and es.lproj InfoPlist.strings
# whose ES NSHumanReadableCopyright equals the catalog's ES value.
# Also fails when the keys the compiler extracted from the Swift sources (the newest Debug or Release
# build's *.stringsdata, "Localizable" table) differ from the catalog's non-stale keys, in either
# direction: a used key missing from the catalog, or a catalog key no code uses.
# Since 04-06 it also fails on (L10N-01, UI-SPEC L10N-01 gates 1 and 4):
#   - specifier parity: every ES value carries the same format specifiers as its EN value (positional
#     forms normalized to index plus type), in both catalogs and every plural variation leaf;
#   - rioplatense voseo (D-17): a fixed list of voseo pronoun and verb forms, whole words, in any ES value;
#   - raw literals: a bare string literal passed to NSMenuItem(title:), messageText, informativeText,
#     addButton(withTitle:), setAccessibilityLabel, toolTip, title or Text(verbatim:) in Metr/**/*.swift
#     (not Metr/Debug/, not #if DEBUG regions) unless allow-listed below with a reason.
# METR_L10N_CATALOG and METR_L10N_INFOPLIST override the catalog paths, for the edge probes that run the
# checks over a deliberately broken copy.
# Prints "L10N OK keys=<n> extracted=<n> infoplist=<n> specifiers=<n> voseo=0 rawliterals=<n>".
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

CATALOG="${METR_L10N_CATALOG:-Metr/Localizable.xcstrings}"
[ -f "$CATALOG" ] || { echo "FAIL: $CATALOG not found" >&2; exit 1; }

python3 -I - "$CATALOG" <<'PY'
import json, sys

def has_value(unit):
    return (
        isinstance(unit, dict)
        and unit.get("state") == "translated"
        and isinstance(unit.get("value"), str)
        and unit["value"].strip() != ""
    )

def translated(loc):
    if not isinstance(loc, dict):
        return False
    if has_value(loc.get("stringUnit")):
        return True
    variations = loc.get("variations")
    if isinstance(variations, dict) and variations:
        leaves = []
        for group in variations.values():
            if isinstance(group, dict):
                leaves.extend(group.values())
        return bool(leaves) and all(translated(v) for v in leaves)
    return False

catalog = json.load(open(sys.argv[1], encoding="utf-8"))
if catalog.get("sourceLanguage") != "en":
    print("FAIL: sourceLanguage is not en")
    sys.exit(1)

checked, missing = 0, []
for key, entry in catalog.get("strings", {}).items():
    if entry.get("extractionState") == "stale" or entry.get("shouldTranslate") is False:
        continue
    checked += 1
    if not translated(entry.get("localizations", {}).get("es")):
        missing.append(key)

if missing:
    print("FAIL: keys without a translated ES value:")
    for key in missing:
        print("  " + repr(key))
    sys.exit(1)
print(f"KEYS={checked}")
PY

# Keys the compiler extracted. GeneratedStringSymbols_Localizable.stringsdata is built from the
# catalog itself, so it is excluded: counting it would make the comparison measure nothing.
extracted="$(python3 -I - "$CATALOG" "$METR_DERIVED/Build/Intermediates.noindex/Metr.build" <<'PY'
import glob, json, os, sys

catalog = json.load(open(sys.argv[1], encoding="utf-8"))
base = sys.argv[2]

def files(config):
    pattern = os.path.join(base, config, "Metr.build", "Objects-normal", "arm64", "*.stringsdata")
    return [f for f in glob.glob(pattern) if not os.path.basename(f).startswith("GeneratedStringSymbols")]

candidates = [(max(os.path.getmtime(f) for f in fs), fs) for fs in (files("Debug"), files("Release")) if fs]
if not candidates:
    print("FAIL: no compiler-extracted strings (build first)")
    sys.exit(1)
newest = max(candidates, key=lambda c: c[0])[1]

extracted = set()
for f in newest:
    for entry in json.load(open(f, encoding="utf-8")).get("tables", {}).get("Localizable", []):
        extracted.add(entry["key"])

known = {
    k for k, e in catalog.get("strings", {}).items()
    if e.get("extractionState") != "stale" and e.get("shouldTranslate") is not False
}
missing = sorted(extracted - set(catalog.get("strings", {})))
unused = sorted(known - extracted)
if missing:
    print("FAIL: extracted keys missing from the catalog:")
    for k in missing:
        print("  " + repr(k))
    sys.exit(1)
if unused:
    print("FAIL: catalog keys the compiler does not extract:")
    for k in unused:
        print("  " + repr(k))
    sys.exit(1)
print(len(extracted))
PY
)" || { echo "$extracted"; exit 1; }

keys="$(python3 -I -c 'import json,sys; c=json.load(open(sys.argv[1], encoding="utf-8")); print(sum(1 for e in c["strings"].values() if e.get("extractionState")!="stale" and e.get("shouldTranslate") is not False))' "$CATALOG")"

if [ -d "$METR_APP_RELEASE" ]; then
  [ -s "$METR_APP_RELEASE/Contents/Resources/es.lproj/Localizable.strings" ] \
    || { echo "FAIL: Release bundle has no es.lproj/Localizable.strings" >&2; exit 1; }
fi

# InfoPlist.xcstrings: every key translated to ES (the copyright line follows the system language).
INFOPLIST_CATALOG="${METR_L10N_INFOPLIST:-Metr/InfoPlist.xcstrings}"
[ -f "$INFOPLIST_CATALOG" ] || { echo "FAIL: $INFOPLIST_CATALOG not found" >&2; exit 1; }
infoplist="$(python3 -I - "$INFOPLIST_CATALOG" <<'PY'
import json, sys

catalog = json.load(open(sys.argv[1], encoding="utf-8"))
if catalog.get("sourceLanguage") != "en":
    print("FAIL: InfoPlist sourceLanguage is not en")
    sys.exit(1)
missing, count = [], 0
for key, entry in catalog.get("strings", {}).items():
    count += 1
    unit = entry.get("localizations", {}).get("es", {}).get("stringUnit", {})
    if unit.get("state") != "translated" or not str(unit.get("value", "")).strip():
        missing.append(key)
if missing or count == 0:
    print("FAIL: InfoPlist keys without a translated ES value: " + repr(missing))
    sys.exit(1)
print(count)
PY
)" || { echo "$infoplist"; exit 1; }

# The project must list both regions, or the lproj folders are not built (RESEARCH Pitfall 11 asserts
# the folders, not CFBundleLocalizations).
regions="$(awk '/knownRegions = \(/{f=1; next} f && /\);/{exit} f{gsub(/[[:space:],]/, ""); print}' Metr.xcodeproj/project.pbxproj)"
for region in en es; do
  printf '%s\n' "$regions" | grep -qx "$region" || { echo "FAIL: knownRegions does not list $region" >&2; exit 1; }
done

if [ -d "$METR_APP_RELEASE" ]; then
  resources="$METR_APP_RELEASE/Contents/Resources"
  for lang in en es; do
    [ -s "$resources/$lang.lproj/InfoPlist.strings" ] \
      || { echo "FAIL: Release bundle has no $lang.lproj/InfoPlist.strings" >&2; exit 1; }
  done
  expected="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["strings"]["NSHumanReadableCopyright"]["localizations"]["es"]["stringUnit"]["value"])' "$INFOPLIST_CATALOG")"
  actual="$(plutil -extract NSHumanReadableCopyright raw -o - "$resources/es.lproj/InfoPlist.strings" 2>/dev/null || true)"
  [ "$actual" = "$expected" ] \
    || { echo "FAIL: es.lproj/InfoPlist.strings NSHumanReadableCopyright is '$actual', expected '$expected'" >&2; exit 1; }
fi

# Specifier parity, voseo and raw literals (04-06). Both catalogs; stale keys are not counted.
CHECKS_PY="$(mktemp)"
cat > "$CHECKS_PY" <<'PY'
import glob, json, os, re, sys
from collections import Counter

SPEC = re.compile(r"%(?:(\d+)\$)?(?:ll|l|hh|h|z|q|L)?([@dDuUxXfeEgGsScCpi])")

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

def specifiers(value):
    """Multiset of (index, type): a positional %2$lld keeps its index, plain ones count in order."""
    found, position = Counter(), 0
    for m in SPEC.finditer(value.replace("%%", "")):
        position += 1
        index = int(m.group(1)) if m.group(1) else position
        kind = m.group(2)
        found[(index, kind.lower() if kind in "dDuU" else kind)] += 1
    return found

# Rioplatense voseo forms (D-17). Whole words, case-insensitive. Standard first-person preterite forms
# that coincide with a voseo imperative (abri, sali, elegi, permiti, ...) are left out on purpose: they
# are correct neutral Spanish. This list lives only in this script.
VOSEO = """vos sos tenés podés querés sabés hacés ponés venís salís decís elegís abrís cerrás usás movés
necesitás buscás mirás andá decí esperá fijate hacé mirá poné probá tené vení seleccioná activá desactivá
confirmá guardá descargá tocá usá buscá copiá pegá cambiá revisá intentá reiniciá actualizá instalá
ejecutá habilitá aceptá cancelá continuá ignorá volvé dejá mové mostrá ocultá""".split()
voseo_re = re.compile(r"(?<![\wáéíóúñ])(" + "|".join(map(re.escape, VOSEO)) + r")(?![\wáéíóúñ])", re.IGNORECASE)

failures, compared, voseo_hits = [], 0, 0
for catalog_path in sys.argv[1:3]:
    catalog = json.load(open(catalog_path, encoding="utf-8"))
    name = os.path.basename(catalog_path)
    for key, entry in catalog.get("strings", {}).items():
        if entry.get("extractionState") == "stale" or entry.get("shouldTranslate") is False:
            continue
        localizations = entry.get("localizations", {})
        es = leaves(localizations.get("es"))
        en = leaves(localizations.get("en")) if "en" in localizations else {(): key}
        for path, es_value in es.items():
            en_value = en.get(path)
            if en_value is None and path:
                # an ES plural category EN does not have (many): compare with EN's other
                en_value = en.get(path[:-1] + ((path[-1][0], "other"),))
            if en_value is None:
                en_value = next(iter(en.values()), None)
            if en_value is None:
                failures.append(f"{name}: {key!r}: no EN value to compare the ES value with")
                continue
            compared += 1
            if specifiers(en_value) != specifiers(es_value):
                failures.append(
                    f"{name}: {key!r}: specifiers differ, EN {sorted(specifiers(en_value).elements())} "
                    f"vs ES {sorted(specifiers(es_value).elements())}: {es_value!r}")
            for m in voseo_re.finditer(es_value):
                voseo_hits += 1
                failures.append(f"{name}: {key!r}: voseo form {m.group(1)!r} in {es_value!r}")

# Raw literals reaching the UI without the catalog.
PATTERNS = [
    r'NSMenuItem\(title:\s*"', r'\bmessageText\s*=\s*"', r'\binformativeText\s*=\s*"',
    r'addButton\(withTitle:\s*"', r'setAccessibilityLabel\(\s*"', r'\btoolTip\s*=\s*"',
    r'(?<![\w.])title\s*=\s*"', r'\.title\s*=\s*"', r'Text\(verbatim:\s*"',
]
raw_re = re.compile("|".join("(?:%s)" % p for p in PATTERNS))
# literal source text -> reason. Anything else fails.
ALLOWED = {
    "Metr": "the product name, identical in every language",
    "—": "a typographic dash for a missing value, no words",
    "\\u{00A0}": "a no-break space that reserves a line of height, no words",
}
allowed_count = 0
for path in sorted(glob.glob("Metr/**/*.swift", recursive=True)):
    if path.startswith("Metr/Debug/"):
        continue
    stack = []  # "debug", "notdebug" or "other" per open #if
    for number, line in enumerate(open(path, encoding="utf-8"), 1):
        code = line.strip()
        if code.startswith("#if"):
            if re.fullmatch(r"#if\s+DEBUG", code):
                stack.append("debug")
            elif re.fullmatch(r"#if\s+!\s*DEBUG", code):
                stack.append("notdebug")
            else:
                stack.append("other")
            continue
        if code.startswith("#else") or code.startswith("#elseif"):
            if stack and stack[-1] == "debug":
                stack[-1] = "notdebug"
            elif stack and stack[-1] == "notdebug":
                stack[-1] = "debug"
            continue
        if code.startswith("#endif"):
            if stack:
                stack.pop()
            continue
        if "debug" in stack or code.startswith("//"):
            continue
        for m in raw_re.finditer(line):
            rest = line[m.end():]
            literal = re.match(r'((?:[^"\\]|\\.)*)"', rest)
            text = literal.group(1) if literal else rest.strip()
            if text in ALLOWED:
                allowed_count += 1
            else:
                failures.append(f'{path}:{number}: raw string literal "{text}" reaches the UI without String(localized:)')

if failures:
    print("FAIL:")
    for f in failures:
        print("  " + f)
    sys.exit(1)
print(f"specifiers={compared} voseo={voseo_hits} rawliterals={allowed_count}")
PY
checks="$(python3 -I "$CHECKS_PY" "$CATALOG" "$INFOPLIST_CATALOG")" && rc=0 || rc=$?
rm -f "$CHECKS_PY"
[ "$rc" = "0" ] || { echo "$checks"; exit 1; }

echo "L10N OK keys=$keys extracted=$extracted infoplist=$infoplist $checks"
