;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; rollup/relative-snlt.scm — joint-production rollup variant (3):
;;; RELATIVE-SNLT allocation.
;;;
;;; Spec: docs/planning/solve/planner-open-questions.md §3 (joint production), option (3).
;;;
;;; Instead of attributing all of a recipe's labour to one declared primary
;;; output (co-products ride free), split the recipe's GROSS effort across its
;;; net outputs in proportion to (qty × standalone-SNLT), where the standalone
;;; SNLT of an output is the labour it WOULD cost if produced on its own by some
;;; other single-output recipe (its independent technology). This:
;;;   • stays plan-INDEPENDENT and intrinsic (a property of the technology, not
;;;     of the current demand/solve — unlike the marginal dual, variant 4);
;;;   • is non-negative by construction (no matrix inversion ⇒ no Steedman
;;;     negatives); and
;;;   • reuses existing machinery (compute-sne-for-recipe / the standalone
;;;     anchor in rollup/common.scm).
;;;
;;; The one thing it cannot price is a co-product with NO standalone recipe (no
;;; independent labour basis). Those fall back to the mean anchor of the priced
;;; co-products (so they no longer ride free), and are flagged `anchored? = #f`
;;; — that residual is exactly where variant (4)'s dual is the honest answer.
;;;
;;; Assumes rollup/common.scm loaded. Pure functions; store consulted via $.

(define-module (playnet algorithms rollup relative-snlt)
  #:use-module (srfi srfi-1)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet vf schemas)
  #:use-module (goblins)
  #:use-module (playnet algorithms rollup common)
  #:use-module (playnet algorithms rollup fixpoint)
  #:export (rollup-relative-snlt rollup-relative-snlt-for))



(define* (rollup-relative-snlt store recipe-id #:key (sne-index (hashmap)) (lifespans #f)
                                               (price #f))
  "Attribute a recipe's gross crystallized effort across its net outputs by
   relative standalone SNLT. Returns an alist:
     ((total-effort     . E)            ; the joint cost split (hours)
      (anchored-fraction . f)           ; share of outputs with a standalone anchor
      (outputs . ( ((spec . s) (qty . q) (effort . e) (snlt . v)
                    (anchor . σ|#f) (anchored? . bool)) … )))
   where v = e/q is the per-unit crystallized SNLT imputed to that co-product
   and Σ e = E (the split conserves total labour)."
  (let* ((E    (recipe-gross-effort store recipe-id #:sne-index sne-index #:lifespans lifespans
                                          #:price price))
         (outs (recipe-net-outputs store recipe-id)))
    (if (null? outs)
        `((total-effort . ,E) (anchored-fraction . 0) (outputs . ()))
        ;; the split arithmetic is `split-joint` (rollup/fixpoint.scm) — one place
        (let* ((anchors (map (lambda (sq)
                               (standalone-snlt-for-spec store (car sq)
                                                         #:exclude recipe-id #:sne-index sne-index
                                                         #:price price))
                             outs))
               (prices  (split-joint E outs anchors))
               (finite  (filter identity anchors)))
          `((total-effort . ,E)
            (anchored-fraction . ,(exact->inexact (/ (length finite) (length outs))))
            (outputs .
              ,(map (lambda (sq anchor v)
                      `((spec . ,(car sq)) (qty . ,(cdr sq)) (effort . ,(* v (cdr sq))) (snlt . ,v)
                        (anchor . ,anchor) (anchored? . ,(and anchor #t))))
                    outs anchors prices)))))))

(define* (rollup-relative-snlt-for store recipe-id spec
                                   #:key (sne-index (hashmap)) (lifespans #f) (price #f))
  "Per-unit relative-SNLT imputed to one co-product SPEC of a recipe (or #f if
   spec is not a net output). Convenience wrapper over rollup-relative-snlt."
  (let ((row (assoc spec (map (lambda (o) (cons (assq-ref o 'spec) o))
                              (assq-ref (rollup-relative-snlt
                                          store recipe-id
                                          #:sne-index sne-index #:lifespans lifespans
                                          #:price price)
                                        'outputs)))))
    (and row (assq-ref (cdr row) 'snlt))))
