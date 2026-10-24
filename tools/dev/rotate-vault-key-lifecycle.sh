#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tools/dev/rotate-vault-key-lifecycle.sh — end-to-end LOCALCHIMERA_VAULT_KEY rotation
#
# Glues together the three pieces that have to move together:
#   1. tools/dev/rotate-vault-keys.scm   — re-encrypts every scope's bran.vault
#   2. deploy/secrets.scm{,.age}     — the durable source of truth
#   3. /run/secrets/localchimera-vault-key — refreshed by activation on reconfigure
#
# What it does, in order:
#   1. Reads the CURRENT vault key (env LOCALCHIMERA_VAULT_KEY_OLD, or pulls
#      from a server via torsocks ssh if --from-server <host> is given).
#   2. Generates a fresh 32-byte hex via openssl.
#   3. Runs rotate-vault-keys.scm against the local state dir (or remote).
#   4. Decrypts deploy/secrets.scm.age, swaps the LOCALCHIMERA_VAULT_KEY line,
#      re-encrypts via secrets-encrypt.sh (which shreds the plaintext).
#   5. Prints the NEW key for the operator to stash.
#   6. Tells you what to do next (commit + push + reconfigure + restart).
#
# Usage (local rotation, single host):
#   LOCALCHIMERA_VAULT_KEY_OLD=<64hex>                   \
#   LOCALCHIMERA_STATE_DIR=/var/lib/localchimera/.local/state/localchimera \
#     ./tools/dev/rotate-vault-key-lifecycle.sh
#
# Usage (remote rotation):
#   LOCALCHIMERA_VAULT_KEY_OLD=<64hex>                   \
#     ./tools/dev/rotate-vault-key-lifecycle.sh --remote root@HOST_IP
#
# Why a wrapper script and not a Make target: the deploy step (commit +
# push + reconfigure) is human-in-the-loop by design — the operator
# decides when to roll forward.

set -euo pipefail

die() { printf 'rotate-vault-key: %s\n' "$*" >&2; exit 1; }

# ── arg parse ──────────────────────────────────────────────────────────────
REMOTE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --remote) REMOTE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

# ── 1. resolve OLD ─────────────────────────────────────────────────────────
OLD="${LOCALCHIMERA_VAULT_KEY_OLD:-}"
[ "${#OLD}" -eq 64 ] || die "LOCALCHIMERA_VAULT_KEY_OLD must be 64 hex chars (got ${#OLD})"

# ── 2. generate NEW ────────────────────────────────────────────────────────
command -v openssl >/dev/null 2>&1 || die "openssl not found"
NEW=$(openssl rand -hex 32)
[ "${#NEW}" -eq 64 ] || die "openssl rand returned wrong length: ${#NEW}"
[ "$OLD" != "$NEW" ] || die "OLD == NEW (cosmic accident); re-run"

# Stage NEW to a 0600 temp so the rest of the script can pass it without
# echoing it everywhere.
NEW_FILE=$(mktemp -t localchimera-vault-new.XXXXXX)
chmod 600 "$NEW_FILE"
printf '%s\n' "$NEW" > "$NEW_FILE"
trap 'shred -u "$NEW_FILE" 2>/dev/null || rm -f "$NEW_FILE"' EXIT

# ── 3. re-encrypt every scope's bran.vault ─────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

if [ -n "$REMOTE" ]; then
  printf '── re-encrypting scopes on %s (over torsocks ssh) ──\n' "$REMOTE"
  # We assume the remote already has a checkout of the repo at the
  # standard path; if not, the operator runs the per-host script directly.
  REMOTE_REPO="/var/lib/localchimera/radicle/checkout"
  torsocks ssh -o ConnectTimeout=30 -o BatchMode=yes "$REMOTE" \
    "cd '$REMOTE_REPO' && \
     LOCALCHIMERA_STATE_DIR=/var/lib/localchimera/.local/state/localchimera \
     LOCALCHIMERA_VAULT_KEY_OLD='$OLD' \
     LOCALCHIMERA_VAULT_KEY_NEW='$NEW' \
     guile --no-auto-compile -L module tools/dev/rotate-vault-keys.scm"
else
  : "${LOCALCHIMERA_STATE_DIR:?set LOCALCHIMERA_STATE_DIR or use --remote <host>}"
  printf '── re-encrypting scopes under %s ──\n' "$LOCALCHIMERA_STATE_DIR"
  cd "$REPO_DIR"
  LOCALCHIMERA_VAULT_KEY_OLD="$OLD" \
  LOCALCHIMERA_VAULT_KEY_NEW="$NEW" \
    guile --no-auto-compile -L module tools/dev/rotate-vault-keys.scm
fi

# ── 4. swap key in deploy/secrets.scm{,.age} ───────────────────────────────
SECRETS="$REPO_DIR/deploy/secrets.scm"
SECRETS_AGE="$REPO_DIR/deploy/secrets.scm.age"
DECRYPT_SH="$REPO_DIR/deploy/scripts/secrets-decrypt.sh"
ENCRYPT_SH="$REPO_DIR/deploy/scripts/secrets-encrypt.sh"

if [ ! -f "$SECRETS_AGE" ]; then
  die "no $SECRETS_AGE found — can't rotate operator secret store"
fi

printf '── updating deploy/secrets.scm.age ──\n'

# Decrypt (writes secrets.scm) — needs deploy/.age-key.txt locally.
"$DECRYPT_SH" >/dev/null

if ! grep -q '^[[:space:]]*(setenv "LOCALCHIMERA_VAULT_KEY"' "$SECRETS"; then
  die "no (setenv \"LOCALCHIMERA_VAULT_KEY\" ...) line in $SECRETS — refusing to add silently"
fi

# Replace the value in-place. Pin the line shape so we don't accidentally
# match a comment or doc snippet.
sed -i.bak -E \
  's|^([[:space:]]*\(setenv "LOCALCHIMERA_VAULT_KEY" )"[0-9a-fA-F]{64}"|\1"'"$NEW"'"|' \
  "$SECRETS"
rm -f "$SECRETS.bak"

# Re-encrypt + shred plaintext.
"$ENCRYPT_SH" >/dev/null

# ── 5. show the NEW key ────────────────────────────────────────────────────
printf '\n── ROTATION COMPLETE ──\n\n'
printf 'NEW LOCALCHIMERA_VAULT_KEY (stash now — losing this = losing future vaults):\n\n'
printf '  %s\n\n' "$NEW"

# ── 6. next-steps reminder ─────────────────────────────────────────────────
cat <<EOF
Now deploy the new secret to production so /run/secrets/localchimera-vault-key
gets rewritten by activation:

  git add deploy/secrets.scm.age
  git commit -m "secrets: rotate LOCALCHIMERA_VAULT_KEY"
  git push home main          # USB → home clone
  cd ~/Programs/localchimera && git push rad main

On the server (via torsocks ssh):
  herd restart localchimera-gateway   # picks up the new env at next start

If you used --remote, the per-scope bran.vault files are ALREADY re-
encrypted on that host; the deploy is just to make the new key
survive a reboot via /run/secrets.

OLD key is now useless. Securely destroy any operator-side stashes
of it (KeePass entry, paper note, etc.).
EOF
