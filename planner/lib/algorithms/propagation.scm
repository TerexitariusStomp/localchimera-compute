;;; propagation.scm — Duration conversion, SNLT computation, flow record creation
;;;
;;; Translated from src/lib/algorithms/propagation.ts
;;; Pure functions — no actor state, no side effects.

;; Assumes schemas.scm and store-utils.scm are loaded.
;; Assumes store actors are accessible via $ within a turn.

(use-modules (srfi srfi-1))


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
        (let ((val (duration-has-numerical-value dur))
              (unit (duration-has-unit dur)))
          (cond
            ((equal? unit "days")    (* val *ms-per-day*))
            ((equal? unit "hours")   (* val *ms-per-hour*))
            ((equal? unit "minutes") (* val *ms-per-minute*))
            ((equal? unit "seconds") (* val *ms-per-second*))
            (else *ms-per-hour*))))))

(define (rp-duration-days rp)
  "Convert a RecipeProcess's hasDuration to calendar days."
  (* (rp-duration-ms rp) *days-per-ms*))


;; =========================================================================
;; SNLT — Socially Necessary Labour Time
;; =========================================================================

(define *non-consuming-actions* '(use work cite deliver-service))

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
               ;; Sum primary output quantity
               (total-output-qty
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
                       0 procs)))
          (if (<= total-output-qty 0) +inf.0
              (/ total-work-hours total-output-qty))))))


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
          id (recipe-flow-action flow) #f
          input-of output-of
          #f  ;; resourceInventoriedAs (resolved at execution)
          (recipe-flow-resource-conforms-to flow)
          (recipe-flow-resource-classified-as flow)
          scaled-rq scaled-eq
          provider receiver
          #f #f #f due-date #f  ;; temporal fields
          at-location #f  ;; inScopeOf
          (recipe-flow-stage flow) (recipe-flow-state flow)
          #f #f #f  ;; satisfies, clauseOf, independentDemandOf
          plan-id #f #f)  ;; plannedWithin, finished, availability-window
        ;; Intent (unilateral)
        (make-intent
          id (recipe-flow-action flow) #f #f #f
          input-of output-of
          #f  ;; resourceInventoriedAs
          (recipe-flow-resource-conforms-to flow)
          (recipe-flow-resource-classified-as flow)
          scaled-rq scaled-eq #f #f  ;; availableQty, minimumQty
          provider receiver
          #f #f #f due-date  ;; temporal
          at-location
          (recipe-flow-stage flow) (recipe-flow-state flow)
          plan-id #f #f #f #f))))  ;; satisfies, inScopeOf, finished, availability-window
