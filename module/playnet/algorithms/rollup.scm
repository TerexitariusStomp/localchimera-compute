;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; rollup.scm — Cost rollup in crystallized SNLT, and substance metabolism.
;;;
;;; Spec: docs/playnet.typ §"Inter-scope propagation" (the dual ledgers),
;;;       §"Metabolic coherence".
;;;
;;; Two metabolic axes:
;;;
;;; 1. Labour metabolism — denominated in *crystallized SNLT* (the total
;;;    labour congealed in a unit). Work flows contribute effort-quantity
;;;    directly (already hours = SNLT_direct at this stage); non-work flows
;;;    contribute qty × SNLT_cryst(spec). Human time — abstract labour.
;;;    (The surface's *area* is SNLT_direct alone; this rollup yields the
;;;    crystallized measure used for credit and recipe-sizing.)
;;;
;;; 2. Material metabolism — substance-denominated throughput in the units
;;;    of the physical substance itself (kg, m³, MJ, tCO2e, etc.). This
;;;    captures what nature gives, regardless of labour content.

(define-module (playnet algorithms rollup)
  #:use-module (playnet vf formulas actions)
  #:use-module (srfi srfi-1)
  #:use-module (playnet utils units)
  #:use-module (playnet algorithms propagation)
  #:use-module (playnet vf schemas)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (playnet utils store-utils)
  #:use-module (playnet algorithms rollup common)
  #:use-module (playnet algorithms rollup relative-snlt)
  #:use-module (playnet algorithms rollup fixpoint)
  #:export (flow-snlt-cost flow-substance-qty flow-substance-costs
            rollup-standard-cost crystallized-snlt-for-spec
            recipe-unit-snlt rollup-actual-cost cost-variance)
  #:re-export (rollup-producers-of))



;; ===========================================================================
;; Labour metabolism — SNLT
;; ===========================================================================

(define* (flow-snlt-cost recipe-store action spec rq eq scale
                         #:optional (price-spec #f))
  "Hours of embodied labor for a single flow.
   - work + effort-quantity: hours directly.
   - non-work + spec + resource-quantity: qty × PRICE-SPEC(spec).
   - else: 0.
   PRICE-SPEC prices an input spec in hours/unit; it defaults to the DIRECT
   measure (min-snlt-for-spec — one level of embodiment). Pass the
   crystallized pricer to make the rollup transitive."
  (cond
    ((and (eq? action 'work) eq)
     (* (measure-has-numerical-value eq) scale))
    ((and spec rq)
     (let ((snlt ((or price-spec
                      (lambda (s) (min-snlt-for-spec recipe-store s)))
                  spec)))
       (if (= snlt +inf.0) 0
           (* (measure-has-numerical-value rq) scale snlt))))
    (else 0)))

;; ===========================================================================
;; Material metabolism — substance quantities
;; ===========================================================================

(define (flow-substance-qty rq)
  "Extract substance-denominated quantity from a resource-quantity measure.
   Returns (substance . base-qty) for material flows, or #f for:
   - no resource-quantity
   - unrecognized unit
   - time units (those belong in labour metabolism)
   Example: (cons 'mass 1500) for 1.5 tonnes of compost."
  (and rq
       (let* ((qty (measure-has-numerical-value rq))
              (unit (measure-has-unit rq))
              (substance (unit->substance unit)))
         (and (not (eq? substance 'time))
              (not (eq? substance 'other))
              (> qty 0)
              (cons substance (convert-unit qty unit))))))

(define (flow-substance-costs resource-quantity effort-quantity)
  "Extract both labour and material metabolic quantities from an event.
   Returns: ((labour . hours) (substance . (cat . base-qty)) | #f).
   Labour comes from effort-quantity (work) or is #f for non-work.
   Substance comes from resource-quantity unit classification."
  (let ((labour (and effort-quantity
                     (measure-has-numerical-value effort-quantity)))
        (substance (flow-substance-qty resource-quantity)))
    `((labour . ,(or labour 0))
      (substance . ,substance))))

(define* (rollup-standard-cost recipe-id recipe-store
                               #:key (scale-factor 1) (price-spec #f))
  "Standard cost from recipe in SNLT hours: sum input flow costs per stage.
   Returns alist: ((total . hours) (by-stage . list)).
   PRICE-SPEC (hours/unit for an input spec) threads to flow-snlt-cost —
   default direct, pass the crystallized pricer for the transitive rollup."
  (let* ((chain ($ recipe-store 'get-process-chain recipe-id))
         (stages
           (map (lambda (rp)
                  (let* ((pid (recipe-process-id rp))
                         (flows ($ recipe-store 'flows-for-process pid))
                         (inputs (car flows))
                         (stage-cost
                           (fold (lambda (f acc)
                                   (+ acc (flow-snlt-cost
                                            recipe-store
                                            (recipe-flow-action f)
                                            (recipe-flow-resource-conforms-to f)
                                            (recipe-flow-resource-quantity f)
                                            (recipe-flow-effort-quantity f)
                                            scale-factor
                                            price-spec)))
                                 0 inputs)))
                    `((process-id . ,pid) (name . ,(recipe-process-name rp))
                      (cost . ,stage-cost))))
                chain)))
    `((total . ,(fold (lambda (s acc) (+ acc (assq-ref s 'cost))) 0 stages))
      (by-stage . ,stages))))

;; ── SNLT_crystallized per spec — the credit measure ─────────────────────────
;; playnet.typ: "credit and recipe-sizing use SNLT_crystallized (the total
;; congealed in a unit)"; the surface's areas keep SNLT_direct. The rollup is
;; `crystallize` (rollup/fixpoint.scm) — the Leontief adjoint ℓ̂ = Tᵀℓ iterated to
;; its fixpoint, the cheapest producer taken at every node (moral depreciation), a
;; joint recipe's effort split across its co-products by relative standalone SNLT.
;; The engine's `good-labour-content` runs the same kernel over its templates, so
;; the account layer (pool K, effective-price) and the claim path price a good at
;; the number the plan reports for it. Read over recipe topology, so it needs no
;; solve; producers are found by NET output (a co-product is reachable as an
;; output), and a cycle — corn sown to grow corn — converges to the adjoint's own
;; value. A spec no recipe produces is +inf.0 at the top (unreachable is a real
;; answer) and contributes 0 as an input (flow-snlt-cost's convention — no labour
;; basis). Locked by tests/scope/test-joint-production.scm and
;; test-snlt-order-invariance.scm.

(define (crystallized-snlt-for-spec recipe-store spec-id)
  "Total labour congealed in one unit of SPEC-ID, in hours: direct work
   plus, transitively, the crystallized labour of every material input.
   Co-products of a joint recipe receive their relative-SNLT share.
   +inf.0 when no recipe produces the spec."
  (hash-ref (crystallize (recipe-alternatives recipe-store #:from spec-id))
            spec-id +inf.0))

(define (recipe-unit-snlt recipe-store rid spec price)
  "Per-unit crystallized SNLT that RID imputes to SPEC, pricing inputs through
   PRICE. Sole net output → the recipe's whole effort over its quantity; several
   → that output's relative-SNLT share. #f when RID does not deliver SPEC."
  ;; An unpriceable input contributes nothing — that convention lives in ONE
  ;; place, `rollup-input-price` in rollup/common.scm, which every variant reads
  ;; inputs through. Do not re-guard it here.
  (let ((nout (false-if-exception (recipe-net-outputs recipe-store rid))))
    (cond
      ;; joint: split the one cost across the several outputs
      ((and (pair? nout) (> (length nout) 1))
       (rollup-relative-snlt-for recipe-store rid spec #:price price))
      ;; single net output (or a store that cannot report them): as before
      (else
        (let ((outq (recipe-output-qty recipe-store rid spec)))
          (and (> outq 0)
               (/ (assq-ref (rollup-standard-cost rid recipe-store #:price-spec price)
                            'total)
                  outq)))))))

(define (rollup-actual-cost resource-id observer recipe-store)
  "Actual cost in SNLT hours from recorded events: trace backward through
   the produce events that yielded RESOURCE-ID, then sum input event
   costs across those producing processes.
   Returns alist: ((total . hours) (by-event . list))."
  (let* ((produce-events
           (filter (lambda (e) (memq (economic-event-action e) creating-actions))
                   ($ observer 'events-for-resource resource-id)))
         (proc-ids
           (delete-duplicates
             (filter-map economic-event-output-of produce-events)))
         ;; events-for-process is the observer's own index (idx-by-process,
         ;; keyed by both input-of and output-of) — the candidate set it
         ;; gives is already bounded to events touching PROC-IDS, instead of
         ;; filtering the WHOLE event log (which only grows) for every
         ;; resource whose actual cost is rolled up. One event can be
         ;; indexed under two different pids (input-of one, output-of
         ;; another) when both are in PROC-IDS, so the union is
         ;; deduplicated by event id before the same filter applies —
         ;; exactly the set all-events would have filtered to, never more.
         (candidate-events
           (delete-duplicates
            (append-map (lambda (pid) ($ observer 'events-for-process pid)) proc-ids)
            (lambda (a b) (equal? (economic-event-id a) (economic-event-id b)))))
         (input-events
           (filter (lambda (e)
                     (and (economic-event-input-of e)
                          (member (economic-event-input-of e) proc-ids)
                          (memq (economic-event-action e)
                                (append using-up-actions (filter input-action? inert-flow-actions)))))   ; every input a process takes
                   candidate-events))
         (entries
           (map (lambda (e)
                  (let* ((spec (economic-event-resource-conforms-to e))
                         (rq (economic-event-resource-quantity e))
                         (eq (economic-event-effort-quantity e))
                         (cost (flow-snlt-cost recipe-store
                                               (economic-event-action e)
                                               spec rq eq 1)))
                    `((event-id . ,(economic-event-id e))
                      (spec-id . ,spec)
                      (qty . ,(cond (rq (measure-has-numerical-value rq))
                                    (eq (measure-has-numerical-value eq))
                                    (else 0)))
                      (cost . ,cost))))
                input-events)))
    `((total . ,(fold (lambda (entry acc) (+ acc (assq-ref entry 'cost))) 0 entries))
      (by-event . ,entries))))

(define (cost-variance standard actual)
  "variance = standard - actual (hours; positive = under budget)."
  (let ((std (assq-ref standard 'total))
        (act (assq-ref actual 'total)))
    `((variance . ,(- std act))
      (variance-pct . ,(if (> std 0) (* (/ (- std act) std) 100) 0)))))
