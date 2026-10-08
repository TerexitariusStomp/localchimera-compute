;;; bench-resolve.scm — warm start on a RE-SOLVE (metabolism), where it should matter.
;;;
;;; Cold-solve a P×T economy, then PERTURB demand (+20% at half the cells, same problem
;;; shape) and re-solve two ways: COLD (heuristic start) vs WARM (from the previous
;;; solution x*). Reports OSQP iterations + wall-clock for each. Warm-starting from a
;;; nearby prior plan is the metabolic case (small change ⇒ few iterations).
;;;
;;; Run:  guile -L module/playnet/planner module/playnet/planner/bench-resolve.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner solve solver))
(define (msx t0) (/ (* 1000.0 (- (get-internal-real-time) t0)) internal-time-units-per-second))

(define (build-grid P T bump)
  (declare-world! #:places (map (lambda (i) (list (format #f "p~a" i) 0.0 (* 0.01 i))) (iota P))
                  #:periods (iota T) #:templates *base-templates*
                  #:storable '("bread") #:movable '("grain") #:tau 0.001 #:hold 0.001
                  #:neighbours (map (lambda (i) (cons (format #f "p~a" i)
                                                      (filter (lambda (x) x) (list (and (> i 0) (format #f "p~a" (- i 1)))
                                                                                   (and (< i (- P 1)) (format #f "p~a" (+ i 1)))))))
                                    (iota P)))
  (let ((k 0))
    (for-each (lambda (pl) (for-each (lambda (t) (let ((c (cell pl t)))
      (hash-set! *cap* (lg "soil" c) 1000.0) (hash-set! *A* c 1000.0)
      (hash-set! *demand* (lg "bread" c) (if (and bump (even? k)) 12.0 10.0))   ; perturb: +20% at half the cells
      (set! k (+ k 1)))) *periods*)) *places*)))

(format #t "~%==== warm start on a re-solve (OSQP), 250×12 = 17,726 activities ====~%")
(build-grid 250 12 #f)
(define x* (call-with-values build-located (lambda (forms lf ncol cols goods raws idx)
             (car (call-with-values (lambda () (solve-osqp forms lf ncol)) list)))))   ; the prior plan
(build-grid 250 12 #t)                                                                  ; demand perturbed (+20% at half)
(call-with-values build-located (lambda (forms lf ncol cols goods raws idx)
  (let* ((tc (get-internal-real-time)) (xc (car (call-with-values (lambda () (solve-osqp forms lf ncol)) list)))    (mc (msx tc)) (ic (car *osqp-last*))
         (tw (get-internal-real-time)) (xw (car (call-with-values (lambda () (solve-osqp forms lf ncol x*)) list))) (mw (msx tw)) (iw (car *osqp-last*)))
    (format #t "  re-solve COLD (heuristic start):  ~5,0f ms  ~a iters~%" mc ic)
    (format #t "  re-solve WARM (from prior plan):  ~5,0f ms  ~a iters~%" mw iw)
    (format #t "  → warm/cold time = ~,2f×, iters = ~,2f×~%~%" (/ mw (max 1e-9 mc)) (/ (exact->inexact iw) (max 1 ic))))))
