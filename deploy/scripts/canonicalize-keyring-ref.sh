#!/usr/bin/env bash
# canonicalize-keyring-ref.sh — make the operator's keyring branch fetchable
# as a plain top-level ref, reproducibly.
#
# `guix pull`/`guix time-machine` need a plain `refs/heads/keyring` on the
# playnet channel to authenticate at all (it carries the operator's pubkey
# as a .key file). Radicle only auto-materialises a plain top-level ref for
# the repo's CONFIGURED DEFAULT BRANCH (main here) — every other branch,
# keyring included, exists only under
# refs/namespaces/<peer>/refs/heads/keyring, invisible to a tool that walks
# the storage expecting an ordinary flat git layout. Checked directly: no
# `rad` command designates additional canonical branches — the repo
# identity's xyz.radicle.project has exactly one such field, defaultBranch.
#
# The fix is one `git update-ref`, run directly against the bare storage.
# Confirmed additive and safe: it survives a real `rad sync --fetch` from a
# live peer (Radicle's own sync does not prune or contest a ref it didn't
# create), and it does not touch, rename, or delete anything.
#
# This is a MANUAL, one-time fix (deploy/channels.scm's own %playnet-git-
# mirror-locations comment carries the historical record for why it exists).
# This script exists so redoing it — after a storage rebuild, disaster
# recovery, or a fresh box — is one command instead of re-deriving the whole
# investigation from scratch.
#
# Usage (on the box, as a user that can sudo to playnet):
#   sudo bash deploy/scripts/canonicalize-keyring-ref.sh
#
# Idempotent: if the ref already points at the right commit, does nothing.
set -euo pipefail

RID="${PLAYNET_RID_BARE:-z27dFkN28LQAsSsG3DVHcfBqYAArQ}"
STORAGE="${PLAYNET_RADICLE_STORAGE:-/var/lib/playnet/radicle/.radicle/storage}"
REPO="$STORAGE/$RID"
STORAGE_USER="${PLAYNET_STORAGE_USER:-playnet}"

[ -d "$REPO" ] || { echo "[keyring] no repo storage at $REPO — nothing to do"; exit 0; }

# The source of truth is whatever the delegate that owns the canonical
# `main` also has under its own namespaced `keyring` — the SAME peer,
# so this is "give this peer's own other branch the same treatment its
# default branch already gets automatically", not introducing a new
# identity into the trust picture.
main_owner=$(sudo -u "$STORAGE_USER" git -C "$REPO" for-each-ref \
  --format='%(refname)' 'refs/namespaces/*/refs/heads/main' \
  | head -1 | sed -E 's#refs/namespaces/([^/]+)/refs/heads/main#\1#')

if [ -z "$main_owner" ]; then
  echo "[keyring] could not identify the delegate owning refs/heads/main — aborting" >&2
  exit 1
fi

target_ref="refs/namespaces/$main_owner/refs/heads/keyring"
target_hash=$(sudo -u "$STORAGE_USER" git -C "$REPO" rev-parse "$target_ref" 2>/dev/null || true)

if [ -z "$target_hash" ]; then
  echo "[keyring] delegate $main_owner has no keyring branch (checked $target_ref) — nothing to canonicalize" >&2
  echo "[keyring] this is expected if the operator's pubkey has never been pushed as a keyring branch from this identity" >&2
  exit 1
fi

current_hash=$(sudo -u "$STORAGE_USER" git -C "$REPO" rev-parse refs/heads/keyring 2>/dev/null || true)

if [ "$current_hash" = "$target_hash" ]; then
  echo "[keyring] refs/heads/keyring already at $target_hash — nothing to do"
  exit 0
fi

echo "[keyring] setting refs/heads/keyring -> $target_hash (from $target_ref, delegate $main_owner)"
sudo -u "$STORAGE_USER" git -C "$REPO" update-ref refs/heads/keyring "$target_hash"
echo "[keyring] done — verify with: git -C $REPO for-each-ref refs/heads"
