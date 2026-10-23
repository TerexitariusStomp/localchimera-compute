#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# deploy/peer/updater.sh — in-container Radicle updater.
#
# Watches `rad node events` for ref updates on $PLAYNET_RID and, on
# each update, runs the four fences:
#
#   1. Delegate-signature gate     (Radicle native — fetch only honors
#                                   refs signed by pinned delegates)
#   2. Preflight gate              (run preflight-check.scm in the new
#                                   tree before applying)
#   3. Atomic generation switch    (fetch into a sha-named directory,
#                                   move symlink current → new sha)
#   4. Crash-loop rollback         (handled by shepherd in peer.scm —
#                                   if gateway dies ≥3× in 60s after
#                                   an update, herd rollback flips the
#                                   symlink back to `previous`)
#
# Run as a shepherd service. Designed to never exit on its own; if it
# does, shepherd will restart it.

set -eu

: "${PEER_HOME:=/srv/playnet}"
: "${PLAYNET_RID:?Set PLAYNET_RID}"

export HOME="$PEER_HOME"
export RAD_HOME="$PEER_HOME/.radicle"

LOG_PREFIX="[peer-updater]"
log() { echo "$LOG_PREFIX $(date -Iseconds) $*"; }

run_preflight() {
    # Run against the candidate tree, not the live one.
    local tree="$1"
    if [ -f "$tree/deploy/scripts/preflight-check.scm" ]; then
        log "preflight: $tree"
        guile -L "$tree/module" "$tree/deploy/scripts/preflight-check.scm" 2>&1 \
            | sed "s|^|$LOG_PREFIX preflight: |"
        return "${PIPESTATUS[0]:-$?}"
    fi
    log "preflight: no script in tree, skipping (advisory)"
    return 0
}

apply_update() {
    local new_sha="$1"
    local gen_dir="$PEER_HOME/generations/$new_sha"
    local prev_target

    if [ -d "$gen_dir" ]; then
        log "Generation $new_sha already materialized"
    else
        log "Materializing generation $new_sha"
        local tmp="$PEER_HOME/generations/.staging-$$"
        rm -rf "$tmp"
        # Clone from local rad storage into staging.
        git clone --quiet "$RAD_HOME/storage/${PLAYNET_RID#rad:}" "$tmp"
        git -C "$tmp" checkout --quiet "$new_sha"
        if ! run_preflight "$tmp"; then
            log "Preflight FAILED for $new_sha — discarding, staying on current"
            rm -rf "$tmp"
            return 0
        fi
        mv "$tmp" "$gen_dir"
    fi

    # Atomic symlink swap. previous → old current; current → new sha.
    if [ -L "$PEER_HOME/current" ]; then
        prev_target="$(readlink "$PEER_HOME/current")"
        ln -sfn "$prev_target" "$PEER_HOME/previous.new"
        mv -T "$PEER_HOME/previous.new" "$PEER_HOME/previous"
    fi
    ln -sfn "generations/$new_sha" "$PEER_HOME/current.new"
    mv -T "$PEER_HOME/current.new" "$PEER_HOME/current"
    log "Switched current → $new_sha"

    # Trigger a clean restart. Shepherd's crash-loop policy in peer.scm
    # handles the rollback if the new generation can't stay up.
    herd restart playnet-gateway || log "WARNING: herd restart failed"

    # Prune: keep current, previous, and 3 most recent.
    keep="$(readlink "$PEER_HOME/current") $(readlink "$PEER_HOME/previous" 2>/dev/null || true)"
    ls -1t "$PEER_HOME/generations" 2>/dev/null \
        | grep -v '^\.' \
        | tail -n +6 \
        | while read -r d; do
            case " $keep " in
                *" generations/$d "*) ;;
                *) rm -rf "$PEER_HOME/generations/$d" ;;
            esac
          done
}

# Watch loop: rad node events stream can disconnect; reconnect with
# exponential backoff capped at 60s.
backoff=1
while true; do
    log "Watching rad node events for $PLAYNET_RID"
    rad node events 2>/dev/null | while IFS= read -r event; do
        backoff=1
        case "$event" in
            *"$PLAYNET_RID"*RefsFetched*|*"$PLAYNET_RID"*refs-changed*)
                log "Ref update: $event"
                # Rad fetch already happened (RefsFetched). Read the
                # new tip from local storage.
                new_sha="$(git -C "$RAD_HOME/storage/${PLAYNET_RID#rad:}" \
                            rev-parse --short HEAD 2>/dev/null || echo "")"
                cur_sha="$(readlink "$PEER_HOME/current" 2>/dev/null \
                            | sed 's|^generations/||' || echo "")"
                if [ -n "$new_sha" ] && [ "$new_sha" != "$cur_sha" ]; then
                    apply_update "$new_sha" || \
                        log "apply_update failed (continuing watch)"
                fi
                ;;
        esac
    done
    log "Event stream ended; reconnecting in ${backoff}s"
    sleep "$backoff"
    backoff=$((backoff * 2))
    [ "$backoff" -gt 60 ] && backoff=60
done
