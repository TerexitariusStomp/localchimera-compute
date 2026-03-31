#!/bin/sh
# tests/ux-test.sh — Start server, run browser UX tests, teardown.
# Usage: sh tests/ux-test.sh
#
# Serves browser/repl.wasm via Python http.server (zero deps).
# Runs Playwright tests via node (from guix shell or PATH).
# Fully reproducible: no npm install, no npx, no node_modules.

set -e

PORT="${UX_TEST_PORT:-8088}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BROWSER_DIR="$ROOT_DIR/browser"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "== Browser UX Test Runner =="
echo "Port: $PORT"

# Check prereqs
for cmd in node python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: $cmd not found" >&2
    exit 1
  fi
done

if [ ! -f "$BROWSER_DIR/repl.wasm" ]; then
  echo "ERROR: browser/repl.wasm not found. Run 'make' first." >&2
  exit 1
fi

# Start static file server with correct WASM MIME type
echo "Starting server on port $PORT..."
cd "$BROWSER_DIR" && python3 -c "
import http.server, socketserver
class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      '.wasm': 'application/wasm',
                      '.mjs': 'text/javascript'}
    def log_message(self, *args): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(('', $PORT), Handler) as s:
    s.serve_forever()
" &
SERVER_PID=$!
cd "$ROOT_DIR"
SERVER_PID=$!

cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Wait for server to be ready
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

# Find Chromium — prefer system-installed over Playwright-managed
for chromium_path in \
  /snap/bin/chromium \
  /usr/bin/chromium \
  /usr/bin/chromium-browser \
  /usr/bin/google-chrome; do
  if [ -x "$chromium_path" ]; then
    export CHROMIUM_PATH="$chromium_path"
    echo "Using Chromium: $CHROMIUM_PATH"
    break
  fi
done

if [ -z "$CHROMIUM_PATH" ]; then
  # Fall back to Playwright-managed browser
  if command -v npx >/dev/null 2>&1; then
    echo "No system Chromium found, using Playwright-managed..."
    npx playwright install chromium 2>/dev/null
  else
    echo "ERROR: No Chromium found and npx not available" >&2
    exit 1
  fi
fi

# Run the Playwright tests
echo ""
cd "$ROOT_DIR"
node "$SCRIPT_DIR/browser-ux.mjs" "http://localhost:$PORT"
EXIT_CODE=$?

echo ""
if [ "$EXIT_CODE" -eq 0 ]; then
  echo "All browser UX tests passed."
else
  echo "Some browser UX tests failed. Check tests/screenshots/ for details."
fi

exit $EXIT_CODE
