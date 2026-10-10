#!/bin/sh
# fetch-eco.sh — reproducibly pull a bioregion's LOCAL ecological state variables,
# the ones a shed's *frag-container* limits bind on (a bioregion contains a MULTITUDE
# of fragile specs: topsoil carbon, groundwater, forest …). Companion to fetch.sh
# (climate) + fetch-yields.sh (yields). GENERAL: any location on Earth.
#
#   sh fetch-eco.sh [LAT] [LON] [LABEL]
#   sh fetch-eco.sh                        # → Doon Valley (30.32, 78.03)
#
# MACHINE-PULLABLE here — topsoil organic carbon (the soil-carbon fragility):
#   ISRIC SoilGrids v2.0 (CC-BY 4.0), global 250 m. Masked (null) over water/urban
#   cells — so if the exact point is null this AUTO-PROBES a nearest-first ring of
#   nearby cells (±3 km, then ±6 km) and vendors the first cell that returns soil,
#   recording the coordinates actually used. No human nudge needed.
#
# TRANSCRIPTION-TIER (no open API reachable — sourced like the eco-catalogue's
# planetary boundaries, DRAFT figures to be RATIFIED at UC level):
#   · Groundwater — CGWB "Dynamic Ground Water Resources" / India-WRIS block
#     Stage-of-Extraction %. (Global proxy: WRI Aqueduct baseline water stress.)
#   · Forest cover — Global Forest Watch / FSI "India State of Forest Report".
# See sources.md §eco for the pinned URLs + the frag-record each figure becomes.
. "$(dirname "$0")/_fetch-lib.sh"

LAT="${1:-30.32}" ; LON="${2:-78.03}" ; LABEL="${3:-doon}"
OUT="$(place_out "$LABEL")"
mkdir -p "$OUT"
URL="https://rest.isric.org/soilgrids/v2.0/properties/query"
Q="property=soc&property=nitrogen&property=phh2o&depth=0-5cm&depth=5-15cm&depth=15-30cm&value=mean"

# query one cell → writes $OUT/soil-eco.json, echoes the 0-5cm SOC mean or "null"
probe() {
  curl -sS --max-time 110 "${URL}?lon=$2&lat=$1&${Q}" -o "${OUT}/soil-eco.json" || { echo null; return; }
  python3 - "${OUT}/soil-eco.json" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1])); print(d["properties"]["layers"][0]["depths"][0]["values"]["mean"])
except Exception: print("null")
PY
}

# the point first, then a nearest-first ring (±4 km ≈ 0.04°, then ±8 km) to escape a
# masked river/urban cell. SoilGrids RATE-LIMITS (~5 req/min), so probes are SPACED
# (~13 s) and the ring is small — a masked point resolves in a couple of tries.
RING="0,0  0.04,0  -0.04,0  0,0.04  0,-0.04  0.04,0.04  -0.04,-0.04  0.08,0  0,0.08"
used=""; first=1
for d in $RING; do
  [ $first -eq 1 ] || sleep 13     # respect the rate limit between probes
  first=0
  dlat=${d%,*}; dlon=${d#*,}
  plat=$(awk "BEGIN{printf \"%.4f\", $LAT + $dlat}")
  plon=$(awk "BEGIN{printf \"%.4f\", $LON + $dlon}")
  v=$(probe "$plat" "$plon")
  if [ "$v" != "null" ] && [ "$v" != "None" ]; then used="$plat $plon"; break; fi
  echo "  (masked/throttled at $plat, $plon — spacing, then next ring cell)"
done
[ -n "$used" ] || { echo "no non-null SoilGrids cell within ±6 km — use local trial soil (sources.md §eco)"; exit 1; }

sum_into "$OUT" SHA256SUMS-eco soil-eco.json
echo "soil cell used: $used → ${OUT}/soil-eco.json (checksummed). Derive: guile process-eco.scm ${OUT}/soil-eco.json"
