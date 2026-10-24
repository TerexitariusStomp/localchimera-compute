#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/keri/integration/run-integration.sh — spin up real KERIA + witnesses,
# run the integration test suite, tear everything down.
#
# Invoked by `make test-keri-integration`. Stand-alone entry point:
#
#   guix shell -L deploy/guix -m deploy/manifests/keri-test-manifest.scm -- \
#     sh tests/keri/integration/run-integration.sh
#
# What this does:
#   1. mktemp a fresh work dir under $TMPDIR.
#   2. Start `kli witness demo` in the background (6 nodes, 5642-5647).
#      These are the DEMO witnesses — hard-coded well-known keys. Fine for
#      integration tests, NEVER for production. See keria-service.scm for the
#      "DO NOT USE DEMO IN PROD" warning.
#   3. Start `keria start` in the background pointing at the work dir.
#   4. Poll each service's HTTP port until it responds. No fixed sleeps —
#      if a service doesn't come up in READY_TIMEOUT seconds we abort.
#   5. Run tests/keri/integration/test-real-keria.scm with the right env.
#   6. Tear down both processes on success, failure, or Ctrl-C (trap EXIT).
#
# Everything lives in $TMPDIR — no writes inside the repo, no state
# carried between runs.

set -e
set -u
# Pipefail would be nice but we want to survive `kill` + `wait` exit codes.

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
READY_TIMEOUT="${KERI_TEST_READY_TIMEOUT:-45}"

# Ports. Match the defaults the bridge expects; override if something else
# on the host is listening.
KERIA_ADMIN_PORT="${KERIA_ADMIN_PORT:-3901}"
KERIA_AGENT_PORT="${KERIA_AGENT_PORT:-3902}"
KERIA_BOOT_PORT="${KERIA_BOOT_PORT:-3903}"
# Witness ports are hard-coded to 5642-5647 in `kli witness demo` — no
# way to override without patching keripy, so we just require them free.
WITNESS_PORTS="5642 5643 5644 5645 5646 5647"
# Pool witness (a PROPERLY CONFIGURED witness whose OOBI advertises its
# /loc/scheme endpoint — unlike the demo six, it can be receipted-to).
POOLWIT_HTTP="${POOLWIT_HTTP:-5742}"
POOLWIT_TCP="${POOLWIT_TCP:-5732}"

# Test passcode — 21 CESR chars, deterministic for the test run.
# NEVER use this in production; it derives all signing keys.
KERIA_PASSCODE="${KERIA_PASSCODE:-testpasscode21charsXX}"

# ── work dir ───────────────────────────────────────────────────────────────
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keri-test-XXXXXX")"
KERIA_DATA_DIR="$WORK_DIR/keria"
WITNESS_DATA_DIR="$WORK_DIR/witnesses"
KERIA_CONFIG_DIR="$KERIA_DATA_DIR/config"
# keripy's Configer resolves --config-dir D --config-file F to
# D/keri/cf/F.json — a file at D/F.json is silently ignored and KERIA
# boots with no iurls (which is how this harness ran for months).
KERIA_CONFIG_FILE="$KERIA_CONFIG_DIR/keri/cf/keria.json"
KERIA_LOG="$WORK_DIR/keria.log"
WITNESS_LOG="$WORK_DIR/witnesses.log"

mkdir -p "$KERIA_DATA_DIR" "$WITNESS_DATA_DIR" "$KERIA_CONFIG_DIR/keri/cf"

# Reuse the production KERIA config (points at the same localhost witness
# OOBIs the demo witnesses expose — AIDs BBilc4…, BLskRTI…, etc.).
cp "$ROOT_DIR/deploy/keria-config.json" "$KERIA_CONFIG_FILE"

# ── process tracking ───────────────────────────────────────────────────────
KERIA_PID=""
WITNESS_PID=""
POOLWIT_PID=""
EXIT_CODE=0

say() { printf '[integration] %s\n' "$*" >&2; }

# kill-tree: SIGTERM + 1s grace + SIGKILL, aimed at the whole process
# group. Works for both `keria start` (single python child) and
# `kli witness demo` (parent + 6 witnesses under setsid).
kill_tree() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.2
  done
  kill -KILL -- -"$pid" 2>/dev/null || true
  kill -KILL "$pid" 2>/dev/null || true
}

# wait_port_free: block until a TCP port stops responding (or we give up).
# Prevents the next run from tripping the port-in-use preflight when
# the OS hasn't yet reclaimed a freshly-killed socket.
wait_port_free() {
  local port="$1"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -sS -m 1 -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null || return 0
    sleep 0.3
  done
  # Still listening → something else owns the port; warn but don't hang.
  say "WARN: port $port still in use after teardown"
}

cleanup() {
  local code=$?
  say "tearing down (exit=$code)"
  kill_tree "$KERIA_PID"
  kill_tree "$WITNESS_PID"
  kill_tree "$POOLWIT_PID"
  # Sweep any stragglers that didn't catch the group signal (observed
  # with kli's fork-before-setsid on some kernels).
  pkill -KILL -u "$(id -u)" -f "keria start .*$WORK_DIR" 2>/dev/null || true
  pkill -KILL -u "$(id -u)" -f "kli witness demo" 2>/dev/null || true
  pkill -KILL -u "$(id -u)" -f "kli witness start --name poolwit" 2>/dev/null || true
  for p in "$KERIA_BOOT_PORT" "$KERIA_ADMIN_PORT" "$KERIA_AGENT_PORT" $WITNESS_PORTS $POOLWIT_HTTP; do
    wait_port_free "$p"
  done
  # Dump logs on failure so CI / the user sees what went wrong.
  if [ "$code" -ne 0 ]; then
    say "== witness log (tail) =="
    [ -f "$WITNESS_LOG" ] && tail -n 40 "$WITNESS_LOG" >&2 || true
    say "== keria log (tail) =="
    [ -f "$KERIA_LOG" ] && tail -n 40 "$KERIA_LOG" >&2 || true
    say "work dir preserved for inspection: $WORK_DIR"
  else
    rm -rf "$WORK_DIR"
  fi
  exit "$code"
}
trap cleanup EXIT INT TERM

# ── preflight: tools we need ───────────────────────────────────────────────
for tool in keria kli guile curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    say "ERROR: missing required tool '$tool'"
    say "  run via: make test-keri-integration (supplies the guix shell)"
    exit 2
  fi
done

# ── preflight: port conflicts ──────────────────────────────────────────────
for port in "$KERIA_ADMIN_PORT" "$KERIA_AGENT_PORT" "$KERIA_BOOT_PORT" $WITNESS_PORTS $POOLWIT_HTTP $POOLWIT_TCP; do
  # Any response (even HTTP error) means something's listening. We want silence.
  if curl -sS -m 1 -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then
    say "ERROR: port $port already in use — free it or override KERIA_*_PORT"
    exit 3
  fi
done

# ── spawn witnesses ────────────────────────────────────────────────────────
say "starting kli witness demo (ports $WITNESS_PORTS)"
# setsid puts kli in its own process group so we can kill all 6 children.
(
  cd "$WITNESS_DATA_DIR"
  HOME="$WITNESS_DATA_DIR" \
  KERI_HOME="$WITNESS_DATA_DIR" \
  PYTHONUNBUFFERED=1 \
    setsid kli witness demo >"$WITNESS_LOG" 2>&1
) &
WITNESS_PID=$!

# Witness AIDs hard-coded by `kli witness demo` (keripy source). Same set
# the test uses for OOBI assertions.
WITNESS_AIDS_5642="BBilc4-L3tFUnfM_wJr4S4OJanAv_VmF_dJNN6vkf2Ha"
WITNESS_AIDS_5643="BLskRTInXnMxWaGqcpSyMgo0nYbalW99cGZESrz3zapM"
WITNESS_AIDS_5644="BIKKuvBwpmDVA4Ds-EpL5bt9OqPzWPja2LigFYZN2YfX"
WITNESS_AIDS_5645="BM35JN8XeJSEfpxopjn5jr7tAHCE5749f0OobhMLCorE"
WITNESS_AIDS_5646="BIj15u5V11bkbtAxMA7gcNJZcax-7TgaBMLsQnMHpYHP"
WITNESS_AIDS_5647="BF2rZTW79z4IXocYRQnjjsOuvFUQv-ptCf8Yltd7PfsM"

# Wait until each witness actually serves its OOBI (not just accepts TCP).
# A TCP accept happens within ~1s but the witness needs another ~30s to
# load its KEL and start responding to /oobi/<AID>/controller. Probing
# the OOBI directly avoids racing the test against a half-booted witness.
wait_for_witnesses() {
  local deadline=$(( $(date +%s) + READY_TIMEOUT ))
  for port in $WITNESS_PORTS; do
    local aid_var="WITNESS_AIDS_${port}"
    local aid="${!aid_var}"
    while true; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        say "ERROR: witness on port $port not ready after ${READY_TIMEOUT}s"
        return 1
      fi
      # Real readiness: the OOBI endpoint returns 200 with a CESR-framed
      # body containing the witness AID. /  alone returns 405 immediately,
      # which is too eager — the witness's port accepts before the KEL
      # state is loaded.
      if curl -sS -m 2 "http://127.0.0.1:$port/oobi/$aid/controller" 2>/dev/null \
           | grep -q "$aid"; then
        break
      fi
      sleep 0.5
    done
    say "witness on $port serving OOBI"
  done
}
wait_for_witnesses

# ── spawn the pool witness ─────────────────────────────────────────────────
# A properly CONFIGURED keripy witness (vs the six demo ones): its config
# carries `curls`, so at hab creation keripy runs makeEndRole+makeLocScheme
# and its OOBI body advertises the /loc/scheme endpoint. That makes it the
# only witness in this harness a KERIA agent can actually receipt against
# (the demo witnesses serve a bare icp — no endpoint, receipting impossible).
# NB: `kli witness start --config-file` is broken in keripy 1.2.12
# (Configer.get(default=) TypeError), so we rely on Habery's DEFAULT
# config lookup instead: Configer(name=<keystore name>) under the Alt
# head dir — i.e. $HOME/.keri/cf/poolwit.json with HOME isolated below.
POOLWIT_DIR="$WORK_DIR/poolwit"
mkdir -p "$POOLWIT_DIR/.keri/cf"
cat > "$POOLWIT_DIR/.keri/cf/poolwit.json" <<EOF
{
  "dt": "2026-01-01T00:00:00.000000+00:00",
  "pw": {
    "dt": "2026-01-01T00:00:00.000000+00:00",
    "curls": ["http://127.0.0.1:$POOLWIT_HTTP/"]
  }
}
EOF
say "starting pool witness (http=$POOLWIT_HTTP tcp=$POOLWIT_TCP)"
(
  cd "$POOLWIT_DIR"
  HOME="$POOLWIT_DIR" \
  KERI_HOME="$POOLWIT_DIR" \
  PYTHONUNBUFFERED=1 \
    setsid kli witness start --name poolwit --alias pw \
      -H "$POOLWIT_HTTP" -T "$POOLWIT_TCP" >"$WORK_DIR/poolwit.log" 2>&1
) &
POOLWIT_PID=$!

# Discover the pool witness AID (fresh salt each run → query, don't pin).
wait_for_poolwit() {
  local deadline=$(( $(date +%s) + READY_TIMEOUT ))
  POOLWIT_AID=""
  while [ -z "$POOLWIT_AID" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      say "ERROR: pool witness did not report an identifier in ${READY_TIMEOUT}s"
      return 1
    fi
    POOLWIT_AID=$(HOME="$POOLWIT_DIR" KERI_HOME="$POOLWIT_DIR" \
                    kli status --name poolwit --alias pw 2>/dev/null \
                  | grep -oE "Identifier:[[:space:]]*[A-Za-z0-9_-]+" \
                  | awk '{print $2}' | head -1)
    [ -z "$POOLWIT_AID" ] && sleep 0.5
  done
  # Ready = the OOBI serves AND carries the /loc/scheme endpoint reply.
  while true; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      say "ERROR: pool witness OOBI not serving /loc/scheme in ${READY_TIMEOUT}s"
      return 1
    fi
    if curl -sS -m 2 "http://127.0.0.1:$POOLWIT_HTTP/oobi/$POOLWIT_AID/controller" \
         2>/dev/null | grep -q "/loc/scheme"; then
      break
    fi
    sleep 0.5
  done
  say "pool witness $POOLWIT_AID serving OOBI with /loc/scheme"
}
wait_for_poolwit
export KERI_POOLWIT_AID="$POOLWIT_AID"
export KERI_POOLWIT_OOBI="http://127.0.0.1:$POOLWIT_HTTP/oobi/$POOLWIT_AID/controller"

# ── spawn keria ────────────────────────────────────────────────────────────
say "starting keria (admin=$KERIA_ADMIN_PORT http=$KERIA_AGENT_PORT boot=$KERIA_BOOT_PORT)"
(
  cd "$KERIA_DATA_DIR"
  HOME="$KERIA_DATA_DIR" \
  KERI_HOME="$KERIA_DATA_DIR" \
  KERIA_PASSCODE="$KERIA_PASSCODE" \
  PYTHONUNBUFFERED=1 \
  PYTHONDONTWRITEBYTECODE=1 \
    keria start \
      --config-dir "$KERIA_CONFIG_DIR" \
      --config-file "keria.json" \
      --admin-http-port "$KERIA_ADMIN_PORT" \
      --http "$KERIA_AGENT_PORT" \
      --boot "$KERIA_BOOT_PORT" \
      --passcode "$KERIA_PASSCODE" \
      >"$KERIA_LOG" 2>&1
) &
KERIA_PID=$!

wait_for_keria() {
  local deadline=$(( $(date +%s) + READY_TIMEOUT ))
  for port in "$KERIA_ADMIN_PORT" "$KERIA_AGENT_PORT" "$KERIA_BOOT_PORT"; do
    # Require TWO consecutive successful HTTP responses with a short gap
    # between them. KERIA's Falcon app accepts TCP a moment before its
    # router is fully wired; the first HTTP call can race the second
    # phase of init and time out for Guile's strict client even though
    # curl sees a status code. Two-in-a-row is empirically enough to
    # eliminate that race in tier-A.
    local consecutive=0
    while [ "$consecutive" -lt 2 ]; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        say "ERROR: keria port $port not ready after ${READY_TIMEOUT}s"
        return 1
      fi
      if ! kill -0 "$KERIA_PID" 2>/dev/null; then
        say "ERROR: keria process died during startup"
        return 1
      fi
      if curl -sS -m 2 -o /dev/null -w "%{http_code}" \
           "http://127.0.0.1:$port/" 2>/dev/null | grep -qE '^[0-9]+$'; then
        consecutive=$(( consecutive + 1 ))
      else
        consecutive=0
      fi
      sleep 0.5
    done
    say "keria on $port up"
  done
}
wait_for_keria

# ── run the test suite ─────────────────────────────────────────────────────
say "running integration tests"
export KERIA_ADMIN_URL="http://127.0.0.1:$KERIA_ADMIN_PORT"
export KERIA_BOOT_URL="http://127.0.0.1:$KERIA_BOOT_PORT"
export KERIA_PASSCODE
export KERIA_WORK_DIR="$WORK_DIR"
export KERI_WITNESS_DEMO_PORTS="$WITNESS_PORTS"

# Force line-buffered stdout so test markers stream through `make`
# output pipes instead of piling up in a 4 KiB block buffer. The
# tier-B witness receipts can take 20-40 s per call, so without this
# the user sees an empty screen for minutes and can't diagnose hangs.
RUN_GUILE="stdbuf -oL -eL guile --no-auto-compile -L $ROOT_DIR/module -L $ROOT_DIR/tests"

# Tier-A/B real-KERIA bridge tests. This is the real green-light criterion:
# witnesses + KERIA up, the bridge round-trips boot/create-aid/registry/oobi.
# The later suites are gated on THIS passing, not on each other — they exercise
# independent surfaces and a failure in one must not mask the others.
# NB: `set -e` is in effect — a bare failing command aborts the script. Each
# test below is wrapped in an `if` (exempt from set -e) so one suite's failure
# records into EXIT_CODE without short-circuiting the independent suites after
# it.
BRIDGE_EXIT=0
if ! $RUN_GUILE "$SCRIPT_DIR/test-real-keria.scm"; then BRIDGE_EXIT=1; fi
EXIT_CODE=$BRIDGE_EXIT

# ── economic-substrate credential issuance (schemas served over OOBI) ────────
# Serve the 5 saidified schemas so KERIA can resolve them, then issue our
# work/skill/claim creds via the bridge and verify against KERIA's validator.
# Gated on the bridge being green (not on backend-live, which exercises an
# unrelated witness-backed AID path); issuance uses witnessless AIDs.
if [ $BRIDGE_EXIT -eq 0 ]; then
  SCHEMA_PORT="${SCHEMA_PORT:-7723}"
  python3 "$ROOT_DIR/tests/keri/integration/schema-server.py" \
    "$ROOT_DIR/module/localchimera/keri/schemas" "$SCHEMA_PORT" \
    >"$WORK_DIR/schema-server.log" 2>&1 &
  SCHEMA_PID=$!
  sleep 1
  say "schema-server on :$SCHEMA_PORT"
  export LOCALCHIMERA_SCHEMA_SERVER="http://127.0.0.1:$SCHEMA_PORT"
  if ! $RUN_GUILE "$SCRIPT_DIR/test-keria-issuance.scm"; then EXIT_CODE=1; fi
  kill "$SCHEMA_PID" 2>/dev/null || true
fi

# ── witnessed inception with live receipt collection ────────────────────────
# Against the POOL witness (the configured one that advertises /loc/scheme).
# Gated on the bridge being green, independent of the other suites.
if [ $BRIDGE_EXIT -eq 0 ]; then
  if ! $RUN_GUILE "$SCRIPT_DIR/test-witness-receipts.scm"; then EXIT_CODE=1; fi
fi

exit "$EXIT_CODE"
