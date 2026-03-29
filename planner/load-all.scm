;;; load-all.scm — Load all planner modules in dependency order
;;;
;;; Usage: guile --no-auto-compile -q -l load-all.scm
;;;        or from within a script: (load "load-all.scm")

;; Layer 0: Records + utilities
(load "lib/schemas.scm")
(load "lib/store-utils.scm")

;; Layer 1: Store actors
(load "lib/process-registry.scm")
(load "lib/knowledge/buffer-zones.scm")
(load "lib/knowledge/capacity-buffers.scm")
(load "lib/knowledge/spatial-things.scm")
(load "lib/knowledge/recipes.scm")
(load "lib/knowledge/buffer-snapshots.scm")
(load "lib/knowledge/federation-recipes.scm")
(load "lib/agents.scm")
(load "lib/execution/alerts.scm")
(load "lib/observation/observer.scm")
(load "lib/observation/account.scm")
(load "lib/observation/transition.scm")
(load "lib/observation/demand-policy.scm")
(load "lib/planning/planning.scm")
(load "lib/scope-root.scm")

;; Layer 2: Core algorithms
(load "lib/algorithms/propagation.scm")
(load "lib/algorithms/sne.scm")
(load "lib/algorithms/ddmrp.scm")
(load "lib/algorithms/signals.scm")
(load "lib/algorithms/netting.scm")
(load "lib/algorithms/dependent-demand.scm")
(load "lib/algorithms/dependent-supply.scm")

;; Layer 2: Extended algorithms
(load "lib/algorithms/critical-path.scm")
(load "lib/algorithms/shortest-path.scm")
(load "lib/algorithms/network-flow.scm")
(load "lib/algorithms/flow-graph.scm")
(load "lib/algorithms/custody.scm")
(load "lib/algorithms/otif.scm")
(load "lib/algorithms/metabolism.scm")
(load "lib/algorithms/positioning.scm")
(load "lib/algorithms/track-trace.scm")
(load "lib/algorithms/value-equations.scm")
(load "lib/algorithms/rollup.scm")
(load "lib/algorithms/resource-flows.scm")

;; Layer 2: Orchestration
(load "lib/planning/plan-for-unit.scm")
(load "lib/planning/plan-for-scope.scm")
(load "lib/planning/plan-for-region.scm")

;; Planning utilities
(load "lib/planning/schedule-book.scm")
(load "lib/planning/remote-transport.scm")

;; Execution engine
(load "lib/execution/monitors.scm")
(load "lib/execution/scope-execution.scm")

;; Layer 3: Indexes
(load "lib/indexes/index-utils.scm")
(load "lib/indexes/intents.scm")
(load "lib/indexes/commitments.scm")
(load "lib/indexes/economic-events.scm")
(load "lib/indexes/economic-resources.scm")
(load "lib/indexes/independent-demand.scm")
(load "lib/indexes/independent-supply.scm")
(load "lib/indexes/membership.scm")
(load "lib/indexes/proposals.scm")
(load "lib/indexes/agents.scm")

;; Utilities
(load "lib/utils/buffer-type.scm")
(load "lib/utils/recurrence.scm")

;; Unified query facade
(load "lib/query.scm")

;; Layer 4: Federation
(load "lib/planning/store-registry.scm")
(load "lib/planning/plan-federation.scm")
