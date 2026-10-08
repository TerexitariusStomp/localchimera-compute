#!/usr/bin/env bash
# carry-satellite.sh — carry a satellite repo's Radicle storage to the box.
#
#   bash deploy/scripts/carry-satellite.sh <name>       (names: deploy/satellites.scm)
#
# The box's seed node and the home node sit in different gossip clusters that
# do not relay (see promote.sh's canonical carry, root-caused 2026-06-28), so
# `rad seed` on the box finds no peer that has a new satellite and times out.
# This script ships the whole storage repo of the satellite — heads, identity
# COB, sigrefs — as one git bundle over the SSH we already use, materializes
# it as the box's bare storage repo, and records the seed policy so the node
# keeps it. Plain signed git, no networked pseudonym node: the same opsec
# shape as promote.sh. Idempotent: re-running fetches only what is new.
#
# Once the storage repo exists on the box, the CI hook's `satellite-pins.scm
# place` finds the pinned commit there and lands the tree; the nginx mirror
# route and the seed list themselves come from deploy/os.scm on reconfigure.
#
# Tor: same PLAYNET_BOX / PROMOTE_TORSOCKS convention as promote.sh.
set -euo pipefail

NAME="${1:?usage: carry-satellite.sh <name>}"
BOX="${PLAYNET_BOX:?set PLAYNET_BOX=<ssh alias or root@host> (not hardcoded — opsec)}"
TS="${PROMOTE_TORSOCKS-torsocks}"
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
BOX_RAD_HOME=/var/lib/playnet/radicle/.radicle

line=$(GUILE_AUTO_COMPILE=0 "$HERE/deploy/scripts/satellite-pins.scm" list | awk -F'\t' -v n="$NAME" '$1==n')
[ -n "$line" ] || { echo "[carry] no satellite named $NAME in deploy/satellites.scm"; exit 1; }
RID=$(echo "$line" | cut -f2); COMMIT=$(echo "$line" | cut -f3)
[ "$RID" != "-" ] || { echo "[carry] $NAME has no rid yet — rad init it first"; exit 1; }
BARE="${RID#rad:}"
HS="${RAD_HOME:-$HOME/.radicle}/storage/$BARE"
[ -d "$HS" ] || { echo "[carry] no home storage at $HS — is $RID initialized on this node?"; exit 1; }
git -C "$HS" cat-file -e "$COMMIT^{commit}" || { echo "[carry] pinned $COMMIT is not in $HS"; exit 1; }

BUNDLE=$(mktemp /tmp/satellite-$NAME.XXXXXX.bundle)
trap 'rm -f "$BUNDLE"' EXIT
git -C "$HS" bundle create "$BUNDLE" --all >/dev/null 2>&1
echo "[carry] $NAME $RID → $BOX ($(du -h "$BUNDLE" | cut -f1) bundle, pinned ${COMMIT:0:8})"
$TS scp -q "$BUNDLE" "$BOX:/tmp/satellite-$NAME.bundle"

$TS ssh "$BOX" "
  set -e
  S=$BOX_RAD_HOME/storage/$BARE
  chown playnet /tmp/satellite-$NAME.bundle
  [ -d \"\$S\" ] || sudo -u playnet git init -q --bare \"\$S\"
  sudo -u playnet git -C \"\$S\" fetch -q /tmp/satellite-$NAME.bundle '+refs/*:refs/*'
  rm -f /tmp/satellite-$NAME.bundle
  # A Guix channel authenticates against a plain refs/heads/keyring, and Radicle
  # materializes a plain ref only for the default branch. A satellite that is a
  # channel pushes its keyring branch as usual; here it gets the plain ref too
  # (deploy/scripts/canonicalize-keyring-ref.sh has the reasoning).
  kr=\$(sudo -u playnet git -C \"\$S\" for-each-ref --format='%(refname)' 'refs/namespaces/*/refs/heads/keyring' | head -1)
  if [ -n \"\$kr\" ]; then
    sudo -u playnet git -C \"\$S\" update-ref refs/heads/keyring \"\$(sudo -u playnet git -C \"\$S\" rev-parse \"\$kr\")\"
    echo \"[box] $NAME: refs/heads/keyring is plain, for channel authentication\"
  fi
  sudo -u playnet env RAD_HOME=$BOX_RAD_HOME rad seed $RID --scope all --no-fetch 2>&1 | tail -1 || true
  if sudo -u playnet git -C \"\$S\" cat-file -e $COMMIT^{commit}; then
    echo \"[box] $NAME storage holds pinned ${COMMIT:0:8}; refs: \$(sudo -u playnet git -C \"\$S\" for-each-ref | wc -l)\"
  else
    echo '[box] ERROR: pinned commit missing after fetch'; exit 1
  fi
  sudo -u playnet env RAD_HOME=$BOX_RAD_HOME rad ls 2>/dev/null | grep -F '$BARE' || echo '[box] note: rad ls does not list it yet (node may need a restart to index)'
"
echo "[carry] done — the next CI deploy places it; force one with: make ship"
