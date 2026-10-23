;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; propagation.scm — Duration conversion, SNLT computation, flow record creation
;;;
;;; Translated from src/lib/algorithms/propagation.ts
;;; Pure functions — no actor state, no side effects.

;; Assumes schemas.scm and store-utils.scm are loaded.
;; Assumes store actors are accessible via $ within a turn.

(define-module (playnet algorithms propagation)
  #:use-module (srfi srfi-1)
  #:use-module (playnet vf schemas)
  #:use-module ((playnet vf formulas actions) #:select (inert-flow-actions))
  #:use-module (playnet utils store-utils)
  #:use-module ((playnet utils units) #:select (hours-in))
  #:use-module (goblins)
  #:export (*ms-per-day* *ms-per-hour* *ms-per-minute* *ms-per-second* *days-per-ms*
            rp-duration-ms rp-duration-days *non-consuming-actions* recipe-output-qty
            compute-snlt min-snlt-for-spec create-flow-record))




;; =========================================================================
;; Duration conversion
;; =========================================================================

(define *ms-per-day*    86400000)
(define *ms-per-hour*   3600000)
(define *ms-per-minute* 60000)
(define *ms-per-second* 1000)
(define *days-per-ms*   (/ 1 86400000))

(define (rp-duration-ms rp)
  "Convert a RecipeProcess's hasDuration to milliseconds.
   Default: 1 hour if no duration specified."
  (let ((dur (recipe-process-has-duration rp)))
    (if (not dur) *ms-per-hour*
        ;; in any unit of time the unit tables know; one they do not reads as hours
        (* (hours-in (duration-has-numerical-value dur) (duration-has-unit dur)) *ms-per-hour*))))

(define (rp-duration-days rp)
  "Convert a RecipeProcess's hasDuration to calendar days."
  (* (rp-duration-ms rp) *days-per-ms*))


;; =========================================================================
;; SNLT — Socially Necessary Labour Time
;; =========================================================================

(define *non-consuming-actions* inert-flow-actions)   ; the table's flows with no onhand effect

(define (recipe-output-qty recipe-store recipe-id spec-id)
  "Total quantity of SPEC-ID produced across a recipe's processes — the
   denominator both SNLT measures (direct here, crystallized in rollup.scm)
   divide their per-run labour by."
  (fold (lambda (rp acc)
          (let* ((flows-pair ($ recipe-store 'flows-for-process
                               (recipe-process-id rp)))
                 (outputs (cdr flows-pair)))
            (fold (lambda (f a)
                    (if (and spec-id
                             (equal? (recipe-flow-resource-conforms-to f) spec-id)
                             (recipe-flow-resource-quantity f))
                        (+ a (measure-has-numerical-value
                               (recipe-flow-resource-quantity f)))
                        a))
                  acc outputs)))
        0 ($ recipe-store 'processes-for-recipe recipe-id)))

(define (compute-snlt recipe-store recipe-id . rest)
  "Compute SNLT (hours per unit of primary output) for a recipe.
   recipe-store: actor reference (called via $).
   Returns +inf.0 for degenerate recipes (zero output)."
  (let* ((recipe ($ recipe-store 'get-recipe recipe-id))
         (spec-id (or (and (pair? rest) (car rest))
                      (and recipe (recipe-primary-output recipe)))))
    (if (not recipe) +inf.0
        (let* ((procs ($ recipe-store 'processes-for-recipe recipe-id))
               ;; Sum all work-flow effort quantities
               (total-work-hours
                 (fold (lambda (rp acc)
                         (let* ((flows-pair ($ recipe-store 'flows-for-process
                                              (recipe-process-id rp)))
                                (inputs (car flows-pair)))
                           (fold (lambda (f a)
                                   (if (eq? (recipe-flow-action f) 'work)
                                       (+ a (if (recipe-flow-effort-quantity f)
                                                 (measure-has-numerical-value
                                                   (recipe-flow-effort-quantity f))
                                                 0))
                                       a))
                                 acc inputs)))
                       0 procs))
               (total-output-qty (recipe-output-qty recipe-store recipe-id spec-id)))
          (if (<= total-output-qty 0) +inf.0
              (/ total-work-hours total-output-qty))))))

(define (min-snlt-for-spec recipe-store spec-id)
  "Minimum SNLT across all recipes producing spec-id. This is the current
   socially-necessary labor time per unit — moral depreciation applies:
   when a more efficient recipe appears, embodied-labor values drop.

   Returns +inf.0 if no recipe exists for spec or all are degenerate.
   Mirrors the SNLT-scoring pattern in dependent-demand.scm."
  (let ((recipes ($ recipe-store 'recipes-for-output spec-id)))
    (if (null? recipes) +inf.0
        (fold (lambda (r acc)
                (min acc (compute-snlt recipe-store (recipe-id r) spec-id)))
              +inf.0 recipes))))


;; =========================================================================
;; Flow record creation — scale a RecipeFlow into an Intent or Commitment
;; =========================================================================

(define (create-flow-record flow process-id direction scale-factor
                            due-date plan-id agents plan-store
                            . rest)
  "Create an Intent or Commitment from a RecipeFlow template.
   direction: 'input or 'output.
   scale-factor: multiplier for quantities.
   agents: alist with optional 'provider and 'receiver.
   If both provider and receiver known, creates Commitment; else Intent.
   Returns the created record (not yet added to any store)."
  (let* ((at-location (and (pair? rest) (car rest)))
         (provider (and agents (assq-ref agents 'provider)))
         (receiver (and agents (assq-ref agents 'receiver)))
         (rq (recipe-flow-resource-quantity flow))
         (eq (recipe-flow-effort-quantity flow))
         (scaled-rq (and rq (make-measure
                              (* (measure-has-numerical-value rq) scale-factor)
                              (measure-has-unit rq))))
         (scaled-eq (and eq (make-measure
                              (* (measure-has-numerical-value eq) scale-factor)
                              (measure-has-unit eq))))
         (input-of (if (eq? direction 'input) process-id #f))
         (output-of (if (eq? direction 'output) process-id #f))
         (id (generate-id "flow-")))
    (if (and provider receiver)
        ;; Commitment (bilateral)
        (make-commitment
          #:id id #:action (recipe-flow-action flow)
          #:input-of input-of #:output-of output-of  ;; resourceInventoriedAs (resolved at execution)
          #:resource-conforms-to (recipe-flow-resource-conforms-to flow)
          #:resource-classified-as (recipe-flow-resource-classified-as flow)
          #:resource-quantity scaled-rq #:effort-quantity scaled-eq
          #:provider provider #:receiver receiver #:due due-date  ;; temporal fields
          #:at-location at-location  ;; inScopeOf
          #:stage (recipe-flow-stage flow) #:state (recipe-flow-state flow)  ;; satisfies, clauseOf, independentDemandOf
          #:planned-within plan-id)  ;; plannedWithin, finished, availability-window
        ;; Intent (unilateral)
        (make-intent
          #:id id #:action (recipe-flow-action flow)
          #:input-of input-of #:output-of output-of  ;; resourceInventoriedAs
          #:resource-conforms-to (recipe-flow-resource-conforms-to flow)
          #:resource-classified-as (recipe-flow-resource-classified-as flow)
          #:resource-quantity scaled-rq #:effort-quantity scaled-eq  ;; availableQty, minimumQty
          #:provider provider #:receiver receiver #:due due-date  ;; temporal
          #:at-location at-location
          #:stage (recipe-flow-stage flow) #:state (recipe-flow-state flow)
          #:planned-within plan-id))))  ;; satisfies, inScopeOf, finished, availability-window
