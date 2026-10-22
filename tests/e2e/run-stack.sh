#!/usr/bin/env bash
# tools/dev/run-stack.sh — bring the light adopted stack up and run the
# live parity legs end to end. The honest e2e for the delegate seams:
# services that answer get a green leg; services not up get a loud skip,
# never a silent pass.
#
#   bash tools/dev/run-stack.sh           # light subset (no secrets needed)
#   bash tools/dev/run-stack.sh --full    # whole compose (needs .env secrets)
#
# The light subset is what runs without credentials: ntfy, OPA, Fuseki,
# Radicale, and the CP-SAT sidecar. Postgres-backed services (Odoo,
# Decidim, cc-node), LiteLLM's model backend, and the brokered services
# (Wasimoff, wasmCloud, Temporal, ActivityPub) stay deployment-dependent —
# the parity legs for them skip loudly.

set -euo pipefail
cd "$(dirname "$0")/../.."

COMPOSE="docker compose -f deploy/adopted-stack.docker-compose.yml"
DEV=${PLAYNET_DEV_CONTAINER:-playnet-compute-dev}
mode="${1:---light}"

# ── bring services up ────────────────────────────────────────────────────
# Whatever already listens on a published port counts as up — the dev
# containers on this box were started ad-hoc, not via compose, and
# recreating them would collide on ports.
up()     { curl -sf -m 2 -o /dev/null "$1" 2>/dev/null; }
up_any() { # any HTTP answer (even 404) proves the listener is there
  curl -s -m 2 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null | grep -qE '[0-9]'; }

if [ "$mode" = "--full" ]; then
  echo "== full stack (compose interpolates secrets from the env) =="
  $COMPOSE up -d
else
  echo "== light stack: ntfy opa fuseki radicale cpsat =="
  # FUSEKI_ADMIN_PASSWORD is the only secret the light subset interpolates;
  # a throwaway suffices — this stack is for tests, not custody.
  # compose interpolates EVERY service's secrets even when starting a
  # subset — satisfy them all with throwaways for the light run
  FUSEKI_ADMIN_PASSWORD=${FUSEKI_ADMIN_PASSWORD:-parity-dev} \
  POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-parity-dev} \
  POSTGRES_USER=${POSTGRES_USER:-parity} \
  CC_NODE_DB=${CC_NODE_DB:-parity-dev} \
  DECIDIM_SECRET_KEY_BASE=${DECIDIM_SECRET_KEY_BASE:-parity-dev} \
  LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY:-parity-dev} \
  OPENAI_API_KEY=${OPENAI_API_KEY:-parity-dev} \
  $COMPOSE up -d ntfy opa fuseki radicale cpsat 2>&1 | tail -5 || \
    echo "(compose reported an error — continuing with whatever is up)"
fi

# ── wait for readiness ───────────────────────────────────────────────────
wait_for() {  # name url [probe]
  local name=$1 url=$2 probe=${3:-up}
  for i in $(seq 60); do
    if $probe "$url"; then echo "  $name ready ($url)"; return 0; fi
    sleep 1
  done
  echo "  $name NOT READY — its legs will skip loudly"
  return 1
}

ready=""
wait_for ntfy     "http://localhost:2586/"              && ready="$ready ntfy"     || true
wait_for opa      "http://localhost:8181/"              && ready="$ready opa"      || true
wait_for fuseki   "http://localhost:3030/\$/ping"       && ready="$ready fuseki"   || true
wait_for radicale "http://localhost:5232/"              && ready="$ready radicale" || true
wait_for cpsat    "http://localhost:5000/" up_any       && ready="$ready cpsat"    || true

# ── export the delegate endpoints ────────────────────────────────────────
# The dev container runs the suites; containers on the default bridge
# reach each other by IP, not by compose DNS name — resolve them.
ip_of() { # first running container whose name contains the svc name
  local name
  name=$(docker ps --format '{{.Names}}' | grep -i "$1" | head -1) || true
  [ -n "$name" ] && docker inspect     -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" 2>/dev/null; }

env_args=()
for svc in $ready; do
  ip=$(ip_of "$svc") || true
  case $svc in
    ntfy)     [ -n "$ip" ] && env_args+=(-e "PLAYNET_NTFY_URL=http://$ip:80") ;;
    opa)      [ -n "$ip" ] && env_args+=(-e "PLAYNET_OPA_URL=http://$ip:8181") ;;
    fuseki)   [ -n "$ip" ] && env_args+=(-e "PLAYNET_JENA_URL=http://$ip:3030") ;;
    radicale) [ -n "$ip" ] && env_args+=(-e "PLAYNET_RADICALE_URL=http://$ip:5232") ;;
    cpsat)    if [ -n "$ip" ]; then
                env_args+=(-e "PLAYNET_CPSAT_URL=http://$ip:5000")
              else
                # sidecar running on the host itself — reach it via the
                # host's bridge address
                env_args+=(-e "PLAYNET_CPSAT_URL=http://172.17.0.1:5000")
              fi ;;
  esac
done

echo "== delegate endpoints for the dev container =="
printf '  %s\n' "${env_args[@]:-(none)}"

# ── run the parity suite inside the dev container ────────────────────────
echo "== parity legs =="
# the dev container runs guile directly — TEST_ENV's guix shell is the
# pinned path on a guix host, not here
docker exec "${env_args[@]}" -w /repo "$DEV" \
  bash -lc 'make test-parity TEST_ENV= GUILE_TEST_DEV="guile --no-auto-compile" 2>&1 | tail -80'

echo "== stack integration =="
docker exec "${env_args[@]}" -w /repo "$DEV" \
  bash -lc 'guile --no-auto-compile -L module tests/e2e/stack-integration.scm'
