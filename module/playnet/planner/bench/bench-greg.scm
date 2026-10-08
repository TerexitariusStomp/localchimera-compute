;;; bench-greg.scm — gradient-regularized native Newton vs fixed-ridge baseline.
;;;
;;; Measures the Doikov–Nesterov gradient-regularized step (λ = c·√‖g‖, *kern-greg*=c)
;;; against the fixed-Tikhonov baseline (*kern-greg*=0) on the SAME built problems,
;;; reporting Newton steps, total CG iterations, convergence flag, met%, and wall-clock.
;;; The point of interest is the FLAT/spatially-coupled case where the baseline native
;;; wanders (Newton-bound) and falls back to OSQP.
;;;
;;; Run:  guile --no-auto-compile -q -L module module/playnet/planner/bench-greg.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner solve solver))
(define (msx t0) (/ (* 1000.0 (- (get-internal-real-time) t0)) internal-time-units-per-second))

;; same line-network bread grid as bench-backends (cheap transport = flat coupling)
(define (build-grid P T tau)
  (declare-world! #:places (map (lambda (i) (list (format #f "p~a" i) 0.0 (* 0.01 i))) (iota P))
                  #:periods (iota T) #:templates *base-templates*
                  #:storable '("bread") #:movable '("grain") #:tau tau #:hold 0.001
                  #:neighbours (map (lambda (i) (cons (format #f "p~a" i)
                                                      (filter (lambda (x) x) (list (and (> i 0) (format #f "p~a" (- i 1)))
                                                                                   (and (< i (- P 1)) (format #f "p~a" (+ i 1)))))))
                                    (iota P)))
  (for-each (lambda (pl) (for-each (lambda (t) (let ((c (cell pl t)))
    (hash-set! *cap* (lg "soil" c) 1000.0) (hash-set! *A* c 1000.0) (hash-set! *demand* (lg "bread" c) 10.0))) *periods*)) *places*))

;; native-c-core directly → (met ms N CG conv); optional Newton caps
(define* (probe-core greg #:optional (cmid *kern-newton-mid*) (cfin *kern-newton-final*))
  (set! *kern-greg* greg) (set! *kern-newton-mid* cmid) (set! *kern-newton-final* cfin)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x0 (ensure-feasible forms labform (located-warm cols ncol idx) solve-native-c-core))
             (t0 (get-internal-real-time)))
        (call-with-values (lambda () (solve-native-c-core forms labform x0))
          (lambda (x t cg nt conv?)
            (list (* 100.0 (mean-fill (flatten forms) x)) (msx t0) nt cg conv?)))))))

;; the REAL entry point (with OSQP fallback) → (met ms)
(define (probe-e2e greg)
  (set! *kern-greg* greg)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x0 (located-warm cols ncol idx)) (t0 (get-internal-real-time))
             (x (car (call-with-values (lambda () (solve-native-c forms labform x0)) list))))
        (list (* 100.0 (mean-fill (flatten forms) x)) (msx t0))))))

(define dmid *kern-newton-mid*) (define dfin *kern-newton-final*)
(define (pr label r) (format #t "  ~16a met ~5,1f  ms ~7,0f  N ~4@a  CG ~6@a  ~a~%"
                             label (car r) (cadr r) (caddr r) (cadddr r) (if (list-ref r 4) "conv" "STALL")))
(define (run-row label)
  (pr (string-append label " base")  (probe-core 0.0 dmid dfin))
  (pr "  greg Ĥ₀=0.1"               (probe-core 0.1 dmid dfin))
  (pr "  greg cap×4"                 (probe-core 0.1 (* 4 dmid) (* 4 dfin)))
  (set! *kern-newton-mid* dmid) (set! *kern-newton-final* dfin)
  (let ((b (probe-e2e 0.0)) (g (probe-e2e 0.1)))
    (format #t "  ~16a e2e(+OSQP fallback): base met ~5,1f ms ~6,0f | greg met ~5,1f ms ~6,0f~%~%"
            "" (car b) (cadr b) (car g) (cadr g))))

(format #t "~%==== adaptive gradient-regularization (native-c, IC(0)-PCG) ====~%")
(for-each (lambda (d) (build-grid (car d) (cadr d) (caddr d))
            (run-row (format #f "grid ~ax~a" (car d) (cadr d))))
  '((60 8 0.001) (120 10 0.001) (250 12 0.001)))
(setup-space 0.002) (run-row "space-cheap")
(setup-space 0.04)  (run-row "space-dear")
(newline)
