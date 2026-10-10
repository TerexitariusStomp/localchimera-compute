;;; engine/robust.scm — robust multi-scenario planning over the located solver.
;;;
;;; Design: docs/planning/solve/robust-multiscenario.md. Phase-1 (raw forms) proved the
;;; mechanism; this is Phase-2: the SAME idea driven through the records pipeline,
;;; keyed by the VF-aligned <planning-scenario> record (schemas.scm).
;;;
;;; A two-stage stochastic program is NOT a new solver — it is a different
;;; ASSEMBLY of the forms `build-located` already emits:
;;;   • each scenario is built by `build-located` with its yields scaled → its own
;;;     forms over the SAME (structural, coefficient-independent) column layout;
;;;   • FIRST-STAGE columns (planting/allocation, named in #:first-stage-procs) are
;;;     SHARED — one global slot referenced by every scenario ⇒ non-anticipativity
;;;     is free (sharing the index IS the equality x⁽ˢ⁾ = x);
;;;   • RECOURSE columns get a private per-scenario slot;
;;;   • every wall — reproduction `bar` floors, eco `frag` barriers, `held`
;;;     margins — is kept per-scenario (ROBUST — hold in every future); `des`
;;;     desire + free-time are p-weighted (EXPECTED objective).
;;; The result is one larger — still convex — program, solved by `solve` unchanged.
;;;
;;; Loaded into the engine (uses build-located, ingest-records!, col-key,
;;; f-kind/f-const/f-coeffs/f-Dw, solve, and the schemas records).

;; ── the SHOCK ALGEBRA is its own module ─────────────────────────────────────
;; (playnet vf formulas shocks): the DSL's normal form, the one matcher a branch
;; binds to the build (branch-flow-factor, branch-avail-factor), the mean
;; behind the certainty-equivalent and the Observer's calibration, the
;; adverse direction, and the tail laid over the record. What stays here is
;; what reads or writes the engine's world.

;; the band-writable tables, as one ingest left them — copied once per
;; assembly, restored per branch (each branch pours its OWN bands over the
;; same pristine world; re-ingesting was how a branch used to get this)
(define (world-pristine)
  (define (copy h) (let ((c (make-hash-table))) (hash-for-each (lambda (k v) (hash-set! c k v)) h) c))
  (list (copy *init*) (copy *stretch-floor*) (copy *band*)))
(define (restore-pristine! p)
  (define (put! h c) (hash-clear! h) (hash-for-each (lambda (k v) (hash-set! h k v)) c))
  (put! *init* (car p)) (put! *stretch-floor* (cadr p)) (put! *band* (caddr p)))

;; ── the WORLD a scenario ingests ────────────────────────────────────────────
;; A scenario block differs from the base solve in its SHOCKS and in nothing else,
;; so every option that DESCRIBES THE WORLD has to reach it. Re-listing those
;; options by hand at each layer is what silently lost #:manners and #:arc-table:
;; a scope placed in a bioregion takes the robust branch, so for every shed the
;; mode vocabulary reached nothing and travel time fell back to rate×haversine no
;; matter what the routing table had learned. The three robust layers now forward
;; their whole keyword list verbatim, and this is the ONE place that says which of
;; those keywords ingest-records! understands.
(define %world-keywords
  '(#:periods #:movable #:storable #:tau #:hold #:demand #:eco-caps #:reserve
    #:backend #:eco-frag #:eco-spec-frag #:eco-budget #:eco-container #:eco-couple
    #:couplings
    #:eco-prior #:stock-frag #:stock-prices #:agent-hours #:agent-skills #:agent-position
    #:horizon #:period-spans #:willing? #:legal-forbids? #:legal-decorate #:per-agent?
    #:desire-weights #:arc-table #:arc-topology? #:manners #:never-raw #:raws
    #:resource-suppliers #:specs #:span-of #:whole #:proc-frag
    #:certificates                   ; each citizen's drawable credit — a fact about the world, the bar over their claims
    #:live-avail                     ; the registry's reservations: a registered resource ingests at what is free of them
    #:refine-periods?))              ; whether the partition refines at the roster's clock boundaries

;; ingest-records! reads two world keywords a scenario does not take. Each switches on an
;; engine mode the live solve has never run, and each moves plans that stand today, so
;; each waits on a decision of its own. Measured 2026-10-09, each forwarded alone, after
;; the skill reading became the worked spec's (formulas/actions labour-specs):
;;   #:skill-dynamics  practice laws that make a skill's competence a state carried from
;;                     period to period — test-dev-world: the heavy want and 38 of 40
;;                     hours go unplanned; test-dev-ledger: the issue's lead changes
;;                     (ann → box); the other two suites stand;
;;   #:composition     the chemistry's element rows — reaction-network-test: demand met
;;                     falls from 1.0 and R1 no longer makes the CO that R2 consumes;
;;                     test-bread-seed: the work per process differs; the other two stand.
;; The test holds this list and %world-keywords to every keyword ingest-records! reads.
(define %held-back-world-keywords '(#:skill-dynamics #:composition))

(define (world-opts opts)
  "The keyword pairs in OPTS that describe the world, ready to `apply` onto
   ingest-records!. What is filtered out belongs to ONE SOLVE rather than to a
   world: the scenario set, the first-stage naming, the reproduction floors, a
   warm start. Defaults are left to ingest-records!, whose own defaults for these
   keywords are the same ones plan-from-records declares — so forwarding only
   what a caller actually passed reproduces today's numbers exactly."
  (let loop ((o opts) (out '()))
    (cond ((or (null? o) (null? (cdr o))) (reverse out))
          ((memq (car o) %world-keywords)
           (loop (cddr o) (cons (cadr o) (cons (car o) out))))
          (else (loop (cddr o) out)))))

;; does the reserve yield to this future? 'tail ⇒ p = 0 (beyond the record); a list ⇒ named
(define (reserve-yields? s yields-to)
  (cond ((eq? yields-to 'tail) (tail-scenario? s))
        ((pair? yields-to) (and (member (planning-scenario-id s) yields-to) #t))
        (else #f)))

;; Build ONE scenario's located forms by reusing build-located with scaled yields
;; + reproduction floors applied. Returns (prob forms labform ncol cols idx).
(define* (robust-scenario-block s pristine
                                #:key (acquire '()) (promote #f) (repro-floors '()) (repro-caps '()) (insurance '()) (bands '())
                                      (budgeted-floors '())      ; ((g F Γ) …) — held in EVERY future against any Γ sources lost (engine lay-budgeted-floors)
                                      ;; the futures the reserve YIELDS TO — scenario ids in which the
                                      ;; insurance rows are not poured, so the calamity may draw the
                                      ;; reserve down: "held as a hard possibility-tension that
                                      ;; out-pulls desire yet yields to true calamity" (playnet.typ
                                      ;; §q_r^*). Default 'tail: the futures at probability ZERO — the
                                      ;; precautionary tail the bioregion assembler carries "beyond the
                                      ;; record", which is what TRUE calamity means here; the reserve
                                      ;; stands through every recorded bad year and is spent in the
                                      ;; unprecedented one. A list of ids names them by hand; '() ⇒
                                      ;; the reserve stands in every future (Taleb-strict).
                                      (reserve-yields-to 'tail)
                                      ;; the discrete search's tables (search-state), put back
                                      ;; after ingest's reset! so this block is built under the
                                      ;; node's config, cuts and fixings; and the RECOURSE batch
                                      ;; columns, whose floors stay relaxed in every future
                                      (search-state #f) (relax-keys '())
                                #:allow-other-keys #:rest opts)
  ;; THE WORLD IS ALREADY INGESTED — once, by robust-assemble, from the
  ;; unshocked records; PRISTINE is its band-writable state. A branch is
  ;; three facts laid over that one world: its WEATHER (the two factor
  ;; seams, set here and read at build time), its BANDS (poured over the
  ;; restored pristine tables — insurance yields to the tail per branch,
  ;; so the pour differs), and the SEARCH's tables. Every structural read
  ;; — batch floors, leads, reach, whole counts — comes off the unshocked
  ;; world, which is what makes branch-invariant structure a construction
  ;; rather than a check.
  (restore-pristine! pristine)
  (let ((shocks (scenario-shocks s)))
    (set! *flow-period-factor* (branch-flow-factor shocks))
    (set! *avail-factor* (branch-avail-factor shocks)))
  ;; the bands are per-scenario — held in EVERY future. For a calamity reserve:
  ;; full margin in the nominal year, margin eroded but `lo` intact in the
  ;; drought — which is what "insurance" means
  (set! *budgeted-floors* budgeted-floors)
  (set! *acquire* acquire) (set! *promote* promote)   ; before the pour: the tier table decides what is poured
  (apply-repro-bands! (repro-bands #:floors repro-floors #:caps repro-caps
                                   #:insurance (if (reserve-yields? s reserve-yields-to) '() insurance)
                                   #:bands bands))
  (when search-state (restore-search-state! search-state))
  (for-each (lambda (k) (hash-set! *mbq-relaxed* k #t)) relax-keys)
  (call-with-values build-located
    (lambda (forms lf ncol cols goods raws idx)
      (list (planning-scenario-probability s) forms lf ncol cols idx))))

;; a scenario block, by name (built by robust-scenario-block above).
(define (blk-prob b) (list-ref b 0)) (define (blk-forms b) (list-ref b 1))
(define (blk-lf b)   (list-ref b 2)) (define (blk-ncol b)  (list-ref b 3))
(define (blk-cols b) (list-ref b 4)) (define (blk-idx b)   (list-ref b 5))

;; the shared FIRST-STAGE activity of a proc = Σ x over its p|proc|… columns. `fs` is
;; the col-key → shared-index map plan-robust-from-records returns; this is the one
;; read the plan's own first-stage-plan and the tests share.
(define (first-stage-activity x fs proc)
  (let ((acc 0.0))
    (hash-for-each (lambda (k i) (when (equal? (key-process k) proc) (set! acc (+ acc (vector-ref x i))))) fs)
    ;; a first-stage column the discrete layer DECIDED is a fact, not a variable:
    ;; it left `fs` with the program, and its count is read from the fixings. A
    ;; recourse column the presolve pinned is keyed (scenario . key) there — a
    ;; scenario's own fact, outside first-stage activity.
    (hash-for-each (lambda (k n) (when (and (string? k) (equal? (key-process k) proc)) (set! acc (+ acc n)))) *col-fixed*)
    acc))

;; the stock CARRIED FORWARD from a period, decided before the futures diverge —
;; the granary. Storage is a move column along the time edge (planner.scm
;; build-columns, "m|good|place@t|place@t+1"); under a scenario tree the one at
;; the root is shared by every branch, so it reads off `fs` like any first-stage
;; decision. #f when the carry is not a shared decision (a flat scenario set
;; keeps storage as recourse) — the caller then has a per-branch question, not
;; a granary.
(define (carried-forward x fs good place t)
  (let ((i (hash-ref fs (format #f "m|~a|~a@~a|~a@~a" good place t place (+ t 1)) #f)))
    (and i (vector-ref x i))))

;; Robust multi-scenario plan over records. #:scenarios = list of <planning-scenario>
;; (absent/singleton ⇒ ordinary deterministic solve). #:first-stage-procs = proc-ids
;; committed BEFORE the weather resolves (planting/allocation) — shared across
;; scenarios; everything else is recourse. #:pins = ((col-key . value) …) —
;; accepted commitments entering as hand-decided first-stage facts, substituted
;; out of the program; an unmeetable pin raises rather than solving around it
;; (docs/planning/solve/commitment-horizon.md). IGNORED once any scenario carries a
;; #:path (docs/planning/solve/scenario-tree.md): under a tree the PERIOD is the commit
;; time, so which columns share falls out of when each scenario's path diverges,
;; not from naming processes. Returns:
;;   (values x fs-global rc-global nglobal nscenarios)
;; where x is the global activity vector, fs-global : col-key → shared index,
;; rc-global : (scen-idx . col-key) → private index — in BOTH modes; a tree's
;; deeper (partially-shared) nodes still answer through rc-global, each
;; (scen-idx . key) simply pointing at the index its node shares with.
;;
;; the barrier starts INTERIOR to a held wall: the start point is lifted a
;; little above the hold (numerical, never a policy number)
(define *hold-lift* 1.05)                  ; the factor above the held value
(define *hold-floor* 0.01)                 ; …and a floor for a zero hold

;; A pin or hold names a SHARED first-stage column with a nonnegative value —
;; anything else is refused loudly. An accept (and the offer it grew from) is
;; a first-stage fact by definition, so a key this assembly does not share
;; (unknown, or recourse) has no home here.
(define (check-shared-entry! what fs-global e)
  ;; refused TYPED ('commitment-unplaceable): the feasibility-lapse door
  ;; reads this key — an unplaceable hold is exactly what lapsing frees —
  ;; while every untyped raise stays a fault that propagates
  (let ((k (car e)) (v (cdr e)))
    (unless (and (string? k) (hash-ref fs-global k #f))
      (throw* 'commitment-unplaceable
             (string-append "robust: a " what " must name a shared first-stage column of this assembly") k))
    (unless (and (real? v) (>= v 0))
      (throw* 'commitment-unplaceable
             (string-append "robust: a " what "'s value must be a nonnegative number") e))))

;; The deterministic door's warm contract, kept on the robust door: a warm-x
;; of the global shape re-centres with the metabolism barrier weight (few
;; Newton steps); a warm-x of another shape (the horizon grew, the roster
;; moved) is stale, and the cold interior point stands.
(define (warm-fits? warm-x n)
  (and warm-x (vector? warm-x) (= (vector-length warm-x) n)))
(define (warm-tstart tstart warm-x n)
  (or tstart (and (warm-fits? warm-x n) *metabolism-tstart*)))

;; a form's value at x: const + Σ coeff·x — a wall's slack, a want's delivery
(define (form-value f x)
  (fold (lambda (ic a) (+ a (* (cdr ic) (vector-ref x (car ic))))) (f-const f) (f-coeffs f)))

;; scenario-node(s, t): two scenarios are the SAME node deciding at period t iff
;; their paths agree on every period strictly before t — a decision may depend on
;; what has been observed, never on what has not. '() (no path) is always its own
;; node, so a flat scenario set (today's behaviour) is the degenerate one-node-
;; per-scenario tree, not a special case bolted on beside it.
(define (scenario-node s t)
  (let ((path (planning-scenario-path s)))
    (if (null? path) '() (list-head path (min (length path) (max 0 t))))))

;; ── the EXTENSIVE FORM, assembled and not yet solved ─────────────────────────
;; One scenario block per future, remapped into one global program: shared
;; ── MAXIMIN RELATIVE SATISFACTION: the wants judged without a probability ──
;; docs/antifragile/antifragile.md: "maximize the minimum fraction of available
;; value you capture, across all states of the world." A want's captured value
;; in a future is its satisfaction u = min(1, s/D) (the `des` penalty is a
;; function of exactly 1−u); a future's AVAILABLE value V* is the most its own
;; program can capture, planted for that future alone — one single-future
;; solve per branch. The plan then maximizes τ with, in every future s,
;;   Σ_j w_j·u_sj ≥ τ·V*_s,   u_sj ≤ s_j(x)/D_j,   0 ≤ u_sj ≤ 1,   0 ≤ τ ≤ 1
;; — linear walls over new columns (u per want per future, τ shared), and a
;; want on τ toward 1 at the whole desire mass Σ_s V*_s, so a unit of the worst
;; future's fraction outweighs every want beneath it. The wants' own terms stay,
;; each future at ONE equal weight: the tie-break among plans with the same τ,
;; and the record's odds steer nothing. Convex: u ≤ s/D is a half-space, the
;; epigraph of a min of linear functions. The p = 0 tail counts like any future.
(define *maximin-terms* '())          ; ((scenario-id V* ((w . u-key) …)) …) — the report reads τ and the fractions off x by key
;; a want's ASK, both spellings: `want-ask` (solver.scm), the reading the fill report shares
(define (maximin-extend blocks scen des-terms nglobal x0 fs-global rc-global)
  "→ (nglobal* x0* forms terms): the columns, start, walls and want that lift
   the extensive form to the maximin epigraph."
  (define n (length blocks))
  (define (achievable si b)              ; (V*_s . served): the branch planted for itself alone, and each want's satisfaction there
    (let* ((ncol (blk-ncol b))
           (x (call-with-values (lambda () (solve (blk-forms b) (blk-lf b) (make-vector ncol 0.25)))
                (lambda (x . _) x))))
      ;; the achievable value is read off a PLAN, never off an iterate that
      ;; came apart: a diverged point clips every want to full satisfaction
      ;; and states an available value no future has — the joint plan's
      ;; fraction then reads near zero against a fiction
      (when (plan-grossly-infeasible? (flatten (blk-forms b)) x)
        (raise-starvation (format #f "maximin: future ~a has no plan of its own to read its achievable value from"
                                  (planning-scenario-id (list-ref scen si)))))
      (let ((wants (filter-map
                    (lambda (f)
                      (let* ((f (form-body f)) (D (want-ask f)))
                        (and D (> D 0.0)
                             (cons (cdr (f-Dw f)) (max 0.0 (min 1.0 (/ (form-value f x) D)))))))
                    (blk-forms b))))
        (cons (fold (lambda (ws a) (+ a (* (car ws) (cdr ws)))) 0.0 wants) (map cdr wants)))))
  (let* ((VS (let loop ((bs blocks) (si 0) (acc '()))
               (if (null? bs) (reverse acc)
                   (loop (cdr bs) (+ si 1) (cons (achievable si (car bs)) acc)))))
         (Vs (map car VS)) (served (map cdr VS))
         (Wtau (fold + 0.0 Vs))
         (_ (when (getenv "PLANNER_PD_DEBUG")
              (format (current-error-port) "  [maximin] wants ~a achievable ~s~%" (length des-terms) Vs)))
         (tau nglobal) (next (+ nglobal 1))
         (forms '()) (terms '()))
    ;; no future captures any value: there is no fraction to maximize, and a τ
    ;; want with nothing behind it floats to the barrier's centre and lands in
    ;; the fill report as a want half met (a commune, unregistered: 0.1 met of
    ;; a demand no column feeds). No epigraph, and the wants stand alone.
    (if (<= Wtau 0.0)
        (begin (when (getenv "PLANNER_PD_DEBUG") (format (current-error-port) "  [maximin] no future captures any value — no epigraph~%")) #f)
        (begin
        (hash-set! fs-global "maximin|tau" tau)
        (set! forms (cons (list 'bar 0.0 (list (cons tau 1.0)) #f) forms))              ; τ ≥ 0
        (set! forms (cons (list 'bar 1.0 (list (cons tau -1.0)) #f) forms))             ; τ ≤ 1
        (set! forms (cons (mk-device (list 'bar 0.0 (list (cons tau 1.0))) 1.0 Wtau) forms))  ; pull τ → 1 at the whole desire mass — a DEVICE, no one's want (solver.scm mk-device)
        (let loop ((si 0) (Vs Vs) (served served))
          (unless (null? Vs)
            (let ((V* (car Vs)) (mine (filter (lambda (d) (= (car d) si)) des-terms)) (row '()) (j 0) (fixed 0.0)
                  ;; the wants this future can serve at all, by its own plan — in
                  ;; the order the block's forms lay them, the order des-terms
                  ;; collected them (reversed by consing)
                  (own (list->vector (car served))))
              (when (> V* 0.0)
                (for-each
                 (lambda (d k)
                   (let* ((c (list-ref d 1)) (co (list-ref d 2)) (D (list-ref d 3)) (w (list-ref d 4))
                          (u* (if (< k (vector-length own)) (vector-ref own k) 1.0)))
                     (if (or (null? co) (<= u* 1e-6))
                         ;; a want no column feeds, or one this future's own plan serves
                         ;; NOTHING of: its satisfaction is a constant and enters the wall
                         ;; as one. A u column for it would sit between u ≤ s/D — s at 0
                         ;; wherever the future can put it — and u ≥ 0: no interior from
                         ;; any start, the barrier stuck where it begins. Measured live: the
                         ;; path-follower stalled at min-slack 1e-17 on exactly these,
                         ;; stationarity 0.9, τ = 0.09 under futures capturing 0.48.
                         ;; a want no column feeds: its satisfaction is the constant
                         ;; min(1, c/D), and it enters the wall as a constant. A u
                         ;; column for it would sit between u ≤ c/D and u ≥ 0 — at
                         ;; c = 0 an empty-interior pin no barrier can start from
                         (set! fixed (+ fixed (* w (if (null? co) (max 0.0 (min 1.0 (/ c D))) u*))))
                         (let ((u next) (key (format #f "maximin|u|~a" j)))
                           (set! next (+ next 1)) (set! j (+ j 1))
                           (hash-set! rc-global (cons si key) u)
                           (set! forms (cons (list 'bar (/ c D) (append (map (lambda (ic) (cons (car ic) (/ (cdr ic) D))) co) (list (cons u -1.0))) #f) forms))  ; u ≤ s/D
                           (set! forms (cons (list 'bar 1.0 (list (cons u -1.0)) #f) forms))      ; u ≤ 1
                           (set! forms (cons (list 'bar 0.0 (list (cons u 1.0)) #f) forms))       ; u ≥ 0
                           (set! row (cons (cons w key) row))))))
                 (reverse mine) (iota (length mine)))
                ;; fixed + Σ w·u − V*·τ ≥ 0 — the future's captured fraction is at least τ
                (set! forms (cons (list 'bar fixed (cons (cons tau (- V*)) (map (lambda (d) (cons (hash-ref rc-global (cons si (cdr d))) (car d))) row)) #f) forms))
                (set! terms (cons (list (planning-scenario-id (list-ref scen si)) V* (reverse row) fixed) terms)))
              (loop (+ si 1) (cdr Vs) (cdr served)))))
        (let ((x0* (make-vector next 0.25)))
          (do ((i 0 (+ i 1))) ((= i nglobal)) (vector-set! x0* i (vector-ref x0 i)))
          (vector-set! x0* tau 0.1)
          (list next x0* (reverse forms) (reverse terms)))))))
(define (maximin-report x fs-global rc-global)
  "((tau . τ) (futures . ((id V* captured-fraction) …))) off the solved x, or #f."
  (let ((ti (hash-ref fs-global "maximin|tau" #f)))
    (when (getenv "PLANNER_PD_DEBUG")
      (format (current-error-port) "  [maximin-report] tau-index ~s terms ~a x-len ~a~%" ti (length *maximin-terms*) (vector-length x)))
    (and ti (pair? *maximin-terms*)
         (list (cons 'tau (vector-ref x ti))
               (cons 'futures
                     (let loop ((ts *maximin-terms*) (si 0) (acc '()))
                       (if (null? ts) (reverse acc)
                           (let* ((t (car ts)) (V* (cadr t))
                                  (cap (fold + (if (> (length t) 3) (cadddr t) 0.0)     ; the constant part: wants no column feeds
                                             (map (lambda (wk) (let ((i (hash-ref rc-global (cons si (cdr wk)) #f)))
                                                                 (if i (* (car wk) (vector-ref x i)) 0.0)))
                                                  (caddr t)))))
                             ;; the future's epigraph slack Σw·u − V*·τ: ≥ 0 at any point of the
                             ;; program; τ sits at the least fraction when the solve is done
                             (loop (cdr ts) (+ si 1) (cons (list (car t) V* (if (> V* 0.0) (/ cap V*) 1.0) (- cap (* V* (vector-ref x ti)))) acc))))))))))

;; columns where the futures have not diverged, private ones where they have.
;; With SEARCH-STATE given (the discrete layer's tables), every block is built
;; under it and the decided first-stage columns are substituted out of the global
;; program — §7's "a decided count is a fact" — with the index maps renumbered
;; to match. → (values forms labform x0 fs-global rc-global nglobal nscen cols0 first?)
(define* (robust-assemble resources agents spatials recipe-procs recipe-flows
                          #:key (scenarios '()) (first-stage-procs '())
                                (search-state #f) (relax-keys '()) (pins '()) (holds '())
                                (warm-x #f)
                                ;; MAXIMIN RELATIVE SATISFACTION (antifragile-sweep.md): the
                                ;; wants are judged by the least fraction of a future's own
                                ;; achievable value the plan captures, no probability weighing
                                ;; them; see maximin-extend below
                                (maximin? #f)
                          #:allow-other-keys #:rest opts)
  (let* ((scen   (if (pair? scenarios) scenarios
                     (list (make-planning-scenario "deterministic" #f 1.0 '() #f))))
         ;; ONE ingest for the whole assembly: the world — templates, spans,
         ;; stocks, batch floors — is built from the unshocked records here,
         ;; and every branch below is a view over it (the weather seam).
         (pristine (begin (apply ingest-records! resources agents spatials
                                 recipe-procs recipe-flows (world-opts opts))
                          ;; the voice field and the governed dials, set after ingest's reset
                          ;; exactly as the single deterministic solve sets them
                          (apply apply-solve-settings! opts)
                          (world-pristine)))
         (blocks (map (lambda (s)
                        (apply robust-scenario-block s pristine
                               #:search-state search-state #:relax-keys relax-keys opts))
                      scen))
         (b0 (car blocks)) (ncol (blk-ncol b0)) (cols0 (blk-cols b0)) (idx0 (blk-idx b0))
         (allkeys (map col-key cols0))
         (local->key (make-hash-table)) (local->cell (make-hash-table))
         ;; a TREE once any scenario names a path — all-or-nothing, so no scenario
         ;; is left with an undefined node.
         (tree? (any (lambda (s) (pair? (planning-scenario-path s))) scen)))
    ;; every scenario shares the SAME structural column layout (coeff-independent)
    (for-each (lambda (b) (unless (= (blk-ncol b) ncol)
                            (error "robust: scenario column structure differs" (blk-ncol b) ncol)))
              blocks)
    (for-each (lambda (c) (hash-set! local->key (hash-ref idx0 (col-key c)) (col-key c))
                          (hash-set! local->cell (hash-ref idx0 (col-key c)) (col-cell c)))
              cols0)
    (when tree?
      (for-each (lambda (s) (unless (pair? (planning-scenario-path s))
                              (error "robust: scenario tree requires EVERY scenario to carry a #:path once any one does"
                                     (planning-scenario-id s))))
                scen))
  (call-with-values
    (lambda ()
      (if tree?
          ;; ── TREE — share a column exactly where the scenarios routing through
          ;; it have not yet diverged. One index per (key . node), assigned as
          ;; encountered; fs-global gets the ones EVERY scenario agrees on (always
          ;; true at t=0, since scenario-node ignores the path entirely there —
          ;; the root needs no scenario to have observed anything).
          (let* ((node-global (make-hash-table))
                 (fs-global (make-hash-table)) (rc-global (make-hash-table))
                 (fully-shared (make-hash-table)) (i 0))
            (for-each
             (lambda (k)
               (let* ((t (period-of (hash-ref local->cell (hash-ref idx0 k))))
                      (nodes (map (lambda (s) (scenario-node s t)) scen)))
                 (when (every (lambda (n) (equal? n (car nodes))) (cdr nodes))
                   (hash-set! fully-shared k #t))
                 (let loop ((ss scen) (si 0))
                   (unless (null? ss)
                     (let* ((node-key (cons k (scenario-node (car ss) t)))
                            (gi (or (hash-ref node-global node-key #f)
                                    (let ((n i)) (hash-set! node-global node-key n) (set! i (+ i 1)) n))))
                       (hash-set! rc-global (cons si k) gi)
                       (when (hash-ref fully-shared k #f) (hash-set! fs-global k gi)))
                     (loop (cdr ss) (+ si 1))))))
             allkeys)
            (values (lambda (k) (hash-ref fully-shared k #f)) fs-global rc-global i))
          ;; ── LEGACY — the declared first-stage/recourse binary, unchanged ──
          ;; FIRST-STAGE-PROCS runs O(crowd) once housing stands (a nightfall
          ;; per person rides in it), and first? is asked per coefficient of
          ;; every form in every scenario — a hash-set holds the procs and a
          ;; memo holds each key's verdict, so the key splits once and the
          ;; roster is read once.
          (let* ((fsp (let ((h (make-hash-table)))
                        (for-each (lambda (p) (hash-set! h p #t)) first-stage-procs) h))
                 (fmemo (make-hash-table))
                 (first? (lambda (k)
                           (if (hash-get-handle fmemo k) (hash-ref fmemo k)
                               ;; …and where a MEANS stands is one fact in every future: a
                               ;; key is at the door or it is not, so its ride is decided
                               ;; with the first stage, whole (engine means-ride?)
                               (let* ((p (key-process k))
                                      (v (and p (or (hash-ref fsp p #f) (means-ride? p)) #t)))
                                 (hash-set! fmemo k v) v))))
                 (fs-keys (filter first? allkeys))
                 (rc-keys (filter (lambda (k) (not (first? k))) allkeys))
                 (nfs (length fs-keys)) (nrc (length rc-keys))
                 (fs-global (make-hash-table)) (rc-global (make-hash-table)))
            (let ((i 0)) (for-each (lambda (k) (hash-set! fs-global k i) (set! i (+ i 1))) fs-keys))
            (let loop ((si 0))
              (when (< si (length blocks))
                (let ((r 0)) (for-each (lambda (k) (hash-set! rc-global (cons si k) (+ nfs (* si nrc) r))
                                               (set! r (+ r 1))) rc-keys))
                (loop (+ si 1))))
            (values first? fs-global rc-global (+ nfs (* (length blocks) nrc))))))
    (lambda (first? fs-global rc-global nglobal)
    (let* ((remap (lambda (si li) (let ((k (hash-ref local->key li)))
                                    (if (first? k) (hash-ref fs-global k) (hash-ref rc-global (cons si k))))))
           (allforms '()) (alllab '()) (branch-programs '()) (des-terms '()))
      (let loop ((bs blocks) (si 0))
        (unless (null? bs)
          (let ((prob (if (and maximin? (> (length blocks) 1))         ; every future counts once beyond τ; the record's odds no longer steer
                          (/ 1.0 (length blocks))
                          (blk-prob (car bs))))
                (forms (blk-forms (car bs))) (lf (blk-lf (car bs))))
            ;; one scenario's form, re-indexed into the global vector. A want is
            ;; EXPECTED (its weight × p); every wall — bar, frag, held — is
            ;; ROBUST, kept whole in every future. A method form is unwrapped,
            ;; remapped and re-wrapped, so the solver still sees its scaffolding
            ;; and the certificate still does not. Every kind is named: a kind
            ;; this table has not met is an error, not a bar by accident.
            (define* (remap-form f #:optional (prob prob))
              (if (method-form? f)
                  (mk-method (remap-form (form-body f) prob))
                  (let ((co (map (lambda (ic) (cons (remap si (car ic)) (cdr ic))) (f-coeffs f))))
                    (case (f-kind f)
                      ((des)  (list 'des  (f-const f) co (cons (car (f-Dw f)) (* prob (cdr (f-Dw f))))))  ; EXPECTED
                      ((cap)  (append (list 'cap (f-const f) co (cons (car (f-Dw f)) (* prob (cdr (f-Dw f)))))  ; EXPECTED — a want, its ask a wall beside it; the scale rides whole,
                                      (cddddr f)))                                                              ; and the ASK stamped after it rides too (want-ask reads it: the epigraph, the fill report)
                      ((qc)   (list 'qc   (f-const f) co (f-Dw f)))
                      ((frag) (list 'frag (f-const f) co (f-Dw f)))                                        ; ROBUST (per-scenario)
                      ((held) (list 'held (f-const f) co (f-Dw f)))                                        ; ROBUST — the margin is held in every future
                      ((bar)  (list 'bar  (f-const f) co #f))                                              ; ROBUST (per-scenario)
                      (else   (error "robust: a tension kind the scenario assembly does not know" (f-kind f)))))))
            (for-each (lambda (f) (set! allforms (cons (remap-form f) allforms))) forms)
            ;; the branch's WANTS on the global indices — what maximin-extend reads
            (for-each (lambda (f)
                        (let* ((b (form-body f))
                               (D (want-ask b)))
                          (when D
                            (set! des-terms
                              (cons (list si (f-const b)
                                          (map (lambda (ic) (cons (remap si (car ic)) (cdr ic))) (f-coeffs b))
                                          D (cdr (f-Dw b)))
                                    des-terms)))))
                      forms)
            (for-each (lambda (ic) (set! alllab (cons (cons (remap si (car ic)) (* prob (cdr ic))) alllab))) lf)
            ;; the branch's OWN program, unweighted, on the global indices —
            ;; what a per-branch cost (the regret-tilt's Z_ω) is read from
            (set! branch-programs
              (cons (list (planning-scenario-id (list-ref scen si)) prob
                          (map (lambda (f) (remap-form f 1.0)) forms)
                          (map (lambda (ic) (cons (remap si (car ic)) (cdr ic))) lf))
                    branch-programs)))
          (loop (cdr bs) (+ si 1))))
      (let* (;; a METABOLISM warm re-solve re-centres near the standing
             ;; optimum — the same contract as the deterministic door. A
             ;; warm-x of another shape (the horizon grew, the roster moved)
             ;; is stale, and the cold interior point stands.
             (x0 (if (warm-fits? warm-x nglobal)
                     (vector-copy warm-x)
                     (make-vector nglobal 0.25)))
             ;; ── #:holds — offers under live consideration, held as walls ────
             ;; (commitment-horizon.md: the bounded rung.) A hold keeps the
             ;; offered value available while a person decides: x ≥ v as an
             ;; ordinary bar wall on the shared column, felt by every backend
             ;; and carried through substitute-fixed's renumbering like any
             ;; form — *col-bounds* stays the discrete search's own per-node
             ;; tool. A hold the program cannot honor makes the solve
             ;; infeasible, which raises: the feasibility-lapse signal the
             ;; caller turns into a loud lapse of the offer. The start point
             ;; is lifted above each held wall so the barrier begins interior.
             (hold-forms
              (map (lambda (h)
                     (check-shared-entry! "hold" fs-global h)
                     (let ((gi (hash-ref fs-global (car h)))
                           (v* (exact->inexact (cdr h))))
                       (vector-set! x0 gi (max (vector-ref x0 gi) (* *hold-lift* (max v* *hold-floor*))))
                       (list 'bar (- v*) (list (cons gi 1.0)) #f)))
                   holds))
             (forms0 (append (reverse allforms) hold-forms))
             (lab* (reverse alllab))
             (mm (and maximin? (> (length blocks) 1)
                      (maximin-extend blocks scen des-terms nglobal x0 fs-global rc-global)))
             (nglobal (if mm (list-ref mm 0) nglobal))
             (x0 (if mm (list-ref mm 1) x0))
             (forms* (if mm (append forms0 (list-ref mm 2)) forms0)))
        (set! *maximin-terms* (if mm (list-ref mm 3) '()))
        ;; ── #:pins — accepted commitments as HAND-DECIDED first-stage columns ──
        ;; (docs/planning/solve/commitment-horizon.md: an accept is a col-fixed by a
        ;; human instead of the search tree.) Pins enter here, AFTER every block
        ;; build (each block's ingest resets the world state, clearing the
        ;; table), and go through the same substitute-fixed door the discrete
        ;; layer uses — so a pin that starves a wall in ANY scenario raises,
        ;; never silently ignored. A pin names a SHARED column: an accept is a
        ;; first-stage fact by definition, so a key this assembly does not
        ;; share (unknown, or recourse) is refused loudly.
        (when (pair? pins)
          (for-each (lambda (p) (check-shared-entry! "pin" fs-global p)) pins)
          (if search-state
              ;; under the discrete search each node owns the fixed-column
              ;; table (node-solve sets it, the block builds restore it) —
              ;; a pin JOINS the node's fixings rather than clobbering
              ;; them, and it wins on its own column: an accept is a fact
              ;; in every node of the tree. Both branches of a pinned
              ;; column then price the same — wasted nodes at worst,
              ;; never a wrong incumbent.
              (for-each (lambda (kv) (hash-set! *col-fixed* (car kv) (cdr kv))) pins)
              (with-col-fixed! pins)))
        (if (and (not search-state) (null? pins))
            (begin
              (set! *branch-programs* (list #f nglobal branch-programs))
              (values forms* lab* x0 fs-global rc-global nglobal (length blocks) cols0 first?))
            ;; the decided columns leave the program. One index table carries
            ;; both maps through substitute-fixed — shared keys as strings,
            ;; private ones as (scenario . key) — and is split back after.
            (let ((gidx (make-hash-table)))
              (hash-for-each (lambda (k i) (hash-set! gidx k i)) fs-global)
              (hash-for-each (lambda (k i) (hash-set! gidx k i)) rc-global)
              ;; the pre-substitution index table, kept so a per-branch cost can
              ;; rebuild the full vector (branch-costs below)
              (let ((gidx-old (make-hash-table)))
                (hash-for-each (lambda (k i) (hash-set! gidx-old k i)) gidx)
                (set! *branch-programs* (list gidx-old nglobal branch-programs)))
              (call-with-values (lambda () (substitute-fixed forms* lab* nglobal cols0 gidx x0))
                (lambda (forms** lab** gidx* x0*)
                  (let ((fs* (make-hash-table)) (rc* (make-hash-table)))
                    (hash-for-each (lambda (k i) (if (string? k) (hash-set! fs* k i) (hash-set! rc* k i))) gidx*)
                    (values forms** lab** x0* fs* rc* (vector-length x0*) (length blocks) cols0 first?))))))))))))

;; the branches' own programs, left by the last robust-assemble for the
;; per-branch cost read: (old-index-table nglobal-old ((id prob forms lab) …))
(define *branch-programs* '())

(define (branch-costs x fs-global rc-global)
  "((scenario-id prob cost) …) — each branch's own objective at the solution,
   the Z_ω a risk measure or the regret-tilt reads. The programs sit on the
   pre-substitution indices, so the full vector is rebuilt first: a decided
   column takes its fixed value, every other its solved one."
  (if (null? *branch-programs*) '()
      (let* ((old (car *branch-programs*)) (n (cadr *branch-programs*))
             (full (make-vector n 0.0)))
        (if old
            (hash-for-each
             (lambda (k iold)
               (vector-set! full iold
                 (or (col-fixed k)
                     (let ((inew (or (hash-ref fs-global k #f) (hash-ref rc-global k #f))))
                       (if inew (vector-ref x inew) 0.0)))))
             old)
            (let loop ((i 0))
              (when (and (< i n) (< i (vector-length x)))
                (vector-set! full i (vector-ref x i)) (loop (+ i 1)))))
        (map (lambda (bp) (list (car bp) (cadr bp) (solution-cost full (caddr bp) (cadddr bp))))
             (reverse (caddr *branch-programs*))))))

;; The located labour pulls of a MANY-future solve: λ(s,c) summed over the
;; futures' own balance rows. A labour commitment is FIRST-STAGE — made
;; before the weather is known — so its column stands in every branch's
;; Lab|s|c balance, and the objective's gradient along it is Σ_ω λ_ω(s,c):
;; the reduced-cost identity on the extensive form. The futures'
;; probabilities are already inside those duals (the wants that shaped x
;; carry p), so the sum is unweighted; one future gives the deterministic
;; reading exactly. The Lab| rows' constants are not weather-shocked
;; (branch-avail-factor scales a RAW's supply), so the tables in place at
;; report time serve every branch's read. What stays absent is any
;; PER-future λ — that would state more than the solve knows.
(define (robust-bill x cols0 nscen view)
  "engine acquire-bill over every future, each row at the future that buys most of it."
  (let* ((bills (map (lambda (si) (assq-ref (acquire-bill x cols0 (view si)) 'bill)) (iota nscen)))
         (keys (delete-duplicates (map car (apply append bills))))
         (rows (map (lambda (k)
                      (let ((rs (filter-map (lambda (b) (assoc k b)) bills)))
                        (fold (lambda (r a) (if (> (cadr r) (cadr a)) r a)) (car rs) (cdr rs))))
                    keys)))
    `((bill . ,rows) (bill-hours . ,(fold + 0.0 (map caddr rows))))))
(define (robust-labour-pulls x cols0 nscen view t)
  (let ((acc (make-hash-table)))
    (let loop ((si 0))
      (when (< si nscen)
        (for-each (lambda (kv)
                    (hash-set! acc (car kv) (+ (hash-ref acc (car kv) 0.0) (cdr kv))))
                  (labour-pulls (tension-duals x cols0 (view si) t)))
        (loop (+ si 1))))
    (hash-map->list cons acc)))

;; solve the extensive form → x plus the maps a report reads it through
(define* (robust-solve forms lab x0 #:key (allow-infeasible? #f) (tstart #f))
  (let* ((C (flatten forms))
         (res (call-with-values (lambda () (if tstart (solve forms lab x0 tstart)
                                               (solve forms lab x0))) list))
         (x (car res)))
    ;; Infeasibility is a REAL answer here — a reproduction floor unmeetable
    ;; in SOME scenario (e.g. a famine-scale tail on too little land). The
    ;; fast backend may return a diverged x instead of raising, so guard it,
    ;; mirroring solve-native's gross-infeasibility check. The planner
    ;; REFUSING to promise is the honest result (Taleb: don't over-promise).
    ;; #:allow-infeasible? is the caller saying "this solve MAY have no
    ;; answer" — the deterministic door's own contract, honored here so a
    ;; live scope can price its dilemmas off the certificate instead of
    ;; dying: feasible? #f rides the plan-verdict either way.
    (when (and (not allow-infeasible?) (plan-grossly-infeasible? C x))
      ;; the certificate phase-I left names the limits it could not clear:
      ;; the raise carries them, so the log says WHICH floor, not only that
      ;; one exists
      (raise-starvation
       (format #f "plan-robust: no strictly-feasible point — a reproduction floor is unmeetable in some scenario; phase-I certificate: ~s"
               (let ((c *last-certificate*))
                 (if (list? c)
                     (filter (lambda (kv) (memq (car kv) '(feasible? violation breached worst)))
                             c)
                     c)))))
    (values x C
            (if (>= (length res) 2) (list-ref res 1) 0.02)
            (if (>= (length res) 4) (list-ref res 3) 0))))   ; Newton steps — the metabolism read

(define* (plan-robust-from-records resources agents spatials recipe-procs recipe-flows
                                   #:key (scenarios '()) (allow-infeasible? #f)
                                         (warm-x #f) (tstart #f)
                                   #:allow-other-keys #:rest opts)
  (call-with-values
    (lambda () (apply robust-assemble resources agents spatials recipe-procs recipe-flows opts))
    (lambda (forms lab x0 fs-global rc-global nglobal nscen cols0 first?)
      (call-with-values (lambda () (robust-solve forms lab x0 #:allow-infeasible? allow-infeasible?
                                     #:tstart (warm-tstart tstart warm-x nglobal)))
        (lambda (x C tfin ntot)
          ;; x, the shared/recourse index maps, sizes, the canonical columns, the
          ;; stage predicate, and the flattened GLOBAL program (for mean-fill).
          (values x fs-global rc-global nglobal nscen cols0 first? C))))))

;; ── THE WALLS A SOLVE SITS ON, named by column ───────────────────────────────
;; Printed under PLANNER_PD_DEBUG, and whenever a solve ended STALLED
;; (solver.scm %stalled-stat), so the log says WHICH term: the walls the
;; returned point violates, the tightest ones, and the structural pins.
(define (solve-stalled?)
  (let ((st (and (list? *last-certificate*) (assq-ref *last-certificate* 'stationarity))))
    (and (number? st) (> st 1e-1))))

(define (report-walls forms x fs-global rc-global)
  (define port (current-error-port))
  (define name                                   ; global index → column key
    (let ((h (make-hash-table)))
      (hash-for-each (lambda (k i) (hash-set! h i k)) fs-global)
      (hash-for-each (lambda (k i) (hash-set! h i (format #f "~a:~a" (car k) (cdr k)))) rc-global)
      (lambda (i) (hash-ref h i i))))
  (define (upto n l) (list-head l (min n (length l))))
  (define (columns b n) (map (lambda (ic) (list (name (car ic)) (cdr ic) (vector-ref x (car ic)))) (upto n (f-coeffs b))))
  (let* ((bars (filter (lambda (b) (eq? (f-kind b) 'bar)) (map form-body forms)))
         ;; every wall at its slack, tightest first
         (slacks (sort (map (lambda (b) (cons (form-value b x) b)) bars)
                       (lambda (a b) (< (car a) (car b)))))
         (viol (filter (lambda (sb) (< (car sb) -1e-9)) slacks))
         ;; the STRUCTURAL pins: a wall with a non-positive constant, a negative
         ;; coefficient and no positive one admits no strictly interior point —
         ;; each column it names is forced to exactly 0
         (pins (filter (lambda (b)
                         (and (<= (f-const b) 0.0)
                              (any (lambda (ic) (< (cdr ic) 0.0)) (f-coeffs b))
                              (not (any (lambda (ic) (> (cdr ic) 0.0)) (f-coeffs b)))))
                       bars)))
    (format port "  [verdict] ~a wall(s) violated at the returned point (~a of them single-column bounds)~%"
            (length viol) (count (lambda (sb) (= 1 (length (f-coeffs (cdr sb))))) viol))
    ;; an active wall at slack 0 with nothing violated is where a barrier solve sits when it stalls
    (for-each (lambda (sb)
                (format port "  [tightest] slack ~,2e const ~,3f: ~s~%" (car sb) (f-const (cdr sb)) (columns (cdr sb) 4)))
              (upto 6 slacks))
    (for-each (lambda (sb)
                (format port "  [verdict] slack ~,4f const ~,3f: ~s~%" (car sb) (f-const (cdr sb))
                        (columns (cdr sb) (length (f-coeffs (cdr sb))))))
              (upto 8 (filter (lambda (sb) (> (length (f-coeffs (cdr sb))) 1)) viol)))
    (format port "  [pins] ~a wall(s) nothing feeds (const ≤ 0, no + coefficient)~%" (length pins))
    (for-each (lambda (b)
                (format port "  [pins] const ~,3f: ~s~%" (f-const b)
                        (map (lambda (ic) (cons (name (car ic)) (cdr ic))) (f-coeffs b))))
              (upto 8 pins))))

;; Robust plan in the standard plan-from-records 9-value shape, so it can be
;; returned from `plan-from-records #:scenarios …`. The executable plan reported
;; is the FIRST scenario's view (shared first-stage + that scenario's recourse) —
;; a coherent plan whose first-stage part is common to all futures; the report
;; carries the shared planting decision + scenario count.
(define* (robust-plan-report resources agents spatials recipe-procs recipe-flows
                             #:key (scenarios '()) (decided #f) (node-budget #f)
                                   (allow-infeasible? #f) (warm-x #f) (tstart #f)
                             #:allow-other-keys #:rest opts)
  (define (warm-ts n) (warm-tstart tstart warm-x n))
  (define (assemble st relax)
    (apply robust-assemble resources agents spatials recipe-procs recipe-flows
           #:search-state st #:relax-keys relax opts))
  (parameterize ((*bnb-nodes* (or node-budget (*bnb-nodes*))))   ; this solve's budget: the search and its certificate read it
  (call-with-values (lambda () (assemble #f '()))
    (lambda (forms lab x0 fs-global rc-global nglobal nscen cols0 first?)
      ;; §7 — THE DISCRETE LAYER over the extensive form. Integer FIRST STAGE,
      ;; continuous RECOURSE: the search decides the shared columns (declared
      ;; whole or minimum-batch, and shared by every future), because those are
      ;; the acts committed before the weather resolves; a recourse column's
      ;; floor stays relaxed in every future and the certificate names it. Each
      ;; node re-assembles the whole form under the node's tables — one block per
      ;; scenario — and solves it once; the search itself is the same tree, the
      ;; same certificate, the same incumbent as the deterministic solve.
      (let* ((allkeys (map col-key cols0))
             (recourse (filter (lambda (k) (and (not (first? k)) (or (mbq-floor k) (whole-col? k)))) allkeys))
             (rc-batch (filter mbq-floor recourse))
             (program (lambda ()
                        (call-with-values (lambda () (assemble (search-state) rc-batch))
                          (lambda (forms lab x0 fs rc n ns cols0 first?)
                            (set-last-certificate! '((feasible? . unknown)))
                            (call-with-values (lambda () (robust-solve forms lab x0 #:allow-infeasible? allow-infeasible?
                                                            #:tstart (warm-ts n)))
                              (lambda (x C tfin ntot) (values x forms lab fs)))))))
             (searched (and (discrete-declared?)
                            (parameterize ((*discrete-key?* first?) (*discrete-program* program))
                              (call-with-values (lambda () (solve-discrete #:seed decided)) list))))
             (decided-now (and searched (decided-state))))
        (call-with-values
            (lambda ()
              ;; the plan: the incumbent's program when a search ran (its tables
              ;; are in place; recourse floors relaxed as during the search), the
              ;; assembly already in hand otherwise
              (if searched (assemble (search-state) rc-batch)
                  (values forms lab x0 fs-global rc-global nglobal nscen cols0 first?)))
          (lambda (forms lab x0 fs-global rc-global nglobal nscen cols0 first?)
            (call-with-values (lambda () (robust-solve forms lab x0 #:allow-infeasible? allow-infeasible?
                                            #:tstart (warm-ts nglobal)))
              (lambda (x Cglobal tfin ntot)
                ;; scenario-si view: col-key → its global index (first-stage shared).
                (define (view si)
                  (let ((h (make-hash-table)))
                    (for-each (lambda (c) (let ((k (col-key c)))
                                            (hash-set! h k (if (first? k) (hash-ref fs-global k)
                                                               (hash-ref rc-global (cons si k))))))
                              cols0)
                    h))
                ;; the shared first-stage planting decision, as (proc . activity) summary.
                (define first-stage-plan
                  (let ((acc '()))
                    (define (add! p v) (set! acc (assoc-replace acc p (+ (or (assoc-ref acc p) 0.0) v))))
                    (hash-for-each (lambda (k i)
                                     (let ((p (key-process k)))
                                       (when p (add! p (vector-ref x i)))))
                                   fs-global)
                    (hash-for-each (lambda (k n)                    ; the decided ones are facts (a pinned recourse column is keyed (si . key): a scenario's own)
                                     (let ((p (and (string? k) (key-process k))))
                                       (when p (add! p n))))
                                   *col-fixed*)
                    acc))
                (when (or (getenv "PLANNER_PD_DEBUG") (solve-stalled?))
                  (report-walls forms x fs-global rc-global))
                (let ((v0 (view 0)))
                  (call-with-values (lambda () (plan->work x cols0 v0))
                    (lambda (ints coms candidates)
                      (values ints coms (plan->material x cols0 v0)
                              (mean-fill Cglobal x) cols0 x v0 ntot
                              (append
                               ;; ONE branch ⇒ the extensive form IS the
                               ;; deterministic program, so its dual and
                               ;; embodied readings are exact and the robust
                               ;; door reports everything the deterministic
                               ;; door does — what lets a live scope run
                               ;; robust-by-default with a singleton scenario
                               ;; and lose nothing. More branches carry ONE
                               ;; located reading — the labour pulls summed
                               ;; over the futures (robust-labour-pulls) —
                               ;; and keep every other per-future dual absent.
                               (if (= nscen 1) (solve-report x cols0 v0 tfin)
                                   (list (cons 'labour-pulls
                                               (robust-labour-pulls x cols0 nscen view tfin))))
                               ;; THE BILL under uncertainty: what the walls made the solve
                               ;; buy, read in every future and reported at the worst —
                               ;; enough for whichever future asks the most of each row
                               (let ((a (let ((m (memq #:acquire opts))) (and m (pair? (cdr m)) (cadr m)))))
                                 (if (pair? a) (robust-bill x cols0 nscen view) '()))
                               (list (cons 'candidates candidates)
                                     (cons 'robust #t)
                                     (cons 'nscenarios nscen)
                                     (cons 'first-stage-plan first-stage-plan)
                                     ;; each branch's own objective at x — Z_ω
                                     (cons 'branch-costs (branch-costs x fs-global rc-global))
                                     ;; the worst future's captured fraction of its own achievable value
                                     (cons 'maximin (maximin-report x fs-global rc-global))
                                     ;; the certificate rides ONCE, below: the deterministic door's
                                     ;; shape (plan-verdict), the discrete block on it when a search
                                     ;; ran. A second `certificate` ahead of it is the one assq finds —
                                     ;; measured: the searched block shadowed on every robust plan.
                                     ;; the social-individual accounting, read through the
                                     ;; scenario-0 view — the same coherent plan the ints/coms
                                     ;; above describe, so the orb narrates real hours on a
                                     ;; robust solve too. The located labour pulls ride as
                                     ;; labour-pulls above (summed over the futures — the
                                     ;; first-stage reading); every other per-future dual
                                     ;; stays absent, since projecting one future's λ as
                                     ;; "the" pull would state more than the solve knows.
                                     (cons 'social (social-ledger x v0)))
                               ;; what the search proved and decided, as on the
                               ;; deterministic path — plus the recourse columns
                               ;; whose discreteness this two-stage solve relaxes
                               (if searched
                                   (list (cons 'certificate
                                               (cons (cons 'discrete
                                                           (append (discrete-certificate searched)
                                                                   (list (cons 'recourse-relaxed recourse))))
                                                     (plan-verdict forms tfin)))
                                         (cons 'decided decided-now))
                                   ;; no search ran: the verdict over the extensive form still
                                   ;; rides — `feasible` on the wire was 'unknown on every
                                   ;; robust solve without it
                                   (cons (cons 'certificate (plan-verdict forms tfin))
                                         (if (discrete-declared?) (list (cons 'discrete 'relaxed)) '())))))))))))))))))   ; +parameterize for the budget
