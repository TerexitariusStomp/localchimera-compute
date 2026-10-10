#!/usr/bin/env bash
# make-icons.sh — the raster icons, drawn from the two SVG sources.
#
#   icon.svg           the mark on its rounded ground   → icon-192, icon-512
#   icon-maskable.svg  full-bleed ground, mark inset    → icon-maskable-512,
#                                                          apple-touch-icon-180
#
# manifest.json, the pages' <link rel="apple-touch-icon"> and the service
# worker's notifications name the PNGs. They are committed; rerun this
# (`make icons`) after editing a source. The λ is set in the profile's
# monospace face, so the run happens inside the pinned shell `make icons` opens.
set -euo pipefail
cd "$(dirname "$0")/../../browser/assets/icons"
r() { rsvg-convert -w "$1" -h "$1" "$2" -o "$3"; }
r 192 icon.svg          icon-192.png
r 512 icon.svg          icon-512.png
r 512 icon-maskable.svg icon-maskable-512.png
r 180 icon-maskable.svg apple-touch-icon-180.png
