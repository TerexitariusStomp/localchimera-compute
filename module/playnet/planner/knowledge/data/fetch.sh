#!/bin/sh
# fetch.sh — reproducibly pull the external datasets that calibrate a bioregion's
# scenario set to raw/<label>/ . GENERAL: works for ANY location on Earth (the
# Open-Meteo + SoilGrids APIs are global); the Doon Valley is just the default.
#
#   sh fetch.sh [LAT] [LON] [LABEL]
#   sh fetch.sh                      # → Doon Valley (30.32, 78.03), label "doon"
#   sh fetch.sh 36.72 -4.42 malaga   # → a Mediterranean bioregion
#
# Pinned queries; the derived numbers come from process.scm. `sha256sum -c
# raw/<label>/SHA256SUMS` verifies the vendored raw is byte-identical to a pull.
# Sources (open, no API key): see sources.md for full provenance + licences.
. "$(dirname "$0")/_fetch-lib.sh"

LAT="${1:-30.32}" ; LON="${2:-78.03}" ; LABEL="${3:-doon}"
OUT="$(place_out "$LABEL")"
mkdir -p "$OUT"
echo "bioregion '${LABEL}' at ${LAT}, ${LON}"

# 1) Daily precipitation, 1960–2023 — ERA5 reanalysis via Open-Meteo Archive API
#    (CC-BY 4.0). Drives the drought/flood frequencies (process.scm).
curl -sS --max-time 120 \
  "https://archive-api.open-meteo.com/v1/archive?latitude=${LAT}&longitude=${LON}&start_date=1960-01-01&end_date=2023-12-31&daily=precipitation_sum&timezone=auto" \
  -o "${OUT}/precip.json"

# 2) Daily TEMPERATURE, 1960–2023 — ERA5 via Open-Meteo (CC-BY 4.0). Drives the heat/
#    frost fragility (process-temp.scm). Separate file/manifest so precip.json is untouched.
curl -sS --max-time 120 \
  "https://archive-api.open-meteo.com/v1/archive?latitude=${LAT}&longitude=${LON}&start_date=1960-01-01&end_date=2023-12-31&daily=temperature_2m_max,temperature_2m_min,temperature_2m_mean&timezone=auto" \
  -o "${OUT}/temp.json"
sum_into "$OUT" SHA256SUMS-temp temp.json

# 3) Soil properties at the point — ISRIC SoilGrids v2.0 (CC-BY 4.0). May be null
#    over some cells; local trial soil is the fallback there.
curl -sS --max-time 90 \
  "https://rest.isric.org/soilgrids/v2.0/properties/query?lon=${LON}&lat=${LAT}&property=soc&property=nitrogen&property=phh2o&depth=0-5cm&depth=5-15cm&value=mean" \
  -o "${OUT}/soilgrids.json"

sum_into "$OUT" SHA256SUMS precip.json soilgrids.json
echo "fetched + checksummed → ${OUT}/ . Derive: guile process.scm ${OUT}/precip.json [wet-months]; guile process-temp.scm ${OUT}/temp.json"
