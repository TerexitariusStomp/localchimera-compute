#!/usr/bin/env bash
# tests/personhood/two-box/run-two-box.sh — the TWO-BOX witness harness.
#
# Two boxes, for real: two processes with their OWN PLAYNET_STATE_DIR, each
# fronted by its OWN serve-static instance, and NOTHING between them but
# HTTP — the exact shape two federated gateways share. Both ceremony kinds
# cross, in sequence: box1 opens a WORK witnessing (the ask publishes as a
# served state file), box2's poll finds it, co-signs with a key that never
# leaves its process, publishes the attest; box1's poll lands it and the
# credential strengthens to k-of-n in place. Then box1 opens an ENROLLMENT
# for a new candidate; the ask crosses as kind=enroll with candidate +
# sponsor intact, box2 vouches with the same one signing act, and the
# candidate's PHC issues on box1 carrying the remote witness as an edge.
#
#   make test-witness-two-box
#
# Everything lives under $TMPDIR; teardown on exit either way.
set -u
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/witness-2box-XXXXXX")"
D1="$WORK/box1-state"; D2="$WORK/box2-state"; SHARED="$WORK/shared"
mkdir -p "$D1" "$D2" "$SHARED"
P1="${WITNESS_P1:-8471}"; P2="${WITNESS_P2:-8472}"
GUILE="guile --no-auto-compile -L $ROOT_DIR/module -L $ROOT_DIR"

PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT INT TERM

say() { echo "[2box] $*"; }

# ── the two static tiers, one per box ───────────────────────────────────────
serve() { # serve <state-dir> <port>
  PLAYNET_STATE_DIR="$1" $GUILE \
    -c "((@ (server serve-static) run-static-server) \
         #:work-dir \"$ROOT_DIR/browser\" \
         #:oobi-dir \"$WORK/oobi\" #:port $2)" \
    >"$WORK/static-$2.log" 2>&1 &
  PIDS="$PIDS $!"
}
serve "$D1" "$P1"
serve "$D2" "$P2"

# wait for both to answer
for port in "$P1" "$P2"; do
  ok=""
  for i in $(seq 1 40); do
    if curl -fsS "http://127.0.0.1:$port/witness/requests" >/dev/null 2>&1; then
      ok=1; break
    fi
    sleep 0.25
  done
  [ -n "$ok" ] || { say "static tier on :$port never came up"; exit 1; }
done
say "two static tiers up (:$P1 :$P2)"

# ── the two drivers: witness first (it publishes its aid), worker second ────
PLAYNET_STATE_DIR="$D2" WITNESS_SHARED="$SHARED" \
  WITNESS_PEER="http://127.0.0.1:$P1" \
  $GUILE "$ROOT_DIR/tests/personhood/two-box/box2.scm" &
BOX2=$!; PIDS="$PIDS $BOX2"

PLAYNET_STATE_DIR="$D1" WITNESS_SHARED="$SHARED" \
  WITNESS_PEER="http://127.0.0.1:$P2" \
  $GUILE "$ROOT_DIR/tests/personhood/two-box/box1.scm"
B1=$?

wait "$BOX2"; B2=$?
if [ "$B1" -eq 0 ] && [ "$B2" -eq 0 ]; then
  say "PASS — both legs: work credential strengthened, candidate PHC issued with the remote vouch"
  exit 0
else
  say "FAIL (box1=$B1 box2=$B2) — logs in $WORK"
  trap - EXIT
  cleanup
  exit 1
fi
