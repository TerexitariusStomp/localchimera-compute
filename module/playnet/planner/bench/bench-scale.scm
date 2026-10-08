;;; bench-scale.scm — current monolithic scaling on the block-sparse spacetime mesh.
;;; Re-measures Newton steps, CG iters, wall-clock, met with the CURRENT engine
;;; (gradient-regularized Newton + conv?-gated OSQP fallback) so the doc's
;;; complexity table reflects reality. build-world = the space-time mesh
;;; (per-cell labour/eco, storage(time)+transport(space) moves; n ≈ 3·P·T·K).
;;;
;;; Run:  guile --no-auto-compile -q -L module module/playnet/planner/bench-scale.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner solve solver))
;; build-world — the block-sparse mesh this benchmark measures on. It used to
;; ride along inside the engine's §9; it is bench apparatus, so it lives here.
(primitive-load (or (and=> (current-filename) (lambda (f) (string-append (dirname f) "/world.scm")))
                    (%search-load-path "playnet/planner/bench/world.scm")
                    "module/playnet/planner/bench/world.scm"))
(set! *backend* 'native)
(define (timed th) (let ((t0 (get-internal-run-time))) (call-with-values th (lambda a (cons (/ (* 1000.0 (- (get-internal-run-time) t0)) internal-time-units-per-second) a)))))

(define (run P T K)
  (call-with-values (lambda () (build-world P T K))
    (lambda (forms labform n nnz x0)
      (let* ((res (timed (lambda () (solve-native-c forms labform x0))))
             (ms (car res)) (x (cadr res)) (cg (cadddr res)) (nt (list-ref res 4)))
        (format #t "  ~3a ~3a ~2a  ~7a  ~8a   ~4a  ~6a  ~7,0f  ~5,1f  ~4,0f%~%"
                P T K n nnz nt cg ms (/ (* 1000.0 ms) (max 1 n)) (* 100.0 (mean-fill (flatten forms) x)))
        (force-output)))))

(format #t "~%==== monolithic scaling, block-sparse spacetime mesh (gradient-reg engine) ====~%")
(format #t "    P   T  K       n      nnz   newton    cg      ms    µs/n   met~%")
(for-each (lambda (cfg) (run (car cfg) (cadr cfg) (caddr cfg)))
  (list '(4 4 4) '(8 8 4) '(12 12 4) '(16 16 5) '(22 22 5) '(32 32 5) '(44 44 5) '(60 60 5)))
(newline)
