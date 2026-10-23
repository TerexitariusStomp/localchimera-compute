#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# save-opencode-data.sh
# Save OpenCode session data to Persistent storage before shutdown.

set -uo pipefail

PERSISTENT="/home/amnesia/Persistent/opencode"
DATA_DIR="/home/amnesia/.local/share/opencode"

echo "[opencode] Saving session data to Persistent..."

mkdir -p "$PERSISTENT/data"

if [ -f "$DATA_DIR/opencode.db" ]; then
    cp "$DATA_DIR/opencode.db" "$PERSISTENT/data/opencode.db"
    echo "[opencode] Database saved -> Persistent/opencode/data/opencode.db"
fi

if [ -d "$DATA_DIR/storage" ]; then
    rm -rf "$PERSISTENT/data/storage"
    cp -a "$DATA_DIR/storage" "$PERSISTENT/data/storage"
    echo "[opencode] Storage saved  -> Persistent/opencode/data/storage/"
fi

if [ -d "$DATA_DIR/snapshot" ]; then
    rm -rf "$PERSISTENT/data/snapshot"
    cp -a "$DATA_DIR/snapshot" "$PERSISTENT/data/snapshot"
    echo "[opencode] Snapshots saved -> Persistent/opencode/data/snapshot/"
fi

echo "[opencode] Done."
