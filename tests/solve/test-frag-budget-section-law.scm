;;; test-frag-budget-section-law.scm — the eco-budget over a container obeys
;;; the section law: what the container counts is exactly the sum of what its
;;; leaves draw, and the pool is ONE pool — fungible across the leaves.
;;;
;;; This is the fold on the CONTAINMENT tree (engine/fragility.scm places-within:
;;; the upward walk read from the other end), computed per solve from static
;;; declarations — so it needs no standing node, only its law stated:
;;;
;;;   draw(container) = Σ draw(leaves)          (the fold)
;;;   a pool of L over two leaves ≠ two pools of L/2   (fungibility — the
;;;   section is over the container's cells, not a per-leaf allowance)
;;;
;;; Run:  guile --no-auto-compile -q -L module \
;;;         -l tests/solve/test-frag-budget-section-law.scm

(use-modules (playnet test harness) (srfi srfi-1)
             (playnet solve engine) (playnet solve world) (playnet solve compile)
             (playnet solve solver) (playnet vf schemas)
             (playnet knowledge dsl shorthand))

(define wprofile (list 80.0 120.0 0.5 50.0))   ; the shed's water: ~100 m3 a period

(define (run frags demand-a demand-b)
  (set-templates! (compile-recipe
    (list (rp "pump" "Pump"))
    (list (out "o1" "crop" 1.0 "pump") (wrk "o2" 0.01 "pump") (in "o3" "water" 1.0 "pump"))))
  (ingest-located!
   (map (lambda (p) (er (string-append "m-" p) "water" #f #:place p #:qty 0.0 #:unit "m3"))
        '("farm-a" "farm-b"))
   '()
   (list (place* "shed" #:name "the watershed")
         (place* "farm-a" #:name "farm-a" #:parent "shed")
         (place* "farm-b" #:name "farm-b" #:parent "shed"))
   #:periods '(0) #:raws '("water")
   #:eco-spec-frag frags
   #:demand (list (cons (lg "crop" (cell "farm-a" 0)) demand-a)
                  (cons (lg "crop" (cell "farm-b" 0)) demand-b)))
  (for-each (lambda (p) (hash-set! *A* (cell p 0) 1000000.0)) '("farm-a" "farm-b"))
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values
                      (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
             (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))))
        (cons (V "p|pump|farm-a@0") (V "p|pump|farm-b@0"))))))

(display "\n── the fold: the container's draw is the sum of its leaves ──\n")
;; one pool over the shed; both farms want 1000 — far beyond the pool
(define pooled (run (list (frag-within "shed" '("water") wprofile)) 1000.0 1000.0))
(define total (+ (car pooled) (cdr pooled)))
(format #t "   pooled: a ~,1f  b ~,1f  total ~,1f~%" (car pooled) (cdr pooled) total)
(check "the two leaves together stay within the shed's envelope (≈100, priced past it)"
       (< total 200.0) #t)
(check "and both leaves draw — neither is the container's whole"
       (and (> (car pooled) 0.0) (> (cdr pooled) 0.0)) #t)

(display "\n── fungibility: one pool is not two half-pools ──\n")
;; farm-a wants everything, farm-b wants almost nothing: under ONE pool
;; farm-a may take what farm-b leaves; under two half-pools it may not
(define lopsided (run (list (frag-within "shed" '("water") wprofile)) 1000.0 1.0))
(define halves   (run (list (frag-within "farm-a" '("water") (map (lambda (v) (/ v 2)) wprofile))
                            (frag-within "farm-b" '("water") (map (lambda (v) (/ v 2)) wprofile)))
                      1000.0 1.0))
(format #t "   one pool, lopsided: a ~,1f   two half-pools: a ~,1f~%" (car lopsided) (car halves))
(check "under one pool, farm-a draws more than a half-pool allows"
       (> (car lopsided) (+ (car halves) 5.0)) #t)
(check "and the pool's total still holds what the halves' total holds (same envelope)"
       (< (abs (- (+ (car lopsided) (cdr lopsided))
                  (+ (car pooled) (cdr pooled))))
          (* 0.25 total))
       #t)

(test-summary!)
