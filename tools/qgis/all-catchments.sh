#!/usr/bin/env bash
# tools/qgis/all-catchments.sh — queue a TRUE upstream catchment job (via
# catchment-job.scm / grass:r.water.outlet) for every seeded bioregion.
#
# Same pour points and DEM radius as all-watersheds.sh's table (the
# bioregion's own lat/lon from module/playnet/planner/knowledge/<id>.scm);
# the fifth column is catchment-job.scm's stream threshold — accumulation
# cells before a channel counts as "on the network" for snapping, not the
# basin-size threshold watershed-job.scm uses. 2000 cells (~16 km² of
# contributing area) proved out against Salem-on-the-Willamette: a real
# channel network, not every micro-depression.
#
# Unlike all-watersheds.sh's `basin` (a local sub-shed, always small),
# r.water.outlet's catchment can be genuinely large — the whole upstream
# drainage. See tools/qgis/catchment-job.scm's header for why the two
# differ and when each is the right question.
#
# Usage: QGIS_DIR=/var/lib/playnet/qgis tools/qgis/all-catchments.sh [id ...]

set -euo pipefail
here=$(dirname "$0")
sheds='
berlin     52.52   13.40  1 2000
bay-area   37.77  -122.42 1 2000
cascadia   45.00  -123.00 2 2000
doon-shed  30.32   78.03  1 2000
'
want=("$@")
echo "$sheds" | while read -r id lat lon r thr; do
  [ -n "$id" ] || continue
  if [ ${#want[@]} -gt 0 ] && ! printf '%s\n' "${want[@]}" | grep -qx "$id"; then continue; fi
  guile --no-auto-compile "$here/catchment-job.scm" "$id" "$lat" "$lon" "$r" "$thr"
done
