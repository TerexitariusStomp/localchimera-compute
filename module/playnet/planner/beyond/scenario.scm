;;; beyond/scenario.scm — a future the plan is held against: the planning scenario.
;;;
;;; ValueFlows has Scenario and ScenarioDefinition, groupings for analysis. Robust
;;; planning needs a scenario to carry what a future does and how likely it is.
;;; The planning scenario decorates a vf:Scenario with that: its probability, the
;;; yield multipliers that make it concrete, and its place in a scenario tree.
;;;
;;; Route into the core (docs/planning/codebase-organization.md §7): the scenario
;;; itself is a vf:Scenario under a ScenarioDefinition; the stochastic weights are
;;; the part ValueFlows has no slot for.

(define-module (playnet planner beyond scenario)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils records) #:select (vf-record-type vf-record-constructor vf-record-predicate vf-record-accessor vf-record-modifier vf-record-type-name vf-record-type-fields vf-record-copier))
  #:use-module ((playnet planner vf serdes) #:select (register-vf-records!))
  #:export (<planning-scenario> %make-planning-scenario make-planning-scenario
            planning-scenario? planning-scenario-id planning-scenario-scenario
            planning-scenario-probability planning-scenario-yield-multipliers
            planning-scenario-note planning-scenario-path))

;;; PlanningScenario — a STOCHASTIC decoration of a vf:Scenario for robust
;;; planning. vf:Scenario is deliberately loose ("a grouping mechanism for
;;; flows… supports many situations"); a stochastic scenario is one such use: a
;;; single mutually-exclusive FUTURE, carrying a probability and the yield
;;; multipliers that make it concrete. The SET of these — grouped by a
;;; vf:ScenarioDefinition = "the uncertainty being planned against" — is what
;;; `plan-robust-from-records #:scenarios` consumes. A deterministic plan is the
;;; degenerate singleton {probability 1.0, no multipliers}.
;;; Fields:
;;;   id (string), scenario? (string: the vf:Scenario ID this decorates),
;;;   probability (number in [0,1] — the p_s weight; the set should sum to 1),
;;;   yield-multipliers (assoc (spec-id . factor); an output flow of a spec in
;;;                      this list has its produced quantity scaled by factor —
;;;                      e.g. drought → (("cropA" . 0.0) …); unlisted ⇒ 1.0),
;;;   note? (string),
;;;   path? (list of branch labels, OPTIONAL, default '() — a scenario TREE
;;;          position: this scenario's branch label at period 0, then period 1,
;;;          … Two scenarios are indistinguishable when DECIDING at period t iff
;;;          their paths agree on every period before t — a decision may depend
;;;          on what has been observed, never on what has not. '() for every
;;;          scenario in a set is the flat (non-tree) case: every scenario is its
;;;          own leaf under one shared root, exactly the existing robust
;;;          first-stage/recourse split. See docs/planning/solve/scenario-tree.md.
(define <planning-scenario>
  (vf-record-type 'PlanningScenario
    '((immutable id)
      (immutable scenario)
      (immutable probability)
      (immutable yield-multipliers)
      (immutable note)
      (immutable path))))

;; PATH is optional and defaults to '() so every existing 5-argument call site
;; (24 of them, across the knowledge/ bioregions and every robust test) keeps
;; working unchanged — the flat case IS the default, not a special case of it.
(define %make-planning-scenario (vf-record-constructor <planning-scenario>))
(define* (make-planning-scenario id scenario probability yield-multipliers note
                                 #:optional (path '()))
  (%make-planning-scenario id scenario probability yield-multipliers note path))
(define planning-scenario?              (vf-record-predicate   <planning-scenario>))
(define planning-scenario-id            (vf-record-accessor    <planning-scenario> 'id))
(define planning-scenario-scenario      (vf-record-accessor    <planning-scenario> 'scenario))
(define planning-scenario-probability   (vf-record-accessor    <planning-scenario> 'probability))
(define planning-scenario-yield-multipliers (vf-record-accessor <planning-scenario> 'yield-multipliers))
(define planning-scenario-note          (vf-record-accessor    <planning-scenario> 'note))
(define planning-scenario-path          (vf-record-accessor    <planning-scenario> 'path))

;; ── persistence: these records register their own types ─────────────────────
(register-vf-records!
  <planning-scenario>)
