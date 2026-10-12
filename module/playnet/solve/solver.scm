;;; solver.scm — the convex solver, and nothing about an economy.
;;;
;;; Sectioned by ROLE, not by backend — so a change to one concern is a change
;;; to one section, and a knob can never quietly govern machinery filed under a
;;; different heading (which is how the phase-I/IC(0) defect hid):
;;;   §0 utilities · §1 FORMS (the problem and its calculus) · §2 FEASIBILITY
;;;   (every inside-the-limits question, phase-I included) · §3 CERTIFICATION
;;;   (KKT, gap bounds, the published certificate) · §4 DIALS (every tunable,
;;;   one block) · §5 CORES (reference Scheme · compiled C · Mehrotra
;;;   primal-dual · OSQP — mechanism only) · §6 ACCEPTANCE + DISPATCH (the
;;;   ladder, the ranking rule, the backend selector) · §7 reporting.
;;;
;;; Its whole vocabulary is `forms`: a list of backend-neutral terms, each a kind
;;; (`bar`, `des`, `frag`, `qc`, `held`) over a sparse row. Not one ValueFlows
;;; accessor appears below — no RecipeFlow, no EconomicResource, no measure, no
;;; unit. Hand it forms and it returns numbers; what those numbers MEAN is the
;;; business of planner.scm, which is loaded around this one.
;;;
;;; The boundary is the engine's own rule made physical: the solver sees
;;; everything, the certificate sees only the world.

;; ════════════════════════════════════════════════════════════════════════════
;; §0 — utilities
;; small vector helpers shared by every backend. Loading this file runs nothing:
;; the demos it used to gate behind PLANNER_LIB live in demo.scm, which owns
;; *demos?* now because it is the only thing left that reads it.
;; ════════════════════════════════════════════════════════════════════════════
(define-module (playnet solve solver)
  #:use-module ((playnet utils host) #:select (getenv))
  #:use-module (playnet protocol context)
  #:use-module ((playnet utils catch) #:select (throw*))
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (rnrs bytevectors)
  #:use-module (playnet vf formulas tension-kinds)
  #:export (vdot vcopy vneg mk-bar mk-des mk-device device-form? mk-qc mk-frag mk-held mk-cap mk-method method-form? want-ask cask
            form-body world-forms f-kind f-const f-coeffs f-Dw *kappa* cnt cptr cconst
            ckind cD cw cidx cval flatten term-values frac-to-boundary term-coeffs
            csr-hv csr-diag csr-grad obj-value world-objective form-scale
            %feasible-tol bar-slacks-feasible? retract-feasible bar-slacks-min
            %diverged-tol plan-grossly-infeasible? augment-phase1 *infeas-tol*
            program-scale infeasible-by? phase1-decide infeasibility-report
            signal-infeasible! raise-starvation ensure-feasible plan-finite? plan-certificate
            assert-plan-invariants! %verdict-fields plan-verdict
            strong-convexity-modulus optimal-face-dimension column-upper-bounds
            give-bound offset-column detach-column column-wall?
            *face-dirs-max* optimal-face-extent radius-from-bounds
            *box-prop-rounds* *box-prop-last-rounds* *box-prop-last-railed?*
            column-caps box-bounded? feasible-box-radius *kkt-stat-tol* *dual-fit-cap*
            *kkt-dual-fit?* call-without-dual-fit fit-active-dual kkt-report
            *last-certificate* set-last-certificate! certificate-of-last-solve set-certificate-from-kkt!
            face-clause certificate-summary *kern-omp* *kern-ridge* *kern-precond*
            *kern-dense-thr* *kern-precond-auto* auto-precond *kern-rcm* *kern-maxdeg*
            *kern-sigma* *kern-tmin* *target-gap* *kern-tmin-default* *kern-tmin-min*
            forms-box-bounded? tmin-for sync-kern-tmin! call-at-settled-floor
            *kern-inner-tau* *kern-newton-mid* *kern-newton-final* *kern-cgcap*
            *kern-greg* *kern-hmin* *kern-mettol* greg-lambda *kern-inner-rel*
            *kern-inner-abs* inner-tol *osqp-fallback* *osqp-fallback-maxvar*
            *osqp-fallback-metfloor* call-with-greg *kern-pd-tol* *kern-pd-maxit*
            *osqp-eps* *backend* set-backend! set-kappa! set-kern-mettol!
            set-kern-newton-final! set-kern-precond-auto! set-osqp-fallback! pcg
            solve-native-core solve-native solve-native/cert *kern-lib* %cpu-flags
            *kern-isa-missing* kern-isa-ok? kern-available? kern-isa-refusal
            kern-unavailable-reason kfn k-tvals k-tcoef k-grad k-diag k-obj k-pcg
            k-dot k-axpy k-ic0sym k-ic0fac k-ic0free k-pcgic0 k-ic0wsym k-ic0wfac
            k-ic0wfree k-pcgic0w k-cholsym k-cholfac k-cholsolve k-cholfree k-chollnnz
            k-pcgchol k-buildcsc k-pcgssor k-solvepd k-pcgomp k-ompthreads k-solvemany
            k-meanfill k-set-tmin k-set-schedule sync-kern-dials! vec->f64 vec->i32 f64bv->vec i32bv->vec bvp solve-native-c-core
            solve-flat scope-core solve-exact set-kern-enabled!
            solve-native-c-pd %link-osqp *osqp-lib* *osqp-inf* *osqp-last*
            osqp-available? i64* f64* triplets->csc solve-osqp solve-native-c qc-free?
            certified solve mean-fill mean-overfill labour-intensity fill-report
            self-test))

;; the compiled kernel and OSQP cross the FFI; Hoot has none (see the cond-expand at §5b)
(cond-expand (guile (use-modules (system foreign))) (else))

(define (vdot a b) (let ((s 0.0) (n (vector-length a))) (do ((i 0 (+ i 1))) ((= i n) s) (set! s (+ s (* (vector-ref a i) (vector-ref b i)))))))
(define (vcopy a) (let* ((n (vector-length a)) (r (make-vector n))) (do ((i 0 (+ i 1))) ((= i n) r) (vector-set! r i (vector-ref a i)))))
(define (vneg a) (let* ((n (vector-length a)) (r (make-vector n))) (do ((i 0 (+ i 1))) ((= i n) r) (vector-set! r i (- (vector-ref a i))))))

;; ════════════════════════════════════════════════════════════════════════════
;; §1 — FORMS: the problem, and its calculus
;; the backend-neutral representation — constructors, the flattened
;; CSR program, term values/coeffs, gradients, objective. Nothing here
;; decides anything; it states the program and differentiates it.
;; ════════════════════════════════════════════════════════════════════════════

;; A program is a list of linear FORMS over an activity vector x (length na):
;;   'bar  const coeffs        — a possibility slack  s(x)=const+Σv·x ≥ 0
;;                               (goods balance, labour ≤ cap, eco ≤ cap, x ≥ 0)
;;   'des  const coeffs (D . w) — a desire on delivered s(x)=const+Σv·x toward D,
;;                               penalty w·(max(0,(D−s)/D))²  (one-sided: satiation)
;;   'frag const coeffs w       — a FRAGILITY profile: fixed-weight log barrier
;;                               −w·log(s), s the normalised distance-to-tip
;;                               (s* and s_tip folded into const+coeffs). Like
;;                               'bar but FELT AT THE OPTIMUM (fixed w, not swept t).
;; coeffs = list of (activity-index . coefficient).  A separate `labform` (list of
;; (index . labour)) carries the free-time term κ·Σℓ·x.  Both backends read these.
(define (mk-bar const coeffs) (list 'bar const coeffs #f))
(define (mk-des form D w)     (list 'des (cadr form) (caddr form) (cons D w)))
;; A DEVICE is a des term nobody asked for: a variable the program pulls toward a
;; target for its own reasons (the maximin fraction τ → 1). It solves exactly as a
;; want does and is no want — want-ask answers #f for it, so neither the fill
;; report nor the epigraph ever counts the machinery among the people's asks.
(define (mk-device form D w)  (append (mk-des form D w) '(device)))
(define (device-form? f)      (and (eq? (car f) 'des) (pair? (cddddr f)) (eq? 'device (car (cddddr f)))))
(define (mk-qc  const coeffs w) (list 'qc const coeffs w))   ; two-sided quadratic cost w·(const+Σv·x)² (EMP congestion)
(define (mk-frag const coeffs w) (list 'frag const coeffs w)) ; fragility barrier −w·log(s), fixed governance weight
;; a desire that does not ABANDON: w·(1−u)²/u for u = s/D, agreeing with `des` in
;; value, gradient AND curvature at satiation, and diverging as satisfaction
;; collapses. The middle term between a want that can be priced out and a floor
;; that admits no trade-off at all. See tension-kinds.scm.
(define (mk-held form D w)    (list 'held (cadr form) (caddr form) (cons D w)))
(define* (mk-cap form w #:optional (scale 1.0)) (list 'cap (cadr form) (caddr form) (cons scale w)))   ; a want whose ask is a wall: φ = w/(1+s/scale); scale = the spec's reference quantum, never a report (tension-kinds.scm)
;; ── TENSIONS OF THE WORLD, AND TENSIONS OF THE METHOD ───────────────────────
;; Every form above states something about the ECONOMY: a limit that exists, a
;; want someone has. A solver also erects tensions of its OWN — a proximal term
;; holding scopes together while prices converge, a cap pinning a crossing while
;; a plan is reconciled. Same shapes, different kind of claim, and conflating
;; them has cost this engine twice already: certifying against the proximal-
;; augmented program flattered the result (a scope was credited for satisfying
;; scaffolding the coordinator erected), and a reconciliation cap read as a real
;; limit drove the bound to +inf, because a cap sits at slack ~0 by construction
;; while a scope's own barriers sit far from theirs and one central-path t cannot
;; fit both.
;;
;; Origin is ORTHOGONAL to shape — the proximal terms are `qc`, the caps are
;; `bar` — so this wraps rather than adding a kind. The rule it makes structural:
;; THE SOLVER SEES EVERYTHING, THE CERTIFICATE SEES ONLY THE WORLD. A method
;; tension may steer the search; it may never appear in what the plan claims to
;; have proven. Marking at construction means a future change of method — a
;; different coordinator, a different repair — carries its scaffolding with it
;; and cannot leak into a certificate by omission.
(define (mk-method f) (list 'method f))
(define (method-form? f) (and (pair? f) (eq? (car f) 'method)))
(define (form-body f) (if (method-form? f) (cadr f) f))
(define (world-forms fs) (filter (lambda (f) (not (method-form? f))) fs))

(define (f-kind f) (car f)) (define (f-const f) (cadr f)) (define (f-coeffs f) (caddr f)) (define (f-Dw f) (cadddr f))
(define *kappa* 0.02)            ; free-time weight (prunes waste)

;; Flatten the forms into CSR flat arrays (no list overhead in the inner loops),
;; then follow the central path: at barrier parameter t, the desire is quadratic
;; and each 'bar contributes −t·log(slack); H = Σ coeff·a aᵀ is never formed —
;; H·v = Σ coeff·a(aᵀv) costs O(nnz), and diagonally-preconditioned CG solves
;; H d = −g. Sweep t down; the gap to the true optimum is ≤ m·t (the certificate).
;; csr = #(nt nnz ptr const kind D w idx val ask)
(define (cnt c) (vector-ref c 0)) (define (cptr c) (vector-ref c 2)) (define (cconst c) (vector-ref c 3))
(define (ckind c) (vector-ref c 4)) (define (cD c) (vector-ref c 5)) (define (cw c) (vector-ref c 6))
(define (cidx c) (vector-ref c 7)) (define (cval c) (vector-ref c 8))
(define (cask c) (vector-ref c 9))         ; per term: the want's ASK (0 where the term is no want) — see want-ask
;; A WANT'S ASK, whichever shape the want took: a des form's D, or the wall a
;; citizen's own want rides on as a cap form (stamped as its fifth element by
;; build-located, docs/planning/solve/quantity-as-a-cap.md); #f for any other form.
;; THE reading of "how much was asked" — the maximin epigraph (solve/robust.scm) and
;; the fill report (mean-fill, mean-overfill) both take it from here, so a want
;; counts as a want in the report exactly when it counts in the objective.
;; Measured: with every want a citizen's own, the report read kind-1 terms
;; only, found none, and answered 1.0 — a plan that baked nothing was "met".
(define (want-ask f)
  (case (f-kind f)
    ((des) (and (not (device-form? f)) (car (f-Dw f))))
    ((cap) (and (> (length f) 4) (list-ref f 4)))
    (else #f)))
(define (flatten forms*)
  (let* ((forms (map form-body forms*))     ; a method tension solves like any other
         (nt (length forms))
         (nnz (fold (lambda (f a) (+ a (length (f-coeffs f)))) 0 forms))
         (ptr (make-vector (+ nt 1) 0)) (const (make-vector nt 0.0))
         (kind (make-vector nt 0)) (D (make-vector nt 1.0)) (w (make-vector nt 0.0))
         (idx (make-vector (max 1 nnz) 0)) (val (make-vector (max 1 nnz) 0.0))
         (ask (make-vector nt 0.0)))        ; the want's ask, both spellings (want-ask); 0 for a wall
    (let loop ((fs forms) (ti 0) (off 0))
      (if (null? fs) (begin (vector-set! ptr nt off) (vector nt nnz ptr const kind D w idx val ask))
          (let ((f (car fs)))
            (vector-set! ptr ti off) (vector-set! const ti (f-const f))
            (vector-set! ask ti (or (want-ask f) 0.0))
            (when (eq? (f-kind f) 'des)
              (vector-set! kind ti 1) (vector-set! D ti (car (f-Dw f))) (vector-set! w ti (cdr (f-Dw f))))
            (when (eq? (f-kind f) 'qc)
              (vector-set! kind ti 2) (vector-set! w ti (f-Dw f)))    ; qc: payload = weight
            (when (eq? (f-kind f) 'frag)
              (vector-set! kind ti 3) (vector-set! w ti (f-Dw f)))    ; frag: payload = fixed weight
            (when (eq? (f-kind f) 'held)
              (vector-set! kind ti 4) (vector-set! D ti (car (f-Dw f))) (vector-set! w ti (cdr (f-Dw f))))
            (when (eq? (f-kind f) 'cap)
              (vector-set! kind ti 5) (vector-set! D ti (car (f-Dw f))) (vector-set! w ti (cdr (f-Dw f))))  ; cap: D = the spec's reference scale (never an ask), payload weight
            (let put ((cs (f-coeffs f)) (o off))
              (if (null? cs) (loop (cdr fs) (+ ti 1) o)
                  (begin (vector-set! idx o (caar cs)) (vector-set! val o (cdar cs)) (put (cdr cs) (+ o 1))))))))))
(define (term-values C x)
  (let* ((nt (cnt C)) (ptr (cptr C)) (idx (cidx C)) (val (cval C)) (sv (make-vector nt 0.0)))
    (do ((ti 0 (+ ti 1))) ((= ti nt) sv)
      (let ((s (vector-ref (cconst C) ti)))
        (do ((k (vector-ref ptr ti) (+ k 1))) ((= k (vector-ref ptr (+ ti 1))))
          (set! s (+ s (* (vector-ref val k) (vector-ref x (vector-ref idx k))))))
        (vector-set! sv ti s)))))
;; fraction-to-the-boundary step cap: the largest η for which every BARRIER slack (bar/frag) stays
;; ≥ (1−γ) of its current value along d — the standard interior-point safeguard that keeps the iterate
;; strictly inside the barriers and bounds the step, so a far start can never roam across a wall.
(define (frac-to-boundary C sv d n)
  (let ((nt (cnt C)) (ptr (cptr C)) (idx (cidx C)) (val (cval C)) (cap 1.0))
    (do ((ti 0 (+ ti 1))) ((= ti nt) cap)
      (let ((k (vector-ref (ckind C) ti)))
        (when (memv k '(0 3 4))                                      ; bar/frag/held all diverge at their wall
          (let ((ds 0.0))                                            ; directional derivative Σ coeff·d of this slack
            (do ((j (vector-ref ptr ti) (+ j 1))) ((= j (vector-ref ptr (+ ti 1))))
              (set! ds (+ ds (* (vector-ref val j) (vector-ref d (vector-ref idx j))))))
            (when (< ds 0.0)                                         ; slack decreasing ⇒ bound η so it stays ≥ 1% of current
              (set! cap (min cap (/ (* -0.99 (vector-ref sv ti)) ds))))))))))
(define (term-coeffs C t sv)               ; curvature coefficient per form (the rank-1 weight)
  (let* ((nt (cnt C)) (cv (make-vector nt 0.0)))   ; per-kind φ″ from tension-kinds.scm
    (do ((ti 0 (+ ti 1))) ((= ti nt) cv)
      (vector-set! cv ti ((kind-curv (vector-ref *kind-fns* (vector-ref (ckind C) ti)))
                          (vector-ref sv ti) t (vector-ref (cD C) ti) (vector-ref (cw C) ti))))))
(define (csr-hv C cv v n)                   ; H·v, matrix-free, + ridge
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
(define (csr-diag C cv n)                   ; diag(H), for Jacobi preconditioning
  (let ((d (make-vector n 1e-7)) (ptr (cptr C)) (idx (cidx C)) (val (cval C)) (nt (cnt C)))
    (do ((ti 0 (+ ti 1))) ((= ti nt))
      (let ((c (vector-ref cv ti)))
        (unless (= c 0.0)
          (do ((k (vector-ref ptr ti) (+ k 1))) ((= k (vector-ref ptr (+ ti 1))))
            (let ((i (vector-ref idx k)) (vk (vector-ref val k))) (vector-set! d i (+ (vector-ref d i) (* c vk vk))))))))
    d))
(define (csr-grad C labform t sv n)        ; per-form φ′ from tension-kinds; nonzero loop unchanged
  (let ((g (make-vector n 0.0)) (ptr (cptr C)) (idx (cidx C)) (val (cval C)) (nt (cnt C)))
    (do ((ti 0 (+ ti 1))) ((= ti nt))
      (let ((gc ((kind-grad (vector-ref *kind-fns* (vector-ref (ckind C) ti)))
                 (vector-ref sv ti) t (vector-ref (cD C) ti) (vector-ref (cw C) ti))))
        (unless (= gc 0.0)                  ; bar's −t/s and des's sign already folded into φ′
          (do ((k (vector-ref ptr ti) (+ k 1))) ((= k (vector-ref ptr (+ ti 1))))
            (let ((i (vector-ref idx k))) (vector-set! g i (+ (vector-ref g i) (* gc (vector-ref val k)))))))))
    (for-each (lambda (ic) (vector-set! g (car ic) (+ (vector-ref g (car ic)) (* *kappa* (cdr ic))))) labform)
    g))
(define (obj-value C labform t x sv)       ; per-form φ from tension-kinds.scm
  (let ((acc (fold (lambda (ic a) (+ a (* *kappa* (cdr ic) (vector-ref x (car ic))))) 0.0 labform)) (nt (cnt C)))
    (do ((ti 0 (+ ti 1))) ((= ti nt) acc)
      (set! acc (+ acc ((kind-value (vector-ref *kind-fns* (vector-ref (ckind C) ti)))
                        (vector-ref sv ti) t (vector-ref (cD C) ti) (vector-ref (cw C) ti)))))))
;; The objective the WORLD states, for ranking candidate plans: des/qc/held/frag
;; at their φ plus the free-time term — and NO bar terms. A bar is a constraint;
;; its guarded φ returns 1e12 within 1e-12 of the wall, which is exactly where
;; an LP optimum sits, so ranking through it scores a plan 1e12 per BINDING
;; constraint and prefers an interior do-little seed over the optimum itself.
;; Feasibility is judged separately (%feasible-tol); this is only the value.
(define (world-objective C labform x)
  (let ((sv (term-values C x)) (acc (fold (lambda (ic a) (+ a (* *kappa* (cdr ic) (vector-ref x (car ic))))) 0.0 labform)) (nt (cnt C)))
    (do ((ti 0 (+ ti 1))) ((= ti nt) acc)
      (unless (= (vector-ref (ckind C) ti) 0)
        (set! acc (+ acc ((kind-value (vector-ref *kind-fns* (vector-ref (ckind C) ti)))
                          (vector-ref sv ti) 0.0 (vector-ref (cD C) ti) (vector-ref (cw C) ti))))))))
;; Scale-INVARIANT gross-infeasibility test: is any HARD (bar/frag) form violated
;; by more than 5% of its OWN magnitude? scale = max(1, |const|, Σ|coeff·x|) — the
;; constraint's throughput — so the test works at any unit scale. (An ABSOLUTE
;; −1 threshold false-positived a feasible kcal-scale floor and would miss a gross
;; violation at tonne scale.) Used to turn a diverged/garbage solve into an honest
;; "no strictly-feasible point" on the fast backend, in every solve path.
;; A hard form's OWN magnitude at x: the larger of its constant and the
;; throughput flowing through it, floored at 1. Written once, because two things
;; read it and they must not drift — `plan-grossly-infeasible?` judges a
;; violation against it PER CONSTRAINT, and `program-scale` takes it over the
;; program so phase-I's single relaxation scalar has something to be read against.
(define (form-scale C x ti)
  (let ((ptr (cptr C)) (idx (cidx C)) (val (cval C)) (thru 0.0))
    (do ((j (vector-ref ptr ti) (+ j 1))) ((= j (vector-ref ptr (+ ti 1))))
      (set! thru (+ thru (abs (* (vector-ref val j) (vector-ref x (vector-ref idx j)))))))
    (max 1.0 (abs (vector-ref (cconst C) ti)) thru)))

;; ════════════════════════════════════════════════════════════════════════════
;; §2 — FEASIBILITY: is a point inside, and can any point be
;; every "inside the limits?" question in one place: the float-noise
;; band (%feasible-tol), the 5% gross test, phase-I (which DECIDES
;; feasibility — s* > 0 is a proof), retraction, and the infeasibility
;; report. Phase-I always runs matrix-free Jacobi: its slack is a dense
;; column that poisons factor preconditioners (measured: s* 0.152 under
;; ic0 vs 7e-5 under jacobi on the same program).
;; ════════════════════════════════════════════════════════════════════════════

;; ── Phase-I feasibility: native needs NO good warm start ─────────────────────
;; The barrier needs a STRICTLY feasible x (every 'bar slack > 0); on coupled
;; problems (demand met only by shipping from a disjoint cell) finding one is the
;; hard part, and a far start leaves native stuck. Standard two-phase fix: augment
;; with ONE infeasibility variable s, turn each 'bar  s_ℓ(x) ≥ 0  into
;; s_ℓ(x) + s ≥ 0  — trivially feasible by taking s past the worst violation —
;; drop the desires, and MINIMISE s with the SAME kernel. If min s < 0 the
;; recovered x is strictly feasible for the original: the phase-II start. Reuses
;; the whole Newton-PCG(+IC0) machinery; no good warm start, no OSQP needed.
;; A BINDING constraint sits exactly at its limit, so its slack lands within
;; floating-point noise of zero — on either side. A bare `slack > 0` verdict
;; therefore reports a perfectly good plan as infeasible whenever the solve is
;; tight, which is precisely when plans are most interesting. (Measured: a
;; storage plan meeting 100 % of demand certified `feasible? #f` on a min-slack
;; of −2.1e-12.)
;;
;; So feasibility is judged the way `plan-grossly-infeasible?` already judges it —
;; against each constraint's OWN magnitude (`form-scale`) rather than against an
;; absolute zero — only at a numerical tolerance instead of that test's 5 %
;; acceptance band. The two must not drift: one decides whether to accept a
;; point, this one decides what to say about it, and they now read the same
;; scale.
;;
;; THE TOLERANCE IS THE SOLVER FAMILY'S OWN FLOOR, not float noise. Phase-I
;; hands every downstream solve a point that satisfies the RELAXED program and
;; is exterior to the original by exactly its s* — and s* bottoms out near 1e-5
;; (the pin paragraph below measures it), because phase-I runs through the same
;; capped core as everything else. Judging candidates at 1e-9 while the
;; interior-finder itself lands at 1e-5 rejected EVERY attempt on a measured
;; spanning-structure program — native by −1.3e-5, OSQP by its ADMM eps — and
;; the ladder then returned the phase-I seed itself (fill 0.18 where OSQP held
;; 1.0). A real breach is still orders of magnitude above this band, and a
;; fragility "crossed" by 3e-5 of its own scale is float-noise against a wall
;; the barrier keeps real optima strictly inside of.
;; ── THREE TOLERANCES, ONE LADDER ────────────────────────────────────────────
;; "Is this point inside its limits?" is asked three times here, for three
;; different purposes, and the answers must differ or each caller breaks. They
;; were three numbers in three places — two named, one a bare 0.05 buried in a
;; loop — so the ladder had to be rediscovered by whoever next touched one. It
;; is one ladder, measured against ONE scale (`form-scale`, each constraint's
;; own throughput — never an absolute, or the same physical program answers
;; differently in grams and kilograms):
;;
;;   %feasible-tol  3e-5   the solver family's own floor. Below this a slack is
;;                         NOISE, and a binding constraint sits here by nature.
;;                         Judges what to SAY about a point (the certificate).
;;   *infeas-tol*   1e-3   phase-I's s* against the program's magnitude. Judges
;;                         whether the PROGRAM has an answer at all.
;;   %diverged-tol  0.05   a violation this large is not a tight optimum, it is
;;                         an iterate that came apart. Judges whether to ACCEPT
;;                         a candidate, or retry from a fresh start.
;;
;; They must stay ordered — noise < no-answer < came-apart. Collapse any two and
;; the middle meaning is lost: at the noise floor every tight plan reads
;; infeasible (measured: a storage plan meeting 100% of demand, min-slack
;; −2.1e-12); at the divergence band a genuinely broken solve reads fine.
(define %feasible-tol 3e-5)
(define (bar-slacks-feasible? C x sv)
  "Is every HARD form satisfied to within float noise of its own scale?"
  (let ((nt (cnt C)) (ok #t))
    (do ((ti 0 (+ ti 1))) ((or (not ok) (= ti nt)) ok)
      (when (memv (vector-ref (ckind C) ti) '(0 3 4))
        (when (< (vector-ref sv ti) (* (- %feasible-tol) (form-scale C x ti)))
          (set! ok #f))))))

;; ── retraction, with the anchor it always needed ─────────────────────────────
;; Every hard slack is AFFINE along the segment to another plan, so the least
;; blend restoring feasibility is exact arithmetic. The first attempt at this
;; anchored on phase-I's point and failed — phase-I is exterior by its own
;; relaxation floor. The anchor that works is a STRICTLY INTERIOR sibling from
;; the same ladder: the centred native candidate, sitting one attempt earlier.
;; A wall-riding optimum (OSQP's, typically) blended a hair toward it clears
;; every wall while keeping nearly all of its objective advantage.
;; Machine-checked from both sides (docs/formal/solver-certificate,
;; `retract_feasible_correct`), under exactly the two preconditions stated in
;; the docstring — strictly interior anchor, exact arithmetic: every blend at
;; or past the folded θ restores every hard slack (1.01 overshoot included),
;; and every blend short of θ leaves one negative. LEAST is a theorem.
(define (retract-feasible C x anchor)
  "The least X-to-ANCHOR blend with every hard slack ≥ 0; X unchanged when
   already feasible. ANCHOR must be strictly interior."
  (let ((sx (term-values C x)) (sa (term-values C anchor)) (nt (cnt C)) (theta 0.0))
    (do ((ti 0 (+ ti 1))) ((= ti nt))
      (when (memv (vector-ref (ckind C) ti) '(0 3 4))
        (let ((vx (vector-ref sx ti)) (va (vector-ref sa ti)))
          (when (and (< vx 0.0) (> va vx))
            (set! theta (max theta (/ vx (- vx va))))))))
    (if (<= theta 0.0) x
        ;; θ < 1 is FORCED by a strictly interior anchor (each root is
        ;; |vx|/(|vx|+va) < 1 — proven, `retractTheta_lt_one`), so the min
        ;; clamp guards float overshoot for θ near 1, not a real θ ≥ 1 case;
        ;; both branches land at or past θ (`retract_feasible_overshoot`).
        (let* ((th (min 1.0 (* theta 1.01)))
               (n (vector-length x)) (y (make-vector n 0.0)))
          (do ((i 0 (+ i 1))) ((= i n))
            (vector-set! y i (+ (* (- 1.0 th) (vector-ref x i))
                                (* th (vector-ref anchor i)))))
          y))))

(define (bar-slacks-min C sv)               ; smallest HARD slack at x (feasible ⇔ > 0)
  (let ((nt (cnt C)) (m +inf.0))            ; bar, frag AND held: each one's slack must stay > 0 — a frag's
    (do ((ti 0 (+ ti 1))) ((= ti nt) m)     ; s_tip−draw past the tip has φ′=0 (no push-back), and held's bare-
      (let ((k (vector-ref (ckind C) ti)))  ; need floor is the same shape; phase-I must recover both.
        (when (memv k '(0 3 4)) (set! m (min m (vector-ref sv ti))))))))

(define %diverged-tol 0.05)   ; the ladder's top rung — see THREE TOLERANCES above
(define %stalled-stat 1e-1)   ; relative stationarity above which a returned point is an iterate that STOPPED, not a plan: the stationarity rung of the same ladder (noise 1e-6 `optimal?` < a finished path-follower ~1e-3 < stalled)
(define (plan-grossly-infeasible? C x)
  (let ((nt (cnt C)) (ptr (cptr C)) (idx (cidx C)) (val (cval C)) (bad #f))
    (do ((ti 0 (+ ti 1))) ((or bad (= ti nt)) bad)
      (let ((k (vector-ref (ckind C) ti)))
        (when (memv k '(0 3 4))
          (let ((s (vector-ref (cconst C) ti)))
            (do ((j (vector-ref ptr ti) (+ j 1))) ((= j (vector-ref ptr (+ ti 1))))
              (set! s (+ s (* (vector-ref val j) (vector-ref x (vector-ref idx j))))))
            (when (< s (* (- %diverged-tol) (form-scale C x ti))) (set! bad #t))))))))
(define (augment-phase1 forms na)           ; +s (index na) on every HARD form (bar, frag AND held); drop 'des/'qc; objective = min s
  (values (filter-map (lambda (f) (and (memq (f-kind f) '(bar frag held))
                          (mk-bar (f-const f) (cons (cons na 1.0) (f-coeffs f))))) forms)
          (list (cons na 1.0e5))))          ; large linear weight ⇒ κ·W·s dominates ⇒ s driven to its min

;; ── INFEASIBILITY IS A THEOREM, NOT A TIMEOUT ────────────────────────────────
;; `augment-phase1` puts +s in EVERY hard form and minimises s, so a point
;; satisfying the original constraints is exactly a point where s can reach 0.
;; Phase-I therefore does not merely hunt for a feasible start — it DECIDES
;; feasibility, and s* > 0 is a PROOF that none exists, with s* the least amount
;; by which the limits must be relaxed before any plan is possible.
;;
;; That number was computed and thrown away. The old path then ran a full solve
;; on a problem already known to have no answer, failed its slack check, redid
;; the entire thing from another start, and raised a message naming no quantity:
;; the symptom rather than the obstruction, which is precisely what §8
;; Obligation 9 asks not to do. It also made the repository's heaviest test
;; spend most of its time proving the same impossibility twice over.
;;
;; `phase1-decide` returns both, and the infeasible case is published as a
;; certificate rather than widened into the return — the same choice, for the
;; same reason, as the federated certificate: this return is a positional
;; contract with eight call sites.
;; The threshold separates "no strictly INTERIOR point" from "no point at all",
;; and those are different things. A variable PINNED to a value — x ≥ c together
;; with −x ≥ −c, which several fixtures use deliberately to hold an activity at
;; zero — has an empty interior, so phase-I's s* settles at ~1e-5 and can never
;; reach 0 no matter how feasible the program is. At 1e-6 that read as proof of
;; infeasibility and failed four working tests whose only crime was a pin.
;;
;; A GENUINE infeasibility is not marginal: s* is the real shortfall in the units
;; of the breached constraint (calories a diet cannot supply, hours that do not
;; exist), which is orders of magnitude above the numerical floor of a pin. The
;; gap between the two is wide, so the threshold sits in it rather than at the
;; edge of one — the same reasoning the −1.0 gross-infeasibility check below uses,
;; and for the same reason.
(define *infeas-tol* 1e-3)   ; DIMENSIONLESS: a fraction of the program's own magnitude

;; The magnitude a uniform relaxation should be judged against — the largest
;; throughput any hard form carries, by the same `max(1, |const|, Σ|coeff·x|)`
;; reading `plan-grossly-infeasible?` applies per constraint. Phase-I's s* is one
;; scalar added to EVERY hard form, so it is read against the program as a whole.
(define (program-scale C x)
  (let ((nt (cnt C)) (m 1.0))
    (do ((ti 0 (+ ti 1))) ((= ti nt) m)
      (when (memv (vector-ref (ckind C) ti) '(0 3 4))
        (set! m (max m (form-scale C x ti)))))))

;; The one place the engine decides "this relaxation is too big to call feasible".
;; RELATIVE, because s* is a quantity in the goods' own units: an absolute 1e-3 is
;; noise beside a kcal-scale floor and an enormous concession beside a kg-scale
;; stock — the same scale-blindness that once let a solve draw 182× the soil it
;; had. s* itself stays physical, so `signal-infeasible!` can still name a real
;; amount; only the JUDGEMENT about it is dimensionless.
(define (infeasible-by? C x s*)
  (> s* (* *infeas-tol* (program-scale C x))))

(define (phase1-decide forms labform x0 core)
  "→ (values x s*). s* is the least uniform relaxation that admits a plan, in the
   goods' own units — `infeasible-by?` is what reads it against the program's
   magnitude, so this stays a measurement and the threshold stays in one place.

   What this verdict is entitled to claim is machine-checked
   (docs/formal/solver-certificate, PhaseOne.lean): the start point below is
   strictly interior; s* > 0 uniformly certifies infeasibility; accepting
   s* ≤ ε concedes at most ε on every hard row; and on a FEASIBLE program an
   interior-point phase-I drives s toward 0 without reaching it (the pin
   case above) — which is why the threshold reads a margin, not zero."
  (let* ((C (flatten forms)) (na (vector-length x0)) (smin (bar-slacks-min C (term-values C x0))))
    (if (> smin 1e-7) (values x0 0.0)
        (call-with-values (lambda () (augment-phase1 forms na))
          (lambda (af alf)
            (let* ((s0 (+ (max 0.0 (- smin)) 1.0))            ; s_ℓ(x0)+s0 > 0 ∀ℓ
                   (x0a (let ((v (make-vector (+ na 1) 0.0))) (do ((i 0 (+ i 1))) ((= i na)) (vector-set! v i (vector-ref x0 i))) (vector-set! v na s0) v))
                   ;; phase-I just needs A feasible point — and its slack appears
                   ;; in EVERY hard form, a dense column that poisons a plain
                   ;; incomplete factor. This guard used to fire only for
                   ;; 'direct while the default IC(0) slipped through, and the
                   ;; factor's garbage Newton directions stalled the line search
                   ;; with the slack still MACROSCOPIC — measured on the 7-day
                   ;; household-week program: s* 0.152 under ic0 (33 Newtons,
                   ;; stalled) vs 7e-5 under jacobi (197 Newtons, converged),
                   ;; everything else identical. Downstream, every mechanism
                   ;; sized for floor-scale (~1e-5) phase-I residuals amplified
                   ;; that 0.152 into a returned plan 0.15 OUTSIDE a true stock
                   ;; wall — certified infeasible, but handed back as quantities
                   ;; all the same. So phase-I runs matrix-free Jacobi-CG, which
                   ;; is immune by construction — EXCEPT on a hub-rich program,
                   ;; where `auto-precond` on the UNAUGMENTED C already chooses
                   ;; 'ic0w: there the dense hub rows (a communal stock drawn by
                   ;; every mouth) are the dominant ill-conditioning, Jacobi-CG
                   ;; saturates on them (N=1000 festival: 252k CG iterations,
                   ;; stationarity 0.999 — an UNCONVERGED phase-I whose s* is
                   ;; no certificate), and ic0w prices the hubs exactly through
                   ;; its Woodbury block while the slack's clique fill rides the
                   ;; sparse factor. The decision reads the unaugmented program
                   ;; because the slack inflates nnz and so the df threshold:
                   ;; the same hubs sit under it after augmentation. A hub-free
                   ;; program (household-week: df=0) keeps jacobi, so the
                   ;; measured regression above stays impossible by this gate.
                   (p1 (if (eq? (auto-precond C) 'ic0w) 'ic0w 'jacobi))
                   (saved *kern-precond*))
              (call-with-values (lambda () (dynamic-wind
                                            (lambda () (set! *kern-precond* p1))
                                            (lambda () (core af alf x0a 1.0))
                                            (lambda () (set! *kern-precond* saved))))
                (lambda (xa . rest)
                  (let ((x (make-vector na)))
                    (do ((i 0 (+ i 1))) ((= i na)) (vector-set! x i (vector-ref xa i)))
                    (when (getenv "PLANNER_PD_DEBUG")
                      (format (current-error-port) "  [phase-I] s*=~,3e n=~a cgcap=~a core-rest=~s scale=~,3e tol=~,3e~%" (vector-ref xa na) na *kern-cgcap* rest
                              (program-scale C x) (* *infeas-tol* (program-scale C x))))
                    (values x (max 0.0 (vector-ref xa na))))))))))))

(define (infeasibility-report forms x s*)
  "The obstruction, not the symptom: how much the limits are missed by, and WHICH
   limits miss. A scope can act on a named boundary and a quantity; it can do
   nothing with the word `infeasible`."
  (let* ((C (flatten forms)) (sv (term-values C x)) (nt (cnt C))
         (worst (let lp ((ti 0) (acc '()))
                  (if (= ti nt) acc
                      (lp (+ ti 1)
                          (if (and (memv (vector-ref (ckind C) ti) '(0 3 4))
                                   (< (vector-ref sv ti) 0.0))
                              (cons (cons ti (vector-ref sv ti)) acc)
                              acc))))))
    `((kind . infeasible)
      (feasible? . #f)
      (violation . ,s*)                       ; least relaxation that admits a plan
      (breached . ,(length worst))            ; how many limits are breached
      (worst . ,(if (null? worst) '()
                    (list-head (sort worst (lambda (a b) (< (cdr a) (cdr b))))
                               (min 3 (length worst))))))))

;; the program's own statement that it has NO ROOM — one typed raise
;; ('planner-starvation), so a caller asking "did the PROGRAM refuse?"
;; reads the key, never the prose. Every starvation path speaks through
;; it: phase-I/native (no strictly-feasible point), the published-
;; obstruction door below, robust's scenario floors, and
;; substitute-fixed's decided-count check.
(define (raise-starvation msg . irritants)
  (apply throw* 'planner-starvation msg irritants))

(define (signal-infeasible! forms x s*)
  "Publish the obstruction, then refuse. One place, so the certificate and the
   message can never say different things."
  (set! *last-certificate* (infeasibility-report forms x s*))
  (raise-starvation
   (format #f "INFEASIBLE by ~,4e — ~a limit(s) breached; no plan exists until they are relaxed"
           s* (assq-ref *last-certificate* 'breached))))

(define (ensure-feasible forms labform x0 core)
  "Strictly-bar-feasible point: x0 if it already is, else phase-I's. Kept for the
   call sites that only want the point; `phase1-decide` carries the verdict."
  (call-with-values (lambda () (phase1-decide forms labform x0 core))
    (lambda (x s*) x)))
;; ── ONE SOLVE, SEVERAL ATTEMPTS, ONE RULE FOR ACCEPTING ONE ─────────────────
;;
;; Three separate rescues live here, and they were three nested special cases
;; until they were not worth reading. Written as a list they are one policy:
;; try the strategies in order, take the first result that is ADMISSIBLE, and if
;; none is, keep the best plan anyone produced.
;;
;;   1. native-c            — the path-following step, regularized as configured.
;;   2. native-c, greg off  — for a DEGENERATE problem. λ = c·√‖g‖ fades with the
;;      gradient, which is what leaves no bias at the optimum and also what makes
;;      it useless on a plateau: λ collapses while there is still distance to
;;      walk. Measured at the SHIPPED c=0.01 on `setup-space` τ=0.002 — 55.5% met
;;      in 9 Newton steps where the plain step gets 91.6% in 194. Phase-I is
;;      redone unregularized too, since it runs through the same core.
;;   3. OSQP                — a genuinely different algorithm for when the
;;      interior-point step is simply stuck. NOT admissible for `qc` (it cannot
;;      express congestion) nor for `frag`: OSQP has no log-barrier, only linear
;;      constraints, so a fragility becomes a hard cap AT its tip rather than a
;;      pull felt before it. Measured on the frag rig (tip 10, optimum 9.0840):
;;      native returns 9.0839, OSQP 10.0001 — an ecological limit breached and
;;      reported converged.
;;
;; ADMISSIBLE = the plan is made of numbers, AND it either converged or already
;; delivers the demand, AND it is no worse than the best seen. The middle clause
;; is the old met-floor short-circuit; the last is the old "take OSQP only if it
;; delivers more". Both fall out of one predicate instead of being special cases.
;;
;; Regressions: test-frag-farstart.scm, test-greg-degeneracy.scm,
;; test-pd-finiteness.scm.

(define (plan-finite? x)
  "A plan is made of numbers. A NaN or an overflow is a number-shaped absence
   that compares false against every threshold it later meets."
  (let lp ((i 0))
    (cond ((= i (vector-length x)) #t)
          ((let ((v (vector-ref x i))) (and (real? v) (= v v) (< (abs v) 1e300))) (lp (+ i 1)))
          (else #f))))

;; ════════════════════════════════════════════════════════════════════════════
;; §3 — CERTIFICATION: what a returned plan actually holds
;; one measurement, every backend: the KKT conditions, the certified
;; suboptimality bound with its proof obligations, the face geometry
;; behind it, and the published per-solve certificate.
;; ════════════════════════════════════════════════════════════════════════════

;; The central-path certificate, as DATA. At the stopping barrier-t the duality
;; gap to the true optimum is ≤ m·t (m = # hard possibility-tensions). The solve
;; already returns t; this just names the bound so callers (live.scm's auto-re-
;; solve) can ASSERT near-optimality rather than read it off a printf.
(define (plan-certificate forms t)
  (let ((m (count (lambda (f) (eq? (f-kind f) 'bar)) forms)))
    (list (cons 'barrier-t t) (cons 'm-constraints m) (cons 'duality-gap-bound (* m t)))))

;; The certificate a PLAN carries: the gap arithmetic above, plus the solve's own
;; VERDICT. The compiled backend answers an unsatisfiable program by publishing
;; the obstruction and returning the phase-I point — a vector shaped like a plan
;; that draws stock nobody has. Reporting only `barrier-t`/`duality-gap-bound`
;; leaves a caller unable to tell that point from a plan, so the fields the
;; backend already computes (feasible?, the violation, which limits are breached)
;; ride here too, and `feasible?` is present on every solve rather than only on
;; the ones that failed.
;; PLANNER_INVARIANTS=1 — the standing check the whole suite runs under. Every
;; defect this engine hid in 2026-08 shared one shape: a program that was not what
;; anyone thought it was, reported in numbers that looked fine. An infeasible
;; solve returning its phase-I point is the general case of that, and a test
;; reading only quantities passes on it. Under this flag a solve whose own
;; certificate says infeasible RAISES, so the silence is impossible.
;;
;; A test that MEANS to prove something impossible — mining a stock to exhaustion,
;; clearcutting a forest, a floor that collides with a wall — passes
;; #:allow-infeasible? #t and says so in its own assertions. Declaring the intent
;; is the point: an unannounced infeasible solve is a bug, an announced one is a
;; finding.
(define (assert-plan-invariants! cert allow-infeasible?)
  (when (and (getenv "PLANNER_INVARIANTS") (not allow-infeasible?)
             (list? cert) (eq? #f (assq-ref cert 'feasible?)))
    (error (format #f "plan invariants: this solve is INFEASIBLE (worst limit missed by ~a) and its caller did not declare that it might be. The returned quantities are not a plan. Pass #:allow-infeasible? #t if the impossibility is the point."
                   (or (assq-ref cert 'violation)
                       (and=> (assq-ref cert 'min-slack) -) 'an-unreported-amount)))))

;; sigma/residual ride here too — the honesty radius (need-displacement, service.scm)
;; reads them off the CACHED plan's certificate, and until they were named
;; here plan-verdict's filter silently dropped them: *last-certificate* always
;; carried the full kkt-report, but no live solve's cached plan ever kept
;; sigma past this list, so the honesty chip was dark on every real solve —
;; found live-checking this wiring (2026-09), the stubbed unit test having
;; proved only that need-displacement reads sigma correctly WHEN present.
(define %verdict-fields '(kind feasible? optimal? violation breached worst min-slack sigma residual))
(define (plan-verdict forms t)
  (let* ((v (certificate-of-last-solve))
         (kept (if (list? v)
                   (filter (lambda (kv) (and (pair? kv) (memq (car kv) %verdict-fields))) v)
                   '())))
    ;; PLANNER_VERDICT=1 — one line per solve: did it respect every limit, and is
    ;; it certified optimal? A census across a test run answers "does the planner
    ;; make feasible, optimal plans" with counts rather than with confidence.
    (when (getenv "PLANNER_VERDICT")
      (simple-format (current-error-port) "[VERDICT] feasible=~A optimal=~A gap=~A~%"
                     (if (assq 'feasible? kept) (assq-ref kept 'feasible?) 'unreported)
                     (if (assq 'optimal? kept) (assq-ref kept 'optimal?) 'unreported)
                     (* (count (lambda (f) (eq? (f-kind f) 'bar)) forms) t)))
    (append (plan-certificate forms t) kept)))

;; ── PRIMAL-DUAL Mehrotra (pk_solve_pd) — adaptive σ predictor-corrector. The
;; 'bar terms are the constraints (duals y); kinds 1-3 the smooth objective.
;; Converges in ~10-20 iters where path-following grinds to its Newton cap on a
;; flat/degenerate optimum (validated ~18× fewer outer steps, bench-mehrotra.scm).
;; Matrix-free: reuses the SAME Hv with cv[bar]=y/s + the Jacobi CG. Returns
;; (values x iters) — iters = primal-dual iterations (each = 2 CG solves).
;; ── KKT: ONE MEASUREMENT, EVERY BACKEND ─────────────────────────────────────
;;
;; A plan is optimal exactly when it satisfies the Karush-Kuhn-Tucker conditions,
;; and every question this engine was asking in three different ways is one of
;; them:
;;
;;   primal feasibility   sᵢ(x) ≥ 0     — is the plan INSIDE its limits?
;;   dual feasibility     yᵢ ≥ 0        — free here: y is built as t/sᵢ > 0
;;   stationarity         ∇f − Aᵀy = 0  — is it a critical point?
;;   complementarity      sᵢyᵢ = 0      — the duality gap μ = sᵀy/m
;;
;; This replaces machinery rather than adding to it. `plan-finite?` was a proxy
;; (a NaN plan has NaN residuals). Per-backend `conv?` flags were a proxy
;; (stationarity is the thing they were approximating). And the three separate
;; "OSQP may not be handed a fragility" exclusions were a proxy for PRIMAL
;; FEASIBILITY: a plan sitting past a fragility tip has sᵢ < 0 and fails here, no
;; matter which solver produced it or whether anyone remembered to exclude it.
;; One test catches what three special cases were each catching partially.
;;
;; The dual costs nothing to construct. `csr-grad` at parameter t already returns
;; ∇f − Aᵀy for yᵢ = t/sᵢ — that IS the central-path dual — so the stationarity
;; residual is a gradient the solver can already compute. And when t is unknown
;; (an OSQP result, say), the best such dual is a single scalar: minimise
;; ‖g₀ − t·v‖ over t, where v = Σ_bar aᵢ/sᵢ = g₀ − g₁. One projection, and any
;; plan from any source gets a certificate.
;; ── A CERTIFIED SUBOPTIMALITY BOUND, WITH ITS PROOF ─────────────────────────
;;
;; THEOREM. f convex and differentiable, s(x) = c + Ax affine, S = {x : s(x) ≥ 0}.
;; For any x ∈ S, any y ≥ 0, and r ≔ ∇f(x) − Aᵀy, every feasible x* satisfies
;;
;;     f(x) − f(x*)  ≤  yᵀs(x) + ‖r‖·‖x − x*‖.
;;
;; PROOF. Convexity: f(x*) ≥ f(x) + ∇f(x)ᵀ(x* − x). Substituting ∇f = Aᵀy + r,
;;   f(x) − f(x*) ≤ −(Aᵀy + r)ᵀ(x* − x)
;;                = −yᵀ(s(x*) − s(x)) − rᵀ(x* − x)      [A(x*−x) = s(x*)−s(x)]
;;                = yᵀs(x) − yᵀs(x*) − rᵀ(x* − x)
;;                ≤ yᵀs(x) + ‖r‖‖x* − x‖,               [y ≥ 0, s(x*) ≥ 0 ⇒ −yᵀs(x*) ≤ 0]
;; and Cauchy–Schwarz on the last term. ∎
;;
;; Why this matters here. The engine reported μ and ‖r‖ as two separate numbers
;; and never combined them — but with r ≠ 0, which is the ordinary case, yᵀs(x)
;; ALONE BOUNDS NOTHING. The theorem says what the missing piece is and what it
;; costs: a bound on how far the optimum can be, ‖x − x*‖.
;;
;; DUAL FEASIBILITY IS FREE, not tested: yᵢ = t/sᵢ with t > 0 and sᵢ > 0 is
;; positive by construction, so the y ≥ 0 hypothesis holds identically.
;;
;; The distance bound comes from the constraints themselves. A row with a
;; positive constant and non-positive coefficients (c − Σ|aⱼ|xⱼ ≥ 0) caps every
;; variable it touches at c/|aⱼ|; with x ≥ 0 that boxes the feasible set. Where no
;; row caps a variable the box is unbounded and the honest answer is +inf — an
;; unbounded feasible set admits no finite bound BY THIS ARGUMENT, and saying so
;; is better than quoting yᵀs(x) as though the r term were zero.
(define (strong-convexity-modulus C n sv t)
  "A rigorous LOWER bound on the strong-convexity modulus σ of the objective.

   H = Σᵢ φ″ᵢ aᵢaᵢᵀ. Any term whose row touches a SINGLE variable contributes
   φ″·a² to that diagonal entry and nothing else, so H ⪰ diag(d) over those terms
   alone and λ_min(H) ≥ min_j dⱼ. Every activity column carries an x ≥ 0 barrier
   (φ″ = t/s²), so every variable normally has such a term; if any does not, the
   objective is not strongly convex along that direction and the honest σ is 0.

   Cheap, and loose in the usual direction: a smaller σ gives a WEAKER bound,
   never an unsound one."
  (let ((d (make-vector n 0.0)) (nt (cnt C))
        (ptr (cptr C)) (idx (cidx C)) (val (cval C)))
    (do ((ti 0 (+ ti 1))) ((= ti nt))
      (let ((lo (vector-ref ptr ti)) (hi (vector-ref ptr (+ ti 1))))
        (when (= (- hi lo) 1)                       ; touches exactly one variable
          (let* ((j (vector-ref idx lo)) (a (vector-ref val lo))
                 (c ((kind-curv (vector-ref *kind-fns* (vector-ref (ckind C) ti)))
                     (vector-ref sv ti) t (vector-ref (cD C) ti) (vector-ref (cw C) ti))))
            (when (> c 0.0)
              (vector-set! d j (+ (vector-ref d j) (* c a a))))))))
    (let lp ((j 0) (m +inf.0))
      (cond ((= j n) (if (= m +inf.0) 0.0 m))
            ((= (vector-ref d j) 0.0) 0.0)          ; one flat direction ⇒ not strongly convex
            (else (lp (+ j 1) (min m (vector-ref d j))))))))

(define (optimal-face-dimension C n g0 sv)
  "A CONSTRUCTIVE lower bound on the dimension of the optimal face at x, returned
   as (total free-coordinates interchangeable).

   When the objective is flat, σ = 0, the curvature bound ‖r‖²/(2σ) is +inf, and
   only the geometry bound ‖r‖·D survives. The usual remedy is to weaken the
   regularity assumption — Polyak–Łojasiewicz, or Kurdyka–Łojasiewicz with an
   exponent, which bound f(x) − f* by a power of the gradient and hold where
   strong convexity fails. On THIS objective they buy nothing, and the reason is
   structural: a desire term is w·((D−s)/D)² only while s < D and is identically
   zero once the demand is met, so past satiation f really is constant along
   those directions. The PL constant vanishes exactly where σ does. There is no
   distance to the optimum to bound, because the optimum is not a point.

   The provable object is the FACE. A direction d leaves f unchanged when
     (a) ∇f·d = 0 — no first-order change; and
     (b) aᵢ·d = 0 for every form carrying curvature at barrier weight 0 — none to
         second order either.
   Curvature at barrier weight 0 is exactly: a `bar` has none (φ″ = t/s² vanishes),
   a SATIATED desire has none (φ″ = 0 once s ≥ D), and `qc`/`frag` always do,
   carrying their own fixed weight rather than the swept t. An interior-point
   iterate is strictly feasible, so a small step along such a d stays feasible.
   The face therefore contains the null space of [∇f; A_curved], of dimension
   n − rank, and computing that rank outright is a sparse factorisation this has
   no business doing on every solve.

   Two families of that null space are readable directly from the structure, and
   between them they cover the degeneracies that actually arise:

     FREE COORDINATES — columns no curved form touches at all. Each satisfies (b)
       outright. They span a subspace on which the ONLY remaining condition is the
       single linear one ∇f·d = 0, so they contribute their count less at most
       one. Note the sharpening over requiring ∂f/∂x_j = 0 column by column: a set
       of untouched columns needs to be COLLECTIVELY orthogonal to the gradient,
       not individually flat. Two free transport arcs of equal cost are a face
       even though moving either one alone is not.

     INTERCHANGEABLE COLUMNS — columns with identical coefficients across every
       curved form and equal objective gradient. For any two, e_j − e_k satisfies
       both conditions, and a group of g gives g−1 independent such directions.
       This is the same technology entered twice, or two mills a plan has no
       reason to prefer between, and it is invisible to any per-coordinate test.

   The two families have disjoint support, so the counts add. One-sided in the
   safe direction throughout: flatness outside these families goes uncounted, so
   0 means `none found`, never `the optimum is unique`."
  (let* ((nt (cnt C)) (ptr (cptr C)) (idx (cidx C)) (val (cval C))
         (sig (make-vector n '()))            ; per column: ((form . coeff) …) over CURVED forms
         (gs (sqrt (let lp ((i 0) (a 0.0))
                     (if (= i n) a (lp (+ i 1) (+ a (expt (vector-ref g0 i) 2)))))))
         (tol (* 1e-9 (+ 1.0 gs))))
    (do ((ti 0 (+ ti 1))) ((= ti nt))
      (let ((c ((kind-curv (vector-ref *kind-fns* (vector-ref (ckind C) ti)))
                (vector-ref sv ti) 0.0 (vector-ref (cD C) ti) (vector-ref (cw C) ti))))
        (when (> c 0.0)
          (do ((k (vector-ref ptr ti) (+ k 1))) ((= k (vector-ref ptr (+ ti 1))))
            (let ((j (vector-ref idx k)))
              (vector-set! sig j (cons (cons ti (vector-ref val k)) (vector-ref sig j))))))))
    ;; ── family 1: columns untouched by curvature ────────────────────────────
    (let* ((free (let lp ((j 0) (acc '()))
                   (if (= j n) acc
                       (lp (+ j 1) (if (null? (vector-ref sig j)) (cons j acc) acc)))))
           (nfree (length free))
           ;; one condition ∇f·d = 0 remains on their span, and it BINDS only if
           ;; the gradient restricted to them is not already zero
           (grad-binds? (any (lambda (j) (> (abs (vector-ref g0 j)) tol)) free))
           (dim-free (max 0 (- nfree (if grad-binds? 1 0))))
           ;; ── family 2: interchangeable columns among the rest ──────────────
           (groups (make-hash-table)))
      (define colgroups (make-hash-table))     ; signature → ((col . grad) …)
      (let lp ((j 0))
        (when (< j n)
          (unless (null? (vector-ref sig j))
            (hash-set! groups (vector-ref sig j)
                       (cons (vector-ref g0 j) (hash-ref groups (vector-ref sig j) '())))
            (hash-set! colgroups (vector-ref sig j)
                       (cons (cons j (vector-ref g0 j)) (hash-ref colgroups (vector-ref sig j) '()))))
          (lp (+ j 1))))
      (let ((dim-swap
             (hash-fold
               (lambda (k gvals acc)
                 ;; within one signature, only columns of EQUAL gradient are
                 ;; interchangeable; count each run of equal gradients as g−1
                 (let lp ((gsorted (sort gvals <)) (run 0) (prev #f) (a acc))
                   (cond ((null? gsorted) (+ a (max 0 (- run 1))))
                         ((and prev (<= (abs (- (car gsorted) prev)) tol))
                          (lp (cdr gsorted) (+ run 1) (car gsorted) a))
                         (else (lp (cdr gsorted) 1 (car gsorted) (+ a (max 0 (- run 1))))))))
               0 groups)))
        ;; …and EXHIBIT a bounded sample of the directions, so their EXTENT can be
        ;; measured. Dimension and extent are different questions: a free
        ;; direction the plan has no room to take is still a free direction, and
        ;; reporting only the count says "many equally good plans" for a priced
        ;; transport cycle with 9·10⁻⁵ of room exactly as loudly as for two
        ;; interchangeable mills with 4·10¹. Capped at *face-dirs-max* because the
        ;; free set can be large and this runs on every solve; the extent computed
        ;; from a subset is a LOWER bound on the best room available, which is the
        ;; safe direction to be wrong in.
        (let* ((axes (if grad-binds?
                         (let ((p (find (lambda (j) (> (abs (vector-ref g0 j)) tol)) free)))
                           (filter-map (lambda (j)
                                         (and p (not (= j p))
                                              (list (cons j 1.0)
                                                    (cons p (- (/ (vector-ref g0 j)
                                                                  (vector-ref g0 p)))))))
                                       free))
                         (map (lambda (j) (list (cons j 1.0))) free)))
               (swaps (hash-fold
                        (lambda (k cols acc)
                          (let lp ((cs (sort cols (lambda (a b) (< (car a) (car b))))) (out acc))
                            (if (or (null? cs) (null? (cdr cs))) out
                                (if (<= (abs (- (cdr (car cs)) (cdr (cadr cs)))) tol)
                                    (lp (cdr cs) (cons (list (cons (car (car cs)) 1.0)
                                                             (cons (car (cadr cs)) -1.0)) out))
                                    (lp (cdr cs) out)))))
                        '() colgroups))
               (dirs (let take ((l (append axes swaps)) (k 0) (acc '()))
                       (if (or (null? l) (>= k *face-dirs-max*)) (reverse acc)
                           (take (cdr l) (+ k 1) (cons (car l) acc))))))
          (list (+ dim-free dim-swap) dim-free dim-swap dirs))))))

(define* (column-bounds C n #:optional (seed #f) (rounds 12) #:key (lower? #f))
  "(values u l): upper bounds uⱼ and lower bounds lⱼ valid for EVERY feasible
   point of C, by interval propagation.

   `feasible-box-radius` reads a bound off a single row and only when that row has
   NO positive coefficients — the easy case, where every other variable can only
   help. That misses the rows that matter here. A federated scope's balance
   row reads

       g − b + import − export ≥ 0,

   which caps `export` perfectly well *once something caps g and import*. So the
   rule generalises: for a row c + Σaᵢxᵢ ≥ 0 and a variable j with aⱼ < 0,

       xⱼ ≤ (c + Σ_{i≠j, aᵢ>0} aᵢ·uᵢ) / (−aⱼ)

   because the NEGATIVE terms only shrink the left side and every variable
   carries an x ≥ 0 barrier, so dropping them is sound. Iterating this until
   nothing moves is ordinary interval propagation; it is monotone (bounds only
   fall) so it terminates, and every bound it produces holds at every feasible
   point, which is what the certificate's radius needs.

   `seed` supplies bounds the matrix cannot know — for a federated scope, the cap
   its neighbours' capacity puts on what it may import.

   LOWER? reads the floors too. A column that a row forces above a floor (a
   reproduction floor holds the consumption of a good at least at its minimum)
   takes the negative term it must pay off the row's budget instead of dropping
   it: with lⱼ a lower bound on the columns that draw on the row, the budget of
   column j is

       Bⱼ = c + Σ_{i≠j, aᵢ>0} aᵢ·uᵢ + Σ_{i≠j, aᵢ<0} aᵢ·lᵢ,

   and a row gives xⱼ ≤ Bⱼ/(−aⱼ) where aⱼ < 0 and xⱼ ≥ −Bⱼ/aⱼ where aⱼ > 0 —
   the same budget read both ways. The floors are the lower bounds the rows of
   one column state (aⱼ > 0, nothing else in the row), and they propagate.
   Without LOWER? every lⱼ stays at the barrier's 0 and the bounds are the
   one-sided ones.

   The step rule and its min-fold update are machine-checked
   (docs/formal/solver-certificate, `propagation_step_sound` /
   `bounds_update_sound`; the two-sided budget by `row_budget` in
   TwoSidedBounds): validity of the bound vectors is a loop invariant, so it
   holds at any round count — the rounds rail changes only tightness."
  (let ((u (if seed (vector-copy seed) (make-vector n +inf.0)))
        (l (make-vector n 0.0))
        (nt (cnt C)) (ptr (cptr C)) (idx (cidx C)) (val (cval C)))
    (let round ((k 0))
      (if (>= k rounds) (values u l)
          (let ((moved #f))
            (do ((ti 0 (+ ti 1))) ((= ti nt))
              (when (= (vector-ref (ckind C) ti) 0)          ; hard constraints only
                (let* ((c  (vector-ref (cconst C) ti))
                       (lo (vector-ref ptr ti)) (hi (vector-ref ptr (+ ti 1)))
                       ;; Σ over aᵢ > 0 of aᵢ·uᵢ, the finite part and the count of infinite terms
                       (pos-fin 0.0) (pos-inf 0)
                       ;; Σ over aᵢ < 0 of aᵢ·lᵢ: what the row's other drawers must take at least
                       (neg 0.0))
                  (do ((m lo (+ m 1))) ((= m hi))
                    (let ((v (vector-ref val m)) (j (vector-ref idx m)))
                      (cond ((> v 0.0)
                             (if (= (vector-ref u j) +inf.0)
                                 (set! pos-inf (+ pos-inf 1))
                                 (set! pos-fin (+ pos-fin (* v (vector-ref u j))))))
                            ((< v 0.0) (set! neg (+ neg (* v (vector-ref l j))))))))
                  ;; upper bounds, at the columns that draw on the row
                  (when (and (= pos-inf 0) (>= (+ c pos-fin) 0.0))
                    (do ((m lo (+ m 1))) ((= m hi))
                      (let ((a (vector-ref val m)) (j (vector-ref idx m)))
                        (when (< a 0.0)
                          ;; this variable's own term is not in the budget
                          (let ((b (/ (+ c pos-fin (- neg (* a (vector-ref l j)))) (- a))))
                            (when (< b (vector-ref u j))
                              (vector-set! u j b) (set! moved #t)))))))
                  ;; lower bounds, at the columns that feed the row (a floor is the one-column row)
                  (when lower?
                    (do ((m lo (+ m 1))) ((= m hi))
                      (let ((a (vector-ref val m)) (j (vector-ref idx m)))
                        (when (> a 0.0)
                          (let* ((uj (vector-ref u j))
                                 ;; the other feeders' total: drop j's own term from the sum
                                 (others (cond ((= uj +inf.0) (and (<= pos-inf 1) pos-fin))
                                               (else (and (= pos-inf 0) (- pos-fin (* a uj)))))))
                            (when others
                              (let ((b (/ (- (+ c others neg)) a)))
                                (when (> b (vector-ref l j))
                                  (vector-set! l j b) (set! moved #t))))))))))))
            (if moved (round (+ k 1)) (values u l)))))))

(define* (column-upper-bounds C n #:optional (seed #f) (rounds 12) #:key (lower? #f))
  "Upper bounds uⱼ valid for EVERY feasible point of C, by interval propagation
   (`column-bounds`, which says how). LOWER? lets the floors tighten them."
  (call-with-values (lambda () (column-bounds C n seed rounds #:lower? lower?))
    (lambda (u l) u)))

;; ── A COLUMN MEASURED FROM WHAT CAN BE GIVEN ────────────────────────────────
;; A good that crosses a scope's boundary crosses either way: the scope
;; supplies it or draws it, and which is the plan's to say. One column carries
;; both. It is the draw on the crossing — it enters the good's balance as a
;; source — measured from G, the most the scope can give:
;;
;;     x′ = G + draw ≥ 0        flow out of the scope  y = G − x′
;;
;; so x′ = 0 gives everything the scope has to give, x′ = G crosses nothing,
;; and x′ above G draws. The column keeps its wall x′ ≥ 0, and with it every
;; statement of this file that rests on that wall (the bound propagation, the
;; radius, the strong-convexity modulus) holds for it as for any other column.
;;
;;   `give-bound`     G, read off the scope's own program
;;   `offset-column`  the program with the column measured from G
;;   `detach-column`  the program with the column taken out of the crossing

(define (column-coeff f col)                  ; the form's coefficient on COL, 0 when it holds none
  (fold (lambda (ic a) (if (= (car ic) col) (+ a (cdr ic)) a)) 0.0 (f-coeffs (form-body f))))

(define (column-wall? f col)                  ; the column's own wall: a world bar on it alone, x ≥ c
  (and (not (method-form? f))
       (eq? (f-kind f) 'bar)
       (let ((cs (f-coeffs f)))
         (and (pair? cs) (null? (cdr cs)) (= (caar cs) col) (> (cdar cs) 0.0)))))

(define (shift-form f col d)                  ; the form with COL standing D further on: const + coeff·D
  (if (method-form? f)
      (cons* 'method (shift-form (cadr f) col d) (cddr f))
      (let ((a (column-coeff f col)))
        (if (zero? a) f
            (cons* (f-kind f) (+ (f-const f) (* a d)) (cddr f))))))

(define (offset-column forms col G)
  "FORMS with column COL measured from G: x := x′ − G in every form that
   holds the column, its own wall left as it is (x′ ≥ 0). Each form keeps its
   kind, its weights and whatever rides behind them, a method tension stays
   one, and the forms keep their order. G = 0 answers FORMS themselves."
  (if (zero? G)
      forms
      (map (lambda (f) (if (column-wall? f col) f (shift-form f col (- G)))) forms)))

(define (detach-column forms col G)
  "FORMS with column COL taken out of the crossing: the column held where it
   crosses nothing (x′ = G) and its term gone from every form that held it, so
   the program is the scope's own without the crossing. The column stays, inert
   under its wall and a cap at nothing, for whoever reads the plan by column."
  (append
   (map (lambda (f)
          (if (column-wall? f col) f
              (let strip ((f f))
                (if (method-form? f)
                    (cons* 'method (strip (cadr f)) (cddr f))
                    (let ((a (column-coeff f col)))
                      (if (zero? a) f
                          (cons* (f-kind f) (+ (f-const f) (* a G))
                                 (remove (lambda (ic) (= (car ic) col)) (f-coeffs f))
                                 (cdddr f))))))))
        forms)
   (list (mk-bar 1e-9 (list (cons col -1.0))))))

(define* (give-bound forms n col #:key (crossing (list col)))
  "The most the program FORMS (N columns) can give through the draw column
   COL: G, and the column that leaves it without bound (#f when it has one).

   A wall that holds COL with a positive coefficient a,  c + a·x + Σ aᵢxᵢ ≥ 0,
   lets x fall to −(c + Σ_{aᵢ>0} aᵢ·uᵢ + Σ_{aᵢ<0} aᵢ·lᵢ)/a at most, the uᵢ the
   upper bounds of the columns that feed the row and the lᵢ the lower bounds of
   the columns that draw on it — a floor holds a consumer at its minimum, and
   what the row must pay it is not there to give. G is the least of those over
   the walls (bar, frag and held all diverge at s = 0), floored at nothing. The
   bounds are `column-bounds` (two-sided) of the program with COL held at 0 —
   what the scope makes of its own — over the rows that hold no column of
   CROSSING with a negative coefficient: the propagation drops what a column
   can only do below nothing, and a crossing column stands here for a quantity
   that goes below nothing. The other columns of CROSSING are unbounded above,
   so a wall they feed bounds nothing."
  (let* ((world (world-forms forms))
         (crossing? (lambda (j) (memv j crossing)))
         (prop (filter (lambda (f) (not (any (lambda (ic) (and (crossing? (car ic)) (< (cdr ic) 0.0)))
                                             (f-coeffs f))))
                       world))
         (seed (let ((v (make-vector n +inf.0))) (vector-set! v col 0.0) v)))
    (call-with-values (lambda () (column-bounds (flatten prop) n seed (max 12 (length prop)) #:lower? #t))
      (lambda (u l) (give-bound* world crossing? col u l)))))

(define (give-bound* world crossing? col u l)
  "The tail of `give-bound`: G off the walls of WORLD, given the bounds U and L."
  (let lp ((fs world) (G +inf.0) (culprit #f))
      (if (null? fs)
          (values (if (= G +inf.0) G (max 0.0 G)) (and (= G +inf.0) culprit))
          (let* ((f (car fs)) (a (column-coeff f col)))
            (if (or (not (memq (f-kind f) '(bar frag held))) (<= a 0.0) (column-wall? f col))
                (lp (cdr fs) G culprit)
                (let row ((cs (f-coeffs f)) (pos 0.0) (open #f))
                  (cond ((pair? cs)
                         (let ((j (caar cs)) (v (cdar cs)))
                           (cond ((= j col) (row (cdr cs) pos open))
                                 ;; another crossing column under a negative coefficient feeds the
                                 ;; row when it goes below nothing, by as much as it may
                                 ((and (< v 0.0) (crossing? j)) (row (cdr cs) +inf.0 (or open j)))
                                 ;; a column that draws on the row pays at least its floor
                                 ((< v 0.0) (row (cdr cs) (+ pos (* v (vector-ref l j))) open))
                                 ((= v 0.0) (row (cdr cs) pos open))
                                 ((= (vector-ref u j) +inf.0) (row (cdr cs) +inf.0 (or open j)))
                                 (else (row (cdr cs) (+ pos (* v (vector-ref u j))) open)))))
                        ((= pos +inf.0) (lp (cdr fs) G (or culprit open)))
                        (else (lp (cdr fs) (min G (/ (+ (f-const f) pos) a)) culprit)))))))))

(define *face-dirs-max* 24)              ; directions sampled for the extent measure

(define (optimal-face-extent C sv dirs)
  "How far the plan can actually MOVE along the exhibited directions before a
   limit stops it — the largest such distance, or 0 when there are none.

   Slacks are affine in the step, s_i(x + t·d) = s_i + t·(aᵢ·d), so each
   direction's room is min over rows with aᵢ·d < 0 of s_i / −(aᵢ·d). Every
   direction has one or two nonzeros, so all of them are measured in ONE pass:
   accumulate each row's dot against every direction in a small scratch vector,
   then fold that row into each running minimum before moving on.

   Reported as the BEST room over the sampled directions. A face whose every
   direction is pinned at 10⁻⁵ is a face the federation cannot act on, and
   quoting its dimension alone would say otherwise."
  (let* ((nd (length dirs)))
    (if (= nd 0) 0.0
        (let* ((dv (list->vector dirs))
               (room (make-vector nd +inf.0))
               (dot (make-vector nd 0.0))
               (nt (cnt C)) (ptr (cptr C)) (idx (cidx C)) (val (cval C)))
          (do ((ti 0 (+ ti 1))) ((= ti nt))
            (when (memv (vector-ref (ckind C) ti) '(0 3 4))     ; hard limits only
              (do ((k 0 (+ k 1))) ((= k nd)) (vector-set! dot k 0.0))
              (do ((m (vector-ref ptr ti) (+ m 1))) ((= m (vector-ref ptr (+ ti 1))))
                (let ((j (vector-ref idx m)) (a (vector-ref val m)))
                  (do ((k 0 (+ k 1))) ((= k nd))
                    (let ((c (assv-ref (vector-ref dv k) j)))
                      (when c (vector-set! dot k (+ (vector-ref dot k) (* a c))))))))
              (do ((k 0 (+ k 1))) ((= k nd))
                (when (< (vector-ref dot k) 0.0)
                  (vector-set! room k (min (vector-ref room k)
                                           (- (/ (vector-ref sv ti) (vector-ref dot k)))))))))
          (let lp ((k 0) (best 0.0))
            (if (= k nd) best
                (lp (+ k 1) (max best (let ((r (vector-ref room k)))
                                        (if (= r +inf.0) 1e300 r))))))))))

;; assv-ref is Guile core, with this exact signature and semantics —
;; (assv-ref alist key) → (cdr (assv key alist)) or #f. Redefining it here was
;; invisible while this file was an include-fragment; as a module it shadowed
;; the core binding for every importer and printed a warning on every suite.

(define (radius-from-bounds u x n)
  "‖x − x*‖ over a box [0,u] containing both, sharpened by x componentwise."
  (let lp ((j 0) (acc 0.0))
    (cond ((= j n) (sqrt acc))
          ((= (vector-ref u j) +inf.0) +inf.0)
          (else (let ((d (max (vector-ref x j)
                              (- (vector-ref u j) (vector-ref x j)))))
                  (lp (+ j 1) (+ acc (* d d))))))))

(define *box-prop-rounds* 8)   ; interval propagation is a fixpoint; this is its rail
;; …and the rail is only honest if somebody can see it bind. These record the
;; LAST propagation: how many rounds it used, and whether it stopped because it
;; reached a fixpoint (#f) or because the rail cut it off (#t). A rail nobody
;; measures is a silent approximation; `test-box-propagation.scm` reads these.
(define *box-prop-last-rounds* 0)
(define *box-prop-last-railed?* #f)

(define (column-caps C n)
  "An upper bound on every column, from the program's own rows.

   One row bounds a column directly when it can spend nothing else:
   c + Σ aⱼxⱼ ≥ 0 with every aⱼ ≤ 0 and c ≥ 0 gives xⱼ ≤ c/|aⱼ| immediately.
   That single-row reading is what this used to do, and it is blind to the
   commonest shape in these programs — an activity bounded not by a constant but
   by a SUPPLY that is itself bounded. `0.3·x ≤ hours-supplied ≤ 20` bounds x,
   and no one row says so.

   So the reading is transitive, by ordinary interval propagation: a row's
   budget is c plus the most its positive terms can contribute, and once every
   positive term is capped the row bounds each of its negative ones. Dropping
   the row's OTHER negative terms is what keeps it sound — they are ≤ 0 on x ≥ 0,
   so ignoring them can only loosen the cap, never invalidate it. Iterate to a
   fixpoint: each round can only lower caps, so it converges, and the rail is
   there because convergence need not be quick.

   A column with no bounding row at all stays +inf, which is the honest answer
   and the one a federated scope's import column deserves — it is a free source,
   and no amount of propagation inside that scope invents a bound for it.

   The sweep reads `u` IN PLACE, so a later row's budget can use a cap written
   earlier in the same round. That looks like the classic double-buffering bug
   and is not one: validity is threaded through every intermediate write
   (docs/formal/solver-certificate, `runWrites_sound`, which models exactly
   this mid-round read). A double-buffer refactor would only cost allocation
   and a round of tightness."
  (let ((u (make-vector n +inf.0)) (nt (cnt C))
        (ptr (cptr C)) (idx (cidx C)) (val (cval C)))
    (set! *box-prop-last-rounds* 0)
    (set! *box-prop-last-railed?* #f)
    (let round ((pass 0) (go? #t))
      ;; PASS is the number already done, so a rail hit is `go? and pass = rail`:
      ;; still work to do and no budget left to do it in.
      (when (and go? (>= pass *box-prop-rounds*)) (set! *box-prop-last-railed?* #t))
      (when (and go? (< pass *box-prop-rounds*))
        (set! *box-prop-last-rounds* (+ pass 1))
        (let ((moved #f))
          (do ((ti 0 (+ ti 1))) ((= ti nt))
            (when (= (vector-ref (ckind C) ti) 0)            ; barrier rows: c + Σ aⱼxⱼ ≥ 0
              (let* ((lo (vector-ref ptr ti)) (hi (vector-ref ptr (+ ti 1)))
                     (budget (let lp ((k lo) (s (vector-ref (cconst C) ti)))
                               (cond ((= k hi) s)
                                     ((> (vector-ref val k) 0.0)
                                      (let ((uk (vector-ref u (vector-ref idx k))))
                                        (if (= uk +inf.0) +inf.0
                                            (lp (+ k 1) (+ s (* (vector-ref val k) uk))))))
                                     (else (lp (+ k 1) s))))))
                (when (and (< budget +inf.0) (>= budget 0.0))
                  (do ((k lo (+ k 1))) ((= k hi))
                    (let ((a (vector-ref val k)) (j (vector-ref idx k)))
                      (when (< a 0.0)
                        (let ((cap (/ budget (- a))))
                          (when (< cap (vector-ref u j))
                            (vector-set! u j cap)
                            (set! moved #t))))))))))
          (round (+ pass 1) moved))))
    u))

(define (box-bounded? C n)
  "Whether the program's own rows bound every column it uses — the condition
   under which `feasible-box-radius` is finite and the certificate's geometry
   branch is live. One fact, read once, used by both."
  (let ((u (column-caps C n)))
    (let lp ((j 0)) (cond ((= j n) #t)
                          ((= (vector-ref u j) +inf.0) #f)
                          (else (lp (+ j 1)))))))

(define* (feasible-box-radius C n #:optional x)
  "A bound on ‖x − x*‖ over the feasible set, or +inf when the constraints do not
   bound some variable. Rigorous and cheap; loose only where the propagation in
   `column-caps` runs out — and looseness costs certificate STRENGTH, never
   soundness.

   Given the current x it is sharpened for free. Only x* needs to lie in the
   box [0, u] — x itself may sit anywhere (mid-solve it often does sit outside
   the propagated box), and |xⱼ − x*ⱼ| ≤ max(xⱼ, uⱼ − xⱼ) still holds
   componentwise: the distance to the FARTHER end of x*'s interval, never the
   whole interval. Do NOT add an in-box guard on x before the sharpened
   branch; it would be dead code that silently disables the sharpening. The
   bound enters the certificate multiplied by ‖r‖, so tightening it tightens
   the proof directly.

   Machine-checked (docs/formal/solver-certificate, BoxRadius.lean): the
   sharpened D bounds ‖x − x*‖ over any box a valid cap vector certifies
   (`norm_sub_le_boxRadius`), sharpening never exceeds the crude ‖u‖
   (`boxRadius_le_crude`), and `box-bounded?`'s reading holds — caps on every
   column make the feasible set bounded (`box_bounded_of_validBounds`)."
  (let ((u (column-caps C n)))
    (let lp ((j 0) (acc 0.0))
      (cond ((= j n) (sqrt acc))
            ((= (vector-ref u j) +inf.0) +inf.0)
            (else
             (let* ((uj (vector-ref u j))
                    (xj (if x (vector-ref x j) 0.0))
                    ;; farther end of [0, uⱼ] from xⱼ — valid because x* is in the box too
                    (d  (if x (max xj (- uj xj)) uj)))
               (lp (+ j 1) (+ acc (* d d)))))))))

(define *kkt-stat-tol* 1e-6)   ; relative stationarity accepted as a critical point
;; ── THE DUAL A PLAN IMPLIES: certification without centring ─────────────────
;; The single-t reconstruction below (y = t/s, one scalar fitted) is exact at a
;; CENTRED point and badly wrong everywhere else — a plateau exit or an OSQP
;; boundary point carries multipliers that are not uniform-t-shaped, so the
;; residual reads enormous against a plan that is in fact globally optimal, and
;; the certificate says +inf about the right answer. The completion is to fit
;; the FULL dual: the KKT multipliers this plan implies, y ≥ 0 supported on the
;; near-active bar rows, minimising ‖∇f − Aᵀy‖. Weak duality makes ANY y ≥ 0
;; sound — f(x) − f(x*) ≤ yᵀs(x) + ‖∇f − Aᵀy‖·‖x − x*‖ — so the fit can only
;; TIGHTEN the certificate, never lie, and it certifies a plan from any solver
;; without the primal path ever needing to centre. Convexity does the rest:
;; a KKT point of these programs IS the global optimum.
;;
;; The fit is a small nonnegative least-squares, solved Lawson–Hanson style:
;; normal equations over the active set (ridged — active rows on an optimal
;; face are often dependent), negative multipliers dropped, re-solved. Skipped
;; when the active set is empty or too large for a dense solve.
(define *dual-fit-cap* 512)
;; The fit changes which candidate an acceptance ladder settles on — a fitted
;; certificate makes a plan admissible EARLIER — and one caller must not have
;; that: federated refinement needs every scope's re-solve to land its vertex
;; by the same rule, so it runs its per-scope solves with the fit off and lets
;; the OUTER certificate (which only reports, never selects there) keep it.
(define *kkt-dual-fit?* #t)
(define (call-without-dual-fit thunk)
  (let ((saved *kkt-dual-fit?*))
    (dynamic-wind (lambda () (set! *kkt-dual-fit?* #f))
                  thunk
                  (lambda () (set! *kkt-dual-fit?* saved)))))
(define (fit-active-dual C x sv g0 n)
  "The multipliers plan X implies: (values y r stat yts) — full-length y ≥ 0,
   the residual r = ∇f − Aᵀy, its relative norm, and yᵀs — or #f when no fit
   is available."
  (let* ((nt (cnt C))
         (act (let lp ((ti 0) (acc '()))
                (if (= ti nt) (reverse acc)
                    (lp (+ ti 1)
                        (if (and (= (vector-ref (ckind C) ti) 0)
                                 (<= (vector-ref sv ti) (* 1e-3 (form-scale C x ti))))
                            (cons ti acc) acc))))))
    (and (pair? act) (<= (length act) *dual-fit-cap*)
         (let* ((rows (map (lambda (ti)      ; sparse row of form ti: ((j . v) …)
                             (let lp ((k (vector-ref (cptr C) ti)) (acc '()))
                               (if (= k (vector-ref (cptr C) (+ ti 1))) acc
                                   (lp (+ k 1) (cons (cons (vector-ref (cidx C) k)
                                                          (vector-ref (cval C) k)) acc)))))
                           act))
                ;; ROWS and ACT are fixed for the whole Lawson–Hanson loop below
                ;; (only S shrinks), so they are vectorised ONCE here: list-ref
                ;; against them inside an O(ms²) nested loop made the matrix
                ;; assembly accidentally O(ms² × |act|) instead of O(ms² × d).
                (rows-v (list->vector rows))
                (act-v (list->vector act))
                (row-dot (lambda (ra rb)     ; a_i·a_j via the shorter row + assv
                           (let ((short (if (< (length ra) (length rb)) ra rb))
                                 (long  (if (< (length ra) (length rb)) rb ra)))
                             (fold (lambda (p acc)
                                     (let ((q (assv (car p) long)))
                                       (if q (+ acc (* (cdr p) (cdr q))) acc)))
                                   0.0 short))))
                (row-g   (lambda (ra) (fold (lambda (p acc) (+ acc (* (cdr p) (vector-ref g0 (car p))))) 0.0 ra)))
                (ridge 1e-10))
           ;; Lawson–Hanson inner loop: solve the ridged normal equations over S,
           ;; drop negative multipliers, re-solve. Terminates: S only shrinks.
           (let loop ((S (iota (length act))))
             (if (null? S)
                 #f
                 (let* ((ms (length S))
                        (S-v (list->vector S))
                        (G (list->vector
                            (map (lambda (i)
                                   (list->vector
                                    (map (lambda (j)
                                           (+ (row-dot (vector-ref rows-v i) (vector-ref rows-v j))
                                              (if (= i j) ridge 0.0)))
                                         S)))
                                 S)))
                        (b (list->vector (map (lambda (i) (row-g (vector-ref rows-v i))) S)))
                        ;; dense Gauss with partial pivoting
                        (y-S (let ((A G) (v (vector-copy b)))
                               (do ((col 0 (+ col 1))) ((= col ms))
                                 (let ((piv (let lp ((r col) (best col))
                                              (if (= r ms) best
                                                  (lp (+ r 1) (if (> (abs (vector-ref (vector-ref A r) col))
                                                                     (abs (vector-ref (vector-ref A best) col)))
                                                                  r best))))))
                                   (let ((tr (vector-ref A col))) (vector-set! A col (vector-ref A piv)) (vector-set! A piv tr))
                                   (let ((tv (vector-ref v col))) (vector-set! v col (vector-ref v piv)) (vector-set! v piv tv))
                                   (let ((p (vector-ref (vector-ref A col) col)))
                                     (unless (= p 0.0)
                                       (do ((r (+ col 1) (+ r 1))) ((= r ms))
                                         (let ((f (/ (vector-ref (vector-ref A r) col) p)))
                                           (unless (= f 0.0)
                                             (do ((c col (+ c 1))) ((= c ms))
                                               (vector-set! (vector-ref A r) c
                                                            (- (vector-ref (vector-ref A r) c)
                                                               (* f (vector-ref (vector-ref A col) c)))))
                                             (vector-set! v r (- (vector-ref v r) (* f (vector-ref v col)))))))))))
                               (let ((y (make-vector ms 0.0)))
                                 (do ((r (- ms 1) (- r 1))) ((< r 0) y)
                                   (let ((p (vector-ref (vector-ref A r) r)))
                                     (vector-set! y r
                                                  (if (= p 0.0) 0.0
                                                      (/ (- (vector-ref v r)
                                                            (let lp ((c (+ r 1)) (acc 0.0))
                                                              (if (= c ms) acc
                                                                  (lp (+ c 1) (+ acc (* (vector-ref (vector-ref A r) c)
                                                                                        (vector-ref y c)))))))
                                                         p))))))))
                        (neg (filter (lambda (k) (< (vector-ref y-S k) -1e-12)) (iota ms))))
                   (if (pair? neg)
                       (loop (map (lambda (k) (vector-ref S-v k))
                                  (filter (lambda (k) (>= (vector-ref y-S k) -1e-12)) (iota ms))))
                       ;; assemble: full-length y (clipped at 0), residual, stat, yᵀs
                       (let ((y (make-vector nt 0.0)) (r (vector-copy g0)) (yts 0.0))
                         (for-each (lambda (k si)
                                     (let ((yi (max 0.0 (vector-ref y-S k)))
                                           (ti (vector-ref act-v si)))
                                       (vector-set! y ti yi)
                                       (set! yts (+ yts (* yi (vector-ref sv ti))))
                                       (for-each (lambda (p)
                                                   (vector-set! r (car p)
                                                                (- (vector-ref r (car p)) (* yi (cdr p)))))
                                                 (vector-ref rows-v si))))
                                   (iota (length S)) S)
                         (let* ((nr (sqrt (let lp ((i 0) (a 0.0))
                                            (if (= i n) a (lp (+ i 1) (+ a (expt (vector-ref r i) 2)))))))
                                (ng (sqrt (let lp ((i 0) (a 0.0))
                                            (if (= i n) a (lp (+ i 1) (+ a (expt (vector-ref g0 i) 2))))))))
                           (list y r (/ nr (+ 1.0 ng)) yts)))))))))))

(define* (kkt-report C labform x #:optional maybe-t #:key (dual #f) (linear '()) (box #f))
  "KKT residuals for plan X. Returns an alist:
     (feasible? . bool)     every barrier slack strictly positive and finite
     (min-slack . v)        the tightest slack; NEGATIVE means a limit is BREACHED
     (mu . v)               complementarity sᵀy/m — the duality gap per constraint
     (stationarity . v)     ‖∇f − Aᵀy‖ relative to ‖∇f‖ — 0 at a critical point
     (optimal? . bool)      feasible AND stationary to tolerance
   With no T the dual is fitted by projection, so a plan from ANY solver — or a
   plan someone hands you — can be checked without re-solving it."
  (let* ((n  (vector-length x))
         (nt (cnt C))
         (sv (term-values C x))
         (fin? (let lp ((i 0)) (cond ((= i n) #t)
                                     ((let ((v (vector-ref x i)))
                                        (and (real? v) (= v v) (< (abs v) 1e300))) (lp (+ i 1)))
                                     (else #f))))
         ;; tightest barrier slack — bar (hard cap), frag (fragility) and held
         ;; (reproduction floor) alike: all three diverge at their own wall, and
         ;; a plan that breaches any one of them is not feasible, full stop.
         ;; ONE definition of that quantity (§0), so this verdict and phase-I's
         ;; screen can never drift apart about which kinds count.
         (mins (bar-slacks-min C sv))
         (g0 (let ((g (csr-grad C labform 0.0 sv n)))   ; ∇f  (no barrier dual)
               ;; extra LINEAR objective terms the caller knows about but the
               ;; forms do not carry — the federated boundary price, for one: a
               ;; coordinated scope is optimising its own program PLUS the price
               ;; of what crosses its boundary, and measuring its residual against
               ;; the unpriced program says only that it is not selfish.
               (for-each (lambda (ic)
                           (vector-set! g (car ic) (+ (vector-ref g (car ic)) (cdr ic))))
                         linear)
               g))
         (g1 (csr-grad C labform 1.0 sv n))        ; ∇f − Aᵀy at t = 1
         (v  (let ((r (make-vector n 0.0)))        ; v = Σ_bar aᵢ/sᵢ
               (do ((i 0 (+ i 1))) ((= i n) r)
                 (vector-set! r i (- (vector-ref g0 i) (vector-ref g1 i))))))
         (nrm (lambda (u) (sqrt (let lp ((i 0) (a 0.0))
                                  (if (= i n) a (lp (+ i 1) (+ a (expt (vector-ref u i) 2))))))))
         (dot (lambda (a b) (let lp ((i 0) (s 0.0))
                              (if (= i n) s (lp (+ i 1) (+ s (* (vector-ref a i) (vector-ref b i))))))))
         (vv  (dot v v))
         ;; A GIVEN dual is used as given. The central-path form yᵢ = t/sᵢ is what
         ;; the path-follower actually converges to, and fitting a single t is a
         ;; reasonable stand-in for a solver that reports none — but the
         ;; primal-dual method carries its OWN y, and measuring its residual
         ;; against a reconstructed one is measuring the wrong thing. It read
         ;; 20,966% of the objective where the same program certifies 0.023%
         ;; through the path-follower. A dual is half the answer; take the real
         ;; one whenever it exists.
         (t   (cond (dual (let lp ((ti 0) (acc 0.0) (mm 0))    ; μ = Σsᵢyᵢ/m
                            (if (= ti nt) (if (> mm 0) (/ acc mm) 0.0)
                                (let ((yi (vector-ref dual ti)))
                                  (if (> yi 0.0)
                                      (lp (+ ti 1) (+ acc (* (vector-ref sv ti) yi)) (+ mm 1))
                                      (lp (+ ti 1) acc mm))))))
                    (maybe-t maybe-t)
                    ((> vv 1e-300) (max 0.0 (/ (dot g0 v) vv)))   ; best-fit central dual
                    (else 0.0)))
         (r   (if dual
                  ;; r = ∇f − Aᵀy with the solver's own y
                  (let ((u (vector-copy g0)))
                    (do ((ti 0 (+ ti 1))) ((= ti nt) u)
                      (let ((yi (vector-ref dual ti)))
                        (unless (= yi 0.0)
                          (do ((k (vector-ref (cptr C) ti) (+ k 1)))
                              ((= k (vector-ref (cptr C) (+ ti 1))))
                            (let ((j (vector-ref (cidx C) k)))
                              (vector-set! u j (- (vector-ref u j)
                                                  (* yi (vector-ref (cval C) k)))))))))
                    u)
                  (let ((u (make-vector n 0.0)))       ; ∇f − Aᵀy at the central-path t
                    (do ((i 0 (+ i 1))) ((= i n) u)
                      (vector-set! u i (- (vector-ref g0 i) (* t (vector-ref v i))))))))
         (stat (if fin? (/ (nrm r) (+ 1.0 (nrm g0))) +inf.0))
         (feas (and fin? (bar-slacks-feasible? C x sv))))
    ;; The certified bound of the theorem above: yᵀs(x) + ‖r‖·‖x − x*‖.
    ;;   yᵀs(x) = Σ sᵢ·(t/sᵢ) = m·t over the m BAR terms — exact, because bar is
    ;;   the only kind whose y is ever actually subtracted from ∇f to build r
    ;;   (g0 = csr-grad at t=0, where bar's φ′ is already 0 — frag, des, qc and
    ;;   held stay folded into g0 as smooth objective, at whatever value they
    ;;   carry, so their true dual — the one r is consistent with — is 0).
    ;;   Counting frag toward m as well is not UNSOUND (a nonnegative m·t only
    ;;   loosens an already-valid bound) but it is not the number the theorem
    ;;   proves either; verified empirically (kkt-probe2.scm) that bar-only is
    ;;   strictly tighter by exactly (#frag)·μ and both remain sound. ‖r‖ is the
    ;;   stationarity residual in ABSOLUTE terms (the relative figure is for
    ;;   reading; the theorem needs the raw norm), and the distance factor is
    ;;   the feasible box radius.
    ;; This is the number that is actually PROVEN. `mu` and `stationarity` remain
    ;; for diagnosis, but neither bounds anything on its own.
    (let* ((m     (let lp ((ti 0) (c 0))            ; bar ONLY: the y actually
                    (if (= ti nt) c                    ; subtracted from ∇f is
                        (lp (+ ti 1) (if (= (vector-ref (ckind C) ti) 0) (+ c 1) c)))))   ; y_bar=t/s; every
                                                        ; other kind's true dual is 0
           ;; when the reconstructed dual leaves a large residual, fit the dual
           ;; the plan IMPLIES (fit-active-dual above) and adopt it when tighter:
           ;; the same plan, certified through its own multipliers — an uncentred
           ;; exit or another solver's optimum stops reading as +inf about the
           ;; right answer
           (fit  (and (not dual) fin? (>= stat *kkt-stat-tol*)
                      *kkt-dual-fit?*
                      (fit-active-dual C x sv g0 n)))
           (fit? (and fit (< (caddr fit) stat)))
           (stat (if fit? (caddr fit) stat))
           (rnorm (cond (fit? (nrm (cadr fit))) (fin? (nrm r)) (else +inf.0)))
           ;; TWO independent bounds on the distance term; both are sound, so the
           ;; smaller is sound. They fail in different places, which is the point.
           ;;   geometry — ‖r‖·D from the constraint box. Needs a bounded feasible
           ;;     set; gives +inf when any variable is uncapped.
           ;;   curvature — ‖r‖²/(2σ) by maximising ‖r‖d − (σ/2)d² over d ≥ 0,
           ;;     from σ-strong convexity. Needs NO feasible-set geometry at all,
           ;;     so it still bounds an unbounded program; gives +inf when the
           ;;     objective is flat in some direction (σ = 0).
           ;; `box` lets a caller supply a radius the CONSTRAINTS IN C cannot show.
           ;; A federated scope's import column is a free source — nothing in its own
           ;; program bounds it, so the honest radius there is +inf and the geometry
           ;; branch is dead. What bounds it is the FEDERATION: once the crossings are
           ;; agreed, the boundary columns are bounded, and that is real information
           ;; the scope's own matrix does not contain.
           (rad   (or box (feasible-box-radius C n x)))
           (sigma (if fin? (strong-convexity-modulus C n sv t) 0.0))
           (b-geo (if (and fin? (< rad +inf.0)) (* rnorm rad) +inf.0))
           (b-cvx (if (and fin? (> sigma 0.0)) (/ (* rnorm rnorm) (* 2.0 sigma)) +inf.0))
           (bdist (min b-geo b-cvx))
           ;; Gated on fin? (a NaN/±inf screen) and a finite branch — NOT on
           ;; feas, and that is deliberate, not an oversight: the assembled
           ;; number is `kkt_bound_correct` (docs/formal/solver-certificate,
           ;; Certificate.lean), which carries ZERO hypotheses on x. The bound
           ;; is valid at a plateau exit, an OSQP boundary point, any
           ;; still-infeasible iterate. `feasible?` next door judges the PLAN;
           ;; do not let a tidying refactor make it judge the bound.
           (bound (if (and fin? (< bdist +inf.0))
                      (+ (if fit? (cadddr fit) (* m t)) bdist)
                      +inf.0))
           (fc    (if fin? (optimal-face-dimension C n g0 sv) '(0 0 0 ())))
           ;; DIMENSION IS NOT EXTENT — measured, not left in a test where nobody
           ;; reading the certificate can see it.
           (fext  (if (and fin? (> (car fc) 0))
                      (optimal-face-extent C sv (list-ref fc 3))
                      0.0)))
      `((feasible?    . ,feas)
        (min-slack    . ,mins)
        (mu           . ,(if fin? t +inf.0))
        (stationarity . ,stat)
        (residual     . ,rnorm)          ; ‖r‖ absolute — the theorem's term
        (box-radius   . ,rad)            ; ‖x − x*‖ bound from the constraints
        (sigma        . ,sigma)          ; strong-convexity modulus (0 = flat somewhere)
        (dist-geometry . ,b-geo)         ; ‖r‖·D
        (dist-curvature . ,b-cvx)        ; ‖r‖²/(2σ) — needs no geometry
        (m            . ,m)              ; barrier terms, for yᵀs(x) = m·t
        ;; The gap bound is machine-checked END TO END — this exact assembled
        ;; number, yᵀs + min(‖r‖·D, ‖r‖²/(2σ)), is `kkt_bound_correct`
        ;; (docs/formal/solver-certificate, Certificate.lean), with the two
        ;; branches, D's derivation, and σ's derivation each their own theorem.
        ;; And the proof needs NO primal feasibility of x: the bound certifies
        ;; f(x) − f(x*) even for a slightly-infeasible plan. Feasibility is the
        ;; plan's own verdict (`feasible?` above), a separate claim; do not
        ;; "tighten" the bound by gating it on feas.
        (gap-bound    . ,bound)          ; ← CERTIFIED: f(x) − f(x*) ≤ this
        (dual-fitted  . ,(and fit? #t))  ; certified through the plan's OWN implied multipliers
        ;; What the bound cannot express: whether the optimum is a POINT. On a
        ;; plateau the plan is one of a whole face of equally good plans, and
        ;; which of them to adopt is a political choice, not a numerical one.
        ;; (total free-coordinates interchangeable) — see optimal-face-dimension
        (face         . ,(list-head fc 3))
        (face-dim     . ,(car fc))
        (face-extent  . ,fext)              ; best room along a free direction
        (optimal?     . ,(and feas (< stat *kkt-stat-tol*)))))))
;; `stationarity` is CALIBRATED: at a known t it is bit-for-bit the same quantity
;; the solver itself minimises (csr-grad at parameter t IS ∇f − Aᵀy for the
;; central-path dual yᵢ = t/sᵢ), verified by computing both on one solve. It
;; appeared to disagree only because the convergence flag it was compared against
;; was reporting a DEMAND PLATEAU as convergence — see the met-plateau exit in
;; solve-native-c-core. With that fixed the two agree, and `optimal?` is a verdict
;; rather than a hope. Normalised by (1 + ‖∇f‖) so the threshold is scale-free.

;; THE CERTIFICATE OF THE LAST SOLVE — the KKT report, and nothing else.
;;
;; This used to be a taxonomy: 'duality-gap for the primal-dual, 'path-floor for
;; the path-follower, 'none for OSQP, each with its own meaning and its own way of
;; being computed. That was three names for one quantity. The KKT residuals are
;; defined for any (x, y) whatever produced them, and the dual can be fitted when
;; a solver does not carry one — so every backend reports the SAME certificate and
;; a caller no longer has to know which solver ran to know what it holds.
;;
;; μ from the primal-dual step is kept alongside when available: it is measured
;; from a real dual iterate rather than fitted, so it is the sharper number, and
;; the two agreeing is itself a check.
;;
;; Read immediately after a solve; not safe across concurrent solves.
;; Regression: tests/solve/test-certificate.scm.
;; the last solve's certificate: ONE context cell (playnet protocol context),
;; so a compiled importer reads the cell's field and never a folded initial value
(define-context certificate #:cell %certificate
  (*last-certificate* '((feasible? . #f) (optimal? . #f))))
(define (certificate-of-last-solve) *last-certificate*)
(define (set-last-certificate! c) (set! *last-certificate* c))   ; the door for a caller that resets it — an importer's own set! writes a box this module never reads once compiled
(define* (set-certificate-from-kkt! k #:optional measured-mu)
  (set! *last-certificate* (if measured-mu (cons (cons 'measured-mu measured-mu) k) k)))

(define (face-clause c)
  "The FACE sentence a certificate carries, or \"\" when the optimum is a point.

   Its own procedure because it belongs to two branches of `certificate-summary`
   and used to live in one: a face is the σ = 0 case, so it is reported most
   often exactly where no finite bound is provable."
  (let* ((f (or (assq-ref c 'face) '(0 0 0)))
         (fd (car f)))
    (if (> fd 0)
        ;; DIMENSION IS NOT EXTENT. A free direction the plan has no room to
        ;; take is still a free direction, and a plan can sit on its own face's
        ;; edge — measured at 9·10⁻⁵ of room on a priced transport cycle against
        ;; 4·10¹ between two interchangeable mills. Claiming "many equally good
        ;; plans" from the dimension alone would be true of the second and false
        ;; of the first, so the extent decides what the dimension MEANS and
        ;; travels with the plan.
        (let ((ext (or (assq-ref c 'face-extent) 0.0)))
          (if (> ext 1e-3)
              (format #f "; the optimum is a FACE of dimension ≥ ~a (~a free, ~a interchangeable) with room ~,3e to move — equally good plans lie along it, and WHICH to take is a choice, not a computation"
                      fd (cadr f) (caddr f) ext)
              (format #f "; the optimum is a FACE of dimension ≥ ~a (~a free, ~a interchangeable) but the plan sits on its EDGE (room ~,3e) — the alternatives are nominal, not available"
                      fd (cadr f) (caddr f) ext)))
        "")))

(define (certificate-summary)
  "One line a human or a report can read."
  (let ((c *last-certificate*))
    (cond
      ((eq? (assq-ref c 'kind) 'federated)
       (format #f "federated over ~a scopes: ~a; CERTIFIED f(x) − f(x*) ≤ ~,3e [Σ local ~,3e + disagreement in hours ~,3e]~a"
               (assq-ref c 'scopes)
               (if (assq-ref c 'feasible?) "every scope locally feasible" "A SCOPE IS INFEASIBLE")
               (assq-ref c 'gap-bound) (assq-ref c 'local-bound)
               (assq-ref c 'disagreement-in-hours)
               (if (assq-ref c 'coupling-feasible?)
                   (if (eq? (assq-ref c 'bound-over) 'crossings-fixed)
                       "; RECONCILED — no scope draws on goods nobody is sending, so the plan is executable; the bound is against the best plan USING THESE CROSSINGS, not the best federated plan"
                       "; RECONCILED — no scope draws on goods nobody is sending, so the plan is executable")
                   (format #f "; overdraw ~,3e — near-optimal in VALUE, not yet consistent in quantity"
                           (or (assq-ref c 'overdraw) (assq-ref c 'consensus))))))
      ((not (assq-ref c 'feasible?))
       (format #f "INFEASIBLE — a limit is breached by ~,3e; this is not a plan"
               (- (or (assq-ref c 'min-slack) 0.0))))
      ((= (or (assq-ref c 'gap-bound) +inf.0) +inf.0)
       ;; …AND STILL SAY WHAT THE FACE IS. A face is the σ = 0 case — the
       ;; objective is flat along some direction — which is exactly when the
       ;; curvature branch gives no finite bound. Reporting the face only
       ;; alongside a finite bound therefore withheld it in the one situation it
       ;; describes: a free cycle came back as a bare "no bound provable", with
       ;; the dimension and the room already computed and dropped on the floor.
       (format #f "feasible; NO finite bound provable (unbounded feasible set or non-finite plan) — μ = ~,3e, ‖r‖ = ~,3e~a"
               (assq-ref c 'mu) (assq-ref c 'residual) (face-clause c)))
      (else
       (format #f "feasible; CERTIFIED f(x) − f(x*) ≤ ~,4e   [m·μ = ~,3e, ‖r‖·D = ~,3e]~a~a"
               (assq-ref c 'gap-bound)
               (* (assq-ref c 'm) (assq-ref c 'mu))
               (* (assq-ref c 'residual) (assq-ref c 'box-radius))
               (if (assq-ref c 'optimal?) "  [stationary]" "")
               (face-clause c))))))


;; ════════════════════════════════════════════════════════════════════════════
;; §4 — DIALS: every tunable, in one place
;; policy, not mechanism. Path schedule (tmin/sigma/newton caps),
;; preconditioner choice, regularizer, inner tolerances, PD and OSQP
;; fallback gates, and the backend selector. Each dial names its
;; consumers beside it; a dial consumed across sections lives HERE,
;; because a knob defined in one backend's section and read in another
;; is how the phase-I/IC(0) defect stayed invisible.
;; ════════════════════════════════════════════════════════════════════════════
(define *kern-omp* (and (getenv "PLANNER_OMP") #t))  ; OpenMP-parallel Jacobi-CG (multicore)
(define *kern-ridge* 1e-7)
(define *kern-precond* 'ic0)            ; 'direct (sparse-skeleton Cholesky + CG) | 'ic0 | 'ic0w | 'ssor | 'jacobi
(define *kern-dense-thr* 24)            ; rows with nnz > this are DENSE (hub goods / per-cell caps)
;; AUTO preconditioner: a sector-rich I-O has dense HUB rows whose a·aᵀ wreck the
;; IC(0) factor's FILL (Σ nnz² over hubs). When that fill is large, switch to the
;; matrix-free *jacobi* CG (zero fill — the hubs cost nothing in a matvec, and CG's
;; Krylov subspace absorbs the few rank-1 hub spikes); otherwise keep IC(0) (low CG
;; on sparse production chains / located meshes). Measured: this makes the 176k-
;; activity 240-sector national solve in ~6 min, near-linear, where IC(0)/OSQP choke.
(define *kern-precond-auto* #t)
(define %precond-override (make-parameter #f))
(define %last-precond-mode #f)
(define %last-attempt-converged? #f)     ; did the ladder's last attempt exit by tolerance? — a retry for a STALLED step reads it          ; the preconditioner mode the last path-follower solve ENDED in ('jacobi-or-ssor when a factor was retired or never chosen)   ; a preconditioner named by the solve's own ladder for one attempt (solve-native-c's jacobi rung)
(define (auto-precond C)
  (if (not *kern-precond-auto*) *kern-precond*
      (let* ((nt (cnt C)) (ptr (cptr C)) (nnz (vector-ref ptr nt)) (df 0) (maxm 0))
        (do ((ti 0 (+ ti 1))) ((= ti nt))
          (let ((m (- (vector-ref ptr (+ ti 1)) (vector-ref ptr ti))))
            (set! maxm (max maxm m))
            (when (> m *kern-dense-thr*) (set! df (+ df (* m m))))))
        ;; TWO readings say "this program has hubs ic0w prices exactly": the
        ;; aggregate fill df against the matvec work, and a single HUB ROW
        ;; past 4× the density threshold — one communal stock drawn by every
        ;; mouth. The hub reading carries the weight: measured on the festival
        ;; fixture (floors-only, one shared seed stock, maxrow ≈ N), forced
        ;; ic0w beats the plain-ic0 default at EVERY population with the hub
        ;; standing — 23s→13s at N=100 (df/nnz 3.8), 66s→28s at N=200,
        ;; 195s→42s at N=400, 355s→58s at N=500, 1067s→141s at N=600, and at
        ;; N=800 plain ic0 finishes no solve in 1800s — while the df ratio
        ;; alone crosses 30 only at N≈900. A hub-free program (household-week:
        ;; maxrow 6, df 0) keeps the default, and the measured first-step
        ;; probe retires a factor the KKT system votes down either way. The
        ;; DOWNSIDE is bounded by a synthetic: 2048 columns, one hub row swept
        ;; from width 16 to 512 with no crowd beside it — ic0 and ic0w land
        ;; within noise of each other at every width, so firing on a hub costs
        ;; nothing where the crowd is absent and the hub alone is benign.
        (let ((hubs? (or (> df (* 30 (max 1 nnz)))
                         (> maxm (* 4 *kern-dense-thr*)))))
          (when (getenv "PLANNER_PRECOND_DEBUG")
            (format (current-error-port) "  [auto-precond] nt=~a nnz=~a maxrow=~a df=~a thresh=~a → ~a~%"
                    nt nnz maxm df (* 30 (max 1 nnz)) (if hubs? 'ic0w *kern-precond*)))
          (if hubs? 'ic0w *kern-precond*)))))
(define *kern-rcm* #t)                  ; fill-reducing RCM ordering for the 'direct factor (skeleton)
(define *kern-maxdeg* 32)               ; forms with degree > this (dense local-resource caps, e.g.
                                        ; labour) stay OUT of the factor → near-linear fill; CG (over
                                        ; the full H) absorbs their few rank-1 terms. 0 ⇒ full factor.
;; ── central-path schedule ────────────────────────────────────────────────────
;; Path-following: walk t from tstart down to *kern-tmin* by t ← σ·t, re-centring
;; each level with tight-tolerance Newton (‖g‖ < max(1e-6, τ·t); τ=0 ⇒ 1e-6
;; everywhere) BUT capping intermediate Newton iterations low. The lever that
;; works is the iteration CAP, not σ or τ: a level converges to ‖g‖<1e-6 in <8
;; Newton steps when the geometry is benign, so an intermediate cap never bites
;; there; where it does bite is a level we are about to abandon anyway — capping
;; it stops the solver POLISHING slop the next level immediately corrects.
;; Measured (native-c, IC(0)-PCG): the three benign located scenarios already
;; centre each level in <8 Newton steps, so the cap never binds there (met
;; identical, Newtons unchanged); the lever only bites the degenerate spatially-
;; coupled case, where mid 24/final 80 trims 280→224 Newtons while holding met
;; at 96.84% (baseline 96.91%). That optimum is FLAT and the met is path-noise
;; (95.7–96.9% across caps, NON-monotone; running to convergence took 1600
;; Newtons and landed no better) — so the deep cut (mid 8 → 128 Newtons) is
;; available but costs ~1% met, and the real fix for that case is OSQP/warm-start
;; (below), not the schedule. A "long-step" variant (small σ + loose centring τ) was
;; measured FRAGILE on this primal barrier: pulling σ/τ instead of the iteration
;; count gives poor Newton directions and line-search damping, raising step count
;; on small problems even as it falls on large. The cost on hard spatial coupling
;; is Newton-bound, NOT CG-bound (CG/Newton ≈ 14 under IC(0)); its real fix is a
;; demand-aware spatial warm start / OSQP fallback (see ingest-located!), not the
;; schedule. Caps stay exposed knobs for the federated/large-block case.
(define *kern-sigma* 0.5)               ; path contraction t ← σ·t
(define *kern-tmin*  0.005)             ; the path floor IN FORCE — derived per solve when *target-gap* is set (see sync-kern-tmin!)
;; ONE constant, not four. The C kernel walks t down to a floor and stops; that
;; floor was a literal 0.02 inside pk_solve, twice more inside solve-native-core,
;; and *kern-tmin* here — so setting this moved nothing, and the knob read as live
;; while being inert. Scheme is authoritative now; every entry point that can
;; reach the C path syncs first.
;;
;; The floor is NOT an implementation detail. The barrier left standing at it is
;; felt in the plan: against a non-binding wall the residual +t/x gradient is held
;; off only by the free-time thrift κ·ℓ, so an activity settles near 2t/(κℓ) ABOVE
;; its demand instead of at it. Spread over a whole economy that is not a rounding
;; error — at 0.02 a 240-sector I-O fixture ran 87% of its activities inflated,
;; total activity 2.15× and labour 1.6× what the same delivered demand needs.
;;
;; 0.02 → 0.005 measured on that fixture (module/playnet/bench/bench-io.scm):
;;     4×4 grid,  6 976 activities:  4.84s → 5.38s  (+11%),  labour −28.6%
;;     9×8 grid, 35 664 activities: 38.33s → 45.65s (+19%),  labour −25.8%
;; met% is unchanged (99.98) in both — same delivery, a quarter less labour, and
;; the cost does not worsen with scale (Newton steps grow with path length, not n).
;; Tighter still keeps paying (0.001 ⇒ labour −37.5%) but at +45% time; 0.005 takes
;; nearly all the saving for a tenth of the cost. Raise it only with a benchmark.
;; Regression: tests/solve/test-centering-floor.scm.
;;
;; …AND A FIXED FLOOR IS THE WRONG SHAPE, because the error it leaves grows with
;; the program while the number does not. Every barrier standing at t pushes the
;; activity it bounds outward, so the residue on one activity grows with the
;; number of columns pressing on it. Measured on one 0.3 h task wanted ONCE,
;; against rosters of people who could all do it, at the fixed floor 0.005:
;;
;;     roster    1      3      10      30      60
;;     runs   2.17   3.28    7.13   18.19   34.88     ← demand is 1
;;
;; A commons plans proportionally more waste the more members it has, which is
;; exactly backwards, and no per-activity constant can fix it.
;;
;; What IS constant across programs is the GUARANTEE. At the floor the duality
;; gap is bounded by m·t (`plan-certificate`), so deriving t = g/m holds the
;; certified suboptimality at g whatever the program's size — the certificate
;; then reports the same promise for a household and for a national table,
;; instead of one that quietly degrades. The same measurement at g = 0.005:
;;
;;     roster    1      3      10      30      60
;;     runs   1.00   1.00    1.00    1.00    1.00     ← +25–40% solve time
;;
;; So `*target-gap*` is the knob and `*kern-tmin*` is derived from it per solve.
;; The number 0.005 is unchanged; what it MEANS is now the promise rather than
;; the mechanism. Set `*target-gap*` to #f to pin the floor by hand (which is
;; what test-centering-floor does, since it exists to measure the floor itself).
;; …AND THE PREMISE HAS A LIMIT, which the federated certificate found.
;; "The gap at the floor is bounded by m·t" is only HALF of what
;; `plan-certificate` proves. The whole bound is
;;
;;     f(x) − f(x*)  ≤  m·t  +  min( ‖r‖·D ,  ‖r‖²/(2σ) )
;;                      └ gap ┘   └ geometry ┘  └ curvature ┘
;;
;; and σ — the strong-convexity modulus, a min of t/s² — is itself proportional
;; to t. So the curvature branch goes as 1/t, and driving t down to hold m·t at
;; g does not hold the CERTIFIED gap at g: it holds one summand at g while the
;; other grows by the same factor.
;;
;; Which summand decides is STRUCTURAL, and it is the same fact either way.
;; Where the feasible box is bounded, D is finite, the geometry branch is live
;; and independent of t, the derivation's premise holds exactly, and tightening
;; t is pure gain — that is the ordinary program, and the roster measurement
;; above. Where some column is unbounded, D is honestly +inf, the whole bound
;; rests on curvature, and t is not a cost to be minimised but the thing that
;; BUYS the bound.
;;
;; A federated scope is precisely the second case: its import column is a free
;; source and nothing in that scope's own matrix bounds it (see the geometry/
;; curvature note in `plan-certificate`). Deriving the floor there moved a
;; 16-scope chain's certified bound from 3.90 to 328 — 15% of its objective to
;; 1268% — while the star, whose box is partly bounded, went 0.39 → 2.40.
;;
;; So the derivation is licensed by the same fact that licenses the branch it
;; assumes: derive the floor from the guarantee where the guarantee IS m·t;
;; where the bound rests on curvature, leave the floor at the shipped default,
;; because there the gap term is not what the certificate is made of. Both
;; directions are held — tests/solve/test-centering-floor.scm §6 and
;; tests/solve/test-federated-certificate.scm.
(define *target-gap* 0.005)             ; certified duality-gap target ⇒ t = g/m; #f ⇒ the floor is the caller's to set
(define *kern-tmin-default* 0.005)      ; the floor where no derivation is licensed (the shipped constant)
(define *kern-tmin-min* 1e-7)           ; numerical rail on the derived t, whatever m says

(define (forms-box-bounded? forms)
  "`box-bounded?` on a program still in form-list shape. The width is the widest
   column any row mentions — the same n `build-located` hands the solve."
  (let ((n (fold (lambda (f a) (fold (lambda (c b) (max b (+ 1 (car c)))) a (f-coeffs (form-body f))))
                 0 forms)))
    (or (= n 0) (box-bounded? (flatten forms) n))))

(define (tmin-for forms)
  "The floor this program should stop at: the one holding its certified gap at
   *target-gap*. m is counted exactly as `plan-certificate` counts it, so the
   bound it reports really is the target. With no target, the floor in force
   stands — turning the target off is taking manual control of it. With an
   UNBOUNDED column the gap term is not what the bound is made of, so there is
   nothing to derive it from and the shipped default stands."
  (cond ((not *target-gap*) *kern-tmin*)
        ((not (forms-box-bounded? forms)) *kern-tmin-default*)
        (else
         (let ((m (count (lambda (f) (eq? (f-kind (form-body f)) 'bar)) forms)))
           (if (<= m 0) *kern-tmin*
               (max *kern-tmin-min* (/ *target-gap* m)))))))
;; Deriving the floor and pushing it into C are ONE act, so they are one
;; procedure: a derivation that some entry point forgets to sync is a floor the
;; Scheme believes and the kernel does not, which is the shape of the bug this
;; file already carries a paragraph about (`*kern-tmin*`, single-sourcing).
;;
;; Called WITH the program at each public entry, which derives; called BARE
;; where the floor is already settled — phase-I re-enters the core with an
;; AUGMENTED program carrying one slack per hard form, whose m is not this
;; program's m and must not set this program's floor.
;;
;; `*kern-tmin*` is therefore the floor IN FORCE, not a preference: with a
;; target set it is derived per solve and is better read as an output. A caller
;; who wants to pin it turns `*target-gap*` off and sets it, which is what
;; tests/solve/test-centering-floor.scm does — it exists to measure the floor.
(define* (sync-kern-dials! #:optional forms)
  (when forms (set! *kern-tmin* (tmin-for forms)))
  (false-if-exception (k-set-tmin (exact->inexact *kern-tmin*)))
  ;; …and the path dials ride with it, so pk_solve — the federated batch
  ;; core — walks the same contraction and Newton-cap split the dial-driven
  ;; core walks. The FINAL tolerance stays the batch calibration, 1e-6
  ;; absolute: the ADMM bound is measured against a fixed stationarity per
  ;; round, and the gscale-relative final tolerance balloons on early prox
  ;; rounds (gradients carry the prox centres) — pushed through once, it
  ;; failed 3 of the federated certificate's 41 checks and the bound's
  ;; monotonicity in S, with sigma, the caps and tau each clean alone.
  (false-if-exception
   (k-set-schedule (exact->inexact *kern-sigma*) *kern-newton-mid* *kern-newton-final*
                   1e-6 0.0
                   (exact->inexact *kern-inner-tau*))))
(define sync-kern-tmin! sync-kern-dials!)   ; the floor's own name, kept at every call site

(define (call-at-settled-floor thunk)
  "Run THUNK with the path floor left exactly where it stands.

   A public entry derives its floor from the program it is handed, which is
   right for a program being solved on its own terms and wrong for a re-solve
   that POLISHES a plan somebody else produced. The federated refinement
   re-enters a scope's program at the converged prices to drive its residual
   down; a floor derived there is not the floor the plan it is polishing was
   made at, and solving the polish harder than the thing being polished is how
   the refined plan walks away from the agreement it exists to preserve.
   Measured on a 16-star: consensus 8.0e-5 → 80.8, overdraw 7.2e-6 → 7.2, and
   the gate rightly refused a refinement that used to be worth taking.

   The same principle the BARE `sync-kern-tmin!` call in phase-I rests on: a
   re-entry inherits the floor, it does not reset it."
  (let ((saved *target-gap*))
    (dynamic-wind (lambda () (set! *target-gap* #f))
                  thunk
                  (lambda () (set! *target-gap* saved)))))
(define *kern-inner-tau* 0.0)           ; inner tol = max(1e-6, τ·t); τ=0 ⇒ tight everywhere (robust)
(define *kern-newton-mid*   24)         ; Newton cap per intermediate level (benign levels need <8)
(define *kern-newton-final* 80)         ; Newton cap at the final level (polish hard only here)
(define *kern-cgcap* (and=> (getenv "PLANNER_CGCAP") string->number))
;; max PCG iterations per Newton solve. #f (the default) derives it: CG solves an
;; n-dimensional SPD system EXACTLY within n steps in exact arithmetic, so n+2 (a
;; small margin for round-off) is CG's own bound, not a tuned number. A FIXED
;; ceiling here was the *kern-tmin* mistake again, in a different place: 300 reads
;; as generous on the programs this was tuned against (n well under it, so n+2 was
;; always the binding clamp and 300 never fired), and silently becomes the
;; BINDING constraint, undercutting n+2, the moment a program crosses n=298 —
;; a federated festival program at a few hundred variables hit exactly this:
;; phase-I's own inner solve (the one place CG runs unpreconditioned, see the
;; Jacobi-forcing above) left its start 0.4 to 3+ units exterior, orders above
;; the ~1e-6 noise a converged phase-I leaves, because its own CG budget ran out
;; before its own KKT point — the symptom the comment on `augment-phase1` already
;; names: "the only thing worse than [phase-I not converging] is it happening
;; quietly." Measured: N=100 and N=300 (897 and 2497 variables, both already past
;; 298) converge fine regardless, so this was never about SIZE outrunning a
;; threshold — it is that SOME instance's own conditioning needs more than 300
;; CG steps, and nothing before this derived one ever said so. PLANNER_CGCAP
;; still overrides for a deliberate measurement — a caller's own number, same as
;; *kern-tmin*'s #f/explicit split — but the derived bound is never silently less
;; than what the problem's own dimension already proves is enough.
;; Gradient regularization (Doikov–Nesterov 2021 / Mishchenko 2021): solve the
;; REGULARIZED Newton system (H + λI)d = −g with λ = √(Ĥ·‖g‖/3) ≈ c·√‖g‖ instead
;; of a fixed Tikhonov floor. λ → 0 as ‖g‖ → 0, so it recovers exact (fast-local)
;; Newton at the centre while taming the FLAT/degenerate optimum far out, where a
;; near-singular H gives a wild Newton direction the line search can only damp.
;; This is the matrix-free cure for the spatially-coupled stall (the OSQP fallback's
;; raison d'être) — it costs nothing extra: λ is just the scalar already threaded
;; into Hv / the Jacobi diag / the IC(0) factor. *kern-greg*=0 ⇒ exact old behaviour.
;; λ = max(ridge, √(Ĥ·‖g‖)) with Ĥ a running Hessian-Lipschitz estimate, self-tuned
;; by the line search: a full step (η=1) succeeded ⇒ over-regularized, halve Ĥ; a
;; damped step ⇒ under-regularized, double Ĥ (Doikov's adaptive rule, with our
;; backtracking line search as the acceptance test). Ĥ floors at *kern-hmin* so λ
;; decays to the ridge on benign levels (no bias), and λ→0 as ‖g‖→0 at the optimum.
(define *kern-greg* 0.01)                ; initial Ĥ; 0 ⇒ fixed ridge (exact baseline, adaptation inert)
(define *kern-hmin* 1e-4)                ; floor on the Ĥ estimate
;; Gap-based early stop: at t_min the duality gap is m·t_min REGARDLESS of how
;; tightly we centre. The barrier keeps moving the iterate toward the analytic
;; centre even after the PLAN is done, so the objective never plateaus — but the
;; DELIVERED DEMAND does. Once met stops improving at t_min we are on the
;; (possibly flat/degenerate) optimum, certified by the gap — stop. This kills the
;; hundreds-of-Newton grind where ‖g‖ never reaches 1e-6 but met is already maxed.
;; MET-PLATEAU EARLY EXIT — OFF by default, and the measurement is why.
;; It stops the final centring level once delivered demand stops rising. That
;; sounds thrifty and is a very bad trade: on a located program it saved NINE
;; Newton steps out of 163 (5.5%) and cost FOUR ORDERS OF MAGNITUDE of
;; stationarity — ‖∇‖/(1+‖∇f‖) of 1.1e-1 where running on reaches 9.8e-6. Demand
;; met is not the objective; harmony is, and a plan can deliver every unit asked
;; of it while wasting labour on the way (measured elsewhere this session at 2.15×
;; the activity needed). The exit also used to return conv? = #t, so nothing
;; downstream could see the trade being made.
;; Set to a positive value to re-enable, knowing what it buys.
(define *kern-mettol* 0.0)               ; min delivered-demand gain per step at t_min (0 ⇒ off)
(define (greg-lambda gn Hreg) (if (> *kern-greg* 0.0) (max *kern-ridge* (sqrt (* Hreg gn))) *kern-ridge*))
;; INNER TOLERANCE — RELATIVE to the gradient scale, not an absolute number.
;;
;; It was a flat 1e-6 on ‖∇‖, which asks a different question of every program.
;; Measured at the final level with the honest convergence flag:
;;   space τ=0.04 : ‖∇f‖ 24.3  → gn 2.5e-4 absolute, 9.8e-6 RELATIVE → reported
;;                  NOT converged, though its certified bound is 0.023% of |f|
;;   time         : ‖∇f‖ 0.038 → gn 9.7e-7 absolute → reported converged, on a
;;                  solve of the same relative quality
;; The verdict tracked the objective's magnitude rather than the solve. Since
;; conv? gates the greg retry, the fallback ordering and the optimality claim,
;; a scale-blind test mis-gates all three on any program with large weights.
;;
;; `scale` is (1 + ‖∇f‖) captured once per solve at the final level. 1e-5 relative
;; is the threshold that separates the three fixtures correctly: the well-posed
;; ones pass, the genuinely degenerate one (gn/‖∇f‖ = 0.94) still fails.
(define *kern-inner-rel* 1e-5)          ; gn < rel·(1+‖∇f‖) at the final level
(define *kern-inner-abs* 1e-9)          ; …but never demand less than this
(define* (inner-tol t #:optional (scale 1.0))
  (if (<= t (* 1.0001 *kern-tmin*))
      (max *kern-inner-abs* (* *kern-inner-rel* scale))
      (max 1e-6 (* *kern-inner-tau* t))))
;; ── OSQP fallback on a native-c STALL ────────────────────────────────────────
;; The interior-point Newton converges in ~19 steps on well-conditioned worlds,
;; but a small HARD-SPATIALLY-COUPLED case can have a flat/degenerate optimum the
;; matrix-free PCG path wanders (final central-path level exhausts its Newton cap
;; without reaching ‖g‖<1e-6 — the 5th return value conv?=#f). OSQP's sparse
;; DIRECT factorization solves exactly such a QP cleanly and lands at a better
;; delivered-demand fraction (parity data: space-cheap native .969 vs osqp .974).
;; So: native-c stays the fast default; only when it stalls do we pay one OSQP
;; re-solve (warm-started from the stalled point) and keep whichever delivers more
;; demand — a guaranteed no-regression. Gated OFF for huge problems (OSQP would
;; double the cost) and for 'qc/EMP forms (OSQP's diagonal-P path can't take them).
(define *osqp-fallback* #t)             ; auto OSQP re-solve when native-c stalls
(define *osqp-fallback-maxvar* 50000)   ; skip the re-solve above this many activities
;; conv? from the core means "centred to ‖g‖<1e-6 at t_min". A FLAT/degenerate
;; optimum (many activities give the same delivered demand) never drives ‖g‖ that
;; low even though the plan is already complete and certified to the gap m·t_min —
;; so conv?=#f over-fires the fallback on solves that are in fact done. OSQP can
;; only ever IMPROVE the delivered fraction, so when native already delivers
;; essentially all demand there is nothing to gain: skip the re-solve. The genuine
;; under-delivering stall (e.g. space-cheap .969) is below the floor and still pays
;; the fallback, keeping the no-regression guarantee where it actually matters.
(define *osqp-fallback-metfloor* 0.999) ; native delivers ≥ this ⇒ optimal-to-gap, no OSQP

(define (call-with-greg c thunk)
  "Run THUNK with the gradient regularizer set to C, restoring it after."
  (let ((saved *kern-greg*))
    (dynamic-wind (lambda () (set! *kern-greg* c))
                  thunk
                  (lambda () (set! *kern-greg* saved)))))

(define *kern-pd-tol* 1e-6)      ; stop when duality gap μ = sᵀy/m < this (stall-detector backs it up)
(define *kern-pd-maxit* 80)
(define *osqp-eps* 1e-6)   ; ADMM tolerance (abs=rel). Tight enough that an OSQP

(define *backend* (cond-expand (guile 'auto) (else 'native)))   ; no kernel under Hoot: the reference core

;; ── the dials a CALLER may assign, and why each has a setter ────────────────
;; Six of the knobs above are set from outside this file — `(set! *backend*
;; 'native)` and friends, at 19 sites across the benches, the studies and
;; plan-scope. That idiom keeps working through an import, but ONLY while this
;; module also assigns the variable somewhere. A module that never writes its
;; own global lets the compiler resolve reads of it directly; an importer's
;; set! then writes a box nothing reads, and the module goes on seeing the old
;; value. Interpreted it is fine, compiled it silently diverges, and Guile says
;; nothing either way — so under --no-auto-compile, which is how every test
;; runs, the bug would be invisible until the day something built a .go.
;;
;; These setters are the fix and the documentation at once: they keep the
;; variable boxed, and they name this module's mutable surface.
;; A caller names the backend it wants; the browser build has one, the reference
;; core, so under Hoot every name resolves to it here and nowhere else.
(define (set-backend! b)          (set! *backend* (cond-expand (guile b) (else 'native))))
(define (set-kappa! x)            (set! *kappa* x))
(define (set-kern-mettol! x)      (set! *kern-mettol* x))
(define (set-kern-newton-final! n) (set! *kern-newton-final* n))
(define (set-kern-precond-auto! b) (set! *kern-precond-auto* b))
(define (set-osqp-fallback! b)    (set! *osqp-fallback* b))

;; ════════════════════════════════════════════════════════════════════════════
;; §5 — CORE, reference: matrix-free interior-point Newton-PCG (Scheme)
;; the readable implementation the C kernel is checked against.
;; ════════════════════════════════════════════════════════════════════════════
(define (pcg C cv b diag n)                 ; diagonal-preconditioned CG: solve H x = b
  (let* ((x (make-vector n 0.0)) (r (vcopy b))
         (z (let ((v (make-vector n))) (do ((i 0 (+ i 1))) ((= i n) v) (vector-set! v i (/ (vector-ref r i) (vector-ref diag i))))))
         (p (vcopy z)) (its 0)
         ;; the SAME derived bound the native kernel's cap uses (*kern-cgcap*, above):
         ;; n+2 by default, a caller's own number still sanity-clamped at it. One
         ;; knob, not two numbers that can drift — this is the reference core the
         ;; C kernel is checked against, and under Hoot (no native kernel) it is
         ;; the solve, not a fallback.
         (cap (let ((derived (+ n 2))) (if *kern-cgcap* (min *kern-cgcap* derived) derived))))
    (let loop ((k 0) (rz (vdot r z)))
      (if (or (>= k cap) (< (vdot r r) 1e-14)) (values x its)
          (let* ((Hp (csr-hv C cv p n)) (al (/ rz (max 1e-30 (vdot p Hp)))))
            (set! its (+ its 1))
            (do ((i 0 (+ i 1))) ((= i n))
              (vector-set! x i (+ (vector-ref x i) (* al (vector-ref p i))))
              (vector-set! r i (- (vector-ref r i) (* al (vector-ref Hp i)))))
            (let* ((z2 (let ((v (make-vector n))) (do ((i 0 (+ i 1))) ((= i n) v) (vector-set! v i (/ (vector-ref r i) (vector-ref diag i))))))
                   (rz2 (vdot r z2)))
              (do ((i 0 (+ i 1))) ((= i n)) (vector-set! p i (+ (vector-ref z2 i) (* (/ rz2 rz) (vector-ref p i)))))
              (loop (+ k 1) rz2)))))))
;; interior-point Newton along the central path → (values x t cgtot ntot)
;; CORE: assumes x0 is strictly bar-feasible (ensure-feasible/phase-I guarantees it).
;; ── flat vectors ⇄ byte buffers ─────────────────────────────────────────────
;; Plain bytevector arithmetic, so every build has them: the compiled kernel reads
;; the buffers in place, and the per-scope records of the federated solve
;; (engine.scm, admm-kernel-rec) keep their state in them under either core.
(define (vec->f64 v) (let* ((n (vector-length v)) (bv (make-bytevector (* 8 (max 1 n))))) (do ((i 0 (+ i 1))) ((= i n) bv) (bytevector-ieee-double-native-set! bv (* 8 i) (exact->inexact (vector-ref v i))))))
(define (vec->i32 v) (let* ((n (vector-length v)) (bv (make-bytevector (* 4 (max 1 n))))) (do ((i 0 (+ i 1))) ((= i n) bv) (bytevector-s32-native-set! bv (* 4 i) (vector-ref v i)))))
(define (f64bv->vec bv n) (let ((v (make-vector n))) (do ((i 0 (+ i 1))) ((= i n) v) (vector-set! v i (bytevector-ieee-double-native-ref bv (* 8 i))))))
(define (i32bv->vec bv n) (let ((v (make-vector n))) (do ((i 0 (+ i 1))) ((= i n) v) (vector-set! v i (bytevector-s32-native-ref bv (* 4 i))))))
;; The reference path-follower over an ALREADY FLATTENED program. A scope of the
;; federated solve holds its program flat (direct-CSR) and re-solves it every round
;; with only the prox centres changed, so it enters here and skips `flatten`.
(define* (solve-flat C labform x0 #:optional (tstart 1.0))
  ;; The reference core walks the dial-driven path the compiled core walks —
  ;; σ = *kern-sigma*, the mid/final Newton-cap split against the floor — at
  ;; the BATCH tolerance, max(1e-6, τ·t) absolute at every level: pk_solve
  ;; reads the same values through sync-kern-dials!, the federated bound is
  ;; calibrated against that fixed stationarity, and the parity test
  ;; compares one schedule.
  (let* ((n (vector-length x0)) (cgtot 0) (ntot 0))
    (let path ((t tstart) (x x0))
      (let ((cap (if (<= t (* 1.0001 *kern-tmin*)) *kern-newton-final* *kern-newton-mid*)))
        (let newton ((it 0) (x x))
          (let* ((sv (term-values C x)) (g (csr-grad C labform t sv n)) (gn (sqrt (vdot g g))))
            (if (or (>= it cap) (< gn (max 1e-6 (* *kern-inner-tau* t))))
                (if (<= t *kern-tmin*) (values x t cgtot ntot) (path (max *kern-tmin* (* t *kern-sigma*)) x))
                (let ((cv (term-coeffs C t sv)))
                  (call-with-values (lambda () (pcg C cv (vneg g) (csr-diag C cv n) n))
                    (lambda (d its)
                      (set! cgtot (+ cgtot its)) (set! ntot (+ ntot 1))
                      (let ((f0 (obj-value C labform t x sv)))
                        (let ls ((eta (min 1.0 (frac-to-boundary C sv d n))))   ; never step a barrier slack to (near) zero
                          (let* ((y (let ((v (make-vector n))) (do ((i 0 (+ i 1))) ((= i n)) (vector-set! v i (+ (vector-ref x i) (* eta (vector-ref d i))))) v))
                                 (fy (obj-value C labform t y (term-values C y))))
                            (cond ((and (< fy 1e11) (< fy (- f0 1e-9))) (newton (+ it 1) y))
                                  ((< eta 1e-9) (if (<= t *kern-tmin*) (values x t cgtot ntot) (path (max *kern-tmin* (* t *kern-sigma*)) x)))
                                  (else (ls (* eta 0.5)))))))))))))))))
(define* (solve-native-core forms labform x0 #:optional (tstart 1.0))
  (solve-flat (flatten forms) labform x0 tstart))
(define* (solve-native forms labform x0 #:optional (tstart 1.0))
  (sync-kern-tmin! forms)                 ; the floor follows the guarantee, not a constant
  ;; Feasibility guard: fraction-to-the-boundary bounds the steps, but an ABSURDLY far start (≫ any cap)
  ;; can still exhaust the Newton budget and leave the iterate infeasible. Never return that silently —
  ;; retry once from a small strictly-interior start, then error if even that finds no feasible point.
  (let ((C (flatten forms)))
    (let retry ((x0 x0) (tries 0))
      ;; Decide feasibility FIRST. Phase-I already answers it; running the full
      ;; solve on a program proven to have no answer, then re-running the whole
      ;; sequence from another start, was doing the same impossibility proof
      ;; three times to reach a message that named no quantity. One confirming
      ;; pass from a tiny start is kept — phase-I can stop short — but the
      ;; expensive core solves are not.
      (call-with-values (lambda () (phase1-decide forms labform x0 solve-native-core))
        (lambda (x0f s*)
          ;; Confirmed once from a strictly-interior start, because phase-I can
          ;; stop short from a far one. Deliberately NOT keyed to `tries`: that
          ;; counter is about the CORE solve diverging, which is a different
          ;; failure, and threading one condition through both made each harder
          ;; to read than either.
          ;; judged AT THE PHASE-I POINT, never at the seed: program-scale reads
          ;; each form's throughput Σ|coeff·x|, so a far seed would inflate the
          ;; scale — and with it the tolerance — until genuine infeasibility read
          ;; as noise. The point whose feasibility is in question is the one to
          ;; measure the program at.
          (when (getenv "PLANNER_PD_DEBUG")
            (format (current-error-port) "  [phase-I] s*=~,3e scale=~,3e tol=~,3e n=~a~%" s* (program-scale C x0f) (* *infeas-tol* (program-scale C x0f)) (vector-length x0f)))
          (when (infeasible-by? C x0f s*)
            (call-with-values (lambda () (phase1-decide forms labform
                                                        (make-vector (vector-length x0) 0.05)
                                                        solve-native-core))
              (lambda (x2 s2)
                (when (getenv "PLANNER_PD_DEBUG")
                  (format (current-error-port) "  [phase-I] retry s*=~,3e scale=~,3e~%" s2 (program-scale C x2)))
                (when (infeasible-by? C x2 s2) (signal-infeasible! forms x2 s2)))))
          (call-with-values (lambda () (solve-native-core forms labform x0f tstart))
        (lambda (x . rest)
          ;; Only a GROSS infeasibility means the iterate diverged. A converged solve sits at slack ≥ 0
          ;; up to numerical noise on tight/binding constraints; a diverged one is off by orders of
          ;; magnitude. `plan-grossly-infeasible?` reads that gap RELATIVE to each constraint's own
          ;; throughput, so the same physical program admits the same plan whether its goods are
          ;; counted in kilograms or grams — and a stock overdrawn many times over is caught at every
          ;; scale, rather than passing as noise wherever the unit happens to make one absolute unit
          ;; of slack look small. (The scenario path has read it this way since solve/robust.scm:244.)
          (cond ((not (plan-grossly-infeasible? C x)) (apply values x rest))   ; feasible (incl. binding/noisy) ⇒ done
                ((= tries 0) (retry (make-vector (vector-length x0) 0.05) 1))            ; grossly infeasible (far-start stall) ⇒ retry from a tiny start
                (else (raise-starvation "solve-native: no strictly-feasible point (problem infeasible, or caps unsatisfiable)"))))))))))
(define* (solve-native/cert forms labform x0 #:optional (tstart 1.0))
  (call-with-values (lambda () (solve-native forms labform x0 tstart))
    (lambda (x t . _) (values x (plan-certificate forms t)))))

;; ════════════════════════════════════════════════════════════════════════════
;; §5b — CORE, compiled: same Newton-PCG, hot loops in C (libplanner_kernel)
;; identical algorithm and central-path schedule to §5; parity is
;; asserted bit-for-bit by test-tension-parity.scm.
;; ════════════════════════════════════════════════════════════════════════════

;; Identical algorithm and central-path schedule to §2; the O(nnz)-per-iteration
;; flops (term_values, term_coeffs, csr_grad/diag, obj_value, and the whole PCG
;; inner loop incl. matrix-free H·v) run in kernel.c over flat int32/f64 buffers.
;; Guile keeps the Newton outer loop, line search, and t-schedule — O(iterations),
;; cheap, and where the policy lives. This is the planner's production solver:
;; interior-point needs few iterations, and now each costs C speed, not interp.
(cond-expand
(guile
(define *kern-lib*
  (or (let ((p (getenv "PLANNER_KERNEL"))) (and p (false-if-exception (dynamic-link p))))
      (false-if-exception
        (dynamic-link (string-append
          (dirname (or (current-filename) (string-append (getcwd) "/module/playnet/solve/x")))
          "/kernel/libplanner_kernel")))))
;; ── is this object even runnable on this CPU? ───────────────────────────────
;; kernel.c is built -march=native, so the .so is tuned to whichever machine
;; compiled it. That is the right default — each checkout builds its own, and
;; the hot loops want every instruction the host has — but it makes the object
;; NON-PORTABLE in a way that fails horribly: dlopen succeeds (nothing is
;; executed), FFI binding succeeds, and then the first solve dies on an illegal
;; instruction. SIGILL through the FFI gives no message, no Scheme backtrace and
;; no hint that a copied .so is to blame.
;;
;; So the object declares what it needs (pk_required_isa, a plain string
;; constant — reading data executes nothing and is safe on any CPU) and the
;; loader checks it against the running machine before offering the backend.
;; Missing the symbol means a kernel built before this guard: nothing is claimed
;; and nothing is refused, which is the honest reading of silence.
;;
;; `make -C module/playnet/solve/kernel portable` drops -march=native and is
;; the build to use when one object must serve several machines.
(define (%cpu-flags)
  "The running CPU's feature flags as a list of strings, or #f where the
question cannot be asked (non-Linux, no procfs).

Read char by char rather than by line: `read-line` lives in (ice-9 rdelim),
which this file does not import, and the first version of this reached for it
inside `false-if-exception`. The unbound variable became #f, #f read as `no
answer`, and no answer was treated as `nothing to object to` — so the guard
passed a kernel built for AVX-512 on a machine without it, which is precisely
the case it exists to catch. A check whose failure mode is silent approval is
not a check, and the only reason this one was caught is that it was tested
against a deliberately wrong object rather than only against a right one."
  (let ((txt (false-if-exception
              (call-with-input-file "/proc/cpuinfo"
                (lambda (port)
                  (let loop ((acc '()))
                    (let ((c (read-char port)))
                      (if (eof-object? c)
                          (list->string (reverse acc))
                          (loop (cons c acc))))))))))
    (and (string? txt)
         (let loop ((lines (string-split txt #\newline)))
           (cond ((null? lines) #f)
                 ((string-prefix? "flags" (car lines))
                  (let ((c (string-index (car lines) #\:)))
                    (and c (string-tokenize (substring (car lines) (+ c 1))))))
                 (else (loop (cdr lines))))))))

(define *kern-isa-missing*
  ;; the features this object needs and this CPU lacks — '() when it can run
  (and *kern-lib*
       (let ((req (false-if-exception
                   (pointer->string (dynamic-pointer "pk_required_isa" *kern-lib*))))
             (have (%cpu-flags)))
         (if (and req have)
             (let loop ((r (string-tokenize req)) (miss '()))
               (cond ((null? r) (reverse miss))
                     ((member (car r) have) (loop (cdr r) miss))
                     (else (loop (cdr r) (cons (car r) miss)))))
             '()))))

(define (kern-isa-ok?) (or (not *kern-lib*) (null? *kern-isa-missing*)))

;; The kernel is used when it is linked AND enabled. Disabling it runs every path as
;; a build without one would (a browser): the reference core, one scope at a time.
;; That is how a test holds the two cores against the same program.
(define *kern-enabled* #t)
(define (set-kern-enabled! on?) (set! *kern-enabled* on?))
(define (kern-available?) (and *kern-enabled* *kern-lib* (kern-isa-ok?) #t))

;; a pure function of the missing features, so the sentence can be read in a
;; test on a machine that satisfies its own kernel — which every healthy
;; machine does, and which would otherwise leave this text unexercised
(define (kern-isa-refusal missing)
  (string-append
   "compiled backend unavailable: libplanner_kernel was built for a CPU this one is not. "
   "It needs " (string-join missing ", ")
   ", which this cpu does not have. A -march=native object belongs to the machine that "
   "compiled it: rebuild here with `make -C module/playnet/solve/kernel clean all`, or, "
   "for one object that runs on any x86-64 and still uses what it finds, "
   "`make -C module/playnet/solve/kernel agnostic`."))

(define (kern-unavailable-reason)
  "Why the compiled backend is not on offer, in terms someone can act on."
  (cond ((not *kern-lib*)
         "compiled backend unavailable: libplanner_kernel not found (make -C module/playnet/solve/kernel, or set PLANNER_KERNEL)")
        ((not (null? *kern-isa-missing*)) (kern-isa-refusal *kern-isa-missing*))
        (else "compiled backend unavailable")))
(define (kfn name ret args) (and *kern-lib* (pointer->procedure ret (dynamic-func name *kern-lib*) args)))
(define k-tvals (kfn "pk_term_values" void (list int '* '* '* '* '* '*)))
(define k-tcoef (kfn "pk_term_coeffs" void (list int '* '* '* double '* '*)))
(define k-grad  (kfn "pk_csr_grad"   void (list int int '* '* '* '* '* '* double '* '*)))
(define k-diag  (kfn "pk_csr_diag"   void (list int int '* '* '* '* double '*)))
(define k-obj   (kfn "pk_obj_value"  double (list int '* '* '* double '*)))
(define k-pcg   (kfn "pk_pcg"        int (list int int '* '* '* '* '* '* double int '* '* '* '* '*)))
(define k-dot   (kfn "pk_dot"        double (list int '* '* )))
(define k-axpy  (kfn "pk_axpy"       void (list int '* double '* '*)))
(define k-ic0sym  (kfn "pk_ic0_symbolic" '* (list int int '* '*)))
(define k-ic0fac  (kfn "pk_ic0_factor"   void (list '* int '* '* '* '* double)))
(define k-ic0free (kfn "pk_ic0_free"     void (list '*)))
(define k-pcgic0  (kfn "pk_pcg_ic0"      int (list '* int int '* '* '* '* '* double int '* '* '* '* '*)))
(define k-ic0wsym (kfn "pk_ic0w_symbolic" '*  (list int int '* '* int)))                 ; IC(0)+Woodbury (dense hub rows)
(define k-ic0wfac (kfn "pk_ic0w_factor"   void (list '* int '* '* '* '* double int)))
(define k-ic0wfree(kfn "pk_ic0w_free"     void (list '*)))
(define k-pcgic0w (kfn "pk_pcg_ic0w"      int (list '* int int '* '* '* '* '* double int '* '* '* '* '*)))
(define k-cholsym  (kfn "pk_chol_symbolic" '* (list int int '* '* int int)))
(define k-cholfac  (kfn "pk_chol_factor"   int (list '* int '* '* '* '* double)))
(define k-cholsolve (kfn "pk_chol_solve"   void (list '* '* '*)))
(define k-cholfree (kfn "pk_chol_free"     void (list '*)))
(define k-chollnnz (kfn "pk_chol_lnnz"     long (list '*)))
(define k-pcgchol  (kfn "pk_pcg_chol"      int (list '* int int '* '* '* '* '* double int '* '* '* '* '*)))
(define k-buildcsc (kfn "pk_build_csc"     void (list int int '* '* '* '* '* '*)))
(define k-pcgssor (kfn "pk_pcg_ssor"      int (list int int '* '* '* '* '* '* '* '* '* double int '* '* '* '* '* '* '*)))  ; matrix-free SSOR
(define k-solvepd (kfn "pk_solve_pd"      int (list int int int '* '* '* '* '* '* '* '* '* double double double int int '* '* '*)))  ; Mehrotra primal-dual; last two '* = mu out, y out
;; the same solve with the sparse Cholesky of the normal equations as CG's
;; preconditioner (pk_chol_symbolic once per program; maxdeg keeps the dense
;; first-stage columns out of the factor — a two-stage program's blocks
;; factor, its coupling rides in CG). PLANNER_PD_CHOL=1 selects it.
(define k-solvepdchol (kfn "pk_solve_pd_chol" int (list '* int int int '* '* '* '* '* '* '* '* '* double double double int '* '* '*)))
(define k-cholcolmax (kfn "pk_chol_colmax" void (list int)))   ; border columns (degree > colmax) stay out of the factor
(define k-pcgomp   (kfn "pk_pcg_omp"       int (list int int '* '* '* '* '* '* '* '* '* double int '* '* '* '* '* '*)))
(define k-ompthreads (kfn "pk_omp_threads" int '()))
(define k-solvemany (kfn "pk_solve_many"  int   ; §10 federated: N scope solves, omp over scopes
  (list int '* '* '* '* '* '* '* '* '* '* '* '* double double double '* '*)))
(define k-meanfill  (kfn "pk_meanfill"    double (list int '* '* '* '* '* '* '*)))
(define k-set-tmin  (kfn "pk_set_tmin"    void   (list double)))   ; single-source the path floor into C
(define k-set-schedule (kfn "pk_set_schedule" void (list double int int double double double)))   ; …and the rest of the schedule: sigma, mid/final caps, inner abs/rel/tau
;; Compiled-cache canary. Guile keys its .go cache by version and ABI, and two
;; BUILDS of 3.0.11 share that key: guile-next's compiler inlines bytevector
;; allocation, and a .go it wrote hands the host guile's runtime buffers it
;; reads as immutable — so every native solve dies in vec->i32 with "expecting
;; mutable bytevector". (Measured: of the four build × build pairs only host-
;; loads-next fails.) tools/test/own-ccache.sh keeps each build on its own cache;
;; a hand-run `guile tests/….scm` under guile-next, with auto-compile on, is
;; what writes the shared one. The check runs once at load and names the
;; condition where it starts.
(let ((bv (make-bytevector 4)))
  (catch 'wrong-type-arg
    (lambda () (bytevector-s32-native-set! bv 0 1))
    (lambda _
      (error "(playnet solve solver) was loaded from a .go compiled by a different Guile build — run through tools/test/own-ccache.sh, or clear it with tools/test/stale-go-sweep.sh / rm -rf ~/.cache/guile/ccache"))))

(define (bvp p) (bytevector->pointer p))   ; bytevector → C pointer (≠ §3's list-packing f64*)
;; CORE: assumes x0 strictly bar-feasible (the §2b compiled barrier loop).
(define* (solve-native-c-core forms labform x0 #:optional (tstart 1.0))
  (sync-kern-tmin!)                       ; every C entry point syncs the path floor
  (unless (kern-available?) (error (kern-unavailable-reason)))
  (let* ((C (flatten forms)) (pc     (let ((e (getenv "PLANNER_PRECOND")))     ; the operator's word wins: direct | ic0 | ic0w | ssor | jacobi
                   (cond ((and e (member e '("direct" "ic0" "ic0w" "ssor" "jacobi"))) (string->symbol e))
                         ((%precond-override) => identity)                      ; a ladder rung's word (below): the same door
                         (else (auto-precond C))))) (nt (cnt C)) (n (vector-length x0)) (cgtot 0) (ntot 0)
         (ptr (vec->i32 (cptr C))) (idx (vec->i32 (cidx C))) (val (vec->f64 (cval C)))
         (kind (vec->i32 (ckind C))) (cnst (vec->f64 (cconst C))) (Dv (vec->f64 (cD C))) (wv (vec->f64 (cw C)))
         (pptr (bvp ptr)) (pidx (bvp idx)) (pval (bvp val)) (pkind (bvp kind))
         (pcnst (bvp cnst)) (pD (bvp Dv)) (pw (bvp wv))
         (x (vec->f64 x0)) (px (bvp x))
         (sv (make-bytevector (* 8 (max 1 nt)))) (psv (bvp sv))
         (cv (make-bytevector (* 8 (max 1 nt)))) (pcv (bvp cv))
         (g (make-bytevector (* 8 n)))   (pg (bvp g))
         (b (make-bytevector (* 8 n)))   (pb (bvp b))
         (zero (make-bytevector (* 8 n))) (pzero (bvp zero))
         (diag (make-bytevector (* 8 n))) (pdiag (bvp diag))
         (d (make-bytevector (* 8 n)))   (pd (bvp d))
         (y (make-bytevector (* 8 n)))   (py (bvp y))
         (r (make-bytevector (* 8 n)))   (z (make-bytevector (* 8 n)))
         (p (make-bytevector (* 8 n)))   (hp (make-bytevector (* 8 n)))
         ;; CSC transpose + cd scratch for the OpenMP Jacobi-CG (§2d) AND the SSOR sweep
         (nnz (vector-length (cval C)))
         (csc? (or *kern-omp* (eq? pc 'ssor)))
         (cscptr (and csc? (make-bytevector (* 4 (+ n 1)))))
         (cscidx (and csc? (make-bytevector (* 4 (max 1 nnz)))))
         (cscval (and csc? (make-bytevector (* 8 (max 1 nnz)))))
         (cd     (and *kern-omp* (make-bytevector (* 8 (max 1 nt)))))
         (ssory  (and (eq? pc 'ssor) (make-bytevector (* 8 n))))         ; SSOR forward-sweep scratch
         (ssors  (and (eq? pc 'ssor) (make-bytevector (* 8 (max 1 nt))))) ; running term-dot-products
         (cap (let ((derived (+ n 2))) (if *kern-cgcap* (min *kern-cgcap* derived) derived)))   ; #f ⇒ derived IS the cap; a caller's own number is still sanity-clamped at it
         (lab (map (lambda (ic) (cons (car ic) (exact->inexact (cdr ic)))) labform)))
    (define (gref bv i) (bytevector-ieee-double-native-ref bv (* 8 i)))
    (define (gset! bv i v) (bytevector-ieee-double-native-set! bv (* 8 i) v))
    (define (labdot bv) (fold (lambda (ic a) (+ a (* (cdr ic) (gref bv (car ic))))) 0.0 lab))
    (define direct? (eq? pc 'direct))
    (define ic0? (eq? pc 'ic0))
    (define ic0w? (eq? pc 'ic0w))
    (define ssor? (eq? pc 'ssor))
    ;; THE PRECONDITIONER IS JUDGED BY WHAT IT DOES. The opening choice
    ;; (auto-precond, a static read of the pattern) names a factor or the
    ;; matrix-free Jacobi; from then on the Newton system itself decides.
    ;; CG leaves its residual in r, and ‖r‖/‖g‖ — two dot products already in
    ;; hand — says whether the preconditioned solve solved (H + reg·I) d = −g
    ;; at all. A factor whose CG leaves more than half the residual behind has
    ;; not given a Newton direction (measured on Berlin's three-day program:
    ;; IC(0) left ~1, nine steps, stationarity 0.89, certified bound 4.8e8,
    ;; where Jacobi from the same start converges at 1e-4, bound 11); it is
    ;; retired for the rest of this solve and the step redone under Jacobi,
    ;; whose zero-fill approximation has nothing to break. No shape is named
    ;; and no threshold on the pattern: the KKT residual is the whole test.
    (define mode (if (memq pc '(direct ic0 ic0w)) pc 'jacobi-or-ssor))
    (define (factor-mode?) (memq mode '(direct ic0 ic0w)))
    (define (mode! m) (set! mode m) (set! %last-precond-mode m))   ; the mode this solve ends in, read by the ladder's jacobi rung
    (mode! mode)
    (define %unsolved 0.5)
    (define sym (cond (direct?
                       ;; the border (PLANNER_COLMAX, 0 = none): columns touching more forms
                       ;; than this stay out of the factor — a many-future program's
                       ;; first-stage columns — so L holds the block-diagonal skeleton
                       (when k-cholcolmax
                         (k-cholcolmax (or (and=> (getenv "PLANNER_COLMAX") string->number) 0)))
                       (k-cholsym nt n pptr pidx (if *kern-rcm* 1 0) *kern-maxdeg*))
                      (ic0w?   (k-ic0wsym nt n pptr pidx *kern-dense-thr*))
                      (ic0?    (k-ic0sym nt n pptr pidx))         ; symbolic pattern, once (fixed across steps)
                      (else #f)))
    (when (and direct? (getenv "PLANNER_FILL"))
      (format (current-error-port) "  [direct] L-nnz=~a fill/n=~4,1f~%" (k-chollnnz sym) (/ (k-chollnnz sym) n)))
    (when csc? (k-buildcsc nt n pptr pidx pval (bvp cscptr) (bvp cscidx) (bvp cscval)))  ; once (OMP / SSOR)
    (define (cg-step reg)                                         ; (H + reg·I) d = −g; refactor + solve
      (k-axpy n pzero -1.0 pg pb)                                 ; b = −g
      (cond
        ((and direct? (factor-mode?))                             ; factor sparse skeleton, CG over full H
         (k-cholfac sym nt pptr pidx pval pcv reg)
         (k-pcgchol sym nt n pptr pidx pval pcv pb reg cap pd (bvp r) (bvp z) (bvp p) (bvp hp)))
        ((and ic0w? (factor-mode?))                               ; IC(0) sparse part + Woodbury on dense hub rows
         (k-ic0wfac sym nt pptr pidx pval pcv reg *kern-dense-thr*)
         (k-pcgic0w sym nt n pptr pidx pval pcv pb reg cap pd (bvp r) (bvp z) (bvp p) (bvp hp)))
        (ssor?                                                    ; matrix-free SSOR (recipe-graph Gauss–Seidel)
         (k-diag nt n pptr pidx pval pcv reg pdiag)
         (k-pcgssor nt n pptr pidx pval pcv (bvp cscptr) (bvp cscidx) (bvp cscval) pdiag pb reg cap pd
                    (bvp r) (bvp z) (bvp p) (bvp hp) (bvp ssory) (bvp ssors)))
        ((and ic0? (factor-mode?))
         (k-ic0fac sym nt pptr pidx pval pcv reg)
         (k-pcgic0 sym nt n pptr pidx pval pcv pb reg cap pd (bvp r) (bvp z) (bvp p) (bvp hp)))
        (else                                                     ; Jacobi-CG (serial or OpenMP) — the opening choice, or a retired factor's successor
         (k-diag nt n pptr pidx pval pcv reg pdiag)
         (if *kern-omp*
             (k-pcgomp nt n pptr pidx pval pcv (bvp cscptr) (bvp cscidx) (bvp cscval)
                       pb pdiag reg cap pd (bvp r) (bvp z) (bvp p) (bvp hp) (bvp cd))
             (k-pcg nt n pptr pidx pval pcv pb pdiag reg cap pd (bvp r) (bvp z) (bvp p) (bvp hp))))))
    ;; the gradient SCALE the inner tolerance is relative to: ‖∇f‖ with no barrier
    ;; dual (t = 0), measured once at the start. One extra gradient evaluation
    ;; against ~160 Newton steps — free, and it is what makes the convergence test
    ;; ask the same question of a program with weights of 1 and one with weights
    ;; of 1000.
    (k-tvals nt pptr pidx pval pcnst px psv)
    (k-grad nt n pptr pidx pval pkind pD pw 0.0 psv pg)
    (for-each (lambda (ic) (gset! g (car ic) (+ (gref g (car ic)) (* *kappa* (cdr ic))))) lab)
    (define gscale (+ 1.0 (sqrt (k-dot n pg pg))))
    (call-with-values (lambda ()
    (let path ((t tstart) (Hreg *kern-greg*))
      (let newton ((it 0) (Hreg Hreg) (pmet -1.0))
        (k-tvals nt pptr pidx pval pcnst px psv)
        (k-grad nt n pptr pidx pval pkind pD pw t psv pg)
        (for-each (lambda (ic) (gset! g (car ic) (+ (gref g (car ic)) (* *kappa* (cdr ic))))) lab)
        (let ((gn (sqrt (k-dot n pg pg)))
              (cap-it (if (<= t (* 1.0001 *kern-tmin*)) *kern-newton-final* *kern-newton-mid*)))
          (if (or (>= it cap-it) (< gn (inner-tol t gscale)))     ; centre loosely; tight only at t_min
              (if (<= t *kern-tmin*)
                  (values (f64bv->vec x n) t cgtot ntot (< gn (inner-tol t gscale)))  ; conv? = exited by tol, not cap
                  (path (max *kern-tmin* (* t *kern-sigma*)) Hreg))
              (begin
                (k-tcoef nt pkind pD pw t psv pcv)
                (let* ((reg (greg-lambda gn Hreg))
                       (left (lambda ()                            ; the residual CG left, over the right-hand side; a residual that is not a number left everything
                               (let* ((bb (k-dot n pb pb))
                                      (q (if (> bb 0.0) (sqrt (/ (k-dot n (bvp r) (bvp r)) bb)) 0.0)))
                                 (if (and (real? q) (= q q) (< q +inf.0)) q +inf.0))))
                       ;; THE OPENING CHOICE IS MEASURED. On the first step both
                       ;; candidates solve the same Newton system — the factor the
                       ;; pattern suggested and the matrix-free Jacobi — and jacobi
                       ;; takes the solve on a MATERIAL verdict: the factor left
                       ;; more than 5% of the right-hand side AND at least twice
                       ;; what jacobi left. One extra CG on one step, and the
                       ;; choice is the KKT system's own verdict rather than a
                       ;; reading of the pattern. Measured on Berlin's four-day
                       ;; program: IC(0)'s first step read NaN on that shape (left
                       ;; = everything), held its residual for 26 steps before the
                       ;; guard below retired it, and those steps had already bent
                       ;; the path — the attempt ended at stationarity 0.58 where
                       ;; Jacobi from the start reaches 0.07. The margin is what
                       ;; keeps the verdict material: two near-exact first steps
                       ;; differ by noise, and N=1000's festival phase-I lost its
                       ;; ic0w (both candidates under 1%, jacobi ahead by a hair)
                       ;; to that noise and saturated — 252k CG iterations,
                       ;; stationarity 0.999 — where the kept factor converges.
                       ;; A factor that turns bad later still meets the 50%
                       ;; unsolved guard below, which retires it mid-solve.
                       (its (if (and (= ntot 0) (factor-mode?))
                                (let* ((its-f (cg-step reg)) (left-f (left))
                                       (d-f (bytevector-copy d))
                                       (saved mode)
                                       (_ (mode! 'jacobi-or-ssor))
                                       (its-j (cg-step reg)) (left-j (left)))
                                  (if (and (> left-f 0.05) (> left-f (* 2.0 left-j)))
                                      (begin
                                        (format (current-error-port)
                                                "  [precond] first step: ~a left ~,0f% of the Newton residual, jacobi ~,0f% → jacobi for this solve~%"
                                                saved (* 100.0 left-f) (* 100.0 left-j))
                                        (+ its-f its-j))
                                      (begin (mode! saved) (bytevector-copy! d-f 0 d 0 (* 8 n)) its-f)))
                                (cg-step reg)))
                       (unsolved (left))
                       (its (if (and (factor-mode?) (> unsolved %unsolved))
                                (begin
                                  (format (current-error-port)
                                          "  [precond] ~a left the Newton system ~,0f% unsolved at step ~a → jacobi for the rest of this solve~%"
                                          mode (* 100.0 unsolved) ntot)
                                  (mode! 'jacobi-or-ssor)
                                  (+ its (cg-step reg)))
                                its)))
                  (set! cgtot (+ cgtot its)) (set! ntot (+ ntot 1))
                  (let* ((Lx (labdot x))                                     ; κ·lab·x base; sv still = s(x) here
                         (f0 (+ (k-obj nt pkind pD pw t psv) (* *kappa* Lx)))
                         (Ld (labdot d)))                                    ; κ·lab·y = κ(Lx+η·Ld), linear in η
                    (let ls ((eta 1.0))
                      (k-axpy n px eta pd py)                                ; y = x + η·d
                      (k-tvals nt pptr pidx pval pcnst py psv)               ; sv ← s(y)
                      (let ((fy (+ (k-obj nt pkind pD pw t psv) (* *kappa* (+ Lx (* eta Ld))))))
                        (cond ((and (< fy 1e11) (< fy (- f0 1e-9)))
                               (bytevector-copy! y 0 x 0 (* 8 n))
                               (let ((met (if (and (<= t *kern-tmin*) (> *kern-mettol* 0.0))
                                              (k-meanfill nt pptr pidx pval pkind pcnst pD px) -1.0)))
                                 (if (and (>= pmet 0.0) (< (- met pmet) *kern-mettol*))
                                     ;; DELIVERED DEMAND HAS PLATEAUED — a fair reason to
                                     ;; stop spending Newton steps, and NOT convergence.
                                     ;; This returned #t and was commented "gap-certified",
                                     ;; but the test is that met% stopped rising; the
                                     ;; gradient is never consulted. Measured on a located
                                     ;; program: exits here with ‖∇‖ = 2.8 against a
                                     ;; tolerance of 1e-6, and reported converged. Since
                                     ;; conv? gates the greg retry, the OSQP fallback and
                                     ;; every claim about optimality, saying #t here makes
                                     ;; all three trust a plan nobody checked. Stopping
                                     ;; early is fine; calling it certified is not.
                                     (values (f64bv->vec x n) t cgtot ntot #f)
                                     (newton (+ it 1) (if (>= eta 1.0) (max *kern-hmin* (* Hreg 0.5)) (* Hreg 2.0)) met))))
                              ((< eta 1e-9) (if (<= t *kern-tmin*)
                                                (values (f64bv->vec x n) t cgtot ntot #f)  ; line-search stall = not converged
                                                (path (max *kern-tmin* (* t *kern-sigma*)) Hreg)))
                              (else (ls (* eta 0.5))))))))))))))
      (lambda results (when sym (cond (direct? (k-cholfree sym)) (ic0w? (k-ic0wfree sym)) (else (k-ic0free sym)))) (apply values results)))))

;; ════════════════════════════════════════════════════════════════════════════
;; §5c — CORE, primal-dual: Mehrotra predictor-corrector (pk_solve_pd)
;; solves the KKT system directly; ~18× fewer outer steps on flat
;; optima; finiteness-guarded, falls back to the primal core.
;; ════════════════════════════════════════════════════════════════════════════
(define* (solve-native-c-pd forms labform x0)
  (sync-kern-tmin! forms)                 ; a public entry: derives its own floor (see sync-kern-tmin!)
  (unless (kern-available?) (error "compiled backend unavailable"))
  (let* ((C (flatten forms)) (nt (cnt C)) (n (vector-length x0))
         (ptr (vec->i32 (cptr C))) (idx (vec->i32 (cidx C))) (val (vec->f64 (cval C)))
         (kind (vec->i32 (ckind C))) (cnst (vec->f64 (cconst C))) (Dv (vec->f64 (cD C))) (wv (vec->f64 (cw C)))
         (lab (map (lambda (ic) (cons (car ic) (exact->inexact (cdr ic)))) labform))
         (nlab (length lab))
         (labi (vec->i32 (list->vector (map car lab))))
         (labv (vec->f64 (list->vector (map cdr lab))))
         (x (vec->f64 x0)))
    ;; OMP-parallel inner CG is OFF by default: the matvec is memory-bandwidth-bound and the
    ;; CG has a reduction-barrier per iteration, so fine-grained threading is NET SLOWER (I-O
    ;; 9×8: 30s omp×6 vs 16s serial). The right parallel axis is coarse-grained (scope
    ;; decomposition), not the inner solve. PLANNER_PD_OMP forces it on for experiments.
    (let* ((mubuf (make-f64vector 1 +inf.0))
           (ybuf  (make-f64vector nt 0.0))       ; the dual, by term — see kkt-report
           (chol? (and k-solvepdchol (equal? (getenv "PLANNER_PD_CHOL") "1")))
           (sym   (and chol?
                       (begin
                         ;; the border: PLANNER_PD_COLMAX (default 24) — a first-stage column
                         ;; of a many-future program touches every future's rows and
                         ;; stands far above it; a recourse column touches a handful
                         (when k-cholcolmax
                           (k-cholcolmax (or (and=> (getenv "PLANNER_PD_COLMAX") string->number) 24)))
                         (k-cholsym nt n (bvp ptr) (bvp idx) (if *kern-rcm* 1 0) *kern-maxdeg*))))
           (iters (if sym
                      (let ((its (k-solvepdchol sym nt n nlab (bvp ptr) (bvp idx) (bvp val) (bvp kind) (bvp cnst) (bvp Dv) (bvp wv)
                                                (bvp labi) (bvp labv) (exact->inexact *kappa*) *kern-ridge*
                                                *kern-pd-tol* *kern-pd-maxit*
                                                (bvp x) (bvp mubuf) (bvp ybuf))))
                        (when (getenv "PLANNER_PD_DEBUG")
                          (format (current-error-port) "  [pd-chol] L-nnz=~a fill/n=~4,1f~%" (k-chollnnz sym) (/ (k-chollnnz sym) n)))
                        (k-cholfree sym)
                        its)
                      (k-solvepd nt n nlab (bvp ptr) (bvp idx) (bvp val) (bvp kind) (bvp cnst) (bvp Dv) (bvp wv)
                                 (bvp labi) (bvp labv) (exact->inexact *kappa*) *kern-ridge*
                                 *kern-pd-tol* *kern-pd-maxit* (if (getenv "PLANNER_PD_OMP") 1 0)
                                 (bvp x) (bvp mubuf) (bvp ybuf))))
           (mu (f64vector-ref mubuf 0))
           (yv (let ((v (make-vector nt 0.0)))
                 (do ((i 0 (+ i 1))) ((= i nt) v)
                   (vector-set! v i (f64vector-ref ybuf i))))))
      ;; FINITENESS GUARD. Mehrotra's step is the right tool for a DEGENERATE flat
      ;; optimum, but on a badly flat one it can run to its iteration cap and come
      ;; back with NON-FINITE activities rather than a plan — measured on the
      ;; near-free-transport fixture (setup-space τ=0.002): 80 iterations, 12 NaNs
      ;; in x, mean-fill NaN, while the primal path-follower returns a finite plan
      ;; on the same problem. Nothing downstream checks: a NaN plan would flow
      ;; into credit, rollup and every report as a number-shaped absence.
      ;; So: verify, and fall back to the primal core when the step has diverged.
      ;; The certificate is worth nothing if the vector it certifies is not real.
      ;; Regression: tests/solve/test-pd-finiteness.scm.
      (let ((xv (f64bv->vec x n)))
        (if (plan-finite? xv)                     ; same predicate the attempt list uses
            (values xv iters mu yv)               ; ← plan, gap AND dual travel together
            (begin
              (when (getenv "PLANNER_FALLBACK")
                (format (current-error-port)
                        "  [primal-dual diverged (~a iters, non-finite x) → primal core]~%" iters))
              (call-with-values (lambda () (solve-native-c-core forms labform x0))
                ;; the primal core has no duality gap at all — it reports the path
                ;; floor it stopped at, so a caller can tell WHICH guarantee it holds
                (lambda (xp t cg nt* conv?) (values xp nt* +inf.0 #f)))))))))

;; ════════════════════════════════════════════════════════════════════════════
;; §5d — CORE, OSQP: the planner as a sparse QP
;; ADMM with a direct sparse factor. May never be handed a fragility
;; (no log barrier: it rides an ecological limit to its tip).
;; ════════════════════════════════════════════════════════════════════════════

;; The one-sided desire w·max(0,(D−s)/D)² becomes a clean quadratic by adding an
;; unmet slack uᵢ ≥ Dᵢ−sᵢ(x): minimising w(uᵢ/Dᵢ)² drives uᵢ = max(0,Dᵢ−sᵢ),
;; reproducing satiation exactly. Then the WHOLE program is
;;     min  Σ wᵢ(uᵢ/Dᵢ)² + κ cᵀx     over z=[x;u]
;;     s.t. every 'bar:  Σv·x ≥ −const ;  every 'des:  Σv·x + uᵢ ≥ Dᵢ−const
;; — a sparse convex QP in OSQP's standard form (min ½zᵀPz+qᵀz s.t. l≤Az≤u),
;; P diagonal, A the recipe incidence. libosqp solves it by ADMM, sparse, with
;; its own optimality certificate. Variables: x are 0..na-1, uᵢ are na+i.
;; WHERE THE LIBRARY COMES FROM, IN ORDER OF WHO IS SAYING SO.
;;
;; A hardcoded /gnu/store/<hash>-osqp-1.0.0/lib/libosqp.so used to sit in this
;; list. A store path names ONE machine's build of one derivation, so it
;; resolved on the laptop whose store produced it and on no other: the backend
;; read as available here and absent on the CI box, where three suites that
;; select it explicitly errored out at load. The fix is to stop naming a build
;; and start naming an ENVIRONMENT.
;;
;; OSQP_LIB first, because it is someone stating which library to use, and a
;; search that outranks a statement cannot be steered. Then the ambient Guix
;; profile: `guix shell` exports GUIX_ENVIRONMENT, so the manifest that supplies
;; the Guile running this code supplies its libosqp too, and the two cannot
;; drift apart. Then the loader's own search, for a system-wide install.
(define (%link-osqp)
  (define (try p) (and p (false-if-exception (dynamic-link p))))
  ;; After the shell's environment, the user's standing profiles: a bare `guile`
  ;; from ~/.guix-profile/bin exports neither GUIX_ENVIRONMENT nor GUIX_PROFILE,
  ;; and the libosqp sitting beside it went unfound — the bench then ran without
  ;; the OSQP rung of the ladder and nothing said so (docs/planning/solve/wiod-planner.md).
  (let loop ((roots (list (getenv "GUIX_ENVIRONMENT") (getenv "GUIX_PROFILE")
                          (and=> (getenv "HOME") (lambda (h) (string-append h "/.guix-profile")))
                          (and=> (getenv "HOME") (lambda (h) (string-append h "/.guix-home/profile"))))))
    (cond ((null? roots) (try "libosqp"))
          ((and (car roots) (try (string-append (car roots) "/lib/libosqp.so"))))
          (else (loop (cdr roots))))))
(define *osqp-lib* (or (let ((p (getenv "OSQP_LIB")))
                         (and p (false-if-exception (dynamic-link p))))
                       (%link-osqp)))
(define *osqp-inf* 1e30)
;; plan lands INSIDE %feasible-tol's band and can actually be accepted — at 1e-3
;; every OSQP rescue violated some balance by ~its own eps and was discarded,
;; which silently disabled the whole fallback (measured: the ladder returned the
;; phase-I seed at fill 0.18 past an OSQP plan holding 1.0). Costs iterations
;; only on the rescue path, where correctness is the entire point.
(define *osqp-last* (list 0 0.0 0 0.0 0.0))  ; (iter run_time-s status_val prim_res dual_res) of last solve
(define (osqp-available?) (and *osqp-lib* #t))
(define (i64* xs) (let* ((n (length xs)) (bv (make-bytevector (* 8 (max 1 n))))) (let lp ((i 0)(xs xs)) (if (null? xs) bv (begin (bytevector-s64-native-set! bv (* 8 i) (car xs)) (lp (+ i 1)(cdr xs)))))))
(define (f64* xs) (let* ((n (length xs)) (bv (make-bytevector (* 8 (max 1 n))))) (let lp ((i 0)(xs xs)) (if (null? xs) bv (begin (bytevector-ieee-double-native-set! bv (* 8 i) (exact->inexact (car xs))) (lp (+ i 1)(cdr xs)))))))
;; CSC from triplets (col row val): group by column, rows sorted ascending.
;; Returns (values struct-ptr keepalive) — keepalive must outlive the setup call.
(define (triplets->csc m n trips)
  (let ((cols (make-vector n '())))
    (for-each (lambda (e) (let ((c (car e))) (vector-set! cols c (cons (cons (cadr e) (caddr e)) (vector-ref cols c))))) trips)
    (let ((p (make-list (+ n 1) 0)) (is '()) (xs '()) (off 0) (pv (make-vector (+ n 1) 0)))
      (do ((c 0 (+ c 1))) ((= c n))
        (vector-set! pv c off)
        (let ((entries (sort (vector-ref cols c) (lambda (a b) (< (car a) (car b))))))
          (for-each (lambda (rv) (set! is (cons (car rv) is)) (set! xs (cons (cdr rv) xs)) (set! off (+ off 1))) entries)))
      (vector-set! pv n off)
      (let* ((pbv (i64* (vector->list pv))) (ibv (i64* (reverse is))) (xbv (f64* (reverse xs)))
             (struct (make-c-struct (list int64 int64 '* '* '* int64 int64 int64)
                       (list m n (bytevector->pointer pbv) (bytevector->pointer ibv) (bytevector->pointer xbv) off -1 0))))
        (values struct (list pbv ibv xbv struct))))))
(define* (solve-osqp forms labform na #:optional x0)
  (unless (osqp-available?) (error "OSQP backend unavailable: libosqp not found (guix install osqp, or set OSQP_LIB)"))
  (when (find (lambda (f) (eq? (f-kind f) 'qc)) forms)
    (error "OSQP path does not support 'qc (quadratic-cost / EMP) forms yet — P is built diagonal; use the native/native-c backend"))
  (let* ((des (filter (lambda (f) (eq? (f-kind f) 'des)) forms))
         (nd (length des))
         (nvar (+ na nd))
         (lab (let ((v (make-vector na 0.0))) (for-each (lambda (ic) (vector-set! v (car ic) (+ (vector-ref v (car ic)) (cdr ic)))) labform) v))
         (z0 (make-vector nvar 0.0))   ; warm-start vector [x0 ; u0]; u0 = chain-implied unmet
         ;; P: diagonal. activities: ridge ε. unmet i: 2w/D² + ε.
         (Ptr '()) (q (make-vector nvar 0.0)))
    (when x0 (do ((i 0 (+ i 1))) ((= i na)) (vector-set! z0 i (vector-ref x0 i))))
    (do ((i 0 (+ i 1))) ((= i na)) (set! Ptr (cons (list i i 1e-7) Ptr)) (vector-set! q i (* *kappa* (vector-ref lab i))))
    ;; rows of A: one per form, in order; 'des also writes its unmet column.
    (let ((trips '()) (l '()) (u '()) (row 0) (di 0))
      (for-each (lambda (f)
        (for-each (lambda (ic) (set! trips (cons (list (car ic) row (cdr ic)) trips))) (f-coeffs f))
        (if (eq? (f-kind f) 'des)
            (let* ((D (car (f-Dw f))) (w (cdr (f-Dw f))) (uc (+ na di)))
              (set! trips (cons (list uc row 1.0) trips))           ; +u_i in this row
              (set! Ptr (cons (list uc uc (+ (/ (* 2.0 w) (* D D)) 1e-7)) Ptr))
              (set! l (cons (- D (f-const f)) l)) (set! u (cons *osqp-inf* u))
              (when x0 (let ((s (fold (lambda (ic a) (+ a (* (cdr ic) (vector-ref x0 (car ic))))) (f-const f) (f-coeffs f))))
                         (vector-set! z0 uc (max 0.0 (- D s)))))    ; u0 = max(0, D − delivered(x0))
              (set! di (+ di 1)))
            (begin (set! l (cons (- (f-const f)) l)) (set! u (cons *osqp-inf* u))))
        (set! row (+ row 1)))
        forms)
      (let ((m row))
        (call-with-values (lambda () (triplets->csc nvar nvar (reverse Ptr)))
          (lambda (P Pkeep)
            (call-with-values (lambda () (triplets->csc m nvar (reverse trips)))
              (lambda (A Akeep)
                (let* ((lib *osqp-lib*)
                       (qbv (f64* (vector->list q))) (lbv (f64* (reverse l))) (ubv (f64* (reverse u)))
                       (settings ((pointer->procedure '* (dynamic-func "OSQPSettings_new" lib) '())))
                       (solverp (make-bytevector 8 0)))
                  ;; tune settings for ACCURACY at scale (defaults declare victory on the
                  ;; scaled problem too early ⇒ collapsed primal): more iters, tight eps,
                  ;; and POLISHING (solve the final KKT exactly for an accurate solution).
                  (bytevector-s64-native-set! (pointer->bytevector settings 8 24) 0 0)       ; verbose=0
                  ;; the budget matches the tolerance: at eps 1e-6 (a plan that can
                  ;; pass the certificate's feasibility band) ADMM needs the room —
                  ;; measured: 16000 hit the cap on the federated refine scopes and
                  ;; returned a divergent iterate (~1e8) as if it were a plan
                  (bytevector-s64-native-set! (pointer->bytevector settings 8 160) 0 200000)  ; max_iter
                  (bytevector-ieee-double-native-set! (pointer->bytevector settings 8 168) 0 *osqp-eps*)  ; eps_abs
                  (bytevector-ieee-double-native-set! (pointer->bytevector settings 8 176) 0 *osqp-eps*)  ; eps_rel
                  (bytevector-s64-native-set! (pointer->bytevector settings 8 56) 0 0)        ; polishing=0 (segfaults at scale; not needed once well-posed)
                  (let ((rc ((pointer->procedure int (dynamic-func "osqp_setup" lib) (list '* '* '* '* '* '* int64 int64 '*))
                             (bytevector->pointer solverp) P (bytevector->pointer qbv) A
                             (bytevector->pointer lbv) (bytevector->pointer ubv) m nvar settings)))
                    (unless (= rc 0) (error "osqp_setup failed" rc))
                    (let ((solver (make-pointer (bytevector-u64-native-ref solverp 0))))
                      (when x0                                       ; warm-start from the chain-consistent point
                        (let ((zbv (f64* (vector->list z0))))
                          ((pointer->procedure int (dynamic-func "osqp_warm_start" lib) (list '* '* '*))
                           solver (bytevector->pointer zbv) %null-pointer)))
                      ((pointer->procedure int (dynamic-func "osqp_solve" lib) (list '*)) solver)
                      (let* ((soln (make-pointer (bytevector-u64-native-ref (pointer->bytevector solver 8 8) 0)))
                             (xaddr (bytevector-u64-native-ref (pointer->bytevector soln 8 0) 0))
                             (xbv (pointer->bytevector (make-pointer xaddr) (* nvar 8)))
                             (info (make-pointer (bytevector-u64-native-ref (pointer->bytevector solver 8 16) 0)))
                             (x (make-vector na 0.0)))
                        (do ((i 0 (+ i 1))) ((= i na)) (vector-set! x i (max 0.0 (bytevector-ieee-double-native-ref xbv (* i 8)))))
                        (set! *osqp-last* (list (bytevector-s64-native-ref (pointer->bytevector info 8 88) 0)        ; iter
                                                (bytevector-ieee-double-native-ref (pointer->bytevector info 8 144) 0) ; run_time (s)
                                                (bytevector-s64-native-ref (pointer->bytevector info 8 32) 0)        ; status_val
                                                (bytevector-ieee-double-native-ref (pointer->bytevector info 8 64) 0) ; prim_res
                                                (bytevector-ieee-double-native-ref (pointer->bytevector info 8 72) 0)   ; dual_res
                                                (bytevector-ieee-double-native-ref (pointer->bytevector info 8 48) 0))) ; obj_val
                        ((pointer->procedure int (dynamic-func "osqp_cleanup" lib) (list '*)) solver)
                        Pkeep Akeep                                 ; (keep data alive across setup)
                        (values x 0.0 0 1)))))))))))))
)
(else
;; Hoot has no (system foreign): there is no compiled kernel and no libosqp, so the
;; reference core above is the only backend. The names below keep the export list
;; whole; each entry point that would cross the FFI refuses by name.
(define (kern-isa-ok?) #f)
(define (kern-available?) #f)
(define (set-kern-enabled! on?) #f)     ; nothing to enable
(define (osqp-available?) #f)
(define (kern-unavailable-reason) "compiled backend unavailable: this build has no foreign-function interface")
(define *kern-lib* #f)
(define *kern-isa-missing* #f)
(define *osqp-lib* #f)
(define *osqp-inf* #f)
(define *osqp-last* #f)
(define k-tvals #f)
(define k-tcoef #f)
(define k-grad #f)
(define k-diag #f)
(define k-obj #f)
(define k-pcg #f)
(define k-dot #f)
(define k-axpy #f)
(define k-ic0sym #f)
(define k-ic0fac #f)
(define k-ic0free #f)
(define k-pcgic0 #f)
(define k-ic0wsym #f)
(define k-ic0wfac #f)
(define k-ic0wfree #f)
(define k-pcgic0w #f)
(define k-cholsym #f)
(define k-cholfac #f)
(define k-cholsolve #f)
(define k-cholfree #f)
(define k-chollnnz #f)
(define k-pcgchol #f)
(define k-buildcsc #f)
(define k-pcgssor #f)
(define k-solvepd #f)
(define k-solvepdchol #f)
(define k-cholcolmax #f)
(define k-pcgomp #f)
(define k-ompthreads #f)
(define k-solvemany #f)
(define k-meanfill #f)
(define k-set-tmin #f)
(define k-set-schedule #f)
(define (%cpu-flags . _) (error "needs the foreign-function interface; this build runs the reference core only" '%cpu-flags))
(define (kern-isa-refusal . _) (error "needs the foreign-function interface; this build runs the reference core only" 'kern-isa-refusal))
(define (kfn . _) (error "needs the foreign-function interface; this build runs the reference core only" 'kfn))
(define (bvp . _) (error "needs the foreign-function interface; this build runs the reference core only" 'bvp))
(define (solve-native-c-core . _) (error "needs the foreign-function interface; this build runs the reference core only" 'solve-native-c-core))
(define (solve-native-c-pd . _) (error "needs the foreign-function interface; this build runs the reference core only" 'solve-native-c-pd))
(define (%link-osqp . _) (error "needs the foreign-function interface; this build runs the reference core only" '%link-osqp))
(define (i64* . _) (error "needs the foreign-function interface; this build runs the reference core only" 'i64*))
(define (f64* . _) (error "needs the foreign-function interface; this build runs the reference core only" 'f64*))
(define (triplets->csc . _) (error "needs the foreign-function interface; this build runs the reference core only" 'triplets->csc))
(define (solve-osqp . _) (error "needs the foreign-function interface; this build runs the reference core only" 'solve-osqp))
))

;; ════════════════════════════════════════════════════════════════════════════
;; §6 — ACCEPTANCE + DISPATCH: several attempts, one rule for taking one
;; the ladder (native → greg-off → OSQP), KKT-admissibility, the
;; certificate-then-objective ranking, and the backend dispatcher.
;; ════════════════════════════════════════════════════════════════════════════

;; The two interchangeable solvers, by what this build has: the compiled kernel when
;; it is linked, the reference core (solve-native) otherwise. Same signatures, same
;; return shapes — the federated solve reaches for these two, and a browser (which
;; has no kernel) runs the same scope solves through the reference core.
(define (scope-core . args)
  (apply (if (kern-available?) solve-native-c-core solve-native-core) args))
(define (solve-exact . args)
  (apply (if (kern-available?) solve-native-c solve-native) args))

(define* (solve-native-c forms labform x0 #:optional (tstart 1.0))
  (sync-kern-tmin! forms)                 ; the floor follows the guarantee, not a constant
  ;; Phase-I DECIDES feasibility here too, not just on the Scheme path. The two
  ;; backends used to disagree about what infeasibility even is: `solve-native`
  ;; raised, this one quietly returned a plan whose certificate said
  ;; `feasible? #f` — so a caller that wanted an honest infeasible answer had to
  ;; use the slow reference solver and catch an exception. That is why the
  ;; repository's heaviest test is pinned to the pure-Scheme path.
  ;;
  ;; Now both decide by the same argument and publish the same object: the
  ;; violation s*, how many limits are breached, and which are worst. No
  ;; exception is raised on this path — callers here expect a plan back and
  ;; several of them (live.scm, solve/robust.scm) read the certificate — but the
  ;; verdict is no longer something only one backend can express.
  (let* ((C   (flatten forms))
         ;; Phase-I, then a CONFIRMING pass from a strictly-interior start before
         ;; believing an infeasible verdict. `solve-native` has always done this —
         ;; phase-I can stop short from a far seed — and the two backends are
         ;; supposed to agree about what infeasibility even is, so the discipline
         ;; belongs on both. It matters because `located-warm` seeds a production
         ;; column at its good's throughput in GOODS units while the column's
         ;; activity is in RUNS: the seed lands further outside the feasible region
         ;; the larger the unit a good is stated in, and past some scale phase-I
         ;; cannot walk back from it. The cheap confirming solve recovers the same
         ;; plan the reference backend finds, at every scale.
         ;;
         ;; Since `located-warm` was corrected to seed in RUNS, no test reaches this
         ;; branch — even a demand 100000× capacity now converges from the seed at
         ;; every scale. It stays for the reason it was added, which was never this
         ;; one bug: the two backends are supposed to agree about what infeasibility
         ;; IS, and `solve-native` has always confirmed before believing. Removing it
         ;; here would restore exactly the asymmetry that let the divergence hide.
         ;; Unexercised, deliberately — say so rather than let it look covered.
         (phase1-start                          ; seed pass + confirming interior pass, ONE definition —
          (lambda ()                            ; the greg-off retry must start exactly as the outer solve
            (let ((from-seed (call-with-values  ; does, or the two walk different plateau exits
                                 (lambda () (phase1-decide forms labform x0 solve-native-c-core))
                               (lambda (x s*) (cons x s*)))))
              (if (not (infeasible-by? C (car from-seed) (cdr from-seed)))
                  from-seed
                  (let ((from-interior
                         (call-with-values
                             (lambda () (phase1-decide forms labform
                                          (make-vector (vector-length x0) 0.05)
                                          solve-native-c-core))
                           (lambda (x s*) (cons x s*)))))
                    (if (< (cdr from-interior) (cdr from-seed)) from-interior from-seed))))))
         (x0d (phase1-start))
         (x0f (car x0d))
         (infeas (and (infeasible-by? C x0f (cdr x0d)) (cdr x0d)))
         ;; ── the exterior start is a FIXED POINT, and this is the escape ─────
         ;; Outside its wall the guarded barrier is FLAT — φ = 1e12 with φ′ = 0
         ;; — so a start that phase-I leaves exterior by its relaxation floor
         ;; (s* ~1e-5, the pin paragraph above) freezes the entire path: the
         ;; violated form pushes back on nothing, and every line-search step
         ;; still reads 1e12. Measured on a per-agent spanning program: both
         ;; native attempts returned the seed untouched, stat 2.5, one unit
         ;; delivered of five. So the attempts solve the program RELAXED by
         ;; exactly the start's own deficit — the start is strictly interior
         ;; there, the barrier is alive, and Newton walks — while the
         ;; certificate still judges every candidate against the TRUE program,
         ;; whose feasibility band (the same family floor) already covers a
         ;; deficit this size. A start already interior relaxes nothing.
         ;; PER-FORM, not uniform: bumping every wall by the worst deficit
         ;; moved walls the optimum genuinely rides, and the relaxed central
         ;; point then mapped to wall-riding TRUE slacks (measured: a certified
         ;; solve with face room 0 where it had 3.8e-3). Only a form the start
         ;; actually violates is relaxed, by 1.5× its own deficit — every other
         ;; wall stays exact, and the bumped forms' own barrier margins (~t/y)
         ;; dwarf their tolerance-sized bumps, so the solve exits strictly
         ;; interior to the true program in the ordinary case.
         (form-deficit (lambda (f)
                         (let ((g (if (method-form? f) (cadr f) f)))
                           (if (memq (f-kind g) '(bar frag held))
                               (let ((sl (+ (f-const g)
                                            (fold (lambda (pc a) (+ a (* (cdr pc) (vector-ref x0f (car pc)))))
                                                  0.0 (f-coeffs g)))))
                                 (if (< sl 0.0) (* 1.5 (- sl)) 0.0))
                               0.0))))
         (relax (fold (lambda (f a) (max a (form-deficit f))) 0.0 forms))
         (relax-form (lambda (f)
                       (let ((b (form-deficit f)))
                         (if (= b 0.0) f
                             (let ((bump (lambda (g) (cons (f-kind g) (cons (+ (f-const g) b) (cddr g))))))
                               (if (method-form? f) (mk-method (bump (cadr f))) (bump f)))))))
         (forms* (if (= relax 0.0) forms (map relax-form forms)))
         ;; …and a rescue that has to do REAL work is a regression, so it says so.
         ;; This escape was built when phase-I could leave a start exterior by a
         ;; macroscopic amount (measured 0.152 on a 7-day per-agent program, from
         ;; running its dense-slack column under IC(0) — fixed at `phase1-decide`).
         ;; With phase-I converging to the family floor the deficits it now sees
         ;; are 1e-13…1e-6 — float noise, orders below %feasible-tol, and most
         ;; solves need none at all. The mechanism stays: a PINNED variable has an
         ;; empty interior, so s* settles near 1e-5 there by construction and the
         ;; escape is what keeps that program moving. But a deficit above the
         ;; feasibility band no longer means "an awkward start"; it means phase-I
         ;; has stopped converging, and the only thing worse than that happening
         ;; is it happening quietly.
         (_ (when (> relax %feasible-tol)
              (format (current-error-port)
                      "  [phase-I left the start exterior by ~,3e (> ~,3e) — the escape is covering for it; expect a poor plan]~%"
                      relax %feasible-tol)))
         (n   (vector-length x0))
         (osqp-ok? (and *osqp-fallback* (osqp-available?)
                        (<= n *osqp-fallback-maxvar*)
                        (not (find (lambda (f) (memq (f-kind f) '(qc frag))) forms))))
         (attempts
          (filter cdr
            (list
             (cons "native-c"
                   (lambda () (solve-native-c-core forms* labform x0f tstart)))
             ;; the SAME step under Jacobi-CG, when the automatic pick was a
             ;; factor. Measured on Berlin's three-day program (1,299 columns):
             ;; IC(0) stalls at 9 Newton steps, stationarity 0.89, certified
             ;; bound 4.8e8; Jacobi converges in 272 steps, stationarity 1e-4,
             ;; bound 11, 4.6 s. The factor's direction is what Newton cannot
             ;; use there, and a rung is where a failed direction is answered.
             ;; …applicable at its TURN, read off the mode the first attempt
             ;; ended in: a solve that ran Jacobi throughout — chosen on the
             ;; first step, or after retiring its factor — has already made
             ;; this attempt, and the rung answers "not applicable" (xr = #f,
             ;; which the loop passes over without judging)
             (cons "native-c (jacobi)"
                   (and (not (getenv "PLANNER_PRECOND"))
                        (lambda ()
                          (if (eq? %last-precond-mode 'jacobi-or-ssor)
                              (values #f #f #f #f #f)
                              (parameterize ((%precond-override 'jacobi))
                                (solve-native-c-core forms* labform x0f tstart))))))
             ;; …applicable at its turn when the attempt before it STALLED: the
             ;; plateau this rung rescues is a step that gave up (exited by cap
             ;; or line search), and a step that exited by tolerance has no
             ;; plateau to rescue — retrying it repeats a converged solve
             ;; (measured live: a full attempt, ~50 s, ending at the same point)
             (cons "native-c (greg off)"
                   (and (> *kern-greg* 0.0)
                        (lambda ()
                         (if %last-attempt-converged?
                             (values #f #f #f #f #f)
                          (call-with-greg 0.0
                            (lambda ()
                              ;; the SAME start construction as the outer solve,
                              ;; recomputed unregularized — a phase-I run at the
                              ;; regularized setting is already degraded, and a
                              ;; DIFFERENT start construction walks a different
                              ;; plateau exit (measured: f 4.81 vs plain's 3.89
                              ;; from the bare-phase-I variant of this retry)
                              (solve-native-c-core forms* labform (car (phase1-start)) tstart)))))))
             (cons "OSQP"
                   (and osqp-ok?
                        (lambda ()
                          ;; an OSQP failure must never crash the solve
                          (let ((xo (false-if-exception
                                     (call-with-values
                                         (lambda () (solve-osqp forms labform n x0f))
                                       (lambda (xo . _) xo)))))
                            (if xo (values xo *kern-tmin* 0 0 #t)
                                (values x0f *kern-tmin* 0 0 #f))))))))))
    (if infeas
        ;; PROVEN infeasible: every attempt below would solve a program with no
        ;; answer — four times over — to arrive at what phase-I already
        ;; established. Publish the obstruction and stop.
        (begin
          (set! *last-certificate* (infeasibility-report forms x0f infeas))
          (values x0f *kern-tmin* 0 0 #f))
    (let loop ((as attempts) (best #f) (bestbnd +inf.0) (bestfv +inf.0) (interior #f))
      (if (null? as)
          ;; nothing was certifiably optimal — return the best-certified plan and
          ;; publish ITS certificate, so the caller sees what it actually holds
          (let ((b (or best (list x0f *kern-tmin* 0 0 #f
                                  (kkt-report C labform x0f *kern-tmin*)))))
            (when (getenv "PLANNER_FALLBACK")
              (format (current-error-port) "  [ladder: no attempt admissible → returning ~a]~%"
                      (if best "best-ranked candidate" "the phase-I seed")))
            (set-certificate-from-kkt! (list-ref b 5))
            (apply values (list-head b 5)))
          (call-with-values (cdr (car as))
            (lambda (xr t cg nt conv?)
              (if (not xr)                                   ; an attempt that is not applicable at its turn
                  (loop (cdr as) best bestbnd bestfv interior)
              (let* ((name (car (car as)))
                     (_ (set! %last-attempt-converged? (and conv? #t)))
                     ;; a wall-riding candidate is RETRACTED toward the strictly
                     ;; interior sibling before judgment — exit noise costs it a
                     ;; hair of its plan, not its duals (see retract-feasible)
                     (x    (if (and interior (plan-finite? xr)
                                    (< (bar-slacks-min C (term-values C xr)) 0.0))
                               (retract-feasible C xr interior)
                               xr))
                     (k    (kkt-report C labform x t))
                     (feas (assq-ref k 'feasible?))
                     (bnd  (if feas (assq-ref k 'gap-bound) +inf.0))
                     ;; ADMISSIBLE = the KKT conditions. Feasible (inside every
                     ;; limit — what the scattered fragility exclusions were each
                     ;; approximating) and stationary (a critical point). No
                     ;; separate finiteness test: a NaN plan has NaN residuals.
                     (adm? (and feas (assq-ref k 'optimal?))))
                (when (getenv "PLANNER_FALLBACK")
                  (format (current-error-port)
                          "  [~a: feasible ~a  min-slack ~,3e  stat ~,3e  f ~,6e  certified ≤ ~,3e → ~a]~%"
                          name feas (assq-ref k 'min-slack) (assq-ref k 'stationarity)
                          (if feas (world-objective C labform x) +inf.0)
                          bnd (if adm? "accept" "next")))
                (if adm?
                    (begin (set-certificate-from-kkt! k) (values x t cg nt conv?))
                    ;; RANK BY THE CERTIFICATE WHERE IT SAYS SOMETHING, by the
                    ;; OBJECTIVE where it does not. Three rankings failed
                    ;; measurably before this one. met% picked whichever attempt
                    ;; DELIVERED most, which is not the objective (a met-ranked
                    ;; choice carried a certified gap of 1.44 where a rejected
                    ;; sibling carried 0.24). The gap-bound alone picked the
                    ;; TIGHTEST BOUND, which is not the best plan (greg plateau:
                    ;; 82% met at bound 773 outranked 97% at 5.8e5 — both bounds
                    ;; sound, the comparison meaningless where ‖r‖ blows up on a
                    ;; plateau). The objective alone then picked wall-riding
                    ;; candidates whose duals diverge over near-ties a tight
                    ;; certificate could settle (test-certificate: a plan ON its
                    ;; wall, face room 0, outranked one strictly inside carrying
                    ;; a 0.12 bound). So: a bound is INFORMATIVE when it is
                    ;; finite and no larger than the objective's own scale.
                    ;; Between two informative certificates, the tighter wins —
                    ;; that comparison is exactly what a certificate is for.
                    ;; Between two uninformative ones, the objective wins — it
                    ;; is exact and directly comparable. Mixed, the uncertified
                    ;; candidate must beat the certified one by MORE than its
                    ;; certified gap: anything less is inside what the
                    ;; certificate already guarantees.
                    (let* ((fv (if feas (world-objective C labform x) +inf.0))
                           (inf? (lambda (b f) (or (= b +inf.0) (> b (+ 1.0 (abs f))))))
                           (better?
                            (cond ((not best) feas)
                                  ((and (not (inf? bnd fv)) (not (inf? bestbnd bestfv)))
                                   (< bnd bestbnd))
                                  ((and (inf? bnd fv) (inf? bestbnd bestfv))
                                   (or (< fv bestfv) (and (= fv bestfv) (< bnd bestbnd))))
                                  ((inf? bnd fv) (< fv (- bestfv bestbnd)))
                                  ;; the candidate is the certified one and the
                                  ;; incumbent is not: the incumbent keeps only by
                                  ;; beating the candidate by MORE than the
                                  ;; candidate's certified gap — the rule above,
                                  ;; read from the other side. Written the other
                                  ;; way round it asked the certified point to beat
                                  ;; an uncertified one by its whole gap; measured
                                  ;; live on Berlin's day, the first attempt at
                                  ;; stationarity 0.51 kept its place over the
                                  ;; Jacobi rung at 2.7e-3 on a value within one
                                  ;; unit of it, and the plan shipped stalled.
                                  (else (not (< bestfv (- fv bnd)))))))
                      (loop (cdr as)
                            (if better? (list x t cg nt conv? k) best)
                            (if better? bnd bestbnd)
                            (if better? fv bestfv)
                            (or interior
                                (and (plan-finite? x)
                                     (> (assq-ref k 'min-slack) 0.0)
                                     x))))))))))))))
(define (qc-free? forms) (not (find (lambda (f) (eq? (f-kind f) 'qc)) forms)))   ; OSQP can't do EMP/congestion (qc) forms; its P is diagonal

;; Every route reports the same certificate: run the backend, measure the plan.
;;
;; And NO route may return an infeasible plan. The attempt list inside
;; solve-native-c already refuses one, but a backend named explicitly went
;; straight through — measured: `native-pd` on a near-free-transport program
;; returns min-slack −4.2e-2 (a breached barrier) with an objective twelve orders
;; worse than the path-follower's, and `solve` handed it back. A caller naming a
;; backend is choosing an ALGORITHM, not waiving the constraints; feasibility is
;; the federation's, not the caller's, to give up. So every route is guarded, and
;; a breach falls back to the path-follower, which respects barriers by
;; construction (fraction-to-the-boundary).
;;
;; The dual is FITTED only when the backend cannot supply one. A path-following
;; solve knows its own t; the primal-dual carries a real y. Re-fitting a dual the
;; solver already has overstates the residual by orders of magnitude (§ #18).
(define* (certified thunk forms labform #:key (t #f) (measured-mu #f) (dual #f) (fallback #f))
  (call-with-values thunk
    (lambda args
      (let* ((x  (car args))
             (tt (or t (and (>= (length args) 2)
                            (let ((v (list-ref args 1)))
                              (and (real? v) (> v 0.0) (<= v 1.0) v)))))
             (k  (if dual (kkt-report (flatten forms) labform x #:dual dual)
                     (if tt (kkt-report (flatten forms) labform x tt)
                         (kkt-report (flatten forms) labform x)))))
        ;; the fallback's triggers, on the same ladder the slacks use (THREE
        ;; TOLERANCES above): a point that is INFEASIBLE, or one whose
        ;; stationarity says the solve CAME APART (%stalled-stat). The noise
        ;; floor stays `optimal?` (1e-6, reported); the path-follower's own
        ;; endpoint reads ~2.6e-3 relative on Berlin's day and is a plan;
        ;; measured live on that day: the primal-dual returned after 23
        ;; iterations at stationarity 1.0 — every maximin wall slack by
        ;; hundreds, τ = 0.08 under futures capturing 0.35 — feasible, and
        ;; not a plan by any reading. Its own stopping rule passed it; the
        ;; certificate is where "done" is decided, so it is decided here.
        ;; the ladder publishes the certificate of the attempt it chose; this
        ;; recomputation must agree with it — when it does not, both are named
        (let ((prev (and (list? *last-certificate*) (assq-ref *last-certificate* 'stationarity)))
              (now (assq-ref k 'stationarity)))
          (when (and (number? prev) (number? now) (> prev 0.0) (> now 0.0)
                     (or (> now (* 10.0 prev)) (> prev (* 10.0 now))))
            (format (current-error-port) "  [certified] DISAGREES with the ladder: ladder stat ~,2e, recomputed ~,2e at t=~a (arg t ~s)~%"
                    prev now tt (and (>= (length args) 2) (list-ref args 1)))))
        (format (current-error-port) "  [certified] ~a feasible=~a stationarity=~a fallback=~a n=~a~%"
                (or (assq-ref k 'backend) "?") (assq-ref k 'feasible?)
                (let ((st (assq-ref k 'stationarity))) (if (number? st) (format #f "~,2e" st) st))
                (and fallback #t) (vector-length x))
        (if (or (not fallback)
                (and (assq-ref k 'feasible?)
                     (let ((st (assq-ref k 'stationarity)))
                       (or (not (number? st)) (<= st %stalled-stat)))))
            (begin (set-certificate-from-kkt! k measured-mu) (apply values args))
            (begin
              (format (current-error-port)
                      "  [~a returned a point that is ~a (min-slack ~,3e, stationarity ~,3e) → path-follower]~%"
                      (or (assq-ref k 'backend) "backend")
                      (if (assq-ref k 'feasible?) "feasible but STALLED" "INFEASIBLE")
                      (assq-ref k 'min-slack) (assq-ref k 'stationarity))
              (certified fallback forms labform)))))))

(define* (solve forms labform x0 #:optional (tstart 1.0))
  (sync-kern-tmin! forms)                 ; Scheme owns the path floor — see *kern-tmin*
  (case *backend*
    ;; Even ASKED FOR by name, OSQP may not be handed a fragility. It has no
    ;; log-barrier, so the barrier becomes a hard cap at its tip and the plan is
    ;; free to sit exactly on an ecological limit — measured at x = 10.00013 on a
    ;; tip of 10, reported as solved. "The caller chose it" is not a good enough
    ;; reason to breach a limit the federation inscribed: the choice of solver is
    ;; an implementation detail, the barrier is a governance decision. So the
    ;; substitution is made, and made LOUDLY rather than silently.
    ((osqp)
     (if (find (lambda (f) (eq? (f-kind f) 'frag)) forms)
         (begin
           (format (current-error-port)
                   "  [backend osqp requested, but the program carries a fragility barrier~%~
                     ~4tOSQP cannot represent one and would ride it to its tip → using native-c]~%")
           (certified (lambda () (solve-native-c forms labform x0 tstart)) forms labform))
         (certified (lambda () (solve-osqp forms labform (vector-length x0) x0))
                    forms labform)))
    ((native-c) (certified (lambda () (solve-native-c forms labform x0 tstart)) forms labform))
    ((native)   (certified (lambda () (solve-native forms labform x0 tstart)) forms labform))
    ((native-pd)                                   ; matrix-free Mehrotra primal-dual (drop-in 5-value return)
     (let ((xf (ensure-feasible forms labform x0 solve-native-c-core)))
       (call-with-values (lambda () (solve-native-c-pd forms labform xf))
         (lambda (x its mu yv)
           (call-with-values
               (lambda ()
                 (certified (lambda () (values x *kern-tmin* 0 its #t)) forms labform
                            #:dual yv #:measured-mu mu
                            #:fallback (lambda () (solve-native-c forms labform x0 tstart))))
             (lambda a (apply values a)))))))
    ;; AUTO (default): OSQP when the problem is qc-free AND sparse — measured 7–10× faster than the
    ;; native kernel there. But OSQP cannot handle EMP/congestion (qc) forms, and it CHOKES on
    ;; dense commodity hubs (its sparse factor fills) — exactly where matrix-free Mehrotra wins. So:
    ;;   qc-free + sparse        → OSQP (fast, proven)
    ;;   dense hubs (sector I-O) → Mehrotra primal-dual (matrix-free, ~5 iters where OSQP is intractable)
    ;;   qc present / no OSQP    → primal native-c (with its OSQP-stall fallback)
    (else (let ((C (flatten forms)))
            (format (current-error-port) "  [solve door] auto: qc-free=~a precond=~a osqp=~a frag=~a~%"
                    (qc-free? forms) (auto-precond C) (osqp-available?) (and (find (lambda (f) (eq? (f-kind f) 'frag)) forms) #t))
            (cond
              ((and (qc-free? forms) (eq? (auto-precond C) 'jacobi))
               (let ((xf (ensure-feasible forms labform x0 solve-native-c-core)))
                 (call-with-values (lambda () (solve-native-c-pd forms labform xf))
                   (lambda (x its mu yv)
           (call-with-values
               (lambda ()
                 (certified (lambda () (values x *kern-tmin* 0 its #t)) forms labform
                            #:dual yv #:measured-mu mu
                            #:fallback (lambda () (solve-native-c forms labform x0 tstart))))
             (lambda a (apply values a)))))))
              ;; OSQP as the PRIMARY backend, under the same exclusion the fallback
              ;; uses. It has no log-barrier, so a `frag` term becomes a hard cap AT
              ;; its tip instead of a pull felt before it — an ecological limit ridden
              ;; to the wall and reported met. Excluding it only in the fallback left
              ;; this branch open, which is the branch a qc-free sparse economy
              ;; actually takes; a fragility-carrying plan went straight through it.
              ((and (osqp-available?) (qc-free? forms)
                    (not (find (lambda (f) (eq? (f-kind f) 'frag)) forms)))
               ;; and it carries NO certificate — say so, rather than leaving the box
               ;; holding the previous solve's gap, which reads as a proof of this one
               (certified (lambda () (solve-osqp forms labform (vector-length x0) x0))
                          forms labform))
              (else (certified (lambda () (solve-native-c forms labform x0 tstart)) forms labform)))))))

;; ════════════════════════════════════════════════════════════════════════════
;; §7 — REPORTING: fill fractions and the self-test
;; ════════════════════════════════════════════════════════════════════════════

(define (mean-fill C x)                     ; mean delivered/asked over the WANTS — a des term or a citizen's own want on its cap (cask)
  (let ((sv (term-values C x)) (nt (cnt C)) (sum 0.0) (nd 0))
    (do ((ti 0 (+ ti 1))) ((= ti nt))
      (let ((ask (vector-ref (cask C) ti)))
        (when (> ask 0.0)
          (set! nd (+ nd 1)) (set! sum (+ sum (max 0.0 (min 1.0 (/ (vector-ref sv ti) ask))))))))
    (if (> nd 0) (/ sum nd) 1.0)))

;; MEAN-FILL IS BLIND ABOVE THE TARGET — it clamps each good's fill at 1, which is
;; right for an average of need-met (a glut of bread must not paper over a shortage
;; of medicine) and wrong as the ONLY number reported, because then no figure in
;; the system can express making MORE than anyone asked for. Every headline stayed
;; at 99.98% through a plan running 2.15× the activity it needed
;; (tests/solve/test-centering-floor.scm). These two are its uncapped companions:
;; report them beside it, never instead of it.
(define (mean-overfill C x)                 ; mean max(0, delivered/demand − 1) — what mean-fill clamps away
  (let ((sv (term-values C x)) (nt (cnt C)) (sum 0.0) (nd 0))
    (do ((ti 0 (+ ti 1))) ((= ti nt))
      (let ((ask (vector-ref (cask C) ti)))
        (when (> ask 0.0)
          (set! nd (+ nd 1))
          (set! sum (+ sum (max 0.0 (- (/ (vector-ref sv ti) ask) 1.0)))))))
    (if (> nd 0) (/ sum nd) 0.0)))

(define (labour-intensity labform x)        ; hours committed by the plan — the thing surplus wastes
  (fold (lambda (ic a) (+ a (* (cdr ic) (vector-ref x (car ic))))) 0.0 labform))

(define (fill-report C labform x)
  "The three numbers that must be read together: what share of need is met, how
   far the plan OVERSHOOTS it, and what labour it commits to do so. A plan can
   look perfect on the first and be badly wrong on the other two."
  `((met       . ,(* 100.0 (mean-fill C x)))
    (overshoot . ,(* 100.0 (mean-overfill C x)))
    (labour    . ,(labour-intensity labform x))))

(define (self-test)
  ;; one activity makes good g0 at 1h labour; want 10, labour caps x≤5 → 50% met.
  (let* ((forms (list (mk-bar 0.0 '((0 . 1.0)))                       ; balance g0 ≥ 0
                      (mk-des (mk-bar 0.0 '((0 . 1.0))) 10.0 1000.0)  ; demand g0 = 10
                      (mk-bar 5.0 '((0 . -1.0)))                      ; labour: x ≤ 5
                      (mk-bar 0.0 '((0 . 1.0)))))                     ; x ≥ 0
         (labform '((0 . 1.0))) (x0 (vector 0.5)) (C (flatten forms)))
    (format #t "~%==== §4 PARITY: native interior-point vs OSQP (sparse QP, FFI) ====~%")
    (call-with-values (lambda () (solve-native forms labform x0))
      (lambda (xn t cg nt2) (format #t "  native: x=~,4f  delivered ~,2f  met ~,1f%~%" (vector-ref xn 0) (vector-ref xn 0) (* 100 (mean-fill C xn)))))
    (if (osqp-available?)
        (call-with-values (lambda () (solve-osqp forms labform 1))
          (lambda (xo . _) (format #t "  osqp:   x=~,4f  delivered ~,2f  met ~,1f%~%" (vector-ref xo 0) (vector-ref xo 0) (* 100 (mean-fill C xo)))))
        (format #t "  osqp:   (libosqp not found — native-only)~%"))
    (format #t "  expect x≈5.0, 50% met from both~%")))


