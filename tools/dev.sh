#!/bin/bash
# tools/dev.sh — the day dial, LIVE, on your own machine.
#
# Starts a real gateway (no KERIA — same shape as tests/ux/ux-full.sh) with
# a persistent state dir, waits for its sturdyref, and prints the
# app.html URL with ?gateway=<sref> spliced in — the page's highest-
# priority discovery source, so the stale /var/lib sref is bypassed.
#
# ONE COMMAND, WHOLE STACK: it also brings up the static server if nothing
# is serving :8080 yet, pointed at this run's own state dir — so
# /entry-points.json and /oobi describe THIS gateway rather than production.
# An already-running `make serve` is reused untouched (and left running on
# exit); one we started is torn down with the gateway.
#
# Ctrl-C stops whatever this script started; state persists in .dev-data
# so your identity and plan survive restarts.
#
#   make dev                 # gateway + static server + the live URL
#   STATIC_PORT=8081 make dev
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DATA="$ROOT/.dev-data"
GW_PORT="${GATEWAY_PORT:-9099}"
STATIC_PORT="${STATIC_PORT:-8080}"
SREF_FILE="$DATA/gateway-sref.txt"
GW_LOG="$DATA/gateway.log"

mkdir -p "$DATA" "$DATA/oobi-host"
rm -f "$SREF_FILE"

# ── the static server ────────────────────────────────────────────────────
# Started FIRST so the page is reachable while the gateway warms up (the
# gateway takes tens of seconds to mint its sturdyref). PLAYNET_DATA_DIR
# points serve-static at this run's state, so /entry-points.json carries the
# LOCAL gateway's sref and /oobi serves the KELs this gateway actually wrote —
# without it the dev page describes production while talking to localhost.
STATIC_PGID=""
if curl -sf -o /dev/null "http://127.0.0.1:$STATIC_PORT/app.html" 2>/dev/null; then
  echo "== reusing the static server already on :$STATIC_PORT =="
  echo "   (NOTE: started outside this script, so it may point at another"
  echo "    data dir — restart it under 'make dev' if /oobi looks wrong)"
else
  echo "== starting static server on :$STATIC_PORT (state: $DATA) =="
  setsid env PLAYNET_DATA_DIR="$DATA" \
    make serve PORT="$STATIC_PORT" OOBI_DIR="$DATA/oobi-host" \
    > "$DATA/static.log" 2>&1 < /dev/null &
  STATIC_PGID=$!
  for i in $(seq 1 40); do
    curl -sf -o /dev/null "http://127.0.0.1:$STATIC_PORT/app.html" 2>/dev/null && break
    sleep 1
  done
  if curl -sf -o /dev/null "http://127.0.0.1:$STATIC_PORT/app.html" 2>/dev/null; then
    echo "  static server up"
  else
    echo "ERROR: static server didn't come up"; tail -10 "$DATA/static.log"; exit 1
  fi
fi

# The gateway MUST run the same pinned Goblins that browser/day-boot.wasm
# was compiled against. keri-test-manifest bypasses time-machine (see its
# header), so a bare `guile-goblins` there can resolve to a different
# version — and the OCapN websocket handshake is not compatible across
# versions. The symptom names neither: the browser says "WebSocket
# designator verification failed", the gateway log says "invalid client
# verification message". Same fix as tests/ux/ux-full.sh.
GOBLINS_PATHS="$(make -s print-goblins-path 2>/dev/null)"
GOBLINS_LP="${GOBLINS_PATHS%%:*}"
GOBLINS_CC="${GOBLINS_PATHS##*:}"
[ -d "$GOBLINS_LP" ] || { echo "ERROR: pinned goblins not found — run 'make print-goblins-path'"; exit 1; }

# ── the demo commune ─────────────────────────────────────────────────────
# An empty gateway has no scope, and a dial with no scope cannot open a chat
# channel, a meeting room or anything else scope-shaped — you sign in and land
# on a working page with nothing to act on. PLAYNET_SEED_DEMO gives it a
# commune with recipes and intents.
#
# Seeded ONCE per state dir: the state is durable, so seeding every start would
# pile the same demo data up again. SEED=1 forces a re-seed, SEED=0 never seeds.
#
# PLAYNET_SCOPES_DURABLE=1 (on the gateway line below) boots the WHOLE
# governance tier — UC, scope-graph, curator — the same shape production runs.
# The demand fold (declared needs → the solve) reads the scope graph, so
# without it a dev gateway plans an eternally empty day.
SEED="${SEED:-auto}"
if [ "$SEED" = auto ]; then
  if [ -e "$DATA/.seeded" ]; then SEED=0; else SEED=1; fi
fi
[ "$SEED" = 1 ] && echo "== seeding the demo commune (SEED=0 to skip) =="

echo "== starting gateway on :$GW_PORT (state: $DATA, durable) =="
# The gateway keeps its OWN compile cache (XDG_CACHE_HOME below): the test
# suites' pure-shell guile writes .go files into ~/.cache/guile that THIS
# guile mis-loads — keri's canonical JSON goes wrong and every signup fails
# "signature does not verify". An isolated cache makes the gateway immune
# to whatever the suites compiled since it last booted.
setsid guix shell -L deploy/guix -m deploy/manifests/keri-test-manifest.scm -- \
  bash -c "PLAYNET_DATA_DIR='$DATA' PLAYNET_SEED_DEMO='$SEED' PLAYNET_SCOPES_DURABLE=1 LTDL_LIBRARY_PATH=\"\$GUIX_ENVIRONMENT/lib\" \
    XDG_CACHE_HOME='$DATA/cache' \
    exec guile --no-auto-compile -L '$GOBLINS_LP' -C '$GOBLINS_CC' -L module -L . -L deploy/guix \
      -s server/gateway.scm --host 127.0.0.1 --port $GW_PORT" \
  > "$GW_LOG" 2>&1 < /dev/null &
GW_PGID=$!
# Only tear down what WE started: a static server the operator was already
# running in another terminal keeps running after Ctrl-C here.
cleanup() {
  kill -- -"$GW_PGID" 2>/dev/null; pkill -P "$GW_PGID" 2>/dev/null
  [ -n "$STATIC_PGID" ] && { kill -- -"$STATIC_PGID" 2>/dev/null
                             pkill -P "$STATIC_PGID" 2>/dev/null; }
}
trap cleanup EXIT INT TERM

for i in $(seq 1 80); do [ -f "$SREF_FILE" ] && break; sleep 3; done
[ -f "$SREF_FILE" ] || {
  echo "ERROR: gateway didn't write a sturdyref"; tail -10 "$GW_LOG"; exit 1; }
[ "$SEED" = 1 ] && touch "$DATA/.seeded"
SREF="$(cat "$SREF_FILE")"
# the file's sref may carry its inner ws URL raw OR pre-encoded, and it
# records the BIND address (0.0.0.0, unconnectable from a browser) —
# normalize to a single-encoded loopback ws, then encode the whole sref
# for the ?gateway= query param
ENC="$(python3 -c "
import urllib.parse, sys
s = sys.argv[1].strip()
base, sep, ws = s.partition('?url=')
if sep:
    if '://' in ws:                       # raw -> encode once
        ws = urllib.parse.quote(ws, safe='')
    ws = ws.replace('0.0.0.0', '127.0.0.1')
    s = base + sep + ws
print(urllib.parse.quote(s, safe=''))" "$SREF")"
echo "  gateway up"

# dev=1: the page tears its service worker down and polls the live-reload
# token — every refresh serves this checkout's files, never a cached build
URL="http://127.0.0.1:$STATIC_PORT/app.html?dev=1&gateway=$ENC"
echo
echo "  the dial, live:"
echo "    $URL"
echo
# Two peers is the interesting case — a walkie room needs someone to mesh
# with, and one browser profile holds one identity. Separate profiles (or a
# normal + private window) give you two AIDs against the same gateway.
echo "  two peers (a meeting needs two): open the SAME url in a second"
echo "  browser profile or a private window, create an identity in each,"
echo "  then 📻 the network → join with video."
echo
echo "  logs: tail -f $GW_LOG"
[ -n "$STATIC_PGID" ] && echo "        tail -f $DATA/static.log"
echo "  Ctrl-C stops everything this script started."
echo "$URL" > "$DATA/dial-url.txt"
wait "$GW_PGID"
