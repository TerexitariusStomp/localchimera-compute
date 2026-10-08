;;; bench-io.scm — the REAL national: a sector-rich input-output economy.
;;;
;;; S sectors in L tiers (a layered I-O DAG: each sector consumes `deg` inputs from
;;; lower tiers + labour; tier-0 draws an eco-capped raw; the top tier is final
;;; demand). Tiled over a P-province GRID (4-neighbour adjacency) × T periods.
;;; Transport runs only on MOVABLE goods along grid edges; storage only on STORABLE
;;; goods, period→period+1. Built two ways from ONE spec:
;;;   • monolithic  — one activity matrix, solve-native-c (gradient-reg engine)
;;;   • decomposed  — one scope per province, inter-province transport = boundary
;;;                   links, solve-decomposed (Anderson ADMM, C+OpenMP over scopes)
;;;
;;; Run:  guile --no-auto-compile -q -L module module/playnet/planner/bench-io.scm
;;;       PLANNER_OMP=1 OMP_NUM_THREADS=6 guile … (parallel decomposed)

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner solve compile)
             (playnet planner solve solver))
(define (secs th) (let ((t0 (get-internal-run-time))) (call-with-values th (lambda a (cons (/ (- (get-internal-run-time) t0) (* 1.0 internal-time-units-per-second)) a)))))

;; ── the I-O spec (deterministic, reproducible) ──────────────────────────────
;; A REALISTIC input-output table is SHALLOW: most sectors are assembled from a
;; few basic commodities + labour, so the Leontief inverse converges in a couple
;; of terms and the longest production chain is short (this is what keeps a real
;; economy well-conditioned — a strict deep tier-chain is an artefact, not reality).
;; Three levels: primary (raw+labour) → secondary (from primary) → tertiary (from
;; primary+secondary, final demand on the top band). Max dependency depth = 3.
(define S 240)            ; sectors
(define NP0 24)           ; [0,NP0)  primary   — raw + labour
(define NP1 96)           ; [NP0,NP1) secondary — from primary
(define NF 60)            ; final-demand sectors = the top NF of tertiary
(define DEG 6)            ; input degree (inputs per sector)
(define (primary? s) (< s NP0))
(define (final? s) (>= s (- S NF)))
(define (movable? s) (= 0 (modulo s 3)))    ; ~1/3 of goods ship
(define (storable? s) (= 0 (modulo s 5)))   ; ~1/5 store across periods
;; inputs of sector s: DEG basic goods drawn (deterministically) from lower levels
(define (inputs-of s)
  (let ((ub (cond ((< s NP0) 0) ((< s NP1) NP0) (else NP1))))
    (if (= ub 0) '()
        (delete-duplicates (map (lambda (k) (modulo (+ (* s 7) (* k 13)) ub)) (iota DEG))))))
(define ICO (/ 0.6 DEG))                     ; per-input coeff ⇒ column-sum 0.6 (fast Leontief, shallow)

;; province grid R×C, 4-neighbour adjacency
(define (grid-neighbours P)
  (let* ((C (inexact->exact (ceiling (sqrt P)))) (R (inexact->exact (ceiling (/ P C)))) (nb (make-vector P '())))
    (do ((p 0 (+ p 1))) ((= p P) nb)
      (let ((r (quotient p C)) (c (modulo p C)))
        (for-each (lambda (d) (let* ((rr (+ r (car d))) (cc (+ c (cdr d))) (q (+ (* rr C) cc)))
                    (when (and (>= rr 0) (< rr R) (>= cc 0) (< cc C) (< q P)) (vector-set! nb p (cons q (vector-ref nb p))))))
                  '((-1 . 0) (1 . 0) (0 . -1) (0 . 1)))))))

;; ── monolithic builder: ONE activity matrix over goods=(sector . cell) ──────
(define DEM 50.0)
;; finals-first warm levels: propagate final demand DOWN the I-O DAG so each good's
;; warm ≈ what its consumers need (the deep-DAG analogue of build-world's cascade —
;; without it the solver thrashes finding a feasible interior). Depends only on the
;; global I-O spec, so compute once.
;; seed EVERY good with a small ε (not 0) ⇒ delivered(g)=ε>0 at the warm point ⇒
;; a strictly-feasible Leontief interior ⇒ ensure-feasible is a no-op (no slow phase-I).
(define EPS 2.0)
(define NEED
  (let ((nd (make-vector S 0.0)))
    (do ((s 0 (+ s 1))) ((= s S)) (vector-set! nd s (if (final? s) DEM EPS)))
    (do ((s (- S 1) (- s 1))) ((< s 0))     ; inputs are always lower-indexed ⇒ one high→low sweep
      (for-each (lambda (j) (vector-set! nd j (+ (vector-ref nd j) (* ICO (vector-ref nd s))))) (inputs-of s)))
    nd))
(define (build-io P T)
  (let* ((ncell (* P T)) (cellof (lambda (p t) (+ (* p T) t))) (nb (grid-neighbours P))
         (gid (make-hash-table)) (ng 0)
         (g! (lambda (good c) (let ((key (cons good c))) (or (hash-ref gid key) (let ((i ng)) (set! ng (+ ng 1)) (hash-set! gid key i) i)))))
         (acts '()) (na 0))
    (define (act! flows labour lcell warm) (set! acts (cons (vector na flows labour lcell warm) acts)) (set! na (+ na 1)))
    ;; production: each sector in each cell
    (do ((p 0 (+ p 1))) ((= p P)) (do ((t 0 (+ t 1))) ((= t T))
      (let ((c (cellof p t)))
        (do ((s 0 (+ s 1))) ((= s S))
          (let* ((o (g! s c))
                 (ins (if (primary? s)
                          (list (cons (g! 'raw c) (- ICO)))
                          (map (lambda (j) (cons (g! j c) (- ICO))) (inputs-of s)))))
            (act! (cons (cons o 1.0) ins) 0.25 c (max 0.05 (vector-ref NEED s))))))))
    ;; storage: storable goods, period t → t+1
    (do ((p 0 (+ p 1))) ((= p P)) (do ((t 0 (+ t 1))) ((= t (- T 1)))
      (do ((s 0 (+ s 1))) ((= s S)) (when (storable? s)
        (act! (list (cons (g! s (cellof p t)) -1.0) (cons (g! s (cellof p (+ t 1))) 1.0)) 0.03 (cellof p t) 0.02)))))
    ;; transport: movable goods along grid edges, same period
    (do ((p 0 (+ p 1))) ((= p P)) (for-each (lambda (q) (when (> q p)   ; one direction per undirected edge (both dirs as separate cols)
      (do ((t 0 (+ t 1))) ((= t T))
        (do ((s 0 (+ s 1))) ((= s S)) (when (movable? s)
          (act! (list (cons (g! s (cellof p t)) -1.0) (cons (g! s (cellof q t)) 1.0)) 0.08 (cellof p t) 0.02)
          (act! (list (cons (g! s (cellof q t)) -1.0) (cons (g! s (cellof p t)) 1.0)) 0.08 (cellof q t) 0.02))))))
      (vector-ref nb p)))
    ;; assemble forms (mirrors build-world)
    (let ((n na) (flowsby (make-vector ng '())) (forms '()) (labform '()) (bycell (make-vector ncell '())))
      (for-each (lambda (a)
                  (for-each (lambda (fc) (vector-set! flowsby (car fc) (cons (cons (vector-ref a 0) (cdr fc)) (vector-ref flowsby (car fc))))) (vector-ref a 1))
                  (when (> (vector-ref a 2) 0.0) (let ((c (vector-ref a 3))) (vector-set! bycell c (cons (cons (vector-ref a 0) (vector-ref a 2)) (vector-ref bycell c))))))
                acts)
      (let ((raw? (make-vector ng #f)))
        (do ((p 0 (+ p 1))) ((= p P)) (do ((t 0 (+ t 1))) ((= t T))
          (let ((r (hash-ref gid (cons 'raw (cellof p t))))) (when r (vector-set! raw? r #t)))))
        (do ((lg 0 (+ lg 1))) ((= lg ng)) (unless (vector-ref raw? lg) (set! forms (cons (mk-bar 0.0 (vector-ref flowsby lg)) forms)))))
      ;; demand on final-tier goods
      (do ((p 0 (+ p 1))) ((= p P)) (do ((t 0 (+ t 1))) ((= t T))
        (do ((s 0 (+ s 1))) ((= s S)) (when (final? s)
          (let ((lg (hash-ref gid (cons s (cellof p t))))) (when lg (set! forms (cons (mk-des (mk-bar 0.0 (vector-ref flowsby lg)) DEM 1000.0) forms))))))))
      ;; per-cell labour cap + labform
      (do ((c 0 (+ c 1))) ((= c ncell))
        (let ((lst (vector-ref bycell c)))
          (unless (null? lst)
            (set! forms (cons (mk-bar (* 1.0 S 12.0) (map (lambda (al) (cons (car al) (- (cdr al)))) lst)) forms))   ; labour cap ~ generous
            (set! labform (append lst labform)))))
      ;; eco cap on raw
      (do ((p 0 (+ p 1))) ((= p P)) (do ((t 0 (+ t 1))) ((= t T))
        (let ((lg (hash-ref gid (cons 'raw (cellof p t))))) (when lg (set! forms (cons (mk-bar 1e5 (vector-ref flowsby lg)) forms))))))
      ;; x ≥ 0
      (do ((ai 0 (+ ai 1))) ((= ai n)) (set! forms (cons (mk-bar 0.0 (list (cons ai 1.0))) forms)))
      (let ((x0 (make-vector n 0.05)))
        (for-each (lambda (a) (vector-set! x0 (vector-ref a 0) (vector-ref a 4))) acts)
        (values forms labform n (fold (lambda (f a) (+ a (length (f-coeffs f)))) 0 forms) x0)))))

;; ── the full stack: auto-Jacobi + gap-stop (+ OMP via PLANNER_OMP) on the national
(set! *osqp-fallback* #f)
(define (run-io P T)
  (let* ((b (call-with-values (lambda () (build-io P T)) list))
         (forms (car b)) (labform (cadr b)) (n (caddr b)) (x0 (list-ref b 4)) (C (flatten forms))
         (xf (ensure-feasible forms labform x0 solve-native-c-core)))
    ;; Mehrotra primal-dual (what auto routes dense-hub problems to)
    (let ((rp (secs (lambda () (solve-native-c-pd forms labform xf)))))
      (format #t "    ~3ax~2a  n=~6a  MEHROTRA-C  iters ~3a  ~6,1fs  met ~5,1f%~%"
              P T n (caddr rp) (car rp) (* 100. (mean-fill C (cadr rp)))) (force-output))
    C))
(format #t "~%==== national I-O scaling: matrix-free Mehrotra primal-dual ====~%")
(run-io 9 8)
;(run-io 20 8)
;(run-io 40 8)
(newline)
