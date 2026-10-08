#!/usr/bin/env bash
# openvtc-parity-check.sh — list upstream OpenVTC commits not yet audited
# against our hand-ported credential/trust layer.
#
# Read-only: fetches the upstream repo into a sibling cache directory, diffs
# it against the pin in docs/planning/identity/openvtc-parity.md, and prints the
# commits that touch a credential/trust-relevant path. Never writes to this
# repo or moves the pin — that's a human decision after reading the report.
# Plan: docs/planning/identity/openvtc-parity.md
#
# Usage: tools/openvtc-parity-check.sh
# Env:   PLAYNET_OPENVTC_CACHE=path   (default: ../openvtc-upstream)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN_DOC="$ROOT/docs/planning/openvtc-parity.md"
UPSTREAM="https://github.com/OpenVTC/openvtc.git"
CACHE="${PLAYNET_OPENVTC_CACHE:-$ROOT/../openvtc-upstream}"

# How the two network calls (clone, fetch) reach upstream. A host with a direct
# route uses plain git. A Tor-routed host — the box has no clearnet resolver —
# goes through torsocks. PLAYNET_GIT_PREFIX states it outright; unset, the
# script looks: no answer for the upstream host and a torsocks on PATH means
# torsocks.
if [ -n "${PLAYNET_GIT_PREFIX+set}" ]; then
  read -r -a NETGIT <<< "${PLAYNET_GIT_PREFIX} git"
elif ! getent hosts github.com >/dev/null 2>&1 && command -v torsocks >/dev/null 2>&1; then
  NETGIT=(torsocks git)
else
  NETGIT=(git)
fi

# Paths whose commits actually bear on credential/trust logic — DIDs, VRCs,
# PHCs, SAID/hash computation, signing. Everything else (CI, deps, unrelated
# docs) is noise for this audit.
RELEVANT_PATHS=(
    'openvtc/src'
    'openvtc-core/src'
    'did-git-sign/src'
    'docs/relationships-vrcs.md'
    'docs/openvtc-config-data-structure.md'
    'docs/secured-configuration-management.md'
)

[ -f "$PIN_DOC" ] || { echo "error: missing $PIN_DOC" >&2; exit 2; }

PIN_COMMIT="$(grep -oP '(?<=^PIN_COMMIT=)\S+' "$PIN_DOC")"
PIN_DATE="$(grep -oP '(?<=^PIN_DATE=)\S+' "$PIN_DOC")"
[ -n "$PIN_COMMIT" ] || { echo "error: PIN_COMMIT not found in $PIN_DOC" >&2; exit 2; }

if [ -d "$CACHE/.git" ]; then
    "${NETGIT[@]}" -C "$CACHE" fetch --quiet origin
else
    echo "cloning $UPSTREAM into $CACHE ..."
    "${NETGIT[@]}" clone --quiet "$UPSTREAM" "$CACHE"
fi

HEAD_REF="$(git -C "$CACHE" rev-parse origin/HEAD 2>/dev/null || git -C "$CACHE" rev-parse HEAD)"

if ! git -C "$CACHE" cat-file -e "$PIN_COMMIT" 2>/dev/null; then
    echo "error: pinned commit $PIN_COMMIT not found upstream (rewritten history?)" >&2
    exit 2
fi

TOTAL=$(git -C "$CACHE" log --oneline "$PIN_COMMIT..$HEAD_REF" | wc -l | tr -d ' ')

if [ "$TOTAL" -eq 0 ]; then
    echo "ok: pin $PIN_COMMIT (pinned $PIN_DATE) is upstream HEAD — nothing to audit"
    exit 0
fi

echo "OpenVTC parity check"
echo "  pin:      $PIN_COMMIT (pinned $PIN_DATE)"
echo "  upstream: $HEAD_REF"
echo "  $TOTAL commit(s) since the pin, filtering to credential/trust-relevant paths:"
echo ""

FLAGGED=$(git -C "$CACHE" log --reverse --format='%H|%ad|%s' --date=short \
    "$PIN_COMMIT..$HEAD_REF" -- "${RELEVANT_PATHS[@]}")

if [ -z "$FLAGGED" ]; then
    echo "  none — every commit since the pin is outside credential/trust paths."
    echo ""
else
    while IFS='|' read -r hash date subject; do
        echo "  $date ${hash:0:9} $subject"
        git -C "$CACHE" show --stat --format='' "$hash" -- "${RELEVANT_PATHS[@]}" \
            | sed 's/^/      /' | grep -v '^\s*$'
        echo ""
    done <<< "$FLAGGED"
fi

FLAGGED_COUNT=$(printf '%s\n' "$FLAGGED" | grep -c . || true)
echo "$FLAGGED_COUNT of $TOTAL commit(s) flagged for review."
echo ""
echo "After auditing, update PIN_COMMIT/PIN_DATE/LAST_AUDIT_DATE in $PIN_DOC"
echo "in the same commit as any porting work the audit produced."
