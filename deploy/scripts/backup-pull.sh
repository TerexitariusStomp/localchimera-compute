#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# deploy/scripts/backup-pull.sh — operator workstation: pull the latest
# encrypted backup snapshots from the live host to a local archive.
#
# Run from your workstation (Tails/Whonix/laptop), not the server.
# Reuses the deploy SSH key (already routed through Tor).
#
# Usage:
#   LOCALCHIMERA_HOST=localchimera.onion bash deploy/scripts/backup-pull.sh
#
# Defaults:
#   LOCALCHIMERA_HOST            — required (server hostname or .onion)
#   LOCALCHIMERA_BACKUP_USER     — deploy
#   LOCALCHIMERA_BACKUP_REMOTE   — /var/lib/localchimera/backups/
#   LOCALCHIMERA_BACKUP_LOCAL    — $HOME/localchimera-backups
#
# Encrypted blobs only — your YubiKey or age key never leaves the
# workstation. To restore, run `backup-restore.sh` against any blob in
# $LOCALCHIMERA_BACKUP_LOCAL.

set -euo pipefail

: "${LOCALCHIMERA_HOST:?Set LOCALCHIMERA_HOST=server.onion (or IP)}"
: "${LOCALCHIMERA_BACKUP_USER:=deploy}"
: "${LOCALCHIMERA_BACKUP_REMOTE:=/var/lib/localchimera/backups/}"
: "${LOCALCHIMERA_BACKUP_LOCAL:=$HOME/localchimera-backups}"

mkdir -p "$LOCALCHIMERA_BACKUP_LOCAL"
chmod 700 "$LOCALCHIMERA_BACKUP_LOCAL"

echo "Pulling encrypted snapshots:"
echo "  $LOCALCHIMERA_BACKUP_USER@$LOCALCHIMERA_HOST:$LOCALCHIMERA_BACKUP_REMOTE"
echo "  → $LOCALCHIMERA_BACKUP_LOCAL"
echo

rsync -av --partial --info=progress2 \
    -e "ssh -o ConnectTimeout=30" \
    "$LOCALCHIMERA_BACKUP_USER@$LOCALCHIMERA_HOST:$LOCALCHIMERA_BACKUP_REMOTE" \
    "$LOCALCHIMERA_BACKUP_LOCAL/"

echo
echo "Done. Latest snapshot:"
ls -lh "$LOCALCHIMERA_BACKUP_LOCAL/latest.tar.age" 2>/dev/null || \
    echo "  (no latest.tar.age — check rsync output)"
echo
echo "To inspect what's in the latest snapshot (no writes):"
echo "  bash deploy/scripts/backup-restore.sh $LOCALCHIMERA_BACKUP_LOCAL/latest.tar.age"
