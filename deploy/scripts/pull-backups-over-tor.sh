#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# deploy/scripts/pull-backups-over-tor.sh — operator-workstation timer target.
#
# Pulls the box's age-encrypted backup archives to a local off-box copy,
# STRICTLY over Tor. This is the off-box half of the backup story: the box
# produces daily encrypted snapshots; this keeps a copy on the workstation so a
# lost box does not take the only copy with it.
#
# Opsec posture (deliberate):
#   - Tor-only, no clearnet fallback. The host is an ssh-config ALIAS (default
#     `localchimera-server`) whose ProxyCommand routes through the local Tor SOCKS
#     proxy. No host/IP/.onion is hardcoded here — it lives only in ~/.ssh/config.
#   - Hard Tor gate: if the SOCKS proxy is not reachable, SKIP cleanly (exit 0)
#     rather than attempt any connection. A down proxy must never cause a direct
#     (deanonymising) connection to the box.
#   - Ciphertext only. The age private key never leaves the workstation and is
#     never touched here; we move only *.tar.age blobs. Decrypt with
#     deploy/scripts/backup-restore.sh when actually recovering.
#
# Env (all optional):
#   LOCALCHIMERA_HOST          ssh alias (default: localchimera-server)
#   LOCALCHIMERA_BACKUP_USER   remote user (default: root — the archives are root-only)
#   LOCALCHIMERA_BACKUP_REMOTE remote dir  (default: /var/lib/localchimera/backups/)
#   LOCALCHIMERA_BACKUP_LOCAL  local dir   (default: $HOME/localchimera-backups)
#   TOR_SOCKS             host:port   (default: 127.0.0.1:9050)

set -euo pipefail

HOST="${LOCALCHIMERA_HOST:-localchimera-server}"
RUSER="${LOCALCHIMERA_BACKUP_USER:-root}"
REMOTE="${LOCALCHIMERA_BACKUP_REMOTE:-/var/lib/localchimera/backups/}"
LOCAL="${LOCALCHIMERA_BACKUP_LOCAL:-$HOME/localchimera-backups}"
SOCKS="${TOR_SOCKS:-127.0.0.1:9050}"

# --- Tor gate: proceed only if the SOCKS proxy is up. No Tor → no pull. -------
socks_host="${SOCKS%%:*}"; socks_port="${SOCKS##*:}"
if ! (exec 3<>"/dev/tcp/${socks_host}/${socks_port}") 2>/dev/null; then
    echo "tor-pull: Tor SOCKS ${SOCKS} unreachable — skipping (no clearnet fallback)"
    exit 0
fi
exec 3>&- 2>/dev/null || true

mkdir -p "$LOCAL"; chmod 700 "$LOCAL"

echo "tor-pull: ${RUSER}@${HOST}:${REMOTE} → ${LOCAL}  (ssh alias, Tor-routed)"
# The alias supplies the ProxyCommand; BatchMode keeps it non-interactive and
# key-only (never prompts, never falls through to something weaker).
rsync -a --partial \
    -e "ssh -o BatchMode=yes -o ConnectTimeout=60" \
    "${RUSER}@${HOST}:${REMOTE}" "${LOCAL}/"

echo "tor-pull: done — $(ls "${LOCAL}"/state-*.tar.age 2>/dev/null | wc -l) archive(s) held off-box"
