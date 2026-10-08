;;; bench-located.scm — scaling benchmark for the LOCATED engine (planner.scm).
;;;
;;; A P×T spacetime grid: the bread chain (grow→mill→bake) at every cell, soil + labour
;;; capped per cell, bread demanded at every cell and STORABLE across periods (storage
;;; columns), and grain MOVABLE between places (transport columns). We time build-located
;;; + solve-native-c and report activities (decision variables), balances, wall-clock, and
;;; the fraction of demand met. Scales places to show how big an economy this laptop runs.
;;;
;;; Run:  guile -L module/playnet/planner module/playnet/planner/bench-located.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner solve solver))

(define (ms-since t0) (/ (* 1000.0 (- (get-internal-real-time) t0)) internal-time-units-per-second))

(define (build-grid P T)
  ;; places on a line so km() is finite; templates = grow (soil→grain), mill (grain→flour), bake (flour→bread);
  ;; bread carries across periods (storage), grain ships between places (transport); the transport
  ;; NETWORK is a line — each town adjacent to i±1 (O(P) edges, not O(P²))
  (declare-world! #:places (map (lambda (i) (list (format #f "p~a" i) 0.0 (* 0.01 i))) (iota P))
                  #:periods (iota T) #:templates *base-templates*
                  #:storable '("bread") #:movable '("grain") #:tau 0.001 #:hold 0.001
                  #:neighbours (map (lambda (i) (cons (format #f "p~a" i)
                                                      (filter (lambda (x) x) (list (and (> i 0) (format #f "p~a" (- i 1)))
                                                                                   (and (< i (- P 1)) (format #f "p~a" (+ i 1)))))))
                                    (iota P)))
  (for-each (lambda (pl)
    (for-each (lambda (t)
      (let ((c (cell pl t)))
        (hash-set! *cap* (lg "soil" c) 1000.0)         ; raw for grow
        (hash-set! *A* c 1000.0)                        ; labour pool at the cell
        (hash-set! *demand* (lg "bread" c) 10.0)))      ; demand bread everywhere
      *periods*))
    *places*))

(define (met x idx)                                    ; (total bread baked . total bread demanded)
  (let ((baked (hash-fold (lambda (k i a) (if (string-prefix? "p|bake|" k) (+ a (vector-ref x i)) a)) 0.0 idx))
        (dem   (hash-fold (lambda (g d a) (+ a d)) 0.0 *demand*)))
    (cons baked dem)))

(set! *backend* 'auto)                                 ; OSQP for qc-free, native-c for EMP/congestion
(format #t "~%==== located engine — scaling benchmark (auto backend) ====~%")
(format #t "   P×T   cells   activities   balances   build ms   solve ms    met%~%")
(for-each (lambda (dims)
  (let ((P (car dims)) (T (cdr dims)))
    (build-grid P T)
    (let* ((tb (get-internal-real-time))
           (res (call-with-values build-located list))
           (build-ms (ms-since tb)))
      (apply (lambda (forms labform ncol cols goods raws idx)
        (let* ((x0 (located-warm cols ncol idx))
               (ts (get-internal-real-time))
               (sol (call-with-values (lambda () (solve forms labform x0)) list))
               (solve-ms (ms-since ts))
               (x (car sol))
               (bd (met x idx)) (baked (car bd)) (dem (cdr bd))
               (metpct (* 100.0 (min 1.0 (/ baked (max 1e-9 dem))))))
          (format #t "  ~3@ax~2@a  ~6@a   ~10@a   ~8@a   ~8,0f   ~8,0f   ~5,1f~%"
                  P T (* P T) ncol (length goods) build-ms solve-ms metpct)
          (force-output)))
        res))))
  '((20 . 5) (60 . 8) (120 . 10) (250 . 12) (500 . 12) (1000 . 12)))
(newline)
