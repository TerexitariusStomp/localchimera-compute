;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; rollup/fixpoint.scm — ONE fixpoint over the technology adjoint.
;;;
;;; Spec: docs/localchimera.typ §"Reproduction labour and the two measures of labour"
;;;       (the value rollup), §"Concrete and abstract labour" (ℓ̂ = Tᵀℓ),
;;;       docs/planning/solve/planner-open-questions.md §3 (joint production).
;;;
;;; Crystallized labour is the least fixpoint
;;;
;;;     ℓ̂(g) = min over producers of g of  [ direct + Σ_i qty_i · ℓ̂(input_i) ] / out-qty
;;;
;;; — the Leontief adjoint, the socially-necessary (cheapest) producer taken at every
;;; node (moral depreciation). This module is the one place that fixpoint is written.
;;; It knows nothing of recipe stores, templates, actors, units — or of any solve: ℓ̂
;;; is a property of the technology, every hour at coefficient one, and it is what a
;;; claim costs. A good's VALUE in a plan — its pull, scarcity and all, per skill and
;;; per cell — is the dual of the solve (engine.scm `good-pulls`, `labour-pulls`),
;;; read off the optimum and never recomputed here; a caller hands this module
;;; ALTERNATIVES — one per recipe or template — and reads a table back.
;;;
;;;   alternative = (direct inputs outputs)
;;;     direct  : hours of living labour one run spends
;;;     inputs  : ((node . qty) …) consumed per run — a worn durable's condition
;;;               (Cond|durable) is one of these, so depreciation rides in like any
;;;               other input
;;;     outputs : ((node . qty) …) produced per run, gross
;;;
;;; JOINT PRODUCTION. An alternative with several products has ONE gross effort E,
;;; split across them in proportion to qty × ANCHOR — `split-joint` below, the one
;;; place the arithmetic lives. A product's anchor is the cheapest price any OTHER
;;; alternative imputes to it at the previous pass — a sole-product recipe (its
;;; standalone cost) or another joint recipe (its own split) alike — so the anchor
;;; converges with the fixpoint and stays a property of the technology. A product
;;; only this recipe reaches takes the mean of its anchored siblings, and when no
;;; sibling is anchored the split is by quantity. Σ effort = E at every step —
;;; nothing rides free, no hour is counted twice, and the split is non-negative by
;;; construction (no inversion, so no Steedman negatives). At the margin the plan's
;;; dual μ(g) values a co-product through the technology matrix without any split;
;;; that is the value, and this labour-content is what it reduces to when nothing but
;;; labour is scarce. Membership is NET (produced − self-consumed > 0), so a fully
;;; self-consumed intermediate is no product; the quantity stays GROSS, because the
;;; self-consumed part is already charged as an input — seed grain at 9 h → 10,
;;; eating 1, prices at (9 + ℓ̂)/10 = 1.0, Leontief's own answer.
;;;
;;; CYCLES. Iterated from zero (Jacobi, double-buffered), so costs converge UPWARD to
;;; the true fixpoint (ρ(A) < 1): corn sown to grow corn prices at 4/(1−0.2), the
;;; adjoint's answer. The min is taken only across alternatives, never across passes,
;;; so the result is order-independent. Convergence is geometric — tens of passes in
;;; practice; the cap is a safety net, and on a tiny graph (a self-loop and little
;;; else) it is the cap that ends the run, ~1e-6 from the limit.
;;;
;;; FLUTTER. A joint split anchored on the pass before can settle into a small
;;; standing wave, each pass moving every price by the same millionth and back: the
;;; move then has a floor above the tolerance, and an iteration that waits for the
;;; tolerance runs to its cap, a pass for every alternative, which is the square of
;;; a crowd. A move that has stopped shrinking has said all it will: sixteen passes
;;; without the smallest move falling by a hundredth end the run, where a cycle that
;;; is still converging, however slowly, keeps shrinking and keeps running.
;;;
;;; UNPRICEABLE. A node no alternative delivers has no row — a raw, a free gift of
;;; nature — and as an INPUT it contributes 0. What "no row" means at the TOP is the
;;; caller's convention (+inf.0 for the pool: unreachable is a real answer; 0 for the
;;; SNE index).
;;;
;;; ACCUMULATOR. Scalar hours — the object credit and claims are sized over. The same
;;; recursion with a vector accumulator (ℓ̂ per skill, d̂ per raw, an element per
;;; element) is a DECOMPOSITION for inspection: it lets the plan say which skill's
;;; tightness a dual comes from. It reports; it never feeds a price — the per-skill,
;;; per-cell pull is already the solve's own λ(k,c) and μ(g).

(define-module (localchimera algorithms rollup fixpoint)
  #:use-module (srfi srfi-1)
  #:export (crystallize alternative-products split-joint))

(define (alternative-products alt)
  "The co-products one run of ALT delivers: ((node . gross-qty) …) for every
   output whose net (produced − self-consumed) is positive."
  (let ((net (make-hash-table)) (gross (make-hash-table)))
    (for-each (lambda (oq)
                (hash-set! gross (car oq) (+ (hash-ref gross (car oq) 0.0) (cdr oq)))
                (hash-set! net   (car oq) (+ (hash-ref net   (car oq) 0.0) (cdr oq))))
              (caddr alt))
    (for-each (lambda (iq)
                (when (hash-ref net (car iq) #f)
                  (hash-set! net (car iq) (- (hash-ref net (car iq)) (cdr iq)))))
              (cadr alt))
    (filter-map (lambda (sq) (and (> (cdr sq) 1e-12) (cons (car sq) (hash-ref gross (car sq)))))
                (hash-map->list cons net))))

(define (split-joint E products anchors)
  "Per-unit prices, one per product, splitting the gross effort E across
   PRODUCTS ((node . qty) …) in proportion to qty × anchor. ANCHORS aligns
   with PRODUCTS: a number, or #f for a product with none, which takes the
   mean of its anchored siblings — and when none is anchored, the split is by
   quantity. Σ price × qty = E."
  (let* ((finite  (filter identity anchors))
         (fill    (if (null? finite) 1.0 (/ (apply + finite) (length finite))))
         (weights (map (lambda (sq an) (* (cdr sq) (or an fill))) products anchors))
         (weights (if (> (apply + weights) 0.0) weights (map cdr products)))
         (W       (apply + weights)))
    (map (lambda (sq w) (/ (* E (/ w W)) (cdr sq))) products weights)))

(define* (crystallize alternatives #:key (tol 1e-9) (max-passes #f))
  "Table node → ℓ̂ (hours per unit) over ALTERNATIVES; a node no alternative
   delivers has no row."
  (let* ((alts (map (lambda (a) (cons (alternative-products a) a)) alternatives))   ; (products direct inputs outputs)
         (cap  (or max-passes (max 64 (length alts)))))
    (let loop ((prev (make-hash-table)) (prev-offers (make-hash-table)) (pass 0)
               (least +inf.0) (still 0))             ; the smallest move yet, and the passes since it last fell
      (let* ((cur (make-hash-table)) (offers (make-hash-table))
             (effort (map (lambda (a)                          ; gross effort of one run, inputs at the previous pass
                            (+ (cadr a)
                               (fold (lambda (iq acc) (+ acc (* (cdr iq) (hash-ref prev (car iq) 0.0))))
                                     0.0 (caddr a))))
                          alts))
             ;; a node keeps its cheapest offer, who made it, and the cheapest of the
             ;; rest: all that "the cheapest OTHER producer" ever asks of it. A node a
             ;; crowd's every eat returns to (the vapour, the dung) has an offer from
             ;; each, and kept whole the list is searched once for every one of them
             (offer! (lambda (a node cost)                    ; (best its-maker best-of-the-rest)
                       (let ((e (hash-ref offers node #f)))
                         (hash-set! offers node
                                    (cond ((not e) (list cost a #f))
                                          ((eq? a (cadr e)) (list (min cost (car e)) a (caddr e)))
                                          ((< cost (car e)) (list cost a (car e)))
                                          (else (list (car e) (cadr e) (if (caddr e) (min cost (caddr e)) cost))))))
                       (hash-set! cur node (let ((v (hash-ref cur node #f))) (if v (min v cost) cost)))))
             (anchor-of (lambda (node self)                   ; cheapest OTHER producer at the previous pass
                          (let ((e (hash-ref prev-offers node #f)))
                            (and e (if (eq? (cadr e) self) (caddr e) (car e)))))))
        (for-each
         (lambda (a E)
           (let ((prods (car a)))
             (cond
              ((null? prods) #f)
              ((null? (cdr prods)) (offer! a (caar prods) (/ E (cdar prods))))     ; sole product: whole effort per unit
              (else
               (for-each (lambda (sq v) (offer! a (car sq) v))
                         prods
                         (split-joint E prods (map (lambda (sq) (anchor-of (car sq) a)) prods)))))))
         alts effort)
        (let ((maxd 0.0) (maxv 1.0))
          (hash-for-each (lambda (node v)
                           (set! maxd (max maxd (abs (- v (hash-ref prev node 0.0)))))
                           (set! maxv (max maxv (abs v))))
                         cur)
          (let* ((fell? (< maxd (* 0.99 least)))
                 (still (if fell? 0 (+ still 1))))
            (if (or (>= pass cap) (< maxd (* tol maxv)) (>= still 16))
                cur
                (loop cur offers (+ pass 1) (if fell? maxd least) still))))))))
