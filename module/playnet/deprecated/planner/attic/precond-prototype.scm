;;; precond-prototype.scm — does an (I−A)-Neumann preconditioner beat jacobi on the
;;; real WIOD Newton system? Measured in Scheme BEFORE any kernel.c work.
;;;
;;; The interior-point Hessian is  H = Σ_k cv_k a_k a_kᵀ + ridge·I  with three groups:
;;;   • balance/des forms  → (I−A)ᵀ W (I−A)   (W = diag of balance curvatures)  — the DENSE part
;;;   • x≥0 bound barriers → D_bound = diag(t/x_j²)                               — diagonal
;;;   • labour cap         → cv_lab · ℓ ℓᵀ                                        — rank-1
;;; Candidate preconditioner:  M⁻¹ = (I−A)⁻¹ W⁻¹ (I−A)⁻ᵀ, each (I−A)⁻¹ applied by a
;;; truncated Neumann series Σ_{0}^{K} A^k (Horner, K matvecs) — the same upstream
;;; propagation as recipe-backtrace. M⁻¹H ≈ I + (I−A)⁻¹W⁻¹(I−A)⁻ᵀ(D_bound+lab), so CG
;;; should converge fast IF the diagonal/labour part is small vs the balance coupling.
;;;
;;; We build H at a representative WORKING point (x = 0.7·seed, mid-path t) — where the
;;; demand penalties are ACTIVE (the dense coupling is live) — and count PCG iterations
;;; to ‖r‖/‖r₀‖<1e-6 for jacobi vs Neumann(K), then weigh the MATVEC BUDGET:
;;;   jacobi   : iters × 1 matvec        (the bar to beat ≈ 161 CG/Newton from the solve)
;;;   neumann  : iters × (1 + 2K) matvecs
;;; Run: guile --no-auto-compile -q -L module module/playnet/deprecated/planner/attic/precond-prototype.scm

;; self-contained (no planner.scm needed): builds its own H + PCG. Run COMPILED
;; (no --no-auto-compile) so the 733k matvec loops JIT — interpreted is ~50× slower.
(define-module (playnet deprecated planner attic precond-prototype)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:export (IO fld N GO FDR HOURS ATRIP DEMAND STOCK vsum TOTH NNZ AI AJ AV A-apply
            At-apply neu-inv neu-invT seed SEED X T RIDGE DELIV WBAL DBND ELL LCAP
            SLAB CVLAB MATVECS Hv HDIAG dot axpy! pcg jac neu B))

(use-modules (srfi srfi-1) (srfi srfi-4) (ice-9 format) (ice-9 match))
(define IO (call-with-input-file "docs/data/wiod/wiod2014.sexp" read))
(define (fld k) (cdr (assq k (cdr IO))))
(define N (car (fld 'n))) (define GO (car (fld 'gross-output)))
(define FDR (car (fld 'final-demand-raw))) (define HOURS (car (fld 'hours))) (define ATRIP (fld 'a-triples))
(define DEMAND (make-vector N 0.0)) (define STOCK (make-vector N 0.0))
(do ((g 0 (+ g 1))) ((= g N)) (let ((f (vector-ref FDR g)))
  (vector-set! DEMAND g (max 0.0 f)) (vector-set! STOCK g (max 0.0 (- f)))))
(define (vsum v) (let loop ((j 0)(s 0.0)) (if (= j N) s (loop (+ j 1) (+ s (vector-ref v j))))))
(define TOTH (vsum HOURS))

;; ── sparse matvecs:  A[i,j]=a (good i consumed by activity j) ────────────────
;; pack triples into typed arrays once → tight indexed loops (lists are too slow)
(define NNZ (length ATRIP))
(define AI (make-s32vector NNZ)) (define AJ (make-s32vector NNZ)) (define AV (make-f64vector NNZ))
(let loop ((ts ATRIP) (k 0)) (unless (null? ts) (match (car ts) ((i j a)
  (s32vector-set! AI k i) (s32vector-set! AJ k j) (f64vector-set! AV k a))) (loop (cdr ts) (+ k 1))))
(define (A-apply v)  (let ((o (make-vector N 0.0)))   ; (A v)_i = Σ_j a_ij v_j
  (do ((k 0 (+ k 1))) ((= k NNZ) o)
    (let ((i (s32vector-ref AI k))) (vector-set! o i (+ (vector-ref o i) (* (f64vector-ref AV k) (vector-ref v (s32vector-ref AJ k)))))))))
(define (At-apply v) (let ((o (make-vector N 0.0)))   ; (Aᵀv)_j = Σ_i a_ij v_i
  (do ((k 0 (+ k 1))) ((= k NNZ) o)
    (let ((j (s32vector-ref AJ k))) (vector-set! o j (+ (vector-ref o j) (* (f64vector-ref AV k) (vector-ref v (s32vector-ref AI k)))))))))
;; (I−A)⁻¹ u ≈ Σ_{0}^{K} A^k u  (Horner: z←u+A z, K times); (I−A)⁻ᵀ similarly
(define (neu-inv u K)  (let ((z (vector-copy u))) (do ((k 0 (+ k 1))) ((= k K) z)
  (let ((az (A-apply z))) (do ((g 0 (+ g 1))) ((= g N)) (vector-set! z g (+ (vector-ref u g) (vector-ref az g))))))))
(define (neu-invT u K) (let ((z (vector-copy u))) (do ((k 0 (+ k 1))) ((= k K) z)
  (let ((az (At-apply z))) (do ((g 0 (+ g 1))) ((= g N)) (vector-set! z g (+ (vector-ref u g) (vector-ref az g))))))))

;; ── seed + representative working point ─────────────────────────────────────
(define (seed eps it tol) (let ((x (make-vector N 0.0)) (term (make-vector N 0.0)))
  (do ((g 0 (+ g 1))) ((= g N)) (vector-set! term g (+ (vector-ref DEMAND g) eps)))
  (let loop ((k 0)) (do ((g 0 (+ g 1))) ((= g N)) (vector-set! x g (+ (vector-ref x g) (vector-ref term g))))
    (let ((nt (A-apply term)) (m 0.0)) (do ((g 0 (+ g 1))) ((= g N)) (set! m (max m (abs (vector-ref nt g)))))
      (if (or (>= k it) (< m tol)) x (begin (set! term nt) (loop (+ k 1))))))))
(define SEED (seed 1.0 200 1e-3))
(define X (let ((x (make-vector N 0.0))) (do ((j 0 (+ j 1))) ((= j N)) (vector-set! x j (max 1e-3 (* 0.7 (vector-ref SEED j))))) x))
(define T 0.1)  (define RIDGE 1e-7)
;; delivered(g) = ((I−A)x)_g ; balance slack s_g = STOCK_g + delivered_g
(define DELIV (let ((ax (A-apply X)) (o (make-vector N 0.0)))
  (do ((g 0 (+ g 1))) ((= g N)) (vector-set! o g (- (vector-ref X g) (vector-ref ax g)))) o))
;; W_g = balance curvature: demand good → des penalty 2w/D² (active since x<seed); else t/s²
(define WBAL (make-vector N 0.0))
(do ((g 0 (+ g 1))) ((= g N))
  (let* ((d (vector-ref DEMAND g)) (s (+ (vector-ref STOCK g) (vector-ref DELIV g))))
    (vector-set! WBAL g (if (> d 0.0) (/ (* 2.0 1000.0) (* d d))     ; des weight 1000
                            (/ T (max 1e-12 (* s s)))))))
;; D_bound_j = t/x_j² (the x≥0 barrier) ; labour rank-1 cv_lab ℓℓᵀ
(define DBND (let ((o (make-vector N 0.0))) (do ((j 0 (+ j 1))) ((= j N))
  (vector-set! o j (/ T (max 1e-12 (expt (vector-ref X j) 2))))) o))
(define ELL (let ((o (make-vector N 0.0))) (do ((j 0 (+ j 1))) ((= j N))
  (let ((go (vector-ref GO j)) (h (vector-ref HOURS j))) (when (and (> go 0.) (> h 0.)) (vector-set! o j (/ h go))))) o))
(define LCAP (* 1.05 TOTH))
(define SLAB (let ((u 0.0)) (do ((j 0 (+ j 1))) ((= j N)) (set! u (+ u (* (vector-ref ELL j) (vector-ref X j))))) (- LCAP u)))
(define CVLAB (/ T (max 1e-12 (* SLAB SLAB))))

;; ── H·v = (I−A)ᵀ W (I−A) v + D_bound v + cv_lab ℓ(ℓᵀv) + ridge v ─────────────
(define MATVECS 0)
(define (Hv v)
  (set! MATVECS (+ MATVECS 1))
  (let* ((iav (let ((av (A-apply v)) (o (make-vector N 0.0)))   ; (I−A)v
                (do ((g 0 (+ g 1))) ((= g N)) (vector-set! o g (- (vector-ref v g) (vector-ref av g)))) o))
         (wiav (let ((o (make-vector N 0.0))) (do ((g 0 (+ g 1))) ((= g N))
                 (vector-set! o g (* (vector-ref WBAL g) (vector-ref iav g)))) o))
         (atw (At-apply wiav))                                  ; (I−A)ᵀ (W (I−A)v) = wiav − Aᵀwiav
         (ld (let ((u 0.0)) (do ((j 0 (+ j 1))) ((= j N)) (set! u (+ u (* (vector-ref ELL j) (vector-ref v j))))) u))
         (o (make-vector N 0.0)))
    (do ((g 0 (+ g 1))) ((= g N))
      (vector-set! o g (+ (- (vector-ref wiav g) (vector-ref atw g))     ; balance coupling
                          (* (vector-ref DBND g) (vector-ref v g))       ; bound diagonal
                          (* CVLAB (vector-ref ELL g) ld)                ; labour rank-1
                          (* RIDGE (vector-ref v g)))))
    o))
(define HDIAG (let ((o (make-vector N 0.0)))   ; diag(H) for jacobi: (1+a_ii?)... approx Σ structural
  ;; diag = Σ_g W_g (I−A)_{g,j}² + D_bound_j + cv_lab ℓ_j² + ridge ; (I−A)_{g,j}=δ−a_gj
  (do ((j 0 (+ j 1))) ((= j N)) (vector-set! o j (+ (vector-ref DBND j) (* CVLAB (expt (vector-ref ELL j) 2)) RIDGE)))
  ;; add W_j·1 for the diagonal (g=j) term of (I−A): coeff (1−a_jj)²≈1
  (do ((g 0 (+ g 1))) ((= g N)) (vector-set! o g (+ (vector-ref o g) (vector-ref WBAL g))))
  ;; add Σ_g W_g a_gj² off the diagonal contributions to column j
  (for-each (match-lambda ((i j a) (vector-set! o j (+ (vector-ref o j) (* (vector-ref WBAL i) a a))))) ATRIP)
  o))

(define (dot a b) (let ((s 0.0)) (do ((i 0 (+ i 1))) ((= i N) s) (set! s (+ s (* (vector-ref a i) (vector-ref b i)))))))
(define (axpy! y al x) (do ((i 0 (+ i 1))) ((= i N)) (vector-set! y i (+ (vector-ref y i) (* al (vector-ref x i))))))
;; PCG solving H d = b with preconditioner apply (lambda (r) -> z)
(define (pcg b apply-Minv tol maxit)
  (let ((x (make-vector N 0.0)) (r (vector-copy b)) (z #f) (p #f) (rz 0.0) (b0 (sqrt (dot b b))))
    (set! z (apply-Minv r)) (set! p (vector-copy z)) (set! rz (dot r z))
    (let loop ((k 0))
      (if (or (>= k maxit) (< (sqrt (dot r r)) (* tol b0))) k
          (let* ((hp (Hv p)) (al (/ rz (dot p hp))))
            (axpy! x al p) (axpy! r (- al) hp)
            (let* ((z2 (apply-Minv r)) (rz2 (dot r z2)) (be (/ rz2 rz)))
              (set! p (let ((np (vector-copy z2))) (axpy! np be p) np)) (set! rz rz2)
              (loop (+ k 1))))))))

(define (jac r) (let ((o (make-vector N 0.0))) (do ((i 0 (+ i 1))) ((= i N)) (vector-set! o i (/ (vector-ref r i) (vector-ref HDIAG i)))) o))
(define (neu K) (lambda (r) (let ((y (neu-invT r K))) (do ((g 0 (+ g 1))) ((= g N)) (vector-set! y g (/ (vector-ref y g) (max 1e-30 (vector-ref WBAL g))))) (neu-inv y K))))

;; representative RHS b = H·(random) so it's in range
(define B (Hv (let ((o (make-vector N 0.0))) (do ((j 0 (+ j 1))) ((= j N)) (vector-set! o j (sin (* 0.7 j)))) o)))
(format #t "~%H at x=0.7·seed, t=~a   (W demand=2000/D², bound & labour barriers live)~%" T)
(format #t "  budget = fundamental matvecs (A or Aᵀ apply): jacobi=iters·2, neumann=iters·(2+2K)~%")
(format #t "  ~12a  ~6a  ~10a~%" "precond" "iters" "matvec-budget")
(for-each
  (lambda (spec)
    (let* ((K (car spec)) (apply (caddr spec))
           (its (pcg B apply 1e-4 150))
           (budget (* its (+ 2 (* 2 (or K 0))))))
      (format #t "  ~12a  ~6a  ~10a~a~%" (cadr spec) its budget (if (>= its 150) " (capped!)" ""))
      (force-output)))
  (list (list #f 'jacobi jac) (list 8 'neumann-K8 (neu 8))))
(format #t "~%real-solve jacobi baseline ≈ 161 CG/Newton × 2 = ~~322 matvec-budget/Newton~%")
(newline)
