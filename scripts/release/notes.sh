#!/usr/bin/env bash
# Usage: scripts/release/notes.sh VERSION DMG OUT
# Writes the GitHub Release body (UI-SPEC "Release notes template") to OUT: the `Metr <version>` heading,
# a two-line summary, Install, a fenced block with the DMG's SHA-256 and the shasum command, Requirements
# and Known issues, then the same in Spanish below a horizontal rule. No marketing copy.
# The SHA-256 is computed from DMG; if DMG.sha256 sits next to it, the two must agree (T-04-17).
# The wording never advises right-click Open or a global Gatekeeper switch-off, and every mention of
# notarization says the build is not notarized (it is ad-hoc signed, D-23).
# Prints "NOTES OK sha256=<hex>". Exit 2 on bad arguments, 1 on any failure.
set -euo pipefail

fail() { echo "FAIL: $1" >&2; exit 1; }
usage() { echo "usage: scripts/release/notes.sh VERSION DMG OUT" >&2; exit 2; }

[ "$#" -eq 3 ] || usage
VERSION="$1"; DMG="$2"; OUT="$3"

VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$'
[[ "$VERSION" =~ $VERSION_RE ]] || { echo "FAIL: version '$VERSION' is not <major>.<minor>.<patch> with an optional -rc.<n>" >&2; exit 2; }
[ -f "$DMG" ] || fail "DMG not found: $DMG"
NAME="Metr-$VERSION.dmg"
[ "$(basename "$DMG")" = "$NAME" ] || fail "the DMG is named $(basename "$DMG"), expected $NAME"

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || fail "could not compute the SHA-256"
if [ -f "$DMG.sha256" ]; then
  [ "$(cut -d' ' -f1 "$DMG.sha256")" = "$SHA" ] || fail "$NAME.sha256 does not match the DMG"
fi

README_URL="https://github.com/LataroCaballero/Metr#install"
README_ES_URL="https://github.com/LataroCaballero/Metr/blob/main/README.es.md"

TMP="$OUT.tmp.$$"
trap 'rm -f -- "$TMP"' EXIT

cat > "$TMP" <<EOF
# Metr $VERSION

See exactly how much your Mac is using and which app is using it, from the menu bar.
Native, light and free, and open source. Apple Silicon only.

## Install

1. Download \`$NAME\` and drag Metr to Applications.
2. Open Metr. macOS stops it the first time because this build is ad-hoc signed and not notarized.
3. Allow it once in System Settings › Privacy & Security › Open Anyway.

All the steps are in the [README]($README_URL).

To check your download:

\`\`\`
$SHA  $NAME
shasum -a 256 $NAME
\`\`\`

## Requirements

Apple Silicon, macOS 26 or later.

## Known issues

- Memory grows a little with each open and close of the window (an AppKit issue in the window chrome).
- The build is ad-hoc signed and not notarized, which is why macOS asks for Open Anyway.

---

# Metr $VERSION

Mira cuánto está usando tu Mac y qué app lo usa, desde la barra de menús.
Nativa, ligera y gratuita, y de código abierto. Solo para Apple Silicon.

## Instalación

1. Descarga \`$NAME\` y arrastra Metr a Aplicaciones.
2. Abre Metr. macOS la bloquea la primera vez porque esta versión está firmada ad hoc y no está notarizada.
3. Permítela una vez en Ajustes del Sistema › Privacidad y seguridad › Abrir igualmente (en Latinoamérica el botón se llama «Abrir de todos modos»).

Todos los pasos están en el [README]($README_ES_URL).

Para comprobar tu descarga:

\`\`\`
$SHA  $NAME
shasum -a 256 $NAME
\`\`\`

## Requisitos

Apple Silicon, macOS 26 o posterior.

## Problemas conocidos

- La memoria crece un poco cada vez que abres y cierras la ventana (un problema de AppKit en el marco de la ventana).
- Esta versión está firmada ad hoc y no está notarizada, por eso macOS te pide Abrir igualmente.
EOF

mv -f -- "$TMP" "$OUT"
echo "NOTES OK sha256=$SHA"
