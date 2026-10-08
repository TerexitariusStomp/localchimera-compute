#!/bin/sh
# fetch-water.sh — WRI Aqueduct 3.0 baseline water RISK at a point (any lat/lon). Real,
# global water-stress fragility data. GENERAL + reproducible: pinned point query, vendored
# + checksummed (same discipline as fetch.sh). No key. Source: WRI Aqueduct (CC-BY 4.0).
#
#   sh fetch-water.sh [LAT] [LON] [LABEL]
. "$(dirname "$0")/_fetch-lib.sh"
LAT="${1:-30.32}" ; LON="${2:-78.03}" ; LABEL="${3:-doon}"
OUT="$(place_out "$LABEL")" ; mkdir -p "$OUT"
curl -sS --max-time 90 \
  "https://gis.wri.org/server/rest/services/Aqueduct/aqueduct_global_2014/MapServer/0/query?geometry=${LON},${LAT}&geometryType=esriGeometryPoint&inSR=4326&spatialRel=esriSpatialRelIntersects&outFields=*&returnGeometry=false&f=json" \
  -o "${OUT}/water.json"
sum_into "$OUT" SHA256SUMS-water water.json
echo "water risk → ${OUT}/water.json . Derive: guile process-water.scm ${OUT}/water.json"
