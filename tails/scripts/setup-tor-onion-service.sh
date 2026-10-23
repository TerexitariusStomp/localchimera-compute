#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# setup-tor-onion-service.sh
# Sets up a Tor hidden service for Radicle on Tails.
# Stores onion service keys in vault (encrypted) if mounted,
# otherwise falls back to ~/Persistent/tor-onion-service/ (plaintext).
# Must run with root (via sudo).
#
# This script:
# 1. Creates /var/lib/tor/radicle with proper ownership
# 2. Copies onion keys from vault or plaintext (if any) or generates new ones
# 3. Appends HiddenServiceDir/HiddenServicePort to torrc
# 4. Reloads Tor
# 5. Reads the .onion address and saves it

PERSISTENT_DIR="/home/amnesia/Persistent/tor-onion-service"
VAULT_DIR="/home/amnesia/Persistent/vault/tor-onion"
ONION_DIR="/var/lib/tor/radicle"
TORRC="/etc/tor/torrc"
ONION_PORT=8776

mkdir -p "$PERSISTENT_DIR"

# Step 1: Create onion service directory
mkdir -p "$ONION_DIR"
chmod 700 "$ONION_DIR"

# Step 2: Copy keys from vault (preferred) or plaintext fallback
KEYS_SRC=""
if mountpoint -q /home/amnesia/Persistent/vault 2>/dev/null && [ -f "$VAULT_DIR/hs_ed25519_secret_key" ]; then
    KEYS_SRC="$VAULT_DIR"
    echo "Restoring onion service keys from vault."
elif [ -f "$PERSISTENT_DIR/hs_ed25519_secret_key" ]; then
    KEYS_SRC="$PERSISTENT_DIR"
    echo "Restoring onion service keys from plaintext fallback."
fi

if [ -n "$KEYS_SRC" ]; then
    cat "$KEYS_SRC/hs_ed25519_secret_key" > "$ONION_DIR/hs_ed25519_secret_key"
    cat "$KEYS_SRC/hs_ed25519_public_key" > "$ONION_DIR/hs_ed25519_public_key"
fi

chown -R debian-tor:debian-tor "$ONION_DIR"
chmod 700 "$ONION_DIR"

# Step 3: Add hidden service config to torrc if not already there
if ! grep -q "HiddenServiceDir.*radicle" "$TORRC" 2>/dev/null; then
    echo "" >> "$TORRC"
    echo "## Radicle Onion Service" >> "$TORRC"
    echo "HiddenServiceDir $ONION_DIR" >> "$TORRC"
    echo "HiddenServicePort $ONION_PORT 127.0.0.1:$ONION_PORT" >> "$TORRC"
    echo "Added hidden service config to torrc."
else
    echo "Hidden service config already in torrc."
fi

# Step 4: Reload Tor to pick up the new config
systemctl reload tor 2>/dev/null || systemctl restart tor 2>/dev/null
echo "Tor reloaded."

# Step 5: Wait for onion address to appear, then save it
for i in $(seq 1 10); do
    if [ -f "$ONION_DIR/hostname" ]; then
        ONION_ADDR=$(cat "$ONION_DIR/hostname" | tr -d '[:space:]')
        echo "$ONION_ADDR" > "$PERSISTENT_DIR/onion-address.txt"
        echo "Onion address: $ONION_ADDR"

        # Save keys back to vault if mounted, and plaintext as fallback
        if mountpoint -q /home/amnesia/Persistent/vault 2>/dev/null; then
            mkdir -p "$VAULT_DIR"
            cat "$ONION_DIR/hs_ed25519_secret_key" > "$VAULT_DIR/hs_ed25519_secret_key" 2>/dev/null || true
            cat "$ONION_DIR/hs_ed25519_public_key" > "$VAULT_DIR/hs_ed25519_public_key" 2>/dev/null || true
        fi
        # Also save to plaintext as non-secret fallback (keys only, not for new setups)
        cat "$ONION_DIR/hs_ed25519_secret_key" > "$PERSISTENT_DIR/hs_ed25519_secret_key" 2>/dev/null || true
        cat "$ONION_DIR/hs_ed25519_public_key" > "$PERSISTENT_DIR/hs_ed25519_public_key" 2>/dev/null || true
        chmod 600 "$PERSISTENT_DIR/hs_ed25519_secret_key" 2>/dev/null || true
        echo "Keys saved."
        exit 0
    fi
    sleep 1
done

echo "ERROR: Onion address not found after 10 seconds."
exit 1
