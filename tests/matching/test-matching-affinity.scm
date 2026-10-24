;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-matching-affinity.scm — classification affinity between needs and offers.
;;;
;;; The ported match-prototype scoring core, proven over folksonomy-template
;;; chains: chain indexing, leaf→root overlap with distance decay, the
;;; same-spec deterministic floor, geometric-mean composition (a zero vetoes,
;;; a missing dimension abstains), and pool matching with threshold + order.
;;;
;;; Run:  guile --no-auto-compile -q -L module \
;;;         -l tests/matching/test-matching-affinity.scm

(use-modules (localchimera test harness)
             (localchimera matching affinity)
             (srfi srfi-1))

(define (assq-ref alist key) (let ((p (assq key alist))) (and p (cdr p))))

;; A cut of the folksonomy: goods → food → {produce → zucchini, baked → bread}
;;                          services → care → childcare
(define tree
  '((id . "all") (label . "all") (count . 0)
    (children
     ((id . "term:goods") (label . "Goods") (count . 3)
      (children
       ((id . "term:food") (label . "Food") (count . 3)
        (children
         ((id . "term:produce") (label . "Produce") (count . 2)
          (children
           ((id . "term:zucchini") (label . "Zucchini") (count . 1)
            (children))))
         ((id . "term:baked") (label . "Baked") (count . 1)
          (children
           ((id . "term:bread") (label . "Bread") (count . 1)
            (children))))))))
     ((id . "term:services") (label . "Services") (count . 1)
      (children
       ((id . "term:care") (label . "Care") (count . 1)
        (children
         ((id . "term:childcare") (label . "Childcare") (count . 1)
          (children)))))))))

(define idx (chain-index tree))

(display "\n── chains from the template ──\n")

(check "a leaf term's chain runs broadest-first from below the root"
       (chain-of idx "term:zucchini")
       '("term:goods" "term:food" "term:produce" "term:zucchini"))

(check "an unfiled term still chains to itself"
       (chain-of idx "term:wild") '("term:wild"))

(display "\n── chain overlap and decay ──\n")

(call-with-values
    (lambda () (category-overlap (chain-of idx "term:zucchini")
                                 (chain-of idx "term:zucchini")))
  (lambda (term dist da db)
    (check "identical chains meet at the leaf" term "term:zucchini")
    (check "…at distance 0" dist 0)))

(call-with-values
    (lambda () (category-overlap (chain-of idx "term:zucchini")
                                 (chain-of idx "term:bread")))
  (lambda (term dist da db)
    (check "siblings' cousins meet at the shared ancestor" term "term:food")
    (check "…two steps above zucchini" dist 2)))

(call-with-values
    (lambda () (category-overlap (chain-of idx "term:zucchini")
                                 (chain-of idx "term:childcare")))
  (lambda (term dist da db)
    (check "disjoint subtrees do not overlap" (not term))))

(check "distance 0 scores 1.0" (= 1.0 (category-score 0)))
(check "distance 1 scores 0.8" (< (abs (- 0.8 (category-score 1))) 1e-9))
(check "past the distance cap the category signal abstains"
       (not (category-score 2)))

(display "\n── composition: veto, abstain, mean ──\n")

(check "all-abstain composes to no match"
       (= 0 (compose-scores '((category . #f) (time . #f)))))
(check "one zero vetoes"
       (= 0 (compose-scores '((category . 1.0) (time . 0)))))
(check "geometric mean over the present dimensions"
       (< (abs (- 0.6 (compose-scores '((a . 0.9) (b . 0.4))))) 1e-9))

(display "\n── scoring a pair ──\n")

;; Like the prototype's specific-to-general expressions, a classified slot
;; carries terms at more than one level — that is what lets cousins meet
;; within the distance cap instead of needing an embedding fallback.
(define need-zucchini
  '((id . "need:a:spec-zucchini") (spec . "spec-zucchini")
    (cats "term:zucchini" "term:produce") (qty . 2) (unit . "kg")))
(define offer-zucchini
  '((id . "means:b:spec-garden") (spec . "spec-garden")
    (cats "term:zucchini") (qty . 5) (unit . "kg")))
(define offer-bread
  '((id . "means:c:spec-bread") (spec . "spec-bread")
    (cats "term:bread" "term:food") (qty . 3) (unit . "loaf")))
(define offer-childcare
  '((id . "means:d:spec-childcare") (spec . "spec-childcare")
    (cats "term:childcare") (qty . 6) (unit . "hours")))

(let ((m (score-pair idx need-zucchini offer-zucchini)))
  (check "shared leaf category matches" (pair? m))
  (check "…on the shared term" (assq-ref m 'term) "term:zucchini")
  (check "…covered quantity leaves the category score whole"
         (= 1.0 (assq-ref m 'score))))

(check "disjoint categories are no match at all"
       (not (score-pair idx need-zucchini offer-childcare)))

(let ((m (score-pair idx
                     '((id . "need:x:spec-bread") (spec . "spec-bread")
                       (cats) (qty . 1) (unit . "loaf"))
                     '((id . "means:y:spec-bread") (spec . "spec-bread")
                       (cats) (qty . 1) (unit . "loaf")))))
  (check "same spec is the deterministic floor — no categories needed"
         (and m (= 1.0 (assq-ref m 'score))))
  (check "…and the badge term is the spec" (assq-ref m 'term) "spec-bread"))

(check "no categories and unlike specs: no signal, no match"
       (not (score-pair idx
                        '((id . "n") (spec . "spec-a") (cats) (qty . 1) (unit . "each"))
                        '((id . "c") (spec . "spec-b") (cats) (qty . 1) (unit . "each")))))

(display "\n── quantity coverage ──\n")

(check "offer covers need → 1.0" (= 1.0 (quantity-score 2 "kg" 5 "kg")))
(check "partial offer → the ratio" (= 0.5 (quantity-score 4 "kg" 2 "kg")))
(check "unlike units read as unknown" (= 0.5 (quantity-score 2 "kg" 3 "loaf")))
(check "an unquantified side abstains" (not (quantity-score 2 "kg" #f "kg")))

(display "\n── the pool, matched ──\n")

(let* ((needs (list need-zucchini))
       (caps (list offer-zucchini offer-bread offer-childcare))
       (rows (match-pool idx needs caps #:threshold 0.5))
       (hits (assq-ref (car rows) 'hits)))
  (check "one row per need" (length rows) 1)
  (check "the veg garden and the bakery match; childcare does not"
         (length hits) 2)
  (check "best first: the shared-leaf garden over the shared-food bakery"
         (assq-ref (car hits) 'id) "means:b:spec-garden")
  (check "the cousin match names the shared ancestor"
         (assq-ref (cadr hits) 'term) "term:food"))

(let* ((rows (match-pool idx (list need-zucchini) (list offer-bread)
                         #:threshold 0.9)))
  (check "the threshold prunes the generic cousin"
         (assq-ref (car rows) 'hits) '()))

(let* ((extra (lambda (n c) '((time . 0))))
       (rows (match-pool idx (list need-zucchini) (list offer-zucchini)
                         #:extra extra)))
  (check "a vetoing extra dimension (no time overlap) kills the match"
         (assq-ref (car rows) 'hits) '()))

(test-summary!)
