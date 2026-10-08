#!/bin/sh
# tests/ux/ux-run.sh — serve browser/ (with a /ws → gateway proxy) and run a
# Playwright browser e2e test against a LIVE gateway.
#
#   guix shell -m deploy/manifests/browser-test-manifest.scm -- \
#     sh tests/ux/ux-run.sh tests/<feature>-ux.mjs
#
# Expects a gateway already running, its sref in GATEWAY_SREF_FILE (default
# data/gateway-sref.txt) and its OCapN port in GATEWAY_PORT (default 9090).
# Serves browser/ on UX_TEST_PORT (default 8089).
set -e
TEST="${1:?usage: sh tests/ux/ux-run.sh tests/<feature>-ux.mjs}"
PORT="${UX_TEST_PORT:-8089}"
GATEWAY_PORT="${GATEWAY_PORT:-9090}"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BROWSER_DIR="$ROOT_DIR/browser"
SREF_FILE="${GATEWAY_SREF_FILE:-$ROOT_DIR/data/gateway-sref.txt}"

[ -f "$BROWSER_DIR/repl.wasm" ] || { echo "ERROR: browser/repl.wasm missing — run 'make'"; exit 1; }
[ -f "$SREF_FILE" ] || { echo "ERROR: no gateway sref at $SREF_FILE — start a gateway first"; exit 1; }
if   [ -f "$TEST" ];            then TESTPATH="$TEST"
elif [ -f "$ROOT_DIR/$TEST" ]; then TESTPATH="$ROOT_DIR/$TEST"
else echo "ERROR: test file not found: $TEST"; exit 1; fi

# Playwright's node_modules + chromium from the guix profile.
if [ -n "${GUIX_ENVIRONMENT-}" ] && [ -d "$GUIX_ENVIRONMENT/lib/node_modules" ] && [ ! -e "$ROOT_DIR/node_modules" ]; then
  ln -s "$GUIX_ENVIRONMENT/lib/node_modules" "$ROOT_DIR/node_modules"; CLEAN_LINK="$ROOT_DIR/node_modules"
fi
CHROMIUM_BIN="$(command -v chromium || true)"
[ -n "$CHROMIUM_BIN" ] && export CHROMIUM_PATH="$CHROMIUM_BIN"

# Node static server + /ws → gateway proxy + /entry-points.json (mirrors nginx).
GATEWAY_SREF="$(cat "$SREF_FILE")" \
  node "$ROOT_DIR/tests/ux/_serve-wsproxy.mjs" "$BROWSER_DIR" "$PORT" "$GATEWAY_PORT" &
SERVER_PID=$!
SERVER2_PID=""
trap 'kill $SERVER_PID $SERVER2_PID 2>/dev/null; [ -n "$CLEAN_LINK" ] && rm -f "$CLEAN_LINK"' EXIT INT TERM
# A second commune (ux-full.sh SECOND_GATEWAY=1): the same static tree behind
# its own /ws proxy + entry-points, so a page at UX_BASE2 reaches the OTHER
# gateway. Origin-separated by port, so the two pages never share storage.
if [ -n "${GATEWAY2_PORT-}" ] && [ -f "${GATEWAY2_SREF_FILE-}" ]; then
  PORT2="${UX_TEST_PORT2:-8090}"
  GATEWAY_SREF="$(cat "$GATEWAY2_SREF_FILE")" \
    node "$ROOT_DIR/tests/ux/_serve-wsproxy.mjs" "$BROWSER_DIR" "$PORT2" "$GATEWAY2_PORT" &
  SERVER2_PID=$!
  export UX_BASE2="http://localhost:$PORT2"
  echo "  second commune: serving browser/ on :$PORT2, /ws → 127.0.0.1:$GATEWAY2_PORT"
fi
sleep 1

# Stripped sref (no ?url= suffix), url-encoded, for the ?gatewaySref= param.
ENC="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read().strip().split("?")[0], safe=""))' < "$SREF_FILE")"

echo "== browser e2e: $TEST =="
echo "  serving browser/ on :$PORT, /ws → 127.0.0.1:$GATEWAY_PORT"
node "$TESTPATH" "http://localhost:$PORT" "$ENC"
