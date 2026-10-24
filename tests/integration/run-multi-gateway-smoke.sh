#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/integration/run-multi-gateway-smoke.sh
#
# Two-gateway subprocess smoke test. Spawns two localchimera gateways in
# disjoint state dirs on disjoint ports (gateway-harness.sh), waits for
# each to write its gateway-sref.txt, then runs the OCapN driver to verify
# both are reachable + enlivenable from a third process.
#
# Exit 0 = both gateways booted + cross-process enliven works.
# Exit 1 = anything else; subprocesses are killed on EXIT.
#
# Why subprocess (not in-vat): in-vat tests already cover the protocol
# (test-federation-ocapn.scm uses ^fake-network), but they don't catch
# bugs that only show up when the gateway boots its full Goblins stack
# under real `make-forkexec-constructor` semantics — missing -L paths,
# environment-variable assumptions, sturdyref-file write races, etc.
# Those are the deploy-shape bugs this test guards against.
#
# Synthetic backend only: no KERIA, no libsodium, no vault key. For
# real cross-gateway IPEX delivery you need a different harness (each
# gateway gets its own KERIA agent, the operator-only path).
#
# LOCALCHIMERA_SCOPES_DURABLE=0: no on-disk scope restore, faster boot; LOCALCHIMERA_PEERS
# and LOCALCHIMERA_UC_AID unset: each gateway stands alone and is its own UC.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source tests/integration/gateway-harness.sh
gw_setup

echo "=== multi-gateway smoke ==="
echo "  TMPA=$TMPA port=$PORT_A"
echo "  TMPB=$TMPB port=$PORT_B"
gw_spawn "A" "$TMPA" "$PORT_A" LOCALCHIMERA_SCOPES_DURABLE=0
gw_spawn "B" "$TMPB" "$PORT_B" LOCALCHIMERA_SCOPES_DURABLE=0
gw_wait_for "A" "$TMPA/gateway-sref.txt" 45
gw_wait_for "B" "$TMPB/gateway-sref.txt" 45
SREF_A=$(head -n 1 "$TMPA/gateway-sref.txt")
SREF_B=$(head -n 1 "$TMPB/gateway-sref.txt")

echo
echo "=== running driver ==="
if guile --no-auto-compile -L module -L . \
         -s tests/integration/test-multi-gateway-driver.scm \
         "$SREF_A" "$SREF_B"; then
    echo
    echo "=== PASS ==="
    exit 0
else
    echo
    echo "=== FAIL — last gateway logs ==="
    echo "--- gateway A ---"; tail -30 "$LOG_A"
    echo "--- gateway B ---"; tail -30 "$LOG_B"
    exit 1
fi
