#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# save-feather-ringdb.sh
# Sync Feather's Monero ringdb back to Persistent so it survives reboot.
# Run periodically or before shutdown.

set -uo pipefail

RINGDB_SRC="/home/amnesia/.shared-ringdb"
RINGDB_DST="/home/amnesia/Persistent/feather_data/shared-ringdb"

if [ -d "$RINGDB_SRC" ]; then
    mkdir -p "$RINGDB_DST"
    cp -a "$RINGDB_SRC"/* "$RINGDB_DST/" 2>/dev/null
    chmod 700 "$RINGDB_DST"
    chmod 600 "$RINGDB_DST"/* 2>/dev/null
    echo "[feather] Ringdb saved to Persistent."
else
    echo "[feather] No ringdb to save yet."
fi
