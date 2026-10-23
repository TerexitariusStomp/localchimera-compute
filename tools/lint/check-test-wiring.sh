#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tools/lint/check-test-wiring.sh — every test file must be reachable from `make`.
#
# The failure this exists to stop is not a failing test; it is a test nobody
# runs. On 2026-07-28 an audit found five browser suites in this state:
#
#   • tests/day-signup-ux.mjs, day-events-ux.mjs, day-availability-ux.mjs had
#     no Make target at all — orphans;
#   • test-day-respond-ux and test-day-nav-ux HAD targets, but routed through
#     tests/ux/ux-run.sh, which aborts without a gateway sref those self-contained
#     tests never needed. They could not pass on a clean checkout.
#
# All five had meanwhile rotted against a renamed seam (window.__dialStatus →
# window.__dial.status) and nobody noticed, because nothing ever invoked them.
# A test that is never run reads as coverage while providing none — strictly
# worse than no test.
#
# So: for every tests/<name>-ux.mjs there must be a `test-<name>-ux` target
# that make can resolve. Cheap (make -n, nothing executes), no browser needed,
# so it belongs in the fast `make test` path.
#
# And every Scheme suite stands in the directory of the module it pins
# (tests/<dir>/, docs/planning/codebase-layout.md §8): tools/lint/module-map.scm
# --check-suites reads each suite's imports and names the ones astray.
#
# Run: bash tools/lint/check-test-wiring.sh   (or `make check-test-wiring`)

set -uo pipefail
cd "$(dirname "$0")/../.."

missing=0
checked=0

for f in tests/ux/*-ux.mjs; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .mjs)"          # e.g. signup-ux
    target="test-${base}"                 # e.g. test-signup-ux
    checked=$((checked + 1))
    if ! make -n "$target" >/dev/null 2>&1; then
        echo "  UNWIRED: $f has no reachable \`make $target\` target"
        missing=$((missing + 1))
    fi
done

if [ "$missing" -gt 0 ]; then
    echo ""
    echo "check-test-wiring: $missing of $checked browser test(s) unreachable from make."
    echo "Add a target (see the DAY_UX pattern rule in the Makefile for the"
    echo "self-contained ones, or the ux-full.sh targets for gateway-backed ones)."
    exit 1
fi

echo "check-test-wiring: all $checked browser tests are reachable from make."

# And every generated file's freshness check is in the gate: each `check-*-fresh`
# target the Makefile defines is in FRESH_CHECKS (or FRESH_EXEMPT, with its reason
# there), and each name in either exists. A generated file added without its check
# in the list would be a file the gate never compares.
declared="$(grep -oE '^check-[a-z0-9-]+-fresh:' Makefile | tr -d ':' | sort -u)"
listed="$(make -s --no-print-directory print-fresh-checks | tr ' ' '\n' | grep . | sort -u)"
unlisted="$(comm -23 <(echo "$declared") <(echo "$listed"))"
unknown="$(comm -13 <(echo "$declared") <(echo "$listed"))"
if [ -n "$unlisted" ] || [ -n "$unknown" ]; then
    [ -n "$unlisted" ] && echo "$unlisted" | sed 's/^/  UNLISTED: /; s/$/ is in no gate list (FRESH_CHECKS or FRESH_EXEMPT)/'
    [ -n "$unknown" ] && echo "$unknown" | sed 's/^/  UNKNOWN: /; s/$/ is listed but the Makefile defines no such target/'
    exit 1
fi
echo "check-test-wiring: all $(echo "$declared" | wc -l) freshness checks are in the gate."

guile --no-auto-compile tools/lint/module-map.scm --check-suites
