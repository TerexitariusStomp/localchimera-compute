;;; dev-recipes.scm — VF recipes for self-improvement development tasks
;;;
;;; Models PLAN-MASTER.md priorities as ValueFlows economic activity.
;;; The planner can schedule development work, emit deficit signals,
;;; and track fulfillment — the system plans its own improvement.
;;;
;;; Resource specs: deliverables (test suites, modules, etc.)
;;; Process spec:   "code-improvement" — consumes developer-hours, produces deliverable
;;; Recipes:        one per PLAN-MASTER item
;;;
;;; Assumes schemas.scm and store-utils.scm are loaded.

;; =========================================================================
;; seed-dev-knowledge! — populate a recipe-store with development recipes
;; =========================================================================

(define (seed-dev-knowledge! rs)
  "Seed development resource specs, process specs, and recipes into RS.
   RS must be a ^recipe-store actor ref. Call within a vat context."

  ;; ── Resource specifications (deliverables) ─────────────────────────────

  ($ rs 'add-resource-spec
     (make-resource-specification
      "spec-dev-persistence-tests" "Persistence round-trip tests"
      "Bloblin persist/restore cycle for governed orgs" #f
      '("tag:dev" "tag:layer-1") "each" #f #f #f #f #f))

  ($ rs 'add-resource-spec
     (make-resource-specification
      "spec-dev-wrapper-deprecation" "Deprecated module markers"
      "Mark non-kernel modules as deprecated" #f
      '("tag:dev" "tag:kernel") "each" #f #f #f #f #f))

  ($ rs 'add-resource-spec
     (make-resource-specification
      "spec-dev-hoot-compat" "Hoot compatibility verified"
      "Kernel files compile via guild compile-wasm" #f
      '("tag:dev" "tag:kernel") "each" #f #f #f #f #f))

  ($ rs 'add-resource-spec
     (make-resource-specification
      "spec-dev-test-coverage" "Test coverage expanded"
      "Missing test suites wired into make test-all" #f
      '("tag:dev" "tag:testing") "each" #f #f #f #f #f))

  ($ rs 'add-resource-spec
     (make-resource-specification
      "spec-dev-kb-consistency" "Knowledge base consistency"
      "system-kb.scm facts match actual file paths" #f
      '("tag:dev" "tag:knowledge") "each" #f #f #f #f #f))

  ;; Developer effort (consumed by all dev tasks)
  ($ rs 'add-resource-spec
     (make-resource-specification
      "spec-dev-effort" "Developer session"
      "One Claude Code improvement session" #f
      '("tag:dev") "session" "session" #f #f #f #f))

  ;; ── Process specification ──────────────────────────────────────────────

  ($ rs 'add-process-spec
     (make-process-specification
      "pspec-code-improvement" "Code improvement"
      "Implement, test, and merge a development task" #f
      #f #f #f #f #f))

  ;; ── Recipe processes (one per task type) ───────────────────────────────

  ($ rs 'add-recipe-process
     (make-recipe-process
      "rp-implement" "Implement task"
      "Read PLAN-MASTER, implement on feature branch, run tests, open PR" #f
      "pspec-code-improvement" '("tag:dev")
      (make-duration 1 "hours") #f #f))

  ;; ── Recipe flows ───────────────────────────────────────────────────────

  ;; Input: consume one developer session
  ($ rs 'add-recipe-flow
     (make-recipe-flow
      "rf-dev-effort-in" 'consume "spec-dev-effort" #f
      (make-measure 1 "session") #f "rp-implement" #f #f #f #f #f #f #f))

  ;; Output: produce the deliverable (parameterized per recipe)
  ;; Each recipe below gets its own output flow.

  ;; ── Recipes (one per PLAN-MASTER item) ─────────────────────────────────

  ;; LAYER 1: Persistence tests
  ($ rs 'add-recipe-flow
     (make-recipe-flow
      "rf-persistence-tests-out" 'produce "spec-dev-persistence-tests" #f
      (make-measure 1 "each") #f #f "rp-implement" #f #f #f #f #f #f))
  ($ rs 'add-recipe
     (make-recipe "recipe-persistence-tests" "Implement persistence tests"
                  "PLAN-MASTER LAYER 1: Bloblin round-trip tests"
                  "spec-dev-persistence-tests" "spec-dev-persistence-tests"
                  '("rp-implement") #f))

  ;; Wrapper deprecation
  ($ rs 'add-recipe-flow
     (make-recipe-flow
      "rf-wrapper-deprecation-out" 'produce "spec-dev-wrapper-deprecation" #f
      (make-measure 1 "each") #f #f "rp-implement" #f #f #f #f #f #f))
  ($ rs 'add-recipe
     (make-recipe "recipe-wrapper-deprecation" "Mark wrappers as deprecated"
                  "Mark non-kernel modules as deprecated per revised direction"
                  "spec-dev-wrapper-deprecation" "spec-dev-wrapper-deprecation"
                  '("rp-implement") #f))

  ;; Hoot compatibility
  ($ rs 'add-recipe-flow
     (make-recipe-flow
      "rf-hoot-compat-out" 'produce "spec-dev-hoot-compat" #f
      (make-measure 1 "each") #f #f "rp-implement" #f #f #f #f #f #f))
  ($ rs 'add-recipe
     (make-recipe "recipe-hoot-compat" "Verify Hoot compatibility"
                  "Ensure kernel files compile via guild compile-wasm"
                  "spec-dev-hoot-compat" "spec-dev-hoot-compat"
                  '("rp-implement") #f))

  ;; Test coverage
  ($ rs 'add-recipe-flow
     (make-recipe-flow
      "rf-test-coverage-out" 'produce "spec-dev-test-coverage" #f
      (make-measure 1 "each") #f #f "rp-implement" #f #f #f #f #f #f))
  ($ rs 'add-recipe
     (make-recipe "recipe-test-coverage" "Expand test coverage"
                  "Wire missing test suites into make test-all"
                  "spec-dev-test-coverage" "spec-dev-test-coverage"
                  '("rp-implement") #f))

  ;; KB consistency
  ($ rs 'add-recipe-flow
     (make-recipe-flow
      "rf-kb-consistency-out" 'produce "spec-dev-kb-consistency" #f
      (make-measure 1 "each") #f #f "rp-implement" #f #f #f #f #f #f))
  ($ rs 'add-recipe
     (make-recipe "recipe-kb-consistency" "Fix KB consistency"
                  "Cross-reference system-kb.scm facts against actual file paths"
                  "spec-dev-kb-consistency" "spec-dev-kb-consistency"
                  '("rp-implement") #f))

  'dev-knowledge-seeded)
