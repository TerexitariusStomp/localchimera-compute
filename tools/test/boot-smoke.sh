#!/usr/bin/env bash
# tools/test/boot-smoke.sh — the gateway boots: a throwaway-state gateway reaches
# "REPL listening", or the tail of its log says why not.
#
# The suite loads modules one at a time and never runs the composition boot/ makes of
# them, so a change that breaks only the boot (a missing import in a phase module, an
# arity the boot passes) is green everywhere else. This starts the real gateway on a
# free port, with a data directory of its own, and waits for its REPL socket.
#
# Run: bash tools/test/boot-smoke.sh        (from any directory; PORT=… pins the port)
set -u
cd "$(dirname "$0")/../.."
PORT="${PORT:-}"
if [ -z "$PORT" ]; then
  for p in $(seq 18400 18999); do ss -ltn 2>/dev/null | grep -q ":$p " || { PORT=$p; break; }; done
fi
TMP=$(mktemp -d /tmp/pnb.XXXXXX)
guix shell --pure -L deploy/guix -m deploy/manifests/keri-test-manifest.scm -- \
  bash -c 'env LC_ALL=C.UTF-8 XDG_RUNTIME_DIR="$0" PLAYNET_DATA_DIR="$0" PLAYNET_SCOPES_DURABLE=0 LTDL_LIBRARY_PATH="$GUIX_ENVIRONMENT/lib" \
  bash tools/test/own-ccache.sh guile --no-auto-compile -L module -L . -s server/gateway.scm --host 127.0.0.1 --port "$1"' "$TMP" "$PORT" > "$TMP/gateway.log" 2>&1 &
PID=$!
for i in $(seq 1 150); do
  grep -q "REPL listening" "$TMP/gateway.log" 2>/dev/null && break
  kill -0 $PID 2>/dev/null || break
  sleep 1
done
ok=1
grep -q "REPL listening" "$TMP/gateway.log" && ok=0
kill $PID 2>/dev/null; sleep 1; kill -9 $PID 2>/dev/null
if [ $ok -eq 0 ]; then echo "boot-smoke: the gateway reached REPL listening"; rm -rf "$TMP"; exit 0; fi
grep -n -B30 "BOOT FAILED" "$TMP/gateway.log" | grep -v "^[0-9]*-;;;" | tail -40
tail -n 20 "$TMP/gateway.log"
echo "boot-smoke: the gateway did not reach REPL listening (log kept at $TMP/gateway.log)"
exit 1
