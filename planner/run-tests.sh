#!/bin/sh
# Run all planner test suites
set -e

cd "$(dirname "$0")"

GUILE_AUTO_COMPILE=0

# ── Shorthand for the full module load chain ──
LOAD_BASE="-l lib/schemas.scm -l lib/store-utils.scm \
  -l lib/process-registry.scm \
  -l lib/knowledge/buffer-zones.scm -l lib/knowledge/capacity-buffers.scm \
  -l lib/knowledge/spatial-things.scm -l lib/knowledge/recipes.scm \
  -l lib/knowledge/buffer-snapshots.scm -l lib/agents.scm \
  -l lib/execution/alerts.scm -l lib/observation/observer.scm \
  -l lib/observation/account.scm -l lib/planning/planning.scm \
  -l lib/scope-root.scm"

LOAD_ALGORITHMS="$LOAD_BASE \
  -l lib/algorithms/propagation.scm -l lib/algorithms/sne.scm \
  -l lib/algorithms/ddmrp.scm -l lib/algorithms/signals.scm"

LOAD_NETTING="$LOAD_ALGORITHMS \
  -l lib/algorithms/netting.scm"

LOAD_PLANNING="$LOAD_NETTING \
  -l lib/algorithms/dependent-demand.scm \
  -l lib/algorithms/dependent-supply.scm \
  -l lib/planning/plan-for-unit.scm \
  -l lib/planning/plan-for-scope.scm \
  -l lib/planning/plan-for-region.scm"

LOAD_FEDERATION="$LOAD_PLANNING \
  -l lib/planning/store-registry.scm \
  -l lib/planning/plan-federation.scm"

# Use load-all.scm for relational planner tests (includes miniKanren)
LOAD_ALL="-l load-all.scm"

TOTAL_PASS=0
TOTAL_FAIL=0

run_test() {
  local name="$1"
  local file="$2"
  local loader="$3"

  echo ""
  echo "=== $name ==="
  # Run test, count PASS/ok lines, detect failures
  if eval "guile --no-auto-compile -q -L ../module $loader -l $file" 2>&1; then
    echo "  [OK]"
  else
    echo "  [FAILED]"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  fi
}

# ── Original test suites ──

echo "=== Scope Integration ==="
guile --no-auto-compile -q \
  $LOAD_BASE \
  -l tests/scope-integration.scm

echo ""
echo "=== Algorithm Foundation ==="
guile --no-auto-compile -q \
  $LOAD_ALGORITHMS \
  -l tests/algorithms-foundation.scm

echo ""
echo "=== Federation Planning ==="
guile --no-auto-compile -q \
  $LOAD_FEDERATION \
  -l tests/planning-federation.scm

# ── Relational planner tests ──

echo ""
echo "=== Relational Planner (core) ==="
guile --no-auto-compile -q -L ../module \
  $LOAD_ALL \
  -l tests/relational-planner.scm

# ── Ported from TypeScript test suite ──

echo ""
echo "=== Dependent Demand (ported from TS) ==="
guile --no-auto-compile -q -L ../module \
  $LOAD_ALL \
  -l tests/test-dependent-demand.scm

echo ""
echo "=== Netting Advanced (ported from TS) ==="
guile --no-auto-compile -q -L ../module \
  $LOAD_ALL \
  -l tests/test-netting-advanced.scm

echo ""
echo "=== Observer Effects (ported from TS) ==="
guile --no-auto-compile -q -L ../module \
  $LOAD_ALL \
  -l tests/test-observer-effects.scm

echo ""
echo "=== Labor Capacity (ported from TS) ==="
guile --no-auto-compile -q -L ../module \
  $LOAD_ALL \
  -l tests/test-labor-capacity.scm

echo ""
echo "=== Signal Algebra (ported from TS) ==="
guile --no-auto-compile -q -L ../module \
  $LOAD_ALL \
  -l tests/test-signal-algebra.scm

echo ""
echo "=== Planning Constraints (ported from TS) ==="
guile --no-auto-compile -q -L ../module \
  $LOAD_ALL \
  -l tests/test-planning-constraints.scm

echo ""
echo "=== DDMRP Advanced (ported from TS) ==="
guile --no-auto-compile -q -L ../module \
  $LOAD_ALL \
  -l tests/test-ddmrp-advanced.scm

echo ""
echo "=== Critical Path (ported from TS) ==="
guile --no-auto-compile -q -L ../module \
  $LOAD_ALL \
  -l tests/test-critical-path.scm

echo ""
echo "════════════════════════════════════════════"
echo "  All test suites complete."
echo "════════════════════════════════════════════"
