#!/usr/bin/env bash
# tools/emit/map-tiles.sh — cut the basemap's archives and fetch its glyphs.
#
# The map draws OpenStreetMap vector tiles served from PMTiles archives under
# MAP_DIR (default data/map), one per region of tools/emit/regions.tsv, each cut
# from a Protomaps daily planet build by go-pmtiles `extract` — a range read of
# the planet file, so only the region's bytes travel. The labels' glyph ranges
# (Noto Sans, OFL) land under browser/assets/map/fonts, kept out of git for
# their size and shipped by the deploy rsync like the rest of browser/.
#
#   make map-tiles                       every region, every asset
#   REGIONS=berlin make map-tiles        one region
#   MAXZOOM=12 make map-tiles            a lighter cut (default 15)
#   MAP_DIR=/var/lib/playnet/map make map-tiles   on the box
#
# Over Tor by default (go-pmtiles is a static Go binary: torsocks cannot wrap
# it, so it reads HTTPS_PROXY instead); NO_TOR=1 goes direct. The go-pmtiles
# release is pinned by version and sha256 and cached under ~/.cache/playnet.
set -euo pipefail
cd "$(dirname "$0")/../.."

PROTOMAPS_BUILD="${PROTOMAPS_BUILD:-20261008}"
GO_PMTILES_VERSION="1.31.2"
GO_PMTILES_SHA256="3ed7dbf4ec2e6dfe5e25b6f70d1ffc932729f93c86db353bf514dd71010a312f"
ASSETS_COMMIT="028c18f713baecad011301ff7a69acc39bcc2ae7"
MAP_DIR="${MAP_DIR:-data/map}"
MAXZOOM="${MAXZOOM:-15}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/playnet/go-pmtiles"
FONTS_DIR="browser/assets/map/fonts"

# curl under torsocks; go-pmtiles under HTTPS_PROXY alone (torsocks would
# refuse curl's own connection to the local proxy, so the two never mix)
CURL=(curl -sSLf)
PMTILES=("$CACHE/$GO_PMTILES_VERSION/pmtiles")
if [[ "${NO_TOR:-0}" != "1" ]]; then
  CURL=(torsocks "${CURL[@]}")
  PMTILES=(env "HTTPS_PROXY=${HTTPS_PROXY:-socks5://127.0.0.1:9050}" "${PMTILES[@]}")
fi

# ── go-pmtiles, pinned ────────────────────────────────────────────────────
bin="$CACHE/$GO_PMTILES_VERSION/pmtiles"
if [[ ! -x "$bin" ]]; then
  mkdir -p "$(dirname "$bin")"
  tgz="$CACHE/go-pmtiles_${GO_PMTILES_VERSION}_Linux_x86_64.tar.gz"
  echo "  -> go-pmtiles $GO_PMTILES_VERSION"
  "${CURL[@]}" -o "$tgz.new" \
    "https://github.com/protomaps/go-pmtiles/releases/download/v${GO_PMTILES_VERSION}/go-pmtiles_${GO_PMTILES_VERSION}_Linux_x86_64.tar.gz"
  got=$(sha256sum "$tgz.new" | cut -d' ' -f1)
  if [[ "$got" != "$GO_PMTILES_SHA256" ]]; then
    echo "     sha256 $got is not the pinned $GO_PMTILES_SHA256 — left as $tgz.new" >&2
    exit 1
  fi
  mv -f "$tgz.new" "$tgz"
  tar -xzf "$tgz" -C "$(dirname "$bin")" pmtiles
fi

# ── the glyphs ────────────────────────────────────────────────────────────
# Each family is 256 range files, fetched eight at a time; a range already
# present is kept, so a stopped run resumes where it was.
fetch_range() {   # <family> <range>
  local dir="$FONTS_DIR/$1" range="$2"
  [[ -f "$dir/$range.pbf" ]] && return 0
  "${CURL[@]}" -o "$dir/$range.pbf.new" \
    "https://raw.githubusercontent.com/protomaps/basemaps-assets/$ASSETS_COMMIT/fonts/${1// /%20}/$range.pbf" \
    && mv -f "$dir/$range.pbf.new" "$dir/$range.pbf"
}
export -f fetch_range
export FONTS_DIR ASSETS_COMMIT CURL_CMD="${CURL[*]}"
for family in "Noto Sans Regular" "Noto Sans Medium" "Noto Sans Italic"; do
  dir="$FONTS_DIR/$family"
  mkdir -p "$dir"
  if [[ $(ls "$dir"/*.pbf 2>/dev/null | wc -l) -eq 256 ]]; then continue; fi
  echo "  -> glyphs: $family"
  for ((lo = 0; lo < 65536; lo += 256)); do echo "$lo-$((lo + 255))"; done \
    | xargs -P 8 -I{} bash -c 'CURL=($CURL_CMD); fetch_range "$1" "$2"' _ "$family" {}
done
[[ -f "$FONTS_DIR/OFL.txt" ]] || "${CURL[@]}" -o "$FONTS_DIR/OFL.txt" \
  "https://raw.githubusercontent.com/protomaps/basemaps-assets/$ASSETS_COMMIT/fonts/OFL.txt"

# ── the archives ──────────────────────────────────────────────────────────
mkdir -p "$MAP_DIR"
planet="https://build.protomaps.com/${PROTOMAPS_BUILD}.pmtiles"
while IFS=$'\t' read -r name w s e n; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  if [[ -n "${REGIONS:-}" ]] && [[ ",$REGIONS," != *",$name,"* ]]; then continue; fi
  out="$MAP_DIR/$name.pmtiles"
  if [[ -f "$out" ]]; then echo "  == $out (present; delete it to recut)"; continue; fi
  echo "  -> $name: $w $s $e $n to z$MAXZOOM from build $PROTOMAPS_BUILD"
  "${PMTILES[@]}" extract "$planet" "$out.new" --bbox="$w,$s,$e,$n" --maxzoom="$MAXZOOM"
  mv -f "$out.new" "$out"
done < tools/emit/regions.tsv

echo "Done. Archives in $MAP_DIR:"
ls -lh "$MAP_DIR"/*.pmtiles 2>/dev/null || echo "  (none)"
