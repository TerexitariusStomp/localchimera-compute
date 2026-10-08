#!/bin/bash
# tests/ux/ux-mesh.sh — browser e2e WITH a real mesh hop: two rns-bridges
# over a local TCP link, the gateway wired to bridge B (recipient side),
# and a Playwright browser persona that announces itself, then receives
# LXMF mail injected at bridge A — the full
# browser→gateway→bridge→TCP→bridge→mailbox→browser round trip.
#
#   make test-keri-mesh-ux
#
# Needs server/rns-bridge/target/debug/rns-bridge (cargo build) and the
# rns-wasm pkg; skips politely when absent.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
BRIDGE_BIN="$ROOT/server/rns-bridge/target/debug/rns-bridge"
if [ ! -x "$BRIDGE_BIN" ] || [ ! -f "$ROOT/rns-wasm/pkg/rns_wasm.js" ]; then
  echo "SKIP: needs rns-bridge debug binary + rns-wasm pkg"
  exit 0
fi
[ -f browser/repl.wasm ] || { echo "ERROR: browser/repl.wasm missing — run 'make' first"; exit 1; }

DATA="$ROOT/.ux-mesh-data"
GW_PORT="${GATEWAY_PORT:-9099}"
OOBI_PORT="${OOBI_PORT:-8099}"
TCP_PORT=14243
SREF_FILE="$DATA/gateway-sref.txt"
GW_LOG="$DATA/gateway.log"
rm -rf "$DATA"; mkdir -p "$DATA"

pkill -9 -f "[r]ns-bridge --control-socket $DATA" 2>/dev/null

# ── two bridges over one TCP link (smoke-test topology) ────────────────
# share_instance=No: two rns nodes on one host otherwise join the same
# local shared instance and the topology stops being this TCP link.
mkdir -p "$DATA/bra" "$DATA/brb"
printf '[reticulum]\nshare_instance = No\n\n[interfaces]\n  [[srv]]\n    type = TCPServerInterface\n    enabled = Yes\n    listen_ip = 127.0.0.1\n    listen_port = %s\n' "$TCP_PORT" > "$DATA/bra/config"
printf '[reticulum]\nshare_instance = No\n\n[interfaces]\n  [[cli]]\n    type = TCPClientInterface\n    enabled = Yes\n    target_host = 127.0.0.1\n    target_port = %s\n' "$TCP_PORT" > "$DATA/brb/config"

"$BRIDGE_BIN" --control-socket "$DATA/a.sock" --socket-dir "$DATA/bra/socks" --config "$DATA/bra" > "$DATA/bra.log" 2>&1 &
BRA_PID=$!
for i in $(seq 1 50); do [ -S "$DATA/a.sock" ] && break; sleep 0.2; done
"$BRIDGE_BIN" --control-socket "$DATA/b.sock" --socket-dir "$DATA/brb/socks" --config "$DATA/brb" > "$DATA/brb.log" 2>&1 &
BRB_PID=$!
for i in $(seq 1 50); do [ -S "$DATA/b.sock" ] && break; sleep 0.2; done
sleep 2
echo "== bridges up (A: $DATA/a.sock ←TCP:$TCP_PORT→ B: $DATA/b.sock) =="

cleanup() {
  kill -- -"$GW_PGID" 2>/dev/null; pkill -P "$GW_PGID" 2>/dev/null
  [ -n "${OOBI_PGID:-}" ] && { kill -- -"$OOBI_PGID" 2>/dev/null; pkill -P "$OOBI_PGID" 2>/dev/null; }
  kill "$BRA_PID" "$BRB_PID" 2>/dev/null
}
trap cleanup EXIT INT TERM

# ── gateway wired to bridge B ──────────────────────────────────────────
echo "== starting gateway on :$GW_PORT (reticulum via bridge B) =="
setsid guix shell -L deploy/guix -m deploy/manifests/keri-test-manifest.scm -- \
  bash -c "PLAYNET_DATA_DIR='$DATA' PLAYNET_SCOPES_DURABLE=0 \
    RETICULUM_BRIDGE_SOCKET='$DATA/b.sock' \
    LTDL_LIBRARY_PATH=\"\$GUIX_ENVIRONMENT/lib\" \
    exec guile --no-auto-compile -L module -L . -L deploy/guix -s server/gateway.scm --host 127.0.0.1 --port $GW_PORT --reticulum" \
  > "$GW_LOG" 2>&1 < /dev/null &
GW_PGID=$!

for i in $(seq 1 80); do [ -f "$SREF_FILE" ] && break; sleep 3; done
[ -f "$SREF_FILE" ] || { echo "ERROR: gateway didn't register a sturdyref"; tail -8 "$GW_LOG"; exit 1; }
grep -q "mesh-mailbox + delivery stream wired" "$GW_LOG" \
  || { echo "ERROR: gateway booted without mesh wiring"; grep -i "mesh\|reticulum" "$GW_LOG" | tail -5; exit 1; }
echo "  gateway up, mesh wired"

# ── /oobi server ───────────────────────────────────────────────────────
setsid guix shell -L deploy/guix -m deploy/manifests/keri-test-manifest.scm -- \
  guile --no-auto-compile -L module -L . \
  -c "((@ (server serve-static) run-static-server) #:work-dir \"browser\" #:oobi-dir \"$DATA/oobi-host\" #:port $OOBI_PORT)" \
  > "$DATA/oobi-server.log" 2>&1 < /dev/null &
OOBI_PGID=$!
for i in $(seq 1 30); do curl -sf -o /dev/null "http://127.0.0.1:$OOBI_PORT/" && break; sleep 2; done
export OOBI_URL="http://127.0.0.1:$OOBI_PORT"
export MESH_BRIDGE_A_SOCK="$DATA/a.sock"
export MESH_DATA_DIR="$DATA"
echo "  /oobi server up"

echo "== running tests/ux/keri-mesh-ux.mjs (Playwright) =="
GATEWAY_PORT="$GW_PORT" GATEWAY_SREF_FILE="$SREF_FILE" \
  guix shell -m deploy/manifests/browser-test-manifest.scm -- sh tests/ux/ux-run.sh tests/ux/keri-mesh-ux.mjs
RC=$?
if [ "$RC" -eq 0 ]; then rm -rf "$DATA"
else echo "== logs kept in $DATA =="; grep -i "mesh\|lxmf\|DELIVERY" "$GW_LOG" | tail -8; fi
exit $RC
