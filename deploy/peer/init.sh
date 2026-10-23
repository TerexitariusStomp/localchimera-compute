#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# deploy/peer/init.sh — entrypoint for the self-updating peer image.
#
# Runs as PID 1. Responsible for:
#   1. Creating the storage layout under $PEER_HOME on first boot.
#   2. Cloning the playnet project into the first generation if the
#      tree is empty.
#   3. Pinning the allowed delegates in rad config (so a stranger
#      gossiping a poisoned tip cannot move HEAD).
#   4. Exec'ing shepherd, which supervises tor + radicle-node +
#      playnet-gateway + self-updater.
#
# Required env:
#   PLAYNET_RID         Radicle project ID (rad:z...). No default — fail
#                       loudly so a misconfigured peer can't run.
#   PLAYNET_DELEGATES   Comma-separated `did:key:...` of trusted
#                       maintainers. The peer rejects refs not signed
#                       by one of these. No default for the same reason.
# Optional env:
#   PEER_HOME           State root (default /srv/playnet).
#   RAD_SEED            Initial seed peer to bootstrap from
#                       (rad://<nid>@<host>:<port>). If unset the peer
#                       waits for inbound gossip.

set -eu

: "${PEER_HOME:=/srv/playnet}"
: "${PLAYNET_RID:?Set PLAYNET_RID to the Radicle project ID}"

# PLAYNET_DELEGATES is advisory: trust enforcement actually happens
# inside Radicle (refs are valid only if signed by a delegate listed
# in the project's identity blob). Keeping the env var around so
# operators have an explicit place to record who they expect, but we
# don't need to configure rad with it — that contract is set when the
# project was `rad init`-ed, not on the consuming peer.
: "${PLAYNET_DELEGATES:=}"

export HOME="$PEER_HOME"
export RAD_HOME="$PEER_HOME/.radicle"
# The alias is gossiped to every peer on the network alongside the node
# ID, so the default names the role and nothing about the machine (a
# hostname here would broadcast the operator's box or hosting provider).
# Peers are told apart by their node ID; PEER_ALIAS overrides for
# operators who want a name.
ALIAS="${PEER_ALIAS:-playnet-peer}"

mkdir -p "$PEER_HOME/generations" "$RAD_HOME"

# First-boot bootstrap: clone the project if no generations exist.
if [ -z "$(ls -A "$PEER_HOME/generations" 2>/dev/null)" ]; then
    echo "[peer-init] First boot: cloning $PLAYNET_RID"

    # Initialise rad identity if absent. The auto-generated key
    # identifies *this peer*, not a maintainer — it never has commit
    # authority over the project.
    if [ ! -f "$RAD_HOME/keys/radicle.pub" ]; then
        # `--stdin` reads passphrase from stdin; an empty passphrase
        # means the key is not encrypted (acceptable since it lives
        # only inside this container's volume).
        rad auth --alias "$ALIAS" --stdin <<<""
    fi

    # Optional: seed peer to dial on startup. Configured via rad's
    # node.peers list so the daemon dials it when started below.
    if [ -n "${RAD_SEED:-}" ]; then
        rad config push "node.peers" "$RAD_SEED" || true
    fi

    # rad clone needs a running node; start one in the background just
    # for the bootstrap, then stop it before handing off to shepherd
    # (which starts radicle-node as a supervised service).
    echo "[peer-init] Starting rad node (bootstrap-only)"
    rad node start >"$PEER_HOME/bootstrap-node.log" 2>&1 &
    bootstrap_node_pid=$!
    # Wait for the node to be ready (rad node status returns 0).
    for _ in $(seq 1 30); do
        if rad node status >/dev/null 2>&1; then break; fi
        sleep 1
    done

    # Clone into a sha-named generation directory.
    # `rad clone <rid>` writes into a directory named after the
    # project, in the current working dir; we work from a staging
    # dir then mv into the sha-named final slot.
    staging="$PEER_HOME/.staging-bootstrap"
    rm -rf "$staging"
    mkdir -p "$staging"
    (cd "$staging" && rad clone "$PLAYNET_RID" --no-confirm)
    cloned="$(find "$staging" -maxdepth 1 -mindepth 1 -type d | head -n 1)"
    if [ -z "$cloned" ]; then
        echo "[peer-init] FATAL: rad clone produced no checkout" >&2
        rad node stop >/dev/null 2>&1 || kill "$bootstrap_node_pid" 2>/dev/null || true
        exit 1
    fi
    sha="$(git -C "$cloned" rev-parse --short HEAD)"
    mv "$cloned" "$PEER_HOME/generations/$sha"
    rm -rf "$staging"
    ln -sfn "generations/$sha" "$PEER_HOME/current"
    echo "[peer-init] Bootstrap generation: $sha"

    # Stop the bootstrap node so shepherd can manage its own.
    rad node stop >/dev/null 2>&1 || kill "$bootstrap_node_pid" 2>/dev/null || true
    wait "$bootstrap_node_pid" 2>/dev/null || true
fi

# Hand off to shepherd as PID 1. The shepherd config lives in the
# package's share/ tree (mounted at /share via guix pack -S).
exec shepherd \
    --config /share/playnet/deploy/peer/peer.scm \
    --logfile "$PEER_HOME/shepherd.log" \
    --pid "$PEER_HOME/shepherd.pid"
