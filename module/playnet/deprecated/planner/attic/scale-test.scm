;;; scale-test.scm — does NEAR-LINEAR actually hold on realistic structure?
;;;
;;; The earlier benchmark (spacetime-compiled) was a single-cell chain — one
;;; shared labour constraint coupling every column, PATHOLOGICALLY dense for a
;;; sparse method. Real economies are BLOCK-SPARSE: each cell has its own local
;;; labour, local goods balance, and couples to neighbours only through a few
;;; moves. This builds that structure at scale and measures it, with a real CSR
;;; sparse backend (flat arrays, tight H·v — no list overhead) and a diagonal-
;;; preconditioned matrix-free Newton-CG.
;;;
;;;   world: P places × T periods; each cell a chain of K goods (g0←…←g_{K-1}←raw),
;;;          per-cell labour, per-cell ecological cap, storage (time) + transport
;;;          (space) moves; every cell demands g0.   n ≈ 3·P·T·K activities.
;;;
;;; Run:  guile -L module module/playnet/planner/scale-test.scm

(use-modules (srfi srfi-1) (ice-9 format))

;; ── vectors ──────────────────────────────────────────────────────────────────
(define (vdot a b) (let ((s 0.0) (n (vector-length a))) (do ((i 0 (+ i 1))) ((= i n) s) (set! s (+ s (* (vector-ref a i) (vector-ref b i)))))))
(define (vcopy a) (let* ((n (vector-length a)) (r (make-vector n))) (do ((i 0 (+ i 1))) ((= i n) r) (vector-set! r i (vector-ref a i)))))

;; ── linear forms → CSR ───────────────────────────────────────────────────────
;; form = (kind const coeffs Dw) ; coeffs = list (index . value)
;;   'bar : slack s(x)=const+Σv·x > 0  (balance / labour / eco / x≥0)
;;   'des : demand gap, Dw = (D . w)
(define (mk-bar const coeffs) (list 'bar const coeffs #f))
(define (mk-des form D w)     (list 'des (cadr form) (caddr form) (cons D w)))
(define (f-kind f) (car f)) (define (f-const f) (cadr f)) (define (f-coeffs f) (caddr f)) (define (f-Dw f) (cadddr f))
;; csr = #(nt nnz ptr const kind D w idx val)
(define (cnt c) (vector-ref c 0)) (define (cptr c) (vector-ref c 2)) (define (cconst c) (vector-ref c 3))
(define (ckind c) (vector-ref c 4)) (define (cD c) (vector-ref c 5)) (define (cw c) (vector-ref c 6))
(define (cidx c) (vector-ref c 7)) (define (cval c) (vector-ref c 8))
(define (flatten forms)
  (let* ((nt (length forms))
         (nnz (fold (lambda (f a) (+ a (length (f-coeffs f)))) 0 forms))
         (ptr (make-vector (+ nt 1) 0)) (const (make-vector nt 0.0))
         (kind (make-vector nt 0)) (D (make-vector nt 1.0)) (w (make-vector nt 0.0))
         (idx (make-vector (max 1 nnz) 0)) (val (make-vector (max 1 nnz) 0.0)))
    (let loop ((fs forms) (ti 0) (off 0))
      (if (null? fs) (begin (vector-set! ptr nt off) (vector nt nnz ptr const kind D w idx val))
          (let ((f (car fs)))
            (vector-set! ptr ti off) (vector-set! const ti (f-const f))
            (when (eq? (f-kind f) 'des)
              (vector-set! kind ti 1) (vector-set! D ti (car (f-Dw f))) (vector-set! w ti (cdr (f-Dw f))))
            (let put ((cs (f-coeffs f)) (o off))
              (if (null? cs) (loop (cdr fs) (+ ti 1) o)
                  (begin (vector-set! idx o (caar cs)) (vector-set! val o (cdar cs)) (put (cdr cs) (+ o 1))))))))))

;; ── CSR numerics (the fast inner loops) ──────────────────────────────────────
(define *kappa* 0.02)
(define (term-values C x)
  (let* ((nt (cnt C)) (ptr (cptr C)) (idx (cidx C)) (val (cval C)) (sv (make-vector nt 0.0)))
    (do ((ti 0 (+ ti 1))) ((= ti nt) sv)
      (let ((s (vector-ref (cconst C) ti)))
        (do ((k (vector-ref ptr ti) (+ k 1))) ((= k (vector-ref ptr (+ ti 1))))
          (set! s (+ s (* (vector-ref val k) (vector-ref x (vector-ref idx k))))))
        (vector-set! sv ti s)))))
(define (term-coeffs C t sv)
  (let* ((nt (cnt C)) (cv (make-vector nt 0.0)))
    (do ((ti 0 (+ ti 1))) ((= ti nt) cv)
      (let ((s (vector-ref sv ti)))
        (if (= (vector-ref (ckind C) ti) 1)
            (when (< s (vector-ref (cD C) ti)) (let ((Dd (vector-ref (cD C) ti))) (vector-set! cv ti (/ (* 2.0 (vector-ref (cw C) ti)) (* Dd Dd)))))
            (when (> s 1e-12) (vector-set! cv ti (/ t (* s s)))))))))
(define (csr-hv C cv v n)
  (let ((r (make-vector n 0.0)) (ptr (cptr C)) (idx (cidx C)) (val (cval C)) (nt (cnt C)))
    (do ((ti 0 (+ ti 1))) ((= ti nt))
      (let ((c (vector-ref cv ti)))
        (unless (= c 0.0)
          (let ((dot 0.0) (lo (vector-ref ptr ti)) (hi (vector-ref ptr (+ ti 1))))
            (do ((k lo (+ k 1))) ((= k hi)) (set! dot (+ dot (* (vector-ref val k) (vector-ref v (vector-ref idx k))))))
            (let ((cd (* c dot)))
              (do ((k lo (+ k 1))) ((= k hi)) (let ((i (vector-ref idx k))) (vector-set! r i (+ (vector-ref r i) (* cd (vector-ref val k)))))))))))
    (do ((i 0 (+ i 1))) ((= i n)) (vector-set! r i (+ (vector-ref r i) (* 1e-7 (vector-ref v i)))))
    r))
(define (csr-diag C cv n)
  (let ((d (make-vector n 1e-7)) (ptr (cptr C)) (idx (cidx C)) (val (cval C)) (nt (cnt C)))
    (do ((ti 0 (+ ti 1))) ((= ti nt))
      (let ((c (vector-ref cv ti)))
        (unless (= c 0.0)
          (do ((k (vector-ref ptr ti) (+ k 1))) ((= k (vector-ref ptr (+ ti 1))))
            (let ((i (vector-ref idx k)) (vk (vector-ref val k))) (vector-set! d i (+ (vector-ref d i) (* c vk vk))))))))
    d))
(define (csr-grad C labform t sv n)
  (let ((g (make-vector n 0.0)) (ptr (cptr C)) (idx (cidx C)) (val (cval C)) (nt (cnt C)))
    (do ((ti 0 (+ ti 1))) ((= ti nt))
      (let ((s (vector-ref sv ti)))
        (if (= (vector-ref (ckind C) ti) 1)
            (let ((Dd (vector-ref (cD C) ti)) (ww (vector-ref (cw C) ti)))
              (when (< s Dd) (let ((gc (/ (* -2.0 ww (- Dd s)) (* Dd Dd))))
                (do ((k (vector-ref ptr ti) (+ k 1))) ((= k (vector-ref ptr (+ ti 1))))
                  (let ((i (vector-ref idx k))) (vector-set! g i (+ (vector-ref g i) (* gc (vector-ref val k)))))))))
            (when (> s 1e-12) (let ((gc (/ t s)))
              (do ((k (vector-ref ptr ti) (+ k 1))) ((= k (vector-ref ptr (+ ti 1))))
                (let ((i (vector-ref idx k))) (vector-set! g i (- (vector-ref g i) (* gc (vector-ref val k)))))))))))
    (for-each (lambda (ic) (vector-set! g (car ic) (+ (vector-ref g (car ic)) (* *kappa* (cdr ic))))) labform)
    g))
(define (obj-value C labform t x sv)
  (let ((acc (fold (lambda (ic a) (+ a (* *kappa* (cdr ic) (vector-ref x (car ic))))) 0.0 labform)) (nt (cnt C)))
    (do ((ti 0 (+ ti 1))) ((= ti nt) acc)
      (let ((s (vector-ref sv ti)))
        (if (= (vector-ref (ckind C) ti) 1)
            (let ((Dd (vector-ref (cD C) ti))) (when (< s Dd) (set! acc (+ acc (* (vector-ref (cw C) ti) (expt (/ (- Dd s) Dd) 2))))))
            (set! acc (+ acc (if (<= s 1e-12) 1e12 (* (- t) (log s))))))))))

;; ── diagonal-preconditioned matrix-free CG ───────────────────────────────────
(define (pcg C cv b diag n)
  (let* ((x (make-vector n 0.0)) (r (vcopy b))
         (z (let ((v (make-vector n))) (do ((i 0 (+ i 1))) ((= i n) v) (vector-set! v i (/ (vector-ref r i) (vector-ref diag i))))))
         (p (vcopy z)) (its 0))
    (let loop ((k 0) (rz (vdot r z)))
      (if (or (>= k (min 300 (+ n 2))) (< (vdot r r) 1e-14)) (values x its)
          (let* ((Hp (csr-hv C cv p n)) (al (/ rz (max 1e-30 (vdot p Hp)))))
            (set! its (+ its 1))
            (do ((i 0 (+ i 1))) ((= i n))
              (vector-set! x i (+ (vector-ref x i) (* al (vector-ref p i))))
              (vector-set! r i (- (vector-ref r i) (* al (vector-ref Hp i)))))
            (let* ((z2 (let ((v (make-vector n))) (do ((i 0 (+ i 1))) ((= i n) v) (vector-set! v i (/ (vector-ref r i) (vector-ref diag i))))))
                   (rz2 (vdot r z2)))
              (do ((i 0 (+ i 1))) ((= i n)) (vector-set! p i (+ (vector-ref z2 i) (* (/ rz2 rz) (vector-ref p i)))))
              (loop (+ k 1) rz2)))))))

;; ── interior-point Newton along the central path ────────────────────────────
(define* (solve C labform x0 #:optional (tstart 1.0))
  (let ((n (vector-length x0)) (cgtot 0) (ntot 0))
    (let path ((t tstart) (x x0))
      (let newton ((it 0) (x x))
        (let* ((sv (term-values C x)) (g (csr-grad C labform t sv n)) (gn (sqrt (vdot g g))))
          (if (or (>= it 40) (< gn 1e-6))
              (if (<= t 0.02) (values x t cgtot ntot) (path (max 0.02 (* t 0.5)) x))
              (let* ((cv (term-coeffs C t sv))
                     (negg (let ((v (make-vector n))) (do ((i 0 (+ i 1))) ((= i n)) (vector-set! v i (- (vector-ref g i)))) v)))
                (call-with-values (lambda () (pcg C cv negg (csr-diag C cv n) n))
                  (lambda (d its)
                    (set! cgtot (+ cgtot its)) (set! ntot (+ ntot 1))
                    (let ((f0 (obj-value C labform t x sv)))
                      (let ls ((eta 1.0))
                        (let* ((y (let ((v (make-vector n))) (do ((i 0 (+ i 1))) ((= i n)) (vector-set! v i (+ (vector-ref x i) (* eta (vector-ref d i))))) v))
                               (fy (obj-value C labform t y (term-values C y))))
                          (cond ((and (< fy 1e11) (< fy (- f0 1e-9))) (newton (+ it 1) y))
                                ((< eta 1e-9) (if (<= t 0.02) (values x t cgtot ntot) (path (max 0.02 (* t 0.5)) x)))
                                (else (ls (* eta 0.5))))))))))))))))

;; ── the BLOCK-SPARSE world generator ─────────────────────────────────────────
;; activity = #(id flows labour labour-cell warm). Returns (forms labform n nnz x0).
(define* (build-world P T K #:optional (dem (lambda (p t) 100.0)))
  (let* ((ncell (* P T)) (cell (lambda (p t) (+ (* p T) t)))
         (gid (make-hash-table)) (ng 0)
         (g! (lambda (good c) (let ((key (cons good c))) (or (hash-ref gid key) (let ((i ng)) (set! ng (+ ng 1)) (hash-set! gid key i) i)))))
         (acts '()) (na 0))
    (define (act! flows labour lcell warm) (set! acts (cons (vector na flows labour lcell warm) acts)) (set! na (+ na 1)))
    (do ((p 0 (+ p 1))) ((= p P)) (do ((t 0 (+ t 1))) ((= t T))      ; production: g_i at c
      (let ((c (cell p t)))
        (do ((i 0 (+ i 1))) ((= i K))
          (let ((out (g! (* 1000 i) c)) (inp (if (< i (- K 1)) (g! (* 1000 (+ i 1)) c) (g! 'raw c))))
            (act! (list (cons out 1.0) (cons inp -1.0)) 0.3 c (+ 110.0 i)))))))
    (do ((p 0 (+ p 1))) ((= p P)) (do ((t 0 (+ t 1))) ((= t (- T 1)))  ; storage forward in time
      (do ((i 0 (+ i 1))) ((= i K))
        (act! (list (cons (g! (* 1000 i) (cell p t)) -1.0) (cons (g! (* 1000 i) (cell p (+ t 1))) 1.0)) 0.05 (cell p t) 0.02))))
    (do ((p 0 (+ p 1))) ((= p (- P 1))) (do ((t 0 (+ t 1))) ((= t T))  ; transport adjacent places
      (do ((i 0 (+ i 1))) ((= i K))
        (act! (list (cons (g! (* 1000 i) (cell p t)) -1.0) (cons (g! (* 1000 i) (cell (+ p 1) t)) 1.0)) 0.1 (cell p t) 0.02))))
    (let ((n na) (flowsby (make-vector ng '())) (forms '()) (labform '()) (bycell (make-vector ncell '())))
      (for-each (lambda (a)
                  (for-each (lambda (fc) (vector-set! flowsby (car fc) (cons (cons (vector-ref a 0) (cdr fc)) (vector-ref flowsby (car fc))))) (vector-ref a 1))
                  (when (> (vector-ref a 2) 0.0) (let ((c (vector-ref a 3))) (vector-set! bycell c (cons (cons (vector-ref a 0) (vector-ref a 2)) (vector-ref bycell c))))))
                acts)
      (do ((lg 0 (+ lg 1))) ((= lg ng)) (set! forms (cons (mk-bar 0.0 (vector-ref flowsby lg)) forms)))   ; balance ≥ 0
      (do ((p 0 (+ p 1))) ((= p P)) (do ((t 0 (+ t 1))) ((= t T))                                          ; demand g0 everywhere
        (let ((lg (hash-ref gid (cons 0 (cell p t))))) (when lg (set! forms (cons (mk-des (mk-bar 0.0 (vector-ref flowsby lg)) (dem p t) 1000.0) forms))))))
      (do ((c 0 (+ c 1))) ((= c ncell))                                                                    ; labour ≤ cap PER CELL (block-sparse)
        (let ((lst (vector-ref bycell c)))
          (unless (null? lst)
            (set! forms (cons (mk-bar (* 1000.0 K) (map (lambda (al) (cons (car al) (- (cdr al)))) lst)) forms))
            (set! labform (append lst labform)))))
      (do ((p 0 (+ p 1))) ((= p P)) (do ((t 0 (+ t 1))) ((= t T))                                          ; eco cap on raw per cell
        (let ((lg (hash-ref gid (cons 'raw (cell p t))))) (when lg (set! forms (cons (mk-bar 1e6 (vector-ref flowsby lg)) forms))))))
      (do ((ai 0 (+ ai 1))) ((= ai n)) (set! forms (cons (mk-bar 0.0 (list (cons ai 1.0))) forms)))        ; x ≥ 0
      (let ((x0 (make-vector n 0.05)))
        (for-each (lambda (a) (vector-set! x0 (vector-ref a 0) (vector-ref a 4))) acts)
        (values forms labform n (fold (lambda (f a) (+ a (length (f-coeffs f)))) 0 forms) x0)))))

;; ── run the scale sweep ──────────────────────────────────────────────────────
(define (mean-fill C x)                   ; mean (delivered/demand) over demand goods — is it a REAL solve?
  (let ((sv (term-values C x)) (nt (cnt C)) (sum 0.0) (nd 0))
    (do ((ti 0 (+ ti 1))) ((= ti nt))
      (when (= (vector-ref (ckind C) ti) 1)
        (set! nd (+ nd 1)) (set! sum (+ sum (min 1.0 (/ (vector-ref sv ti) (vector-ref (cD C) ti)))))))
    (if (> nd 0) (/ sum nd) 1.0)))
(define (timed thunk) (let ((t0 (get-internal-run-time))) (call-with-values thunk (lambda a (cons (/ (* 1000.0 (- (get-internal-run-time) t0)) internal-time-units-per-second) a)))))
(format #t "~%==== SCALE: near-linear on BLOCK-SPARSE spacetime structure ====~%")
(format #t "  P×T cells, chain K; per-cell labour & eco (block-sparse); storage+transport moves; every cell wants g0~%~%")
(format #t "   P    T   K       n      nnz   newton   cg     ms    µs/n   demand-met~%")
(for-each
 (lambda (cfg)
   (let ((P (car cfg)) (T (cadr cfg)) (K (caddr cfg)))
     (call-with-values (lambda () (build-world P T K))
       (lambda (forms labform n nnz x0)
         (let* ((C (flatten forms))
                (res (timed (lambda () (solve C labform x0))))
                (ms (car res)) (x (cadr res)) (cgtot (cadddr res)) (ntot (list-ref res 4)))
           (format #t "  ~3a  ~3a  ~2a  ~6a  ~7a   ~4a  ~5a  ~6,0f  ~6,1f  ~5,1f%~%"
                   P T K n nnz ntot cgtot ms (/ (* 1000.0 ms) (max 1 n)) (* 100.0 (mean-fill C x))))))))
 '((4 4 4) (8 8 4) (12 12 4) (16 16 5) (22 22 5) (30 30 5)))
(newline)

;; ── METABOLISM: re-solving on an event (warm vs cold) ────────────────────────
;; The plan is solved; then an event hits (a demand surge). The metabolism
;; re-adapts by WARM-STARTING from the standing plan and re-centring near the
;; boundary — a handful of Newton steps — versus a COLD solve from scratch.
(define (solve* C lf x0 . ts) (call-with-values (lambda () (apply solve C lf x0 ts)) list))
(format #t "==== METABOLISM: re-solve on an event (warm-start from the standing plan) ====~%")
(call-with-values (lambda () (build-world 8 8 4))
  (lambda (forms lf n nnz x0)
    (let* ((C (flatten forms)) (base (solve* C lf x0)) (x1 (car base)))
      (format #t "  base plan:                       ~a Newton steps, ~,1f%% met~%" (list-ref base 3) (* 100 (mean-fill C x1)))
      (call-with-values (lambda () (build-world 8 8 4 (lambda (p t) (if (= p 0) 150.0 100.0))))
        (lambda (f2 lf2 n2 z2 x02)
          (let* ((C2 (flatten f2)) (warm (solve* C2 lf2 x1 0.03)) (cold (solve* C2 lf2 x02 1.0)))
            (format #t "  --- event: demand surges ×1.5 across place 0 ---~%")
            (format #t "  WARM re-solve (from standing plan): ~a Newton steps, ~,1f%% met~%" (list-ref warm 3) (* 100 (mean-fill C2 (car warm))))
            (format #t "  COLD re-solve (from scratch):       ~a Newton steps, ~,1f%% met~%" (list-ref cold 3) (* 100 (mean-fill C2 (car cold))))
            (format #t "  ⇒ the metabolism re-adapts in ~a steps vs ~a from scratch — the fast layer beneath the plan~%"
                    (list-ref warm 3) (list-ref cold 3))))))))
(newline)
