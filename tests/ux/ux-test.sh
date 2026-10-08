#!/bin/sh
# tests/ux/ux-test.sh — Start server, run browser UX tests, teardown.
# Usage: sh tests/ux/ux-test.sh
#
# Serves browser/repl.wasm via Python http.server (zero deps).
# Runs Playwright tests via node (from guix shell or PATH).
# Fully reproducible: no npm install, no npx, no node_modules.

set -e

PORT="${UX_TEST_PORT:-8088}"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
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

# Bridge the guix shell's node_modules into the repo so ESM resolution
# can find it. The guix profile sets NODE_PATH correctly for CJS, but
# `await import()` in a .mjs file uses ESM's resolver, which only walks
# ancestor `node_modules` directories — it ignores NODE_PATH. So we
# expose the guix env's node_modules as $ROOT_DIR/node_modules via a
# symlink, cleaned up on exit. node_modules/ is gitignored, so this
# can't accidentally land in a commit.
NODE_MODULES_LINK=""
if [ -n "${GUIX_ENVIRONMENT-}" ] && [ -d "$GUIX_ENVIRONMENT/lib/node_modules" ] \
     && [ ! -e "$ROOT_DIR/node_modules" ]; then
  ln -s "$GUIX_ENVIRONMENT/lib/node_modules" "$ROOT_DIR/node_modules"
  NODE_MODULES_LINK="$ROOT_DIR/node_modules"
fi

if [ ! -f "$BROWSER_DIR/repl.wasm" ]; then
  echo "ERROR: browser/repl.wasm not found. Run 'make' first." >&2
  exit 1
fi

# Start static file server with correct WASM MIME type + COOP/COEP headers
echo "Starting server on port $PORT..."
cd "$BROWSER_DIR" && python3 -c "
import http.server, socketserver
class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      '.wasm': 'application/wasm',
                      '.mjs': 'text/javascript'}
    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        super().end_headers()
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
  # Only unlink if we created it (don't trample a real user-managed node_modules)
  if [ -n "$NODE_MODULES_LINK" ] && [ -L "$NODE_MODULES_LINK" ]; then
    rm -f "$NODE_MODULES_LINK"
  fi
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

# Find Chromium — prefer guix-shell-provided, then system, then Playwright-managed.
# When the manifest pulls in ungoogled-chromium, `chromium` lands on PATH
# inside the shell. `command -v` finds it without hard-coding the store path.
if command -v chromium >/dev/null 2>&1; then
  export CHROMIUM_PATH="$(command -v chromium)"
  echo "Using Chromium (PATH): $CHROMIUM_PATH"
else
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
fi

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
  echo "Some browser UX tests failed. Check tests/ux/screenshots/ for details."
fi

exit $EXIT_CODE
