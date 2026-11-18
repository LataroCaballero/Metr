#!/usr/bin/env bash
# Usage: scripts/verify/readme.sh [--strict]
# The README gate (DIST-03, DIST-04, DIST-05; T-04-23, T-04-24, T-04-25). Reads README.md and README.es.md
# and docs/footprint.env and fails with "FAIL: <what>" and exit 1 on:
#   mirror     the first line of each file links the other; the same number of sections (11: the title, the
#              hero and nine `## ` sections); the same footprint rows in the same order (Idle, Panel open,
#              Window open);
#   required   README.md: Open Anyway, System Settings › Privacy & Security, System Settings › Menu Bar, the
#              UI-SPEC zero-telemetry sentence, nettop, MIT, Apple Silicon, macOS 26, shasum -a 256 and the
#              per-app quarantine-removal command; README.es.md: Abrir igualmente, Abrir de todos modos,
#              Ajustes del Sistema › Privacidad y seguridad, Barra de menús, the Spanish sentence and MIT;
#   forbidden  in both: the global Gatekeeper switch-off command, right-click or Control-click Open advice (EN
#              and ES wording), and any line that mentions notarization without saying Metr is not notarized;
#   images     4 <picture> elements per file, each with a prefers-color-scheme dark source; the paths across
#              both files are exactly the 14 PNGs of the Screenshot contract; an existing one is at most
#              400 KB and counts toward images=, a missing one prints "README PENDING <path>" and counts
#              toward pending= (no failure without --strict);
#   numbers    every number of the footprint block equals docs/footprint.env formatted as
#              scripts/release/readme-footprint.sh does (English point, Spanish comma), computed again here.
# --strict (run before publishing, 04-13): all 14 images exist, the soak line is not pending and the version
# in the machine line equals the project's MARKETING_VERSION (an rc table cannot pass as a 1.0.0 table).
# The soak line must be present and be one of two sentences: the measured soak, or the explicit waiver. The
# waiver sentence passes only while budget.env carries SOAK_WAIVED_CDHASH equal to the footprint's
# FOOTPRINT_SHIPPED_CDHASH and a non-empty SOAK_WAIVED_BY; a missing soak line still fails.
# Prints README PENDING lines, then
#   README OK sections=11 pictures=4 images=<existing> pending=<missing> numbers=<n>   (strict appends " strict=1")
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
STRICT=0
case "${1:-}" in
  "") ;;
  --strict) STRICT=1 ;;
  *) echo "usage: scripts/verify/readme.sh [--strict]" >&2; exit 2 ;;
esac

MARKETING="$(awk '/^[[:space:]]*MARKETING_VERSION = /{ sub(/^[^=]*= /, ""); sub(/;$/, ""); print; exit }' Metr.xcodeproj/project.pbxproj)"

STRICT="$STRICT" MARKETING="$MARKETING" python3 -I - <<'PY'
import os, re, sys
from decimal import Decimal, ROUND_HALF_UP

strict = os.environ["STRICT"] == "1"
marketing = os.environ["MARKETING"]

def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)

def read(path):
    try:
        return open(path, encoding="utf-8").read()
    except OSError:
        fail(f"cannot read {path}")

en = read("README.md")
es = read("README.es.md")
NBSP = " "

# --- mirror: language links, sections ---------------------------------------------------------
if "README.es.md" not in en.split("\n", 1)[0]:
    fail("README.md must link README.es.md on its first line")
if "README.md" not in es.split("\n", 1)[0]:
    fail("README.es.md must link README.md on its first line")

def sections(text, name):
    h1 = len(re.findall(r"^# \S", text, re.M))
    h2 = len(re.findall(r"^## \S", text, re.M))
    first_h2 = re.search(r"^## ", text, re.M)
    head = text[: first_h2.start()] if first_h2 else text
    hero = 1 if "<picture>" in head else 0
    if h1 != 1:
        fail(f"{name} needs exactly one title (found {h1})")
    if not hero:
        fail(f"{name} has no hero picture before its first section")
    return 1 + hero + h2

s_en, s_es = sections(en, "README.md"), sections(es, "README.es.md")
if s_en != s_es:
    fail(f"README.md has {s_en} sections and README.es.md has {s_es}")
if s_en != 11:
    fail(f"expected 11 sections (title, hero and nine second-level headings), found {s_en}")

# --- required content --------------------------------------------------------------------------
EN_SENTENCE = ("Metr makes no network connections: no telemetry, no analytics, no update check, no accounts. "
               "Everything it shows is read locally from your Mac.")
ES_SENTENCE = ("Metr no realiza conexiones de red: sin telemetría, sin analíticas, sin comprobación de actualizaciones, "
               "sin cuentas. Todo lo que muestra se lee localmente en tu Mac.")
for needle in ["Open Anyway", "System Settings › Privacy & Security", "System Settings › Menu Bar", EN_SENTENCE,
               "nettop", "MIT", "Apple Silicon", "macOS 26", "shasum -a 256",
               "xattr -dr com.apple.quarantine /Applications/Metr.app"]:
    if needle not in en:
        fail(f"README.md is missing required text: {needle}")
for needle in ["Abrir igualmente", "Abrir de todos modos", "Ajustes del Sistema › Privacidad y seguridad",
               "Barra de menús", ES_SENTENCE, "MIT"]:
    if needle not in es:
        fail(f"README.es.md is missing required text: {needle}")

# --- forbidden content (literals split so this script never matches itself) ---------------------
forbidden = [
    "spctl --master" + "-disable", "spctl --global" + "-disable", "Anywhere",
    "right" + "-click", "right" + " click", "control" + "-click", "control" + " click", "ctrl" + "-click",
    "clic " + "derecho", "clic con el " + "botón derecho", "botón " + "derecho", "control" + "-clic", "clic " + "con control",
]
for name, text in (("README.md", en), ("README.es.md", es)):
    low = text.lower()
    for bad in forbidden:
        if bad.lower() in low:
            fail(f"{name} contains forbidden advice: {bad}")
    for line in text.splitlines():
        if re.search(r"notari[sz]", line, re.I) and not re.search(
                r"not notarized|no está notarizada|no esta notarizada|no están notarizadas", line, re.I):
            fail(f"{name} mentions notarization without saying Metr is not notarized: {line.strip()}")

# --- images ----------------------------------------------------------------------------------------
EXPECTED = {f"docs/screenshots/menubar-{s}.png" for s in ("light", "dark")}
for lang in ("en", "es"):
    for shot in ("panel", "window-cpu", "window-processes"):
        for s in ("light", "dark"):
            EXPECTED.add(f"docs/screenshots/{lang}/{shot}-{s}.png")

paths = set()
for name, text, lang in (("README.md", en, "en"), ("README.es.md", es, "es")):
    pictures = re.findall(r"<picture>.*?</picture>", text, re.S)
    if len(pictures) != 4:
        fail(f"{name} has {len(pictures)} <picture> elements, expected 4")
    own = set()
    for pic in pictures:
        if not re.search(r'<source[^>]*media="\(prefers-color-scheme: dark\)"', pic):
            fail(f"{name} has a <picture> without a prefers-color-scheme: dark source")
        refs = re.findall(r'(?:srcset|src)="([^"]+)"', pic)
        if len(refs) != 2:
            fail(f"{name} has a <picture> that does not name exactly a dark and a light image")
        own.update(refs)
    other = "es" if lang == "en" else "en"
    for ref in own:
        if f"/{other}/" in ref:
            fail(f"{name} points at the other language's image: {ref}")
    paths |= own
if paths != EXPECTED:
    missing = sorted(EXPECTED - paths)
    extra = sorted(paths - EXPECTED)
    fail(f"the READMEs do not reference exactly the 14 screenshot PNGs (not referenced: {missing}; unexpected: {extra})")

existing = pending = 0
for path in sorted(paths):
    if os.path.isfile(path):
        kb = (os.path.getsize(path) + 1023) // 1024
        if kb > 400:
            fail(f"{path} is {kb} KB, over 400 KB")
        existing += 1
    else:
        print(f"README PENDING {path}")
        pending += 1
if strict and pending:
    fail(f"--strict: {pending} of the 14 screenshots are missing")

# --- footprint numbers ----------------------------------------------------------------------------
env = {}
try:
    for line in open("docs/footprint.env", encoding="utf-8"):
        line = line.rstrip("\n")
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k] = v
except OSError:
    fail("docs/footprint.env is missing (run scripts/release/measure-footprint.sh)")
for key in ["IDLE_CPU_PCT", "IDLE_MEMORY_MB", "IDLE_WAKEUPS", "PANEL_CPU_PCT", "PANEL_METR_CPU_PCT", "PANEL_TOP_CPU_PCT",
            "PANEL_MEMORY_MB", "PANEL_WAKEUPS", "WINDOW_CPU_PCT", "WINDOW_MEMORY_MB", "WINDOW_WAKEUPS",
            "WINDOW_CYCLES_GROWTH_MB", "FOOTPRINT_VERSION", "FOOTPRINT_MAC", "FOOTPRINT_MACOS", "FOOTPRINT_BUILD"]:
    if key not in env or not env[key]:
        fail(f"docs/footprint.env has no {key}")

def rnd(value, places):
    return str(Decimal(value).quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP))

def fmt(value, places, lang):
    text = rnd(value, places)
    return text.replace(".", ",") if lang == "es" else text

def block(text, name):
    if text.count("<!-- footprint:start -->") != 1 or text.count("<!-- footprint:end -->") != 1:
        fail(f"{name} needs exactly one footprint:start and footprint:end")
    return text.split("<!-- footprint:start -->", 1)[1].split("<!-- footprint:end -->", 1)[0]

budget = {}
try:
    for line in open("scripts/perf/budget.env", encoding="utf-8"):
        line = line.rstrip("\n")
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            budget[k] = v
except OSError:
    fail("scripts/perf/budget.env is missing")

numbers = 0
waived = 0
ROWS = [("IDLE", {"en": "Idle", "es": "En reposo"}),
        ("PANEL", {"en": "Panel open", "es": "Panel abierto"}),
        ("WINDOW", {"en": "Window open", "es": "Ventana abierta"})]
for name, text, lang in (("README.md", en, "en"), ("README.es.md", es, "es")):
    body = block(text, name)
    rows = [l for l in body.splitlines() if l.startswith("|")][2:]
    if len(rows) != 3:
        fail(f"{name} footprint table has {len(rows)} rows, expected 3")
    for row, (key, labels) in zip(rows, ROWS):
        cells = [c.strip() for c in row.strip("|").split("|")]
        if len(cells) != 4 or not cells[0].startswith(labels[lang]):
            fail(f"{name} footprint row out of order or malformed (expected {labels[lang]}): {row}")
        cpu = fmt(env[f"{key}_CPU_PCT"], 2, lang) + (NBSP + "%" if lang == "es" else "%")
        mem = fmt(env[f"{key}_MEMORY_MB"], 1, lang) + (NBSP if lang == "es" else " ") + "MB"
        wake = fmt(env[f"{key}_WAKEUPS"], 1, lang)
        for got, want, what in ((cells[1], cpu, "CPU"), (cells[2], mem, "memory"), (cells[3], wake, "wakeups")):
            if got != want:
                fail(f"{name} {key} {what} cell is '{got}', docs/footprint.env says '{want}'")
            numbers += 1
    # The other generated numbers: the panel split and the cycles figure.
    for key, places in (("PANEL_METR_CPU_PCT", 2), ("PANEL_TOP_CPU_PCT", 2)):
        want = fmt(env[key], places, lang)
        if want not in body:
            fail(f"{name} footprint block does not carry {key} ({want})")
        numbers += 1
    raw_idle = env["IDLE_CPU_PCT"].replace(".", ",") if lang == "es" else env["IDLE_CPU_PCT"]
    if raw_idle not in body:
        fail(f"{name} footprint block does not carry the idle CPU as stored ({raw_idle})")
    numbers += 1
    growth = fmt(env["WINDOW_CYCLES_GROWTH_MB"], 1, lang)
    if growth not in body:
        fail(f"{name} footprint block does not carry the cycles figure ({growth})")
    numbers += 1
    version = re.search(r"Metr (\S+) \(", body)
    if not version or version.group(1) != env["FOOTPRINT_VERSION"]:
        fail(f"{name} machine line does not name Metr {env['FOOTPRINT_VERSION']}")
    if env["FOOTPRINT_MAC"] not in body or env["FOOTPRINT_MACOS"] not in body:
        fail(f"{name} machine line does not name the Mac and macOS version of docs/footprint.env")
    if strict:
        if version.group(1) != marketing:
            fail(f"--strict: {name} footprint is for Metr {version.group(1)}, the project is {marketing}")
        if re.search(r"pending|pendiente", body, re.I):
            fail(f"--strict: {name} footprint still has a pending line (the 24 hour soak on this build)")
        measured_line = ("24 hour soak on this build:", "Prueba de 24 horas con esta compilación:")[lang == "es"]
        waived_line = ("No 24 hour soak was run on this build", "No se hizo la prueba de 24 horas con esta compilación")[lang == "es"]
        if waived_line in body:
            if not budget.get("SOAK_WAIVED_BY", "").strip() or budget.get("SOAK_WAIVED_CDHASH", "") != env["FOOTPRINT_SHIPPED_CDHASH"]:
                fail(f"--strict: {name} says the soak was waived, but budget.env has no owner waiver for CDHash {env['FOOTPRINT_SHIPPED_CDHASH']}")
            waived += 1
        elif measured_line not in body:
            fail(f"--strict: {name} footprint has no soak line (neither a measured soak nor an explicit waiver)")

sections_n = s_en
tail = (" strict=1" + (" soak=waived" if waived else "")) if strict else ""
print(f"README OK sections={sections_n} pictures=4 images={existing} pending={pending} numbers={numbers}{tail}")
PY
