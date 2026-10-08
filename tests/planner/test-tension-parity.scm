;;; test-tension-parity.scm — termwise Scheme ≡ C, the regression net.
;;;
;;; The refactor routed term-coeffs / csr-grad / obj-value through
;;; tension-kinds.scm (one source of truth) instead of inline `cond`. The C
;;; kernel (kernel.c) is UNCHANGED. So if the refactored Scheme matches the C
;;; kernel term-for-term on random programs, then — since the C kernel already
;;; matched the OLD Scheme (parity-assert) — the refactor preserved behavior.
;;; This is finer than parity-assert (one delivered scalar, 4 scenarios): it
;;; checks the gradient, curvature, and objective directly, at random points.
;;;
;;; Run:  guile -L . module/playnet/planner/tension-parity-test.scm

(use-modules (srfi srfi-1) (rnrs bytevectors) (ice-9 format))
(use-modules (playnet planner solve solver))
(unless (kern-available?) (begin (display "C kernel unavailable; cannot check parity\n") (exit 1)))

(define rs (seed->random-state 271828))
(define (rnd lo hi) (+ lo (* (- hi lo) (random:uniform rs))))
(define na 6)
(define (rcoeffs k) (map (lambda (_) (cons (random na rs) (rnd -1.5 1.5))) (iota k)))
(define (make-forms)                       ; a random mix of all four kinds
  (append
   (map (lambda (_) (mk-bar (rnd 0.8 2.5) (rcoeffs (+ 1 (random 3 rs))))) (iota 5))
   (map (lambda (_) (mk-des (list 'x (rnd 0.0 1.5) (rcoeffs 2)) (rnd 1.0 3.0) (rnd 0.5 2.0))) (iota 5))
   (map (lambda (_) (mk-qc (rnd -1.0 1.0) (rcoeffs 2) (rnd 0.3 1.8))) (iota 5))
   (map (lambda (_) (mk-frag (rnd 0.8 2.5) (rcoeffs (+ 1 (random 3 rs))) (rnd 0.3 1.8))) (iota 5))))
(define (xrand) (let ((v (make-vector na))) (do ((i 0 (+ i 1))) ((= i na) v) (vector-set! v i (rnd 0.0 1.0)))))
(define (maxdiff a b n) (let ((m 0.0)) (do ((i 0 (+ i 1))) ((= i n) m) (set! m (max m (abs (- (vector-ref a i) (vector-ref b i))))))))

(define (trial t)
  (let* ((forms (make-forms)) (x (xrand)) (C (flatten forms)) (nt (cnt C)) (n na)
         (sv (term-values C x))
         ;; refactored Scheme (empty labform: pk_csr_grad excludes the κ·lab term)
         (g-s (csr-grad C '() t sv n)) (cv-s (term-coeffs C t sv)) (o-s (obj-value C '() t x sv))
         ;; unchanged C kernel
         (ptr (vec->i32 (cptr C))) (idx (vec->i32 (cidx C))) (val (vec->f64 (cval C)))
         (kind (vec->i32 (ckind C))) (Dv (vec->f64 (cD C))) (wv (vec->f64 (cw C)))
         (svb (vec->f64 sv)) (gb (make-bytevector (* 8 n))) (cvb (make-bytevector (* 8 nt))))
    (k-grad nt n (bvp ptr) (bvp idx) (bvp val) (bvp kind) (bvp Dv) (bvp wv) t (bvp svb) (bvp gb))
    (k-tcoef nt (bvp kind) (bvp Dv) (bvp wv) t (bvp svb) (bvp cvb))
    (let ((o-c (k-obj nt (bvp kind) (bvp Dv) (bvp wv) t (bvp svb))))
      (list (maxdiff g-s (f64bv->vec gb n) n)
            (maxdiff cv-s (f64bv->vec cvb nt) nt)
            (abs (- o-s o-c))))))

(let loop ((trials '()) (ts '(1.0 0.5 0.1 0.02)) (k 0))
  (if (null? ts)
      (let* ((gmax (apply max (map first trials)))
             (cmax (apply max (map second trials)))
             (omax (apply max (map third trials)))
             (ok (and (< gmax 1e-9) (< cmax 1e-9) (< omax 1e-6))))
        (format #t "~%── termwise parity · refactored Scheme vs C kernel · ~a trials ──~%" k)
        (format #t "  max |Δ gradient|   = ~a~%" gmax)
        (format #t "  max |Δ curvature|  = ~a~%" cmax)
        (format #t "  max |Δ objective|  = ~a~%" omax)
        (format #t "  ~a Scheme ≡ C term-for-term ⇒ refactor preserved behavior~%~%"
                (if ok "✓" "✗"))
        (exit (if ok 0 1)))
      (loop (append trials (map (lambda (_) (trial (car ts))) (iota 8)))
            (cdr ts) (+ k 8))))
