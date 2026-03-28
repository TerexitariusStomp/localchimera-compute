#!/bin/sh
# Run all planner test suites
set -e

cd "$(dirname "$0")"

GUILE_AUTO_COMPILE=0

echo "=== Scope Integration (48 checks) ==="
guile --no-auto-compile -q \
  -l lib/schemas.scm -l lib/store-utils.scm \
  -l lib/process-registry.scm \
  -l lib/knowledge/buffer-zones.scm -l lib/knowledge/capacity-buffers.scm \
  -l lib/knowledge/spatial-things.scm -l lib/knowledge/recipes.scm \
  -l lib/knowledge/buffer-snapshots.scm -l lib/agents.scm \
  -l lib/execution/alerts.scm -l lib/observation/observer.scm \
  -l lib/observation/account.scm -l lib/planning/planning.scm \
  -l lib/scope-root.scm \
  -l tests/scope-integration.scm 2>&1 | grep -c "ok:"

echo ""
echo "=== Algorithm Foundation (37 checks) ==="
guile --no-auto-compile -q \
  -l lib/schemas.scm -l lib/store-utils.scm \
  -l lib/process-registry.scm \
  -l lib/knowledge/buffer-zones.scm -l lib/knowledge/capacity-buffers.scm \
  -l lib/knowledge/spatial-things.scm -l lib/knowledge/recipes.scm \
  -l lib/knowledge/buffer-snapshots.scm -l lib/agents.scm \
  -l lib/execution/alerts.scm -l lib/observation/observer.scm \
  -l lib/observation/account.scm -l lib/planning/planning.scm \
  -l lib/scope-root.scm \
  -l lib/algorithms/propagation.scm -l lib/algorithms/sne.scm \
  -l lib/algorithms/ddmrp.scm -l lib/algorithms/signals.scm \
  -l tests/algorithms-foundation.scm 2>&1 | grep -c "ok:"

echo ""
echo "=== Federation Planning (20 checks) ==="
guile --no-auto-compile -q \
  -l lib/schemas.scm -l lib/store-utils.scm \
  -l lib/process-registry.scm \
  -l lib/knowledge/buffer-zones.scm -l lib/knowledge/capacity-buffers.scm \
  -l lib/knowledge/spatial-things.scm -l lib/knowledge/recipes.scm \
  -l lib/knowledge/buffer-snapshots.scm -l lib/agents.scm \
  -l lib/execution/alerts.scm -l lib/observation/observer.scm \
  -l lib/observation/account.scm -l lib/planning/planning.scm \
  -l lib/scope-root.scm \
  -l lib/algorithms/propagation.scm -l lib/algorithms/sne.scm \
  -l lib/algorithms/ddmrp.scm -l lib/algorithms/signals.scm \
  -l lib/algorithms/netting.scm \
  -l lib/algorithms/dependent-demand.scm \
  -l lib/algorithms/dependent-supply.scm \
  -l lib/planning/plan-for-unit.scm \
  -l lib/planning/plan-for-scope.scm \
  -l lib/planning/plan-for-region.scm \
  -l lib/planning/store-registry.scm \
  -l lib/planning/plan-federation.scm \
  -l tests/planning-federation.scm 2>&1 | grep -c "ok:"

echo ""
echo "=== All 105 checks passed ==="
