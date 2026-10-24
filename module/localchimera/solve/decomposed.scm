;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/solve/decomposed.scm — §10: the federated decomposed solve, scopes in parallel.
;;;
;;; The whole economy is ONE convex program (solve/engine §6); a SPATIALLY
;;; coupled one is a space-time mesh whose single factorisation does not
;;; scale. This module decomposes it BY SCOPE: each scope's located program
;;; is a kernel record it can solve alone, the goods that cross its boundary
;;; are its crossing columns, and `solve-decomposed` runs the scaled-dual
;;; ADMM rounds over the records (the C kernel in batch where it is built,
;;; the Scheme reference otherwise), coordinated by the pulls on the goods
;;; they provision across their boundaries. `refine-plan` is the exact local
;;; solve at the settled pulls; the boundary oracle (solve/federation-oracle)
;;; is one scope's half of this behind a message, and the records bridge
;;; (solve/federation-solve) builds the records it is given.

(define-module (localchimera solve decomposed)
  #:use-module ((localchimera utils host) #:select (getenv get-internal-real-time internal-time-units-per-second))
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (rnrs bytevectors)
  #:use-module ((localchimera solve voice-field) #:select (voice-labform voice-report))
  #:use-module ((localchimera solve admm-link) #:select (make-exchange exchange-keys exchange-live? exchange-flow exchange-pull exchange-rho
                                                exchange-rounds allocate-caps))
  #:use-module (localchimera solve solver)
  #:use-module (localchimera solve compile)
  #:export (solve-decomposed record-plan record-crossings refine-plan crossing-alist->hash crossing-col
            crossing-key crossing-sign crossing-offset crossing-column crossing-flow crossing-side
            admm-kernel-rec admm-kernel-batch admm-scope-met admm-write-prox!))

;; the batched kernel solve crosses the FFI; Hoot has none (see the cond-expand at the batch)
(cond-expand (guile (use-modules (system foreign))) (else))

;;       coordinated by the pulls on goods they provision across their boundaries
;; ════════════════════════════════════════════════════════════════════════════
;; The whole economy is ONE convex program (§6); but a SPATIALLY-coupled one is a
;; space-time mesh whose single factorisation does not scale. Decompose by SCOPE:
;; each scope's plan is an independent interior-point solve (pk_solve, in C), all
;; run in parallel over scopes (pk_solve_many, omp — coarse-grained, the only
;; granularity that scales), coordinated ONLY through the located PULLS on the
;; goods scopes provision across their boundaries (scaled-dual ADMM, over-relaxed,
;; adaptive ρ). DIRECT-CSR: each scope's matrix is built once and the Scheme forms
;; freed (~80 B/nonzero resident), so what stays is the matrices, not the lists.
;;
;; A scope is an assoc record: 'forms (local FORMS; prox added here) · 'labform ·
;; 'x0 (start, made feasible here) · 'crossings, what the scope puts on the goods
;; it shares: a list of (local-var-idx link-key sign . offset), the scope's flow
;; on LINK-KEY being  y = sign·x + offset  — y > 0 it supplies, y < 0 it draws.
;; A column that can only give is (col key 1 . 0), one that can only take
;; (col key -1 . 0), and one measured from what the scope can give
;; (col key -1 . G): the draw on the crossing, standing at G when nothing
;; crosses (solver.scm `offset-column`). A link-key (any equal? value) names one
;; good crossing between the scopes that hold it. Returns (values plans met
;; rounds pulls): pulls = hash link-key → λ (= ρ·u, the located labour-pull on
;; that good, one number for every scope that shares it).
;; TOL — the boundary-consensus tolerance, and the single biggest lever on both
;; plan quality and provability in the federated path. It was 5e-3, which stops
;; the coordination long before the pulls are right:
;;
;;   fixture        tol      rounds   met%     certified bound     wall
;;   star  S=16     5e-3       9      99.86    7.383e2             179 ms
;;   star  S=16     1e-4      35      99.92    1.080e0             352 ms
;;   chain S=16     5e-3      87      99.89    2.624e4            1020 ms
;;   chain S=16     1e-4     105      99.92    1.680e1            1195 ms
;;   chain S=32     5e-3     155      91.39    2.761e7            2332 ms
;;   chain S=32     1e-4     247      99.79    3.166e4            3324 ms
;;
;; Three orders of magnitude on the certificate, and on a 32-scope chain EIGHT
;; POINTS of demand that the looser tolerance simply left unserved. This is not a
;; proof-quality-versus-speed trade: the old default returned a worse plan AND an
;; unprovable one, for 1.2–2× less time. Same shape as the met-plateau exit it
;; sits beside — a stopping rule that halted while there was still real progress
;; to make, and reported success.
;;
;; The bound plateaus below ~1e-4 (chain S=4 measured identical at 1e-4, 1e-5 and
;; 1e-6), so there is no reason to go tighter by default; the remaining slack is
;; the inner solves, not the pulls.
;; ── WHAT A RECORD PUTS ON ITS CROSSINGS ─────────────────────────────────────
;; One reader, for every loop that steps a good: the record's crossings, in the
;; order the record gives them.
(define (record-crossings rec)
  (let ((a (assq 'crossings rec))) (if a (cdr a) '())))
(define (crossing-col c) (car c))
(define (crossing-key c) (cadr c))
(define (crossing-sign c) (caddr c))
(define (crossing-offset c) (cdddr c))
;; an offset of nothing is kept exact, so a column that can only give or only
;; take reads and writes the very numbers it holds
(define (crossing-flow c x)                     ; the scope's signed flow, its column standing at X
  (let ((y (* (crossing-sign c) x)) (o (crossing-offset c)))
    (if (eqv? o 0) y (+ y o))))
(define (crossing-column c y)                   ; where its column stands for the signed flow Y
  (let ((o (crossing-offset c)))
    (* (crossing-sign c) (if (eqv? o 0) y (- y o)))))
(define (crossing-side c)                       ; give | take | net
  (cond ((not (eqv? (crossing-offset c) 0)) 'net)
        ((> (crossing-sign c) 0) 'give)
        (else 'take)))
(define (record-plan rec x)                     ; X read as the recipes mean it: a column measured from
  (let ((off (filter (lambda (c) (not (eqv? (crossing-offset c) 0))) (record-crossings rec))))   ; what the scope can give
    (if (null? off) x                                                                           ; answers the draw it stands for
        (let ((v (vector-copy x)))
          (for-each (lambda (c) (vector-set! v (crossing-col c) (- (vector-ref x (crossing-col c)) (crossing-offset c))))
                    off)
          v))))
(define (crossing-most-given c u)               ; the most the scope can put on the crossing, its column bounded by U
  (max 0.0 (if (> (crossing-sign c) 0)
               (crossing-flow c u)
               (exact->inexact (crossing-offset c)))))

;; ── ONE SCOPE'S KERNEL RECORD — the unit a scope can solve ALONE ────────────
;; The ADMM's per-scope state, lifted out of solve-decomposed so the same
;; construction serves a scope solving its own subproblem in its own vat
;; (solve/federation-oracle.scm): forms+prox flattened to CSR once, the Scheme forms
;; freed (direct-CSR), the prox columns FIRST so their centres are slots
;; 0..nbnd−1 of cnst/w and a round rewrites exactly those. Slots:
;;   0 nt · 1 n · 2 nlab · 3 ncross · 4 the crossings (record-crossings, in order)
;;   5 ptr 6 idx 7 val 8 kind 9 cnst 10 D 11 w · 12 labi 13 labv · 14 x · 15 scratch
;;   16 · 17 unused · 18 flat view (only the reference core asks for it)
;; The record is the same whichever core solves it: the compiled kernel reads the
;; buffers in place, the reference core reads them through `admm-flat`.
(define (admm-kernel-rec rec rho)
  (let* ((get (lambda (k) (let ((a (assq k rec))) (and a (cdr a)))))
         (bnd (record-crossings rec))                            ; the crossings, in the record's order
         ;; scaffolding: it holds the scopes together while the pulls settle,
         ;; and is not a tension anyone in the economy feels. Marked so it can
         ;; never be certified against — see mk-method.
         (prox (map (lambda (b) (mk-method (mk-qc 0.0 (list (cons (crossing-col b) 1.0)) (/ rho 2.0)))) bnd))
         (base (get 'forms)) (lab (or (get 'labform) '()))
         (C (flatten (append prox base))) (nt (cnt C))             ; prox forms FIRST → indices 0..nbnd-1
         (x0 (get 'x0)) (n (vector-length x0))
         (xf (ensure-feasible base lab x0 scope-core)) (per (+ (* 2 nt) (* 9 n))))
    (vector nt n (length lab) (length bnd) bnd                                             ; 0 nt 1 n 2 nlab 3 ncross 4 crossings
            (vec->i32 (cptr C)) (vec->i32 (cidx C)) (vec->f64 (cval C)) (vec->i32 (ckind C)) ; 5 ptr 6 idx 7 val 8 kind
            (vec->f64 (cconst C)) (vec->f64 (cD C)) (vec->f64 (cw C))                         ; 9 cnst 10 D 11 w
            (vec->i32 (list->vector (map car lab))) (vec->f64 (list->vector (map (lambda (ic) (exact->inexact (cdr ic))) lab)))  ; 12 labi 13 labv
            (vec->f64 xf) (make-bytevector (* 8 per)) #f #f                                     ; 14 x 15 scratch 16 17 unused
            #f)))                                                                             ; 18 the flat Scheme view, made on first use (admm-flat)
;; the prox centres for one scope's crossings, in their order: CENTRES are the
;; signed flows to solve against, each written as where its column stands for
;; that flow; the quadratic (ρ/2)(x − c)² is stored flattened as cnst = −c, w = ρ/2
(define (admm-write-prox! kr centres rho)
  (let ((cnst (vector-ref kr 9)) (w (vector-ref kr 11)) (j 0))
    (for-each (lambda (b c)
                (bytevector-ieee-double-native-set! cnst (* 8 j) (- (exact->inexact (crossing-column b c))))
                (bytevector-ieee-double-native-set! w (* 8 j) (/ rho 2.0))
                (set! j (+ j 1)))
              (vector-ref kr 4) centres)))
;; ── THE REFERENCE CORE'S VIEW OF A RECORD ────────────────────────────────────
;; The record's buffers as the flat program `solve-flat` takes, built once (slot 18)
;; and kept: only the prox centres and weights (the first nbnd slots of cnst and w)
;; are rewritten each round, and `admm-flat` copies just those across.
(define (admm-flat kr)
  (unless (vector-ref kr 18)
    (let* ((nt (vector-ref kr 0)) (ptr (i32bv->vec (vector-ref kr 5) (+ nt 1))) (nnz (vector-ref ptr nt)))
      (vector-set! kr 18
        (cons (vector nt nnz ptr (f64bv->vec (vector-ref kr 9) nt) (i32bv->vec (vector-ref kr 8) nt)
                      (f64bv->vec (vector-ref kr 10) nt) (f64bv->vec (vector-ref kr 11) nt)
                      (i32bv->vec (vector-ref kr 6) nnz) (f64bv->vec (vector-ref kr 7) nnz) (make-vector nt 0.0))
              (let ((labi (i32bv->vec (vector-ref kr 12) (vector-ref kr 2)))
                    (labv (f64bv->vec (vector-ref kr 13) (vector-ref kr 2))))
                (map cons (vector->list labi) (vector->list labv)))))))
  (let ((C (car (vector-ref kr 18))))
    (do ((j 0 (+ j 1)) (nbnd (length (vector-ref kr 4)))) ((= j nbnd))
      (vector-set! (cconst C) j (bytevector-ieee-double-native-ref (vector-ref kr 9) (* 8 j)))
      (vector-set! (cw C) j (bytevector-ieee-double-native-ref (vector-ref kr 11) (* 8 j))))
    (vector-ref kr 18)))
;; mean delivered/demand over the desire terms, clamped to 1, in percent — pk_meanfill's arithmetic
(define (admm-scheme-met kr)
  (let* ((C (car (admm-flat kr))) (x (f64bv->vec (vector-ref kr 14) (vector-ref kr 1)))
         (sv (term-values C x)))
    (let lp ((ti 0) (sum 0.0) (nd 0))
      (cond ((= ti (cnt C)) (if (> nd 0) (* 100. (/ sum nd)) 0.0))
            ((= (vector-ref (ckind C) ti) 1)
             (lp (+ ti 1) (+ sum (min 1.0 (/ (vector-ref sv ti) (vector-ref (cD C) ti)))) (+ nd 1)))
            (else (lp (+ ti 1) sum nd))))))
;; the batch, one scope after another, each from its own current x, in place
(define (admm-scheme-batch krs)
  (lambda ()
    (for-each (lambda (kr)
                (let* ((v (admm-flat kr)) (n (vector-ref kr 1)))
                  (call-with-values (lambda () (solve-flat (car v) (cdr v) (f64bv->vec (vector-ref kr 14) n) 1.0))
                    (lambda (x . _)
                      (do ((i 0 (+ i 1))) ((= i n))
                        (bytevector-ieee-double-native-set! (vector-ref kr 14) (* 8 i) (vector-ref x i)))))))
              krs)
    #f))
;; ── THE COMPILED KERNEL'S BATCH ──────────────────────────────────────────────
(cond-expand
 (guile
(define (i32-array ns) (vec->i32 (list->vector ns)))
(define (ptr-array bvs)              ; bytevectors → bytevector of their C addresses
  (let ((pa (make-bytevector (* 8 (max 1 (length bvs))))))
    (let lp ((i 0) (b bvs)) (if (null? b) pa
      (begin (bytevector-u64-native-set! pa (* 8 i) (pointer-address (bytevector->pointer (car b)))) (lp (+ i 1) (cdr b)))))))
;; the scope's mean fill at its current x (slot 14), in percent — by the compiled kernel
(define (admm-c-met kr)
  (* 100. (k-meanfill (vector-ref kr 0) (bvp (vector-ref kr 5)) (bvp (vector-ref kr 6)) (bvp (vector-ref kr 7))
                      (bvp (vector-ref kr 8)) (bvp (vector-ref kr 9)) (bvp (vector-ref kr 10)) (bvp (vector-ref kr 14)))))
;; the batch: pk_solve_many over a list of kernel records, in place — a thunk,
;; because the pointer tables are built once and the records they point into
;; must stay reachable for as long as the thunk is (they are closed over here)
(define (admm-c-batch krs)
  (let* ((S (length krs)) (kap (exact->inexact *kappa*))
         (rg (lambda (kr i) (vector-ref kr i)))
         (parr (lambda (i) (ptr-array (map (lambda (kr) (rg kr i)) krs))))
         (p-nts (i32-array (map (lambda (kr) (rg kr 0)) krs)))
         (p-ns  (i32-array (map (lambda (kr) (rg kr 1)) krs)))
         (p-nls (i32-array (map (lambda (kr) (rg kr 2)) krs)))
         (ps (map parr '(5 6 7 8 9 10 11 12 13 14 15)))     ; ptr idx val kind cnst D w labi labv x scr
         (pv (list->vector (map bvp ps)))
         (pp (lambda (i) (vector-ref pv i))))
    (lambda ()
      ;; the batch core walks the dial-driven schedule: the floor AND the rest
      ;; of the path dials cross here, so a round's solves run under the same
      ;; sigma, caps and tolerances the single-scope core runs under — the C
      ;; defaults stand only for a caller that never syncs
      (sync-kern-dials!)
      (k-solvemany S (bvp p-nts) (bvp p-ns) (bvp p-nls) (pp 0)(pp 1)(pp 2)(pp 3)(pp 4)(pp 5)(pp 6)(pp 7)(pp 8)
                   kap *kern-ridge* 1.0 (pp 9)(pp 10))
      ps)))
 )
 (else
  ;; pk_solve_many and pk_meanfill cross the FFI; a build without them runs every
  ;; scope through the reference core (kern-available? is #f there, so these are
  ;; never chosen).
  (define (i32-array . _)          (error "needs the compiled kernel" 'i32-array))
  (define (ptr-array . _)          (error "needs the compiled kernel" 'ptr-array))
  (define (admm-c-met . _)         (error "needs the compiled kernel" 'admm-c-met))
  (define (admm-c-batch . _)       (error "needs the compiled kernel" 'admm-c-batch))))
;; The two the federated solve and the boundary oracle call: the compiled kernel
;; when it is linked, the reference core when it is not. One scope's plan is the
;; same program either way.
(define (admm-kernel-batch krs) ((if (kern-available?) admm-c-batch admm-scheme-batch) krs))
(define (admm-scope-met kr)     ((if (kern-available?) admm-c-met admm-scheme-met) kr))

;; ── the exact local solve at the settled pulls ───────────────────────────────
;; ADMM minimises each scope INEXACTLY on purpose; once the pulls have settled,
;; each scope's problem is min f_s(x_s) + λᵀy_s with nothing left to
;; coordinate, and it is solved to full accuracy from the ADMM iterate. The
;; pull folds into `labform`, whose entries contribute κ·coeff to the
;; gradient, so a pull λ on a column that carries the flow with sign s enters
;; as (c . s·λ/κ). The prox stays centred on the agreed flow z: against the
;; bare program a scope with plenty of the good is indifferent and supplies
;; what nobody draws (287 kg against a 40 kg need, measured); at convergence
;; the augmented minimiser IS the constrained one. A qc form costs
;; w·(const + Σv·x)², so the centre enters NEGATED, as admm-write-prox!
;; stores it. The solve selects WITHOUT the dual fit (the outer certificate
;; reports with it, solver.scm *kkt-dual-fit?*) and at the floor the plan was
;; made at (`call-at-settled-floor`): a polish, not a program of its own. The
;; monolith's finish and the boundary oracle's `refine!` are this one solve.
;; A crossing-keyed alist (pulls, z, rho, centres, caps) is hashed ONCE per
;; call, not re-scanned with assoc once per crossing inside the maps over
;; BND below — the alist and bnd are both sized to the scope's own boundary
;; B, so an assoc-per-element there is O(B²) per round, repeated every ADMM
;; iteration (up to *leap-budget* of them).
(define (crossing-alist->hash alist)
  (let ((h (make-hash-table)))
    (for-each (lambda (p) (hash-set! h (car p) (cdr p))) alist)
    h))
(define (refine-plan rec x0 z pulls rho)
  "REC a scope record (forms labform crossings); X0 the plan to start from; Z
   and PULLS ((good . value) …) the signed flow agreed for this scope and the
   pull on each good; RHO a number or ((good . ρ) …).
   → (x . labform*) — X #f when the solve fails — or #f when the record has no forms."
  (let* ((get (lambda (k) (let ((a (assq k rec))) (and a (cdr a)))))
         (f0 (get 'forms))
         (bnd (record-crossings rec))
         (pulls-h (crossing-alist->hash pulls))
         (z-h (crossing-alist->hash z))
         (rho-h (and (pair? rho) (crossing-alist->hash rho)))
         (of (lambda (h b) (exact->inexact (or (hash-ref h (crossing-key b) #f) 0.0))))
         (rho-of (lambda (b) (if rho-h (exact->inexact (hash-ref rho-h (crossing-key b))) rho)))
         (kp (if (> (abs *kappa*) 1e-300) *kappa* 1.0))
         (lab* (append (or (get 'labform) '())
                       (map (lambda (b) (cons (crossing-col b) (/ (* (crossing-sign b) (of pulls-h b)) kp))) bnd)))
         (prox-z (map (lambda (b) (mk-method (mk-qc (- (crossing-column b (of z-h b)))
                                                    (list (cons (crossing-col b) 1.0))
                                                    (/ (rho-of b) 2.0))))
                      bnd)))
    (and f0
         (cons (false-if-exception
                (call-without-dual-fit
                 (lambda ()
                   (call-at-settled-floor
                    (lambda ()
                      (call-with-values (lambda () (solve-exact (append prox-z f0) lab* x0))
                        (lambda (x . _) x)))))))
               lab*))))

(define* (solve-decomposed scope-list #:key (rho 4.0) (iters 120) (tol 1e-4) (alpha 1.6)
                           (accel #t) (mmax 8) (met-eps 0.05) (met-stall 3)
                           (reconcile? #t) (refine? #t)
                           ;; WARM Z: ((link-key y …) …), the signed flows to start
                           ;; a good from, one per scope that shares it, in scope
                           ;; order — the folds' own reading of what each holds and
                           ;; asks (warm-boundary-flows) rather than a blank 0.
                           ;; Same fixed point; fewer rounds to reach it.
                           (z0 '()))
  (let* ((scopes (list->vector scope-list)) (S (vector-length scopes))
         (sref (lambda (s k) (let ((a (assq k (vector-ref scopes s)))) (and a (cdr a)))))
         (recs (make-vector S)))
    (define (f64set! bv i v) (bytevector-ieee-double-native-set! bv (* 8 i) v))
    (define (f64ref bv i) (bytevector-ieee-double-native-ref bv (* 8 i)))
    ;; build forms+prox, flatten → CSR, FREE the Scheme forms (direct-CSR)
    (do ((s 0 (+ s 1))) ((= s S))
      (vector-set! recs s (admm-kernel-rec (vector-ref scopes s) rho)))
    (define (rg s i) (vector-ref (vector-ref recs s) i))
    (define solve-all! (admm-kernel-batch (vector->list recs)))
    ;; the goods: key → the scopes that share it, each with its crossing,
    ;; ((scope . crossing) …) in scope order. A good has as many as share it.
    (define parts (make-hash-table))
    (do ((s 0 (+ s 1))) ((= s S))
      (for-each (lambda (b)
                  (let* ((k (crossing-key b)) (ps (hash-ref parts k '())))
                    (when (any (lambda (p) (= (car p) s)) ps)
                      (error "solve-decomposed: a scope holds one good twice" k))
                    (hash-set! parts k (append ps (list (cons s b))))))
                (rg s 4)))
    (define goods (hash-map->list cons parts))
    ;; the exchange (solve/admm-link.scm): every live good's signed agreed flows and its pull
    (define ex (make-exchange (map (lambda (g) (cons (car g) (length (cdr g)))) goods) z0 #:rho rho))
    (define (pos-of s k) (list-index (lambda (p) (= (car p) s)) (hash-ref parts k)))
    (define (scope-met s) (admm-scope-met (vector-ref recs s)))
    ;; the goods each scope shares, in the order of its crossings
    (define tables (map (lambda (s) (map crossing-key (rg s 4))) (iota S)))
    ;; one round: the prox centres written into every scope's record, the batch
    ;; solved in place, and each scope's signed flows read off its buffer
    (define (round! centres)
      (do ((s 0 (+ s 1))) ((= s S))
        (admm-write-prox! (vector-ref recs s) (map cdr (list-ref centres s)) (exchange-rho ex)))
      (solve-all!)
      (map (lambda (s)
             `((flows . ,(map (lambda (b) (cons (crossing-key b) (crossing-flow b (f64ref (rg s 14) (crossing-col b)))))
                              (rg s 4)))
               (met . ,(scope-met s))))
           (iota S)))
    (call-with-values
        (lambda () (exchange-rounds ex tables round! #:alpha alpha #:accel accel #:mmax mmax #:iters iters
                                    #:tol tol #:met-eps met-eps #:met-stall met-stall))
      (lambda (replies met rounds stale-rounds link-resid)
                    (let* ((plans0 (map (lambda (s) (f64bv->vec (rg s 14) (rg s 1))) (iota S)))
                           (plans plans0)
                           (pulls (let ((h (make-hash-table)))
                                    (for-each (lambda (g) (hash-set! h (car g) (exchange-pull ex (car g)))) goods) h)))
                      ;; ── THE FEDERATED CERTIFICATE ───────────────────────────
                      ;; Reported through the certificate box rather than as a
                      ;; fifth return value: this return is a four-value contract
                      ;; with several callers, and widening a positional return
                      ;; broke a test twice already today.
                      ;;
                      ;; Each scope is certified against ITS OWN program — the
                      ;; forms the caller handed in, without the ADMM's proximal
                      ;; terms. That is the honest object: the proximal term is
                      ;; scaffolding the coordinator erected, not something the
                      ;; scope asked for, and a residual measured against the
                      ;; augmented problem would flatter the result.
                      ;;
                      ;; TWO numbers, and they are NOT summable into one:
                      ;;   local   Σ per-scope certified bounds — how far each
                      ;;           scope is from optimal ON ITS OWN problem.
                      ;;   consensus  max |supplied − drawn| over the links — how
                      ;;           far the scopes are from AGREEING.
                      ;; A plan with consensus > 0 is not federation-feasible at
                      ;; all: it has scopes shipping quantities their neighbours
                      ;; are not receiving. So this is NOT yet a bound on distance
                      ;; from the federated optimum — that needs either a
                      ;; projection onto the coupling constraints or a duality
                      ;; argument over the whole coupled program. What it IS is
                      ;; the two quantities such a bound would be built from,
                      ;; reported instead of discarded.
                      ;; ── FINAL EXACT LOCAL SOLVE, at the converged pulls ──
                      ;; ADMM minimises each scope INEXACTLY on purpose: every
                      ;; round re-solves everything against updated pulls, so
                      ;; running any one solve hard is wasted work. But the
                      ;; certificate assumes each scope sits at its local optimum,
                      ;; and none do — so it certifies iterates that were never
                      ;; meant to be converged, and reports a bound two orders
                      ;; looser than the monolith's on the same economy.
                      ;;
                      ;; Once the pulls have converged (disagreement in hours ~1e-5
                      ;; here, so they have), each scope's problem is just
                      ;;   min f_s(x_s) + λᵀA_s x_s
                      ;; with no proximal term and nothing left to coordinate. Solve
                      ;; THAT to full accuracy, warm-started from the ADMM iterate,
                      ;; and certify the result. The pull folds into `labform`,
                      ;; whose entries contribute κ·coeff to the gradient — so a
                      ;; pull λ on column c enters as (c . λ/κ).
                      ;;
                      ;; The refined plans REPLACE the ADMM ones: certifying a point
                      ;; we do not return would be a certificate for a plan nobody
                      ;; has. That means consensus must be re-measured on them, and
                      ;; refinement is kept only if the TOTAL bound improves —
                      ;; tighter local optimality can cost agreement, and the total
                      ;; is the honest arbiter of that trade.
                      ;; the pull as each of scope s's columns carries it: (col . sign·λ)
                      (define (pull-of s)
                        (map (lambda (b) (cons (crossing-col b) (* (crossing-sign b) (exchange-pull ex (crossing-key b)))))
                             (rg s 4)))
                      ;; what scope s shares: the signed flow agreed for it and the pull, per good
                      (define (share-of s)
                        (values (map (lambda (b) (let ((k (crossing-key b))) (cons k (exchange-flow ex k (pos-of s k))))) (rg s 4))
                                (map (lambda (b) (let ((k (crossing-key b))) (cons k (exchange-pull ex k)))) (rg s 4))))
                      ;; the exact local solve at the converged pulls — refine-plan, the
                      ;; boundary oracle's own — from the ADMM iterate: (x . labform*) or #f
                      (define (refine s)
                        (call-with-values (lambda () (share-of s))
                          (lambda (z pulls)
                            (refine-plan (vector-ref scopes s) (list-ref plans s) z pulls (exchange-rho ex)))))
                      ;; certify the ADMM plans as they stand …
                      ;; THE CERTIFICATE SEES ONLY THE WORLD. A scope's own forms are
                      ;; prox-free today because the proximal terms are appended
                      ;; separately at solve time — but that is a fact about where the
                      ;; append happens, and every certificate below would inherit any
                      ;; method tension that ever landed here. Filtering makes the rule
                      ;; hold by construction instead of by argument; it is a no-op on
                      ;; the current call graph and a guard on the next one.
                      (define (own-forms s) (world-forms (or (sref s 'forms) '())))
                      (define (flows-of xs k)      ; each participant's signed flow on good K in the plans XS
                        (map (lambda (p) (crossing-flow (cdr p) (vector-ref (list-ref xs (car p)) (crossing-col (cdr p)))))
                             (hash-ref parts k)))
                      (define (certify-set xs labs formsf boxf)
                        (let* ((ks (map (lambda (s)
                                          (let ((f (formsf s)))
                                            (and f (kkt-report (flatten f) (list-ref labs s)
                                                               (list-ref xs s)
                                                               #:box (boxf s)))))
                                        (iota S)))
                               (ok  (and (every (lambda (k) (and k (assq-ref k 'feasible?))) ks) #t))
                               (loc (if (every (lambda (k) k) ks)
                                        (fold (lambda (k a) (+ a (assq-ref k 'gap-bound))) 0.0 ks)
                                        +inf.0))
                               ;; consensus measured ON THESE plans, not inherited
                               (res (let lp ((ks (exchange-keys ex)) (mx 0.0) (pr 0.0))
                                      (if (null? ks) (cons mx pr)
                                          (let* ((d (fold + 0.0 (flows-of xs (car ks))))
                                                 (lam (exchange-pull ex (car ks))))
                                            (lp (cdr ks) (max mx (abs d)) (+ pr (abs (* lam d)))))))))
                          ;; the per-scope gaps are carried alongside their sum.
                          ;; `local-bound` is Σ over scopes and a sum says nothing
                          ;; about its terms: a cover whose bound leapt from 2.5 to
                          ;; 58 and back to 3.9 as S doubled looked like erratic
                          ;; behaviour of the whole certificate, when the question
                          ;; that decides it — is this every scope drifting, or one
                          ;; scope carrying the total? — was one list away and
                          ;; unaskable from outside.
                          (list ok loc (car res) (cdr res)
                                (if (< loc +inf.0) (+ loc (cdr res)) +inf.0)
                                (map (lambda (k) (and k (assq-ref k 'gap-bound))) ks)
                                ;; and per-scope FEASIBILITY beside it, for the same
                                ;; reason: `feasible?` is a conjunction, and a reader
                                ;; pricing one scope's plan needs to know whether THAT
                                ;; scope's floors closed (federated-withdrawal-displacement)
                                (map (lambda (k) (and k (assq-ref k 'feasible?) #t)) ks))))
                      ;; ── RECONCILIATION: from near-optimal in VALUE to consistent
                      ;;    in QUANTITY ────────────────────────────────────────
                      ;; ADMM converges the PULLS, not the quantities. At the stop
                      ;; the scopes still disagree about what crosses — one ships
                      ;; what the other is not receiving — so the plan is a
                      ;; near-optimal valuation and not something a federation can
                      ;; act on. The bound was honest about this and named it; it
                      ;; is now closed rather than named.
                      ;;
                      ;; What makes a plan EXECUTABLE is not that the two sides
                      ;; agree to the last digit — an interior-point solve can never
                      ;; deliver that, since both approach a bound from strictly
                      ;; inside and by different residues. It is that no scope plans
                      ;; on goods nobody is sending:
                      ;;
                      ;;     drawn  ≤  supplied       on every link.
                      ;;
                      ;; A surplus at the border is waste and is reported as such; a
                      ;; DEFICIT is a plan that cannot be carried out. Requiring
                      ;; equality would be demanding of the federation something
                      ;; physics does not, and would reject every reconciliation
                      ;; that actually works.
                      ;;
                      ;; So the owner's shipment is taken as given and the consumer
                      ;; is capped at it. The cap is an ordinary barrier. A PIN
                      ;; (x ≥ z together with −x ≥ −z) would be degenerate — no
                      ;; strictly feasible point — and that construction corrupted a
                      ;; fixture earlier in this work before being removed
                      ;; structurally; it is not reintroduced here.
                      (define (crossing-of xs k)   ; → (supplied . drawn) on a live good, else #f
                        (and (exchange-live? ex k)
                             (let ((ys (flows-of xs k)))
                               (cons (fold + 0.0 (map (lambda (y) (if (> y 0.0) y 0.0)) ys))
                                     (fold + 0.0 (map (lambda (y) (if (< y 0.0) (- y) 0.0)) ys))))))
                      (define (overdraw xs)        ; max(Σ drawn − Σ supplied, 0): the unexecutable part
                        (fold (lambda (k m) (let ((c (crossing-of xs k))) (max m (- (cdr c) (car c)))))
                              0.0 (exchange-keys ex)))
                      (define (shipments xs)       ; good → what its owners will actually send
                        (let ((h (make-hash-table)))
                          (for-each (lambda (k) (hash-set! h k (max 0.0 (car (crossing-of xs k)))))
                                    (exchange-keys ex))
                          h))
                      ;; RECONCILE BY CLAMPING. Two larger constructions were tried
                      ;; first and both overshoot, for the same underlying reason: the
                      ;; question is microscopic and they answer it globally.
                      ;;
                      ;;   RE-SOLVING each scope is wrong specifically for ADMM: the
                      ;;   inner solves are TRUNCATED on purpose, so the iterate is
                      ;;   nowhere near the exact minimiser of its own subproblem and
                      ;;   the duals lag even when the primal consensus reads 3.8·10⁻⁵.
                      ;;   A full re-solve hauls the plan to wherever those stale
                      ;;   pulls point — measured on a 16-scope chain, objective
                      ;;   2.6·10¹ → 1.1·10² and the certificate to 8.7·10⁹.
                      ;;
                      ;;   PROJECTING onto the nearest feasible capped plan is better
                      ;;   in principle and still too big in practice: the projection
                      ;;   is itself an interior-point solve, so its own barrier
                      ;;   residue displaces the plan far more than the overdraw does.
                      ;;   Measured on a 16-scope star: bound 1.08 → 14.8.
                      ;;
                      ;; The overdraw is 3.8·10⁻⁵ on flows of order 10³. The smallest
                      ;; edit that makes the ensemble executable is to set each draw
                      ;; to exactly what its owner ships, and change nothing else:
                      ;;
                      ;;     drawn := supplied   wherever drawn > supplied
                      ;;
                      ;; The plan moves by exactly the overdraw, so the objective and
                      ;; the residual the certificate measures move by O(overdraw).
                      ;; The consumer draws marginally less of a good it was over-
                      ;; counting; its own balance has slack, and whether that slack
                      ;; covers the edit is not assumed — the clamped plan is put back
                      ;; through the same KKT feasibility test as any other, and the
                      ;; reconciliation is refused if any scope fails it.
                      (define (clamp xs)         ; every scope that draws held to its share of what is supplied (allocate-caps)
                        (let ((out (map vector-copy xs)))
                          (for-each
                            (lambda (k)
                              (let* ((ps (hash-ref parts k))
                                     (ys (flows-of out k))
                                     (held (allocate-caps ys)))
                                ;; a column is written where its scope is cut, and nowhere else
                                (for-each (lambda (p y c)
                                            (when (< y c)
                                              (vector-set! (list-ref out (car p)) (crossing-col (cdr p))
                                                           (crossing-column (cdr p) c))))
                                          ps ys held)))
                            (exchange-keys ex))
                          out))
                      ;; ── CAPS VALID FOR EVERY COUPLING-FEASIBLE PLAN ─────────
                      ;; The radius below the reconciliation is derived by capping each
                      ;; boundary column at the crossing THIS plan agreed, which makes
                      ;; the bound a statement about the best plan using those
                      ;; crossings — weaker than the monolithic claim, and weaker in a
                      ;; way that is easy to quote as if it were not.
                      ;;
                      ;; The unrestricted claim needs caps no particular plan chose.
                      ;; They exist, and the coupling graph holds them: what a
                      ;; scope GIVES is bounded by its own capacity once what it
                      ;; takes is bounded, and what it TAKES by what is given
                      ;; upstream, because drawn ≤ supplied holds at every
                      ;; coupling-feasible point. Alternate the two to a fixpoint. Bounds only ever fall,
                      ;; so it terminates; on a chain the information walks one hop per
                      ;; round from the granary outward, which is the same diameter the
                      ;; ADMM pays for and here costs only arithmetic.
                      ;; Takes the scope DIMENSIONS, not a plan, because it never
                      ;; depended on one: the caps come from the constraints and the
                      ;; coupling graph, and the plan was only ever supplying a vector
                      ;; length. It was being run three times per solve — for the
                      ;; unrefined, refined and clamped certifications — to compute the
                      ;; same answer each time.
                      (define (federated-bounds ns)
                        (let* ((Cs (map (lambda (s) (flatten (own-forms s))) (iota S)))
                               (us (map (lambda (s) (make-vector (list-ref ns s) +inf.0)) (iota S))))
                          (let loop ((k 0))
                            (if (> k (+ S 2)) us
                                (let ((before (map (lambda (v) (vector-copy v)) us)))
                                  ;; (1) each scope's own constraints, seeded by what the
                                  ;;     federation has established so far
                                  (set! us (map (lambda (s)
                                                  (column-upper-bounds (list-ref Cs s)
                                                                       (list-ref ns s)
                                                                       (list-ref us s)))
                                                (iota S)))
                                  ;; (2) what a scope draws the others supply, at every
                                  ;;     coupling-feasible point: its draw is at most the
                                  ;;     most the others can put on the crossing
                                  (for-each
                                    (lambda (kk)
                                      (let* ((ps (hash-ref parts kk))
                                             (given (map (lambda (p)
                                                           (crossing-most-given
                                                            (cdr p) (vector-ref (list-ref us (car p)) (crossing-col (cdr p)))))
                                                         ps)))
                                        (for-each (lambda (p)
                                                    (when (< (crossing-sign (cdr p)) 0)
                                                      (let* ((others (fold + 0.0 (map (lambda (q g) (if (eq? q p) 0.0 g)) ps given)))
                                                             ;; drawing all of it, the column stands at
                                                             (top (crossing-column (cdr p) (- others))))
                                                        (when (< top (vector-ref (list-ref us (car p)) (crossing-col (cdr p))))
                                                          (vector-set! (list-ref us (car p)) (crossing-col (cdr p)) top)))))
                                                  ps)))
                                    (exchange-keys ex))
                                  (if (every (lambda (a b)
                                               (let lp ((j 0))
                                                 (cond ((= j (vector-length a)) #t)
                                                       ((= (vector-ref a j) (vector-ref b j)) (lp (+ j 1)))
                                                       (else #f))))
                                             before us)
                                      us
                                      (loop (+ k 1))))))))
                      ;; computed ONCE — the caps are a property of the constraints
                      ;; and the coupling graph, not of any plan.
                      (define fed-caps (federated-bounds (map vector-length plans0)))
                      (define (reconcile xs labs rounds)
                        ;; → (plans forms-accessor overdraw radius-accessor), certified
                        ;; against each scope's OWN forms — the same object the
                        ;; unreconciled bound is measured against, so the two compare.
                        ;;
                        ;; The RADIUS is what reconciliation buys the certificate. The
                        ;; bound was never dominated by coordination: measured per scope
                        ;; on a 16-scope chain, m·μ ≈ 3·10⁻² and ‖r‖ ≈ 2·10⁻⁴, while the
                        ;; whole of it came from ‖r‖²/(2σ) with σ ≈ 3·10⁻⁹ — because σ is
                        ;; a min of t/s² and the boundary columns carry slacks of order
                        ;; 10³. The geometry branch ‖r‖·D would have been far tighter
                        ;; and was unavailable, because D is honestly +inf: what a
                        ;; scope draws is a free source and NOTHING in that scope's
                        ;; own program bounds it. What bounds it is the federation. Once the
                        ;; crossings are agreed they do exactly that, so the radius
                        ;; becomes finite and the bound stops being hostage to σ.
                        (let* ((ys (clamp xs))
                               (zh (shipments ys))
                               ;; the UNRESTRICTED radius: bounds no particular plan chose
                               (fb fed-caps)
                               (rad-free (map (lambda (s)
                                                (radius-from-bounds (list-ref fb s)
                                                                    (list-ref ys s)
                                                                    (vector-length (list-ref ys s))))
                                              (iota S)))
                               (free? (every (lambda (r) (< r +inf.0)) rad-free))
                               ;; the fallback: capped at THIS plan's crossings, which
                               ;; certifies only against plans that ship no more
                               (rad-fixed (map (lambda (s)
                                                 (let ((xv (list-ref ys s)))
                                                   (feasible-box-radius
                                                     (flatten (append (or (sref s 'forms) '())
                                                                      ;; each column capped where its scope's flow is
                                                                      ;; the good's whole shipment, either way
                                                                      (filter-map
                                                                        (lambda (bb)
                                                                          (let ((zq (hash-ref zh (crossing-key bb) #f)))
                                                                            (and zq (mk-bar (crossing-column bb (if (> (crossing-sign bb) 0) zq (- zq)))
                                                                                            (list (cons (crossing-col bb) -1.0))))))
                                                                        (rg s 4))))
                                                     (vector-length xv) xv)))
                                               (iota S))))
                          (list ys own-forms (overdraw ys)
                                (lambda (s) (list-ref (if free? rad-free rad-fixed) s))
                                (if free? 'coupling-feasible 'crossings-fixed))))

                      ;; the BASELINE certification must carry the boundary pull too:
                      ;; a coordinated scope optimises its program plus the pull of
                      ;; what crosses, and measuring against the program without it
                      ;; says only "it did not act alone" (4.6× looser, measured).
                      (let* ((labs0 (map (lambda (s)
                                           (let ((kp (if (> (abs *kappa*) 1e-300) *kappa* 1.0)))
                                             (append (or (sref s 'labform) '())
                                                     (map (lambda (p) (cons (car p) (/ (cdr p) kp)))
                                                          (pull-of s)))))
                                         (iota S)))
                             ;; The propagated caps hold at EVERY coupling-feasible
                             ;; point, so they are the right radius here too — not
                             ;; only after reconciliation. Without them what a scope
                             ;; draws is a free source with no bound in its own
                             ;; program, D is honestly +inf, and the whole bound
                             ;; falls back on ‖r‖²/(2σ) with a σ of order 10⁻⁹.
                             ;; That is the same defect the reconciled path had;
                             ;; it simply survived here because this branch is
                             ;; taken when reconciliation is off.
                             ;;
                             ;; Sound even where the unreconciled plan itself
                             ;; exceeds a cap: radius-from-bounds takes
                             ;; max(xⱼ, uⱼ−xⱼ), and with x*ⱼ ≥ 0 that is still an
                             ;; upper bound on |xⱼ − x*ⱼ| when xⱼ is above uⱼ.
                             (box0  (lambda (sx)
                                      (radius-from-bounds (list-ref fed-caps sx)
                                                          (list-ref plans sx)
                                                          (vector-length (list-ref plans sx)))))
                             (c0    (certify-set plans labs0 own-forms box0))
                             (refs  (map refine (iota S)))
                             (c1    (and (every (lambda (r) (and r (car r))) refs)
                                         (certify-set (map car refs) (map cdr refs) own-forms
                                                      (lambda (sx)
                                                        (radius-from-bounds
                                                          (list-ref fed-caps sx)
                                                          (car (list-ref refs sx))
                                                          (vector-length (car (list-ref refs sx))))))))
                             ;; Keep refinement only if it improves the bound AND does
                             ;; not cost agreement. The bound alone is NOT a
                             ;; sufficient test: λᵀ|d| multiplies a violation by a
                             ;; pull, and the pulls here are small, so a
                             ;; catastrophic disagreement registers as a modest
                             ;; term. Measured: refinement took the chain-of-4
                             ;; bound from 5.0e2 to 5.8e-1 — 870× tighter — while
                             ;; consensus went from 4.8e-3 to 35.8. That is not a
                             ;; better plan, it is scopes that have stopped talking
                             ;; to each other, and the bound said "improved".
                             ;;
                             ;; So the premise of the refinement is WRONG at this
                             ;; tolerance: the proximal term is not scaffolding to
                             ;; be discarded once pulls converge, it is what holds
                             ;; the scopes together. Removing it lets each walk to
                             ;; its own optimum at the current pulls, which are
                             ;; converged only to `tol`. Kept, gated, and reported
                             ;; — the refinement is right in principle and will
                             ;; earn its place when the pulls are tight enough
                             ;; that it does not move the plan.
                             ;; Refinement — the exact local solve at the converged
                             ;; pulls — is what drives ‖r‖ to zero, and ‖r‖·D is
                             ;; what the bound is now made of. Measured per scope on
                             ;; a 16-chain: every scope carries ‖r‖ ≈ 1e-4 from
                             ;; ADMM's deliberately-truncated inner solves, except
                             ;; the last, which converges to 5e-9 and contributes
                             ;; only its irreducible m·μ.
                             ;;
                             ;; It was gated on not costing AGREEMENT, because
                             ;; dropping the proximal term lets scopes walk apart
                             ;; (a 4-chain went to consensus 35.8). Reconciliation
                             ;; now repairs exactly that, so the agreement condition
                             ;; is retired when reconciliation is there to do it —
                             ;; and the result is checked, not assumed: the plan is
                             ;; only kept if the clamp leaves it feasible with
                             ;; nothing overdrawn.
                             ;;
                             ;; What makes this safe rather than a gamble is the
                             ;; radius fix. The bound test still gates refinement,
                             ;; and with an honest D the case that used to be
                             ;; tempting-but-harmful no longer passes it: on a
                             ;; 4-chain c0 was 5.0e2 against a +inf radius, so
                             ;; refinement's 5.8e-1 looked worth any amount of
                             ;; disagreement. c0 is now 2.5 and refinement cannot
                             ;; beat it, so it is refused there and accepted on a
                             ;; star, where it takes the bound 1.080 → 0.393.
                             ;; `refine? #f` restores the old conservative gate.
                             (use1  (and c1 (list-ref c1 0)
                                         (< (list-ref c1 4) (list-ref c0 4))
                                         (or (and reconcile? (not (eq? refine? #f)))
                                             (<= (list-ref c1 2) (max (list-ref c0 2) tol)))))
                             (ccA   (begin
                                      (when (getenv "PLANNER_FED")
                                        (format (current-error-port) "  [fed refine: c0=~s~%               c1=~s~%               use1=~s]~%" c0 c1 use1))
                                      (if use1 c1 c0)))
                             (outA  (if use1 (map car refs) plans))
                             ;; ── and now make it ACTIONABLE ──────────────────
                             ;; Reconciliation is kept when it does what it exists
                             ;; to do: leave every scope feasible and bring the
                             ;; crossings into agreement. It is allowed to cost
                             ;; objective — a consistent plan that delivers slightly
                             ;; less is worth more than an inconsistent one that
                             ;; promises more, because the second cannot be carried
                             ;; out. That trade is stated here rather than hidden in
                             ;; a threshold.
                             ;; Skip entirely when nothing is overdrawn — the plan is
                             ;; already executable and reconciliation is S full solves
                             ;; per round. Two rounds is the working bound: capping each
                             ;; draw at its owner's shipment fixes every link in one
                             ;; pass, and the second only confirms what is supplied
                             ;; did not move under it.
                             ;; Always run. The clamp is a no-op where nothing is
                             ;; overdrawn, and the radius it derives from the agreed
                             ;; crossings is what the certificate wants in EITHER case —
                             ;; a plan that never disagreed still has bounded crossings,
                             ;; and gating on "was a repair needed" left a 4-scope chain
                             ;; certifying at 3.1·10¹ for want of information it already
                             ;; had.
                             (repair? (> (overdraw outA) 1e-9))
                             (rec   (and reconcile? (reconcile outA '() 2)))
                             (c2    (and rec (certify-set (car rec) labs0 (cadr rec)
                                                          (list-ref rec 3))))
                             ;; The ONLY condition is that the clamped plan still
                             ;; passes the same KKT feasibility test as any other. An
                             ;; earlier version also demanded the bound stay meaningful,
                             ;; which was necessary while reconciliation RE-SOLVED and
                             ;; could destroy it. Clamping moves the plan by exactly the
                             ;; overdraw, so the bound moves by O(overdraw) and the
                             ;; extra gate only misfired — it refused a free
                             ;; reconciliation on a 4-scope chain whose bound was
                             ;; already above its objective before anything was
                             ;; reconciled. The bound is reported either way; what has
                             ;; to be checked is feasibility, and that is checked.
                             (use2  (and c2 (list-ref c2 0) (<= (caddr rec) 1e-9)))
                             (cc    (if use2 c2 ccA))
                             (out   (if use2 (car rec) outA))
                             ;; Measured on the plan being RETURNED, and measured as
                             ;; the DEFICIT (drawn − supplied), not as |supplied − drawn|.
                             ;; Those differ, and conflating them mislabelled a plan
                             ;; that was already executable: a 4-scope chain whose
                             ;; links were all in surplus reported an overdraw of
                             ;; 9·10⁻⁷ — its largest disagreement in either direction —
                             ;; and was refused reconciliation it did not need, then
                             ;; flagged not-executable for the lack of it. Executability
                             ;; is a property of the plan, not of whether a repair ran.
                             (od    (overdraw out)))
                        (set-last-certificate!
                              `((kind . federated) (scopes . ,S)
                                (feasible? . ,(list-ref cc 0))
                                (local-bound . ,(list-ref cc 1))
                                (local-bounds . ,(if (> (length cc) 5) (list-ref cc 5) '()))
                                (local-feasible . ,(if (> (length cc) 6) (list-ref cc 6) '()))
                                (consensus . ,(list-ref cc 2))
                                (disagreement-in-hours . ,(list-ref cc 3))
                                (gap-bound . ,(list-ref cc 4))
                                ;; COUPLING-FEASIBLE now means executable — no scope
                                ;; drawing on goods nobody is sending — rather than
                                ;; agreement to the last digit, which no interior
                                ;; solve reaches and which physics does not require.
                                (overdraw . ,od)
                                (coupling-feasible? . ,(<= od 1e-9))
                                ;; WHAT THE BOUND IS OVER. The radius that makes it
                                ;; finite comes from capping each boundary column at the
                                ;; crossing this plan agreed, so the x* it compares
                                ;; against ranges over plans whose crossings do not
                                ;; exceed those — a different coupling-feasible plan may
                                ;; ship more. `crossings-fixed` therefore certifies
                                ;; against the best plan USING THESE CROSSINGS, which is
                                ;; what a federation that has committed to them wants,
                                ;; and is strictly weaker than the monolithic claim.
                                ;; Recovering the unrestricted one needs caps valid for
                                ;; every coupling-feasible plan — interval propagation
                                ;; over the coupling graph, iterated to a fixpoint.
                                ;; Both branches now take their radius from the
                                ;; coupling graph, so both quantify over every
                                ;; coupling-feasible plan. `own-program` remains
                                ;; only for the case where propagation could not
                                ;; close — an genuinely unbounded cover — where the
                                ;; radius falls back to what a scope can prove alone.
                                (bound-over . ,(cond (use2 (list-ref rec 4))
                                                     ((< (list-ref cc 4) +inf.0) 'coupling-feasible)
                                                     (else 'own-program)))
                                (reconciled? . ,(and use2 repair? #t))
                                (refined? . ,use1)
                                (rounds . ,rounds)
                                (met . ,met)))
                        (set! plans out)
                        ;; met MUST describe the plan being RETURNED. It was computed
                        ;; from the ADMM's own buffers before reconciliation replaced
                        ;; the plans, so a reconciled solve reported the delivery of a
                        ;; plan it did not hand back — the exact shape of defect this
                        ;; file keeps turning up: a metric measuring something adjacent
                        ;; to what it names. Recomputed here on `out`, through the same
                        ;; pk_meanfill the loop uses, so the two are the same number.
                        (do ((sx 0 (+ sx 1))) ((= sx S))
                          (let ((bv (rg sx 14)) (xv (list-ref out sx)))
                            (do ((i 0 (+ i 1))) ((= i (vector-length xv)))
                              (f64set! bv i (vector-ref xv i)))))
                        (set! met (/ (let lp ((sx 0) (a 0.0))
                                       (if (= sx S) a (lp (+ sx 1) (+ a (scope-met sx)))))
                                     (max 1 S))))
                      (values plans met rounds pulls))))))
