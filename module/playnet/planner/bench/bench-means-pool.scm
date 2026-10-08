;;; bench-means-pool.scm — what the shared bar costs, measured.
;;;
;;; The means-pool formulation (docs/planning/federation/patchwork-scopes-containment.md)
;;; puts one Σ bar over every cell a means serves. That row touches every cell —
;;; the dense-hub shape playnet.typ §"Sparse by nature" names as the case that
;;; raises κ — so the honest question is the price of the bar against the same
;;; capacity granted per cell. Work-plan step 6, the half measurable today: the
;;; bar INSIDE one located solve. (The consensus row ACROSS scope solves is the
;;; open thread — solve-decomposed couples goods, not capacity, and bench-decomp
;;; measures that coupling's rounds.)
;;;
;;; A line of P places, one period. Every place demands `thing`; a recipe turns
;;; Svc|m + labour into things. Two worlds with the SAME aggregate capacity:
;;;   per-cell   each place its own C unit-hours of m   (P independent caps)
;;;   pooled     one supplier bar of P·C spanning all P  (the means-pool form)
;;;
;;; Run: guile --no-auto-compile -q -L module module/playnet/planner/bench/bench-means-pool.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner solve compile)
             (playnet planner solve solver))
(define (msx t0) (/ (* 1000.0 (- (get-internal-real-time) t0)) internal-time-units-per-second))

(define C 48.0)          ; unit-hours of m per place-equivalent

(define (setup-world P pooled?)
  (let ((places (map (lambda (i) (format #f "p~a" i)) (iota P))))
    (declare-world! #:places (map (lambda (p i) (list p 40.0 (+ -74.0 (* 0.01 i)))) places (iota P))
                    #:spans '((0 "2026-03-03" "2026-03-03"))
                    #:templates (list (list "p-make" '(("thing" . 1.0))
                                            (list (cons (svc-good "m") 1.0)) 0.2 '(("gen" . 0.2)) '() '() '() '()))
                    #:resource-suppliers (if pooled?
                                             (list (list "pool" '("m") (map (lambda (p) (cell p 0)) places)
                                                         (* C P) #t))
                                             '()))
    (for-each (lambda (p)
                (hash-set! *demand* (lg "thing" (cell p 0)) 10.0)
                (hash-set! *A* (cell p 0) 100.0)
                (unless pooled? (hash-set! *cap* (lg (svc-good "m") (cell p 0)) C)))
              places)))

(define (run-case P pooled?)
  (setup-world P pooled?)
  (let* ((t0 (get-internal-real-time)))
    (call-with-values build-located
      (lambda (forms labform ncol cols goods raws idx)
        (let* ((build-ms (msx t0))
               (t1 (get-internal-real-time))
               (x  (car (call-with-values
                            (lambda () (solve-native forms labform (located-warm cols ncol idx)))
                          list)))
               (solve-ms (msx t1))
               (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0))))
               (made (fold (lambda (p a) (+ a (V (string-append "p|p-make|" p "@0"))))
                           0.0 *places*)))
          (list build-ms solve-ms ncol made))))))

(format #t "~%==== the shared bar vs per-cell caps — same aggregate capacity ====~%")
(format #t "    P   form      build(ms)  solve(ms)   cols    Σ made~%")
(for-each
 (lambda (P)
   (for-each
    (lambda (pooled?)
      (let ((r (run-case P pooled?)))
        (format #t "  ~4d  ~8a  ~9,1f  ~9,1f  ~5d  ~8,2f~%"
                P (if pooled? "pooled" "per-cell")
                (car r) (cadr r) (caddr r) (cadddr r))))
    '(#f #t)))
 '(50 200 800))
(format #t "~%    (the pooled bar is ONE budget spanning P cells; per-cell is that~%")
(format #t "     capacity granted afresh at each — the bar is what makes it a pool)~%")
