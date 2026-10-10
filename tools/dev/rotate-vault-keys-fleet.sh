#!/usr/bin/env bash
# tools/dev/rotate-vault-keys-fleet.sh — orchestrate vault-key rotation
#                                    across a fleet of playnet gateways
#
# Wraps the existing per-host tools/dev/rotate-vault-keys.scm: copies the
# new key out, runs the tool over torsocks ssh, tracks per-host result.
# Bails on first failure so the operator can investigate before
# half-rotated hosts cause issues.
#
# Per the operator-memory constraint: all SSH to project infra goes
# through torsocks. The OLD + NEW vault keys MUST be supplied
# out-of-band (env vars on this invocation) — they never go over
# unencrypted channels.
#
# Usage:
#   PLAYNET_VAULT_KEY_OLD=<64hex>    \
#   PLAYNET_VAULT_KEY_NEW=<64hex>    \
#     ./tools/dev/rotate-vault-keys-fleet.sh hosts.txt
#
# hosts.txt: one entry per line, in `user@host:/path/to/playnet-repo` form.
# Lines beginning with # are comments.

set -uo pipefail

die() { printf '%s\n' "$*" >&2; exit 1; }

if [ "$#" -ne 1 ]; then
  die "usage: $0 hosts.txt"
fi
HOSTS_FILE="$1"
[ -r "$HOSTS_FILE" ] || die "can't read $HOSTS_FILE"

OLD="${PLAYNET_VAULT_KEY_OLD:-}"
NEW="${PLAYNET_VAULT_KEY_NEW:-}"
[ "${#OLD}" -eq 64 ] || die "PLAYNET_VAULT_KEY_OLD must be 64 hex chars"
[ "${#NEW}" -eq 64 ] || die "PLAYNET_VAULT_KEY_NEW must be 64 hex chars"
[ "$OLD" != "$NEW" ] || die "OLD and NEW are identical — no-op"

ROTATED=()
FAILED=()

while IFS= read -r line; do
  # Skip blank lines + comments
  case "$line" in ''|\#*) continue ;; esac

  host="${line%%:*}"        # before the colon: user@hostname
  remote_path="${line#*:}"  # after: playnet repo path on remote

  printf '\n── rotating on %s (%s) ──\n' "$host" "$remote_path"

  if torsocks ssh -o ConnectTimeout=10 \
                  -o BatchMode=yes \
                  "$host" \
       "cd '$remote_path' && \
        PLAYNET_VAULT_KEY_OLD='$OLD' \
        PLAYNET_VAULT_KEY_NEW='$NEW' \
        guile --no-auto-compile -L module tools/dev/rotate-vault-keys.scm"
  then
    printf '  ✓ %s rotated\n' "$host"
    ROTATED+=("$host")
  else
    printf '  ✗ %s FAILED\n' "$host"
    FAILED+=("$host")
    # Stop on first failure: split-brain is worse than partial rotation
    # the operator knows about. The rotate-vault-keys.scm tool itself is
    # idempotent (re-running with same NEW after partial success skips
    # already-rotated vaults), so resume after fix is safe.
    break
  fi
done < "$HOSTS_FILE"

printf '\n── summary ──\n'
printf 'Rotated (%d): %s\n' "${#ROTATED[@]}" "${ROTATED[*]:-<none>}"
printf 'Failed  (%d): %s\n' "${#FAILED[@]}"  "${FAILED[*]:-<none>}"

if [ "${#FAILED[@]}" -gt 0 ]; then
  cat <<EOF

Failure on $FAILED. Already-rotated hosts (${#ROTATED[@]}) are on NEW;
the failed host is still on OLD. To recover:

  1. Investigate the failure (check /var/log/syslog on the failed host
     or re-run with -v ssh args)
  2. Fix the underlying issue (network, permissions, free space)
  3. Re-run this script with the same hosts.txt. rotate-vault-keys.scm
     is idempotent: already-rotated hosts no-op, the failed host
     completes.

The fleet is in a SPLIT state until then. New scope spawns + grants
still work on each host using its current key; cross-host operations
(scope handoffs) need both endpoints on the same key.
EOF
  exit 1
fi

cat <<EOF

All ${#ROTATED[@]} host(s) rotated successfully.

Next steps:
  1. Update PLAYNET_VAULT_KEY in deploy/secrets.scm or your operator
     secret store to the NEW value.
  2. Securely destroy the OLD key (you no longer need it).
  3. Note: each host's bran.vault files are now sealed under NEW.
     Restart playnet-gateway on each host to verify decryption.
EOF
