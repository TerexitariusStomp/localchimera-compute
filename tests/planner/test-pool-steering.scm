;;; test-pool-steering.scm — one bar, and demand steers which cell draws it.
;;;
;;; docs/planning/federation/patchwork-scopes-containment.md §1: a means-pool spanning
;;; cells is ONE budget, and WHICH cell draws it is a per-period solve OUTPUT —
;;; custody as the draw pattern, no credential, no field write, no custody
;;; event. test-containment-place.scm pins the pool's STRUCTURE (one budget,
;;; draws in two cells); this test pins the DYNAMIC: move the demand and the
;;; draw follows — all of it, an even split, none of it — while Σ stays pinned
;;; to the bar in every solve.
;;;
;;; Denomination (svc-hours-factor): the bar is unit-HOURS, and a `use` that
;;; states no duration holds the unit for the WHOLE period, costing that
;;; period's hours — so each thing costs 1.0 × 24 h = 24 of the 30 unit-hours,
;;; and the bar supports 30/24 = 1.25 things. Σ landing on exactly that in
;;; every solve is the bar BINDING, not demand falling short.
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-pool-steering.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine)
             (playnet solve compile)
             (playnet solve solver))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

;; one durable "m": its Svc| pool spans cells a and b with ONE 30-unit-hour bar.
;; one recipe per cell: 1 thing = 1 Svc|m + 0.2 h labour.
(define (solve-with demand-a demand-b)
  (declare-world! #:places '(("a" 40.0 -74.0) ("b" 40.1 -74.0))
                  #:spans '((0 "2026-03-03" "2026-03-03"))
                  #:templates
                    (list (list "p-make" '(("thing" . 1.0))
                                (list (cons (svc-good "m") 1.0)) 0.2 '(("gen" . 0.2)) '() '() '() '()))
                  #:resource-suppliers (list (list "pool" '("m") (list (cell "a" 0) (cell "b" 0)) 30.0 #t)))
  (hash-set! *demand* (lg "thing" (cell "a" 0)) demand-a)
  (hash-set! *demand* (lg "thing" (cell "b" 0)) demand-b)
  (hash-set! *A* (cell "a" 0) 100.0)
  (hash-set! *A* (cell "b" 0) 100.0)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values
                         (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
             (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0))))
             (made-a (V "p|p-make|a@0")) (made-b (V "p|p-make|b@0")))
        (format #t "    demand a=~2,0f b=~2,0f  →  draw a=~5,2f  b=~5,2f   (Σ=~5,2f)~%"
                demand-a demand-b made-a made-b (+ made-a made-b))
        (cons made-a made-b)))))

(format #t "~%── one bar over two cells; demand steers which cell draws it ──~%~%")
(define r1 (solve-with 25.0  0.0))
(define r2 (solve-with 12.0 12.0))
(define r3 (solve-with  0.0 25.0))

(define bar-up (/ 30.0 (period-hours 0)))         ; 30 unit-hours, denominated by the engine's own period
(define (near? a b) (< (abs (- a b)) 0.05))
(define (share r) (let ((s (+ (car r) (cdr r)))) (if (> s 1e-9) (/ (car r) s) -1)))
(define (total r) (+ (car r) (cdr r)))

(check "demand at a alone → 100% of the draw at a" (near? (share r1) 1.0))
(check "demand split evenly → the draw splits evenly" (near? (share r2) 0.5))
(check "demand at b alone → 100% of the draw at b" (near? (share r3) 0.0))
(check "Σ ≤ the bar in every solve — one budget, never copied"
       (every (lambda (r) (<= (total r) (+ bar-up 0.05))) (list r1 r2 r3)))
(check "Σ = the bar in every solve — it BINDS; demand steers only WHERE"
       (every (lambda (r) (near? (total r) bar-up)) (list r1 r2 r3)))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — custody is the draw pattern:~%  it redistributed across three solves with no credential,~%  no field write, and no custody event.~%" *pass*)
    (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)))
(format #t "════════════════════════════════════════════~%")
(exit (if (> *fail* 0) 1 0))
