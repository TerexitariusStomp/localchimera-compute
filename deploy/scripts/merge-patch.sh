#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# merge-patch.sh — DELEGATE action: merge a contributor's Radicle patch to
# canonical main (and thereby deploy it).
#
#   bash deploy/scripts/merge-patch.sh <patch-id> [agent-name]
#
# This is the "ship" half of the split flow: CONTRIBUTORS only ever run
# `rad patch open` (no infra access, no deploy key — see CONTRIBUTING.md).
# DELEGATES review the patch on the board, then run this to promote it.
#
# It is a thin, opinionated wrapper around promote.sh:
#   1. Resolve the patch's head commit from its Radicle COB.
#   2. Refuse anything that isn't a fast-forward over canonical main
#      (promote.sh is ff-only by design — it will not guess a merge/rebase
#      on your behalf; if the patch is behind, ask the contributor to
#      `git rebase` onto canonical and update the patch, or rebase + re-sign
#      it yourself first).
#   3. Hand the head to promote.sh, which authenticates the signed chain on
#      the box, fast-forwards the live checkout, advances Radicle canonical,
#      and lets the CI hook redeploy (≤300s).
#   4. On success, mark the patch merged in Radicle so the board reflects it.
#
# Tor-only: every remote touch is inherited from promote.sh (torsocks).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH="${1:?usage: merge-patch.sh <patch-id> [agent-name]}"
AGENT="${2:-claude}"
: "${LOCALCHIMERA_RID:=rad:z27dFkN28LQAsSsG3DVHcfBqYAArQ}"

command -v rad >/dev/null || { echo "[merge-patch] ERROR: rad CLI not found"; exit 1; }

echo "[merge-patch] resolving patch $PATCH"
# Capture patch state once. `rad patch show` renders a box-drawing table; we
# read the head SHA and the CI labels off it.
SHOW="$(rad patch show "$PATCH" --repo "$LOCALCHIMERA_RID" 2>/dev/null)"
# Head = the 40-hex on the "Head" row (robust to the │ borders / column padding).
HEAD_SHA="$(echo "$SHOW" | grep -i head | grep -oiE '[0-9a-f]{40}' | head -1)"
[ -n "$HEAD_SHA" ] || { echo "[merge-patch] ERROR: could not resolve head of patch $PATCH"; exit 1; }
echo "[merge-patch] patch head = $HEAD_SHA"

# --- CI: native Radicle broker (no label gate) ------------------------------
# CI runs natively via the seed's radicle-ci-broker: it executes the patch's
# .radicle/native.yaml steps and posts the result as a CI JOB COB, shown on the
# board. There is no ci-pass/ci-fail label to gate on, and rad 1.7 exposes no
# CLI to query the job status — so this tool does NOT auto-gate on CI. Confirm
# the patch's CI job passed on the board before merging; the fast-forward and
# GPG-signature checks below still guard what actually ships.
echo "[merge-patch] NOTE: CI is native (radicle-ci-broker job COB). Confirm it"
echo "              passed at localchimera.earth/radicle before merging this patch."

# Make sure we actually have the object locally (fetch the patch branch).
if ! git cat-file -e "$HEAD_SHA^{commit}" 2>/dev/null; then
    echo "[merge-patch] fetching patch objects via rad"
    rad patch checkout "$PATCH" --repo "$LOCALCHIMERA_RID" >/dev/null 2>&1 || true
fi
git cat-file -e "$HEAD_SHA^{commit}" 2>/dev/null \
    || { echo "[merge-patch] ERROR: patch head $HEAD_SHA not in local storage after checkout"; exit 1; }

# Delegate must sign what ships. If the patch head isn't signed by a key git
# trusts here, promote.sh will reject it downstream — but say so early.
sig="$(git log --format='%G?' -1 "$HEAD_SHA" 2>/dev/null || echo '?')"
if [ "$sig" != "G" ] && [ "$sig" != "U" ]; then
    echo "[merge-patch] NOTE: patch head is not GPG-signed (got '$sig')."
    echo "             promote.sh requires a signed tip. Rebase + sign it yourself,"
    echo "             or ask the contributor to sign, before promoting."
    exit 1
fi

echo "[merge-patch] handing $HEAD_SHA to promote.sh"
bash "$HERE/promote.sh" "$HEAD_SHA" "$AGENT"

# There is no `rad patch merge`: Radicle marks a patch merged by itself once its
# head is in canonical. So read the state back instead of trying to set it. A
# patch that still reads "open" here has not synced from canonical to this node
# yet (it shows merged once it does); it is not a failed step.
status=$(rad patch show "$PATCH" --repo "$LOCALCHIMERA_RID" 2>/dev/null \
           | awk '/^│ Status/ {print $3}' || true)
echo "[merge-patch] patch $PATCH: status ${status:-unknown} (Radicle marks it merged itself once its head is in canonical)"

echo "[merge-patch] done — CI hook redeploys within ≤300s."
