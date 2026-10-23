#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# restore-radicle.sh
# Restores Radicle from Persistent storage after a Tails reboot.
# - Adds rad/radicle-node/git-remote-rad to PATH
# - Restores ~/.radicle data (identity from vault if mounted, config, node state)
# - Sets up Tor hidden service for Radicle (needs admin password)
# - Starts rad node

set -uo pipefail

PERSISTENT="/home/amnesia/Persistent/radicle-1.8.0-x86_64-unknown-linux-musl"
RADICLE_BIN="$PERSISTENT/bin"
RADICLE_DATA="/home/amnesia/Persistent/radicle-data"
LOCAL_BIN="/home/amnesia/.local/bin"
VAULT="/home/amnesia/Persistent/vault"
TOR_ONION_SERVICE="/home/amnesia/Persistent/tor-onion-service"
SETUP_TOR_SCRIPT="/home/amnesia/Persistent/scripts/setup-tor-onion-service.sh"
# Single-line "<NID>@<onion>.onion:8776" pointing at the playnet seed.
# Written by the operator after `rad self --nid` on the server; without
# it `rad sync` has to discover seeds via DHT, which is what fails on
# fresh Tails sessions.
PLAYNET_SEED_FILE="/home/amnesia/Persistent/scripts/playnet-seed.txt"

echo "[radicle] Restoring Radicle from Persistent..."

# --- Binaries on PATH ---
mkdir -p "$LOCAL_BIN"
ln -sf "$RADICLE_BIN/rad" "$LOCAL_BIN/rad" 2>/dev/null
ln -sf "$RADICLE_BIN/radicle-node" "$LOCAL_BIN/radicle-node" 2>/dev/null
ln -sf "$RADICLE_BIN/git-remote-rad" "$LOCAL_BIN/git-remote-rad" 2>/dev/null

if [[ ":$PATH:" != *":$LOCAL_BIN:"* ]]; then
    export PATH="$LOCAL_BIN:$PATH"
fi

# --- Radicle data directory ---
if [ -d "$RADICLE_DATA" ]; then
    if [ ! -d ~/.radicle ] || [ -z "$(ls -A ~/.radicle 2>/dev/null)" ]; then
        mkdir -p ~/.radicle
        cp -a "$RADICLE_DATA"/* ~/.radicle/ 2>/dev/null || true
        echo "[radicle] Data restored -> ~/.radicle/"
    else
        echo "[radicle] ~/.radicle already exists, skipping restore"
    fi
else
    echo "[radicle] No saved data found. Run 'rad auth' to set up identity."
fi

# --- Radicle keys from vault ---
if mountpoint -q "$VAULT" 2>/dev/null && [ -f "$VAULT/radicle-keys/radicle" ]; then
    mkdir -p ~/.radicle/keys
    cp "$VAULT/radicle-keys/radicle" ~/.radicle/keys/radicle
    cp "$VAULT/radicle-keys/radicle.pub" ~/.radicle/keys/radicle.pub
    chmod 600 ~/.radicle/keys/radicle
    echo "[radicle] Keys restored from vault -> ~/.radicle/keys/"
elif [ -d "$RADICLE_DATA/keys" ]; then
    mkdir -p ~/.radicle/keys
    cp -a "$RADICLE_DATA/keys/"* ~/.radicle/keys/ 2>/dev/null || true
    echo "[radicle] Keys restored from plaintext fallback -> ~/.radicle/keys/"
fi

# --- Tor hidden service for Radicle ---
if [ -f "$SETUP_TOR_SCRIPT" ] && [ -d "$TOR_ONION_SERVICE" ]; then
    echo "[radicle] Setting up Tor hidden service (requires admin password)..."
    sudo bash "$SETUP_TOR_SCRIPT" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "[radicle] Tor hidden service configured."
        ONION_ADDR=""
        if [ -f "$TOR_ONION_SERVICE/onion-address.txt" ]; then
            ONION_ADDR=$(cat "$TOR_ONION_SERVICE/onion-address.txt" | tr -d '[:space:]')
        fi
        if [ -n "$ONION_ADDR" ] && [ -f ~/.radicle/config.json ]; then
            python3 -c "
import json, sys
c = json.load(open('$HOME/.radicle/config.json'))
c['node']['listen'] = ['0.0.0.0:8776']
c['node']['externalAddresses'] = ['$ONION_ADDR:8776']
c['node']['onion'] = {'mode': 'forward'}
c['node']['proxy'] = '127.0.0.1:9050'
json.dump(c, open('$HOME/.radicle/config.json', 'w'), indent=2)
" 2>/dev/null
            echo "[radicle] Config updated with onion address: $ONION_ADDR"
        fi
    else
        echo "[radicle] Tor hidden service setup failed (skipping)."
    fi
else
    echo "[radicle] Tor hidden service not configured (missing keys or script)."
fi

# --- Playnet seed wiring (preferredSeeds + persistent connect) ---
if [ -s "$PLAYNET_SEED_FILE" ] && [ -f ~/.radicle/config.json ]; then
    PLAYNET_SEED=$(tr -d '[:space:]' < "$PLAYNET_SEED_FILE")
    if [[ "$PLAYNET_SEED" == *"@"*".onion:"* ]]; then
        PLAYNET_SEED="$PLAYNET_SEED" python3 -c "
import json, os
p = os.path.expanduser('~/.radicle/config.json')
c = json.load(open(p))
seed = os.environ['PLAYNET_SEED']
node = c.setdefault('node', {})
node['proxy'] = node.get('proxy', '127.0.0.1:9050')
node.setdefault('onion', {})['mode'] = 'forward'
for key in ('preferredSeeds', 'connect'):
    xs = node.get(key, [])
    if seed not in xs:
        xs.append(seed)
    node[key] = xs
json.dump(c, open(p, 'w'), indent=2)
" 2>/dev/null && echo "[radicle] Preferred seed wired: $PLAYNET_SEED"
    else
        echo "[radicle] WARN: $PLAYNET_SEED_FILE does not look like <NID>@<onion>.onion:<port>"
    fi
fi

# --- Start rad node ---
if command -v rad > /dev/null 2>&1; then
    rad node start 2>/dev/null
    echo "[radicle] Node started."
fi

if command -v rad > /dev/null 2>&1; then
    RAD_VER=$(rad --version 2>/dev/null || echo "unknown")
    echo "[radicle] Done! rad available: $RAD_VER"
else
    echo "[radicle] WARNING: rad not found in PATH"
fi
