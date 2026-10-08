#!/bin/bash
# restore-feather.sh
# Run this after each Tails boot to restore Feather wallet's ringdb from Persistent.
# This prevents Feather from having to rescan the entire blockchain on startup.

set -uo pipefail

PERSISTENT="/home/amnesia/Persistent/feather_data"
RINGDB_SRC="$PERSISTENT/shared-ringdb"
RINGDB_DST="/home/amnesia/.shared-ringdb"

echo "[feather] Restoring Monero ringdb from Persistent..."

if [ -d "$RINGDB_SRC" ]; then
    mkdir -p "$RINGDB_DST"
    cp -a "$RINGDB_SRC"/* "$RINGDB_DST/" 2>/dev/null
    chmod 700 "$RINGDB_DST"
    chmod 600 "$RINGDB_DST"/* 2>/dev/null
    echo "[feather] Ringdb restored  -> ~/.shared-ringdb/"
else
    echo "[feather] WARNING: No saved ringdb found in Persistent. First run?"
fi

echo "[feather] Done. Open Feather to pick up where you left off."
