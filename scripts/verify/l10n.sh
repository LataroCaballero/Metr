#!/usr/bin/env bash
# Usage: scripts/verify/l10n.sh
# Fails when any String Catalog key lacks a translated, non-empty ES value.
# When METR_APP_RELEASE exists, also requires es.lproj/Localizable.strings in the bundle.
# Also fails when the keys the compiler extracted from the Swift sources (the newest Debug or Release
# build's *.stringsdata, "Localizable" table) differ from the catalog's non-stale keys, in either
# direction: a used key missing from the catalog, or a catalog key no code uses.
# Prints "L10N OK keys=<n> extracted=<n>".
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

CATALOG="Metr/Localizable.xcstrings"
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

echo "L10N OK keys=$keys extracted=$extracted"
