;;; bench-backends.scm — native-C vs OSQP (cold) vs OSQP (warm) on the same built problem.
;;;
;;; Same P×T line-network bread economy as bench-located. We build ONCE, then solve three
;;; ways and report solve wall-clock + fraction of demand met (+ OSQP iterations). Tests
;;; whether OSQP and/or a warm start beat the native IC(0)-PCG kernel on the located plan.
;;;
;;; Run:  guile -L module/playnet/planner module/playnet/planner/bench-backends.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner solve solver))
(define (msx t0) (/ (* 1000.0 (- (get-internal-real-time) t0)) internal-time-units-per-second))

(define (build-grid P T)
  (declare-world! #:places (map (lambda (i) (list (format #f "p~a" i) 0.0 (* 0.01 i))) (iota P))
                  #:periods (iota T) #:templates *base-templates*
                  #:storable '("bread") #:movable '("grain") #:tau 0.001 #:hold 0.001
                  #:neighbours (map (lambda (i) (cons (format #f "p~a" i)
                                                      (filter (lambda (x) x) (list (and (> i 0) (format #f "p~a" (- i 1)))
                                                                                   (and (< i (- P 1)) (format #f "p~a" (+ i 1)))))))
                                    (iota P)))
  (for-each (lambda (pl) (for-each (lambda (t) (let ((c (cell pl t)))
    (hash-set! *cap* (lg "soil" c) 1000.0) (hash-set! *A* c 1000.0) (hash-set! *demand* (lg "bread" c) 10.0))) *periods*)) *places*))

(define (metpct x idx)
  (let ((baked (hash-fold (lambda (k i a) (if (string-prefix? "p|bake|" k) (+ a (vector-ref x i)) a)) 0.0 idx))
        (dem   (hash-fold (lambda (g d a) (+ a d)) 0.0 *demand*)))
    (* 100.0 (min 1.0 (/ baked (max 1e-9 dem))))))

(format #t "~%==== backend comparison (same built problem) ====~%")
(format #t "                          native-c          OSQP cold          OSQP warm~%")
(format #t "   P×T   activities   ms     met%      ms    iters met%     ms    iters met%~%")
(for-each (lambda (d)
  (let ((P (car d)) (T (cdr d)))
    (build-grid P T)
    (call-with-values build-located
      (lambda (forms labform ncol cols goods raws idx)
        (let* ((x0 (located-warm cols ncol idx))
               (tn (get-internal-real-time)) (xn (car (call-with-values (lambda () (solve-native-c forms labform x0)) list))) (mn (msx tn))
               (tc (get-internal-real-time)) (xc (car (call-with-values (lambda () (solve-osqp forms labform ncol)) list)))    (mc (msx tc)) (ic (car *osqp-last*))
               (tw (get-internal-real-time)) (xw (car (call-with-values (lambda () (solve-osqp forms labform ncol x0)) list))) (mw (msx tw)) (iw (car *osqp-last*)))
          (format #t "  ~3@ax~2@a  ~7@a   ~6,0f ~5,1f   ~6,0f ~6@a ~5,1f   ~6,0f ~6@a ~5,1f~%"
                  P T ncol mn (metpct xn idx) mc ic (metpct xc idx) mw iw (metpct xw idx))
          (force-output))))))
  '((60 . 8) (120 . 10) (250 . 12) (500 . 12)))
(newline)
