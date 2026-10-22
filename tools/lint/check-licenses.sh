#!/usr/bin/env bash
# check-licenses — the license gate for the OSS-inventory rule (spec/oss-inventory.md).
#
#   1. spec/oss-adopted.txt is the component manifest; every license it names
#      must be on the allowlist below (free, commercially usable — copyleft
#      and MIT both fine, nothing paid, nothing source-available).
#   2. Any vendor/ tree must carry a LICENSE file per vendored root.
#   3. No forbidden-license markers (BUSL, SSPL, Elastic) anywhere in-tree.
#
# Usage: bash tools/lint/check-licenses.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

MANIFEST=spec/oss-adopted.txt
FAIL=0

ALLOWLIST='MIT Apache-2.0 BSD-2-Clause BSD-3-Clause MPL-2.0 LGPL-2.1 LGPL-3.0 GPL-2.0 GPL-3.0 AGPL-3.0 EPL-1.0 EPL-2.0 CAL-1.0 OLDAP-2.8 public-domain CC0-1.0 Reticulum'

license_ok() {
    local lic="$1" w ok
    # multi-license strings ("MIT Apache-2.0") are fine iff each token is allowed
    for w in $lic; do
        ok=0
        for a in $ALLOWLIST; do [ "$w" = "$a" ] && ok=1 && break; done
        [ "$ok" = 1 ] || return 1
    done
    return 0
}

# -- 1. manifest entries all allowlisted -------------------------------------
[ -f "$MANIFEST" ] || { echo "check-licenses: $MANIFEST missing"; exit 1; }
while IFS= read -r line; do
    case "$line" in ''|\#*) continue;; esac
    name="$(echo "$line" | cut -d'|' -f1 | xargs)"
    lic="$(echo "$line"  | cut -d'|' -f2 | xargs)"
    status="$(echo "$line" | cut -d'|' -f4 | xargs)"
    [ -z "$name" ] && continue
    if ! license_ok "$lic"; then
        echo "check-licenses: $name — '$lic' not on the allowlist" >&2
        FAIL=1
    fi
    case "$status" in
        in-use|adopted|flagged) ;;
        *) echo "check-licenses: $name — unknown status '$status'" >&2; FAIL=1;;
    esac
done < "$MANIFEST"

# -- 2. vendored roots carry a LICENSE ----------------------------------------
if [ -d vendor ]; then
    while IFS= read -r d; do
        ls "$d"/LICENSE* "$d"/COPYING* >/dev/null 2>&1 || {
            echo "check-licenses: vendor root $d has no LICENSE file" >&2; FAIL=1; }
    done < <(find vendor -mindepth 1 -maxdepth 1 -type d)
fi

# -- 3. no source-available licenses in-tree -----------------------------------
bad=$(find . -path ./.git -prune -o -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' \) -print0 \
      | xargs -0 grep -ilE 'business source license|BUSL-1|server side public license|SSPL|elastic license' 2>/dev/null || true)
[ -n "$bad" ] && { echo "check-licenses: source-available license found: $bad" >&2; FAIL=1; }

[ "$FAIL" = 0 ] && echo "check-licenses: $(grep -vc '^\s*\(#\|$\)' "$MANIFEST") components, all allowlisted"
exit "$FAIL"
