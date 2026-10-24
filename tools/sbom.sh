#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# sbom.sh — emit a CycloneDX 1.5 SBOM for the deployed product.
#
# The inventory is the source: spec/oss-adopted.txt names every component,
# its license and its source. First-party files are the one component named
# "localchimera" (AGPL-3.0-or-later); everything else arrives as a library/service entry.
#
#   tools/sbom.sh [OUT]     default OUT=sbom.json
#
# This is the P7 proof artifact: check-licenses keeps the manifest honest,
# this makes the deployed composition legible to anything that reads SBOMs.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="${1:-sbom.json}"
MANIFEST=spec/oss-adopted.txt

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g'; }

{
  cat <<'HDR'
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "version": 1,
  "metadata": {
    "component": {
      "type": "application",
      "name": "localchimera",
      "licenses": [{ "expression": "AGPL-3.0-or-later" }]
    }
  },
  "components": [
HDR
  first=1
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue;; esac
    name="$(echo "$line"   | cut -d'|' -f1 | xargs)"
    lic="$(echo "$line"    | cut -d'|' -f2 | xargs)"
    src="$(echo "$line"    | cut -d'|' -f3 | xargs)"
    status="$(echo "$line" | cut -d'|' -f4 | xargs)"
    [ -z "$name" ] && continue
    # multi-license strings are an OR of SPDX ids where the manifest lists them
    lics=""; for w in $lic; do lics="${lics:+$lics, }{ \"license\": { \"id\": \"$w\" } }"; done
    [ $first = 1 ] || printf ',\n'
    first=0
    printf '    { "type": "library", "name": "%s", "licenses": [%s ],' \
        "$(json_escape "$name")" "$lics"
    printf ' "externalReferences": [{ "type": "website", "url": "%s" }],' \
        "$(json_escape "$src")"
    printf ' "properties": [{ "name": "adoption:status", "value": "%s" }] }' \
        "$status"
  done < "$MANIFEST"
  printf '\n  ]\n}\n'
} > "$OUT"

echo "sbom: $(grep -c '"type": "library"' "$OUT") components → $OUT"
