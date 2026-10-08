#!/usr/bin/env bash
# tools/qgis/all-watersheds.sh — queue a watershed job for every seeded bioregion.
#
# One line per shed: id, pour point (the bioregion's own lat/lon from
# module/playnet/planner/knowledge/<id>.scm), DEM tile radius in degrees,
# and the r.watershed basin threshold in cells (GLO-90 ≈ 90 m ⇒ 1 cell ≈ 0.008 km²).
#
#   berlin     — Spree/Havel lowland: flat, so a large threshold keeps one shed.
#   bay-area   — SF Bay: steep coast ranges, smaller basins drain straight to the bay.
#   cascadia   — Willamette Valley: pour point near Salem, 2° to reach the Cascades.
#   doon-shed  — Dehradun: the Doon valley between Siwaliks and Himalaya, narrow.
#
# What a job yields: r.watershed's `basin` map segments the drainage into
# units of at least THRESHOLD cells, so the polygon is the LOCAL SHED the
# pour point sits in — the catchment unit a commune actually shares water
# with — at roughly threshold scale (10 000 cells ≈ 80 km², 60 000 ≈ 500 km²).
# The whole upstream catchment of a river (the full Willamette, say) is a
# different question — tools/qgis/all-catchments.sh, grass:r.water.outlet
# over an outlet snapped onto the main channel; cascadia therefore keeps
# its hand-drawn ecoregion polygon in boundaries.json and its derived
# local shed is informational.
#
# Usage: QGIS_DIR=/var/lib/playnet/qgis tools/qgis/all-watersheds.sh [id ...]

set -euo pipefail
here=$(dirname "$0")
sheds='
berlin     52.52   13.40  1 60000
bay-area   37.77  -122.42 1 10000
cascadia   45.00  -123.00 2 60000
doon-shed  30.32   78.03  1 10000
'
want=("$@")
echo "$sheds" | while read -r id lat lon r thr; do
  [ -n "$id" ] || continue
  if [ ${#want[@]} -gt 0 ] && ! printf '%s\n' "${want[@]}" | grep -qx "$id"; then continue; fi
  guile --no-auto-compile "$here/watershed-job.scm" "$id" "$lat" "$lon" "$r" "$thr"
done
