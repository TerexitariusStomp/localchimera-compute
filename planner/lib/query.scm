;;; query.scm — Unified VF query facade
;;;
;;; Implements standard VF queries (inverses.md) as a single entry point
;;; over Observer, PlanStore, RecipeStore, ProcessRegistry, and AgentStore.
;;;
;;; Usage:
;;;   (define q (make-vf-queries observer plan-store recipe-store proc-reg agent-store))
;;;   (q 'event "evt-123")
;;;   (q 'inventory)
;;;   (q 'critical-path "plan-1")

(use-modules (srfi srfi-1))


;; ═════════════════════════════════════════════════════════════════════════
;; VfQueries — unified query dispatcher
;; ═════════════════════════════════════════════════════════════════════════

(define (make-vf-queries observer plan-store recipe-store proc-reg agent-store)
  "Create a query dispatcher. Call with (q 'method-name args...)."

  (lambda (method . args)
    (case method

      ;; ── Agent queries ──────────────────────────────────────────────

      ((agent)           ($ agent-store 'get-agent (car args)))
      ((all-agents)      ($ agent-store 'all-agents))
      ((agent-relationships)
       ($ agent-store 'relationships-of (car args)))
      ((agents-with-skill)
       ($ observer 'agents-with-skill (car args)))
      ((skills-of)
       ($ observer 'skills-of (car args)))

      ;; ── Event queries ──────────────────────────────────────────────

      ((event)                ($ observer 'get-event (car args)))
      ((all-events)           ($ observer 'all-events))
      ((events-for-resource)  ($ observer 'events-for-resource (car args)))
      ((events-for-process)   ($ observer 'events-for-process (car args)))
      ((events-for-agent)     ($ observer 'events-for-agent (car args)))
      ((events-with-action)   ($ observer 'events-with-action (car args)))
      ((active-events-for-resource)
       ($ observer 'active-events-for-resource (car args)))
      ((events-for-agreement) ($ observer 'events-for-agreement (car args)))
      ((unplanned-events)     ($ observer 'unplanned-events))

      ;; ── Resource queries ───────────────────────────────────────────

      ((resource)             ($ observer 'get-resource (car args)))
      ((all-resources)        ($ observer 'all-resources))
      ((inventory)            ($ observer 'inventory))
      ((enriched-inventory)   (apply (lambda rest ($ observer 'enriched-inventory . rest)) args))
      ((inventory-for-spec)   ($ observer 'inventory-for-spec (car args)))
      ((inventory-at-location) ($ observer 'inventory-at-location (car args)))
      ((inventory-for-agent)  ($ observer 'inventory-for-agent (car args)))
      ((conforming-resources) ($ observer 'conforming-resources (car args)))
      ((resources-contained-in) ($ observer 'resources-contained-in (car args)))
      ((resources-by-state)   ($ observer 'resources-by-state (car args)))

      ;; ── Batch queries ──────────────────────────────────────────────

      ((batch)                ($ observer 'get-batch (car args)))
      ((batches-for-resource) ($ observer 'batches-for-resource (car args)))

      ;; ── Fulfillment / satisfaction ─────────────────────────────────

      ((fulfillment)          ($ observer 'get-fulfillment (car args)))
      ((satisfaction)         ($ observer 'get-satisfaction (car args)))
      ((fulfilled-by)         ($ observer 'fulfilled-by (car args)))
      ((satisfied-by)         ($ observer 'satisfied-by (car args)))
      ((claim-state)          ($ observer 'get-claim-state (car args)))
      ((settled-by)           ($ observer 'settled-by (car args)))
      ((all-claims)           ($ observer 'all-claims))

      ;; ── Plan queries ───────────────────────────────────────────────

      ((plan)                 ($ plan-store 'get-plan (car args)))
      ((all-plans)            ($ plan-store 'all-plans))

      ;; ── Intent queries ─────────────────────────────────────────────

      ((intent)               ($ plan-store 'get-intent (car args)))
      ((all-intents)          ($ plan-store 'all-intents))
      ((open-intents)         ($ plan-store 'open-intents))
      ((intents-for-plan)     ($ plan-store 'intents-for-plan (car args)))
      ((intents-for-spec)     ($ plan-store 'intents-for-spec (car args)))
      ((intents-for-tag)      ($ plan-store 'intents-for-tag (car args)))
      ((offers)               ($ plan-store 'offers))
      ((requests)             ($ plan-store 'requests))

      ;; ── Commitment queries ─────────────────────────────────────────

      ((commitment)             ($ plan-store 'get-commitment (car args)))
      ((all-commitments)        ($ plan-store 'all-commitments))
      ((commitments-for-process) ($ plan-store 'commitments-for-process (car args)))
      ((commitments-for-plan)   ($ plan-store 'commitments-for-plan (car args)))
      ((commitments-for-spec)   ($ plan-store 'commitments-for-spec (car args)))
      ((commitments-for-agreement) ($ plan-store 'commitments-for-agreement (car args)))

      ;; ── Claim queries ──────────────────────────────────────────────

      ((claim)                ($ plan-store 'get-claim (car args)))

      ;; ── Agreement queries ──────────────────────────────────────────

      ((agreement)            ($ plan-store 'get-agreement (car args)))
      ((all-agreements)       ($ plan-store 'all-agreements))
      ((agreement-bundle)     ($ plan-store 'get-agreement-bundle (car args)))
      ((all-agreement-bundles) ($ plan-store 'all-agreement-bundles))

      ;; ── Proposal queries ───────────────────────────────────────────

      ((proposal)             ($ plan-store 'get-proposal (car args)))
      ((all-proposals)        ($ plan-store 'all-proposals))
      ((proposal-list)        ($ plan-store 'get-proposal-list (car args)))
      ((all-proposal-lists)   ($ plan-store 'all-proposal-lists))

      ;; ── Scenario queries ───────────────────────────────────────────

      ((scenario)             ($ plan-store 'get-scenario (car args)))
      ((all-scenarios)        ($ plan-store 'all-scenarios))
      ((scenario-definition)  ($ plan-store 'get-scenario-definition (car args)))
      ((all-scenario-definitions) ($ plan-store 'all-scenario-definitions))

      ;; ── Signal queries ─────────────────────────────────────────────

      ((signals-of-kind)      ($ plan-store 'signals-of-kind (car args)))
      ((signal-meta)          ($ plan-store 'get-meta (car args)))

      ;; ── Recipe queries ─────────────────────────────────────────────

      ((recipe)               ($ recipe-store 'get-recipe (car args)))
      ((all-recipes)          ($ recipe-store 'all-recipes))
      ((process-chain)        ($ recipe-store 'get-process-chain (car args)))
      ((recipes-for-output)   ($ recipe-store 'recipes-for-output (car args)))
      ((resource-spec)        ($ recipe-store 'get-resource-spec (car args)))
      ((process-spec)         ($ recipe-store 'get-process-spec (car args)))
      ((flows-for-process)    ($ recipe-store 'flows-for-process (car args)))

      ;; ── Process queries ────────────────────────────────────────────

      ((process)              ($ proc-reg 'get (car args)))
      ((processes-for-plan)   ($ proc-reg 'for-plan (car args)))

      ;; ── Algorithm delegations ──────────────────────────────────────

      ((trace-resource)       ($ observer 'trace-resource (car args)))

      ((critical-path)
       (critical-path (car args) plan-store proc-reg recipe-store))

      ((rollup-standard)
       (rollup-standard-cost (car args) recipe-store
         #:price-of (if (pair? (cdr args)) (cadr args) (lambda (s u) 0))))

      ((rollup-actual)
       (rollup-actual-cost (car args) observer
         #:price-of (if (pair? (cdr args)) (cadr args) (lambda (s u) 0))))

      ((cash-flow)
       (apply cash-flow-report (car args) (cadr args) (caddr args) observer plan-store
              (cdddr args)))

      ((distribute-income)
       (distribute-income (car args) observer (cadr args)))

      ;; ── Recompute ──────────────────────────────────────────────────

      ((recompute-resource)   ($ observer 'recompute-resource (car args)))
      ((record-exchange)      ($ observer 'record-exchange (car args) (cadr args)))

      (else (error (format #f "Unknown query method: ~a" method))))))
