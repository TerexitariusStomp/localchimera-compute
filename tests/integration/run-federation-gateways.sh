#!/usr/bin/env bash
# tests/integration/run-federation-gateways.sh
#
# Two gateways federated on the wire, end to end through gateway/federate.scm:
#
#   1. Gateway A boots as the federation's Granary, gateway B as its Table
#      (PLAYNET_SEED_FED), with durable scopes in its own state directory so
#      the founding commune stands the same across the boots. Each founding
#      commune is minted with a key of its own (PLAYNET_VAULT_KEY keeps its
#      bran) and signs on the wire through its scope. Each publishes its
#      berth at boot: its peer's sturdyref and the AID it speaks under.
#   2. The driver (federation-gateways-driver.scm) admits both into a signed
#      federation scope with what they trade, serves the federation's desk
#      and fold, and hands each gateway its federation.scm: its demand, the
#      federation's AID, where the desk answers.
#   3. The gateways boot again on the same state: the same berths, now with a
#      federation to answer to — each asks the desk for the spec, federates,
#      joins and settles.
#   4. Gateway B is stopped and started again once federated: it resumes at
#      the versions it kept, A notices the severed session and reaches it
#      again, and the federation is final again at the same price.
#
# FED_KEYS=dev runs the same story with scopes that hold no key (the
# synthetic backend), each gateway signing under a dev identity
# (PLAYNET_FED_SEED).
#
# Exit 0 = the driver read a final certificate before and after the restart.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source tests/integration/gateway-harness.sh
gw_setup
FED_KEYS="${FED_KEYS:-scope}"

member() {   # NAME TMPDIR PORT SEED-FED BYTE: a gateway as one member of the federation
    local keys
    if [ "$FED_KEYS" = dev ]; then
        keys="PLAYNET_FED_SEED=$5"
    else
        keys="PLAYNET_VAULT_KEY=$(printf "%02x" "$5" | awk '{ for (i = 0; i < 32; i++) printf "%s", $0 }')"
    fi
    gw_spawn "$1" "$2" "$3" PLAYNET_STATE_DIR="$2/state" PLAYNET_SCOPES_DURABLE=1 \
             PLAYNET_SEED_FED="$4" "$keys"
}
started() { grep -c "federation peer started" "$1" 2>/dev/null || true; }
wait_started() {   # NAME LOG COUNT SECONDS: until LOG says the peer started COUNT times
    local deadline=$((SECONDS + $4))
    while [ "$SECONDS" -lt "$deadline" ]; do
        [ "$(started "$2")" -ge "$3" ] && { echo "  $1: federation peer started"; return 0; }
        sleep 1
    done
    echo "  $1 never started its peer; federation lines:"
    grep -i "federation" "$2" | tail -20 | sed 's/^/    /'
    return 1
}
say_federation() {
    echo "  gateway $1, federation lines:"
    grep -i "federation\|precond\|error\|exception" "$2" | tail -30 | sed 's/^/    /'
}

echo "=== federation across two gateways (keys: $FED_KEYS) ==="
echo "  A (granary) $TMPA :$PORT_A    B (table) $TMPB :$PORT_B"

# 1. the berths
member "A" "$TMPA" "$PORT_A" granary 1
member "B" "$TMPB" "$PORT_B" table 2
gw_wait_for "A" "$TMPA/federation-sref.txt" 120
gw_wait_for "B" "$TMPB/federation-sref.txt" 120
gw_stop_all
grep -h "founding commune Playnet\|federation berth" "$LOG_A" "$LOG_B" | sed 's/^ *\[gateway\]/  /'

# 2. the federation's word, its desk and its fold — the driver stays up to hear
echo "=== the federation admits both ==="
guile --no-auto-compile -L module -L . -s tests/integration/federation-gateways-driver.scm "$TMPA" "$TMPB" \
    >"$TMPA/driver.log" 2>&1 &
DRIVER=$!
PIDS+=("$DRIVER")
gw_wait_for "driver" "$TMPA/specs-written" 120
grep "^driver:" "$TMPA/driver.log" | tail -4 | sed 's/^/  /'

# 3. the gateways again, on the same state: now peers of the federation
echo "=== the gateways boot again, federated ==="
member "A" "$TMPA" "$PORT_A" granary 1
member "B" "$TMPB" "$PORT_B" table 2
PID_B=$GW_PID
if ! gw_wait_for "driver" "$TMPA/settled" 700; then
    grep "^driver:" "$TMPA/driver.log" | tail -12 | sed 's/^/  /'
    say_federation A "$LOG_A"; say_federation B "$LOG_B"
    exit 1
fi
grep "^driver:" "$TMPA/driver.log" | tail -2 | sed 's/^/  /'

# 4. B stopped and started again, once federated
echo "=== gateway B restarts, federated ==="
reaches_before=$(grep -c "federation (flour .* ok)" "$LOG_A" || true)
gw_stop "$PID_B"
echo '#t' > "$TMPA/stopped"
gw_wait_for "driver" "$TMPA/noted" 60
member "B" "$TMPB" "$PORT_B" table 2
wait_started "B" "$LOG_B" 2 300
echo '#t' > "$TMPA/restarted"
wait "$DRIVER" && rc=0 || rc=$?
grep "^driver:" "$TMPA/driver.log" | tail -4 | sed 's/^/  /'
reaches_after=$(grep -c "federation (flour .* ok)" "$LOG_A" || true)
echo "  A reached B $((reaches_after - reaches_before)) time(s) since the restart"
if [ "$reaches_after" -le "$reaches_before" ]; then
    echo "  A never reached B again"; rc=1
fi
if [ "$rc" -ne 0 ]; then say_federation A "$LOG_A"; say_federation B "$LOG_B"; fi
exit "$rc"
