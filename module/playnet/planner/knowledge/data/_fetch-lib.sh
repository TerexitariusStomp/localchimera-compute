# _fetch-lib.sh — shared skeleton for the fetch-*.sh scripts. Source me FIRST:
#   . "$(dirname "$0")/_fetch-lib.sh"
# Provides: strict mode, cd-to-script-dir, the raw/ layout helpers, and sum_into
# (vendor a checksum manifest).
set -eu
cd "$(dirname "$0")"

# ── raw/ has TWO axes, and they are not interchangeable ─────────────────────
# raw/<label>/       a PLACE. Every file under it describes one point or region
#                    on Earth, and the label names the bioregion (doon, berlin).
# raw/spec/<name>/   a PROCESS, SPECIES or MATERIAL. Keyed by what it is, not
#                    where it is: an industrial unit process, a species' growth
#                    table, an emission factor set. Applies wherever it is used.
#
# The distinction matters because a place-keyed number is calibration (this
# valley's rainfall) and a spec-keyed number is a property (ammonia's energy per
# tonne). Mixing them in one namespace loses that, and `raw/ammonia/` sitting
# beside `raw/doon/` would read as a bioregion called ammonia.
# See sources.md § "Two axes".
RAW_SPEC_DIR=spec

# place_out LABEL — raw dir for a bioregion. Refuses the reserved spec/ name.
place_out() {
  case "$1" in
    "$RAW_SPEC_DIR") echo "place label '$1' is reserved for the spec axis (see sources.md)" >&2; exit 2 ;;
    ""|*/*) echo "place label must be a non-empty single path segment: '$1'" >&2; exit 2 ;;
  esac
  printf 'raw/%s' "$1"
}

# spec_out NAME — raw dir for process/species/material data, keyed by what it is.
spec_out() {
  case "$1" in
    ""|*/*) echo "spec name must be a non-empty single path segment: '$1'" >&2; exit 2 ;;
  esac
  printf 'raw/%s/%s' "$RAW_SPEC_DIR" "$1"
}

# sum_into DIR SHAFILE FILE...  — write sha256 of FILEs (relative to DIR) into DIR/SHAFILE.
# `sha256sum -c DIR/SHAFILE` from DIR then verifies the vendored raw byte-for-byte.
sum_into() {
  dir="$1"; shafile="$2"; shift 2
  ( cd "$dir" && sha256sum "$@" > "$shafile" )
}
