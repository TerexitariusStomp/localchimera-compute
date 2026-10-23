#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tools/lint/check-atlas.sh — tools/dev/atlas.txt is well formed: every region has a unique name that is a
# valid file stem, an https OSM extract (.osm.pbf) and, when it has one, an https transit feed. The routing
# script reads this table and nothing else names a region, so a malformed row would show only in a `fetch`
# over Tor — this shows it at once.
#
# Run: bash tools/lint/check-atlas.sh   (or `make check-atlas`)
set -uo pipefail
cd "$(dirname "$0")/../.."
file=tools/dev/atlas.txt
bad=0; n=0; seen=" "
while IFS='|' read -r name osm gtfs extra; do
  name="${name//[[:space:]]/}"; osm="${osm//[[:space:]]/}"; gtfs="${gtfs//[[:space:]]/}"
  case "$name" in ""|\#*) continue ;; esac
  n=$((n + 1))
  fail() { echo "  $file: region '$name': $1"; bad=$((bad + 1)); }
  [[ "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "the name is not a file stem (a-z, 0-9, - _)"
  [[ "$seen" == *" $name "* ]] && fail "named twice"
  seen+="$name "
  [[ "$osm" =~ ^https://.+\.osm\.pbf$ ]] || fail "the OSM extract is not an https .osm.pbf address"
  [ -z "$gtfs" ] || [[ "$gtfs" =~ ^https://[^[:space:]]+$ ]] || fail "the transit feed is not an https address"
  [ -z "${extra:-}" ] || fail "more than three fields"
done < "$file"
[ "$n" -gt 0 ] || { echo "  $file: no regions"; bad=$((bad + 1)); }
if [ "$bad" -gt 0 ]; then echo "check-atlas: $bad problem(s)"; exit 1; fi
echo "check-atlas: $n region(s) well formed"
