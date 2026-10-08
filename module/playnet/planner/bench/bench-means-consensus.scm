;;; bench-means-consensus.scm — the consensus row at scale, measured.
;;;
;;; allocate-means-consensus (engine/federation-solve.scm) settles one shared bar
;;; across sovereign scope solves by equalising the dual on each scope's cap.
;;; means-consensus-test pins its correctness at n=2; this bench asks the scale
;;; question (patchwork-scopes-containment.md §5 item 7): how do rounds and
;;; wall time grow with the number of scopes, and does a warm start pay?
;;;
;;; The update is per-scope parallel-shaped — each round probes every scope
;;; once and moves each allocation toward the mean dual — so rounds should be
;;; roughly n-independent and wall time ≈ n × rounds × one-scope solve.
;;;
;;; Worlds: n one-place scopes sharing the recipe from means-consensus-test,
;;; demand_i = 5 + 3·i (deterministic spread, no randomness), bar = 15·n.
;;; Cold = the default equal split; warm = the cold rest point with scope 0
;;; perturbed +10% (the function renormalises the init onto the bar).
;;; One extra row takes γ from 0.5 to 1.0 at n=8: does the full step
;;; oscillate, or settle faster? Hitting the 40-round budget IS a finding.
;;;
;;; Run: guile --no-auto-compile -q -L module module/playnet/planner/bench/bench-means-consensus.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner solve compile)
             (playnet planner solve solver))
(define (msx t0) (/ (* 1000.0 (- (get-internal-real-time) t0)) internal-time-units-per-second))

(define (tpl) (list "p-make" '(("thing" . 1.0))
                    (list (cons (svc-good "m") 1.0)) 0.2 '(("gen" . 0.2)) '() '() '() '()))

;; one sovereign scope: a single place, the means capped at the allocation
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

(define (scopes-for n)
  (map (lambda (i) (cons (format #f "scope-~a" i)
                         (make-scope (format #f "p~a" i) (+ 5.0 (* 3.0 i)))))
       (iota n)))

;; run the row once; report (allocs rounds ms spread)
(define* (run-once n #:key (init #f) (gamma 0.5))
  (let* ((total (* 15.0 n))
         (t0 (get-internal-real-time)))
    (call-with-values
        (lambda () (allocate-means-consensus (scopes-for n) "m" total
                                             #:gamma gamma
                                             #:init init))
      (lambda (allocs duals rounds)
        (let* ((ms  (msx t0))
               (mus (map cdr duals))
               (hi  (apply max mus))
               (lo  (apply min mus))
               (spread (if (> hi 0.0) (/ (- hi lo) hi) 0.0)))
          (list (map cdr allocs) rounds ms spread))))))

(format #t "~%==== the consensus row at scale — rounds, wall time, warm starts ====~%")
(format #t "    n   cold rnds  cold ms    warm rnds  warm ms    dual spread~%")
(for-each
 (lambda (n)
   (let* ((cold (run-once n))
          ;; warm: the cold rest with scope 0 nudged +10% — the live shape,
          ;; where yesterday's split seeds today's
          (warm-init (cons (* 1.1 (car (car cold))) (cdr (car cold))))
          (warm (run-once n #:init warm-init)))
     (format #t "  ~3d  ~9d  ~9,1f  ~9d  ~9,1f  ~11,3f~%"
             n (cadr cold) (caddr cold) (cadr warm) (caddr warm) (cadddr cold))))
 '(2 4 8 16))

(format #t "~%    γ=1.0 at n=8 (full step; 40-round budget):~%")
(let ((g1 (run-once 8 #:gamma 1.0)))
  (format #t "    n=8 γ=1.0: ~a rounds, ~,1f ms, dual spread ~,3f~a~%"
          (cadr g1) (caddr g1) (cadddr g1)
          (if (>= (cadr g1) 40) "  — hit the round budget: the full step does not settle" "")))

(format #t "~%    (cold = equal split; warm = the cold rest, scope 0 +10%,~%")
(format #t "     renormalised by the function; spread = (max μ − min μ)/max μ at rest)~%")
