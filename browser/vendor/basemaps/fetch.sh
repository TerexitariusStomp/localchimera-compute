#!/usr/bin/env bash
# Vendor the basemap style library and its sprites: @protomaps/basemaps (the
# MapLibre layers for a Protomaps OpenStreetMap build, BSD-3) and the
# basemaps-assets light spritesheet (MIT, from tangrams/icons).
#
# The files are COMMITTED: the deploy rsync ships them, the service worker
# caches them, and no page asks a CDN for them. This script is how they are
# updated — bump the version or commit, run it, update the digests it prints,
# commit. The glyphs (10 MB) are not here: tools/emit/map-tiles.sh fetches them at
# deploy time beside the archives, by the same size budget that keeps the
# speech model out of git.
#
# Fetched over Tor by default, by the project's networking policy; NO_TOR=1
# overrides. Each file is checked against its pinned sha256.

set -euo pipefail
cd "$(dirname "$0")"

CURL=("curl" "-sLf")
[[ "${NO_TOR:-0}" == "1" ]] || CURL=("torsocks" "${CURL[@]}")

BASEMAPS_VERSION="5.7.2"
ASSETS_COMMIT="028c18f713baecad011301ff7a69acc39bcc2ae7"
NPM="https://cdn.jsdelivr.net/npm/@protomaps/basemaps@${BASEMAPS_VERSION}"
# the npm package carries no licence file; the repository's, at the commit
# that last touched it
LICENSE_COMMIT="f7bcb4869434030ba23271f43e9dbcf6bfc5d63f"
ASSETS="https://raw.githubusercontent.com/protomaps/basemaps-assets/${ASSETS_COMMIT}"
SPRITES="../../assets/map/sprites"
mkdir -p "$SPRITES"

# local path | url | sha256
FILES=(
  "basemaps.js|$NPM/dist/basemaps.js|551864f01da1bfe3005e99987197f22f56d0c35f9a10fa1727a889e2434af16d"
  "LICENSE.md|https://raw.githubusercontent.com/protomaps/basemaps/$LICENSE_COMMIT/LICENSE.md|74f975cfedd168098c43b5cfd6e587e40604684c4ffcec3e90d24b3b09c061b0"
  "$SPRITES/light.json|$ASSETS/sprites/v4/light.json|bfac76cf7ed5c2aa2992695904056a1c6b07785b7fd20e6c640cb44fd6244a2e"
  "$SPRITES/light.png|$ASSETS/sprites/v4/light.png|b6a34640917bdc57d0bd080836db33376371a3312ebe7b849045268015de3481"
  "$SPRITES/light@2x.json|$ASSETS/sprites/v4/light@2x.json|1fb5b123fbe35d2e1f6ac171513ce01df89e671273a417ee89c44886a4c132f0"
  "$SPRITES/light@2x.png|$ASSETS/sprites/v4/light@2x.png|23f6e9df27c2e9a14385763980a24e3608966bfc8192a106058bc2ca959ab563"
)

for entry in "${FILES[@]}"; do
  IFS='|' read -r name url want <<<"$entry"
  echo "  -> $name"
  "${CURL[@]}" "$url" -o "$name.new"
  got=$(sha256sum "$name.new" | cut -d' ' -f1)
  if [[ "$got" != "$want" ]]; then
    echo "     sha256 $got is not the pinned $want — left as $name.new" >&2
    exit 1
  fi
  mv -f "$name.new" "$name"
done

echo "Done. Files vendored:"
ls -lh basemaps.js LICENSE.md "$SPRITES"
