;;; sne.scm — SNLT_crystallized: the total (embodied) labour per unit.
;;;
;;; Spec: docs/playnet.typ §"Labour, skills, and planning" — the two
;;;       socially-necessary labour times: direct vs crystallized.
;;;
;;; SNE computes *socially necessary CRYSTALLIZED labour time* — the total
;;; labour congealed in one unit of output ("crystals of social
;;; substance"). This is the value-rollup measure used for credit and
;;; recipe-sizing, NOT the surface area (which is SNLT_direct, the living
;;; labour added at THIS stage alone). Crystallized = direct + carried:
;;;   - Direct labour (work flows)                          [= SNLT_direct]
;;;   - Embodied labour (qty_consumed * SNLT_cryst of input spec)
;;;   - Equipment depreciation (duration/lifespan * SNLT_cryst of equipment)
;;;   - Excludes: cite flows (knowledge/IP, amortized near 0)
;;;
;;; Translated from src/lib/algorithms/SNE.ts. Pure functions.

;; Assumes schemas.scm, store-utils.scm, propagation.scm are loaded.

(define-module (playnet planner algorithms sne)
  #:use-module (playnet planner formulas actions)
  #:use-module (playnet planner vf schemas)
  #:use-module (playnet planner algorithms propagation)
  #:use-module (playnet planner algorithms rollup common)
  #:use-module (playnet planner algorithms rollup fixpoint)
  #:use-module (goblins)
  #:export (*non-consuming-actions-sne* compute-sne-for-recipe
            compute-recipe-sne/actor direct-sne-for-spec build-sne-index/actor)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (goblins utils hashmap))


(define *non-consuming-actions-sne* inert-flow-actions)   ; the table's: a flow that leaves the stock as it was


;; =========================================================================
;; SNE for a single recipe
;; =========================================================================

(define (compute-sne-for-recipe recipe-id output-spec-id recipe-store sne-index
                                . rest)
  "Compute SNE for one recipe. Returns effort hours per unit of output-spec-id.
   sne-index: hashmap of spec-id -> SNE, consulted for input values.
   lifespans: optional hashmap of spec-id -> lifespan-hours.
   price: optional (spec -> hours) resolver. When given it OVERRIDES the index
   for input pricing, so an input that is not yet in the index is computed on
   demand rather than silently read as 0 — see `compute-recipe-sne/actor`."
  (let* ((lifespans (and (pair? rest) (car rest)))
         (price     (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
         (input-sne-of (lambda (spec)
                         (if price (price spec) (hashmap-ref sne-index spec 0))))
         (recipe ($ recipe-store 'get-recipe recipe-id))
         (procs (if recipe ($ recipe-store 'processes-for-recipe recipe-id) '()))
         ;; Accumulate effort across all processes
         (total-effort 0)
         (total-output-qty 0))

    (for-each
      (lambda (rp)
        (let* ((pid (recipe-process-id rp))
               (flows-pair ($ recipe-store 'flows-for-process pid))
               (inputs (car flows-pair))
               (outputs (cdr flows-pair))
               (proc-duration-hours (/ (rp-duration-ms rp) *ms-per-hour*)))

          ;; Direct labor: work flows
          (for-each
            (lambda (f)
              (when (eq? (recipe-flow-action f) 'work)
                (let ((eq (recipe-flow-effort-quantity f)))
                  (when eq
                    (set! total-effort
                      (+ total-effort (measure-has-numerical-value eq)))))))
            inputs)

          ;; Embodied labor: consuming inputs (not use/cite/work)
          (for-each
            (lambda (f)
              (let ((action (recipe-flow-action f))
                    (spec (recipe-flow-resource-conforms-to f))
                    (rq (recipe-flow-resource-quantity f)))
                (when (and spec rq
                           (not (memq action *non-consuming-actions-sne*)))
                  (let ((input-sne (input-sne-of spec)))
                    (set! total-effort
                      (+ total-effort
                         (* (measure-has-numerical-value rq) input-sne)))))))
            inputs)

          ;; Equipment depreciation: use flows with lifespan.
          ;; DEPRECATED — legacy per-spec lifespan. Canonical depreciation is the
          ;; convex engine's condition-good rollup (wear × ℓ̂(Cond), moral
          ;; depreciation via min-producer; lifespan = condition ÷ per-recipe wear).
          ;; See planner.scm ~806 + test-wear-moral-depreciation.scm.
          (when lifespans
            (for-each
              (lambda (f)
                (when (eq? (recipe-flow-action f) 'use)
                  (let* ((spec (recipe-flow-resource-conforms-to f))
                         (lifespan (and spec (hashmap-ref lifespans spec #f)))
                         (equip-sne (and spec (input-sne-of spec))))
                    (when (and lifespan (> lifespan 0) equip-sne)
                      (set! total-effort
                        (+ total-effort
                           (* (/ proc-duration-hours lifespan) equip-sne)))))))
              inputs))

          ;; Output quantity for this spec
          (for-each
            (lambda (f)
              (when (and (equal? (recipe-flow-resource-conforms-to f) output-spec-id)
                         (recipe-flow-resource-quantity f))
                (set! total-output-qty
                  (+ total-output-qty
                     (measure-has-numerical-value (recipe-flow-resource-quantity f))))))
            outputs)))
      procs)

    (if (<= total-output-qty 0) +inf.0
        (/ total-effort total-output-qty))))


;; =========================================================================
;; Best SNE across all recipes for a spec (with memoization)
;; =========================================================================

;;; NOTE — these two functions are named `…/actor` to distinguish them
;;; from the identically-named `compute-recipe-sne` / `build-sne-index`
;;; in relational/compute.scm. The relational versions operate on lifted
;;; fact lists, these operate on live recipe-store actors.

;; ORDER-INDEPENDENCE. SNE is an INFIMUM over the recipe graph — the least
;; labour that reaches a good — so it is a property of the technology alone, and
;; the answer must not depend on the order `all-resource-specs` hands specs back
;; (hash order of the spec id). The index is therefore read off `crystallize`
;; (rollup/fixpoint.scm) — the value rollup itself, iterated to its fixpoint over
;; the subgraph that reaches the spec, min across producers, a cyclic graph (corn
;; sown to grow corn) converging to the adjoint's own value. rollup.scm's
;; `crystallized-snlt-for-spec` and the engine's `good-labour-content` are the
;; same kernel, so the three agree by construction.
;; Regression: tests/planner/test-snlt-order-invariance.scm.

(define (compute-recipe-sne/actor output-spec-id recipe-store sne-index . rest)
  "Best (minimum) SNE across all recipes producing output-spec-id, every
   input priced through the same fixpoint. A spec already in SNE-INDEX keeps
   its entry; every spec priced along the way is added. A raw — no recipe —
   is 0. Returns (values sne updated-sne-index)."
  ;; no `or` around a `values` — (or …) keeps only the first value
  (let ((lifespans (and (pair? rest) (car rest)))
        (hit (hashmap-ref sne-index output-spec-id #f)))
    (if hit
        (values hit sne-index)
        (let* ((table (crystallize (recipe-alternatives recipe-store
                                                        #:from output-spec-id
                                                        #:lifespans lifespans)))
               (idx (hash-fold (lambda (spec v acc)
                                 (if (hashmap-ref acc spec #f) acc (hashmap-set acc spec v)))
                               sne-index table))
               (sne (hash-ref table output-spec-id 0)))
          (values sne (hashmap-set idx output-spec-id sne))))))

(define (direct-sne-for-spec recipe-store spec-id)
  "SNE counting DIRECT work flows only — no embodied inputs. The base case a
   cyclic recipe graph bottoms out at."
  (let ((recipes ($ recipe-store 'recipes-for-output spec-id)))
    (if (null? recipes) 0
        (fold (lambda (r best)
                (min best (compute-sne-for-recipe (recipe-id r) spec-id
                                                  recipe-store (hashmap) #f
                                                  (lambda (_s) 0))))
              +inf.0 recipes))))


;; =========================================================================
;; Build complete SNE index (actor flavour)
;; =========================================================================

(define (build-sne-index/actor recipe-store . rest)
  "Build complete SNE index for all registered specs.
   Returns hashmap of spec-id -> SNE (effort hours per unit). Each spec
   resolves its own inputs on demand, so the index does not depend on the
   order `all-resource-specs` hands specs back (which is hash order)."
  (let* ((lifespans (and (pair? rest) (car rest)))
         (all-specs ($ recipe-store 'all-resource-specs))
         (index (hashmap)))
    (fold (lambda (spec idx)
            (let-values (((sne new-idx)
                          (compute-recipe-sne/actor
                            (resource-specification-id spec)
                            recipe-store idx lifespans)))
              new-idx))
          index all-specs)))
