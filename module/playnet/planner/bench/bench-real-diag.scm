;;; bench-real-diag.scm — where does the wall-clock go on the real I-O solve?
;;; Builds Run A (reproduce) once and times each phase separately, isolating the
;;; native path-following kernel from the OSQP fallback.
;;; Run: guile --no-auto-compile -q -L module module/playnet/planner/bench-real-diag.scm

(use-modules (srfi srfi-1) (ice-9 format) (ice-9 match))
(use-modules (playnet planner solve compile)
             (playnet planner solve solver))
(define (ms th) (let ((t0 (get-internal-real-time)))
  (call-with-values th (lambda a (cons (/ (* 1000.0 (- (get-internal-real-time) t0)) internal-time-units-per-second) a)))))

(define IO (call-with-input-file "docs/data/wiod/wiod2014.sexp" read))
(define (fld k) (cdr (assq k (cdr IO))))
(define N (car (fld 'n)))
(define GO (car (fld 'gross-output)))
(define FDR (car (fld 'final-demand-raw)))
(define HOURS (car (fld 'hours)))
(define ATRIP (fld 'a-triples))
(define DEMAND (make-vector N 0.0)) (define STOCK (make-vector N 0.0))
(do ((g 0 (+ g 1))) ((= g N)) (let ((f (vector-ref FDR g)))
  (vector-set! DEMAND g (max 0.0 f)) (vector-set! STOCK g (max 0.0 (- f)))))
(define (vsum v) (let loop ((j 0)(s 0.0)) (if (= j N) s (loop (+ j 1) (+ s (vector-ref v j))))))
(define TOTH (vsum HOURS))

(define (A-apply v) (let ((out (make-vector N 0.0)))
  (for-each (match-lambda ((i j a) (vector-set! out i (+ (vector-ref out i) (* a (vector-ref v j)))))) ATRIP) out))
(define (seed eps it tol) (let ((x (make-vector N 0.0)) (term (make-vector N 0.0)))
  (do ((g 0 (+ g 1))) ((= g N)) (vector-set! term g (+ (vector-ref DEMAND g) eps)))
  (let loop ((k 0)) (do ((g 0 (+ g 1))) ((= g N)) (vector-set! x g (+ (vector-ref x g) (vector-ref term g))))
    (let ((nt (A-apply term)) (m 0.0)) (do ((g 0 (+ g 1))) ((= g N)) (set! m (max m (abs (vector-ref nt g)))))
      (if (or (>= k it) (< m tol)) x (begin (set! term nt) (loop (+ k 1))))))))
(define (build Lcap)
  (let ((flowsby (make-vector N '())) (labform '()) (forms '()))
    (do ((j 0 (+ j 1))) ((= j N)) (vector-set! flowsby j (cons (cons j 1.0) (vector-ref flowsby j))))
    (for-each (match-lambda ((i j a) (vector-set! flowsby i (cons (cons j (- a)) (vector-ref flowsby i))))) ATRIP)
    (do ((g 0 (+ g 1))) ((= g N)) (let ((b (mk-bar (vector-ref STOCK g) (vector-ref flowsby g))) (d (vector-ref DEMAND g)))
      ;; the balance wall stays for every good; a demanded good adds its desire (w = D,
      ;; or WIOD_DES_W) — the same program as bench-real.scm since the 2026-09 fix
      (set! forms (cons b forms))
      (when (> d 0.0) (set! forms (cons (mk-des b d (or (and=> (getenv "WIOD_DES_W") string->number) d)) forms)))))
    (let ((co '())) (do ((j 0 (+ j 1))) ((= j N)) (let ((go (vector-ref GO j)) (h (vector-ref HOURS j)))
      (when (and (> go 0.0) (> h 0.0)) (let ((e (/ h go))) (set! co (cons (cons j (- e)) co)) (set! labform (cons (cons j e) labform))))))
      (set! forms (cons (mk-bar Lcap co) forms)))
    (do ((j 0 (+ j 1))) ((= j N)) (set! forms (cons (mk-bar 0.0 (list (cons j 1.0))) forms)))
    ;; a costless column (no inputs, no hours) is unbounded in this program — hold it under its published output (bench-real.scm)
    (let ((has-input (make-vector N #f)))
      (for-each (match-lambda ((i j a) (vector-set! has-input j #t))) ATRIP)
      (do ((j 0 (+ j 1))) ((= j N))
        (when (and (not (vector-ref has-input j)) (<= (vector-ref HOURS j) 0.0))
          (set! forms (cons (mk-bar (max (vector-ref GO j) 1.0) (list (cons j -1.0))) forms)))))
    (values forms labform)))

(call-with-values (lambda () (build (* 1.05 TOTH)))
  (lambda (forms labform)
    (let* ((x0 (seed 1.0 200 1e-3))
           (C (flatten forms))
           (rf (ms (lambda () (ensure-feasible forms labform x0 solve-native-c-core)))))
      (let ((xf (cadr rf)))
        (format #t "~%n=~a  forms=~a  nnz≈~a~%" N (cnt C) (length ATRIP))
        (format #t "ensure-feasible : ~8,1f ms~%" (car rf))
        ;; native path-following ALONE (no fallback)
        (let ((rn (ms (lambda () (call-with-values (lambda () (solve-native-c-core forms labform xf 1.0)) list)))))
          (match (cadr rn) ((x t cg nt conv? . _)
            (format #t "native-c-core   : ~8,1f ms   met ~5,2f%  newton ~a  cg ~a  converged? ~a~%"
                    (car rn) (* 100.0 (mean-fill C x)) nt cg conv?)))
          ;; OSQP alone (the fallback path), if available
          (if (osqp-available?)
              (let ((ro (ms (lambda () (false-if-exception
                              (call-with-values (lambda () (solve-osqp forms labform N xf)) (lambda (xo . _) xo)))))))
                (let ((xo (cadr ro)))
                  (format #t "solve-osqp      : ~8,1f ms   met ~5,2f%~%"
                          (car ro) (if xo (* 100.0 (mean-fill C xo)) -1.0))))
              (format #t "solve-osqp      : (osqp unavailable)~%"))
          (format #t "~%fallback floor = ~a%% ; native met above ⇒ OSQP skipped, below ⇒ OSQP runs~%"
                  (* 100 *osqp-fallback-metfloor*)))))))
(newline)
