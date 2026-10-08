#!/bin/bash
# mount-vault.sh
# Mount the encrypted gocryptfs vault at ~/Persistent/vault
# Prompts for password on the terminal (respects keyboard layout).

set -uo pipefail

CIPHER="/home/amnesia/Persistent/vault-cipher"
MOUNT="/home/amnesia/Persistent/vault"

if mountpoint -q "$MOUNT" 2>/dev/null; then
    echo "[vault] Already mounted at $MOUNT"
    exit 0
fi

if [ ! -f "$CIPHER/gocryptfs.conf" ]; then
    echo "[vault] ERROR: Vault not initialized. Run gocryptfs -init $CIPHER first."
    exit 1
fi

echo "[vault] Enter vault passphrase to mount encrypted storage:"
gocryptfs "$CIPHER" "$MOUNT"
if [ $? -eq 0 ]; then
    echo "[vault] Vault mounted at $MOUNT"
else
    echo "[vault] ERROR: Failed to mount vault."
    exit 1
fi
