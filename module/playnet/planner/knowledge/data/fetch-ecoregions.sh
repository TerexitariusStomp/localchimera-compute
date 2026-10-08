#!/bin/sh
# fetch-ecoregions.sh — pull RESOLVE Ecoregions 2017 (the One Earth ecoregion layer) to
# a SCRATCH dir, for process-ecoregions.scm to filter to a bioregion + simplify. GENERAL.
#
#   sh fetch-ecoregions.sh [SCRATCH_DIR]
#   sh fetch-ecoregions.sh /tmp/eco
#   then: guile process-ecoregions.scm $SCRATCH/Ecoregions2017.shp cascadia ../boundaries.json 0.03 > ../cascadia-ecoregions.json
#
# The source is ~149 MB (Dinerstein et al. 2017, "An Ecoregion-Based Approach…",
# BioScience; CC-BY 4.0) — it is NOT vendored; only the small filtered/simplified subset
# per bioregion is. Same discipline as the SoilGrids/OWID pulls: fetch big, vendor the
# derived. Needs unzip + pyshp (pure-python: `python3 -m venv v && v/bin/pip install pyshp`).
set -eu
OUT="${1:-/tmp/resolve-ecoregions}"
mkdir -p "$OUT"
echo "RESOLVE Ecoregions 2017 → ${OUT}/"
curl -sS --max-time 600 -o "${OUT}/Ecoregions2017.zip" \
  "https://storage.googleapis.com/teow2016/Ecoregions2017.zip"
( cd "$OUT" && unzip -o -q Ecoregions2017.zip )
echo "unpacked. Filter: guile process-ecoregions.scm ${OUT}/Ecoregions2017.shp <bioregion> ../boundaries.json 0.03 > ../<bioregion>-ecoregions.json"
