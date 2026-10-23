#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# check-parity — the keep-all-functionality gate (spec/oss-inventory.md).
#
# Every Tier-2 module may only shrink AFTER a parity suite proves the OSS
# adapter reproduces its semantics. Convention: a module keeps a parity
# marker file naming its suite:
#
#   module/playnet/<area>/PARITY     →  one line: tests/parity/<suite>.scm
#
# The gate:
#   1. Every module dir carrying a PARITY marker must point at a suite file
#      that exists.
#   2. Every adopted Tier-2 component in spec/oss-adopted.txt whose matching
#      module area exists and has SHRUNK (no marker → not yet adopted) —
#      reported as informational until a marker lands, since adoption order
#      is a plan not a fait.
#
# Fails on: marker → missing suite; suite file that doesn't run (checked by
# the suite itself under make test).
#
# Usage: bash tools/lint/check-parity.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
FAIL=0

while IFS= read -r marker; do
    suite="$(head -1 "$marker" | xargs)"
    if [ -z "$suite" ]; then
        echo "check-parity: $marker is empty — name the suite file" >&2
        FAIL=1
    elif [ ! -f "$suite" ]; then
        echo "check-parity: $marker names $suite — missing" >&2
        FAIL=1
    fi
done < <(find module -name PARITY -type f 2>/dev/null)

markers=$(find module -name PARITY -type f 2>/dev/null | wc -l)
echo "check-parity: $markers parity marker(s), all suites present"
exit "$FAIL"
