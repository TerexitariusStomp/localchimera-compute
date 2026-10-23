#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail

# secrets-decrypt.sh — decrypt deploy/secrets.scm.age for deploy
#
# Auto-detects YubiKey vs file key:
#   - If deploy/.age-yubikey-identity.txt exists → YubiKey (touch required)
#   - If deploy/.age-key.txt exists → file key
#
# Usage:
#   ./deploy/scripts/secrets-decrypt.sh
#   guix deploy deploy/machines.scm
#   shred -u deploy/secrets.scm
#
# Or as a one-liner:
#   ./deploy/scripts/secrets-decrypt.sh && guix deploy deploy/machines.scm; shred -u deploy/secrets.scm

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
SECRETS="$DEPLOY_DIR/secrets.scm"
ENCRYPTED="$DEPLOY_DIR/secrets.scm.age"
YUBIKEY_IDENTITY="$DEPLOY_DIR/.age-yubikey-identity.txt"
FILE_KEY="$DEPLOY_DIR/.age-key.txt"

if ! command -v age &>/dev/null; then
    echo "error: age not found. Install with: guix install age"
    exit 1
fi

if [ ! -f "$ENCRYPTED" ]; then
    echo "error: $ENCRYPTED not found. Run secrets-encrypt.sh first."
    exit 1
fi

if [ -f "$SECRETS" ]; then
    # Refuse to overwrite a plaintext that's newer than the encrypted
    # blob — that combination almost always means the operator edited
    # secrets.scm and hasn't re-encrypted yet. Blowing it away would
    # silently lose their edits.
    if [ "$SECRETS" -nt "$ENCRYPTED" ]; then
        echo "error: $SECRETS is newer than $ENCRYPTED."
        echo "Your in-progress edits would be discarded. Either:"
        echo "  - re-encrypt first:  ./deploy/scripts/secrets-encrypt.sh"
        echo "  - or shred plaintext: shred -u $SECRETS"
        exit 1
    fi
    echo "warning: $SECRETS already exists (plaintext). Overwriting."
fi

# Determine decryption mode
if [ -f "$YUBIKEY_IDENTITY" ]; then
    echo "=== YubiKey mode — touch your key when prompted ==="
    age -d -i "$YUBIKEY_IDENTITY" "$ENCRYPTED" > "$SECRETS"
elif [ -f "$FILE_KEY" ]; then
    echo "=== File key mode ==="
    age -d -i "$FILE_KEY" "$ENCRYPTED" > "$SECRETS"
else
    echo "error: no age key found."
    echo "Need either $YUBIKEY_IDENTITY or $FILE_KEY"
    exit 1
fi

chmod 600 "$SECRETS"

echo "Decrypted → $SECRETS (mode 0600)"
echo ""
echo "IMPORTANT: shred -u $SECRETS after deploy!"
