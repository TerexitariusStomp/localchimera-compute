;;; sne.scm — Socially Necessary Effort (SNE) index computation
;;;
;;; Translated from src/lib/algorithms/SNE.ts
;;; Pure functions — no actor state, no side effects.
;;;
;;; SNE = total effort hours per unit of output, including:
;;;   - Direct labor (work flows)
;;;   - Embodied labor (qty_consumed * SNE of input spec)
;;;   - Equipment depreciation (duration / lifespan * SNE of equipment spec)
;;;   - Excludes: cite flows (knowledge/IP, amortized near 0)

;; Assumes schemas.scm, store-utils.scm, propagation.scm are loaded.

(use-modules (srfi srfi-1)
             (srfi srfi-11)
             (goblins utils hashmap))

(define *non-consuming-actions-sne* '(use work cite deliver-service))


;; =========================================================================
;; SNE for a single recipe
;; =========================================================================

(define (compute-sne-for-recipe recipe-id output-spec-id recipe-store sne-index
                                . rest)
  "Compute SNE for one recipe. Returns effort hours per unit of output-spec-id.
   sne-index: hashmap of spec-id -> SNE (mutable during computation for memoization).
   lifespans: optional hashmap of spec-id -> lifespan-hours."
  (let* ((lifespans (and (pair? rest) (car rest)))
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
                  (let ((input-sne (hashmap-ref sne-index spec 0)))
                    (set! total-effort
                      (+ total-effort
                         (* (measure-has-numerical-value rq) input-sne)))))))
            inputs)

          ;; Equipment depreciation: use flows with lifespan
          (when lifespans
            (for-each
              (lambda (f)
                (when (eq? (recipe-flow-action f) 'use)
                  (let* ((spec (recipe-flow-resource-conforms-to f))
                         (lifespan (and spec (hashmap-ref lifespans spec #f)))
                         (equip-sne (and spec (hashmap-ref sne-index spec 0))))
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

(define (compute-recipe-sne output-spec-id recipe-store sne-index . rest)
  "Compute best (minimum) SNE across all recipes producing output-spec-id.
   Memoizes result in sne-index (returns updated hashmap).
   Returns (values sne updated-sne-index)."
  (let* ((lifespans (and (pair? rest) (car rest)))
         (cached (hashmap-ref sne-index output-spec-id #f)))
    (if cached
        (values cached sne-index)
        (let* ((recipes ($ recipe-store 'recipes-for-output output-spec-id))
               (best (if (null? recipes)
                         0  ;; Raw material: no recipe = zero embodied labor
                         (fold (lambda (r best)
                                 (let ((sne (compute-sne-for-recipe
                                              (recipe-id r) output-spec-id
                                              recipe-store sne-index lifespans)))
                                   (min best sne)))
                               +inf.0 recipes)))
               (new-index (hashmap-set sne-index output-spec-id best)))
          (values best new-index)))))


;; =========================================================================
;; Build complete SNE index
;; =========================================================================

(define (build-sne-index recipe-store . rest)
  "Build complete SNE index for all registered specs in one pass.
   Returns hashmap of spec-id -> SNE (effort hours per unit)."
  (let* ((lifespans (and (pair? rest) (car rest)))
         (all-specs ($ recipe-store 'all-resource-specs))
         (index (hashmap)))
    (fold (lambda (spec idx)
            (let-values (((sne new-idx)
                          (compute-recipe-sne
                            (resource-specification-id spec)
                            recipe-store idx lifespans)))
              new-idx))
          index all-specs)))
