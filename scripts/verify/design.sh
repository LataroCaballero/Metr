#!/usr/bin/env bash
# Usage: scripts/verify/design.sh
# DSGN-01 grep gates (UI-SPEC "Audit Contracts", DSGN-01): Metr keeps the first-party Liquid Glass look
# because it adds nothing of its own to it. Over the Swift sources and project files of Metr/ (comment
# lines are ignored), the gate fails on
#   - a custom visual-effect view, a glass-effect modifier or container, or the Liquid Glass opt-out key;
#   - a glass button style anywhere but Metr/Welcome/WelcomeView.swift (the Done button);
#   - a system material passed to a background modifier that is not on the in-script allowlist below;
#   - any .background( at all in Metr/Settings/ (the Settings form stays system-drawn, no color);
#   - an icon-only control (the panel gear, the Top Apps quit button, the window toolbar Quit) that does
#     not carry both a tooltip (.help) and an accessibility label within its modifier chain.
# The forbidden names are split below so this script never matches itself.
# Prints "DESIGN OK materials=<n> glassbuttons=<n> iconlabels=<n>".
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh


python3 -I - <<'PY'
import glob, os, re, sys

visual_effect = "NSVisualEffect" + "View"
glass_names = ["glass" + "Effect", "Glass" + "EffectContainer", "NSGlass" + "EffectView"]
optout_key = "UIDesignRequires" + "Compatibility"
glass_button = re.compile(r"\.buttonStyle\(\s*\.glass")

# file: reason. A system material passed to a background modifier must be listed here.
MATERIAL_ALLOWED = {
    "Metr/Window/Charts/HistoryChart.swift": "hover readout chip; Reduce Transparency makes it opaque",
}
GLASS_BUTTON_FILES = {"Metr/Welcome/WelcomeView.swift"}

# Icon-only controls: (file, symbol). Both a tooltip and an accessibility label must follow the Image(systemName:
# within WINDOW lines (the control's modifier chain).
ICON_CONTROLS = [
    ("Metr/Panel/PanelView.swift", "gearshape"),
    ("Metr/Panel/TopApps/TopAppRow.swift", "xmark.circle.fill"),
    ("Metr/Window/Processes/ProcessesSectionView.swift", "xmark.circle"),
]
WINDOW = 16

failures = []
material_uses = 0
glass_buttons = 0
icon_labels = 0

sources = sorted(glob.glob("Metr/**/*.swift", recursive=True))
text_files = sources + sorted(
    f for f in glob.glob("Metr/**/*", recursive=True)
    if os.path.isfile(f) and f.endswith((".plist", ".entitlements", ".xcconfig", ".json"))
) + ["Metr.xcodeproj/project.pbxproj"]

def code_lines(path):
    """(number, line) of each non-comment line."""
    out = []
    for number, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
        if line.strip().startswith("//"):
            continue
        out.append((number, line.rstrip("\n")))
    return out

for path in text_files:
    for number, line in code_lines(path):
        if optout_key in line:
            failures.append(f"{path}:{number}: the Liquid Glass opt-out key {optout_key}")
        if path.endswith(".swift"):
            if visual_effect in line:
                failures.append(f"{path}:{number}: custom visual-effect view {visual_effect}")
            for name in glass_names:
                if name in line:
                    failures.append(f"{path}:{number}: glass modifier or container {name}")

material = re.compile(r"\.(ultraThin|thin|regular|thick|ultraThick)Material\b|\.bar\b|\bMaterial\.")
background_call = re.compile(r"\.(background|containerBackground|toolbarBackground)\(")
for path in sources:
    lines = code_lines(path)
    for index, (number, line) in enumerate(lines):
        if glass_button.search(line):
            if path in GLASS_BUTTON_FILES:
                glass_buttons += 1
            else:
                failures.append(f"{path}:{number}: glass button style outside the welcome window")
        if path.startswith("Metr/Settings/") and ".background(" in line:
            failures.append(f"{path}:{number}: .background( in the Settings window (it stays system-drawn)")
        if background_call.search(line):
            # the call and the two lines after it (a multi-line argument list)
            window = " ".join(l for _, l in lines[index:index + 3])
            if material.search(window):
                if path in MATERIAL_ALLOWED:
                    material_uses += 1
                else:
                    failures.append(f"{path}:{number}: system material on a background, not on the allowlist")

for path, symbol in ICON_CONTROLS:
    lines = code_lines(path)
    found = False
    for index, (number, line) in enumerate(lines):
        if f'Image(systemName: "{symbol}")' in line:
            found = True
            chain = "\n".join(l for _, l in lines[index:index + WINDOW])
            has_help = ".help(" in chain
            has_label = ".accessibilityLabel(" in chain
            if has_help and has_label:
                icon_labels += 1
            else:
                missing = [w for w, ok in (("tooltip (.help)", has_help), ("accessibility label", has_label)) if not ok]
                failures.append(f"{path}:{number}: icon-only control {symbol} lacks " + " and ".join(missing))
    if not found:
        failures.append(f"{path}: icon-only control {symbol} not found (the gate's control list is stale)")

if failures:
    for f in failures:
        print("FAIL: " + f)
    sys.exit(1)
print(f"DESIGN OK materials={material_uses} glassbuttons={glass_buttons} iconlabels={icon_labels}")
PY
