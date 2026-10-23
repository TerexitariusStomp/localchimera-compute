#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# deploy/scripts/backup-pull.sh — operator workstation: pull the latest
# encrypted backup snapshots from the live host to a local archive.
#
# Run from your workstation (Tails/Whonix/laptop), not the server.
# Reuses the deploy SSH key (already routed through Tor).
#
# Usage:
#   PLAYNET_HOST=playnet.onion bash deploy/scripts/backup-pull.sh
#
# Defaults:
#   PLAYNET_HOST            — required (server hostname or .onion)
#   PLAYNET_BACKUP_USER     — deploy
#   PLAYNET_BACKUP_REMOTE   — /var/lib/playnet/backups/
#   PLAYNET_BACKUP_LOCAL    — $HOME/playnet-backups
#
# Encrypted blobs only — your YubiKey or age key never leaves the
# workstation. To restore, run `backup-restore.sh` against any blob in
# $PLAYNET_BACKUP_LOCAL.

set -euo pipefail

: "${PLAYNET_HOST:?Set PLAYNET_HOST=server.onion (or IP)}"
: "${PLAYNET_BACKUP_USER:=deploy}"
: "${PLAYNET_BACKUP_REMOTE:=/var/lib/playnet/backups/}"
: "${PLAYNET_BACKUP_LOCAL:=$HOME/playnet-backups}"

mkdir -p "$PLAYNET_BACKUP_LOCAL"
chmod 700 "$PLAYNET_BACKUP_LOCAL"

echo "Pulling encrypted snapshots:"
echo "  $PLAYNET_BACKUP_USER@$PLAYNET_HOST:$PLAYNET_BACKUP_REMOTE"
echo "  → $PLAYNET_BACKUP_LOCAL"
echo

rsync -av --partial --info=progress2 \
    -e "ssh -o ConnectTimeout=30" \
    "$PLAYNET_BACKUP_USER@$PLAYNET_HOST:$PLAYNET_BACKUP_REMOTE" \
    "$PLAYNET_BACKUP_LOCAL/"

echo
echo "Done. Latest snapshot:"
ls -lh "$PLAYNET_BACKUP_LOCAL/latest.tar.age" 2>/dev/null || \
    echo "  (no latest.tar.age — check rsync output)"
echo
echo "To inspect what's in the latest snapshot (no writes):"
echo "  bash deploy/scripts/backup-restore.sh $PLAYNET_BACKUP_LOCAL/latest.tar.age"
