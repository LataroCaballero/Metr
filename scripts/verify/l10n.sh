#!/usr/bin/env bash
# Usage: scripts/verify/l10n.sh
# Fails when any String Catalog key lacks a translated, non-empty ES value.
# When METR_APP_RELEASE exists, also requires es.lproj/Localizable.strings in the bundle.
# Prints "L10N OK keys=<n>".
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

keys="$(python3 -I -c 'import json,sys; c=json.load(open(sys.argv[1], encoding="utf-8")); print(sum(1 for e in c["strings"].values() if e.get("extractionState")!="stale" and e.get("shouldTranslate") is not False))' "$CATALOG")"

if [ -d "$METR_APP_RELEASE" ]; then
  [ -s "$METR_APP_RELEASE/Contents/Resources/es.lproj/Localizable.strings" ] \
    || { echo "FAIL: Release bundle has no es.lproj/Localizable.strings" >&2; exit 1; }
fi

echo "L10N OK keys=$keys"
