#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail

# secrets-encrypt.sh — encrypt deploy/secrets.scm with age
#
# Supports two modes:
#   1. YubiKey (preferred): age-plugin-yubikey hardware-backed encryption
#   2. File key (fallback): age software key at deploy/.age-key.txt
#
# YubiKey setup (one-time):
#   age-plugin-yubikey --generate > deploy/.age-yubikey-identity.txt
#   # The identity file is safe to commit — it's a public reference
#   # to the YubiKey slot. Decryption requires physical key + touch.
#
# File key setup (one-time):
#   age-keygen -o deploy/.age-key.txt
#   # NEVER commit .age-key.txt (gitignored)
#
# After encryption, the plaintext secrets.scm is shredded.

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

if [ ! -f "$SECRETS" ]; then
    echo "error: $SECRETS not found."
    echo "Copy from secrets.scm.example and fill in your values first."
    exit 1
fi

# Determine encryption mode: YubiKey preferred, file key fallback
if [ -f "$YUBIKEY_IDENTITY" ]; then
    echo "=== YubiKey mode ==="
    # Extract the recipient from the identity file
    RECIPIENT=$(grep "^age1yubikey" "$YUBIKEY_IDENTITY" | head -1)
    if [ -z "$RECIPIENT" ]; then
        echo "error: no age1yubikey recipient found in $YUBIKEY_IDENTITY"
        exit 1
    fi
    echo "Encrypting with YubiKey recipient: ${RECIPIENT:0:30}..."
    echo "Touch your YubiKey when prompted."
    age -e -r "$RECIPIENT" -o "$ENCRYPTED" "$SECRETS"

elif [ -f "$FILE_KEY" ]; then
    echo "=== File key mode (consider upgrading to YubiKey) ==="
    AGE_PUB=$(age-keygen -y "$FILE_KEY")
    echo "Encrypting with file key: ${AGE_PUB:0:30}..."
    age -e -r "$AGE_PUB" -o "$ENCRYPTED" "$SECRETS"

else
    echo "error: no age key found."
    echo ""
    echo "Option 1 (recommended): YubiKey"
    echo "  guix install age-plugin-yubikey"
    echo "  age-plugin-yubikey --generate > $YUBIKEY_IDENTITY"
    echo ""
    echo "Option 2: File key"
    echo "  age-keygen -o $FILE_KEY"
    exit 1
fi

echo "Shredding plaintext $SECRETS"
shred -u "$SECRETS"

echo ""
echo "Done. Safe to commit deploy/secrets.scm.age"
echo "To decrypt: ./deploy/scripts/secrets-decrypt.sh"
