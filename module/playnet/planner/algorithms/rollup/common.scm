;;; rollup/common.scm — shared scaffolding for the ALTERNATIVE cost-rollup
;;; variants (relative-snlt.scm, marginal-dual.scm).
;;;
;;; The canonical rollup (algorithms/rollup.scm via propagation's compute-snlt,
;;; and sne.scm) attributes a recipe's WHOLE labour to its declared
;;; `recipe-primary-output`, so co-products ride free (zero imputed SNLT). The
;;; variants here implement the two principled alternatives discussed in
;;; docs/planning/solve/planner-open-questions.md §3:
;;;   (3) relative-SNLT allocation — split joint labour across co-products in
;;;       proportion to each output's INDEPENDENT (standalone) labour content;
;;;   (4) marginal / LP-dual imputation — value each good by the activity
;;;       adjoint (the shadow price), which splits joint labour automatically.
;;;
;;; Both build on two primitives the canonical rollup never isolates:
;;;   • recipe-gross-effort : a recipe's TOTAL crystallized labour (direct work +
;;;     embodied consumed inputs + equipment depreciation), summed across its
;;;     processes and NOT divided by any one output — the "joint cost" to split.
;;;   • recipe-net-outputs  : the recipe's NET produced bundle ((spec . qty) …),
;;;     produced minus internally-consumed, so intermediates don't count.
;;;
;;; A store is read through a 4-message subset — get-recipe, get-process-chain,
;;; flows-for-process, all-recipes — supported by BOTH the full recipe-store and
;;; the lightweight (playnet planner knowledge dsl recipe-library), so tests need
;;; only the library.
;;;
;;; Assumes schemas.scm and propagation.scm already loaded (for the recipe-flow /
;;; measure accessors, rp-duration-ms, *ms-per-hour*). Pure functions; the store
;;; is consulted via $.

(define-module (playnet planner algorithms rollup common)
  #:use-module (playnet planner formulas actions)
  #:use-module (srfi srfi-1)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet planner vf schemas)
  #:use-module (goblins)
  #:use-module (playnet planner algorithms propagation)
  #:export (*rollup-non-consuming* rollup-mval rollup-store-procs recipe-net-outputs
            rollup-input-price recipe-gross-effort rollup-recipes-producing
            rollup-producers-of recipe-alternatives standalone-snlt-for-spec))



(define *rollup-non-consuming* inert-flow-actions)   ; the table's: a flow that leaves the stock as it was

(define (rollup-mval m) (and m (measure-has-numerical-value m)))

(define (rollup-store-procs store recipe-id)
  ;; both stores answer get-process-chain with the recipe's <recipe-process> list
  ($ store 'get-process-chain recipe-id))

;; ---------------------------------------------------------------------------
;; recipe-net-outputs — the recipe's NET produced bundle
;; ---------------------------------------------------------------------------
(define (recipe-net-outputs store recipe-id)
  "Net produced bundle ((spec . qty) …): produced qty per spec minus
   internally-consumed qty per spec across all processes. Specs with non-positive
   net (raws, fully-consumed intermediates) are dropped — what remains is the set
   of co-products the recipe actually delivers."
  (let ((bal (make-hash-table)))
    (for-each
      (lambda (rp)
        (let* ((io   ($ store 'flows-for-process (recipe-process-id rp)))
               (ins  (car io)) (outs (cdr io)))
          (for-each (lambda (f)
                      (let ((s (recipe-flow-resource-conforms-to f))
                            (q (rollup-mval (recipe-flow-resource-quantity f))))
                        (when (and s q) (hash-set! bal s (+ (hash-ref bal s 0.0) q)))))
                    outs)
          (for-each (lambda (f)
                      (let ((s (recipe-flow-resource-conforms-to f))
                            (q (rollup-mval (recipe-flow-resource-quantity f))))
                        (when (and s q (not (memq (recipe-flow-action f) *rollup-non-consuming*)))
                          (hash-set! bal s (- (hash-ref bal s 0.0) q)))))
                    ins)))
      (rollup-store-procs store recipe-id))
    (filter (lambda (sq) (> (cdr sq) 1e-12)) (hash-map->list cons bal))))

;; ---------------------------------------------------------------------------
;; recipe-gross-effort — the joint cost to be attributed
;; ---------------------------------------------------------------------------
;; PRICE. `sne-index` alone cannot price an input the index has not reached yet —
;; it reads absent as 0, which is how the same bug got into sne.scm (see
;; tests/planner/test-snlt-order-invariance.scm). Every entry point below takes an
;; optional `price` resolver instead; when given it OVERRIDES the index, so an
;; unpriced input recurses rather than silently costing nothing.
;;
;; THE UNPRICEABLE-INPUT CONVENTION, in one place.
;; A spec no recipe produces has no labour basis. As an OUTPUT that is +inf.0 —
;; "unreachable", a first-class answer §4 of social-category.typ insists on. As an
;; INPUT it must contribute NOTHING: a raw is a free gift of nature, and a bundle
;; containing one is not thereby infinitely expensive. `flow-snlt-cost` in
;; rollup.scm has always mapped +inf.0 → 0 on that boundary; the variants here
;; multiplied straight through, so ONE raw input made a whole recipe +inf.0, the
;; joint route dropped out of the min in `crystallized-snlt-for-spec`, and every
;; co-product silently fell back to its standalone price with the by-product
;; riding free again — a failure indistinguishable from the feature being absent.
;; The guard belongs here, at the single point every variant reads an input
;; through, and not at the call sites. Locked by the raw-input case in
;; tests/planner/test-joint-production.scm.
(define (rollup-input-price price sne-index spec)
  (let ((v (if price (price spec) (hashmap-ref sne-index spec 0))))
    (if (or (not v) (= v +inf.0)) 0 v)))

(define* (recipe-gross-effort store recipe-id #:key (sne-index (hashmap)) (lifespans #f)
                                                    (price #f))
  "Total crystallized labour of a recipe, in hours, summed across all processes
   and NOT divided by any output: direct work + embodied consumed inputs
   (qty × SNE(spec) from sne-index) + optional equipment depreciation
   (duration/lifespan × SNE). This is the quantity the variants split across the
   recipe's net outputs.

   NOTE: the optional `lifespans` depreciation term is DEPRECATED (legacy per-spec
   lifespan). The canonical model treats a durable's condition as a stock good
   `Cond|durable` whose wear is a per-recipe `consume` — depreciation then rolls
   in as an ordinary consumed input, with lifespan emergent (condition ÷ wear) and
   moral depreciation via the min over producers. See project_wear_depreciation_model."
  (let ((eff 0.0))
    (for-each
      (lambda (rp)
        (let* ((io    ($ store 'flows-for-process (recipe-process-id rp)))
               (ins   (car io))
               (dur-h (/ (rp-duration-ms rp) *ms-per-hour*)))
          (for-each
            (lambda (f)
              (let ((act (recipe-flow-action f))
                    (s   (recipe-flow-resource-conforms-to f)))
                (cond
                  ((eq? act 'work)
                   (let ((e (rollup-mval (recipe-flow-effort-quantity f))))
                     (when e (set! eff (+ eff e)))))
                  ((and s (eq? act 'use) lifespans)
                   (let ((life (hashmap-ref lifespans s #f))
                         (esne (rollup-input-price price sne-index s)))
                     (when (and life (> life 0) esne)
                       (set! eff (+ eff (* (/ dur-h life) esne))))))
                  ((and s (not (memq act *rollup-non-consuming*)))
                   (let ((q (rollup-mval (recipe-flow-resource-quantity f)))
                         (esne (rollup-input-price price sne-index s)))
                     (when q (set! eff (+ eff (* q esne)))))))))
            ins)))
      (rollup-store-procs store recipe-id))
    eff))

;; ---------------------------------------------------------------------------
;; standalone-snlt-for-spec — the option-3 anchor
;; ---------------------------------------------------------------------------
(define (rollup-recipes-producing store spec)
  "All recipes whose NET outputs include spec (derived from all-recipes, so it
   works against the lightweight library too)."
  (filter (lambda (r) (assoc spec (recipe-net-outputs store (recipe-id r))))
          ($ store 'all-recipes)))

(define (rollup-producers-of store spec)
  "Recipes producing SPEC as a NET output. Falls back to the primary-output
   index when the store cannot answer `all-recipes` (the lightweight mocks)."
  (or (false-if-exception (rollup-recipes-producing store spec))
      ($ store 'recipes-for-output spec)))

;; ---------------------------------------------------------------------------
;; recipe-alternatives — the store read ONCE, for the fixpoint kernel
;; ---------------------------------------------------------------------------
;; `crystallize` (rollup/fixpoint.scm) is the value rollup; it takes plain
;; ALTERNATIVES — (direct inputs outputs) per recipe — and knows no store. This is
;; the one place a recipe store is turned into that shape: direct = its work hours,
;; inputs = its consumed flows (spec . qty) — a `use` flow with a legacy per-spec
;; lifespan enters as the input edge (spec . duration/lifespan), which is what
;; depreciation is — outputs = its produce flows, gross. With FROM, only the
;; subgraph that reaches FROM's producers is read (demand-driven, breadth-first
;; through inputs); without it, every recipe the store holds.
(define* (recipe-alternatives store #:key (from #f) (lifespans #f))
  (define (one recipe-id)
    (let ((direct 0.0) (ins '()) (outs '()))
      (for-each
        (lambda (rp)
          (let* ((io    ($ store 'flows-for-process (recipe-process-id rp)))
                 (dur-h (/ (rp-duration-ms rp) *ms-per-hour*)))
            (for-each
              (lambda (f)
                (let ((act (recipe-flow-action f))
                      (s   (recipe-flow-resource-conforms-to f))
                      (q   (rollup-mval (recipe-flow-resource-quantity f))))
                  (cond
                    ((eq? act 'work)
                     (let ((e (rollup-mval (recipe-flow-effort-quantity f))))
                       (when e (set! direct (+ direct e)))))
                    ((and s (eq? act 'use) lifespans)
                     (let ((life (hashmap-ref lifespans s #f)))
                       (when (and life (> life 0))
                         (set! ins (cons (cons s (/ dur-h life)) ins)))))
                    ((and s q (not (memq act *rollup-non-consuming*)))
                     (set! ins (cons (cons s q) ins))))))
              (car io))
            (for-each
              (lambda (f)
                (let ((s (recipe-flow-resource-conforms-to f))
                      (q (rollup-mval (recipe-flow-resource-quantity f))))
                  (when (and s q) (set! outs (cons (cons s q) outs)))))
              (cdr io))))
        (rollup-store-procs store recipe-id))
      (list direct ins outs)))
  (if (not from)
      (map (lambda (r) (one (recipe-id r))) ($ store 'all-recipes))
      (let ((seen-spec (make-hash-table)) (seen-recipe (make-hash-table)))
        (let loop ((frontier (list from)) (acc '()))
          (if (null? frontier) acc
              (let ((spec (car frontier)))
                (if (hash-ref seen-spec spec #f)
                    (loop (cdr frontier) acc)
                    (begin
                      (hash-set! seen-spec spec #t)
                      (let step ((rs (rollup-producers-of store spec)) (frontier (cdr frontier)) (acc acc))
                        (cond
                          ((null? rs) (loop frontier acc))
                          ((hash-ref seen-recipe (recipe-id (car rs)) #f) (step (cdr rs) frontier acc))
                          (else
                           (hash-set! seen-recipe (recipe-id (car rs)) #t)
                           (let ((alt (one (recipe-id (car rs)))))
                             (step (cdr rs)
                                   (append frontier (map car (cadr alt)))
                                   (cons alt acc))))))))))))))

(define* (standalone-snlt-for-spec store spec #:key (exclude #f) (sne-index (hashmap))
                                                    (price #f))
  "Minimum crystallized SNLT for spec across recipes that produce it as their
   SOLE net output (a genuinely independent technology), excluding `exclude`.
   This is the anchor relative-SNLT allocation splits by — it never reuses the
   joint recipe itself, so it is not circular. Returns #f when spec has no
   standalone recipe (then it cannot be anchored)."
  (let ((cands (filter-map
                 (lambda (r)
                   (and (not (equal? (recipe-id r) exclude))
                        (let ((nout (recipe-net-outputs store (recipe-id r))))
                          (and (= (length nout) 1) (equal? (caar nout) spec)
                               (cons (recipe-id r) (cdar nout))))))   ; (recipe-id . sole-output-qty)
                 (rollup-recipes-producing store spec))))
    (if (null? cands) #f
        (let ((best (fold (lambda (rq acc)
                            ;; standalone SNLT = the recipe's whole crystallized
                            ;; effort over its sole output's quantity
                            (let* ((q (cdr rq))
                                   (v (and (> q 0)
                                           (/ (recipe-gross-effort store (car rq) #:sne-index sne-index
                                                                      #:price price) q))))
                              (if (and v (not (= v +inf.0))) (min acc v) acc)))
                          +inf.0 cands)))
          (and (not (= best +inf.0)) best)))))
