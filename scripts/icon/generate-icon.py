#!/usr/bin/env python3
"""Generates the Metr app icon as an Icon Composer `.icon` bundle.

Stdlib only, Python 3.9 compatible. Run with `python3 -I`.

Usage: python3 -I scripts/icon/generate-icon.py [--out DIR]
       (default DIR: Metr/AppIcon.icon, relative to the repository root)

Geometry and colors are the 04-UI-SPEC "App Icon Contract" table. Every arc is a
FILLED OUTLINE (an annular sector closed with two semicircular caps), never an open
stroke: an open path on a glass layer renders a chord artifact (RESEARCH Pitfall 3).
Writes only under --out.
"""
import argparse
import json
import math
import os
import sys

CENTER = 512
STROKE = 72
# name, center-line radius, fill fraction (all under 0.90 on purpose: not a closed ring)
RINGS = [("cpu", 308, 0.70), ("memory", 196, 0.45), ("disk", 84, 0.85)]

BACKGROUND = ("srgb:0.22745,0.23137,0.25098,1.00000", "srgb:0.10588,0.10980,0.12157,1.00000")  # #3A3B40 -> #1B1C1F
BACKGROUND_DARK = ("srgb:0.12157,0.12549,0.13725,1.00000", "srgb:0.04314,0.04314,0.04706,1.00000")  # #1F2023 -> #0B0B0C

SVG_HEAD = '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
SVG_TAIL = "</svg>\n"


def _pt(radius, angle):
    return (CENTER + radius * math.cos(angle), CENTER + radius * math.sin(angle))


def arc_outline(radius, fraction):
    """Filled outline of a clockwise arc from 12 o'clock with round caps."""
    ro, ri, cap = radius + STROKE / 2, radius - STROKE / 2, STROKE / 2
    a0 = -math.pi / 2
    a1 = a0 + 2 * math.pi * fraction
    o0, o1, i1, i0 = _pt(ro, a0), _pt(ro, a1), _pt(ri, a1), _pt(ri, a0)
    large = 1 if fraction > 0.5 else 0
    return (
        f"M {o0[0]:.2f} {o0[1]:.2f} "
        f"A {ro:g} {ro:g} 0 {large} 1 {o1[0]:.2f} {o1[1]:.2f} "
        f"A {cap:g} {cap:g} 0 0 1 {i1[0]:.2f} {i1[1]:.2f} "
        f"A {ri:g} {ri:g} 0 {large} 0 {i0[0]:.2f} {i0[1]:.2f} "
        f"A {cap:g} {cap:g} 0 0 1 {o0[0]:.2f} {o0[1]:.2f} Z"
    )


def arc_svg(radius, fraction):
    return SVG_HEAD + f'  <path d="{arc_outline(radius, fraction)}" fill="#FFFFFF"/>\n' + SVG_TAIL


def annulus(radius):
    ro, ri = radius + STROKE / 2, radius - STROKE / 2
    c = CENTER

    def circle(r):
        return f"M {c - r:g} {c} A {r:g} {r:g} 0 1 1 {c + r:g} {c} A {r:g} {r:g} 0 1 1 {c - r:g} {c} Z"

    return circle(ro) + " " + circle(ri)


def tracks_svg():
    d = " ".join(annulus(r) for _, r, _ in RINGS)
    return SVG_HEAD + f'  <path d="{d}" fill="#FFFFFF" fill-opacity="0.16" fill-rule="evenodd"/>\n' + SVG_TAIL


def icon_json():
    def group(name, glass, shadow_kind):
        return {
            "layers": [{"glass": glass, "image-name": f"{name}.svg", "name": name}],
            "shadow": {"kind": shadow_kind, "opacity": 0.5},
            "translucency": {"enabled": False, "value": 0.5},
        }

    groups = [group("tracks", False, "none")] + [group(n, True, "neutral") for n, _, _ in RINGS]
    return {
        "fill": {"linear-gradient": list(BACKGROUND)},
        "fill-specializations": [
            {"value": {"linear-gradient": list(BACKGROUND)}},
            {"appearance": "dark", "value": {"linear-gradient": list(BACKGROUND_DARK)}},
        ],
        "groups": groups,
        "supported-platforms": {"squares": "shared"},
    }


def write(path, text):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def main(argv):
    parser = argparse.ArgumentParser(description="Generate Metr/AppIcon.icon")
    parser.add_argument("--out", default=None, help="bundle directory to write (default Metr/AppIcon.icon)")
    args = parser.parse_args(argv)

    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    out = os.path.abspath(args.out) if args.out else os.path.join(root, "Metr", "AppIcon.icon")
    assets = os.path.join(out, "Assets")
    os.makedirs(assets, exist_ok=True)

    write(os.path.join(assets, "tracks.svg"), tracks_svg())
    for name, radius, fraction in RINGS:
        write(os.path.join(assets, f"{name}.svg"), arc_svg(radius, fraction))
    write(os.path.join(out, "icon.json"), json.dumps(icon_json(), indent=2, sort_keys=True) + "\n")

    layers = sum(len(g["layers"]) for g in icon_json()["groups"])
    print(f"ICON GENERATED groups={len(icon_json()['groups'])} layers={layers}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
