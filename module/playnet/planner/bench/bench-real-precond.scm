;;; bench-real-precond.scm — preconditioner sweep on the real dense I-O Newton solve.
;;; auto-precond falls back to 'jacobi on dense-hub I-O (⇒ ~23k CG). The kernel also
;;; ships 'ic0, 'ic0w (IC(0)+Woodbury on hub rows — purpose-built for this), 'direct
;;; (sparse-skeleton Cholesky + CG), 'ssor. All selectable from Scheme, no recompile.
;;; Build Run A once; solve under each preconditioner; report CG / Newton / time / met.
;;; Run: guile --no-auto-compile -q -L module module/playnet/planner/bench-real-precond.scm

(use-modules (srfi srfi-1) (ice-9 format) (ice-9 match))
(use-modules (playnet planner solve compile)
             (playnet planner solve solver))
(define (ms th) (let ((t0 (get-internal-real-time)))
  (call-with-values th (lambda a (cons (/ (* 1000.0 (- (get-internal-real-time) t0)) internal-time-units-per-second) a)))))

(define IO (call-with-input-file "docs/data/wiod/wiod2014.sexp" read))
(define (fld k) (cdr (assq k (cdr IO))))
(define N (car (fld 'n))) (define GO (car (fld 'gross-output)))
(define FDR (car (fld 'final-demand-raw))) (define HOURS (car (fld 'hours)))
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

;; how many "dense" rows (the hub commodities) and the IC(0)w Schur dimension k?
(let* ((C (flatten (call-with-values (lambda () (build (* 1.05 TOTH))) (lambda (f l) f))))
       (ptr (cptr C)) (nt (cnt C)) (nnz (vector-ref ptr nt)) (df 0) (kdense 0))
  (do ((ti 0 (+ ti 1))) ((= ti nt))
    (let ((m (- (vector-ref ptr (+ ti 1)) (vector-ref ptr ti))))
      (when (> m *kern-dense-thr*) (set! df (+ df (* m m))) (set! kdense (+ kdense 1)))))
  (format #t "~%dense rows (nnz>~a): k=~a   Σm²=~,3g   nnz=~a   auto picks: ~a~%~%"
          *kern-dense-thr* kdense df nnz (auto-precond C)))

(set! *kern-precond-auto* #f)
(call-with-values (lambda () (build (* 1.05 TOTH)))
  (lambda (forms labform)
    (let ((x0 (seed 1.0 200 1e-3)))
      (format #t "  ~8a  ~9a ~7a ~8a  ~a~%" "precond" "time" "newton" "cg" "met")
      (for-each
        (lambda (pc)
          (set! *kern-precond* pc)
          (let* ((xf (ensure-feasible forms labform x0 solve-native-c-core))
                 (r (ms (lambda () (call-with-values (lambda () (solve-native-c-core forms labform xf 1.0)) list)))))
            (match (cadr r) ((x t cg nt conv? . _)
              (format #t "  ~8a  ~7,1fs ~7a ~8a  ~5,2f%~a~%"
                      pc (/ (car r) 1000.0) nt cg (* 100.0 (mean-fill (flatten forms) x))
                      (if conv? "" " (capped)"))
              (force-output)))))
        '(jacobi ic0w direct ic0)))))
(newline)
