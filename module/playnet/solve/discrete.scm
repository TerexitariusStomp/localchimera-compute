;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/solve/discrete.scm — §7: the discrete layer, minimum-batch and whole-count acts decided.
;;;
;;; The ONE genuinely non-convex thing in the solve, non-convex because the
;;; WORLD is: a mill that must run at ≥ L or not at all cannot run at L/2, and
;;; an act that is counted runs a whole number of times. Everything else the
;;; plan chooses stays inside the convex program the engine (solve/engine)
;;; builds; this module decides the declared columns over that program by
;;; branch-and-bound (`solve-discrete`), one tree, one certificate, two kinds
;;; of cut, and reads a decided column back as a FACT the builders see through
;;; the engine's `col-value`. `located-solve` is the engine's located solve
;;; with the decided columns substituted; `located-bill` the same solve read
;;; for its bill. The report of a decided solve is the report's
;;; `report-discrete` (solve/report).

(define-module (playnet solve discrete)
  #:use-module ((playnet utils host) #:select (getenv))
  #:use-module (playnet solve world)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils catch) #:select (catch* throw* with-throw-handler*))
  #:use-module (ice-9 format)
  #:use-module (playnet solve solver)
  #:use-module (playnet solve engine)
  #:export (solve-discrete located-solve located-bill node-solve node-fractional relaxed-bound
            discrete-certificate discrete-declared? decided-state search-state restore-search-state! substitute-fixed
            solution-cost cost-of-config batch-keys *bnb-nodes* *discrete-key?* *discrete-program*))

;; κ-weighted labour of the columns that left. Their work is still done, so it
;; still counts — dropping it would make a node with a decided act look cheaper
;; than the same node with it relaxed, and the search would chase the artefact.
(define *fixed-labour* 0.0)

;; This is the ONE genuinely non-convex thing in the engine, and it is non-convex
;; because the WORLD is: a mill that must run at ≥ L or not at all cannot run at
;; L/2, and no formulation makes that go away. Everything else the planner chooses
;; — including which recipe makes a good — stays inside the convex program, because
;; recipes are not mutually exclusive: two mills are two columns and the plan may
;; run both. (An early prototype made recipe choice look discrete by collapsing
;; each spec to one recipe's scalar coefficients; that was an artefact of its own
;; formulation, not of the problem.)
;;
;; Handled by BRANCH-AND-BOUND, whose soundness is the convex certificate: a
;; node's bound is a relaxation's VALUE, what a solver returns is where it
;; stopped, and subtracting the certified gap is what licenses discarding a
;; subtree. An exhausted tree is a certified global optimum. Measured on a fixture
;; where every column is fractional, nodes grow ~1.5B against 2^B configurations
;; (B = 12: 19 nodes of 4096, 99.5% pruned) — so the node budget is never the
;; limit; the per-node convex solve is.
(define (solution-cost x forms labform)      ; true −harmony: desire penalty + κ free time (barriers→0)
  (let ((C (flatten forms)))
    (+ (* *kappa* *fixed-labour*)            ; the decided columns' work, still done
       (fold (lambda (ic a) (+ a (* *kappa* (cdr ic) (vector-ref x (car ic))))) 0.0 labform)
       (let ((sv (term-values C x)) (nt (cnt C)) (acc 0.0))
         (do ((ti 0 (+ ti 1))) ((= ti nt) acc)
           (when (= (vector-ref (ckind C) ti) 1)
             (let ((s (vector-ref sv ti)) (Dd (vector-ref (cD C) ti)) (ww (vector-ref (cw C) ti)))
               (when (< s Dd) (set! acc (+ acc (* ww (expt (/ (- Dd s) Dd) 2))))))))))))
;; The discrete layer builds and solves DIRECTLY instead of going through
;; `solve-located`. That name is SHADOWED by the test prelude with a two-value
;; version, and a search whose bounds depend on which definition is in scope is
;; not a search — it is a coin flip that happens to land right in the demos. Same
;; three lines either way, and now they mean one thing everywhere.
(define (substitute-fixed forms labform ncol cols idx x0)
  "Take the decided columns out of the program, into the constants.

   → (values forms* labform* idx* x0*), with every fixed column's contribution
   folded in as coeff·n and the remaining columns renumbered to close the gaps.
   A form's SHAPE is untouched: this reads only `const` and `coeffs`, which every
   kind shares, so it cannot miss one and needs nothing from either backend.

   Renumbering rather than leaving the column inert: a variable appearing in no
   form and no objective term is an unconstrained direction, and the Newton system
   would be singular along it.

   WHAT A DECISION IMPLIES IS DECIDED TOO. A fixed count can leave another column
   with no room: a mover fixed away from a cell leaves that cell's service gated
   at 0 ≤ x ≤ 0, a ride fixed at 1 against `departures ≤ 1` sits on its own wall.
   No barrier holds a point with no interior (§7), so a column whose single-
   coefficient bounds meet is a fact as much as the count that made it one, and
   it leaves with the count — to a fixpoint. It is recorded in `*col-fixed*`, so
   `col-value` reads it back. A wall left with no variables states nothing about
   the plan and is dropped; one left VIOLATED says the node has no plan, and says
   so by raising — which the search reads as +inf. A want left with no variables
   stays, as the constant it is."
  (set! *fixed-labour* 0.0)
  (let ((fx (make-hash-table)) (any? #f)
        (key-of (let ((h (make-hash-table))) (hash-for-each (lambda (k j) (hash-set! h j k)) idx) h)))
    (for-each (lambda (c)
                (let* ((k (col-key c)) (n (col-fixed k)) (j (hash-ref idx k #f)))
                  (when (and n j) (hash-set! fx j (exact->inexact n)) (set! any? #t))))
              cols)
    ;; Was anything DECIDED before this presolve ran — a fixing or a cut? Then a
    ;; column the propagation leaves no value is the decision's doing, and the
    ;; node has no plan (raised; the search reads +inf). With nothing decided the
    ;; same finding is the program's own infeasibility, and that verdict is the
    ;; solver's to give as it always has (feasible? #f): the program is returned
    ;; untouched.
    (define decided? (or any? (> (hash-count (const #t) *col-bounds*) 0)))
    (define plain-infeasible? #f)
    (define derived '())                      ; the keys this presolve fixed — withdrawn if the program is returned untouched
    ;; the fixpoint: bounds implied on the remaining columns by the fixed ones.
    ;; BOUND PROPAGATION over every wall: a bar `const + Σ aᵢxᵢ ≥ 0` bounds each
    ;; of its variables by the others' known bounds — xⱼ ≤ (const + Σᵢ≠ⱼ aᵢ·x̄ᵢ)/(−aⱼ)
    ;; for aⱼ < 0, xⱼ ≥ (−const − Σᵢ≠ⱼ aᵢ·x̄ᵢ)/aⱼ for aⱼ > 0, where x̄ᵢ is the
    ;; bound of xᵢ that loosens the sum most (its ceiling under a positive
    ;; coefficient, its floor under a negative one; every column's floor is 0 by
    ;; build). Passes repeat while a bound moves. This is what reads a cell with
    ;; two ways out — `1 − r₁ − r₂ ≥ 0` under a cut r₁ ≥ 1 — as r₂ = 0 and r₁ = 1,
    ;; which a single-variable reading only sees with one way out.
    (define (implied-fixings!)
      (let ((lo (make-hash-table)) (hi (make-hash-table)) (found #f)
            (bars (filter-map                        ; each bar with its fixed columns folded into const
                   (lambda (f0)
                     (let ((f (form-body f0)))
                       (and (eq? (f-kind f) 'bar)
                            (let loop ((cs (f-coeffs f)) (const (f-const f)) (live '()))
                              (if (pair? cs)
                                  (let* ((j (caar cs)) (v (cdar cs)) (n (hash-ref fx j #f)))
                                    (if n (loop (cdr cs) (+ const (* v n)) live)
                                        (loop (cdr cs) const (if (= 0.0 v) live (cons (car cs) live)))))
                                  (and (pair? live) (cons const live)))))))
                   forms)))
        (define (lo-of j) (max 0.0 (hash-ref lo j -inf.0)))
        (define (hi-of j) (hash-ref hi j +inf.0))
        (define (loosest ic)                          ; aᵢ·x̄ᵢ — the term at its loosest, +inf when unbounded
          (let ((a (cdr ic))) (if (> a 0.0) (* a (hi-of (car ic))) (* a (lo-of (car ic))))))
        (let pass ((n 0))
          (let ((moved #f))
            (for-each
             (lambda (bar)
               (let ((const (car bar)) (live (cdr bar)))
                 (for-each
                  (lambda (jc)
                    (let* ((j (car jc)) (a (cdr jc))
                           (rest (fold (lambda (ic acc) (if (eq? ic jc) acc (+ acc (loosest ic)))) 0.0 live)))
                      (when (< rest +inf.0)         ; every other term bounded ⇒ this one is
                        (if (> a 0.0)
                            (let ((b (/ (- (+ const rest)) a)))
                              (when (> b (+ (lo-of j) 1e-9)) (hash-set! lo j b) (set! moved #t)))
                            (let ((b (/ (+ const rest) (- a))))
                              (when (< b (- (hi-of j) 1e-9)) (hash-set! hi j b) (set! moved #t)))))))
                  live)))
             bars)
            (when (and moved (< n 50)) (pass (+ n 1)))))
        (hash-for-each
         (lambda (j h)
           (let ((l (lo-of j)))
             (cond ((< h (- l 1e-7))
                    (if decided?
                        (raise-starvation
                         "substitute-fixed: a decided count leaves this column no value"
                         (hash-ref key-of j j) l h)
                        (set! plain-infeasible? #t)))
                   ((and (<= (- h l) 1e-7) (not (hash-ref fx j #f)))
                    (hash-set! fx j l) (set! found #t) (set! any? #t)
                    (let ((k (hash-ref key-of j #f)))
                      (when k (set! derived (cons k derived))
                            (hash-set! *col-fixed* k (if (< (abs (- l (round l))) 1e-7)
                                                         (inexact->exact (round l)) l))))))))
         hi)
        (when (and found (not plain-infeasible?)) (implied-fixings!))))
    (implied-fixings!)
    (when plain-infeasible?                    ; the solver's verdict, not this presolve's: nothing derived stands
      (for-each (lambda (k) (hash-remove! *col-fixed* k)) derived))
    (if (or (not any?) plain-infeasible?)
        (values forms labform idx x0)
        (let ((remap (make-vector ncol -1)) (n* 0))
          (do ((j 0 (+ j 1))) ((= j ncol))
            (unless (hash-ref fx j #f) (vector-set! remap j n*) (set! n* (+ n* 1))))
          (letrec ((rewrite
                    (lambda (f)
                      (if (method-form? f)
                          (let ((b (rewrite (form-body f)))) (and b (mk-method b)))
                          (let loop ((cs (f-coeffs f)) (const (f-const f)) (acc '()))
                            (if (null? cs)
                                (if (and (null? acc) (memq (f-kind f) '(bar frag held)))
                                    ;; a WALL with no variable left is a fact about the plan,
                                    ;; not a form of it: satisfied, it says nothing (and a
                                    ;; barrier on a constant is log(0) waiting to happen);
                                    ;; violated, the node has no plan. A WANT with no variable
                                    ;; left stays: its shortfall is a constant of the objective,
                                    ;; and dropping it would make the decided plan read cheaper
                                    ;; than the relaxation that led to it.
                                    (begin
                                      (when (< const -1e-7)
                                        (error "substitute-fixed: a decided count violates a limit by" (- const)))
                                      #f)
                                    (cons (f-kind f) (cons const (cons (reverse acc) (cdddr f)))))
                                (let* ((ic (car cs)) (j (car ic)) (v (cdr ic))
                                       (n (hash-ref fx j #f)))
                                  (if n
                                      (loop (cdr cs) (+ const (* v n)) acc)      ; a fact, into const
                                      (loop (cdr cs) const
                                            (cons (cons (vector-ref remap j) v) acc))))))))))
            (let ((forms* (filter-map rewrite forms))
                  (labform*
                   (filter-map (lambda (ic)
                                 (let ((n (hash-ref fx (car ic) #f)))
                                   (if n
                                       (begin (set! *fixed-labour*
                                                    (+ *fixed-labour* (* (cdr ic) n)))
                                              #f)
                                       (cons (vector-ref remap (car ic)) (cdr ic)))))
                               labform))
                  (idx* (make-hash-table))
                  (x0* (make-vector n* 0.05)))
              (hash-for-each (lambda (k j)
                               (when (and (integer? j) (>= j 0) (< j ncol)
                                          (not (hash-ref fx j #f)))
                                 (hash-set! idx* k (vector-ref remap j))))
                             idx)
              (do ((j 0 (+ j 1))) ((= j ncol))
                (unless (hash-ref fx j #f)
                  (vector-set! x0* (vector-ref remap j) (vector-ref x0 j))))
              (values forms* labform* idx* x0*)))))))


(define (located-solve*)                      ; → (values x forms labform idx cols)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (call-with-values
          (lambda () (substitute-fixed forms labform ncol cols idx (located-warm cols ncol idx)))
        (lambda (forms* labform* idx* x0*)
          ;; THIS solve's verdict, not the last one's: a backend that publishes
          ;; nothing leaves `unknown`, which `node-cost` reads as a plan
          (set-last-certificate! '((feasible? . unknown)))
          (call-with-values (lambda () (solve forms* labform* x0*))
            (lambda (x . _) (values x forms* labform* idx* cols))))))))
(define (located-solve)                       ; → (values x forms labform idx)
  (call-with-values located-solve* (lambda (x forms labform idx cols) (values x forms labform idx))))
;; The same solve read for its BILL: what the acquire columns bought (*acquire*),
;; and whether the point is a plan. → (list bill-rows feasible?)
(define (located-bill)
  (call-with-values located-solve*
    (lambda (x forms labform idx cols)
      (list (assq-ref (acquire-bill x cols idx) 'bill)
            (not (eq? #f (assq-ref (certificate-of-last-solve) 'feasible?)))))))
;; The cost of the point a node's solve stopped at, or +inf when that point is
;; no plan. A backend that finds no feasible point either RAISES (the native
;; path) or publishes `feasible? #f` and returns its phase-I point (the compiled
;; one) — a vector shaped like a plan that draws stock nobody has. Read either
;; way, an impossible branch costs infinity: it prunes, and it can never become
;; the incumbent.
(define (node-cost x forms labform)
  (if (eq? #f (assq-ref (certificate-of-last-solve) 'feasible?))
      +inf.0
      (solution-cost x forms labform)))
(define* (cost-of-config cfg #:optional (bnds '()) (fix '()))  ; an EXACT config: every floor enforced
  (hash-clear! *mbq-relaxed*)
  (set! *config* cfg)
  (with-col-bounds! bnds)
  (with-col-fixed! fix)
  ;; A CONFIG is always feasible, but a whole-count cut need not be: "run this at
  ;; least once" can exceed what the cell can supply. An impossible branch costs
  ;; infinity, which prunes it — it is not an error in the plan.
  (catch* #t
    (lambda ()
      (call-with-values (*discrete-program*)
        (lambda (x forms labform idx) (node-cost x forms labform))))
    (lambda args (when (getenv "PLANNER_BNB_TRACE") (format (current-error-port) "  [bnb] node raised: ~s~%" args)) +inf.0)))
;; ── the search is generic over WHICH program it runs on ──────────────────────
;; Two parameters make the tree reusable by any assembly that builds through
;; build-located: WHICH keys it may decide, and WHAT it solves at a node.
;;   *discrete-key?*     column-key → may the search branch on it? The located
;;                       solve decides every declared column; a two-stage
;;                       (robust) solve decides the FIRST-STAGE ones and keeps
;;                       recourse relaxed — integer first stage, continuous
;;                       recourse, the standard shape of stochastic programming.
;;   *discrete-program*  thunk → (values x forms labform idx): build the current
;;                       program under the search's tables (config, relaxed
;;                       floors, cuts, fixings), substitute the decided columns
;;                       out, solve. `located-solve` for one world; solve/robust.scm
;;                       supplies the extensive form.
(define *discrete-key?* (make-parameter (lambda (k) #t)))
(define *discrete-program* (make-parameter (lambda () (located-solve))))
(define (batch-keys)
  (hash-clear! *mbq-relaxed*)
  (set! *config* 'all)
  (filter-map (lambda (c) (and (mbq-of (col-key c)) ((*discrete-key?*) (col-key c)) (col-key c))) (build-columns)))
(define (whole-keys)                       ; the columns a whole count decides, in THIS build
  (filter-map (lambda (c) (and (whole-col? (col-key c)) ((*discrete-key?*) (col-key c)) (col-key c))) (build-columns)))
;; The search's tables, as one value — so an assembly that declares a fresh world
;; while building (one block per scenario) can put them back before it builds.
(define (search-state)
  (list *config* (hash-map->list cons *mbq-relaxed*) (hash-map->list cons *col-bounds*) (hash-map->list cons *col-fixed*)))
(define (restore-search-state! st)
  (set! *config* (car st))
  (hash-clear! *mbq-relaxed*) (for-each (lambda (kv) (hash-set! *mbq-relaxed* (car kv) (cdr kv))) (cadr st))
  (with-col-bounds! (caddr st))
  (with-col-fixed! (cadddr st)))
;; relaxation lower bound: drop every MBQ (batch cols become ordinary x≥0 columns)
(define (relaxed-bound keys)
  (let ((saved (hash-map->list cons *mbq-procs*)))
    (hash-clear! *mbq-procs*)                 ; no MBQ ⇒ convex relaxation
    (let ((lb (cost-of-config 'all)))
      (for-each (lambda (kv) (hash-set! *mbq-procs* (car kv) (cdr kv))) saved)
      lb)))

;; ════════════════════════════════════════════════════════════════════════════
;; BRANCH-AND-BOUND over the batch columns — search, not sampling
;; ════════════════════════════════════════════════════════════════════════════
;; A PERSPECTIVE reformulation buys nothing on this program, and it is worth
;; recording why, because the shape it needs is one we nearly have. Perspective
;; relaxation is tight when a semi-continuous variable carries a SETUP CHARGE or
;; a strictly convex on-cost; it then replaces g(x) by the closure of z·g(x/z),
;; the convex hull of the discontinuous cost. Here the per-column cost is LINEAR
;; (κ·c·x, see `labform`) and there is no fixed charge, so the hull of the cost
;; is the cost, and conv({0} ∪ [L,U]) = [0,U] — precisely what `relaxed-bound`
;; already gets by deleting the floor. The strictly convex part of the objective
;; is the DESIRE term, which is a function of aggregate slacks and so is not
;; separable per column; no per-variable hull argument reaches it.
;;
;; So the relaxation is already the tightest convex one available, and tightness
;; has to come from BRANCHING. A column the relaxation runs at 0 < x < L is
;; infeasible for every config, so split on it — x = 0 against x ≥ L — and
;; recurse. Both children are ordinary convex programs of the kind already
;; solved, and the parent's value bounds both.
;;
;; WHAT MAKES THE PRUNING SOUND. A node's bound is the value of a relaxation, and
;; we do not have that value — we have `solution-cost` at the point the solver
;; stopped, which is ABOVE it. Pruning on a bound that is too high discards the
;; optimum. The certificate closes exactly this: f(x) − f(x*) ≤ gap-bound over
;; the same f (`kkt-report` builds ∇f at barrier weight 0, so its objective is
;; desire + κ·labour, which is what `solution-cost` evaluates), hence
;;
;;     node lower bound  =  solution-cost(x) − gap-bound
;;
;; is valid. Where the certificate is +inf the node simply does not prune, and
;; says so, rather than pruning on a number it cannot justify. The convex
;; certificate is not adjacent to the discrete layer; it is what licenses it.
;; Node budget. NOT the practical limit and not tuned as one — it is a
;; runaway-loop backstop. Measured on a fixture where every column is fractional
;; (bench-discrete.scm), nodes grow ~1.5B against 2^B configurations: B = 12 uses
;; 19 nodes of 4096 configurations, 99.5% pruned, certified global, 6 s. At that
;; growth 400 nodes corresponds to B in the hundreds, which no one will reach,
;; because each node is a full convex solve and the program grows with the
;; horizon. What ends certified discrete planning is the per-node solve, not the
;; search. A scope that wants a tighter or wider budget states it (#:node-budget
;; on plan-from-records / plan-scope — a governed number like tau or hold); the
;; certificate carries `budget` beside `nodes`, so a plan whose search stopped
;; at the budget says so and how far it stopped short (`gap`).
(define *bnb-nodes* (make-parameter 400))   ; a scope may set its own (#:node-budget); the certificate says when it bound
(define *mbq-int-tol* 1e-3)              ; relative: within tol·L of an end reads as integral

(define (collapse-fixings bnds)
  "A range admitting exactly ONE value IS that value: a window whose two ends
   are equal — the batch branch's [L,L], L fractional by design (80 kg over
   30 a run) — and a window admitting exactly one integer both collapse.

   This is what makes the tree finite in a barrier method: narrowing to [3,3]
   leaves no interior to solve in, so at that point the column stops being
   bounded and becomes a fact instead."
  (filter-map (lambda (kv)
                (let* ((lo (cadr kv)) (hi (cddr kv))
                       (l (and lo (inexact->exact (ceiling lo))))
                       (h (and hi (inexact->exact (floor hi)))))
                  (cond ((and lo hi (= lo hi))
                         (cons (car kv) (if (and l (= l lo)) l lo)))
                        ((and l h (= l h)) (cons (car kv) l))
                        (else #f))))
              bnds))

(define* (node-solve on free #:optional (bnds '()))  ; ON keeps its floor, FREE drops it, rest absent
  (hash-clear! *mbq-relaxed*)
  (for-each (lambda (k) (hash-set! *mbq-relaxed* k #t)) free)
  (set! *config* on)
  (with-col-bounds! bnds)                ; the branch cuts, as METHOD tensions
  (with-col-fixed! (collapse-fixings bnds))
  (catch* #t
    (lambda ()
      (call-with-values (*discrete-program*)
        (lambda (x forms labform idx)
          (let* ((cost (node-cost x forms labform))
                 (gap  (or (assq-ref (certificate-of-last-solve) 'gap-bound) +inf.0))
                 (lb   (if (< gap +inf.0) (- cost gap) -inf.0)))   ; unjustified ⇒ never prunes
            (list lb cost x idx)))))
    ;; a cut with no feasible point closes its whole subtree
    (lambda _ (list +inf.0 +inf.0 #f #f))))

(define *whole-int-tol* 1e-4)            ; a barrier method stops NEAR an integer, never on it
(define (node-whole-fractional x idx)    ; whole-count columns the relaxation split
  (sort (filter-map
          (lambda (kv)
            (let ((k (car kv)) (j (cdr kv)))
              (and (string? k) (whole-col? k) ((*discrete-key?*) k) (integer? j) (not (col-fixed k))
                   (let* ((v (vector-ref x j))
                          (e (* *whole-int-tol* (max 1.0 (abs v))))   ; scale-free, as MBQ's is
                          (f (- v (floor v))))
                     (and (> f e) (< f (- 1.0 e))
                          (cons k (min f (- 1.0 f))))))))          ; distance to the nearer integer
          (hash-map->list cons idx))
        (lambda (a b) (> (cdr a) (cdr b)))))                       ; most fractional first

(define (tighten-bound bnds k lo hi)     ; narrow K's box; either end #f leaves it alone
  (let* ((cur (or (assoc-ref bnds k) '(#f . #f)))
         (lo* (cond ((not lo) (car cur)) ((car cur) (max (car cur) lo)) (else lo)))
         (hi* (cond ((not hi) (cdr cur)) ((cdr cur) (min (cdr cur) hi)) (else hi))))
    (cons (cons k (cons lo* hi*))
          (filter (lambda (kv) (not (equal? (car kv) k))) bnds))))

(define (node-fractional free x idx)     ; keys the relaxation runs strictly between 0 and L
  (sort (filter-map
          (lambda (k)
            (let* ((j (hash-ref idx k #f)) (L (or (mbq-floor k) 0.0))
                   (v (if j (vector-ref x j) 0.0)) (e (* *mbq-int-tol* (max 1.0 L))))
              (and j (> L 0.0) (> v e) (< v (- L e))
                   (cons k (min v (- L v))))))          ; distance to the nearer end
          free)
        (lambda (a b) (> (cdr a) (cdr b)))))            ; most fractional first

(define* (solve-discrete #:key (seed #f))   ; → (values best-cfg certified? lower-bound best-cost nkeys nodes)
  ;; SEED is a standing plan's `decided` state — its config, cuts and fixings, as
  ;; `decided-state` reads them off a finished search. Offered FIRST: it is a
  ;; restriction of the program, so its exact cost is a valid upper bound, and
  ;; when the world has barely moved it is the optimum or next to it, so the
  ;; tree prunes from the root. A key it names that this build lacks is simply
  ;; absent; a batch column new to this build reads OFF under it — still a bound,
  ;; only a looser one. This is warm-x's twin for the discrete half of a plan.
  (let* ((keys (batch-keys)) (k (length keys))
         (inc +inf.0) (inc-cfg 'all) (inc-bnds '()) (inc-fix '()) (used 0) (root-lb -inf.0))
    ;; Any config is FEASIBLE, so its exact cost is a valid upper bound. Seeding
    ;; with all-on and all-off costs two solves and buys pruning from the root.
    (define* (offer cfg #:optional (b '()) (fx '()))
      ;; An incumbent is only ever read off a SUBSTITUTED program, so the plan it
      ;; names is integral by construction rather than by rounding — which is why
      ;; the answer never depends on the integrality tolerance.
      (let ((c (cost-of-config cfg b fx)))
        (when (< c inc)
          (set! inc c) (set! inc-cfg cfg) (set! inc-bnds b) (set! inc-fix fx))))
    ;; THE TABLES THE SOLVE BELOW READS ARE THE INCUMBENT'S PROGRAM — all four
    ;; of them. *config* and *mbq-relaxed* hold whatever node or offer priced
    ;; LAST, and a search that ends right after pricing a losing config would
    ;; otherwise hand the caller that config's program: measured on one batch
    ;; mill (demand past the relaxation's split, ON the certified optimum at
    ;; cost 0.16), the OFF leaf priced last, the plan built OFF, and the
    ;; certificate's cost stood beside runs = 0, fill = 0. `decided-state`
    ;; reads *config* through here too, so the standing plan records what won.
    (define (leave!)
      (hash-clear! *mbq-relaxed*)
      (set! *config* inc-cfg)
      (with-col-bounds! inc-bnds) (with-col-fixed! inc-fix))
    ;; Whole counts are the OTHER kind of discreteness, so a scope with no batch
    ;; column may still have a tree to search.
    (if (and (null? keys) (= 0 (hash-count (const #t) *whole-procs*)))
        (let ((c (cost-of-config 'all))) (values 'all #t c c 0 0))
        (begin
          ;; An incumbent must be INTEGRAL, and a seed is one only when its fixings
          ;; decide every whole column of this build — a world that grew a new
          ;; theatre since the plan stood would otherwise seed the relaxation of
          ;; that theatre as a "decided" plan. Such a seed is declined whole; the
          ;; tree finds its own.
          (when (and seed (list? seed))
            (let ((fixed (or (assq-ref seed 'fixed) '())))
              (when (every (lambda (k) (assoc k fixed)) (whole-keys))
                (offer (or (assq-ref seed 'config) 'all)
                       (or (assq-ref seed 'cuts) '())
                       fixed))))
          ;; a standing decision that priced finite IS the incumbent; the two
          ;; blind seeds are for a search that starts from nothing
          (unless (or (null? keys) (< inc +inf.0)) (offer keys) (offer '()))
          (let loop ((open (list (list -inf.0 '() keys '()))))
            (cond
             ;; every node either pruned or resolved: the incumbent IS the optimum
             ((null? open) (leave!)
              (values inc-cfg #t root-lb inc k used))
             ((>= used (*bnb-nodes*))
              (leave!)
              (values inc-cfg #f (fold (lambda (n a) (min a (car n))) inc open) inc k used))
             ;; PRUNE BEFORE SOLVING: a node carries its parent's certified bound,
             ;; and a child is a restriction, so a stored bound the incumbent
             ;; already meets closes the node for free. This is where a good
             ;; incumbent — a standing plan's decision, handed back — pays: the
             ;; subtrees it beats are never solved at all.
             ((>= (car (car (sort open (lambda (a b) (< (car a) (car b)))))) inc)
              (leave!)
              (values inc-cfg #t root-lb inc k used))       ; best-first: the best open bound meets it ⇒ all do
             (else
              (let* ((open (sort open (lambda (a b) (< (car a) (car b)))))   ; best-first
                     (nd (car open)) (rest (cdr open))
                     (on (cadr nd)) (free (caddr nd)) (bnds (cadddr nd))
                     (r (node-solve on free bnds))
                     (lb (car r)) (x (caddr r)) (idx (cadddr r)))
                (set! used (+ used 1))
                (when (getenv "PLANNER_BNB_TRACE")     ; the tree, node by node, on stderr
                  (format (current-error-port) "  [bnb ~a] lb ~,4f inc ~,4f on ~a cuts ~a~%" used lb inc on bnds))
                (when (= used 1) (set! root-lb lb))
                (cond
                 ((>= lb inc) (loop rest))                     ; PRUNE — cannot beat the incumbent
                 (else
                  (let ((frac (node-fractional free x idx)))
                    (if (pair? frac)
                        (let ((bk (caar frac)) (L (mbq-floor (caar frac))))
                          ;; child bounds start at the parent's — valid, since a child
                          ;; is a restriction — which is what best-first orders on.
                          ;; THREE children: OFF, x = L as a FACT (a [L,L] window
                          ;; `collapse-fixings` substitutes out, L fractional or
                          ;; not), and x ≥ L. The ON floor is a real wall, and on
                          ;; a column whose feasible maximum IS L — a stock of
                          ;; exactly L runs' draw — it leaves a program with no
                          ;; interior, whose barrier answer is undefined; the
                          ;; face child reaches that optimum through substitution,
                          ;; the whole-count branch below reaches its faces the
                          ;; same way, and the ON child keeps everything above L.
                          (loop (cons (list lb (cons bk on) (delete bk free) bnds)   ; x ≥ L
                                      (cons (list lb (cons bk on) (delete bk free)
                                                  (tighten-bound bnds bk L L))       ; x = L, a fact
                                            (cons (list lb on (delete bk free) bnds) ; x = 0
                                                  rest)))))
                        ;; every batch column settled; now the whole counts, cut on
                        ;; the same tree against the same certificate. THREE
                        ;; children, not two: x ≤ ⌊v⌋, x = ⌈v⌉ (a FACT — collapsed
                        ;; by `collapse-fixings` and substituted out, so no barrier
                        ;; has to hold it), x ≥ ⌈v⌉+1 — the same integers the two
                        ;; cuts ≤⌊v⌋ | ≥⌈v⌉ cover, partitioned so the face is its
                        ;; own child. A one-sided cut x ≥ ⌈v⌉ on a column whose
                        ;; feasible maximum IS ⌈v⌉ leaves a feasible set with no
                        ;; interior — the header above says it of [3,3], and a
                        ;; one-sided cut meeting a wall is the same box — and what
                        ;; comes back is undefined: an unconverged escape, or a
                        ;; raise that read `+inf.0` here and CLOSED the subtree
                        ;; holding the optimum. Measured (worker-supply-capacity
                        ;; bug): one worker, 40h, four 9h whole-count units across
                        ;; four zero-distance cells — the relaxation serves all
                        ;; four at 1.0 exactly, the up-cut x₀ ≥ 1 dies on the face,
                        ;; and the search certified 3 of 4 (cost 1000.5 against
                        ;; the optimum's 0.72). The ≥ ⌈v⌉+1 child meets a wall of
                        ;; its own only to land in ITS middle child one level
                        ;; down, so every face is reached through a fixing.
                        (let ((wf (node-whole-fractional x idx)))
                          (if (pair? wf)
                              (let* ((bk (caar wf)) (v (vector-ref x (hash-ref idx bk))) (c (ceiling v)))
                                (loop (cons (list lb on free (tighten-bound bnds bk #f (floor v)))
                                            (cons (list lb on free (tighten-bound bnds bk c c))
                                                  (cons (list lb on free (tighten-bound bnds bk (+ c 1.0) #f))
                                                        rest)))))
                              ;; nothing fractional: read off the config and cost it exactly,
                              ;; so the incumbent never depends on the integrality tolerance
                              (begin (offer (append on (filter
                                                         (lambda (kk)
                                                           (let ((j (hash-ref idx kk #f)))
                                                             (and j (>= (vector-ref x j)
                                                                        (* 0.5 (or (mbq-floor kk) 0.0))))))
                                                         free))
                                            bnds
                                            ;; every whole column, decided — the ones
                                            ;; already substituted out are no longer in
                                            ;; `idx`, so they come from the cuts
                                            (append
                                             (collapse-fixings bnds)
                                             (filter-map
                                              (lambda (kv)
                                                (and (string? (car kv)) (whole-col? (car kv)) ((*discrete-key?*) (car kv))
                                                     (cons (car kv)
                                                           (inexact->exact
                                                            (round (vector-ref x (cdr kv)))))))
                                              (hash-map->list cons idx))))
                                     (loop rest))))))))))))))))
;; Is there anything to search? The two tables the recipes and the scope pour
;; into (ingest-located!) — the same test solve-discrete makes for itself.
(define (discrete-declared?)
  (or (> (hash-count (const #t) *mbq-procs*) 0)
      (> (hash-count (const #t) *whole-procs*) 0)))
;; The search's own verdict, as data beside the convex certificate. CERTIFIED
;; means the tree was exhausted — every config solved or provably unable to beat
;; the incumbent — so the discrete gap is 0 by search; `root-bound` is the root
;; relaxation, printed for scale. Uncertified means the node budget ran out and
;; the gap is genuine: cost − best open bound. `keys` counts the batch columns
;; (2^keys configurations); whole counts open the tree without adding a key.
(define (discrete-certificate r)
  (apply (lambda (cfg certified? lb cost k nodes)
           `((keys . ,k) (nodes . ,nodes) (budget . ,(*bnb-nodes*)) (certified? . ,certified?)
             (root-bound . ,lb) (cost . ,cost)
             (gap . ,(if certified? 0.0 (max 0.0 (- cost lb))))))
         r))
;; What the search DECIDED, as data a plan can carry and hand back: the incumbent
;; config, its cuts and its fixings — the three tables `solve-discrete` leaves in
;; place for the solve that follows. Read once, right after the search.
(define (decided-state)
  `((config . ,*config*)
    (cuts   . ,(hash-map->list cons *col-bounds*))
    (fixed  . ,(hash-map->list cons *col-fixed*))))
