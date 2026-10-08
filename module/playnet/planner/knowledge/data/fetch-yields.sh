#!/bin/sh
# fetch-yields.sh — reproducibly pull national crop-yield baselines that calibrate a
# bioregion's per-crop yields. Companion to fetch.sh (climate). GENERAL: any country,
# any OWID crop grapher (all source FAOSTAT, cited; all key-free).
#
#   sh fetch-yields.sh [COUNTRY] [CROPS] [LABEL]
#   sh fetch-yields.sh                                  # → India, the Doon staples
#   sh fetch-yields.sh "United States" rice,maize usa
#
# Source: Our World in Data grapher CSVs (FAOSTAT-derived, CC-BY 4.0), key-free — the
# `faostatservices` REST API now needs an auth header, so we use the open OWID mirror.
# The CSV export carries ALL entities (the country filter is client-side in the
# grapher), so process-yields.scm filters to COUNTRY. Millet/ragi has no OWID grapher
# (404) — it stays at its FAOSTAT-bulk-tier value in worlds/doon-valley.scm (sources.md §yields).
# `sha256sum -c raw/<label>/SHA256SUMS-yields` verifies the vendored raw.
. "$(dirname "$0")/_fetch-lib.sh"

COUNTRY="${1:-India}"
CROPS="${2:-rice,maize,wheat,bean,pea}"   # OWID grapher slugs: <crop>-yields
LABEL="${3:-doon}"
OUT="$(place_out "$LABEL")"
mkdir -p "$OUT"
echo "yields for '${COUNTRY}', crops ${CROPS} → ${OUT}/"

# one CSV per crop (Entity,Code,Year,<Crop> - Yield (tonnes per hectare)).
files=""
old_ifs=$IFS; IFS=,
for crop in $CROPS; do
  IFS=$old_ifs
  f="yield-${crop}.csv"
  curl -sS --max-time 90 "https://ourworldindata.org/grapher/${crop}-yields.csv" -o "${OUT}/${f}"
  files="${files} ${f}"
  IFS=,
done
IFS=$old_ifs

sum_into "$OUT" SHA256SUMS-yields $files
echo "fetched + checksummed → ${OUT}/ . Derive: guile process-yields.scm \"${COUNTRY}\" ${OUT}/yield-*.csv"
