#!/bin/sh
# tests/ux-test.sh — Start server, run browser UX tests, teardown.
# Usage: sh tests/ux-test.sh
#
# Serves the pre-built browser/repl.wasm via npx serve (no guix needed).
# Requires: node, npx, chromium

set -e

PORT="${UX_TEST_PORT:-8088}"
BROWSER_DIR="$(cd "$(dirname "$0")/../browser" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "== Browser UX Test Runner =="
echo "Port: $PORT"
echo "Browser dir: $BROWSER_DIR"

# Check prereqs
if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: node not found" >&2
  exit 1
fi

if [ ! -f "$BROWSER_DIR/repl.wasm" ]; then
  echo "ERROR: browser/repl.wasm not found. Run 'make' first." >&2
  exit 1
fi

# Install playwright browsers on first run
if ! npx playwright install chromium --dry-run >/dev/null 2>&1; then
  echo "Installing Playwright chromium..."
  npx playwright install chromium
fi

# Start static file server
echo "Starting server on port $PORT..."
npx -y serve "$BROWSER_DIR" -l "$PORT" -s --no-clipboard 2>/dev/null &
SERVER_PID=$!

cleanup() {
  echo "Stopping server (pid $SERVER_PID)..."
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Wait for server to be ready
echo "Waiting for server..."
for i in $(seq 1 30); do
  if curl -sf "http://localhost:$PORT/" >/dev/null 2>&1; then
    echo "Server ready."
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "ERROR: Server did not start within 30s" >&2
    exit 1
  fi
  sleep 1
done

# Run the Playwright tests
echo ""
node "$SCRIPT_DIR/browser-ux.mjs" "http://localhost:$PORT"
EXIT_CODE=$?

echo ""
if [ "$EXIT_CODE" -eq 0 ]; then
  echo "All browser UX tests passed."
else
  echo "Some browser UX tests failed. Check tests/screenshots/ for details."
fi

exit $EXIT_CODE
