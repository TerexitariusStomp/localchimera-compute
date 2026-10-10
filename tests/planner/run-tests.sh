#!/bin/sh
# Run all planner test suites.
#
# Every test file imports the planner via `(use-modules (playnet planner))`.
# This script cd's to the repo root so -L module resolves correctly and
# each test is addressed as tests/planner/foo.scm.

set -e
# Repo root is two levels up from tests/planner/
cd "$(dirname "$0")/../.."

export GUILE_AUTO_COMPILE=0

# The rift check, on by default in CI (playnet.typ §"the free raw"): every draw
# must be produced, stocked, or barrier-bounded. STARVED — consumed with no
# producer, stock, or barrier — fails the suite: it is a good conjuring itself,
# and the plan's default is fail-closed. EXTERNALITIES are printed, not failed:
# a spec listed in the boundless-ambient allow-list is a deliberate declaration
# (sunlight, rainfall), and the report exists so each stays a conscious choice.
export PLANNER_RAW_LINT=1

# The standing coherence check. Every defect this engine hid shared one shape: a
# program that was not what anyone thought it was, reported in numbers that looked
# fine. An infeasible solve returning its phase-I point is the general case — the
# quantities are shaped like a plan and a test reading only quantities passes. Under
# this, such a solve RAISES unless its caller passed #:allow-infeasible? #t, so
# proving something impossible stays possible while doing it by accident does not.
export PLANNER_INVARIANTS=1

FAILED=0
SKIPPED=0
SUITES=0

run_suite() {
  name="$1"
  file="tests/planner/$2"

  SUITES=$((SUITES + 1))
  echo ""
  echo "=== $name ==="
  if out=$(guile --no-auto-compile -q -L module "$file" 2>&1); then rc=0; else rc=$?; fi   # if-form: set -e safe
  echo "$out"
  # STARVED only — a good produced at NO cell and still consumed, i.e. conjuring
  # itself. STRANDED (produced somewhere, unreachable here, the prune removes
  # the draw) is a dead column worth printing, not a hole in the books, and does
  # not fail a suite.
  if [ "$rc" -eq 0 ] && echo "$out" | grep -q 'RAW-LINT.*starved'; then
    # green on its own assertions, but some good entered the account for free
    echo "  *** SUITE FAILED (RAW-LINT: a draw with no producer, stock, or barrier) ***"
    FAILED=$((FAILED + 1))
  elif [ "$rc" -eq 0 ]; then
    true
  elif echo "$out" | grep -qE 'lib(sodium|blake3|gcrypt)[^ ]*\.so|cannot open shared object'; then
    # an OPTIONAL native crypto library is absent (e.g. libblake3, or libsodium without the -dev
    # symlink) — not a code failure. Report as SKIPPED so the suite count stays honest.
    echo "  *** SUITE SKIPPED (missing native crypto library — install libsodium/libblake3) ***"
    SKIPPED=$((SKIPPED + 1))
  else
    echo "  *** SUITE FAILED ***"
    FAILED=$((FAILED + 1))
  fi
}

# ── Original test suites ─────────────────────────────────────────────────────

run_suite "Scope Integration"        "scope-integration.scm"
run_suite "Algorithm Foundation"     "algorithms-foundation.scm"
run_suite "Federation Planning"      "planning-federation.scm"
run_suite "Relational Planner"       "relational-planner.scm"

# ── Ported from TypeScript test suite ────────────────────────────────────────

# -- Core planning --
run_suite "Dependent Demand"         "test-dependent-demand.scm"
run_suite "Dependent Supply"         "test-dependent-supply.scm"
run_suite "Netting Advanced"         "test-netting-advanced.scm"
run_suite "Planning Store"           "test-planning-store.scm"
run_suite "Accept-Proposal"          "test-accept-proposal.scm"
run_suite "Social Invites"           "test-social-invite.scm"
run_suite "KERI-Gated Acceptance"    "test-keri-acceptance.scm"
run_suite "Planning Constraints"     "test-planning-constraints.scm"

# -- Observer & actions --
run_suite "Observer Effects"         "test-observer-effects.scm"
run_suite "VF Patterns"              "test-vf-patterns.scm"

# -- Labor & capacity --
run_suite "Labor Capacity"           "test-labor-capacity.scm"

# -- Signals & DDMRP --
run_suite "Signal Algebra"           "test-signal-algebra.scm"
run_suite "DDMRP Advanced"          "test-ddmrp-advanced.scm"

# -- Strategy synthesis --
run_suite "Strategy Synthesis"       "test-strategy.scm"

# -- Buffers & execution --
run_suite "Buffer Management"        "test-buffer-management.scm"
run_suite "Execution Reactive"       "test-execution-reactive.scm"

# -- Indexes --
run_suite "Indexes"                  "test-indexes.scm"
run_suite "Query Grammar"           "test-grammar.scm"
run_suite "Query Grammar v3 (table)" "test-grammar3.scm"
run_suite "Montague Composition"     "test-montague.scm"
run_suite "Frame Semantics"          "test-frames.scm"

# -- Spatial & transport --
run_suite "Spatial Transport"        "test-spatial-transport.scm"

# -- Critical path --
run_suite "Critical Path"            "test-critical-path.scm"

# -- Resource flows & value --
run_suite "Resource Flows"           "test-resource-flows.scm"

# -- Federation & incremental --

# -- Workflows & track-trace --
run_suite "Workflow Recipe"          "test-workflow-recipe.scm"

# -- Round 2 --
run_suite "Account"                  "test-account.scm"
run_suite "Hours by part (one fold)"  "test-hours-by.scm"
run_suite "Voice field properties"   "test-property-voice-field.scm"
run_suite "Voice fold (node = fold)" "test-voice-fold.scm"
run_suite "Reading fold (every source apart)" "test-reading-fold.scm"
run_suite "Reading convert (a count of a stock)" "test-reading-convert.scm"
run_suite "Thermal form door (a state is a form)" "test-thermal-form-door.scm"
run_suite "Proofing, live (a thermal step planned)" "test-proofing-live.scm"
run_suite "Water floor, live (a form that is water)" "test-water-floor-live.scm"
run_suite "Composition units, live (a row is per unit)" "test-composition-units-live.scm"
run_suite "Contrary observation (in every future)" "test-contrary-observation.scm"
run_suite "Value Equations & SNE"    "test-value-equations-sne.scm"
run_suite "Mode C"                   "test-mode-c.scm"
run_suite "Container Mediation"      "test-container-mediation.scm"
run_suite "Recurrence"               "test-recurrence.scm"
run_suite "Positioning Routing"      "test-positioning-routing.scm"
run_suite "Schedule Availability"    "test-schedule-availability.scm"
run_suite "Rollup Cost Variance"     "test-rollup-costvar.scm"
run_suite "Federation Membership"    "test-federation-membership.scm"

# -- Round 3 --
run_suite "Composition Complexity"   "test-composition-complexity.scm"
run_suite "Plan for Region"          "test-plan-for-region.scm"
run_suite "Holes"                    "test-holes.scm"
run_suite "Space-Time Scenario"      "test-space-time-scenario.scm"
run_suite "Architectural Elegance"   "test-architectural-elegance.scm"
run_suite "Orb Solve-Brief"          "test-solve-brief.scm"
run_suite "Snapshot Hydration"       "test-snapshot-hydration.scm"
run_suite "Provenance Explain"       "test-provenance-explain.scm"

# -- Food: the reclaim → store → distribute chain, and the law it folds against --
# The chain is generic (food-chain-seed.scm); Berlin is one configuration of it,
# and the jurisdiction answers through the crossing fold, not through the recipe.
run_suite "Food Cold-Chain (VF)"    "test-food-cold-chain-vf.scm"
run_suite "Food Surplus Scenario"   "food-surplus-scenario-test.scm"
run_suite "Food Distribution"       "test-food-distribution.scm"
run_suite "Berlin Food Chain"        "test-berlin-food-chain.scm"
run_suite "The three bills"          "test-bills.scm"
run_suite "Diet"                     "test-diet.scm"
run_suite "Feel the Food"           "test-feel-the-food.scm"
run_suite "Verteilstation duties"   "test-verteilstation-obligations.scm"
run_suite "Sweat, shed & acclim."   "test-sweat-shed.scm"

# -- the legal fold itself: crossings → jurisdiction → bill → decoration --
run_suite "Legal Registry Packs"    "test-legal-registry-packs.scm"
run_suite "Legal Registry Persist"  "test-legal-registry-persist.scm"
run_suite "Legal Gate"              "test-legal-gate.scm"
run_suite "Legal Gate (store)"      "test-legal-gate-store.scm"
run_suite "Legal Gate (assets+holders)" "test-legal-gate-assets.scm"
run_suite "Legal (service door)"   "test-legal-service-door.scm"
run_suite "Legal (root persist)"    "test-legal-registry-root-persist.scm"
run_suite "Legal (validity windows)" "test-legal-validity.scm"
run_suite "Legal (pack lint)"      "test-law-lint.scm"
run_suite "Legal (one fold, one reading)" "test-legal-one-fold.scm"
run_suite "Legal (crossings read off the records)" "test-crossing-derivation.scm"
run_suite "Recipe flow units"      "test-use-unit-lint.scm"
run_suite "Legal (coverage)"      "test-law-coverage.scm"
run_suite "Legal (tension)"        "test-legal-tension.scm"
run_suite "Legal Decorate"          "test-legal-decorate.scm"
run_suite "Legal (insurance)"       "test-law-insurance.scm"
run_suite "Legal (bodies)"          "test-bodies.scm"
run_suite "Legal (body service)"    "test-body-service.scm"
run_suite "Compliance"              "test-compliance.scm"
run_suite "Compliance Planner"      "test-compliance-planner.scm"
run_suite "Compliance Processes"    "test-compliance-processes.scm"


# ── Infrastructure: live-resources + capacity-managed execution ──────────────

run_suite "Live Resource"            "test-live-resource.scm"
run_suite "Host Facts"               "test-host-facts.scm"
run_suite "Host facts as counts"     "test-host-facts-counts.scm"
run_suite "Signal Publisher"         "test-signal-publisher.scm"
run_suite "Live Metabolism"          "test-live-metabolism.scm"
run_suite "Infrastructure Planning"  "test-infrastructure-planning.scm"
run_suite "Capacity Execute"         "test-capacity-execute.scm"
run_suite "Netter custody sidecar"   "test-netter-custody.scm"
run_suite "Custody fact lifting"     "test-custody-lift.scm"

# ── Skills + ACDC substrate (event-sourced, composable, distributable) ────────
run_suite "Skill credential"         "test-skill-credential.scm"
run_suite "Skill fact lifting"       "test-skill-lift.scm"
run_suite "Skill mint-on-work"       "test-skill-mint.scm"
run_suite "Skill composition"        "test-skill-compose.scm"
run_suite "Skill matching"           "test-skill-matching.scm"
run_suite "Skill practiced hours"    "test-skill-practiced.scm"
run_suite "Skill law: the engine's competence law read off the record" "test-skill-law.scm"
run_suite "Conformance recert, live"  "test-conformance-recert-live.scm"
run_suite "Work correction: a corrected work event leaves every total" "test-work-correction.scm"
run_suite "Skill conformance e2e"    "test-skill-e2e.scm"
run_suite "Intent/commitment attest" "test-intent-attest.scm"
run_suite "Completeness snapshot"    "test-state-snapshot.scm"
run_suite "Edge-chain reconstruct"   "test-edge-chain.scm"
run_suite "Settlement chain"         "test-settlement-chain.scm"
run_suite "Live scope credentialing" "test-scope-credentialing.scm"
run_suite "Journey events (arc-time)" "test-journey-events.scm"
run_suite "Confirmed move (stock)"    "test-confirmed-move.scm"
run_suite "Confirm doors"            "test-confirm-doors.scm"
run_suite "Resource records"          "test-resource-records.scm"
run_suite "Event interval"            "test-event-interval.scm"
run_suite "Mode identity"             "test-mode-identity.scm"
run_suite "Ride performed"            "test-ride-performed.scm"
run_suite "Credit integrity"          "test-credit-integrity.scm"
run_suite "Observer boundary"         "test-observer-boundary.scm"
run_suite "Observer corrections"      "test-observer-corrections.scm"
run_suite "Derived fulfilment"         "test-derived-fulfilment.scm"
run_suite "Stock ingest"                "test-stock-ingest.scm"
run_suite "Stage effect"                "test-stage-effect.scm"
run_suite "Event-time resolution"       "test-event-time-resolution.scm"
run_suite "Enact order"                 "test-enact-order.scm"
run_suite "Claim fulfilment"           "test-claim-fulfil.scm"
run_suite "VF action table (TTL)"     "vf-conformance-table-test.scm"
run_suite "VF classes (TTL)"          "vf-conformance-classes-test.scm"
run_suite "VF action effects (differential)" "vf-conformance-effects-test.scm"
run_suite "Topic chat (strata)"      "test-event-chat.scm"
run_suite "Claim over service"       "test-claim-service.scm"
run_suite "Portable event log"       "test-event-log-integration.scm"
run_suite "Matter substance-flow wire" "matter-wire-test.scm"
run_suite "Chemistry (formulas/balance)" "chemistry-test.scm"
run_suite "Reaction network (FBA)"     "reaction-network-test.scm"
run_suite "Containment cascade"        "containment-cascade-test.scm"
run_suite "Grow composition (recipe-derived)" "grow-composition-test.scm"
run_suite "Composition bridge (derive→contained-in→cascade)" "composition-bridge-test.scm"
run_suite "Cascade provenance (evented contents)" "cascade-provenance-test.scm"
run_suite "Reproduction of labour-power (live, per-person, multi-place)" "reproduction-live-vat-test.scm"
run_suite "Reproduction floor through the terminal period" "reproduction-terminal-test.scm"
run_suite "A recurring floor keeps recurring past the horizon's edge" "terminal-reserve-test.scm"
run_suite "Floor vs wall: pricing both horns of a dilemma" "test-floor-wall-dilemma.scm"
run_suite "Reproduction band: two walls on one nutrient" "test-nutrition-band.scm"
run_suite "Insurance reserve: held, in every future" "test-insurance-reserve.scm"
run_suite "Shape by side: frag on a ceiling, held on a floor, forced" "test-shape-by-side.scm"
run_suite "Granary under uncertainty: banked by the plan, sized by the tail" "test-granary-under-uncertainty.scm"
run_suite "Insurance reserve, live: the governed row, the tab" "test-insurance-live.scm"
run_suite "Inspection, live: scheduled hours, skills and means" "test-inspection-live.scm"
run_suite "The reserve's dilemma: bare need vs the calamity stock" "test-reserve-dilemma.scm"
run_suite "Floor vs wall, live: the dilemma priced on the scope's own world" "test-floor-wall-live.scm"
run_suite "Planetary limits as stocks, live" "test-limits-live.scm"

# ── Solver: the certificate and its machine-checked claims ───────────────────
# The math these check is formalized in docs/formal/solver-certificate (Lean);
# these suites hold the Scheme implementation to the theorems' postconditions.
run_suite "Solver Certificate"        "test-certificate.scm"
run_suite "KKT Verification"          "test-kkt-verification.scm"
run_suite "Solver Property Sweep"     "test-property-solver-invariants.scm"
run_suite "OSQP frag exclusion"       "test-osqp-frag-exclusion.scm"

# -- the pin book: map lists, folded like the folksonomy --
run_suite "Pin book"                  "test-pins.scm"

# ── Federation across the wire (Rung 3) ─────────────────────────────────────
# The boundary oracle reproduces solve-decomposed round for round; two communes
# in two vats clear through signed replies; a reply that is not what its signer
# said is refused. The second suite hosts one commune in a CHILD PROCESS behind
# a websocket sturdyref — the same solve across a real process boundary.
run_suite "Federation Wire"           "test-federation-wire.scm"
# the two-process suites wait on real ticks (minutes); PLAYNET_WIRE_TESTS=0 leaves them out
[ "${PLAYNET_WIRE_TESTS:-1}" != 0 ] && run_suite "Federation Wire (2 procs)" "test-federation-wire-procs.scm"

# The same solve with no coordinator and no rounds: peers messaging along the
# links, on a network that reorders, loses and repeats; then as signed actors.
run_suite "Crossing column"           "test-crossing-column.scm"
run_suite "Federation direction"      "test-federation-direction.scm"
run_suite "One citizen (partition)" "test-one-citizen.scm"
run_suite "Person doors (classified)" "test-person-doors.scm"
run_suite "Window union (one day, once)" "test-window-union.scm"
run_suite "Location lease (consent)" "test-location-lease.scm"
run_suite "Practice join (one record)" "test-practice-join.scm"
run_suite "Credit spend (one reading)" "test-credit-spend.scm"
run_suite "Witness roster (community)" "test-witness-roster.scm"
run_suite "Audit of a person (whole log)" "test-audit-person.scm"
run_suite "Crossing set (derived)"  "test-crossing-set.scm"
run_suite "Labour budget (one body)" "test-labour-budget.scm"
run_suite "Fold laws"              "test-fold-laws.scm"
run_suite "Crossing custody"        "test-crossing-custody.scm"
run_suite "Federation rotation"      "test-federation-rotation.scm"
run_suite "Federation Async"          "test-federation-async.scm"
run_suite "Federation Peer"           "test-federation-peer.scm"
[ "${PLAYNET_WIRE_TESTS:-1}" != 0 ] && run_suite "Federation Peer (2 procs)"  "test-federation-peer-procs.scm"
run_suite "Federation scope record"    "test-federation-scope-record.scm"
run_suite "Federation spec"            "test-federation-spec.scm"
run_suite "Federation desk"            "test-federation-desk.scm"
run_suite "Federation Crossing"       "test-federation-crossing.scm"

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════"
[ "$SKIPPED" -gt 0 ] && echo "  $SKIPPED of $SUITES suites SKIPPED (optional native crypto library absent)."
if [ "$FAILED" -eq 0 ]; then
  echo "  All $((SUITES - SKIPPED)) runnable test suites passed."
else
  echo "  $FAILED of $SUITES suites FAILED."
  exit 1
fi
echo "════════════════════════════════════════════"
