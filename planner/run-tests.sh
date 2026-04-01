#!/bin/sh
# Run all planner test suites
# Includes original tests + ported TypeScript tests
set -e

cd "$(dirname "$0")"

export GUILE_AUTO_COMPILE=0

FAILED=0
SUITES=0

run_suite() {
  local name="$1"
  local loader="$2"
  local file="$3"

  SUITES=$((SUITES + 1))
  echo ""
  echo "=== $name ==="
  if eval "guile --no-auto-compile -q $loader -l $file" 2>&1; then
    true
  else
    echo "  *** SUITE FAILED ***"
    FAILED=$((FAILED + 1))
  fi
}

# ── Base module load chains ──────────────────────────────────────────────────

BASE="-l lib/schemas.scm -l lib/store-utils.scm \
  -l lib/process-registry.scm \
  -l lib/knowledge/buffer-zones.scm -l lib/knowledge/capacity-buffers.scm \
  -l lib/knowledge/spatial-things.scm -l lib/knowledge/recipes.scm \
  -l lib/knowledge/buffer-snapshots.scm -l lib/agents.scm \
  -l lib/execution/alerts.scm -l lib/observation/observer.scm \
  -l lib/observation/account.scm -l lib/planning/planning.scm \
  -l lib/scope-root.scm"

ALGO="$BASE \
  -l lib/algorithms/propagation.scm -l lib/algorithms/sne.scm \
  -l lib/algorithms/ddmrp.scm -l lib/algorithms/signals.scm"

FED="$ALGO \
  -l lib/algorithms/netting.scm \
  -l lib/algorithms/dependent-demand.scm \
  -l lib/algorithms/dependent-supply.scm \
  -l lib/planning/plan-for-unit.scm \
  -l lib/planning/plan-for-scope.scm \
  -l lib/planning/plan-for-region.scm \
  -l lib/planning/store-registry.scm \
  -l lib/planning/plan-federation.scm"

# load-all.scm includes miniKanren + relational planner
ALL="-L ../module -l load-all.scm"

# ═══════════════════════════════════════════════════════════════════════════
# Original test suites
# ═══════════════════════════════════════════════════════════════════════════

run_suite "Scope Integration"        "$BASE" "tests/scope-integration.scm"
run_suite "Algorithm Foundation"     "$ALGO" "tests/algorithms-foundation.scm"
run_suite "Federation Planning"      "$FED"  "tests/planning-federation.scm"
run_suite "Relational Planner"       "$ALL"  "tests/relational-planner.scm"

# ═══════════════════════════════════════════════════════════════════════════
# Ported from TypeScript test suite (47 files → 16 relational test files)
# ═══════════════════════════════════════════════════════════════════════════

# -- Core planning --
run_suite "Dependent Demand"         "$ALL" "tests/test-dependent-demand.scm"
run_suite "Dependent Supply"         "$ALL" "tests/test-dependent-supply.scm"
run_suite "Netting Advanced"         "$ALL" "tests/test-netting-advanced.scm"
run_suite "Planning Store"           "$ALL" "tests/test-planning-store.scm"
run_suite "Planning Constraints"     "$ALL" "tests/test-planning-constraints.scm"

# -- Observer & actions --
run_suite "Observer Effects"         "$ALL" "tests/test-observer-effects.scm"
run_suite "VF Patterns"              "$ALL" "tests/test-vf-patterns.scm"

# -- Labor & capacity --
run_suite "Labor Capacity"           "$ALL" "tests/test-labor-capacity.scm"

# -- Signals & DDMRP --
run_suite "Signal Algebra"           "$ALL" "tests/test-signal-algebra.scm"
run_suite "DDMRP Advanced"          "$ALL" "tests/test-ddmrp-advanced.scm"

# -- Buffers & execution --
run_suite "Buffer Management"        "$ALL" "tests/test-buffer-management.scm"
run_suite "Execution Reactive"       "$ALL" "tests/test-execution-reactive.scm"

# -- Indexes --
run_suite "Indexes"                  "$ALL" "tests/test-indexes.scm"

# -- Spatial & transport --
run_suite "Spatial Transport"        "$ALL" "tests/test-spatial-transport.scm"

# -- Critical path --
run_suite "Critical Path"            "$ALL" "tests/test-critical-path.scm"

# -- Resource flows & value --
run_suite "Resource Flows"           "$ALL" "tests/test-resource-flows.scm"

# -- Federation & incremental --
run_suite "Incremental Federation"   "$FED" "tests/test-incremental-federation.scm"

# -- Workflows & track-trace --
run_suite "Workflow Recipe"          "$ALL" "tests/test-workflow-recipe.scm"

# ═══════════════════════════════════════════════════════════════════════════
# Ported from TypeScript test suite (round 2)
# ═══════════════════════════════════════════════════════════════════════════

run_suite "Account"                  "$ALL" "tests/test-account.scm"
run_suite "Value Equations & SNE"    "$ALL" "tests/test-value-equations-sne.scm"
run_suite "Mode C"                   "$ALL" "tests/test-mode-c.scm"
run_suite "Container Mediation"      "$ALL" "tests/test-container-mediation.scm"
run_suite "Recurrence"               "$ALL" "tests/test-recurrence.scm"
run_suite "Positioning Routing"      "$ALL" "tests/test-positioning-routing.scm"
run_suite "Schedule Availability"    "$ALL" "tests/test-schedule-availability.scm"
run_suite "Rollup Cost Variance"     "$ALL" "tests/test-rollup-costvar.scm"
run_suite "Federation Membership"    "$ALL" "tests/test-federation-membership.scm"

# ═══════════════════════════════════════════════════════════════════════════
# Ported from TypeScript test suite (round 3)
# ═══════════════════════════════════════════════════════════════════════════

run_suite "Composition Complexity"   "$ALL" "tests/test-composition-complexity.scm"
run_suite "Plan for Region"          "$ALL" "tests/test-plan-for-region.scm"
run_suite "Space-Time Scenario"      "$ALL" "tests/test-space-time-scenario.scm"
run_suite "Architectural Elegance"   "$ALL" "tests/test-architectural-elegance.scm"
run_suite "Snapshot Hydration"       "$ALL" "tests/test-snapshot-hydration.scm"

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "════════════════════════════════════════════"
if [ $FAILED -eq 0 ]; then
  echo "  All $SUITES test suites passed."
else
  echo "  $FAILED of $SUITES suites FAILED."
  exit 1
fi
echo "════════════════════════════════════════════"
