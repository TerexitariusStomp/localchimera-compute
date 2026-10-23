#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# save-guix-state.sh
# Saves /var/guix state back to Persistent so it survives the next reboot.
# Run before shutting down Tails. Uses vsudo for graphical auth.

set -uo pipefail

PERSISTENT_VAR="/home/amnesia/Persistent/guix-var"
VSUDO="/home/amnesia/Persistent/scripts/vsudo"

echo "[guix] Saving /var/guix state to Persistent..."

if [ -d /var/guix ] && [ "$(ls -A /var/guix 2>/dev/null)" ]; then
    mkdir -p "$PERSISTENT_VAR"
    vsudo cp -a /var/guix/* "$PERSISTENT_VAR/" 2>/dev/null
    vsudo chown -R amnesia:amnesia "$PERSISTENT_VAR" 2>/dev/null
    echo "[guix] /var/guix state saved."
else
    echo "[guix] No /var/guix state to save yet."
fi

if [ -d ~/.config/guix/current ]; then
    mkdir -p /home/amnesia/Persistent/guix-user-config
    cp -a ~/.config/guix/* /home/amnesia/Persistent/guix-user-config/ 2>/dev/null || true
    echo "[guix] User config saved."
fi
