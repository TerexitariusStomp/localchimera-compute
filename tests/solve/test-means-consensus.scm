;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-means-consensus.scm — the consensus row: one bar, across sovereign solves.
;;;
;;; pool-steering-test pins the bar INSIDE one solve: demand steers which cell
;;; draws it. This pins the same bar ACROSS solves — the federation case, where
;;; no scope reads another's records. allocate-means-consensus hands each scope
;;; an allocation, reads back the dual on its cap (the marginal value of one
;;; more unit-hour THERE), and moves the allocation multiplicatively toward equal
;;; duals — the pooled bar's own optimality condition. The test's ground
;;; truth is therefore the MONOLITH: the same two demands under one spanning
;;; supplier bar, whose split the decomposed allocation must reproduce.
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-means-consensus.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve federation-solve) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define TOTAL 30.0)           ; unit-hours of the common means m, one bar
(define DEMAND-A 20.0)        ; things wanted at a — 4× b's want
(define DEMAND-B  5.0)

(define (tpl) (list "p-make" '(("thing" . 1.0))
                    (list (cons (svc-good "m") 1.0)) 0.2 '(("gen" . 0.2)) '() '() '() '()))

;; ── the monolith ground truth: one solve, one supplier bar over both cells ──
(define (monolith-draws)
  (declare-world! #:places '(("a" 40.0 -74.0) ("b" 40.1 -74.0))
                  #:spans '((0 "2026-03-03" "2026-03-03"))
                  #:templates (list (tpl))
                  #:resource-suppliers (list (list "pool" '("m") (list (cell "a" 0) (cell "b" 0)) TOTAL #t)))
  (hash-set! *demand* (lg "thing" (cell "a" 0)) DEMAND-A)
  (hash-set! *demand* (lg "thing" (cell "b" 0)) DEMAND-B)
  (hash-set! *A* (cell "a" 0) 100.0)
  (hash-set! *A* (cell "b" 0) 100.0)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values
                         (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
             (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0))))
             (hours (lambda (p) (* 24.0 (V (string-append "p|p-make|" p "@0"))))))
        (cons (hours "a") (hours "b"))))))     ; unit-hours drawn at each cell

;; ── one sovereign scope's world: a single place, the means capped at ALLOC ──
(define (make-scope place demand)
  (lambda (alloc)
    (declare-world! #:places (list (list place 40.0 -74.0))
                    #:spans '((0 "2026-03-03" "2026-03-03"))
                    #:templates (list (tpl)))
    (hash-set! *cap* (lg (svc-good "m") (cell place 0)) alloc)
    (hash-set! *demand* (lg "thing" (cell place 0)) demand)
    (hash-set! *A* (cell place 0) 100.0)
    (call-with-values build-located
      (lambda (forms labform ncol cols goods raws idx)
        (values (car (call-with-values
                         (lambda () (solve-native forms labform (located-warm cols ncol idx))) list))
                cols idx)))))

(format #t "~%── the same bar, monolith vs consensus-across-solves ──~%~%")

;; NB the engine's desire is RELATIVE fill (gap = (tgt−cur)/tgt), so the
;; SMALLER want pulls harder per unit and the monolith may drive a corner —
;; that is "demand is a want" behaving as documented, and the consensus row
;; must reproduce it, not correct it.

(define truth (monolith-draws))
(format #t "    monolith (one solve, spanning bar):  a=~,2f  b=~,2f unit-hours~%"
        (car truth) (cdr truth))

(call-with-values
    (lambda () (allocate-means-consensus
                (list (cons "scope-a" (make-scope "a" DEMAND-A))
                      (cons "scope-b" (make-scope "b" DEMAND-B)))
                "m" TOTAL))
  (lambda (allocs duals rounds)
    (let* ((aa (assoc-ref allocs "scope-a")) (ab (assoc-ref allocs "scope-b"))
           (ma (assoc-ref duals  "scope-a")) (mb (assoc-ref duals  "scope-b")))
      (format #t "    consensus  (~a rounds, sovereign):    a=~,2f  b=~,2f unit-hours~%"
              rounds aa ab)
      (format #t "    duals at rest:                        μa=~,1f μb=~,1f~%~%" ma mb)
      (check "the row holds exactly: Σ alloc = the bar"
             (< (abs (- (+ aa ab) TOTAL)) 1e-6))
      (check "the consensus split reproduces the monolith's (±10% of the bar)"
             (and (< (abs (- aa (car truth))) (* 0.1 TOTAL))
                  (< (abs (- ab (cdr truth))) (* 0.1 TOTAL))))
      (check "the corner is the KKT inequality: the ceded side's dual sits lower"
             (if (< aa ab) (<= ma mb) (<= mb ma))))))

(format #t "~%── the symmetric case: equal wants, interior rest, one price ──~%~%")

(call-with-values
    (lambda () (allocate-means-consensus
                (list (cons "scope-a" (make-scope "a" 12.0))
                      (cons "scope-b" (make-scope "b" 12.0)))
                "m" TOTAL))
  (lambda (allocs duals rounds)
    (let* ((aa (assoc-ref allocs "scope-a")) (ab (assoc-ref allocs "scope-b"))
           (ma (assoc-ref duals  "scope-a")) (mb (assoc-ref duals  "scope-b")))
      (format #t "    consensus (~a rounds):  a=~,2f b=~,2f   μa=~,1f μb=~,1f~%~%"
              rounds aa ab ma mb)
      (check "equal wants → the bar rests split evenly (±5%)"
             (< (abs (- aa ab)) (* 0.05 TOTAL)))
      (check "…and the duals equalise: one scalar price for the row (±10%)"
             (< (abs (- ma mb)) (* 0.10 (max ma mb)))))))

(format #t "~%── start-independence: skewed guesses, one rest ──~%~%")

;; Convexity kills local optima: the rest point is the KKT point, so the only
;; possible failure is not settling — never settling wrong. Pin it empirically:
;; the same corner from both extreme starting splits.
(define (rest-from init)
  (call-with-values
      (lambda () (allocate-means-consensus
                  (list (cons "scope-a" (make-scope "a" DEMAND-A))
                        (cons "scope-b" (make-scope "b" DEMAND-B)))
                  "m" TOTAL #:init init))
    (lambda (allocs duals rounds)
      (format #t "    from ~a → a=~,2f b=~,2f (~a rounds)~%"
              init (assoc-ref allocs "scope-a") (assoc-ref allocs "scope-b") rounds)
      (assoc-ref allocs "scope-a"))))

(let ((from-a-heavy (rest-from '(29.0 1.0)))
      (from-b-heavy (rest-from '(1.0 29.0))))
  (check "opposite extreme starts settle on the same split (±5% of the bar)"
         (< (abs (- from-a-heavy from-b-heavy)) (* 0.05 TOTAL)))
  (check "…and it is the monolith's split, from either direction"
         (and (< (abs (- from-a-heavy (car truth))) (* 0.1 TOTAL))
              (< (abs (- from-b-heavy (car truth))) (* 0.1 TOTAL)))))

(format #t "~%── the ceiling binds at placement: consent's quantity ──~%~%")

;; b would take nearly the whole bar (the corner above); its hosting
;; willingness says 10 unit-hours, no more. The row must respect it and the
;; remainder must land where consent allows.
(call-with-values
    (lambda () (allocate-means-consensus
                (list (cons "scope-a" (make-scope "a" DEMAND-A))
                      (cons "scope-b" (make-scope "b" DEMAND-B)))
                "m" TOTAL #:ceilings '(("scope-b" . 10.0))))
  (lambda (allocs duals rounds)
    (let ((aa (assoc-ref allocs "scope-a")) (ab (assoc-ref allocs "scope-b")))
      (format #t "    ceiling b≤10 → a=~,2f b=~,2f (~a rounds)~%" aa ab rounds)
      (check "the ceiling holds — no scope is granted more than it offered"
             (<= ab 10.0001))
      (check "the row still holds exactly under the clamp"
             (< (abs (- (+ aa ab) TOTAL)) 1e-6))
      (check "the displaced remainder lands with the consenting scope"
             (> aa 19.0)))))

(format #t "~%── consent that cannot place the bar: the commons keeps the rest ──~%~%")

(call-with-values
    (lambda () (allocate-means-consensus
                (list (cons "scope-a" (make-scope "a" DEMAND-A))
                      (cons "scope-b" (make-scope "b" DEMAND-B)))
                "m" TOTAL #:ceilings '(("scope-a" . 8.0) ("scope-b" . 10.0))))
  (lambda (allocs duals rounds)
    (let ((aa (assoc-ref allocs "scope-a")) (ab (assoc-ref allocs "scope-b")))
      (format #t "    ceilings a≤8 b≤10, bar 30 → a=~,2f b=~,2f~%" aa ab)
      (check "every scope rests at its ceiling"
             (and (< (abs (- aa 8.0)) 1e-6) (< (abs (- ab 10.0)) 1e-6)))
      (check "Σ alloc = Σ ceilings — the unplaceable remainder stays unplaced"
             (< (abs (- (+ aa ab) 18.0)) 1e-6)))))

(format #t "~%── the records path: the same row over ingest-records! worlds ──~%~%")

;; the live shape: each scope's world built from RECORDS, the allocation
;; arriving as an eco-cap — sovereignty is the records staying in the closure.
(define (record-scope place demand)
  (let ((procs (list (rp "make" "Make things")))
        (flows (list (out "f1" "thing" 1.0 "make")
                     (use* "f2" "m" "make" #f #:qty 1.0 #:unit "unit")
                     (wrk "f3" 0.2 "make")))
        (spatials (list (place* place #:name place #:lat 40.0 #:lon -74.0))))
    (records-means-world '() '() spatials procs flows "m" place
                         #:demand (list (cons (lg "thing" (cell place 0)) demand)))))

(call-with-values
    (lambda () (allocate-means-consensus
                (list (cons "scope-a" (record-scope "a" 12.0))
                      (cons "scope-b" (record-scope "b" 12.0)))
                "m" TOTAL))
  (lambda (allocs duals rounds)
    (let ((aa (assoc-ref allocs "scope-a")) (ab (assoc-ref allocs "scope-b")))
      (format #t "    records path (~a rounds): a=~,2f b=~,2f~%" rounds aa ab)
      (check "the records-built worlds split the bar evenly under equal wants"
             (< (abs (- aa ab)) (* 0.05 TOTAL)))
      (check "…and the row holds"
             (< (abs (- (+ aa ab) TOTAL)) 1e-6)))))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — the consensus row recovers the pooled~%  bar across sovereign solves: allocations in, one scalar out,~%  and no scope read another's records.~%" *pass*)
    (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)))
(format #t "════════════════════════════════════════════~%")
(exit (if (> *fail* 0) 1 0))
