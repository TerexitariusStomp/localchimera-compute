#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tools/dev/onion.sh — the day dial, LIVE on your phone, over a throwaway .onion.
#
# One command for the "edit from mobile, see it on mobile" loop:
#   * a dedicated tor instance (its OWN data dir — never touches system tor)
#     publishes a hidden service that maps onion:80 -> 127.0.0.1:8080;
#   * the live-reload watcher (tools/dev/livereload-watch.py) bumps a token file
#     whenever anything under browser/ changes;
#   * app.html opened with ?dev=1 disables its service worker and polls that
#     token, so edits repaint the phone with no manual refresh.
#
# The static server is NOT started here — reuse `make serve` on :8080 in another
# terminal (same as make dev). Ctrl-C stops the tor instance + the watcher.
#
#   make onion               # persistent onion (same URL across restarts)
#   FRESH=1 make onion       # brand-new onion this run
#
# The hidden-service key lives in .onion-data/ (gitignored). Persistent by
# default so you can bookmark the URL on your phone; FRESH=1 rotates it.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

STATIC_PORT="${STATIC_PORT:-8080}"
TOR_PORT="${TOR_PORT:-9080}"        # loopback port this tor forwards FROM (dummy; HS only)
DATA="$ROOT/.onion-data"
HS="$DATA/hs"
TORRC="$DATA/torrc"
TOR_LOG="$DATA/tor.log"

command -v tor >/dev/null || { echo "ERROR: tor not found (guix: tor)."; exit 1; }

# A fresh onion == throw away the hidden-service key.
[ "${FRESH:-}" = "1" ] && rm -rf "$HS"
mkdir -p "$HS"; chmod 700 "$DATA" "$HS"

# Reuse the static server; it, not this script, serves app.html.
if ! curl -sf -o /dev/null "http://127.0.0.1:$STATIC_PORT/app.html"; then
  echo "ERROR: no static server on :$STATIC_PORT — run 'make serve' in another terminal first."
  exit 1
fi

# Live-reload watcher (background; dies with this script).
echo "== starting live-reload watcher (browser/) =="
python3 "$ROOT/tools/dev/livereload-watch.py" "$ROOT/browser" > "$DATA/watch.log" 2>&1 &
WATCH_PID=$!

cat > "$TORRC" <<EOF
SocksPort 0
DataDirectory $DATA/tor
HiddenServiceDir $HS
HiddenServicePort 80 127.0.0.1:$STATIC_PORT
EOF

echo "== starting dedicated tor (its own data dir; system tor untouched) =="
tor -f "$TORRC" > "$TOR_LOG" 2>&1 &
TOR_PID=$!

cleanup() { kill "$TOR_PID" "$WATCH_PID" 2>/dev/null; }
trap cleanup EXIT INT TERM

# Wait for the hidden-service hostname, then for a published descriptor.
for i in $(seq 1 40); do [ -f "$HS/hostname" ] && break; sleep 1; done
[ -f "$HS/hostname" ] || { echo "ERROR: tor never wrote a hostname"; tail -15 "$TOR_LOG"; exit 1; }
ONION="$(cat "$HS/hostname")"
echo -n "  waiting for onion to bootstrap"
for i in $(seq 1 60); do
  grep -q "Bootstrapped 100%" "$TOR_LOG" && break
  echo -n "."; sleep 2
done
echo

echo
echo "  the dial, live on your phone (open in Tor Browser / Onion Browser):"
echo "    http://$ONION/app.html?dev=1"
echo
echo "  ?dev=1 disables the service worker + enables live-reload."
echo "  (tor log: $TOR_LOG  |  watcher log: $DATA/watch.log)"
echo "  Ctrl-C stops the onion + watcher. State: $DATA (gitignored)."
wait "$TOR_PID"
