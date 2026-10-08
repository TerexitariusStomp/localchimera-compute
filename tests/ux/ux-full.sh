#!/bin/bash
# tests/ux/ux-full.sh — self-contained browser e2e: start a gateway (no KERIA),
# then run a Playwright test against it through a /ws proxy. Cleans up on exit.
#
#   bash tests/ux/ux-full.sh tests/<feature>-ux.mjs
#   make test-ux TEST=tests/<feature>-ux.mjs
#
# The test file gets <base-url> <encoded-gateway-sref> as argv (see ux-harness.mjs).
set -u
TEST="${1:?usage: bash tests/ux/ux-full.sh tests/<feature>-ux.mjs}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
DATA="$ROOT/.ux-e2e-data"
GW_PORT="${GATEWAY_PORT:-9097}"
SREF_FILE="$DATA/gateway-sref.txt"
GW_LOG="$DATA/gateway.log"

[ -f browser/repl.wasm ] || { echo "ERROR: browser/repl.wasm missing — run 'make' first"; exit 1; }
rm -rf "$DATA"; mkdir -p "$DATA"

# The gateway MUST run the same pinned Goblins that browser/repl.wasm was
# compiled against. keri-test-manifest deliberately bypasses time-machine
# (see its header), so a bare `guile-goblins` there can resolve to a
# different version — and the OCapN websocket handshake is not compatible
# across versions. The symptom is silent-looking: the browser reports
# "WebSocket designator verification failed" and the gateway log says
# "invalid client verification message", with no mention of versions.
# Prepending the pinned source (-L) AND compiled (-C) paths shadows whatever
# the profile supplies.
GOBLINS_PATHS="$(make -s print-goblins-path 2>/dev/null)"
GOBLINS_LP="${GOBLINS_PATHS%%:*}"
GOBLINS_CC="${GOBLINS_PATHS##*:}"
[ -d "$GOBLINS_LP" ] || { echo "ERROR: pinned goblins not found — run 'make print-goblins-path'"; exit 1; }
echo "  pinned goblins: $GOBLINS_LP"

echo "== starting gateway on :$GW_PORT (no KERIA) =="
# Forward a couple of optional knobs from the outer env so a test can set up
# governance scenarios: PLAYNET_FOUNDERS (comma-sep AIDs made bootstrap
# governors) and PLAYNET_SEED_DEMO (seed the meeting commune). Only injected
# when set, so existing tests are unaffected.
# Each gateway keeps its own STATE dir (witness relay files, enrollment
# ceremony records) so two gateways in one harness never read each other's
# rails through the filesystem — only through the static tier, as peers do.
OOBI_PORT="${OOBI_PORT:-8098}"
OOBI_PORT2="${OOBI_PORT2:-8099}"
GW_EXTRA_ENV=" PLAYNET_STATE_DIR='$DATA/state' PLAYNET_WITNESS_POLL_SECS='${PLAYNET_WITNESS_POLL_SECS:-5}' PLAYNET_REMOTE_POLL_INTERVAL_SEC='${PLAYNET_REMOTE_POLL_INTERVAL_SEC:-5}' PLAYNET_WITNESS_POLL_DEBUG='1'"
# durable scopes mint REAL AIDs only with a vault key; each gateway gets its
# own, so two harness gateways never share an identity
if [ "${PLAYNET_SCOPES_DURABLE:-0}" != "0" ]; then
  VK1="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  VK2="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  GW_EXTRA_ENV="$GW_EXTRA_ENV PLAYNET_VAULT_KEY='$VK1'"
fi
# with a second gateway, each polls the OTHER's static tier for witness asks
[ -n "${SECOND_GATEWAY:-}" ] && GW_EXTRA_ENV="$GW_EXTRA_ENV PLAYNET_PEERS='http://127.0.0.1:$OOBI_PORT2'"
[ -n "${PLAYNET_FOUNDERS:-}" ]  && GW_EXTRA_ENV="$GW_EXTRA_ENV PLAYNET_FOUNDERS='$PLAYNET_FOUNDERS'"
[ -n "${PLAYNET_SEED_DEMO:-}" ] && GW_EXTRA_ENV="$GW_EXTRA_ENV PLAYNET_SEED_DEMO='$PLAYNET_SEED_DEMO'"
# mail the gateway would send is written to this directory, where a test reads it
[ -n "${PLAYNET_MAIL_DIR:-}" ] && GW_EXTRA_ENV="$GW_EXTRA_ENV PLAYNET_MAIL_DIR='$PLAYNET_MAIL_DIR'"
[ -n "${PLAYNET_TEST_OPEN_GOVERNANCE:-}" ] && GW_EXTRA_ENV="$GW_EXTRA_ENV PLAYNET_TEST_OPEN_GOVERNANCE='$PLAYNET_TEST_OPEN_GOVERNANCE'"
setsid guix shell -L deploy/guix -m deploy/manifests/keri-test-manifest.scm -- \
  bash -c "PLAYNET_DATA_DIR='$DATA' PLAYNET_SCOPES_DURABLE=${PLAYNET_SCOPES_DURABLE:-0}$GW_EXTRA_ENV LTDL_LIBRARY_PATH=\"\$GUIX_ENVIRONMENT/lib\" \
    exec guile --no-auto-compile -L '$GOBLINS_LP' -C '$GOBLINS_CC' -L module -L . -L deploy/guix -s server/gateway.scm --host 127.0.0.1 --port $GW_PORT" \
  > "$GW_LOG" 2>&1 < /dev/null &
GW_PGID=$!
OOBI_PGID=""
GW2_PGID=""
cleanup() {
  kill -- -"$GW_PGID" 2>/dev/null; pkill -P "$GW_PGID" 2>/dev/null
  [ -n "$OOBI_PGID" ] && { kill -- -"$OOBI_PGID" 2>/dev/null; pkill -P "$OOBI_PGID" 2>/dev/null; }
  [ -n "$GW2_PGID" ] && { kill -- -"$GW2_PGID" 2>/dev/null; pkill -P "$GW2_PGID" 2>/dev/null; }
  [ -n "${OOBI2_PGID:-}" ] && { kill -- -"$OOBI2_PGID" 2>/dev/null; pkill -P "$OOBI2_PGID" 2>/dev/null; }
}
trap cleanup EXIT INT TERM

for i in $(seq 1 80); do [ -f "$SREF_FILE" ] && break; sleep 3; done
[ -f "$SREF_FILE" ] || { echo "ERROR: gateway didn't register a sturdyref"; tail -5 "$GW_LOG"; exit 1; }
echo "  gateway up, sref written"

# A SECOND commune, opt-in (SECOND_GATEWAY=1): its own data dir, its own port,
# never having seen anything the first one has. This is the mile a carried
# KEL walks — an identity made at one gateway taking a seat at another — and
# it needs two genuinely separate gateways, since "unregistered" is a fact
# about a commune's own oobi-host. ux-run.sh serves it through a second /ws
# proxy and hands the test its base URL as UX_BASE2.
if [ -n "${SECOND_GATEWAY:-}" ]; then
  DATA2="$ROOT/.ux-e2e-data-2"
  GW2_PORT="${GATEWAY2_PORT:-9199}"
  SREF2_FILE="$DATA2/gateway-sref.txt"
  rm -rf "$DATA2"; mkdir -p "$DATA2"
  echo "== starting SECOND gateway on :$GW2_PORT (no KERIA) =="
  GW2_EXTRA_ENV="$(echo "$GW_EXTRA_ENV" | sed -e "s|PLAYNET_STATE_DIR='[^']*'|PLAYNET_STATE_DIR='$DATA2/state'|" -e "s|PLAYNET_PEERS='[^']*'|PLAYNET_PEERS='http://127.0.0.1:$OOBI_PORT'|" -e "s|PLAYNET_VAULT_KEY='[^']*'|PLAYNET_VAULT_KEY='${VK2:-}'|")"
  echo "  second gateway env:$GW2_EXTRA_ENV"
  setsid guix shell -L deploy/guix -m deploy/manifests/keri-test-manifest.scm -- \
    bash -c "PLAYNET_DATA_DIR='$DATA2' PLAYNET_SCOPES_DURABLE=${PLAYNET_SCOPES_DURABLE:-0}$GW2_EXTRA_ENV LTDL_LIBRARY_PATH=\"\$GUIX_ENVIRONMENT/lib\" \
      exec guile --no-auto-compile -L '$GOBLINS_LP' -C '$GOBLINS_CC' -L module -L . -L deploy/guix -s server/gateway.scm --host 127.0.0.1 --port $GW2_PORT" \
    > "$DATA2/gateway.log" 2>&1 < /dev/null &
  GW2_PGID=$!
  for i in $(seq 1 80); do [ -f "$SREF2_FILE" ] && break; sleep 3; done
  [ -f "$SREF2_FILE" ] || { echo "ERROR: second gateway didn't register a sturdyref"; tail -5 "$DATA2/gateway.log"; exit 1; }
  echo "  second gateway up, sref written"
  export GATEWAY2_PORT="$GW2_PORT" GATEWAY2_SREF_FILE="$SREF2_FILE" PLAYNET_DATA_DIR2="$DATA2"
fi

# The REAL /oobi route (server/serve-static.scm) against the gateway's
# oobi-host dir, so tests can assert the served OOBI body (KEL + OKEA
# endpoint replies) exactly as a KERIA resolver would fetch it.
echo "== starting /oobi server on :$OOBI_PORT (serve-static, oobi-dir=$DATA/oobi-host) =="
setsid guix shell -L deploy/guix -m deploy/manifests/keri-test-manifest.scm -- \
  env PLAYNET_STATE_DIR="$DATA/state" PLAYNET_DATA_DIR="$DATA" guile --no-auto-compile -L module -L . \
  -c "((@ (server serve-static) run-static-server) #:work-dir \"browser\" #:oobi-dir \"$DATA/oobi-host\" #:port $OOBI_PORT)" \
  > "$DATA/oobi-server.log" 2>&1 < /dev/null &
OOBI_PGID=$!
# the second gateway's static tier: what the first polls for witness asks
OOBI2_PGID=""
if [ -n "${SECOND_GATEWAY:-}" ]; then
  setsid guix shell -L deploy/guix -m deploy/manifests/keri-test-manifest.scm -- \
    env PLAYNET_STATE_DIR="$DATA2/state" PLAYNET_DATA_DIR="$DATA2" guile --no-auto-compile -L module -L . \
    -c "((@ (server serve-static) run-static-server) #:work-dir \"browser\" #:oobi-dir \"$DATA2/oobi-host\" #:port $OOBI_PORT2)" \
    > "$DATA2/oobi-server.log" 2>&1 < /dev/null &
  OOBI2_PGID=$!
  for i in $(seq 1 30); do
    curl -sf -o /dev/null "http://127.0.0.1:$OOBI_PORT2/" && break; sleep 2
  done
  curl -sf -o /dev/null "http://127.0.0.1:$OOBI_PORT2/" \
    || { echo "ERROR: second /oobi server didn't come up"; tail -5 "$DATA2/oobi-server.log"; exit 1; }
  echo "  second /oobi server up"
fi
for i in $(seq 1 30); do
  curl -sf -o /dev/null "http://127.0.0.1:$OOBI_PORT/" && break; sleep 2
done
curl -sf -o /dev/null "http://127.0.0.1:$OOBI_PORT/" \
  || { echo "ERROR: /oobi server didn't come up"; tail -5 "$DATA/oobi-server.log"; exit 1; }
export OOBI_URL="http://127.0.0.1:$OOBI_PORT"
echo "  /oobi server up"

echo "== running $TEST (Playwright) =="
# PLAYNET_DATA_DIR is exported so a test can inspect what the gateway
# actually persisted (e.g. credential-sync-ux asserts the stored credential
# backup is ciphertext, then decrypts it from the passcode alone).
# UX_MANIFEST names the browser profile; the engines manifest adds icecat and
# webkitgtk for a suite that walks Gecko and WebKit.
GATEWAY_PORT="$GW_PORT" GATEWAY_SREF_FILE="$SREF_FILE" PLAYNET_DATA_DIR="$DATA" \
  guix shell -m "${UX_MANIFEST:-deploy/manifests/browser-test-manifest.scm}" -- sh tests/ux/ux-run.sh "$TEST"
RC=$?
if [ "$RC" -eq 0 ]; then rm -rf "$DATA" "${PLAYNET_DATA_DIR2:-}"
else echo "== test failed (rc=$RC) — keeping $DATA${PLAYNET_DATA_DIR2:+ and $PLAYNET_DATA_DIR2} (gateway.log, oobi-server.log) for diagnosis =="
fi
exit $RC
