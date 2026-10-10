#!/usr/bin/env bash
# tools/dev/valhalla-local.sh — the self-hosted Valhalla routing engine
# (Tier-1: offline, multimodal, no IP leak), driven end to end.
#
# The engine lives under .valhalla/ (gitignored):
#   prefix/        built binaries + libs (prime_server + valhalla)
#   tiles/         routing graph        (valhalla_build_tiles output)
#   transit_tiles/ GTFS transit graph   (ingest + convert output)
#   gtfs_feeds/    unzipped GTFS feeds, one subdir per feed
#   *.pbf          OSM extract · timezones.sqlite · valhalla.json
#
# Data pipeline (each step idempotent; `all` runs the lot):
#   fetch      OSM extract + Sofia GTFS + tz shapefile   (over Tor)
#   tzdb       import tz shapefile → timezones.sqlite
#   calendar   synthesize calendar.txt for calendar_dates-only feeds
#   config     generate valhalla.json (tiles + tz + transit wired)
#   transit    valhalla_ingest_transit + valhalla_convert_transit
#   tiles      valhalla_build_tiles (graph, with transit when present)
#   serve [N]  run valhalla_service on tcp://127.0.0.1:8002 (N threads)
#   stop       stop a running engine
#   route FROM TO [costing]   smoke-test (FROM/TO = "lat,lng")
#   priors [args]   refresh the planner arc-time priors (guile CLI passthrough)
#   profile    GC-root the runtime deps so `guix gc` can't evict them
#
# Everything runs through `guix shell -m .valhalla/manifest.scm` — no Docker,
# no system pollution. The engine binds localhost only; browsers reach it via
# serve-static's same-origin /route proxy, never directly.
#
# Building the engine itself (one-time; see memory/project docs for traps):
#   prime_server: autotools, deps zeromq czmq curl → --prefix=.valhalla/prefix
#   valhalla:     cmake, pin protobuf@3.21, -DENABLE_SINGLE_FILES_WERROR=OFF,
#                 link needs freexl proj minizip librttopo libxml2, -j3 (OOM)
set -euo pipefail

SELF="$(readlink -f "$0")"
ROOT="$(cd "$(dirname "$SELF")/../.." && pwd)"
HERE="$ROOT/.valhalla"
PREFIX="$HERE/prefix"
CONFIG="$HERE/valhalla.json"
MANIFEST="$HERE/manifest.scm"
PROFILE="$HERE/profile"
PBF="$HERE/bulgaria-latest.osm.pbf"
TZZIP="$HERE/timezones-with-oceans-1970.shapefile.zip"
TZSHP="combined-shapefile-with-oceans-1970"

OSM_URL="https://download.geofabrik.de/europe/bulgaria-latest.osm.pbf"  # parked in off/ for now
SF_URL="https://download.bbbike.org/osm/bbbike/SanFrancisco/SanFrancisco.osm.pbf"
BERLIN_URL="https://download.bbbike.org/osm/bbbike/Berlin/Berlin.osm.pbf"
GTFS_URL="https://storage.googleapis.com/storage/v1/b/mdb-latest/o/bg-sofia-city-gtfs-2848.zip?alt=media"
TZ_URL="https://github.com/evansiroky/timezone-boundary-builder/releases/download/2026b/timezones-with-oceans-1970.shapefile.zip"

# Run inside the pinned guix env with the built binaries on PATH. PATH is
# extended *inside* the env (single-quoted) — expanding $PATH out here would
# freeze the pre-shell value and wipe the guix profile (hard-won lesson).
in_env() {
  local how=(-m "$MANIFEST"); [ -L "$PROFILE" ] && how=(-p "$PROFILE")
  local extra=()
  [ -n "${EXTRA_PKGS:-}" ] && read -ra extra <<< "$EXTRA_PKGS"
  guix shell "${how[@]}" ${extra[@]+"${extra[@]}"} -- bash -c '
    export PATH="'"$PREFIX"'/bin:$PATH"
    export LD_LIBRARY_PATH="'"$PREFIX"'/lib:${LD_LIBRARY_PATH:-}"
    "$@"' _ "$@"
}

cmd="${1:-}"; shift || true
cd "$HERE"
case "$cmd" in
  fetch)
    # current atlas: SF + Berlin (bulgaria parked in off/ — restore by moving
    # its pbf back; the tiles step picks up every *.osm.pbf present)
    [ -f "$HERE/sanfrancisco.osm.pbf" ] || \
      torsocks curl -sSL -o "$HERE/sanfrancisco.osm.pbf" "$SF_URL"
    [ -f "$HERE/berlin.osm.pbf" ] || \
      torsocks curl -sSL -o "$HERE/berlin.osm.pbf" "$BERLIN_URL"
    [ -f "$TZZIP" ] || torsocks curl -sSL -o "$TZZIP" "$TZ_URL"
    if [ ! -d gtfs_feeds/sofia ]; then
      torsocks curl -sSL -o sofia-gtfs.zip "$GTFS_URL"
      mkdir -p gtfs_feeds/sofia
      EXTRA_PKGS="unzip" in_env unzip -o -d gtfs_feeds/sofia sofia-gtfs.zip
    fi
    ls -lh "$PBF" "$TZZIP"; ls gtfs_feeds
    ;;
  tzdb)
    # The upstream valhalla_build_timezones script is broken twice over
    # (error_exit never exits; needs the spatialite CLI) — do it directly.
    rm -f timezones.sqlite "$TZSHP".{shp,shx,dbf,prj}
    EXTRA_PKGS="unzip spatialite-tools" in_env bash -c "
      set -e
      unzip -o '$TZZIP' >/dev/null
      spatialite_tool -i -shp ./$TZSHP -d timezones.sqlite \
        -t tz_world -s 4326 -g geom -c UTF-8
      spatialite timezones.sqlite 'SELECT CreateSpatialIndex(\"tz_world\", \"geom\");'
      spatialite timezones.sqlite 'VACUUM;'
      spatialite timezones.sqlite 'ANALYZE;'
      rm -f $TZSHP.shp $TZSHP.shx $TZSHP.dbf $TZSHP.prj
    "
    EXTRA_PKGS="sqlite" in_env sqlite3 timezones.sqlite \
      "SELECT count(*) || ' zones, Sofia: ' ||
       (SELECT count(*) FROM tz_world WHERE tzid='Europe/Sofia') FROM tz_world;"
    ;;
  calendar)
    # Valhalla's GTFS ingest skips every trip of a calendar_dates-only feed
    # ("no calendar.txt entry"). Synthesize calendar.txt per service_id:
    # weekday flags from the dates actually served, range = min..max date.
    for feed in gtfs_feeds/*/; do
      [ -f "$feed/calendar_dates.txt" ] || continue
      EXTRA_PKGS="python" in_env python3 - "$feed" <<'EOF'
import csv, datetime, sys
from collections import defaultdict
feed = sys.argv[1]
svc = defaultdict(list)
with open(feed + '/calendar_dates.txt') as f:
    for row in csv.DictReader(f):
        if row['exception_type'].strip() == '1':
            svc[row['service_id']].append(row['date'].strip())
days = ['monday','tuesday','wednesday','thursday','friday','saturday','sunday']
with open(feed + '/calendar.txt', 'w', newline='') as f:
    w = csv.writer(f)
    w.writerow(['service_id'] + days + ['start_date','end_date'])
    for sid, dates in svc.items():
        wd = set(datetime.datetime.strptime(d, '%Y%m%d').weekday() for d in dates)
        w.writerow([sid] + [1 if i in wd else 0 for i in range(7)]
                   + [min(dates), max(dates)])
print(f"{feed}: calendar.txt synthesized for {len(svc)} services")
EOF
    done
    ;;
  config)
    mkdir -p tiles transit_tiles
    EXTRA_PKGS="python" in_env valhalla_build_config \
      --mjolnir-tile-dir "$HERE/tiles" \
      --mjolnir-tile-extract "" \
      --mjolnir-timezone "$HERE/timezones.sqlite" \
      --mjolnir-admin "" \
      --mjolnir-transit-feeds-dir "$HERE/gtfs_feeds" \
      --mjolnir-transit-dir "$HERE/transit_tiles" \
      --httpd-service-listen "tcp://127.0.0.1:8002" \
      > "$CONFIG"
    echo "wrote $CONFIG"
    ;;
  transit)
    rm -rf transit_tiles && mkdir transit_tiles
    in_env valhalla_ingest_transit -c "$CONFIG"
    in_env valhalla_convert_transit -c "$CONFIG"
    echo "transit graph: $(find transit_tiles -name '*.gph' | wc -l) tiles"
    ;;
  tiles)
    # the atlas is EVERY extract present — regions add, they do not replace
    "$SELF" stop
    rm -rf tiles && mkdir tiles
    in_env valhalla_build_tiles -c "$CONFIG" "$HERE"/*.osm.pbf
    du -sh tiles
    ;;
  serve)
    [ -f "$CONFIG" ] || { echo "no config; run: $0 config" >&2; exit 1; }
    echo "valhalla_service on tcp://127.0.0.1:8002 — Ctrl-C to stop"
    in_env valhalla_service "$CONFIG" "${1:-2}"
    ;;
  stop)
    pgrep -f 'valhalla_servic[e]' | xargs -r kill && echo "engine stopped" || true
    ;;
  route)
    FROM="$1"; TO="$2"; COST="${3:-pedestrian}"
    req="{\"locations\":[{\"lat\":${FROM%,*},\"lon\":${FROM#*,}},{\"lat\":${TO%,*},\"lon\":${TO#*,}}],\"costing\":\"$COST\",\"directions_options\":{\"units\":\"kilometers\"}}"
    curl -s "http://127.0.0.1:8002/route" -d "$req" | head -c 600; echo
    ;;
  priors)
    # refresh the PLANNER's arc-time prior table off the running engine —
    # thin passthrough to the guile CLI (places as name=lat,lng args or
    # --places-file; see module/playnet/solve/refresh-priors.scm).
    exec guix shell -L "$ROOT/deploy/guix" \
      -m "$ROOT/deploy/manifests/dev-test-manifest.scm" -- \
      guile --no-auto-compile "$ROOT/module/playnet/solve/refresh-priors.scm" "$@"
    ;;
  profile)
    guix shell -m "$MANIFEST" --root="$PROFILE" -- true
    echo "GC root: $PROFILE"
    ;;
  all)
    for step in fetch tzdb calendar config transit tiles; do
      echo "── $step ──────────────────────────────────────────"
      "$SELF" "$step"
    done
    echo "done — now: $0 serve"
    ;;
  *)
    sed -n "2,30p" "$SELF"; exit 1
    ;;
esac
