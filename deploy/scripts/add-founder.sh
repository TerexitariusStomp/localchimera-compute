#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# add-founder.sh — make an AID a First-Person founder (a bootstrap governor)
# on the live gateway, then restart so the gate activates.
#
#   bash deploy/scripts/add-founder.sh <AID>
#
# The AID is normally someone's DIAL identity: they sign up on the dial (the
# key is minted in their browser and never leaves it) and hand you only the
# AID — you never touch their key. For a throwaway/test founder you can mint
# one with `make founder` and pass the AID it prints.
#
# Founders become verified persons AND the bootstrap governors: they can
# verify newcomers (fan-out-capped, like any sponsor). The first founder PHC
# flips the gate from fail-open to enforcing. Adding a founder gates every
# remaining provisional user until they are verified — that is the point.
#
# Tor-only: the one remote touch goes through torsocks.
set -euo pipefail

AID="${1:?usage: add-founder.sh <AID>}"
BOX="${LOCALCHIMERA_BOX:?set LOCALCHIMERA_BOX=root@<host-or-onion> (not hardcoded — opsec)}"
FOUNDERS_FILE="${LOCALCHIMERA_DATA_DIR:-/var/lib/localchimera}/founders.txt"

# KERI AID sanity: a 44-char CESR prefix in base64url. Catches typos /
# truncation before we write it to the gateway.
if ! printf '%s' "$AID" | grep -qE '^[A-Za-z][A-Za-z0-9_-]{43}$'; then
    echo "[add-founder] ERROR: '$AID' is not a 44-char KERI AID (base64url)."
    echo "             Copy it from the dial (click your name) or from 'make founder'."
    exit 1
fi

echo "[add-founder] adding founder $AID on $BOX"
torsocks ssh "$BOX" "
  set -e
  touch '$FOUNDERS_FILE'
  if grep -qxF '$AID' '$FOUNDERS_FILE'; then
    echo '[add-founder] already a founder — restarting to ensure it is seeded'
  else
    printf '%s\n' '$AID' >> '$FOUNDERS_FILE'
    chmod 644 '$FOUNDERS_FILE'
    echo '[add-founder] appended. founders.txt now:'
    sed 's/^/  /' '$FOUNDERS_FILE'
  fi
  echo '[add-founder] restarting localchimera-gateway…'
  herd restart localchimera-gateway >/dev/null 2>&1
  sleep 32
  if (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q ':9090'; then
    echo '[add-founder] gateway is up (OCapN :9090).'
  else
    echo '[add-founder] WARN: :9090 not listening — check /var/log/localchimera/gateway.log'
  fi
  if tail -200 /var/log/localchimera/gateway.log | grep -aq 'seeded founder PHC: $AID'; then
    echo '[add-founder] ✓ founder PHC seeded — First-Person is enforcing.'
  else
    echo '[add-founder] note: no fresh seed line (already held a live PHC, or check the log).'
  fi
"
echo "[add-founder] done — log in on the dial with this founder's passcode to verify newcomers."
