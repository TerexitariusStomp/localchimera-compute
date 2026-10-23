# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/integration/gateway-harness.sh — two real gateways as subprocesses.
#
# Sourced by the integration scripts that boot `guile -s server/gateway.scm`
# processes: disjoint state directories and ports, a spawn that takes the
# environment the story needs, a wait on a file a gateway writes, and the
# cleanup that kills whatever was spawned and removes the directories on
# every exit.
#
#   gw_setup                      TMPA TMPB PORT_A PORT_B LOG_A LOG_B, and the trap
#   gw_spawn NAME TMPDIR PORT VAR=VALUE…   a gateway with those variables in its environment; GW_PID its pid
#   gw_stop PID                   that one gateway, stopped
#   gw_wait_for NAME FILE SECONDS  until FILE is there, or the gateway's log tail and 1
#   gw_stop_all                    every spawned gateway, stopped

PIDS=()

gw_cleanup() {
    local rc=$?
    for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done
    sleep 0.5
    for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true; done
    rm -rf "${TMPA:-}" "${TMPB:-}"
    exit "$rc"
}

gw_setup() {
    TMPA=$(mktemp -d -t playnet-gw-a.XXXXXX)
    TMPB=$(mktemp -d -t playnet-gw-b.XXXXXX)
    PORT_A=$((9100 + RANDOM % 800))
    PORT_B=$((9100 + RANDOM % 800))
    while [ "$PORT_A" -eq "$PORT_B" ]; do PORT_B=$((9100 + RANDOM % 800)); done
    LOG_A="$TMPA/gateway.log"
    LOG_B="$TMPB/gateway.log"
    trap gw_cleanup EXIT INT TERM
}

gw_spawn() {
    local name="$1" tmpdir="$2" port="$3"; shift 3
    env PLAYNET_DATA_DIR="$tmpdir" \
        LTDL_LIBRARY_PATH="${GUIX_ENVIRONMENT:+$GUIX_ENVIRONMENT/lib}${LTDL_LIBRARY_PATH:+:$LTDL_LIBRARY_PATH}" \
        "$@" \
        guile --no-auto-compile -L module -L . -s server/gateway.scm --host 127.0.0.1 --port "$port" \
        >>"$tmpdir/gateway.log" 2>&1 &
    GW_PID=$!
    PIDS+=("$GW_PID")
    echo "  $name spawned → :$port (pid $GW_PID)"
}

gw_stop() {
    kill "$1" 2>/dev/null || true
    sleep 1
    kill -9 "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}

gw_wait_for() {
    local name="$1" file="$2" deadline=$((SECONDS + $3))
    while [ "$SECONDS" -lt "$deadline" ]; do
        [ -s "$file" ] && { echo "  $name: $(basename "$file") is there"; return 0; }
        sleep 0.5
    done
    echo "  $name never wrote $(basename "$file"); last log lines:"
    tail -30 "$(dirname "$file")/gateway.log" | sed 's/^/    /'
    return 1
}

gw_stop_all() {
    for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done
    sleep 1
    for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true; done
    PIDS=()
}
