#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# reconfigure.sh — Guix system reconfigure
#
# Two commands. That's it.
# guix pull fetches the channel, guix system reconfigure deploys.
# No -L flags, no -e quoting, no shell workarounds.
#
# Usage (on the server as deploy user):
#   bash deploy/scripts/reconfigure.sh

set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/home/deploy/playnet-deploy}"

if [ -z "${PLAYNET_PROVIDER:-}" ]; then
    echo "[reconfigure] ERROR: Set PLAYNET_PROVIDER to a provider config file."
    echo "  Example: PLAYNET_PROVIDER=deploy/providers/iceland.scm bash deploy/scripts/reconfigure.sh"
    exit 1
fi

# Tor-or-die. guix pull and reconfigure fetch from clearnet substitute
# servers (bordeaux.guix.gnu.org, iris.radicle.xyz). Without torsocks the
# operator's IP is exposed on every deploy. Setting PLAYNET_ALLOW_CLEARNET=1
# is supported only for first-deploy bootstrapping from Tails/Whonix where
# the network is already Tor-only.
TOR=""
if command -v torsocks >/dev/null 2>&1; then
    TOR="torsocks"
elif [ "${PLAYNET_ALLOW_CLEARNET:-0}" != "1" ]; then
    echo "[reconfigure] ERROR: torsocks not found and PLAYNET_ALLOW_CLEARNET!=1."
    echo "  Install torsocks (sudo guix install torsocks) or run from Tails/Whonix."
    exit 1
fi

export PLAYNET_PROVIDER

echo "[reconfigure] Provider: $PLAYNET_PROVIDER"
echo "[reconfigure] Pulling channels${TOR:+ via $TOR}..."
sudo $TOR guix pull -C "$DEPLOY_DIR/deploy/channels.scm" --verbosity=1

echo "[reconfigure] Running guix system reconfigure${TOR:+ via $TOR}..."
sudo PLAYNET_PROVIDER="$PLAYNET_PROVIDER" \
    $TOR /root/.config/guix/current/bin/guix system reconfigure \
    "$DEPLOY_DIR/deploy/machines.scm" \
    --allow-downgrades \
    --verbosity=2

echo "[reconfigure] Seeding mutable checkout..."
sudo rsync -a --delete \
    --include='module/***' \
    --include='server/***' \
    --include='browser/***' \
    --include='tests/***' \
    --include='docs/***' \
    --include='deploy/***' \
    --include='Makefile' \
    --exclude='*' \
    "$DEPLOY_DIR/" /home/playnet/playnet-repo/
sudo chown -R playnet:users /home/playnet/playnet-repo/

echo "[reconfigure] Done."
