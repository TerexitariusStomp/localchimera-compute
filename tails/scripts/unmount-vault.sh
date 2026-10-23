#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# unmount-vault.sh
# Unmount the encrypted gocryptfs vault.

set -uo pipefail

MOUNT="/home/amnesia/Persistent/vault"

if ! mountpoint -q "$MOUNT" 2>/dev/null; then
    echo "[vault] Not mounted."
    exit 0
fi

fusermount -u "$MOUNT"
if [ $? -eq 0 ]; then
    echo "[vault] Vault unmounted."
else
    echo "[vault] WARNING: Could not unmount cleanly (files may be in use)."
    exit 1
fi
