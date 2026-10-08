;;; relaxation.scm — the event-driven chaotic relaxation planner.
;;;
;;; ┌─ DEMOTED TO REFERENCE ─────────────────────────────────────────────────┐
;;; │ The PRIMARY engine is now ../planner.scm — one unified file, two        │
;;; │ backends (native interior-point + OSQP over FFI), space/time/scope as   │
;;; │ coordinates, solved monolithically. This file is kept as the richest    │
;;; │ commentary on the desire/possibility/pull math and the EMP matcher;     │
;;; │ planner.scm ports its reserve tranche, EMP labour, and discrete         │
;;; │ anneal+dual-bound. New work goes in planner.scm.                        │
;;; └────────────────────────────────────────────────────────────────────────┘
;;;
;;; Spec: docs/playnet.typ §"Desire, possibility, and the resolving chord".
;;;
;;; The whole planner, re-founded on the paper's primitives and operating on
;;; the real ValueFlows records of schemas.scm:
;;;
;;;   stock        ResourceSpecification (type, target) + EconomicResource (on-hand)
;;;   recipe edges Recipe / RecipeProcess / RecipeFlow  (consume/use = BOM, work = SNLT_direct)
;;;   event        EconomicEvent  (the atom of accounting; drives the metabolism)
;;;   gap          (target - current)/target                       — continuous
;;;   desire-tension   priority · gap²        (soft, bounded)      — what we want
;;;   possibility-tension   per-skill log-barrier on labour L_k<=A_k, and on
;;;                        capped raw draws (hard, diverging at the limit)
;;;                                                                — what is possible
;;;   harmony      -(Σ desire-tension + Σ possibility-tension)
;;;   pull         marginal harmony of producing one more unit     — felt as loudness
;;;   cascade      a gap summons the recipe scaled to the gap, exploded upstream
;;;   metabolism   events draw stocks down → gaps open → relax → produce → repeat
;;;
;;; Labour is NOT one fungible ceiling. Each work-flow names a *skill*; each
;;; skill k has its own availability A_k, aggregated from a worker roster —
;;; mirroring (playnet planner pools availability-pool)'s rule "one body, one
;;; availability, one entry per skill". The single labour barrier therefore
;;; splits into Σ_k barrier(L_k, A_k): scarce skilled labour (say bakers)
;;; throttles and allocates desire by pull, exactly as the soil envelope
;;; throttles material throughput. Once the convex core settles the quantities,
;;; the real (playnet planner algorithms deferred-acceptance) matcher assigns named
;;; workers to the period's work-slots — labour as a matched flow, made visible.
;;;
;;; The loop is event-driven (it reacts to consumption EconomicEvents) and
;;; relaxes between events, climbing toward maximum harmony. Two layers, each
;;; solved as strongly as its structure allows:
;;;   • the continuous core (quantities, recipes fixed) is convex ⇒ MONOTONE
;;;     gradient ascent to the GLOBAL optimum, no chaos needed;
;;;   • the discrete layer (which recipe makes each good) is non-convex ⇒
;;;     ENUMERATED exactly when the choice space is small (a CERTIFIED joint
;;;     global optimum, the usual case), annealed with restarts when it is not.
;;; So the convexity guarantee carries all the way to a certified joint optimum
;;; whenever the discrete space is enumerable; otherwise the result is reported
;;; honestly as a heuristic.
;;;
;;; SCALE. The whole state is hash-backed: spec membership, targets, priorities,
;;; caps, skill availability, the BOM, the reverse-BOM (consumers), the per-skill
;;; rollups — all O(1) lookups. `settle` is then O(S + E) (each spec and each
;;; recipe edge touched once). `relax` settles once per iteration and probes the
;;; line search in closed form; the marginal rollups (`aemb-*`) are cached across
;;; iterations and only rebuilt when the active set actually changes. So the
;;; continuous core is near-linear in the network and the iteration count is
;;; size-independent (convex + warm start). See the benchmark at the bottom.
;;;
;;; Run:  guile -L module module/playnet/deprecated/planner/attic/relaxation.scm

(define-module (playnet deprecated planner attic relaxation)
  #:use-module (ice-9 format)
  #:export (*specs* *recipes* *flows* *targets* *priority* *roster* *skill-avail*
            *caps* *sites* *all-skills* *ell-skill* *bom* *consumers* *finals?*
            *makeable?* *finals* *makeable* *tracked* *raw* *init* *recipes-by-output*
            *multi* *active* aref aput aadd href hadd! hfold mval *pbase* pweight
            *nsettle* worker-id worker-skills worker-hours worker-voice worker-loc
            worker-window *shift* *flows-by-proc* index-flows! flows-of recipe-out-qty
            recipe-work-pairs recipe-input-pairs cur currents->hash gap consumers
            leontief-forward settle *tbar* barrier bgrad harmony-of harmony
            leontief-adjoint *emb-l* emb-labour *emb-d* emb-draw analytic-pull pull
            default-config install-config! *aemb-l* *aemb-d* *aemb-sig* *Pcur* active?
            active-adjoint aemb-labour aemb-draw refresh-aemb! gauss-solve newton-dir
            relax *t0* *tmin* *tdecay* relax-cp n-constraints config-pressures
            roulette propose-config recompose *exact-budget* *restarts* config-space
            count-configs all-configs solve-discrete recipe-coeffs discrete-bound
            commit assign-labour haversine time-gap *kappa-space* *kappa-time* *emp*
            *emp-iters* mk-demand dem-spec dem-skill dem-hours dem-loc dem-win
            *spec-w* spec-W staff-value labour-demands prox-base emp-slope water-fill
            assign-emp metabolize *report?* sorted-alist worker-line report-labour
            report rspec rproc consume-flow work-flow produce-flow recipe eres cevent
            define-world! init-currents *seed* build-chain bench demo-triage))

(use-modules (srfi srfi-1) (ice-9 format)
             ;; the real labour matcher — pure, string-keyed (producer-proposing
             ;; deferred acceptance with voice tiebreak). We pass it plain
             ;; agent/slot strings, so its records never meet our VF records.
             (playnet planner algorithms deferred-acceptance))
;; schemas.scm has module identity now, so import it. The load-path gymnastics
;; this replaces existed only because it did not: current-filename is #f under
;; `guile -L …`, so the path had to be rediscovered three ways at run time.
(use-modules (playnet planner vf schemas))

;; ═══ static configuration (the surface's knowledge layer) ═══════════════════
;; Filled by `define-world!` at the bottom. These never change as events flow.
;; Everything random-access is a hash table → O(1) lookups, so settle is O(S+E).
(define *specs*    '())   ; list of <resource-specification>
(define *recipes*  '())   ; list of <recipe>
(define *flows*    '())   ; list of <recipe-flow>
(define *targets*  (make-hash-table))  ; spec-id -> desired on-hand (reproduction target)
(define *priority* (make-hash-table))  ; spec-id -> social-desire level (final goods only)
(define *roster*   '())   ; list of (worker-id (skill ...) hours-this-period voice)
(define *skill-avail* (make-hash-table)) ; skill-id -> A_k (person-hours available)
(define *caps*     (make-hash-table))  ; raw-spec-id -> per-period draw cap (envelope)
(define *sites*    (make-hash-table))  ; spec-id -> (lat lng start end): where/when its work happens
(define *all-skills* '()) ; every skill named by any recipe (for directional sweeps)

;; derived once from the recipes (per primary-output spec)
(define *ell-skill* (make-hash-table)) ; spec-id -> alist (skill-id . SNLT_direct hours/unit)
(define *bom*       (make-hash-table)) ; spec-id -> alist (input-spec-id . qty-per-unit)
(define *consumers* (make-hash-table)) ; spec-id -> list (consumer-spec-id . qty) [reverse BOM]
(define *finals?*   (make-hash-table)) ; membership: spec-id has social desire
(define *makeable?* (make-hash-table)) ; membership: spec-id has a recipe
(define *finals*    '())   ; iteration list of final spec-ids
(define *makeable*  '())   ; iteration list of makeable spec-ids
(define *tracked*   '())   ; on-hand stocks we track (finals ∪ makeable), deduped
(define *raw*       '())   ; spec-ids with no recipe (drawn, possibly capped)
(define *init*      (make-hash-table)) ; spec-id -> initial on-hand (from EconomicResources)
(define *recipes-by-output* (make-hash-table)) ; spec-id -> list of <recipe> (alternatives)
(define *multi*     '())   ; makeable specs with >1 recipe — the recomposable choices
(define *active*    '())   ; the installed configuration: alist spec-id -> chosen recipe-id
;; NB: *ell-skill* *bom* *consumers* and the emb memos are PER-CONFIGURATION,
;; rebuilt (in place) by `install-config!`; the core reads whichever is installed.

;; ═══ tiny helpers ═══════════════════════════════════════════════════════════
;; alists (used only for small, finals-sized structures: plan, dir, cfg, pairs)
(define (aref al k . d) (let ((p (assoc k al))) (if p (cdr p) (if (pair? d) (car d) #f))))
(define (aput al k v)   (acons k v (alist-delete k al)))
(define (aadd al k dv)  (aput al k (+ (or (aref al k) 0.0) dv)))
;; hash tables (used for everything spec-indexed)
(define (href h k . d)  (hash-ref h k (if (pair? d) (car d) #f)))
(define (hadd! h k dv)  (hash-set! h k (+ (hash-ref h k 0.0) dv)))
(define (hfold proc init h)             ; (proc key val acc) — portable hash fold
  (let ((acc init)) (hash-for-each (lambda (k v) (set! acc (proc k v acc))) h) acc))
(define (mval m)        (if m (measure-has-numerical-value m) 0.0))
(define *pbase* 2.1544346900318843)            ; base^9 ≈ 1000
(define (pweight lvl)   (expt *pbase* lvl))
(define *nsettle* 0)                            ; instrumentation (used by the benchmark)

;; ═══ the worker roster (a tuple per person) ═════════════════════════════════
;; (id (skill …) hours voice (lat . lng) (avail-start . avail-end))
;; loc/window are optional (#f ⇒ no spatial / no temporal constraint).
(define (worker-id     w) (list-ref w 0))
(define (worker-skills w) (list-ref w 1))      ; skills this body can perform
(define (worker-hours  w) (list-ref w 2))      ; hours available this period (capacity)
(define (worker-voice  w) (list-ref w 3))      ; voice weight — DA tiebreak
(define (worker-loc    w) (and (> (length w) 4) (list-ref w 4)))   ; (lat . lng) or #f
(define (worker-window w) (and (> (length w) 5) (list-ref w 5)))   ; (start . end) hrs or #f
(define *shift* 8.0)                            ; one work-slot = an 8-hour shift

;; ═══ reading the recipe graph (direct labour + BOM from RecipeFlows) ════════
;; flows indexed by process-id (built in define-world!) so flows-of is O(flows
;; in this recipe's processes), not O(all flows) — keeps world-building linear.
(define *flows-by-proc* (make-hash-table))
(define (index-flows! flows)
  (hash-clear! *flows-by-proc*)
  (for-each (lambda (f)
              (for-each (lambda (p)
                          (when p (hash-set! *flows-by-proc* p
                                             (cons f (href *flows-by-proc* p '())))))
                        (list (recipe-flow-recipe-input-of f)
                              (recipe-flow-recipe-output-of f))))
            flows))
(define (flows-of recipe)
  (delete-duplicates
   (append-map (lambda (p) (href *flows-by-proc* p '()))
               (or (recipe-recipe-processes recipe) '()))))

(define (recipe-out-qty recipe)
  (let ((outs (filter (lambda (f) (eq? (recipe-flow-action f) 'produce)) (flows-of recipe))))
    (if (null? outs) 1.0 (mval (recipe-flow-resource-quantity (car outs))))))

(define (recipe-work-pairs recipe)               ; (skill . hours) per work flow
  (filter-map (lambda (f)
                (and (eq? (recipe-flow-action f) 'work)
                     (cons (or (recipe-flow-resource-conforms-to f) "labour")
                           (mval (recipe-flow-effort-quantity f)))))
              (flows-of recipe)))

(define (recipe-input-pairs recipe)              ; (input-spec . qty) for consume/use
  (filter-map (lambda (f)
                (and (memq (recipe-flow-action f) '(consume use))
                     (cons (recipe-flow-resource-conforms-to f)
                           (mval (recipe-flow-resource-quantity f)))))
              (flows-of recipe)))

;; ═══ state = the `currents` alist (spec-id -> on-hand), threaded ════════════
(define (cur currents id) (or (aref currents id) (href *init* id) 0.0))
(define (currents->hash currents)                ; init overlaid by currents → O(1) reads
  (let ((h (make-hash-table)))
    (hash-for-each (lambda (k v) (hash-set! h k v)) *init*)
    (for-each (lambda (kv) (hash-set! h (car kv) (cdr kv))) currents)
    h))
(define (gap id current)
  (let ((tgt (href *targets* id 0.0)))
    (if (<= tgt 0.0) 0.0 (max 0.0 (/ (- tgt current) tgt)))))
(define (consumers id) (href *consumers* id '()))

;; ═══ the Leontief FORWARD solve  x = P·y,  P = (I−A)⁻¹  ══════════════════════
;; production of every spec given the demand over finals: finals from the plan,
;; intermediates derived to cover downstream consumption (net of on-hand),
;; raw drawn (not produced). Memoised recursion = the cascade. O(S + E): each
;; spec memoised once, each reverse-BOM edge traversed once. Its transpose is the
;; crystallized-SNLT adjoint below (`leontief-adjoint`); together they are the
;; forward and reverse passes of one differentiable program.
(define (leontief-forward ch ph)                 ; ch,ph: current/plan hashes → x = P·y
  (let ((memo (make-hash-table)))
    (define (prod id)
      (or (hash-ref memo id)
          (let* ((demand (fold (lambda (ce a) (+ a (* (prod (car ce)) (cdr ce))))
                               0.0 (consumers id)))
                 (p (cond ((hash-ref *finals?* id #f)   (href ph id 0.0))
                          ((hash-ref *makeable?* id #f) (max 0.0 (- demand (href ch id 0.0))))
                          (else                         0.0))))   ; raw: drawn, not made
            (hash-set! memo id p) p)))
    (for-each (lambda (s) (prod (resource-specification-id s))) *specs*)
    memo))

;; settle a plan → resulting currents, per-skill labour, raw draws (for caps).
;; All three results are hash tables (spec/skill keyed) so downstream lookups
;; in harmony/probe are O(1). `labskill` = skill-id -> direct person-hours.
(define (settle currents plan)
  (set! *nsettle* (+ *nsettle* 1))
  (let* ((ch   (currents->hash currents))
         (ph   (let ((h (make-hash-table)))
                 (for-each (lambda (kv) (hash-set! h (car kv) (cdr kv))) plan) h))
         (P    (leontief-forward ch ph))
         (prod (lambda (id) (hash-ref P id 0.0)))
         (consumed (lambda (id) (fold (lambda (ce a) (+ a (* (prod (car ce)) (cdr ce))))
                                      0.0 (consumers id))))
         (labskill (make-hash-table))
         (raws     (make-hash-table))
         (curs     (make-hash-table)))
    (for-each (lambda (id)
                (let ((p (prod id)))
                  (for-each (lambda (sk) (hadd! labskill (car sk) (* p (cdr sk))))
                            (href *ell-skill* id '()))))
              *makeable*)
    (for-each (lambda (id) (hash-set! raws id (consumed id))) *raw*)
    (for-each (lambda (id) (hash-set! curs id (+ (href ch id 0.0) (prod id) (- (consumed id)))))
              *tracked*)
    (values curs labskill raws P)))

;; ═══ tension → harmony → pull ═══════════════════════════════════════════════
;; *tbar* is the interior-point barrier parameter (the user's `t`): harmony is
;; desire − *tbar*·Σ log-barriers. Large *tbar* ⇒ deep interior (near the analytic
;; centre, big safety margin); *tbar*→0 ⇒ the true constrained optimum (exact KKT).
;; The central-path follower `relax-cp` sweeps it down, warm-started. The duality
;; gap of the point it stops at is bounded by m·*tbar* (m = # inequality
;; constraints) — a printed certificate of near-optimality.
(define *tbar* 4.0)
(define (barrier used cap)                       ; hard possibility-tension
  (cond ((>= used cap) 1e9)
        (else (* *tbar* (- (log (/ (- cap used) cap)))))))
(define (bgrad used cap)                          ; d(barrier)/d(use) = *tbar*/(cap-use)
  (if (>= used cap) 1e6 (/ *tbar* (- cap used))))

;; harmony read straight off an already-settled (curs labskill raws) triple —
;; no cascade. This is the single definition of harmony; `harmony` settles to
;; obtain the triple, the line search computes the triple incrementally.
(define (harmony-of curs labskill raws)
  (- 0.0
     ;; soft: desire-tensions on final goods
     (fold (lambda (id a) (+ a (* (pweight (href *priority* id 0))
                                  (expt (gap id (href curs id 0.0)) 2))))
           0.0 *finals*)
     ;; hard: per-skill labour availability — one barrier per skill
     (hfold (lambda (k use a) (+ a (barrier use (href *skill-avail* k 1e9)))) 0.0 labskill)
     ;; hard: ecological / capped raw draws
     (hfold (lambda (r d a) (let ((cap (href *caps* r #f)))
                              (if cap (+ a (barrier d cap)) a)))
            0.0 raws)))

(define (harmony currents plan)
  (call-with-values (lambda () (settle currents plan))
    (lambda (curs labskill raws P) (harmony-of curs labskill raws))))

;; ── crystallized SNLT = the Leontief ADJOINT  ℓ̂ = Pᵀ·direct  ──────────────────
;; `productions` above is the forward cascade x = P·y (P = (I−A)⁻¹). Crystallized
;; SNLT is its transpose: the living labour (or ecological draw) a good has
;; summoned up its WHOLE cascade. One adjoint rollup, parameterised by the per-
;; stage `direct` quantity, serves both labour and draws:
;;     adjoint(i) = direct(i) + Σ_{j∈BOM(i)} a_{ij}·adjoint(j).
;; The scalar, min-over-producers, joint-split form of this recursion is the one
;; value rollup, algorithms/rollup/fixpoint.scm `crystallize` (the engine and the
;; credit pool both read it). This module's VECTOR form — ℓ̂ per skill k (emb-labour),
;; d̂ per raw (emb-draw) — fed `analytic-pull` below, the pre-solver prototype of the
;; pull computed OUTSIDE a solve. In the engine that pull is the solve's own dual —
;; λ(k,c) on the Lab|skill|cell rows, μ(g) on the goods, stationarity joining them
;; through the technology matrix — so the per-skill, per-cell weighting is live
;; there with no second computation. A vector accumulator's remaining use is as a
;; DECOMPOSITION for inspection: which skill's tightness a dual comes from.
;; Memoised per configuration (cleared by install-config!). A final's pull uses
;; these so it already carries every upstream tension — loudness propagating.
(define (leontief-adjoint id tag direct memo)    ; ℓ̂(id) for one `direct` field
  (let ((key (string-append id "|" tag)))
    (or (hash-ref memo key)
        (let ((v (+ (direct id)
                    (fold (lambda (io a) (+ a (* (cdr io) (leontief-adjoint (car io) tag direct memo))))
                          0.0 (href *bom* id '())))))
          (hash-set! memo key v) v))))
(define *emb-l* (make-hash-table))               ; crystallized skill-k SNLT per spec
(define (emb-labour id k) (leontief-adjoint id k (lambda (i) (aref (href *ell-skill* i '()) k 0.0)) *emb-l*))
(define *emb-d* (make-hash-table))               ; crystallized draw of a raw per spec
(define (emb-draw id raw) (leontief-adjoint id raw (lambda (i) (aref (href *bom* i '()) raw 0.0)) *emb-d*))

;; pull = WANT − COST: priority-weighted desire, minus the crystallized SNLT and
;; draw the good summons, each valued at how tight its envelope is (bgrad = the
;; scarcity pull λ/μ). The COST is the adjoint carrying the duals back to the good.
(define (analytic-pull id curs labskill raws)
  (let* ((w (pweight (href *priority* id 0)))
         (T (href *targets* id 1.0))
         (c (href curs id 0.0))
         (want (/ (* 2.0 w (gap id c)) T))                     ; priority-weighted desire
         (cost-labour (hfold (lambda (k use a)                  ; Σ ℓ̂(d,k)·λ_k
                               (+ a (* (emb-labour id k) (bgrad use (href *skill-avail* k 1e9)))))
                             0.0 labskill))
         (cost-eco    (hfold (lambda (r d a)                    ; Σ d̂(d,r)·μ_r
                               (let ((cp (href *caps* r #f)))
                                 (if cp (+ a (* (emb-draw id r) (bgrad d cp))) a)))
                             0.0 raws)))
    (- want cost-labour cost-eco)))

(define (pull currents plan id)                  ; report wrapper (settle once)
  (call-with-values (lambda () (settle currents plan))
    (lambda (curs labskill raws P) (analytic-pull id curs labskill raws))))

;; ── installing a configuration (which recipe makes each good) ───────────────
;; Picks one recipe per makeable spec; derives the per-config ell-skill / bom /
;; consumers IN PLACE (mutating the installed tables) and clears all rollup
;; memos — including the active-set marginal cache, since the BOM changed.
(define (default-config)
  (hfold (lambda (spec recs acc) (acons spec (recipe-id (car recs)) acc))
         '() *recipes-by-output*))

(define (install-config! cfg)
  (hash-clear! *ell-skill*) (hash-clear! *bom*) (hash-clear! *consumers*)
  (hash-clear! *emb-l*) (hash-clear! *emb-d*) (hash-clear! *spec-w*)
  (hash-clear! *aemb-l*) (hash-clear! *aemb-d*) (set! *aemb-sig* #f)
  (for-each
   (lambda (sc)
     (let* ((r   (find (lambda (x) (equal? (recipe-id x) (cdr sc))) *recipes*))
            (out (recipe-out-qty r)))
       (hash-set! *ell-skill* (car sc)
                  (fold (lambda (p acc) (aadd acc (car p) (/ (cdr p) out)))
                        '() (recipe-work-pairs r)))
       (hash-set! *bom* (car sc)
                  (map (lambda (p) (cons (car p) (/ (cdr p) out)))
                       (recipe-input-pairs r)))))
   cfg)
  (hash-for-each (lambda (spec inputs)
                   (for-each (lambda (io)
                               (hash-set! *consumers* (car io)
                                          (cons (cons spec (cdr io)) (consumers (car io)))))
                             inputs))
                 *bom*)
  (set! *active* cfg))

;; ── active-set marginal rollups (`aemb-*`), cached across relax iterations ───
;; The exact directional derivative of (labour, draws) wrt producing one more of
;; a final: it flows real production only through intermediates actually being
;; made (prod>0); an intermediate covered by on-hand absorbs the marginal from
;; stock, contributing nothing. So we zero every branch through an inactive
;; intermediate. These tables depend only on the ACTIVE SET, not on production
;; values, so we keep them across iterations and rebuild only when the active
;; set changes (signature check) — install-config! clears them on a BOM change.
(define *aemb-l* (make-hash-table))
(define *aemb-d* (make-hash-table))
(define *aemb-sig* #f)
(define *Pcur* (make-hash-table))
(define (active? id) (> (hash-ref *Pcur* id 0.0) 0.0))
;; the same Leontief adjoint, but only flowing through ACTIVE inputs (prod>0) —
;; the exact directional derivative for the current active set.
(define (active-adjoint id tag direct memo)
  (let ((key (string-append id "|" tag)))
    (or (hash-ref memo key)
        (let ((v (+ (direct id)
                    (fold (lambda (io a) (+ a (if (active? (car io))
                                                  (* (cdr io) (active-adjoint (car io) tag direct memo)) 0.0)))
                          0.0 (href *bom* id '())))))
          (hash-set! memo key v) v))))
(define (aemb-labour id k) (active-adjoint id k (lambda (i) (aref (href *ell-skill* i '()) k 0.0)) *aemb-l*))
(define (aemb-draw id raw) (active-adjoint id raw (lambda (i) (aref (href *bom* i '()) raw 0.0)) *aemb-d*))
(define (refresh-aemb! P)                         ; point at P; rebuild iff active set changed
  (set! *Pcur* P)
  (let ((sig (sort (filter (lambda (id) (> (hash-ref P id 0.0) 0.0)) *makeable*) string<?)))
    (unless (equal? sig *aemb-sig*)
      (hash-clear! *aemb-l*) (hash-clear! *aemb-d*) (set! *aemb-sig* sig))))

;; ═══ the relaxation step — monotone gradient ascent on the convex core ══════
;; Concave maximisation over a convex set ⇒ no spurious local optima; gradient
;; ascent (analytic pulls, diagonal-Newton–preconditioned by desire curvature
;; 2w/T²) reaches the GLOBAL optimum, harmony never decreasing. Step by a
;; backtracking line search; converge when no improving step exists. Warm-started
;; from the previous plan.
;;
;; INCREMENTAL line search: settle ONCE per iteration (base triple + direction).
;; Along a fixed direction the cascade is linear while the active set holds, so
;; the (labour, draws) response to a step η·dir is dir projected through the
;; ACTIVE rollups (aemb-*, cached). Each probe then evaluates harmony in closed
;; form (no settle). A large η can flip the active set, so we VERIFY each
;; candidate with one true settle and accept only if true harmony rises — exact
;; monotonicity, while the cheap probe keeps it to ~one settle per accepted step.
;;
;; [Chaos/annealing belongs to the DISCRETE layer — recipe recomposition,
;;  minimum batch quantities, atomic skills — which is non-convex. Not here.]

;; ── full-Newton centring direction ──────────────────────────────────────────
;; The DIAGONAL preconditioner dir_f = g_f/(2w/T²) is blind to how two finals
;; couple through a SHARED scarce skill or ecological cap. Full Newton uses the
;; exact Hessian of −harmony in the active region:
;;     −H = diag(2w_f/T_f²)  +  Σ_k B''_k · ℓ̂_k ℓ̂_kᵀ  +  Σ_r B''_r · d̂_r d̂_rᵀ
;; the desire curvature (the old diagonal) PLUS one structured rank-Σ term, built
;; from the SAME crystallized adjoints (ℓ̂ = aemb-labour, d̂ = aemb-draw) and the
;; barrier curvature B''(use,cap) = *tbar*/(cap−use)². −H is SPD (positive
;; diagonal + PSD outer products) ⇒ dir = (−H)⁻¹ g by a small dense solve over
;; the finals. Near a binding wall B''→∞ along that ray, so Newton scales the
;; step down automatically — exactly the conditioning the diagonal lacks.
(define (gauss-solve A b n)        ; solve A x = b ; A n×n (vec of row-vecs), b vec
  (let ((M (make-vector n)) (x (make-vector n 0.0)))
    (do ((i 0 (+ i 1))) ((= i n))                    ; augmented working copy [A|b]
      (let ((row (make-vector (+ n 1) 0.0)))
        (do ((j 0 (+ j 1))) ((= j n)) (vector-set! row j (vector-ref (vector-ref A i) j)))
        (vector-set! row n (vector-ref b i))
        (vector-set! M i row)))
    (do ((c 0 (+ c 1))) ((= c n))                    ; forward elim w/ partial pivot
      (let ((piv c) (best (abs (vector-ref (vector-ref M c) c))))
        (do ((r (+ c 1) (+ r 1))) ((= r n))
          (let ((v (abs (vector-ref (vector-ref M r) c))))
            (when (> v best) (set! best v) (set! piv r))))
        (let ((tmp (vector-ref M c))) (vector-set! M c (vector-ref M piv)) (vector-set! M piv tmp))
        (let ((d (vector-ref (vector-ref M c) c)))
          (when (> (abs d) 1e-15)
            (do ((r (+ c 1) (+ r 1))) ((= r n))
              (let ((f (/ (vector-ref (vector-ref M r) c) d)))
                (do ((j c (+ j 1))) ((> j n))
                  (vector-set! (vector-ref M r) j
                               (- (vector-ref (vector-ref M r) j)
                                  (* f (vector-ref (vector-ref M c) j)))))))))))
    (do ((i (- n 1) (- i 1))) ((< i 0))              ; back substitution
      (let ((s (vector-ref (vector-ref M i) n)))
        (do ((j (+ i 1) (+ j 1))) ((= j n))
          (set! s (- s (* (vector-ref (vector-ref M i) j) (vector-ref x j)))))
        (let ((d (vector-ref (vector-ref M i) i)))
          (vector-set! x i (if (> (abs d) 1e-15) (/ s d) 0.0)))))
    x))

(define (newton-dir curs labskill raws)
  (let* ((fv (list->vector *finals*)) (n (vector-length fv))
         (g  (make-vector n 0.0)) (A (make-vector n)))
    (do ((i 0 (+ i 1))) ((= i n)) (vector-set! A i (make-vector n 0.0)))
    (do ((i 0 (+ i 1))) ((= i n))                    ; g = pull ; desire curvature on diag
      (let* ((fi (vector-ref fv i)) (w (pweight (href *priority* fi 0))) (T (href *targets* fi 1.0)))
        (vector-set! g i (analytic-pull fi curs labskill raws))
        (vector-set! (vector-ref A i) i (max 1e-6 (/ (* 2.0 w) (* T T))))))
    (define (rank-add! used-tbl cap-of adj)          ; += Σ B''·â âᵀ over one constraint set
      (hash-for-each
       (lambda (key used)
         (let ((cap (cap-of key)))
           (when (and cap (< used cap))
             (let ((Bpp (/ *tbar* (let ((s (- cap used))) (* s s)))))
               (do ((i 0 (+ i 1))) ((= i n))
                 (let ((ai (adj (vector-ref fv i) key)))
                   (unless (= ai 0.0)
                     (do ((j 0 (+ j 1))) ((= j n))
                       (let ((row (vector-ref A i)))
                         (vector-set! row j (+ (vector-ref row j)
                                               (* Bpp ai (adj (vector-ref fv j) key)))))))))))))
       used-tbl))
    (rank-add! labskill (lambda (k) (href *skill-avail* k #f)) aemb-labour)
    (rank-add! raws     (lambda (r) (href *caps* r #f))        aemb-draw)
    (let ((x (gauss-solve A g n)))
      (map (lambda (i) (cons (vector-ref fv i) (vector-ref x i))) (iota n)))))

(define (relax currents warm iters)
  (let loop ((p warm) (i 0))
    (if (>= i iters)
        p
        (call-with-values (lambda () (settle currents p))
          (lambda (curs labskill raws P)
            (refresh-aemb! P)                       ; cached unless the active set moved
            (let* ((h0  (harmony-of curs labskill raws))   ; base, no extra settle
                   (dir (newton-dir curs labskill raws))   ; (−H)⁻¹·pull (full Newton)
                   ;; directional sensitivities (hashes), via the ACTIVE rollups
                   (dlab (let ((h (make-hash-table)))
                           (for-each (lambda (k)
                                       (hash-set! h k (fold (lambda (df a)
                                                              (+ a (* (cdr df) (aemb-labour (car df) k))))
                                                            0.0 dir)))
                                     *all-skills*)
                           h))
                   (draw (let ((h (make-hash-table)))
                           (hash-for-each
                            (lambda (r _)
                              (hash-set! h r (fold (lambda (df a)
                                                     (+ a (* (cdr df) (aemb-draw (car df) r))))
                                                   0.0 dir)))
                            raws)
                           h)))
              ;; incremental harmony of the η-step along dir (no settle)
              (define (probe eta)
                (let* ((plan* (fold (lambda (df acc)
                                      (aput acc (car df)
                                            (max 0.0 (+ (or (aref acc (car df)) 0.0)
                                                        (* eta (cdr df))))))
                                    p dir))
                       (curs* (let ((h (make-hash-table)))   ; terminal finals: exact
                                (for-each (lambda (f)
                                            (hash-set! h f (+ (href curs f 0.0)
                                                              (- (or (aref plan* f) 0.0)
                                                                 (or (aref p f) 0.0)))))
                                          *finals*)
                                h))
                       (lab*  (let ((h (make-hash-table)))
                                (hash-for-each (lambda (k dv)
                                                 (hash-set! h k (+ (href labskill k 0.0) (* eta dv))))
                                               dlab)
                                h))
                       (raw*  (let ((h (make-hash-table)))
                                (hash-for-each (lambda (r d)
                                                 (hash-set! h r (+ d (* eta (href draw r 0.0)))))
                                               raws)
                                h)))
                  (cons plan* (harmony-of curs* lab* raw*))))
              (let ls ((eta 1.0))                       ; backtracking line search
                (let ((sp (probe eta)))
                  (cond ((and (> (cdr sp) (+ h0 1e-9))          ; promising on the cheap model…
                              (> (harmony currents (car sp)) (+ h0 1e-9)))  ; …and truly rises
                         (loop (car sp) (+ i 1)))               ; monotone ↑ (verified)
                        ((< eta 1e-4) p)                  ; no improving step → converged
                        (else (ls (* eta 0.5))))))))))))

;; ═══ central-path follower (interior-point) ═════════════════════════════════
;; `relax` centres at a FIXED *tbar* (one point of the central path). To reach
;; the true constrained optimum we follow the path: start deep in the interior
;; (large *tbar*), centre, then shrink *tbar* and re-centre — WARM-STARTED, so
;; each solve is a small step along the path. Each centre is now a FULL-Newton
;; solve (`newton-dir`), so it converges quadratically and survives the
;; ill-conditioning near a binding wall. As *tbar*→0 the iterate tends
;; to the optimum, complementary slackness λ·slack = *tbar* → 0 (exact KKT in the
;; limit), and the duality gap is bounded by m·*tbar*. We stop at *tmin* and
;; report that bound — so the residual interior margin is a KNOWN, tunable gap.
(define *t0*     4.0)     ; start (deep interior — the old fixed barrier)
(define *tmin*   0.02)    ; stop (near the optimum); gap ≤ m·*tmin*
(define *tdecay* 0.35)    ; geometric path schedule
(define (relax-cp currents warm iters)
  (let loop ((t *t0*) (p warm))
    (set! *tbar* t)
    (let ((p* (relax currents p iters)))          ; centre at this t, warm-started
      (if (<= t *tmin*) p* (loop (max *tmin* (* t *tdecay*)) p*)))))
(define (n-constraints)                           ; m = active inequality constraints
  (+ (hash-fold (lambda (k v a) (if (< v 1e8) (+ a 1) a)) 0 *skill-avail*)
     (hash-count (const #t) *caps*)))

;; ═══ the discrete layer — which recipe makes each good ══════════════════════
;; The continuous core is convex, but CHOOSING which recipe makes each good is
;; discrete and non-convex (NP-hard in general). Two regimes, and we always know
;; which one we're in:
;;
;;   • SMALL  (∏ alternatives ≤ *exact-budget*): ENUMERATE every configuration,
;;     convex-solve each, keep the best → a CERTIFIED GLOBAL optimum of the whole
;;     joint problem (the convex core is global per config, and we tried them
;;     all). Deterministic. This is the regime every realistic local solve is in,
;;     because only the goods *near a binding constraint* have a live choice.
;;
;;   • LARGE: simulated annealing with pull-biased proposals and restarts —
;;     a heuristic, reported honestly as uncertified. When a possibility-tension
;;     binds (soil envelope, scarce bakers) recomposing onto a recipe that leans
;;     elsewhere (cassava, pastry) raises harmony, and the search finds it.
;;
;; The convexity guarantee thus carries all the way to a joint global optimum
;; whenever the discrete space is enumerable.

;; pressure(spec) = how hard this spec's recipe presses on a binding constraint
;; — the pull-back term of analytic-pull. High pressure = flipping it is the
;; promising move; we bias proposals by it (annealing branch).
(define (config-pressures currents plan)
  (call-with-values (lambda () (settle currents plan))
    (lambda (curs labskill raws P)
      (map (lambda (spec)
             (cons spec
                   (+ (hfold (lambda (k use a)
                               (+ a (* (emb-labour spec k) (bgrad use (href *skill-avail* k 1e9)))))
                             0.0 labskill)
                      (hfold (lambda (r d a)
                               (let ((cp (href *caps* r #f)))
                                 (if cp (+ a (* (emb-draw spec r) (bgrad d cp))) a)))
                             0.0 raws))))
           *multi*))))

(define (roulette weighted)                      ; pick a key ∝ its (≥0) weight
  (let ((tot (fold (lambda (kv a) (+ a (max 0.0 (cdr kv)))) 0.0 weighted)))
    (if (<= tot 0.0)
        (list-ref (map car weighted) (random (length weighted)))   ; flat: explore freely
        (let lp ((ws weighted) (r (* (random:uniform) tot)) (acc 0.0))
          (let ((acc2 (+ acc (max 0.0 (cdar ws)))))
            (if (or (null? (cdr ws)) (>= acc2 r)) (caar ws) (lp (cdr ws) r acc2)))))))

(define (propose-config cfg pressures)
  (if (null? *multi*) cfg
      (let* ((spec (roulette pressures))         ; the spec most under tension, biased
             (alts (map recipe-id (href *recipes-by-output* spec '()))))
        (aput cfg spec (list-ref alts (random (length alts)))))))

(define (recompose currents warm-plan warm-cfg outer inner)
  (install-config! warm-cfg)
  (let* ((plan0 (relax-cp currents warm-plan inner)) (h0 (harmony currents plan0)))
    (let loop ((cfg warm-cfg) (plan plan0) (h h0)
               (bc warm-cfg) (bp plan0) (bh h0) (i 0) (temp 2.0))
      (if (>= i outer)
          (begin (install-config! bc) (values bc bp))      ; leave the best installed
          ;; cfg is installed at loop entry, so pressures reflect it
          (let ((cfg* (propose-config cfg (config-pressures currents plan))))
            (install-config! cfg*)
            (let* ((plan* (relax-cp currents plan inner))   ; convex core, warm-started
                   (h*    (harmony currents plan*)))
              (if (or (>= h* h) (< (random:uniform) (exp (/ (- h* h) (max 1e-6 temp)))))
                  (loop cfg* plan* h*
                        (if (> h* bh) cfg* bc) (if (> h* bh) plan* bp) (max bh h*)
                        (+ i 1) (* temp 0.7))
                  (begin (install-config! cfg)              ; reject: restore globals
                         (loop cfg plan h bc bp bh (+ i 1) (* temp 0.7))))))))))

;; ── the configuration space (cartesian product over goods with a choice) ────
(define *exact-budget* 4096)                     ; enumerate exactly up to this many configs
(define *restarts*     3)                        ; independent anneals in the large regime
(define (config-space)                            ; ((spec alt …) …) for multi-recipe goods
  (map (lambda (s) (cons s (map recipe-id (href *recipes-by-output* s '())))) *multi*))
(define (count-configs) (fold (lambda (kv n) (* n (length (cdr kv)))) 1 (config-space)))
(define (all-configs)                             ; every full config, built on the default base
  (fold (lambda (kv acc)
          (append-map (lambda (cfg) (map (lambda (alt) (aput cfg (car kv) alt)) (cdr kv))) acc))
        (list (default-config)) (config-space)))

;; solve the discrete layer → (values best-cfg best-plan exact? n-configs).
;; EXACT when the space is small enough (certified global), else annealed.
(define (solve-discrete currents warm-plan warm-cfg outer inner)
  (let ((n (count-configs)))
    (if (<= n *exact-budget*)
        ;; enumerate every config, convex-solve each (warm-started), keep the best
        (let loop ((cfgs (all-configs)) (bc #f) (bp #f) (bh -inf.0))
          (if (null? cfgs)
              (begin (install-config! bc) (values bc bp #t n))
              (begin (install-config! (car cfgs))
                     (let* ((p (relax-cp currents warm-plan inner)) (h (harmony currents p)))
                       (if (> h bh) (loop (cdr cfgs) (car cfgs) p h)
                           (loop (cdr cfgs) bc bp bh))))))
        ;; large space: best of several independent anneals
        (let loop ((r 0) (bc warm-cfg) (bp warm-plan) (bh -inf.0))
          (if (>= r *restarts*)
              (begin (install-config! bc) (values bc bp #f n))
              (call-with-values (lambda () (recompose currents warm-plan warm-cfg outer inner))
                (lambda (c p)
                  (let ((h (harmony currents p)))
                    (if (> h bh) (loop (+ r 1) c p h) (loop (+ r 1) bc bp bh))))))))))

;; ── Lagrangian dual bound: certify the discrete choice (Fenchel) ────────────
;; Ĝ = Σ_k B*(λ_k) + Σ_r B*(μ_r) + Σ_f g_f(ĉ_f) ≥ max over ALL configs of harmony,
;; for the solution's own barrier-gradient pulls (= the duals) (λ_k = t/(A_k−L_k), …). Fenchel:
;; −B(x) ≤ B*(λ) − λx lifts each barrier to a linear pull, which decouples the
;; recipe choice — so ĉ_f, the cheapest pull-weighted crystallized cost of final f, is a
;; per-good min over recipes (a relaxation ⇒ the bound stays an UPPER bound). It
;; turns the exponential config product into a sum over goods, and is TIGHT at the
;; optimum (Fenchel equality), so the printed gap is the cost of the heuristic.
(define (recipe-coeffs r)                          ; per-unit (ell-by-skill . input-by-spec)
  (let ((out (recipe-out-qty r)))
    (cons (fold (lambda (p acc) (aadd acc (car p) (/ (cdr p) out))) '() (recipe-work-pairs r))
          (map  (lambda (p) (cons (car p) (/ (cdr p) out))) (recipe-input-pairs r)))))
(define (discrete-bound currents plan)
  (call-with-values (lambda () (settle currents plan))
    (lambda (curs labskill raws P)
      (define t *tbar*)
      (define (lamk k) (/ t (max 1e-9 (- (href *skill-avail* k 1e9) (href labskill k 0.0)))))
      (define (mur r)  (let ((c (href *caps* r #f))) (if c (/ t (max 1e-9 (- c (href raws r 0.0)))) 0.0)))
      (define (Bstar l cap) (- (* l cap) t (* t (log (max 1e-12 (/ (* l cap) t))))))
      (define memo (make-hash-table))
      (define (cheap g)                            ; min pull-weighted crystallized cost per unit of g
        (cond ((member g *raw*) 0.0)
              ((hash-ref memo g))
              (else
               (let* ((alts (href *recipes-by-output* g '()))
                      (v (if (null? alts) 0.0
                             (apply min (map (lambda (r)
                               (let ((co (recipe-coeffs r)))
                                 (+ (fold (lambda (p a) (+ a (* (lamk (car p)) (cdr p)))) 0.0 (car co))
                                    (fold (lambda (io a) (+ a (if (member (car io) *raw*)
                                                                  (* (mur (car io)) (cdr io))
                                                                  (* (cdr io) (cheap (car io))))))
                                          0.0 (cdr co)))))
                               alts)))))
                 (hash-set! memo g v) v))))
      (define (gf w T s c)                         ; max_q [−w((s−q)/T)² − c q]
        (cond ((<= s 0.0) 0.0)
              ((<= c (/ (* 2.0 w s) (* T T))) (- (/ (* c c T T) (* 4.0 w)) (* c s)))
              (else (* (- w) (expt (/ s T) 2)))))
      (+ (fold (lambda (k a) (+ a (Bstar (lamk k) (href *skill-avail* k 1e9)))) 0.0
               (filter (lambda (k) (< (href *skill-avail* k 1e9) 1e8)) *all-skills*))
         (hash-fold (lambda (r cap a) (+ a (Bstar (mur r) cap))) 0.0 *caps*)
         (fold (lambda (f a)
                 (+ a (gf (pweight (href *priority* f 0)) (href *targets* f 1.0)
                          (max 0.0 (- (href *targets* f 0.0) (cur currents f))) (cheap f))))
               0.0 *finals*)))))

;; apply a chosen plan: the period's production is realised; currents move
(define (commit currents plan)
  (call-with-values (lambda () (settle currents plan))
    (lambda (curs labskill raws P)
      (hfold (lambda (id v acc) (aput acc id v)) currents curs))))

;; ═══ the matched flow: assign named workers to the period's work-slots ═══════
;; The convex core decides HOW MUCH skill-k labour the plan needs (labskill);
;; this turns that into WHO does it. We slice each skill's hours into shift-sized
;; slots (capacity 1) and hand the real deferred-acceptance matcher a preference
;; list — voice breaking contention. To let one person work several shifts, each
;; worker is expanded into ⌊hours/shift⌋ "seats" (id~1, id~2, …), each ranking
;; only the slots whose skill the worker holds; we collapse seats back to the
;; person on the way out. Returns the stable assignment alist (slot-key . worker).
(define (assign-labour labskill)
  (let* ((slots (hfold
                 (lambda (k used acc)
                   (let ((n (inexact->exact (ceiling (/ used *shift*)))))
                     (append (map (lambda (i) (cons (format #f "~a#~a" k (+ i 1)) k))
                                  (iota (max 0 n)))
                             acc)))
                 '() labskill))
         (slot-keys  (map car slots))
         (slot-skill (lambda (s) (aref slots s)))
         (seats (append-map
                 (lambda (w)
                   (let ((mine (filter (lambda (s) (member (slot-skill s) (worker-skills w)))
                                       slot-keys))
                         (cap  (max 1 (inexact->exact (floor (/ (worker-hours w) *shift*))))))
                     (if (null? mine) '()
                         (map (lambda (j)
                                (make-producer-prefs
                                 (format #f "~a~~~a" (worker-id w) (+ j 1))
                                 mine (worker-voice w)))
                              (iota cap)))))
                 *roster*))
         (seat-worker (lambda (seat) (car (string-split seat #\~)))))
    (if (null? slot-keys) '()
        (map (lambda (kv) (cons (car kv) (seat-worker (cdr kv))))
             (deferred-acceptance seats slot-keys)))))

;; ═══ spatiotemporal proximity as TENSION (the cooperative matcher) ══════════
;; Instead of skill being a hard filter and DA giving a stable matching, we make
;; *who works where* a min-tension assignment — the same harmony principle, now
;; over labour. The tensions compose, and the optimum balances them:
;;   • proximity (space): travel distance worker→site is a soft cost.
;;   • proximity (time): mismatch between a worker's window and the shift's.
;;   • EMP (equal sharing): a CONVEX per-worker load cost, so piling work on one
;;     body hurts more and more — minimising it spreads work evenly among the
;;     equally-skilled. EMP is what minimising a convex load tension *does*.
;;   • availability (HARD): a worker cannot exceed their hours — a wall the
;;     water level cannot cross (capped water-filling).
;;   • priority (TRIAGE): leaving a demand unstaffed costs a tension equal to the
;;     served good's weight (spec-W). The water level never rises above that
;;     value, so when labour is scarce the cheap-to-shed (low-priority) work goes
;;     unmet first and scarce hands flow to what matters most.
;; Skill stays hard (you can't bake without the skill). The result is still a
;; convex transportation problem ⇒ a single global optimum, found by equal-
;; marginal water-filling (which IS the Equal Marginal Principle as an algorithm).
;;
;; Primitives mirror (playnet planner matching {spatial,availability}); we
;; reimplement the two pure kernels locally so the planner stays standalone (the
;; modules transitively import the umbrella, which won't compile, and use window
;; record types we can't share across our primitive-load boundary).
(define (haversine a b)                          ; great-circle km; #f loc ⇒ 0 (remote)
  (if (or (not a) (not b)) 0.0
      (let* ((d2r (/ 3.141592653589793 180.0))
             (la1 (* d2r (car a))) (la2 (* d2r (car b)))
             (dla (* d2r (- (car b) (car a)))) (dlo (* d2r (- (cdr b) (cdr a))))
             (h (+ (expt (sin (/ dla 2)) 2)
                   (* (cos la1) (cos la2) (expt (sin (/ dlo 2)) 2)))))
        (* 6371.0 2.0 (atan (sqrt h) (sqrt (- 1.0 h)))))))
(define (time-gap slot-win avail-win)            ; ∈[0,1]: fraction of the shift NOT covered
  (if (or (not slot-win) (not avail-win)) 0.0
      (let ((ov (max 0.0 (- (min (cdr slot-win) (cdr avail-win))
                            (max (car slot-win) (car avail-win)))))
            (need (max 1e-6 (- (cdr slot-win) (car slot-win)))))
        (max 0.0 (min 1.0 (- 1.0 (/ ov need)))))))

(define *kappa-space* 0.12)                      ; tension per km of travel
(define *kappa-time*  2.0)                       ; tension per unit shift-misalignment
(define *emp*         3.0)                        ; EMP weight (↑ ⇒ more equal sharing)
(define *emp-iters*   40)                         ; coordinate-descent sweeps

;; a labour demand: skill k must be worked H hours at SPEC's site/shift
(define (mk-demand spec k hours)
  (let ((site (href *sites* spec #f)))
    (list spec k hours
          (and site (cons (list-ref site 0) (list-ref site 1)))     ; (lat . lng)
          (and site (cons (list-ref site 2) (list-ref site 3))))))  ; (start . end)
(define (dem-spec  d) (list-ref d 0))
(define (dem-skill d) (list-ref d 1))
(define (dem-hours d) (list-ref d 2))
(define (dem-loc   d) (list-ref d 3))
(define (dem-win   d) (list-ref d 4))

;; how much desire a good ultimately serves — its own if final, else the loudest
;; final downstream of it (reverse-BOM rollup). This is what makes scarce labour
;; flow to important work: a demand's "worth staffing" rate is its served-good
;; weight, so milling-for-bread inherits bread's priority. Memoised per config.
(define *spec-w* (make-hash-table))
(define (spec-W s)
  (or (hash-ref *spec-w* s)
      (let ((v (if (hash-ref *finals?* s #f)
                   (pweight (href *priority* s 0))
                   (fold (lambda (c a) (max a (spec-W (car c)))) 0.0 (consumers s)))))
        (hash-set! *spec-w* s v) v)))
;; the *value* of staffing the F-th hour of a demand is desire-like and
;; DIMINISHING: 2·W·(unmet/H)/H, where W is the served-good weight. Diminishing
;; returns make competing demands equalise their marginal value (EMP across
;; demands) and the assignment order-independent — high-W work keeps pulling
;; labour after low-W work's value has fallen, so scarcity sheds low first.
(define (staff-value d filled)
  (let ((H (dem-hours d)))
    (/ (* 2.0 (spec-W (dem-spec d)) (max 0.0 (- H filled))) (* H H))))

(define (labour-demands P)                       ; one demand per (producing spec, skill)
  (append-map
   (lambda (spec)
     (let ((q (hash-ref P spec 0.0)))
       (if (<= q 0.0) '()
           (filter-map (lambda (sk)
                         (and (> (* q (cdr sk)) 1e-9) (mk-demand spec (car sk) (* q (cdr sk)))))
                       (href *ell-skill* spec '())))))
   *makeable*))

;; the marginal tension a worker feels for one more hour on demand d, given the
;; load it already carries: proximity (fixed) + EMP slope·load (rising).
(define (prox-base w d)
  (+ (* *kappa-space* (haversine (worker-loc w) (dem-loc d)))
     (* *kappa-time*  (time-gap (dem-win d) (worker-window w)))))
(define (emp-slope w) (/ *emp* (max 1.0 (worker-hours w))))  ; convex load: marginal ∝ load

;; water-filling with a HARD cap per worker and a DIMINISHING value ceiling.
;; entries = (worker c slope remcap): c = marginal tension at x=0 (base+slope·load0),
;; remcap = hours this worker can still take. The water level λ rises until each
;; filled hour's tension equals its staffing value v(F)=staff-value(d,F); since
;; supply F(λ) rises with λ and the value v(F) falls with F, there is a unique
;; crossing g(λ)=λ−v(F(λ))=0 (g increasing). Worker fills x_w(λ)=clamp((λ−c)/slope,
;; 0, remcap). Returns (values alist-x unmet) — unmet = the hours not worth it.
(define (water-fill d entries)
  (let ((H (dem-hours d))
        (zero (lambda () (map (lambda (e) (cons (car e) 0.0)) entries))))
    (if (or (<= H 0.0) (null? entries)) (values (zero) (max 0.0 H))
        (let* ((xof (lambda (lam e) (max 0.0 (min (list-ref e 3)
                                                  (/ (- lam (cadr e)) (caddr e))))))
               (Fof (lambda (lam) (fold (lambda (e a) (+ a (xof lam e))) 0.0 entries)))
               (g   (lambda (lam) (- lam (staff-value d (Fof lam))))))    ; increasing in λ
          (let bs ((lo 0.0)
                   (hi (+ (apply max (map cadr entries)) (staff-value d 0.0) 1.0))
                   (i 0))
            (let* ((lam (/ (+ lo hi) 2.0)) (gv (g lam)))
              (if (>= i 60)
                  (values (map (lambda (e) (cons (car e) (xof lam e))) entries)
                          (max 0.0 (- H (Fof lam))))
                  (if (< gv 0.0) (bs lam hi (+ i 1)) (bs lo lam (+ i 1))))))))))

;; minimise total tension over the assignment by block coordinate descent: sweep
;; the demands, water-filling each against the others' current loads (so each
;; worker's REMAINING capacity is the hard cap, and the demand's served-good
;; weight is the value ceiling), until it settles. Convex ⇒ global min-tension.
;; Returns (values loads X unmet): loads = wid→hours, X = "wid|di"→hours,
;; unmet = di→unstaffed hours.
(define (assign-emp demands)
  (let ((loads (make-hash-table)) (X (make-hash-table)) (unmet (make-hash-table))
        (dl (length demands)))
    (define (key w di) (format #f "~a|~a" w di))
    (let sweep ((t 0))
      (if (>= t *emp-iters*)
          (values loads X unmet)
          (begin
            (for-each
             (lambda (d di)
               (let ((feas (filter (lambda (w) (member (dem-skill d) (worker-skills w))) *roster*)))
                 (for-each (lambda (w)                  ; lift this demand's current load out
                             (hadd! loads (worker-id w) (- (hash-ref X (key (worker-id w) di) 0.0))))
                           feas)
                 (call-with-values
                   (lambda ()
                     (water-fill d
                                 (map (lambda (w)
                                        (let* ((wid (worker-id w))
                                               (load0 (href loads wid 0.0)))
                                          (list w (+ (prox-base w d) (* (emp-slope w) load0))
                                                (emp-slope w)
                                                (max 0.0 (- (worker-hours w) load0)))))  ; remaining cap
                                      feas)))
                   (lambda (xs um)
                     (hash-set! unmet di um)
                     (for-each (lambda (w) (hash-set! X (key (worker-id w) di) 0.0)) feas)
                     (for-each (lambda (kv)
                                 (hash-set! X (key (worker-id (car kv)) di) (cdr kv))
                                 (hadd! loads (worker-id (car kv)) (cdr kv)))
                               xs)))))
             demands (iota dl))
            (sweep (+ t 1)))))))

;; ═══ the metabolism: event-driven loop ══════════════════════════════════════
;; Each EconomicEvent draws a stock down (consumption); the gap opens; we relax
;; to choose production; we commit it (replenishing); on to the next event.
;; Warm-started: each event perturbs the equilibrium only slightly, so the
;; previous plan re-settles in a few steps (the metabolism's efficiency).
(define (metabolize currents events outer inner)
  (fold (lambda (ev st)
          (let* ((currents (list-ref st 0)) (warm-plan (list-ref st 1)) (warm-cfg (list-ref st 2))
                 (spec  (economic-event-resource-conforms-to ev))
                 (qty   (mval (economic-event-resource-quantity ev)))
                 (drawn (aput currents spec (- (cur currents spec) qty))))           ; the draw
            (call-with-values (lambda () (solve-discrete drawn warm-plan warm-cfg outer inner))
              (lambda (cfg plan exact? n)              ; best cfg already installed
                (let ((after (commit drawn plan)))                                   ; replenish
                  (report ev drawn plan after cfg exact? n)
                  (list after plan cfg))))))
        (list currents '() (default-config)) events))

;; ═══ reporting ══════════════════════════════════════════════════════════════
(define *report?* #t)                            ; benchmark silences this
(define (sorted-alist h) (sort (hash-map->list cons h) (lambda (a b) (string<? (car a) (car b)))))

;; who works, where, how far — the min-tension assignment made visible
(define (worker-line w demands loads X)
  (let* ((wid (worker-id w)) (L (href loads wid 0.0)))
    (when (> L 0.05)
      (let ((km 0.0) (per-skill '()))
        (let loop ((di 0))
          (when (< di (vector-length demands))
            (let ((x (hash-ref X (format #f "~a|~a" wid di) 0.0))
                  (d (vector-ref demands di)))
              (when (> x 1e-9)
                (set! km (+ km (* x (haversine (worker-loc w) (dem-loc d)))))
                (set! per-skill (aadd per-skill (dem-skill d) x))))
            (loop (+ di 1))))
        (format #t "     ~6a  ~5,1fh/~2a  ~6,1f person-km  [~a]~%"
                wid L (worker-hours w) km
                (string-concatenate
                 (map (lambda (kv) (format #f " ~a:~a" (car kv) (inexact->exact (round (cdr kv)))))
                      (reverse per-skill))))))))
(define (report-labour P)
  (when (pair? *roster*)
    (let ((demands (list->vector (labour-demands P))))
      (call-with-values (lambda () (assign-emp (vector->list demands)))
        (lambda (loads X unmet)
          (for-each (lambda (w) (worker-line w demands loads X)) *roster*)
          ;; triage: any demand left unstaffed (priority sheds the cheapest first)
          (let ((short (filter (lambda (di) (> (href unmet di 0.0) 0.05))
                               (iota (vector-length demands)))))
            (when (pair? short)
              (format #t "     UNMET:~a~%"
                      (string-concatenate
                       (map (lambda (di)
                              (let ((d (vector-ref demands di)))
                                (format #f "  ~a/~a ~,1fh" (dem-spec d) (dem-skill d)
                                        (href unmet di 0.0))))
                            short))))))))))
(define (report ev drawn plan after cfg exact? n)
  (when *report?*
  (call-with-values (lambda () (settle drawn plan))
    (lambda (curs labskill raws P)
      (format #t "~%-- ~a ~a~%   harmony ~,2f   [interior-point: t=~,3f, gap <= ~,3f]~%   labour~a~a~%"
              (economic-event-action ev)
              (economic-event-resource-conforms-to ev)
              (harmony drawn plan)
              *tbar* (* (n-constraints) *tbar*)            ; central-path certificate
              (string-concatenate                       ; per-skill used/available
               (map (lambda (sk) (format #f "  ~a ~,0f/~a" (car sk) (cdr sk)
                                         (href *skill-avail* (car sk) "inf"))) (sorted-alist labskill)))
              (string-concatenate                       ; ecological draws
               (filter-map (lambda (rc)
                             (and (href *caps* (car rc) #f)
                                  (format #f "   ~a-draw ~,1f/~a" (car rc) (cdr rc)
                                          (href *caps* (car rc) "inf"))))
                           (sorted-alist raws))))
      (for-each
       (lambda (id)
         (let ((c (aref after id 0.0)))   ; `after` is the threaded currents alist
           (format #t "     ~8a  make ~6,1f   on-hand ~6,1f/~3a   gap ~4,2f~a~%"
                   id (hash-ref P id 0.0) c (href *targets* id "-") (gap id c)
                   (if (hash-ref *finals?* id #f)
                       (format #f "   pull ~7,2f" (pull drawn plan id)) "   (derived)"))))
       *tracked*)
      (when (pair? *multi*)
        (let* ((ghat (discrete-bound drawn plan))         ; Lagrangian upper bound on best config
               (gap  (max 0.0 (- ghat (harmony drawn plan)))))
          (format #t "     recipe choice:~a   [~a]~%"
                  (string-concatenate
                   (map (lambda (s) (format #f "  ~a -> ~a" s (aref cfg s "?"))) *multi*))
                  (if exact?
                      (format #f "exact: global over all ~a configs (dual bound checks: gap ~,3f)" n gap)
                      (format #f "annealed: ~a configs, certified within ~,3f of best (Lagrangian dual)" n gap)))))
      ;; the matched flow: min-tension assignment (proximity + EMP), per worker
      (report-labour P)))))

;; ═══ build the world from real VF records ═══════════════════════════════════
(define (rspec id name unit class) (make-resource-specification #:id id #:name name
                                                                #:resource-classified-as (list class)
                                                                #:default-unit-of-resource unit))
(define (rproc id name) (make-recipe-process #:id id #:name name))
(define (consume-flow id spec qty unit proc) (make-recipe-flow #:id id #:action 'consume
                                                               #:resource-conforms-to spec
                                                               #:resource-quantity (make-measure qty unit)
                                                               #:recipe-input-of proc))
(define (work-flow    id hours skill proc)   (make-recipe-flow #:id id #:action 'work
                                                               #:resource-conforms-to skill
                                                               #:effort-quantity (make-measure hours "hours")
                                                               #:recipe-input-of proc))
(define (produce-flow id spec qty unit proc) (make-recipe-flow #:id id #:action 'produce
                                                               #:resource-conforms-to spec
                                                               #:resource-quantity (make-measure qty unit)
                                                               #:recipe-output-of proc
                                                               #:is-primary #t))
(define (recipe id spec procs) (make-recipe #:id id #:name (string-append "recipe-" id)
                                            #:primary-output spec #:recipe-processes procs))
(define (eres id spec qty unit) (make-economic-resource #:id id #:conforms-to spec
                                                        #:onhand-quantity (make-measure qty unit)))
(define (cevent id spec qty unit)
  (make-economic-event #:id id #:action 'consume #:resource-conforms-to spec
                       #:resource-quantity (make-measure qty unit)))

(define* (define-world! specs recipes flows resources targets priority roster caps
                        #:optional (sites '()))
  (set! *specs* specs) (set! *recipes* recipes) (set! *flows* flows)
  (index-flows! flows)                           ; O(F) index so flows-of is local
  (hash-clear! *targets*)  (for-each (lambda (kv) (hash-set! *targets*  (car kv) (cdr kv))) targets)
  (hash-clear! *priority*) (for-each (lambda (kv) (hash-set! *priority* (car kv) (cdr kv))) priority)
  (hash-clear! *caps*)     (for-each (lambda (kv) (hash-set! *caps*     (car kv) (cdr kv))) caps)
  (hash-clear! *sites*)    (for-each (lambda (kv) (hash-set! *sites*    (car kv) (cdr kv))) sites)
  (set! *roster* roster)
  ;; aggregate per-skill availability A_k from the roster: one body, one
  ;; availability, projected onto each skill it can perform (the availability-
  ;; pool rule). Contention between a worker's skills is resolved at assignment.
  (hash-clear! *skill-avail*)
  (for-each (lambda (w) (for-each (lambda (k) (hadd! *skill-avail* k (worker-hours w)))
                                  (worker-skills w)))
            roster)
  ;; group recipes by primary output (a spec may have several alternatives)
  (hash-clear! *recipes-by-output*)
  (for-each (lambda (r)
              (let ((spec (recipe-primary-output r)))
                (hash-set! *recipes-by-output* spec
                           (append (href *recipes-by-output* spec '()) (list r)))))
            recipes)
  (set! *all-skills*
        (delete-duplicates (append-map (lambda (r) (map car (recipe-work-pairs r))) recipes)))
  (set! *makeable* (hash-map->list (lambda (k v) k) *recipes-by-output*))
  (hash-clear! *makeable?*) (for-each (lambda (id) (hash-set! *makeable?* id #t)) *makeable*)
  (hash-clear! *finals?*)
  (let ((all (map resource-specification-id specs)))
    (set! *finals*   (filter (lambda (id) (hash-ref *priority* id #f)) all))
    (for-each (lambda (id) (hash-set! *finals?* id #t)) *finals*)
    (set! *tracked*  (delete-duplicates (append *finals* *makeable*)))
    (set! *raw*      (filter (lambda (id) (not (hash-ref *makeable?* id #f))) all))  ; O(S)
    (set! *multi*    (filter (lambda (id) (> (length (href *recipes-by-output* id '())) 1))
                             *makeable*)))
  (hash-clear! *init*)
  (for-each (lambda (r) (hash-set! *init* (economic-resource-conforms-to r)
                                   (mval (economic-resource-onhand-quantity r))))
            resources)
  (install-config! (default-config)))

(define (init-currents)                          ; on-hand alist seeded from *init*
  (hash-map->list cons *init*))

;; ─── a tiny commune, with TWO recomposition pressures:
;;   • flour: mill grain (cheap labour, but draws the soil envelope) vs mill
;;     cassava (more labour, no soil draw) — a MATERIAL choice. Tight soil cap
;;     ⇒ recompose flour onto cassava.
;;   • cake: bake it (needs the scarce `bake` skill, contending with bread) vs a
;;     pastry recipe (same flour, but `pastry` labour, which is idle) — a SKILL-
;;     MIX choice. Scarce bakers ⇒ recompose cake onto pastry, freeing bakers
;;     for bread while cake still fills. The labour analog of soil → cassava. ──
(define *seed*
  (list (eres "r-bread" "bread" 10 "each") (eres "r-cake" "cake" 5 "each")
        (eres "r-flour" "flour" 40 "kg")   (eres "r-grain" "grain" 50 "kg")))

(define-world!
  (list (rspec "bread" "Bread" "each" "moc")
        (rspec "cake"  "Cake"  "each" "moc")
        (rspec "flour" "Flour" "kg"   "intermediate")
        (rspec "grain" "Grain" "kg"   "intermediate")
        (rspec "soil"    "Soil fertility" "unit" "ecological")
        (rspec "cassava" "Cassava"        "kg"   "ecological"))
  (list (recipe "bread" "bread" (list "p-bake"))
        (recipe "cake"        "cake" (list "p-cake"))     ; bake path (scarce bakers)
        (recipe "cake-pastry" "cake" (list "p-cake2"))    ; pastry path (idle skill)
        (recipe "flour"         "flour" (list "p-mill"))    ; grain path (draws soil)
        (recipe "flour-cassava" "flour" (list "p-mill2"))   ; cassava path (no soil)
        (recipe "grain" "grain" (list "p-grow")))
  (list (produce-flow "f1" "bread" 20 "each" "p-bake") (consume-flow "f2" "flour" 20 "kg" "p-bake") (work-flow "f3" 16 "bake" "p-bake")
        (produce-flow "f4" "cake"  10 "each" "p-cake") (consume-flow "f5" "flour"  8 "kg" "p-cake") (work-flow "f6" 15 "bake" "p-cake")
        (produce-flow "f16" "cake" 10 "each" "p-cake2") (consume-flow "f17" "flour" 8 "kg" "p-cake2") (work-flow "f18" 15 "pastry" "p-cake2")
        (produce-flow "f7"  "flour" 10 "kg"  "p-mill")  (consume-flow "f8"  "grain"   12 "kg" "p-mill")  (work-flow "f9"   5 "mill" "p-mill")
        (produce-flow "f13" "flour" 10 "kg"  "p-mill2") (consume-flow "f14" "cassava" 14 "kg" "p-mill2") (work-flow "f15"  9 "mill" "p-mill2")
        (produce-flow "f10" "grain" 10 "kg"  "p-grow")  (consume-flow "f11" "soil"    10 "unit" "p-grow") (work-flow "f12" 10 "grow" "p-grow"))
  *seed*
  '(("bread" . 60) ("cake" . 30) ("flour" . 80) ("grain" . 100))   ; targets
  '(("bread" . 9)  ("cake" . 3))                                    ; social desire
  ;; the roster: (worker (skills...) hours-this-period voice). Bakers are
  ;; SCARCE — full reproduction wants ~93 bake-hours but only 60 exist, so the
  ;; baker envelope binds and pull allocates it between bread (9) and cake (3).
  ;; (id (skills) hours voice (lat . lng) (shift-start . shift-end)).
  ;; alice lives at the bakery; bob between bakery & mill; carol by the mill;
  ;; dave at the farm; erin by the bakery. Two bakers (alice 0 km, bob ~1.7 km)
  ;; let us watch proximity vs EMP fight over who bakes.
  (list (list "alice" '("bake")        30 1.0 '(40.000 . -74.000) '(6 . 14))
        (list "bob"   '("bake" "mill") 30 0.8 '(40.015 . -74.000) '(8 . 16))
        (list "carol" '("mill" "grow") 40 1.0 '(40.040 . -74.000) '(8 . 18))
        (list "dave"  '("grow")        30 0.6 '(40.060 . -74.000) '(6 . 18))
        (list "erin"  '("pastry")      40 1.0 '(40.005 . -74.000) '(6 . 14)))   ; relief valve
  '(("soil" . 12) ("cassava" . 200))                                ; envelopes (soil tight!)
  ;; where & when each good's work happens (lat lng shift-start shift-end):
  '(("bread" 40.000 -74.000 6 14) ("cake"  40.000 -74.000 6 14)     ; the bakery
    ("flour" 40.030 -74.000 8 16) ("grain" 40.060 -74.000 6 18)))   ; the mill / the farm

;; ─── run the metabolism over a week of consumption ──────────────────────────
(format #t "~%==== event-driven chaotic relaxation planner ====~%")
(metabolize (init-currents)
            ;; e1's hungry bread pins the bakers (bake ≈ 50/60), so cake must
            ;; live on pastry; as bread fills and bakers free up, cake recomposes
            ;; back onto baking. Meanwhile grain depletes, so flour recomposes
            ;; grain → cassava once the soil envelope would bind.
            (list (cevent "e1" "bread" 14 "each") (cevent "e2" "cake" 7 "each")
                  (cevent "e3" "bread" 16 "each") (cevent "e4" "cake" 5 "each")
                  (cevent "e5" "bread" 12 "each") (cevent "e6" "cake" 9 "each"))
            14    ; outer: annealed recipe-recomposition steps per event
            120)  ; inner: monotone convex-core steps per configuration
(newline)

;; ═══ scaling benchmark ══════════════════════════════════════════════════════
;; A synthetic deep network: one final good `g` at the head of a chain of N
;; intermediate stages, the last drawing a raw under an ecological cap. Each
;; stage also branches into a side intermediate (so E ≈ 2N), exercising the
;; cascade. We time `metabolize` over a few consumption events and report
;; settles + wall-clock, to show the per-event cost grows ~linearly in N.
(define (build-chain N)
  (let* ((mids (map (lambda (i) (format #f "m~a" i)) (iota N)))     ; m0..m(N-1)
         (sides (map (lambda (i) (format #f "s~a" i)) (iota N)))
         (specs (append (list (rspec "g" "Good" "each" "moc") (rspec "raw" "Raw" "kg" "ecological"))
                        (map (lambda (m) (rspec m m "kg" "intermediate")) mids)
                        (map (lambda (s) (rspec s s "kg" "intermediate")) sides)))
         ;; g ← m0 ; mi ← m(i+1) + si ; m(N-1) ← raw ; si ← raw
         (recs (append
                (list (recipe "g" "g" (list "pg")))
                (map (lambda (i) (recipe (list-ref mids i) (list-ref mids i)
                                         (list (format #f "pm~a" i)))) (iota N))
                (map (lambda (i) (recipe (list-ref sides i) (list-ref sides i)
                                         (list (format #f "ps~a" i)))) (iota N))))
         (flows (append
                 (list (produce-flow "fg" "g" 10 "each" "pg")
                       (consume-flow "fgc" "m0" 10 "kg" "pg")
                       (work-flow "fgw" 1 "labour" "pg"))
                 (append-map
                  (lambda (i)
                    (let ((m (list-ref mids i)) (s (list-ref sides i))
                          (down (if (< i (- N 1)) (list-ref mids (+ i 1)) "raw")))
                      (list (produce-flow (format #f "pm~ao" i) m 10 "kg" (format #f "pm~a" i))
                            (consume-flow (format #f "pm~ac" i) down 6 "kg" (format #f "pm~a" i))
                            (consume-flow (format #f "pm~ac2" i) s 4 "kg" (format #f "pm~a" i))
                            (work-flow (format #f "pm~aw" i) 1 "labour" (format #f "pm~a" i))
                            (produce-flow (format #f "ps~ao" i) s 10 "kg" (format #f "ps~a" i))
                            (consume-flow (format #f "ps~ac" i) "raw" 5 "kg" (format #f "ps~a" i))
                            (work-flow (format #f "ps~aw" i) 1 "labour" (format #f "ps~a" i)))))
                  (iota N))))
         (resources (list (eres "rg" "g" 5 "each"))))
    (define-world! specs recs flows resources
      '(("g" . 100)) '(("g" . 6))
      (list (list "w" '("labour") 1e9 1.0))
      '(("raw" . 1e9)))))

;; We time a single COLD relax (empty warm plan) of the convex core — that is
;; the part whose scaling we care about. The chain has one decision variable
;; (the final `g`), so the iteration count is size-independent; each iteration's
;; settle is O(S+E). The interesting columns are `settles` (should be ~flat in N)
;; and `ms/settle` (should grow ~linearly in S) — their product is the per-solve
;; cost, near-linear in the network.
(define (bench)
  (set! *report?* #f)
  (set! *tbar* *t0*)                               ; fixed barrier (no path-following) for timing
  (format #t "~%==== scaling benchmark — cold relax of the convex core ====~%")
  (format #t "     N    specs    edges   settles   ms/solve   µs/settle~%")
  (for-each
   (lambda (N)
     (build-chain N)
     (let ((cur (init-currents)))
       (relax cur '() 300)                       ; warm caches / JIT
       (set! *nsettle* 0)
       (let* ((t0 (get-internal-real-time))
              (_  (relax cur '() 300))
              (ms (/ (* 1000.0 (- (get-internal-real-time) t0)) internal-time-units-per-second)))
         (format #t "  ~5@a   ~6@a   ~6@a   ~7@a   ~8,2f   ~9,2f~%"
                 N (length *specs*) (length *flows*) *nsettle*
                 ms (/ (* 1000.0 ms) (max 1 *nsettle*)))
         (force-output))))
   '(10 50 200 1000 4000)))

(bench)
(newline)

;; ═══ labour triage under scarcity ═══════════════════════════════════════════
;; One carer, two needs: an ICU (priority 9) and a mural (priority 7), each
;; wanting 30h of care — but only 40h of carer exist. Hard capacity (she can't
;; do 60h) pins her at 40/40; priority triage (the ICU is worth more) gives the
;; ICU the larger share and sheds the rest of the mural. Both at once.
(define (demo-triage)
  (set! *report?* #t)
  (format #t "~%==== labour triage under scarcity ====~%")
  (define-world!
    (list (rspec "icu" "ICU care" "each" "moc") (rspec "mural" "Mural" "each" "moc"))
    (list (recipe "icu" "icu" (list "pi")) (recipe "mural" "mural" (list "pm")))
    (list (produce-flow "pio" "icu"   1 "each" "pi") (work-flow "piw" 1 "care" "pi")
          (produce-flow "pmo" "mural" 1 "each" "pm") (work-flow "pmw" 1 "care" "pm"))
    '() '(("icu" . 60) ("mural" . 60)) '(("icu" . 9) ("mural" . 7))
    (list (list "nadia" '("care") 40 1.0 '(40.00 . -74.00) '(6 . 22)))   ; the only carer
    '()
    '(("icu" 40.00 -74.00 6 22) ("mural" 40.02 -74.00 6 22)))
  (call-with-values
    (lambda () (assign-emp (list (mk-demand "icu" "care" 30) (mk-demand "mural" "care" 30))))
    (lambda (loads X unmet)
      (format #t "   need: ICU 30h care (priority 9) + mural 30h care (priority 7) = 60h~%")
      (format #t "   have: nadia, the only carer, 40h~%")
      (format #t "   -> nadia works ~,1fh / 40h  (hard capacity wall)~%" (href loads "nadia" 0.0))
      (format #t "   -> ICU   staffed ~,1fh, unmet ~,1fh~%" (- 30 (href unmet 0 0.0)) (href unmet 0 0.0))
      (format #t "   -> mural staffed ~,1fh, unmet ~,1fh   (lower priority sheds first)~%"
              (- 30 (href unmet 1 0.0)) (href unmet 1 0.0)))))
(demo-triage)
(newline)
