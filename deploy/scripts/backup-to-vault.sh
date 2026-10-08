#!/usr/bin/env bash
# backup-to-vault.sh — refresh tier 3 (KeePass vault) from tier 2 cleartext.
#
# Adds (or updates) entries in ~/.playnet-secrets/playnet-vault.kdbx:
#
#   /Playnet/age-key      — attachment: age-key.txt
#   /Playnet/secrets      — attachment: secrets.scm
#
# Run AFTER `make backup-laptop` has refreshed tier 2 (~/.playnet-secrets/).
# You'll be prompted ONCE for the vault password.

set -euo pipefail

VAULT="${PLAYNET_VAULT:-$HOME/.playnet-secrets/playnet-vault.kdbx}"
AGE_KEY="$HOME/.playnet-secrets/playnet.age-key.txt"
SECRETS="$HOME/.playnet-secrets/playnet.secrets.scm"

if [ ! -f "$VAULT" ]; then
    echo "error: vault not found at $VAULT" >&2
    exit 1
fi
if [ ! -f "$AGE_KEY" ] || [ ! -f "$SECRETS" ]; then
    echo "error: tier-2 files missing — run 'make backup-laptop' first" >&2
    exit 1
fi
if ! command -v keepassxc-cli >/dev/null 2>&1; then
    echo "error: keepassxc-cli not in PATH. guix shell -m deploy/manifests/dev-manifest.scm" >&2
    exit 1
fi

# Single password prompt; reuse across subcommands by piping into stdin
# of each. Stored only in shell-local var, cleared on exit.
PW=""
cleanup() { PW=""; }
trap cleanup EXIT INT TERM

read -rsp "Vault password: " PW; echo

# Helper: run a keepassxc-cli command with the vault password piped
# on stdin. `--no-password` would tell keepassxc-cli to treat the DB
# as keyfile-only, which is wrong — we want it to consume our piped
# password. `-g` generates a random per-entry password we ignore (we
# only care about the attachment).
#
# We tolerate non-zero rc for `mkdir` (group may already exist) and
# `add` (entry may already exist); attachment-import then refreshes
# the actual content idempotently.
kp() { printf '%s' "$PW" | keepassxc-cli "$@"; }

kp mkdir "$VAULT" /Playnet                                                       || true
kp add   "$VAULT" /Playnet/age-key -g \
   --notes "age private key — decrypts deploy/secrets.scm.age (operator-only)"   || true
kp add   "$VAULT" /Playnet/secrets -g \
   --notes "decrypted secrets.scm — env vars consumed by activation gexp"        || true

# Attachment-import IS idempotent with -f (force overwrite). A failure
# here is a real error — the entry must already exist before this runs.
kp attachment-import -f "$VAULT" /Playnet/age-key  age-key.txt   "$AGE_KEY"
kp attachment-import -f "$VAULT" /Playnet/secrets  secrets.scm   "$SECRETS"

echo ""
echo "Vault updated. Verify with:"
echo "  keepassxc-cli ls -R '$VAULT' /Playnet"
