#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# first-run-setup.sh
# For new users who copied the USB. Wipes old encrypted vault, creates a new one,
# generates fresh identities, and walks through adding API keys.

set -uo pipefail

PERSISTENT="/home/amnesia/Persistent"
VAULT_CIPHER="$PERSISTENT/vault-cipher"
VAULT="$PERSISTENT/vault"

# --- Git anonymous config ---
git config --global user.name "amnesia"
git config --global user.email "amnesia@amnesia.org"

echo "============================================"
echo "  Tails Persistent - First Run Setup"
echo "============================================"
echo ""
echo "This will set up your own encrypted vault and"
echo "generate fresh identities. If you already have a"
echo "working vault, press Ctrl+C now."
echo ""

# --- Check prerequisites ---
if ! command -v gocryptfs &>/dev/null; then
    echo "[setup] Installing gocryptfs..."
    sudo apt-get install -y gocryptfs || { echo "[setup] ERROR: Failed to install gocryptfs."; exit 1; }
fi

# --- Wipe old vault and create fresh ---
echo ""
echo "[1/5] Creating encrypted vault..."
echo "  The old vault-cipher/ (if any) will be replaced."
echo ""
read -p "  Continue? [y/N] " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Aborted."
    exit 0
fi

# Unmount if mounted
if mountpoint -q "$VAULT" 2>/dev/null; then
    fusermount -u "$VAULT" 2>/dev/null || true
fi

# Wipe old cipher data
rm -rf "$VAULT_CIPHER"
mkdir -p "$VAULT_CIPHER" "$VAULT"

echo ""
echo "  Choose a strong passphrase for your vault."
echo "  You will need this every time you boot Tails."
echo ""
gocryptfs -init "$VAULT_CIPHER"
if [ $? -ne 0 ]; then
    echo "[setup] ERROR: Vault initialization failed."
    exit 1
fi

# Mount the new vault
echo ""
echo "  Mounting your new vault..."
gocryptfs "$VAULT_CIPHER" "$VAULT"
if [ $? -ne 0 ]; then
    echo "[setup] ERROR: Failed to mount vault."
    exit 1
fi

# --- Create vault directory structure ---
mkdir -p "$VAULT/opencode-auth"
mkdir -p "$VAULT/tor-onion"
mkdir -p "$VAULT/radicle-keys"
mkdir -p "$VAULT/nano-gpt"
mkdir -p "$VAULT/feather-wallets"

echo ""
echo "[2/5] Radicle identity..."
echo "  Creating a new Radicle identity."
echo ""
read -p "  Choose an alias: " RAD_ALIAS
if [ -n "$RAD_ALIAS" ]; then
    # Ensure rad is on PATH
    export PATH="/home/amnesia/.local/bin:$PATH"
    ln -sf /home/amnesia/Persistent/radicle-1.8.0-x86_64-unknown-linux-musl/bin/rad /home/amnesia/.local/bin/rad 2>/dev/null
    rad auth --alias "$RAD_ALIAS"
    if [ $? -eq 0 ]; then
        cp ~/.radicle/keys/radicle "$VAULT/radicle-keys/"
        cp ~/.radicle/keys/radicle.pub "$VAULT/radicle-keys/"
        echo "  Radicle keys saved to vault."
    else
        echo "  WARNING: rad auth failed. Run 'rad auth --alias <name>' manually later."
    fi
else
    echo "  Skipped. Run 'rad auth --alias <name>' manually later."
fi

echo ""
echo "[3/5] Tor onion service..."
echo "  A new .onion address will be generated."
echo "  This requires your Tails admin password."
echo ""
read -p "  Set up Tor onion service now? [y/N] " TOR_CONFIRM
if [ "$TOR_CONFIRM" = "y" ] || [ "$TOR_CONFIRM" = "Y" ]; then
    sudo bash /home/amnesia/Persistent/scripts/setup-tor-onion-service.sh
    if [ $? -eq 0 ]; then
        # Copy new keys to vault
        if [ -f /var/lib/tor/radicle/hs_ed25519_secret_key ]; then
            sudo cat /var/lib/tor/radicle/hs_ed25519_secret_key | tee "$VAULT/tor-onion/hs_ed25519_secret_key" > /dev/null
            sudo cat /var/lib/tor/radicle/hs_ed25519_public_key | tee "$VAULT/tor-onion/hs_ed25519_public_key" > /dev/null
            echo "  Tor onion keys saved to vault."
        fi
    else
        echo "  WARNING: Tor setup failed. Run setup script manually later."
    fi
else
    echo "  Skipped. Run 'bash ~/Persistent/scripts/setup-tor-onion-service.sh' manually later."
fi

echo ""
echo "[4/5] API keys..."
echo ""
read -p "  OpenCode/Nano-GPT API key (paste or press Enter to skip): " API_KEY
if [ -n "$API_KEY" ]; then
    echo "{\"nano-gpt\":{\"key\":\"$API_KEY\"}}" > "$VAULT/opencode-auth/auth.json"
    chmod 600 "$VAULT/opencode-auth/auth.json"
    echo "  API key saved to vault."
else
    echo "  Skipped. Add your key to ~/Persistent/vault/opencode-auth/auth.json later."
fi

echo ""
echo "[5/5] Feather wallet..."
echo "  To import a wallet, open Feather after setup and use the"
echo "  import wizard. Wallet files will be stored in the vault."
echo ""

# --- Restore tools from Persistent ---
echo "============================================"
echo "  Restoring tools from Persistent..."
echo "============================================"
echo ""

bash /home/amnesia/Persistent/opencode/restore-opencode.sh
bash /home/amnesia/Persistent/feather_data/restore-feather.sh
bash /home/amnesia/Persistent/radicle-1.8.0-x86_64-unknown-linux-musl/restore-radicle.sh

echo ""
echo "============================================"
echo "  Setup complete!"
echo "============================================"
echo ""
echo "  Your secrets are encrypted in the vault."
echo "  Next boot: .bashrc will prompt for vault passphrase."
echo ""
echo "  To seed the localchimera repo:"
echo "    rad seed rad:z27dFkN28LQAsSsG3DVHcfBqYAArQ"
echo ""
echo "  To open Feather wallet:"
echo "    /home/amnesia/Persistent/feather-2.8.1-a.AppImage"
echo ""
