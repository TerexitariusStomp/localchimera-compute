;;; bench-national.scm — national-scale solve with the CURRENT engine.
;;; Located line-network (transport+storage spacetime mesh), the realistic spatial
;;; model — near-linear, unlike build-world's all-goods-everywhere transport.
;;; Reports the convex monolith at rising size toward ~national (~150k activities).
;;;
;;; Run:  guile --no-auto-compile -q -L module module/playnet/planner/bench-national.scm

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

(define (run P T)
  (build-grid P T)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x0 (located-warm cols ncol idx)) (t0 (get-internal-real-time))
             (r (call-with-values (lambda () (solve-native-c forms labform x0)) list))
             (ms (msx t0)) (x (car r)) (cg (caddr r)) (nt (cadddr r)))
        (format #t "  ~4ax~3a  ~7a   ~4a  ~6a  ~6,1f s  ~5,1f µs/n  ~4,0f%~%"
                P T ncol nt cg (/ ms 1000.0) (/ (* 1000.0 ms) (max 1 ncol)) (* 100.0 (mean-fill (flatten forms) x)))
        (force-output)))))

(format #t "~%==== national-scale convex monolith, located mesh (current engine) ====~%")
(format #t "    P×T        n      newton    cg      time       µs/n     met~%")
(for-each (lambda (c) (run (car c) (cadr c)))
  (list '(400 12) '(800 16) '(1200 20)))   ; ~28k, ~94k, ~156k activities
(newline)
