#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# restore-opencode.sh
# Run this after each Tails boot to restore OpenCode from Persistent storage.
# You can add this to ~/.bashrc or call it manually.

set -uo pipefail

PERSISTENT="/home/amnesia/Persistent/opencode"

echo "[opencode] Restoring OpenCode from Persistent..."

# --- Binary ---
mkdir -p /home/amnesia/.opencode/bin
if [ -f "$PERSISTENT/bin/opencode" ]; then
    if cp "$PERSISTENT/bin/opencode" /home/amnesia/.opencode/bin/opencode 2>/dev/null; then
        chmod +x /home/amnesia/.opencode/bin/opencode
        echo "[opencode] Binary restored -> ~/.opencode/bin/opencode"
    else
        # Binary may be busy (already running) - symlink as fallback
        ln -sf "$PERSISTENT/bin/opencode" /home/amnesia/.opencode/bin/opencode 2>/dev/null || true
        echo "[opencode] Binary busy (already running?) - symlinked instead"
    fi
else
    echo "[opencode] WARNING: Binary not found in Persistent!"
fi

# Symlink into Persistent/bin so it's on PATH via Persistent/bin
ln -sf "$PERSISTENT/bin/opencode" /home/amnesia/Persistent/bin/opencode 2>/dev/null || true

# --- Config ---
mkdir -p /home/amnesia/.config/opencode
if [ -f "$PERSISTENT/config/opencode.json" ]; then
    cp "$PERSISTENT/config/opencode.json" /home/amnesia/.config/opencode/opencode.json
    echo "[opencode] Config restored  -> ~/.config/opencode/opencode.json"
else
    echo "[opencode] WARNING: Config not found in Persistent!"
fi

# --- Auth (from vault if mounted, else plaintext fallback) ---
mkdir -p /home/amnesia/.local/share/opencode
VAULT="/home/amnesia/Persistent/vault"
AUTH_SRC=""
if mountpoint -q "$VAULT" 2>/dev/null && [ -f "$VAULT/opencode-auth/auth.json" ]; then
    AUTH_SRC="$VAULT/opencode-auth/auth.json"
elif [ -f "$PERSISTENT/auth/auth.json" ]; then
    AUTH_SRC="$PERSISTENT/auth/auth.json"
fi
if [ -n "$AUTH_SRC" ]; then
    cp "$AUTH_SRC" /home/amnesia/.local/share/opencode/auth.json
    chmod 600 /home/amnesia/.local/share/opencode/auth.json
    echo "[opencode] Auth restored    -> ~/.local/share/opencode/auth.json"
else
    echo "[opencode] WARNING: Auth not found (mount vault or check Persistent/opencode/auth/)"
fi

# --- vsudo ---
mkdir -p /home/amnesia/.local/bin
if [ -f /home/amnesia/Persistent/scripts/vsudo ]; then
    cp /home/amnesia/Persistent/scripts/vsudo /home/amnesia/.local/bin/vsudo
    chmod +x /home/amnesia/.local/bin/vsudo
    echo "[opencode] vsudo restored   -> ~/.local/bin/vsudo"
fi

# --- Session Data (DB, storage, snapshots) ---
if [ -d "$PERSISTENT/data" ]; then
    DATA_DIR="/home/amnesia/.local/share/opencode"
    mkdir -p "$DATA_DIR"

    if [ -f "$PERSISTENT/data/opencode.db" ]; then
        cp "$PERSISTENT/data/opencode.db" "$DATA_DIR/opencode.db"
        echo "[opencode] Database restored -> ~/.local/share/opencode/opencode.db"
    fi

    if [ -d "$PERSISTENT/data/storage" ]; then
        rm -rf "$DATA_DIR/storage"
        cp -a "$PERSISTENT/data/storage" "$DATA_DIR/storage"
        echo "[opencode] Storage restored  -> ~/.local/share/opencode/storage/"
    fi

    if [ -d "$PERSISTENT/data/snapshot" ]; then
        rm -rf "$DATA_DIR/snapshot"
        cp -a "$PERSISTENT/data/snapshot" "$DATA_DIR/snapshot"
        echo "[opencode] Snapshots restored -> ~/.local/share/opencode/snapshot/"
    fi
else
    echo "[opencode] No saved session data found (first boot or not saved yet)"
fi

# --- PATH ---
if [[ ":$PATH:" != *":$HOME/.opencode/bin:"* ]]; then
    export PATH="$HOME/.opencode/bin:$PATH"
fi
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

echo "[opencode] Done. Run 'opencode' to start."
