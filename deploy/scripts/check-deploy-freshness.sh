#!/usr/bin/env bash
# check-deploy-freshness.sh — alarm for the gap NOTHING else watches:
# local `main` vs the box's deployed canonical.
#
# The box's radicle-ci auto-deploy is healthy and self-heals its *own* lag
# (box-canonical → seeds via --refetch). But it can only deploy what canonical
# advanced to, and canonical only advances when a delegate runs `make ship`.
# So a `main`-ahead-of-canonical gap (ship overdue) is invisible to every
# box-side mechanism — that's how the 2026-07-21 → 07-27 freeze went unnoticed
# for ~6 days. This closes that blind spot: run it from the dev host (cron or
# by hand) and it shouts when a ship is overdue.
#
# Usage:
#   deploy/scripts/check-deploy-freshness.sh
#   PLAYNET_BOX=playnet-server BRANCH=main WARN_COMMITS=1 WARN_DAYS=2 …
#
# Exit codes: 0 = fresh (or within threshold), 1 = STALE (ship overdue),
#             2 = could not determine (box unreachable / bad state).

set -uo pipefail

BOX="${PLAYNET_BOX:-playnet-server}"
BRANCH="${BRANCH:-main}"
CO="${BOX_CHECKOUT:-/var/lib/playnet/radicle/checkout}"
WARN_COMMITS="${WARN_COMMITS:-1}"   # alarm if >= this many commits ahead
WARN_DAYS="${WARN_DAYS:-3}"         # escalate wording past this staleness
SSH_OPTS="-o ConnectTimeout=60 -o BatchMode=yes"

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "freshness: not in a git repo" >&2; exit 2; }

local_tip=$(git rev-parse --verify "$BRANCH" 2>/dev/null) || {
    echo "freshness: no local branch '$BRANCH'" >&2; exit 2; }

box_canon=$(timeout 90 ssh $SSH_OPTS "$BOX" "git -C '$CO' rev-parse HEAD" 2>/dev/null | tr -d '[:space:]')
if [ -z "$box_canon" ]; then
    echo "freshness: could not read box canonical from $BOX:$CO (unreachable?)" >&2
    exit 2
fi

if [ "$box_canon" = "$local_tip" ]; then
    echo "freshness: OK — box canonical == local $BRANCH ($(git rev-parse --short "$local_tip"))"
    exit 0
fi

# How far ahead is local main? (requires the box commit to be an ancestor;
# if it isn't, histories diverged — a louder problem.)
if git merge-base --is-ancestor "$box_canon" "$local_tip" 2>/dev/null; then
    behind=$(git rev-list --count "$box_canon..$local_tip")
    box_date=$(git show -s --format=%ci "$box_canon" 2>/dev/null || echo "?")
    unsigned=$(git rev-list "$box_canon..$local_tip" 2>/dev/null \
                 | while read -r c; do [ "$(git log --format='%G?' -1 "$c")" = "N" ] \
                     && git log --format='  unsigned: %h %s' -1 "$c"; done)
    if [ "$behind" -ge "$WARN_COMMITS" ]; then
        echo "freshness: STALE — box canonical is $behind commit(s) behind local $BRANCH." >&2
        echo "  box @ $(git rev-parse --short "$box_canon")  ($box_date)" >&2
        echo "  main @ $(git rev-parse --short "$local_tip")" >&2
        echo "  undeployed:" >&2
        git --no-pager log --format='    %h %G? %s' "$box_canon..$local_tip" >&2
        [ -n "$unsigned" ] && { echo "  BLOCKERS (unsigned — will fail/complicate ship):" >&2; echo "$unsigned" >&2; }
        echo "  → run: make ship" >&2
        exit 1
    fi
    echo "freshness: OK — $behind commit(s) ahead, within threshold ($WARN_COMMITS)"
    exit 0
else
    echo "freshness: DIVERGED — box canonical $(git rev-parse --short "$box_canon") is NOT an" >&2
    echo "  ancestor of local $BRANCH. Histories forked (rewrite/reset?). Investigate before ship." >&2
    exit 1
fi
