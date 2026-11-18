#!/usr/bin/env bash
# Usage: scripts/release/readme-footprint.sh
# Formats docs/footprint.env (written by scripts/release/measure-footprint.sh) into the footprint block of
# README.md and README.es.md, between the <!-- footprint:start --> and <!-- footprint:end --> markers.
# Only the text between the markers changes. Every number in the block is read from docs/footprint.env
# (or scripts/perf/budget.env for the budget and the soak) and formatted here, never typed (D-19, D-24):
#   - CPU with two decimals, memory and wakeups with one, rounded half up from the stored value;
#   - the method line also gives the idle CPU as stored (three decimals), so a rounding tie is visible;
#   - English: decimal point, `0.19%`; Spanish: decimal comma and a non-breaking space before % and MB.
# The soak line is shown only when the soak's logged CDHash (SOAK START in $METR_LOGS/soak-24h.out) is the
# CDHash of the build that was measured and the soak finished after it started. Otherwise, when budget.env
# carries an explicit owner waiver for exactly this build (SOAK_WAIVED_CDHASH equal to FOOTPRINT_SHIPPED_CDHASH
# and a non-empty SOAK_WAIVED_BY), the block says honestly that no 24 hour soak was run. With neither, the block
# says the soak is pending (and readme.sh --strict fails). A waiver never carries over to another build.
# Prints "README-FOOTPRINT OK rows=3 soak=<ok|waived|pending>" or "FAIL: <reason>" with exit 1.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

[ -f docs/footprint.env ] || { echo "FAIL: docs/footprint.env is missing (run scripts/release/measure-footprint.sh)" >&2; exit 1; }

METR_ROOT="$METR_ROOT" METR_LOGS="$METR_LOGS" python3 -I - <<'PY'
import os, re, sys
from datetime import datetime
from decimal import Decimal, ROUND_HALF_UP

root = os.environ["METR_ROOT"]
logs = os.environ["METR_LOGS"]

def fail(msg):
    print("FAIL: " + msg, file=sys.stderr)
    sys.exit(1)

def read_env(path):
    out = {}
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k] = v
    return out

env = read_env(os.path.join(root, "docs/footprint.env"))
budget = read_env(os.path.join(root, "scripts/perf/budget.env"))

NUMBER = re.compile(r"^[0-9]+(\.[0-9]+)?$")
for key in ["IDLE_CPU_PCT", "IDLE_MEMORY_MB", "IDLE_WAKEUPS", "PANEL_CPU_PCT", "PANEL_METR_CPU_PCT",
            "PANEL_TOP_CPU_PCT", "PANEL_MEMORY_MB", "PANEL_WAKEUPS", "WINDOW_CPU_PCT", "WINDOW_MEMORY_MB",
            "WINDOW_WAKEUPS", "WINDOW_CYCLES_GROWTH_MB", "WINDOW_CYCLES_N"]:
    if not NUMBER.match(env.get(key, "")):
        fail(f"docs/footprint.env has no plain number for {key}")
for key in ["FOOTPRINT_VERSION", "FOOTPRINT_BUILD", "FOOTPRINT_SHIPPED_CDHASH", "FOOTPRINT_MAC",
            "FOOTPRINT_MACOS", "FOOTPRINT_AT"]:
    if not env.get(key):
        fail(f"docs/footprint.env has no {key}")

NBSP = " "

def rnd(value, places):
    q = Decimal(1).scaleb(-places)
    return str(Decimal(value).quantize(q, rounding=ROUND_HALF_UP))

def num(value, places, lang):
    text = rnd(value, places)
    return text.replace(".", ",") if lang == "es" else text

def pct(value, lang):
    return (num(value, 2, lang) + NBSP + "%") if lang == "es" else (num(value, 2, lang) + "%")

def mb(value, lang):
    return num(value, 1, lang) + (NBSP if lang == "es" else " ") + "MB"

# Soak: only when it ran on this exact build and finished after it started.
soak = "pending"
soak_values = None
try:
    starts = [l for l in open(os.path.join(logs, "soak-24h.out"), encoding="utf-8", errors="replace")
              if l.startswith("SOAK START ")]
except OSError:
    starts = []
if starts:
    m = re.search(r"cdhash=([0-9a-f]+) at=(\S+)", starts[-1])
    if m and m.group(1) == env["FOOTPRINT_SHIPPED_CDHASH"]:
        try:
            started = datetime.strptime(m.group(2), "%Y-%m-%dT%H:%M:%SZ")
            finished = datetime.strptime(budget.get("MEASURED_SOAK_AT", ""), "%Y-%m-%dT%H:%M:%SZ")
        except ValueError:
            started = finished = None
        if (started and finished and finished > started and budget.get("MEASURED_SOAK_RESULT") == "OK"
                and all(NUMBER.match(budget.get(k, "").lstrip("-")) for k in
                        ["MEASURED_SOAK_SLOPE_MB_PER_HOUR", "MEASURED_SOAK_HOURS", "MEASURED_SOAK_LEAKS_DELTA"])):
            soak = "ok"
            soak_values = (budget["MEASURED_SOAK_SLOPE_MB_PER_HOUR"], budget["MEASURED_SOAK_HOURS"],
                           budget["MEASURED_SOAK_LEAKS_DELTA"])

if soak == "pending" and budget.get("SOAK_WAIVED_BY", "").strip() \
        and budget.get("SOAK_WAIVED_CDHASH", "") == env["FOOTPRINT_SHIPPED_CDHASH"]:
    soak = "waived"

date = env["FOOTPRINT_AT"][:10]
cdhash = env["FOOTPRINT_SHIPPED_CDHASH"][:12]
cycles_n = int(env["WINDOW_CYCLES_N"])

def block(lang):
    en = lang == "en"
    if en:
        head = "| State | CPU (% of one core) | Memory | Wakeups/s |"
        rows = [("Idle (panel closed), release build", "IDLE"),
                ("Panel open, optimized build with measurement hooks", "PANEL"),
                ("Window open, optimized build with measurement hooks", "WINDOW")]
    else:
        head = "| Estado | CPU (% de un núcleo) | Memoria | Activaciones/s |"
        rows = [("En reposo (panel cerrado), compilación de lanzamiento", "IDLE"),
                ("Panel abierto, compilación optimizada con ganchos de medición", "PANEL"),
                ("Ventana abierta, compilación optimizada con ganchos de medición", "WINDOW")]
    lines = [head, "|---|---|---|---|"]
    for label, key in rows:
        cpu = env[f"{key}_CPU_PCT"]
        lines.append(f"| {label} | {pct(cpu, lang)} | {mb(env[key + '_MEMORY_MB'], lang)} | "
                     f"{num(env[key + '_WAKEUPS'], 1, lang)} |")
    table = "\n".join(lines)

    cpu_max = num(budget["CPU_PCT_MAX"], 2, lang)
    wake_max = num(budget["WAKEUPS_PER_SEC_MAX"], 1, lang)
    metr_part = pct(env["PANEL_METR_CPU_PCT"], lang)
    top_part = pct(env["PANEL_TOP_CPU_PCT"], lang)
    growth = num(env["WINDOW_CYCLES_GROWTH_MB"], 1, lang)
    # The stored idle value as measured (three decimals), so a rounding tie is never hidden by the table.
    raw_idle = env["IDLE_CPU_PCT"].replace(".", ",") if lang == "es" else env["IDLE_CPU_PCT"]
    if en:
        machine = (f"Measured on a {env['FOOTPRINT_MAC']}, macOS {env['FOOTPRINT_MACOS']}, "
                   f"Metr {env['FOOTPRINT_VERSION']} (build {env['FOOTPRINT_BUILD']}, CDHash {cdhash}), {date}.")
        method = (f"Method: `scripts/perf/` measures Metr's own process with `proc_pid_rusage`. Idle is 300 seconds on the "
                  f"release build; panel and window are 60 seconds on an optimized build with measurement hooks. "
                  f"Panel open includes Metr's streamed `top` child: Metr {metr_part} plus top {top_part}. "
                  f"The idle row is held to the project budget ({cpu_max}% CPU, "
                  f"{wake_max} wakeups/s); it measured {raw_idle}% before rounding.")
        if soak == "ok":
            slope, hours, leaks = soak_values
            sl = ("-" + num(slope[1:], 3, lang)) if slope.startswith("-") else num(slope, 3, lang)
            soak_line = (f"24 hour soak on this build: memory slope {sl} MB/hour "
                         f"over {num(hours, 1, lang)} hours, {leaks} leaks.")
        elif soak == "waived":
            soak_line = ("No 24 hour soak was run on this build: the maintainer chose to skip it for 1.0.0. "
                         "The idle row above is a 300 second measurement, not a soak.")
        else:
            soak_line = "The 24 hour soak on this build is pending."
        issue = (f"Known issue: memory grows a little with each open and close of the window (an AppKit issue in the window "
                 f"chrome). Measured: {growth} MB over {cycles_n} open and close cycles, not counting the first, "
                 f"which loads the window's frameworks.")
    else:
        machine = (f"Medido en un {env['FOOTPRINT_MAC']}, macOS {env['FOOTPRINT_MACOS']}, "
                   f"Metr {env['FOOTPRINT_VERSION']} (compilación {env['FOOTPRINT_BUILD']}, CDHash {cdhash}), {date}.")
        method = (f"Método: `scripts/perf/` mide el proceso de Metr con `proc_pid_rusage`. En reposo son 300 segundos con la "
                  f"compilación de lanzamiento; panel y ventana son 60 segundos con una compilación optimizada con ganchos de "
                  f"medición. Panel abierto incluye el proceso hijo `top` de Metr: Metr {metr_part} más top {top_part}. "
                  f"La fila en reposo cumple el presupuesto del proyecto ({cpu_max}{NBSP}% de CPU, "
                  f"{wake_max} activaciones/s); midió {raw_idle}{NBSP}% antes de redondear.")
        if soak == "ok":
            slope, hours, leaks = soak_values
            sl = ("-" + num(slope[1:], 3, lang)) if slope.startswith("-") else num(slope, 3, lang)
            soak_line = (f"Prueba de 24 horas con esta compilación: pendiente de memoria {sl}{NBSP}MB/hora "
                         f"en {num(hours, 1, lang)} horas, {leaks} fugas.")
        elif soak == "waived":
            soak_line = ("No se hizo la prueba de 24 horas con esta compilación: el responsable del proyecto decidió "
                         "omitirla en la 1.0.0. La fila en reposo es una medición de 300 segundos, no una prueba larga.")
        else:
            soak_line = "La prueba de 24 horas con esta compilación está pendiente."
        issue = (f"Problema conocido: la memoria crece un poco con cada apertura y cierre de la ventana (un problema de AppKit "
                 f"en el marco de la ventana). Medido: {growth}{NBSP}MB en {cycles_n} ciclos de apertura y cierre, sin contar "
                 f"el primero, que carga los frameworks de la ventana.")
    return "\n" + table + "\n\n" + machine + "\n\n" + method + "\n\n" + soak_line + "\n\n" + issue + "\n"

START, END = "<!-- footprint:start -->", "<!-- footprint:end -->"
for path, lang in [("README.md", "en"), ("README.es.md", "es")]:
    full = os.path.join(root, path)
    text = open(full, encoding="utf-8").read()
    if text.count(START) != 1 or text.count(END) != 1 or text.index(START) > text.index(END):
        fail(f"{path} needs exactly one footprint:start before one footprint:end")
    head, rest = text.split(START, 1)
    _, tail = rest.split(END, 1)
    open(full, "w", encoding="utf-8").write(head + START + block(lang) + END + tail)

print(f"README-FOOTPRINT OK rows=3 soak={soak}")
PY
