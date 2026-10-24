#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# localchimera-liveness.sh — publish a per-host MQTT heartbeat every 30 s.
#
# Run as the localchimera-liveness Shepherd service (see deploy/machines.scm).
# Reads identity from /etc/localchimera/{host-id,provider-tag} (written by
# bootstrap-debian.sh) and publishes JSON to
#   localchimera/signals/liveness/<host-id>
# which fleet-bridge subscribes to in order to mark stale providers
# unhealthy. If the identity files are missing the script falls back to
# `hostname` and `unknown` — which still keeps liveness flowing but
# makes the rotor lump every "unknown" host together.

set -uo pipefail   # not -e: the inner mosquitto_pub must not kill the loop.

HOST_ID="$(cat /etc/localchimera/host-id 2>/dev/null || hostname)"
PROVIDER="$(cat /etc/localchimera/provider-tag 2>/dev/null || echo unknown)"
PW="$(cat "${LOCALCHIMERA_DATA_DIR:-/var/lib/localchimera}/mosquitto/pw-liveness.txt")"
INTERVAL="${LOCALCHIMERA_LIVENESS_INTERVAL_SEC:-30}"
TOPIC="localchimera/signals/liveness/$HOST_ID"

while true; do
    payload="$(printf '{"ts":%d,"host":"%s","provider":"%s"}' \
                      "$(date +%s)" "$HOST_ID" "$PROVIDER")"
    mosquitto_pub -h localhost -p 1883 \
                  -u liveness -P "$PW" \
                  -t "$TOPIC" \
                  -m "$payload" 2>/dev/null || true
    sleep "$INTERVAL"
done
