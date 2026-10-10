#!/bin/sh
# Run all governance test suites.
#
# Every test file imports the governance modules it uses. This script cd's
# to the repo root
# so -L module resolves correctly.

set -e
cd "$(dirname "$0")/../.."

export GUILE_AUTO_COMPILE=0

FAILED=0
SUITES=0

run_suite() {
  name="$1"
  # a suite is named by its file, found in the directory of the module it
  # pins (tests/*/NAME); one carrying its own "/" is used exactly as given.
  case "$2" in
    */*) file="$2" ;;
    *)   file=$(ls tests/*/"$2") ;;
  esac

  SUITES=$((SUITES + 1))
  echo ""
  echo "=== $name ==="
  if guile --no-auto-compile -q -L module "$file" 2>&1; then
    true
  else
    echo "  *** SUITE FAILED ***"
    FAILED=$((FAILED + 1))
  fi
}

# ── Governance suites ───────────────────────────────────────────────────────

run_suite "Ballot + Delegation + Override"  "test-ballot.scm"
run_suite "Voice snapshot from account-store" "test-snapshot.scm"
run_suite "Gateway-facing governance service" "test-integration.scm"
run_suite "Commune (4-seal faceted ops)"      "test-commune.scm"
run_suite "Expression (weighted distribution, per-domain)" "test-expression.scm"
run_suite "Demand → proposal (weighted voice → VF)" "test-demand-to-proposal.scm"
run_suite "Demand aggregation (elaborate + merge)" "test-demand-aggregation.scm"
run_suite "Demand unification (partial terms)"    "test-demand-unification.scm"
run_suite "Demand critique (solvability)"         "test-demand-critique.scm"
run_suite "Demand fold (declared needs → planner demand)" "test-demand-fold.scm"
run_suite "Demand fold's own horizon + home-of, through a real solve" "tests/economy/test-demand-scope-horizon.scm"
run_suite "Labour passes tenure: a skill is its holder's capacity, a bike waits for its lend" "tests/doors/test-labour-under-tenure.scm"
run_suite "Skill standing: a claim beside the people who co-signed the work" "test-skill-standing.scm"
run_suite "Contest work: the absence claim, ratified by producer voice with the worker left out" "test-contest-work.scm"
run_suite "Socialization auto-applied at the scope level" "tests/economy/test-plan-commune-scope.scm"
run_suite "Affected-interest (advisory)"      "test-affected-interest.scm"
run_suite "Federation (recursive scope)"      "test-federation.scm"
run_suite "Guardianship (documentary)"        "test-guardianship.scm"
run_suite "ACDC credentials + mandate DSL"    "test-credentials.scm"
run_suite "Recovery round-trip from ACDCs"    "test-recovery.scm"
run_suite "Cross-vat async federation"        "test-async-federation.scm"
run_suite "Bootstrap ceremony + Shamir"       "test-bootstrap.scm"
run_suite "Cross-server OCapN federation"     "test-cross-server.scm"
run_suite "KERI-signed stances (Ed25519)"     "test-keri-stance.scm"
run_suite "Fulfillment chain (work→commitment SAID)" "test-fulfillment-chain.scm"
run_suite "Unified ^scope (kind dispatch + recomposition)" "test-scope-unified.scm"
run_suite "Scope brand (rejects fake counterparties)" "test-scope-brand.scm"
run_suite "Intent ACDC + VF triad linkage"    "test-intent-acdc.scm"
run_suite "KERI backend dispatch (merge/split)" "test-keri-backend.scm"
run_suite "Recover lineage from recomposition ACDCs" "test-recover-lineage.scm"
run_suite "First Person (PHC/VRC/trust triangle)" "test-first-person.scm"
run_suite "First Person on the library alone (shape, queries, I2I, signed VRCs)" "tests/keri/test-first-person.scm"
run_suite "FP portability (export/import + disk)" "tests/keri/test-fp-portability.scm"
run_suite "Personhood policy, read bare (defaults + effective-k)" "tests/keri/test-personhood-policy.scm"
run_suite "FP present-phc ingest (SAID binding + graft reject)" "test-fp-present-phc.scm"
run_suite "Enrollment ceremony (k-of-n witness co-sign)" "test-enrollment-ceremony.scm"
run_suite "Sponsor fan-out cap (rate-limit on invite)" "test-sponsor-fanout.scm"
run_suite "Sybil detector (sponsor anomaly + clique)" "tests/keri/test-sybil-detect.scm"
run_suite "Custody attestation + transfer ACDCs" "test-custody.scm"
run_suite "Custody integration (^scope issuance + transfer)" "test-custody-integration.scm"
run_suite "Structural invariants (leaves-are-real)" "test-structural-invariants.scm"
run_suite "Auditor + half-life watcher (Phase 1)" "test-auditor.scm"
run_suite "Commitment fulfillment + spec hierarchy (Phase 2)" "test-fulfillment.scm"
run_suite "Redistribution mandate + breach detection (Phase 4)" "test-redistribution.scm"
run_suite "End-to-end smoke (genesis → breach → recover)" "test-end-to-end.scm"
run_suite "Recomposition ratification (Phase 6)" "test-recomposition-ballot.scm"
run_suite "Bottom-up merge (democracy-on-keri §4.3)" "test-bottom-up-merge.scm"
run_suite "Scope persistence (durable acdc + kel + bran)" "test-scope-persistence.scm"
run_suite "Scope-graph reactive topology view"          "test-scope-graph.scm"
run_suite "Universal-commune kind dispatch + singularity" "test-universal-commune-kind.scm"
run_suite "Cross-gateway UC reconciliation (collision → proposed merge)" "test-uc-reconciliation.scm"
run_suite "Scope signs the PHCs it issues (autonomous signer)" "test-scope-phc-signing.scm"
run_suite "Two-graph cross-recognition (multi-root + merge lineage)" "test-fp-two-graph.scm"
run_suite "Multisig (k-of-n) credential signing" "test-multisig-credential.scm"
run_suite "Client-side citizen signing (stance/delegation/mandate + verifier)" "test-client-signing.scm"
run_suite "Plan-part stance (a hand)"   "test-part-stance.scm"
run_suite "Scope declarations (span, hosting, regime)" "test-scope-declarations.scm"
run_suite "Contrary observation (a reading against the map)" "test-contrary-observation.scm"
run_suite "Index-oracle issuer-signed observations" "test-index-oracle-signing.scm"
run_suite "Contact points (user-held, gateway-custodied)" "test-contact-point.scm"
run_suite "Open-terminal/get-mailbox gated on a live PHC" "test-open-terminal-mailbox-gate.scm"
run_suite "rotate-keys: real build-rot SAID, chained, signed by the pre-committed next-key" "test-rotate-keys-signing.scm"
run_suite "Temporary socialization (custody moves, the right stays)" "test-temporary-socialization.scm"
run_suite "Socialization: a flat contribution clause" "test-socialization-contribution.scm"
run_suite "Body credential: the vLEI-shaped chain root → AIC → body → role" "test-body-credential.scm"
run_suite "Body bundle: a body credential and a chained role presented across gateways" "test-body-present-bundle.scm"

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════"
if [ $FAILED -eq 0 ]; then
  echo "  All $SUITES governance test suites passed."
else
  echo "  $FAILED of $SUITES governance suites FAILED."
  exit 1
fi
echo "════════════════════════════════════════════"
