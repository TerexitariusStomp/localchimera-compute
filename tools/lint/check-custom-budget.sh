#!/usr/bin/env bash
# check-custom-budget — the ≤5% custom-code gate (spec/oss-inventory.md).
#
# Counts first-party source lines: module/, hoot/, tests/ (*.scm), ui/ (*.ts),
# tools/ (*.scm,*.sh,*.mjs). Generated output (browser/*.js, ccache), vendored
# code, docs, data and lockfiles don't count.
#
# The budget is a ratchet: the count may only ever move DOWN toward the 5%
# goal of the deployed system. Fails if the count exceeds the recorded
# baseline; --update records a new (lower-or-equal) baseline.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
BASELINE=tools/lint/custom-budget.baseline

count() {
    { find module hoot tests -name '*.scm' 2>/dev/null;
      find ui -name '*.ts' -o -name '*.tsx' 2>/dev/null;
      find tools -name '*.scm' -o -name '*.sh' -o -name '*.mjs' 2>/dev/null; } \
      | sort -u | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}'
}

now=$(count)
base=$([ -f "$BASELINE" ] && cat "$BASELINE" || echo 0)

if [ "${1:-}" = "--update" ]; then
    if [ "$base" != 0 ] && [ "$now" -gt "$base" ]; then
        echo "check-custom-budget: count rose ${base} → ${now}; baseline not updated" >&2
        exit 1
    fi
    echo "$now" > "$BASELINE"
    echo "check-custom-budget: baseline recorded at $now first-party lines"
    exit 0
fi

if [ "$base" = 0 ]; then
    echo "check-custom-budget: no baseline — run with --update to record $now" >&2
    exit 1
fi
if [ "$now" -gt "$base" ]; then
    echo "check-custom-budget: ${now} lines exceeds baseline ${base} (+$((now - base)))" >&2
    echo "  the budget ratchet only moves down — shrink first-party code or fix the count" >&2
    exit 1
fi
echo "check-custom-budget: ${now} first-party lines ≤ baseline ${base}"
