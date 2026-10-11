;;; planner.scm — THE planner. One engine, one problem, two backends.
;;;
;;; This is the consolidation: the eight prototypes (relaxation, spatial-core,
;;; spatial-proto, spacetime-newton, compile, spacetime-compiled, scale-test,
;;; ingest-test) collapse into one coherent engine you can point at. The shape:
;;;
;;;   ValueFlows records ─compile→ a LOCATED activity matrix ─build→ ONE sparse
;;;   convex program, expressed as backend-neutral linear FORMS, solved by either
;;;     • NATIVE  — the matrix-free interior-point Newton-PCG (pure Guile, zero
;;;                 dependency, the portable reference); or
;;;     • OSQP    — the same program reduced to a sparse QP and handed to the
;;;                 industry ADMM solver libosqp over FFI (the production path).
;;;
;;; The two backends consume the SAME forms — that is the seam. The planner is a
;;; sparse convex QP; OSQP is the sparse convex QP solver. Space, time and scope
;;; are coordinates (a good is resource@cell); production, transport and storage
;;; are all columns of the one matrix. Decomposition is unnecessary — the coupled
;;; problem is solved monolithically; the Hessian's off-diagonals ARE the coupling.
;;;
;;; This file is a LIBRARY and loading it prints nothing. The self-test and the
;;; worked scenarios (§9) are a script, and live next door:
;;;
;;;   guile -L module module/playnet/deprecated/planner/attic/demo.scm                (self-tests)
;;;
;;; §0 utilities  §1 forms (the backend-neutral problem)  §2 native backend
;;; §3 OSQP backend (QP reduction + FFI)  §4 dispatcher + parity self-test
;;; §5 VF compiler  §6 located/spacetime model  §7 discrete layer
;;; §8 reserve tranche + EMP labour        (§9 scenarios → demo.scm)

;; The engine is a MODULE (phase 3 of the engine-as-module arc). Its mutable
;; world — the tables `reset!` clears — is ONE context in solve/world.scm, held
;; in a cell and read and written by name from here and from every module that
;; imports a name; what `reset!` leaves standing (the dials, the memos, the
;; tolerances) is the engine's own. The export list is the
;; MEASURED interface: every top-level name some file outside the engine family
;; references — every test, bench and demo imports this module by name — plus
;; set-dial! kept deliberately. The tests' double-loads of engine/robust.scm are
;; retired (the engine loads it into itself), so the satellites' free names no
;; longer need exporting for a second copy of their text. The remaining
;; top-level names are internal machinery; exporting one later is one line
;; here.
;; A world is DECLARED, not assembled: declare-world! (beside reset!/mkcells!)
;; is the door every world comes through — a test's or bench's fixture, the
;; worked example's setup-*, and the records: ingest-located! derives its
;; declaration from the resources, agents and spatial things and calls it. So
;; the world's fields it fills (*places*, *periods*, *cells*, *latlon*,
;; *movable*, *storable*, …) are assigned in that one place — world-door-test
;; reads the source and says so.
;; What is written onto a standing world afterwards is a layering, and goes
;; through its door: set-templates!, set-dial!, adopt-container-pools!,
;; workers->riders!, absorb-specs!, the manners bag.
;; This module is the ONE door: (use-modules (playnet solve engine)) is how a
;; test, a bench or the live planner reaches the world, and each states beside
;; it the layers it reads (compile, solver, schemas, …) — the layers are
;; disjoint interfaces, so there is nothing to stack in a particular order.
;; #:declarative? #f — callers set! these globals (interpreted), and the module
;; system must keep them as real boxes. Declarative would be WORSE than a
;; redefinition hazard: Guile then inlines the compile-time value of every
;; imported global that is an immediate (compile.scm's `'()` for *templates*,
;; solver.scm's 'auto for *backend*, every numeric dial), so a setter's write
;; is never read by the engine again — measured: build-columns saw no templates.
;; The browser build (Hoot) compiles a whole program and refuses a module that
;; may be redefined, so it builds from a copy of this file with the flag turned
;; on (the Makefile's .hoot-src rule) — where an imported global is a wasm global read
;; each time. Every global a caller assigns has a setter (set-backend!,
;; set-templates!, set-last-certificate!, set-promote!, set-willing!,
;; set-legal-decorate!, set-acquire!, set-dial!) so neither build writes
;; into an imported binding.
(define-module (playnet solve engine)
  #:re-export (svc-good? lab-good svc-good)   ; the bar-key grammar's, read here and by the engine's importers (facts/located)
  #:use-module (playnet vf formulas flows)
  #:use-module (playnet solve world)
  #:declarative? #f
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils alist) #:select (assv-replace assoc-replace))
  #:use-module ((playnet utils catch) #:select (catch* throw* with-throw-handler*))
  #:use-module (ice-9 format)
  #:use-module (rnrs bytevectors)
  #:use-module ((playnet solve voice-field) #:select (voice-labform voice-report))
  #:use-module ((playnet utils units) #:select (convert-unit/strict unit-known? unit->substance convert-unit unit-rate? unit-rate-parts unit-factor %placeholder-unit %count-unit %effort-unit))
  #:use-module ((playnet utils clock) #:select (hhmm->minutes minutes->hhmm clock-length-minutes clock-overlap-minutes clock-ranges-minutes civil->instant instant->civil instant->weekday now timescale instant->unix unix->instant iso->epoch))
  #:use-module ((playnet vf facts availability) #:select (dated-week? dated-week-week dated-week-overrides))
  #:use-module ((playnet vf facts agent-time) #:select (agent-schedulable-window agent-disposable-hours agent-away-dates away-count))
  #:use-module (playnet vf schemas)
  #:use-module (playnet vf formulas actions)
  #:use-module (playnet vf beyond schedules)
  #:use-module (playnet vf beyond scenario)
  #:use-module (playnet utils keywords)
  #:use-module ((playnet utils keyed-id) #:select (keyed-id))
  #:use-module (playnet vf facts located)
  #:re-export (lg cell good-spec located-cell place-of period-of key-period key-retime key-prefix bar-fields bar-field parse-located-good
               key-terms key-process key-arc)
  #:use-module ((playnet algorithms rollup fixpoint) #:select (crystallize))
  #:use-module ((playnet solve externality) #:select (withdrawal-displacement paired-difference))
  #:use-module ((playnet vf formulas propagate) #:select (propagate propagate-agents))
  #:use-module (playnet vf formulas tension-kinds)
  #:use-module (playnet vf formulas periods)   ; what a period is in wall-clock time
  #:use-module (playnet vf facts boundary)   ; the flows nothing makes
  #:use-module (playnet vf formulas fragility)   ; a limit as a record: one form for every scale
  #:re-export (<fragility> fragility? fragility-profile fragility-extent fragility-window fragility-specs
               fragility-level fragility-kind fragility-key make-fragility fragility-with-profile
               floor-on-good frag-rate frag-budget frag-contained frag-within pooled-budget as-fragility
               as-fragilities fragility-specs-of)
  #:re-export (*ambient-flows*)
  #:re-export (period-days iso->epoch/time span-timed? set-period-span! period-span *period-length*
               set-period-length! declared-period-hours period-hours period-contains? time->period
               set-daily-horizon! set-clock-horizon!)
  #:use-module ((playnet solve admm-link) #:select (make-exchange exchange-keys exchange-live? exchange-flow exchange-pull exchange-rho
                                                exchange-rounds allocate-caps))
  #:use-module (playnet solve solver)
  #:use-module (playnet solve compile)
  #:use-module (playnet vf formulas capacity)
  #:use-module (playnet knowledge worlds bioregions)
  #:use-module (playnet vf formulas stocks)
  #:use-module (playnet solve recipe-response)
  #:use-module (playnet vf formulas shocks)
  #:re-export (iso->epoch)        ; the date's instant is the clock's (playnet utils clock)
  #:re-export (priority-weight)   ; the ladder's one table is the term math's (tension-kinds.scm)
  #:re-export (scenario-shocks shock-action shock-key shock-period shock-factor
               calibrate-shocks observed-shocks scenario-with-shocks certainty-equivalent-scenario)
  #:use-module ((playnet utils records) #:select (vf-record-type vf-record-constructor vf-record-predicate vf-record-accessor vf-record-modifier vf-record-type-name vf-record-type-fields))
  #:use-module (playnet vf aggregation containment)
  #:export (key-spec  spec-owner spec-base  want-as-cap? set-cap-scale! cap-scale-of *desire-w0*   absorb-specs! add-trainable!
             arc-hours arc-net-km
            batch-keys *bnb-nodes* build-columns build-located
               tier-shape acquire-bill bill-net located-bill   chain-duration-gaps close-elements! template-creates template-at-edge? col-flows col-key col-labour
            column-terms build-terms
                 column-labour-hours svc-spec
            col-value
            cost-of-config     declare-whole! declare-proc-frag!   legal-frag-forms
             why-not why-not-tally
             requirements unmet req-kind req-name req-met? requirements->wire
            declare-workers! declare-world!   discrete-declared?   coupling-table register-coupling! element-closure-on? *climb-per-km* arc-climb-m arc-climb-km
             *emp-rho*
             record-crossings record-plan

            frag-tip    good-level
                     km
            *legal-decorate*  located-solve located-warm make-band
                 node-fractional
            node-solve   period-dates
                   plan-runs

            relaxed-bound   reset!
             mrec-name mrec-rp mrec-flows mrec-skill mrec-manner mrec-pace means-ride? rider-hours
            set-dial!   set-skill-spec! set-competence! apply-skill-dynamics!
              set-worker-pref! *pref-bound* skilled-worker-at?
            solve* solve-decomposed   solve-discrete solve-located    spec-skips-balance?
            spec-stationary?  stock->flow store-recipe  svc-held? svc-hours-factor
             temporal-target   Tkey
            whole-col?    with-col-bounds! with-col-fixed!  set-promote! set-willing! set-legal-decorate! set-acquire!     inert-caps
            ;; read by the robust assembly and the plan door (solve/robust, solve/plan)
            *discrete-key?* *discrete-program*  apply-solve-settings! col-cell col-fixed decided-state discrete-certificate mbq-floor restore-search-state! search-state  solution-cost substitute-fixed
            ;; read by the federated solve and the boundary oracle (solve/federation-solve, solve/federation-oracle)
            ;; read by the records pipeline (solve/records)
             mover-ride-templates part-mode-recipes riders? workers->riders!
            ;; read by the report (solve/report)
            bare-run-template mover-placement ride-mode-process run-id template-by-id frag-w
            refine-plan crossing-alist->hash crossing-col crossing-key crossing-offset crossing-sign crossing-column
            crossing-flow crossing-side admm-kernel-rec admm-kernel-batch admm-scope-met admm-write-prox!
            ;; read by the observer ingest (solve/ingest)
            band-floor band-ceiling band-w mobility-skills %owner-sep produced-spec-set span-dates stretch-of hash-add! means-carried?))

;; the batched kernel solve below crosses the FFI; Hoot has none (see the cond-expand there)
(cond-expand (guile (use-modules (system foreign))) (else))

(cond-expand (guile) (else (define (getenv name) #f)))
(cond-expand (guile) (else
  (define (get-internal-real-time) (current-time))   ; the report line's seconds: whole seconds is what a page has
  (define internal-time-units-per-second 1)))
(cond-expand (guile) (else
  (define (string-contains s pat)          ; the first index of PAT in S, or #f (Hoot has no srfi-13)
    (let ((n (string-length s)) (m (string-length pat)))
      (let loop ((i 0))
        (cond ((> (+ i m) n) #f)
              ((string=? (substring s i (+ i m)) pat) i)
              (else (loop (+ i 1)))))))))   ; a page has no process environment; the PLANNER_* switches read as unset

;; The VF records. They MUST be the same record types the observer uses — this
;; engine gets loaded into modules that already import (playnet boot prelude) (live.scm
;; among them), and a second, incompatible set of record types is a silent
;; disaster: constructors from one set, predicates from the other, every match
;; failing for no visible reason.
;;
;; That is what a module guarantees. (playnet vf schemas) is loaded once per
;; process however many loaders ask for it, so there is exactly one <economic-resource>
;; and the question of a duplicate set cannot arise. The `(unless (defined?
;; 'make-economic-resource) ...)` this replaces was hand-rolling that guarantee, and
;; only approximately: it probed ONE name and inferred the presence of 639.

   ; the one value rollup
   ; stage 4: the same three lines one level up (engine/federation-solve.scm)
   ; the (I-C)^-1 cascade — eco coupling's own math, extracted

;; Per-kind term math (value φ / gradient-coeff φ′ / curvature φ″) — the SINGLE
;; SOURCE OF TRUTH the hot loops below dispatch through, also governed by the
;; tension-registry actor. One definition, not the same formulas hand-copied
;; across term-coeffs / csr-grad / obj-value (and their kernel.c twins).

;; ════════════════════════════════════════════════════════════════════════════
;; §0–§4 — THE CONVEX SOLVER
;; ════════════════════════════════════════════════════════════════════════════
;; Everything from the utility shims to the OSQP dispatcher lives in solver.scm,
;; and it is a DIFFERENT SUBJECT from what follows. It consumes `forms` — the
;; backend-neutral kinds (`bar`, `des`, `frag`, `qc`, `held`) — and it has never
;; heard of a RecipeFlow, an EconomicResource or a unit: not one ValueFlows
;; accessor appears in it. That is not tidiness, it is the same rule the
;; certificate keeps ("the solver sees everything, the certificate sees only the
;; world"), stated as a file boundary.
;;
;; A module now, imported by module-use! — the runtime form of use-modules, which
;; unlike a define-module in a primitive-load'ed file does NOT switch
;; current-module. So the engine still defines into whichever module loaded it,
;; and stays ONE entry point for its ~120 callers, while the solver finally has
;; an interface. Unconditional: an import is all-or-nothing, and the old
;; (unless (defined? 'solve-native) …) guard probed one name for 181.

;; §5 — THE VF COMPILER. It lived in a fragment because BOTH this engine and the
;; umbrella needed it and neither could import it — "same text, both loaders",
;; which meant two copies of *templates* and a caller's choice of loader
;; deciding which one it got. A module ends that: one variable, both loaders,
;; each importing it the way its own mechanism allows.

;; ════════════════════════════════════════════════════════════════════════════
;; §6 — THE LOCATED PROGRAM: tile templates over cells; moves are columns
;; ════════════════════════════════════════════════════════════════════════════
;; A good is (resource @ cell), a cell is (place @ period). Production tiles each
;; template per cell; a MOVE is just another column — transport consumes good@from
;; and produces good@to (space), storage does the same forward in time (time's one
;; asymmetry). Site- and timing-selection is the optimum choosing column levels.
;; a column-build-time coefficient hook: (action proc-id spec t) -> factor, consulted
;; while build-columns turns a template's proc-outputs/proc-inputs/skill-labours into
;; a column's flows. Default 1.0 everywhere (no-op). A robust branch binds it to
;; its scenario's matcher (shocks.scm branch-flow-factor): every coefficient
;; shock — flat, period-tagged or located — reaches a column through this one
;; hook, at the cell being tiled, over the one unshocked world.
;; (proc-id . spec) → #t for a `use` whose effort is a DURATION. Svc| is counted
;; in unit-periods, so such a draw is divided by the period's own length at
;; build time — the only place the period, and therefore its length, is known.
;; Kept apart from *flow-period-factor*: that hook is a scenario perturbation
;; engine/robust.scm owns and replaces wholesale, while this is structural and always
;; true. Sharing one slot would let whichever ran last erase the other.
(define (stock->flow qty t)
  "A stated STOCK read as the capacity it renders over period T. Capacity is a
   flow, so `two hectares` or `four kit sets` is not yet a capacity — it is what
   exists; what a period can spend is that times the period's own hours. Every
   scope stating a Svc| cap by hand says it through this, so the conversion is
   named once rather than re-derived as a bare multiplication at each site."
  (* qty (period-hours t)))
;; capacity is a module; import its interface rather than textually loading it.
;; module-use! is the runtime form of use-modules and, unlike the define-module
;; inside a primitive-load'ed file, does NOT switch current-module — so the rest
;; of this engine still defines into whichever module primitive-load'ed it. That
;; is the whole contract this file depends on: ONE entry point for its callers.
;; UNCONDITIONAL. The old (unless (defined? 'holding-capacity) …) guard was
;; right for a textual load — if the umbrella had already INCLUDED capacity.scm
;; every one of its names was present, so skipping was safe. An import is
;; all-or-nothing: skip it because holding-capacity happens to be visible and
;; holding-budget? (used below) is still missing. module-use! twice is harmless.

;; ── what "effort" is, and what it is standing in for ────────────────────────
;; Effort is denominated in TIME here, and that is a convenience rather than a
;; claim. Effort is what a use SPENDS; time is the part of it currently legible,
;; so the two are held equal for now. They are not the same thing: the fuller
;; reading is time × INTENSITY — an oven run hot and an oven run gentle occupy
;; the same hours and do not cost the same, which is exactly the distinction
;; `Cond|durable` wear already carries per recipe ("high for a searing bake, low
;; for a gentle one").
;;
;; Nor is a use's effort a scheduling statement. It says how much was spent, not
;; when within the period it happened; the lattice's period is the only ordering
;; there is, and a duration inside one is not placed on a clock.
;;
;; So the seam to keep open is the coefficient below: an intensity factor would
;; multiply in exactly here, beside the hours, without any of the surrounding
;; structure changing. Nothing should come to depend on effort being time alone.
(define (svc-hours-factor good tpl t)
  "Svc| is a FLOW, like labour — capacity is unit-HOURS, not a headcount (a count
   is a stock; capacity is what that stock can be spent as over a period). So a
   `use` that stated a DURATION already reads in hours and is taken as written,
   while one that stated only a count means it holds the unit for the whole
   period, and that period's hours are what it costs."
  (if (and (svc-good? good)
           (not (member (svc-spec good) (proc-timed-svc tpl))))
      (period-hours t)
      1.0))
;; ── THE PLAN ASKED BACKWARDS: what it would take ─────────────────────────────
;; THE TIER TABLE: what shape each tension takes under the tier held. A floor is
;; a wall in every tier and poured in none of 'none; a held margin is a wall at
;; its ease from 'needs up; a want a wall at its ask under 'wants alone; the
;; soft reserve tranche never survives a held tier. #f — the ordinary solve —
;; keeps every shape as stated. Every site that emits a tension reads this one
;; table through `tier-shape`, so a tier is a row here and nowhere else.
(define %tier-shapes                  ; kind → shape under (none rights needs wants); #f = gone
  '((floor   #f   wall wall wall)
    (margin  #f   #f   wall wall)
    (want    #f   #f   #f   wall)
    (reserve #f   #f   #f   #f)))
(define (tier-shape kind)             ; → 'soft | 'wall | #f
  (if (not *promote*) 'soft
      (list-ref (assq-ref %tier-shapes kind)
                (case *promote* ((none) 0) ((rights) 1) ((needs) 2) ((wants) 3)
                  (else (error "tier-shape: no such tier" *promote*))))))
(define (quantile alpha lo hi) (+ lo (* alpha (- hi lo))))   ; place the tip in the science range: alpha=0 ⇒ lo (most precautious), 0.5 ⇒ central
(define (frag-tip fc) (apply (lambda (lo hi alpha w) (quantile alpha lo hi)) fc))   ; s_tip — the barrier's divergence point, and the raw's draw ceiling for reachability
(define (frag-w fc)   (apply (lambda (lo hi alpha w) w) fc))                         ; the fixed governance weight of a fragility profile
(define (frag-headroom profile key)                                                  ; remaining draw headroom = tip − OBSERVED prior. The barrier baseline AND the reachability ceiling are this one quantity.
  (- (frag-tip profile) (hash-ref *frag-prior* key 0.0)))
(define (frag-barrier profile coeffs key)                                            ; a frag barrier at the remaining headroom over a pressure vector: slack = headroom + Σ coeffs·x = headroom − incremental draw
  (mk-frag (frag-headroom profile key) coeffs (frag-w profile)))
(define (coupling-table name)                      ; NAME's own hash, creating it empty on first touch
  (or (hash-ref *couplings* name #f)
      (let ((h (make-hash-table))) (hash-set! *couplings* name h) h)))
;; TRIPLES: (k-good j-good c) …, already located (concrete goods, not bare
;; agent names — knowledge/*.scm's expand-couple is the one door that gets
;; them there). Multiple calls for the same NAME accumulate.
(define (register-coupling! name triples)
  (let ((h (coupling-table name)))
    (for-each (lambda (e) (hash-set! h (car e) (cons (cons (cadr e) (caddr e)) (hash-ref h (car e) '())))) triples)))
;;   floor    #f | lo | (lo hi alpha)  bare need. A number is a HARD floor at lo: a deficit on the good's on-hand, held by the ≥0 balance every good carries (no
;;                                     extra term). A profile (lo hi alpha) is a floor WITH A MARGIN — the calamity reserve q_r^"res" of playnet.typ §Reproduction
;;                                     labour: `held`, divergent at lo so nothing crosses it, satiating at quantile_alpha of [lo,hi] so nothing is over-made for it.
;;   ceiling  #f | hi | (lo hi alpha)  the toxicity edge: a fixed-weight `frag` on the good's own delivered net, felt before the wall, never crossed. A number is
;;                                     the wall itself; a profile (lo hi alpha) is a wall with an uncertainty RANGE and the tip placed precautionarily inside it at
;;                                     quantile_alpha — the exact *frag-cap* reading (alpha = 0 most precautious).
;; Both walls are "a wall, a range, and a point in it"; what the point DOES follows from the shape, and the shape from the side: on a ceiling thrift and the
;; barrier push the same way, so a log barrier settles and the tip is where the plan may NEVER go (frag); on a floor they oppose, a log barrier would settle at
;; w/κ above the wall — a number about weights — so the tip is where the plan is AT EASE and lo is the wall (held). Measured in tests/solve/test-shape-by-side.scm; docs/planning/solve/reproduction-bands.md.
;;   w                                 the governed steepness of the margin floor and the ceiling.
;; A nutrient band (rda ul w) is one entry; an insurance reserve is a floor-with-margin and no ceiling; an eco-style ceiling on a produced good is a ceiling
;; alone. One table, one emission (build-located "REPRODUCTION BAND"), one pour (apply-repro-bands!) shared by every solve path. Fed by plan-from-records
;; #:bands, with #:repro-floors / #:repro-caps / #:insurance as spellings of one edge each, and by a <fragility> record whose extent is a good and whose
;; side is 'floor (engine/fragility.scm).
(define (band-floor b) (car b)) (define (band-ceiling b) (cadr b)) (define (band-w b) (caddr b))
(define* (make-band #:key (floor #f) (ceiling #f) (w 1.0)) (list floor ceiling w))
(define (hash-add! tbl key delta) (hash-set! tbl key (+ (hash-ref tbl key 0.0) delta)))   ; accumulate: tbl[key] += delta (0 default)
;; the two boundless ambient flows the paragraph above names, a raw in every world by
;; construction: sunlight, the low-entropy source every leaf runs on, and the
;; surroundings' heat at T₀ that a heat pump draws and a cooling form sheds. The
;; chemistry layer reads this list as its boundary carriers (catalogues/substances.scm), so the
;; one statement serves the solve and the books.

(define (structural-raw? s)              ; the planner-generated pool that is free by construction
  ;; credit has no cap of its own: a claim column draws it at the good's
  ;; crystallized SNLT and the plan's tally of that draw IS the citizen's drawdown
  ;; (solve-report `credit-drawn`). The bound is the citizen's CERTIFICATE, a
  ;; supplier bundle over every column drawing their credit (*certificates*,
  ;; build-columns) — a row of the program, not a cap on the raw; the ledger
  ;; re-reads the balance where a claim becomes an event (account.scm `claim`)
  ;; only against a race. A reproduction floor is a need met from the commons
  ;; (live.scm eat), and nothing a person holds or lacks buys a way out of it or into it.
  (and (string? s) (or (lab-good? s) (credit-good? s))))
;; `Svc|durable` is NOT free by construction — it is free only where the durable
;; EXISTS. Using a machine nobody has was the last draw in the system that could
;; conjure itself: a recipe drawing Svc|oven with no oven stocked anywhere and no
;; supplier offering one skipped the ≥0 balance entirely and rendered unbounded
;; service, which is exactly what the fail-closed default refuses everywhere else.
;;
;; The test is per SPEC, not per cell, and that distinction is the whole care
;; needed here. A scope that has declared a U-Bahn's seats at the depot has a
;; U-Bahn; the arc machinery still builds a column from every cell, so demanding
;; a cap at each one would read "no seats at B" as "no such network", and a
;; per-cell rule collapses ordinary transit rather than catching anything real.
;; So: a spec capped ANYWHERE is a means the scope holds, and its service stays a
;; structural pool. A spec capped NOWHERE, stocked nowhere, produced by nobody,
;; and yet drawn — that is a machine that does not exist, and it now dies as
;; loudly as an unaccounted material draw.
(define *svc-known* (make-hash-table))   ; specs some cell caps the service of
(define (refresh-svc-known!)
  (hash-clear! *svc-known*)
  (hash-for-each (lambda (g _)
                   (let ((sp (good-spec g)))
                     (when (svc-good? sp) (hash-set! *svc-known* sp #t))))
                 *cap*)
  ;; …and a means held as a SUPPLIER BUNDLE is held just as much as one declared
  ;; cell by cell. Two ways of saying the same thing — "this scope has an oven" —
  ;; and the index knew one of them, so the SAME economy answered `svc-held?`
  ;; differently depending on which way it had been written down. That is what
  ;; broke means-consensus-test when the dead-good reading was narrowed: the
  ;; monolith declares its pool as a bundle spanning cells, the split declares a
  ;; per-cell cap, and only the split's service counted as held.
  ;;
  ;; It is fixed HERE and not in `svc-held?` on purpose. The index is what the
  ;; question is asked of, so every source of the fact belongs in the index —
  ;; the same rule this file states for keepInPlace, where a legacy tag is
  ;; normalised in at construction and stripped so nothing is dual-sourced at
  ;; query time. A predicate that reads three tables is three chances to add a
  ;; fourth and forget one.
  (for-each (lambda (r)
              (when (list-ref r 4)                       ; durable ⇒ its good is Svc|spec
                (for-each (lambda (sp) (hash-set! *svc-known* (svc-good sp) #t)) (cadr r))))
            *resource-suppliers*)
  ;; …and a means that TRAVELS is held just as much: its service left the cell for
  ;; its presence (means->movers!), and the index still knows the scope has it
  (for-each (lambda (rd)
              (when (eq? (mover-kind rd) 'means)
                (for-each (lambda (sp) (hash-set! *svc-known* sp #t)) (caddr rd))))
            *riders*))
;; a service some MEANS MOVER carries — available wherever the mover may stand,
;; which is what its presence, not a cell's cap, decides
;; Read once per *riders* identity: every skill some rider bears, and every
;; service some MEANS mover carries. Both are asked per template × cell, so a
;; crowd of persons answers from the set where a scan would read the crowd.
(define %rider-skill-index (list #f #f #f))   ; (the *riders* read, skill → #t, means service → #t)
(define (rider-skill-index)
  (unless (eq? (car %rider-skill-index) *riders*)
    (let ((any-skill (make-hash-table)) (means-svc (make-hash-table)))
      (for-each (lambda (rd)
                  (for-each (lambda (sk)
                              (hash-set! any-skill sk #t)
                              (when (eq? (mover-kind rd) 'means) (hash-set! means-svc sk #t)))
                            (caddr rd)))
                *riders*)
      (set! %rider-skill-index (list *riders* any-skill means-svc))))
  %rider-skill-index)
(define (mover-service? spec)
  (and (hash-ref (caddr (rider-skill-index)) spec #f) #t))
(define (svc-held? s)                    ; a service whose durable the scope actually holds
  (and (string? s) (svc-good? s) (hash-ref *svc-known* s #f) #t))
;; BARRIER-BOUNDED: a good under a fragility (a cap/spec/budget/container tip) or in
;; the cascade (*eco-couple*) is NOT an externality — its barrier IS its balance. The
;; ≥0 stock balance is REPLACED by the fragility form (felt before the tip, never
;; crossed), so the draw is accounted, not free. Placing a frag on a spec is thus a
;; complete declaration: this is a bounded natural draw, priced as it nears its wall.
;; (*frag-cap* is located-good-keyed → match the bare spec against its keys;
;; *eco-couple* values hold the drawing js.)
(define (barrier-bounded? spec)
  (or (and (hash-ref *frag-spec* spec #f) #t)
      (and (hash-ref *frag-budget* spec #f) #t)
      (and (hash-ref *frag-container* spec #f) #t)
      (and (hash-ref *eco-couple* spec #f) #t)                                    ; a capped (k) agent
      (hash-fold (lambda (k v a) (or a (equal? (good-spec k) spec))) #f *frag-cap*)   ; bare spec of a frag-capped good
      (hash-fold (lambda (k v a) (or a (and (assoc spec v) #t))) #f *eco-couple*)))   ; a drawing (j) agent stressing some k
;; may this spec skip its ≥0 stock balance? — for exactly THREE honest reasons: it is
;; a planner-generated structural pool, its draw is bounded by a barrier (the barrier
;; is its balance), or it is a declared boundless ambient flow. Everything else is a
;; GOOD that must be produced or stocked (fail-closed). never-raw (money) never skips.
(define (spec-skips-balance? spec produced?)
  (and (not produced?)
       (not (hash-ref *never-raw* spec #f))
       (or (structural-raw? spec) (svc-held? spec) (barrier-bounded? spec) (hash-ref *raws* spec #f))
       #t))
(define *desire-w0* 1000.0)                   ; one citizen's whole emphasis (solve/emphasis.scm) — and the weight of a want nobody has weighted at all
;; ── PER-AGENT LABOUR (the §8 fold): an agent's time is a located-dated good ─────
(define *emp-rho* 0.05)               ; EMP congestion weight (small ⇒ equalize among equals); applied as ρ/(h_w·H) per worker so the term is ρ·util² — scale-free
;; THE GOVERNED DIALS, ONE WRITE: every dial scope/policy.scm registers
;; is set here by its registry key — by `plan-from-records` from the solve's
;; keywords, or by a direct-assembly caller (a test laying a world by hand).
;; The one write keeps each variable boxed under compilation.
(define (set-dial! key v)
  (case key
    ((emp-rho) (set! *emp-rho* v))
    ((pref-bound) (set! *pref-bound* (max 0.0 v)))
    ((want-as-cap) (set! *want-as-cap?* (and v #t)))
    ((stock-draw-hours) (set! *stock-draw-hours* v))
    ((kappa) (set-kappa! v))
    (else (error "set-dial!: no such governed dial" key))))
;; quantity as a cap (docs/planning/solve/quantity-as-a-cap.md): a citizen's own
;; want (an owned good, spec-owner) is emitted as a `cap` term — pulled by
;; its emphasis mass alone — beside a wall at its ask, in place of the
;; ask-relative `des`. THE SHIPPED LEVEL IS THE VOICE-TILTED WATER-FILLING:
;; the emphasis mass (voice × share, the spec's own weighting) tilts each
;; citizen's level, the ask never does — the strategyproof member of the
;; sequential-allotment family that carries the spec's law and nothing
;; else. A scope preferring another member of the family (or the old
;; proportional des) states it by policy through this switch; a solve
;; reads it at build time.
(define *want-as-cap?* #t)   ; the DEFAULT: honesty by shape, the level voice-tilted; a governed dial, stated per solve (#:want-as-cap)
(define (want-as-cap?) *want-as-cap?*)   ; the reader — the honesty radius (service.scm) asks which shape is live before correcting for it
;; the cap kind's per-spec REFERENCE SCALE (one natural quantum of the good —
;; a loaf, a night), keyed by base spec; 1.0 unstated. Exogenous knowledge
;; (a catalogue fact), never a report: a scale a report could move would
;; re-open the door the kind closes.
(define *cap-scale* (make-hash-table))   ; stands across reset!: a catalogue fact a caller states (set-cap-scale!), as *willing?* does; never a solve's own
(define (set-cap-scale! spec c) (if (and (number? c) (> c 0)) (hash-set! *cap-scale* spec c) (hash-remove! *cap-scale* spec)))
(define (cap-scale-of g) (hash-ref *cap-scale* (spec-base (key-spec g)) 1.0))            ; 'total ⇒ equal TOTAL burden per worker | 'pool ⇒ uniform WITHIN each skill pool
(define (set-worker-pref! worker skill pref) (hash-set! *worker-pref* (cons worker skill) pref))
;; The who rail's bound (voice-follows-work.md open item 6, the egalitarian
;; matching principle): a private preference is EQUAL and BOUNDED. π̂ is read
;; clamped to [−β, β], centred on the person's own mean over the skills they
;; hold in the plan, and stated in EMP's own unit — π = π̂·2ρ/H — so between
;; two workers the solve settles at u_a − u_b = π̂_b − π̂_a: a preference is
;; how much less of one's offered time than an indifferent person's, at most
;; 2β apart, the same for every citizen whatever their hours, and scale-free
;; as EMP is. Centring makes a tilt reorder a person's work and leave how
;; much they work to the hours they offer; equal reluctance all round
;; cancels exactly. β is the governed number.
(define *pref-bound* 1.0)                 ; a governed dial, stated per solve (#:pref-bound)
(define (offered-labour-hours)            ; H: total offered LABOUR hours (means capacity is not fairness-normalised)
  (fold (lambda (b a) (if (list-ref b 4) (+ a (cadr b)) a)) 0.0 *supplier-bundles*))
(define (worker-tilts)
  "((worker . ((skill . π̂ − mean) …)) …): every worker's clamped preference on
   each skill they hold a column for, centred on their own mean."
  (map (lambda (w)
         (let* ((skills (delete-duplicates
                         (filter-map (lambda (e) (assq-ref (key-terms (car e)) 'skill)) (cadddr w))))
                (hat (lambda (s) (max (- *pref-bound*) (min *pref-bound* (hash-ref *worker-pref* (cons (car w) s) 0.0)))))
                (mean (if (null? skills) 0.0 (/ (fold + 0.0 (map hat skills)) (length skills)))))
           (cons (car w) (map (lambda (s) (cons s (- (hat s) mean))) skills))))
       (filter (lambda (b) (list-ref b 4)) *supplier-bundles*)))
;; LEGAL gate (§6 legal-crossings.md): a derived `forbid` (or unmet credential)
;; prunes the activity's column — the same mechanism that prunes a recipe with
;; no skilled worker. (process-id, cell) → #t ⇒ forbidden here. Default no-op,
;; set via plan-scope #:legal-decorate (survives reset!, like *willing?*).
;; The WHOLE bill feeds the planner through its existing organs (§6, §2.6):
;;   (proc-id, cell) → (values prune? cost skill-reqs)
;;     prune?     : a hard `forbid`/unmet — a possibility-tension (column pruned)
;;     cost       : a `pay` levy (+ soft/uncertain penalties) — a labour-hour rent
;;                  added to the column's labour, so the plan ROUTES AROUND it
;;     skill-reqs : `obtain`(person) licences — required skills, gated by the
;;                  SAME satisfied-by closure as any skill (a licence IS a skill)
(define *legal-decorate* (lambda (proc-id cell) (values #f 0.0 '())))
;; the doors a caller uses to state these — a set! on an imported binding is refused by a compiled build
(define (set-promote! v) (set! *promote* v))
(define (set-willing! f) (set! *willing?* f))
(define (set-legal-decorate! f) (set! *legal-decorate* f))
(define (set-acquire! v) (set! *acquire* v))
;; ── ARC-TIME TABLE: real network travel time, when known ─────────────────────
;; THE CLIMB. An arc a→b rises what b stands above a (the places' stated altitudes,
;; *alt*), and lifting a load costs m·g·h beyond the road. Each manner states how
;; many metres of climb cost what a kilometre of level road does — the reciprocal
;; of its rolling resistance in thousandths: a car or truck near 15 (Crr ≈ 0.015
;; with the drivetrain), a bicycle near 100, a walker 120 (Naismith's rule, 600 m
;; up for 5 km along). The DISTANCE-spent flows of a transport recipe (fuel, wear,
;; loss) then scale by the road plus the climb's equivalent, and a manner the
;; table does not name climbs at the car's figure. Descent is free: the brake's
;; heat is the surroundings' and the road already paid for.
(define *climb-per-km* '(("pedestrian" . 120.0) ("bicycle" . 100.0) ("auto" . 15.0) ("truck" . 15.0) ("bus" . 15.0)))
(define (arc-climb-m a b)                 ; metres b stands above a, never below zero
  (let ((za (hash-ref *alt* (place-of a) #f)) (zb (hash-ref *alt* (place-of b) #f)))
    (if (and za zb) (max 0.0 (- zb za)) 0.0)))
(define (arc-climb-km a b manner)         ; the climb as the kilometres of level road it costs
  (/ (arc-climb-m a b) (or (assoc-ref *climb-per-km* manner) (assoc-ref *climb-per-km* "auto"))))
(define (run-id of org dst)             ; a run of OF (a recipe's process, or the good a bare carry moves) between two cells
  (keyed-id "run" of org dst))
(define (plan-runs)
  (sort (hash-map->list cons *runs*) (lambda (a b) (string<? (car a) (car b)))))
(define (workers?) (pair? *workers*))
;; lab-good, svc-good?, pres-good, credit-good? and the rest of the bar-key grammar:
;; (playnet vf facts located), the one builder and reader of every key
(define (svc-spec g) (bar-spec g))
;; ── WORKER-AS-RIDER: a mobile worker present where the plan puts them ────────────
(define (riders?) (and (pair? *riders*) (pair? *mode-recipes*)))
(define (inert-caps) *inert-caps*)
(define (skilled?) (or *roster-labour?* (workers?) (riders?)))          ; labour routes through Lab|skill goods (not aggregate) when EITHER is present
;; A rider's HOURS in a period: one number holds for every period; an alist
;; ((period . hours) …) reads each period its own — a person whose roster entries
;; differ by day, a means whose availability window does — and a period the alist
;; leaves out has none.
(define* (rider-hours rd t #:optional skill)
  (let ((h (or (and skill (hash-ref *borne-hours* (cons (car rd) skill) #f))   ; what it bears keeps its own hours (means->movers!)
               (cadddr rd))))
    (if (number? h) h (or (assv-ref h t) 0.0))))
(define (mrec-rp e) (car e)) (define (mrec-flows e) (cadr e))
(define (mrec-name e) (recipe-process-name (mrec-rp e)))
(define (mover-flows flows)              ; (work . pickup): the `work` resolved from a pickup — the moved one's own work, what makes a recipe a mode — and the pickup it rides
  (any (lambda (f)
         (and (eq? 'work (recipe-flow-action f)) (recipe-flow-resolve-from-flow f)
              (let ((p (find (lambda (g) (and (eq? 'pickup (recipe-flow-action g))
                                              (equal? (recipe-flow-id g) (recipe-flow-resolve-from-flow f))))
                             flows)))
                (and p (cons f p)))))
       flows))
;; ── A MODE MAY NAME ITS MOVER ────────────────────────────────────────────────
;; A travel mode relocates a generic mover — the hole a rider's own good fills.
;; A mode whose mover is a MEANS' own specification (a flat key, a projector) is
;; how that means travels: carried, by the mode's `work` line, at the mode's
;; pace. The means is then a mover like a tractor that drives itself
;; (means->movers!) — one whole thing, in one place a band, rendering its
;; capacity where it stands — and the mode is its alone.
(define (mrec-self e) (car (mover-flows (mrec-flows e))))
(define (mrec-good e)                    ; the generic mover the recipe relocates — the hole a rider's own good fills
  (recipe-flow-resource-conforms-to (cdr (mover-flows (mrec-flows e)))))
(define (mrec-skill e)                   ; the skill the mover bears to travel this way; #f when being moved is all it takes
  (let ((sk (recipe-flow-resource-conforms-to (mrec-self e))))
    (and (not (equal? sk (mrec-good e))) sk)))
(define (spec-used? spec)                ; a means: some process of the scope `use`s it
  (let ((svc (svc-good spec)))
    (any (lambda (tpl) (and (assoc svc (proc-inputs tpl)) #t)) *templates*)))
(define (mode-means e)                   ; the thing this mode carries — a means, or a container that is a mover — #f for a mode anyone may ride
  (let ((g (mrec-good e)))
    (and (or (spec-used? g)
             (hash-fold (lambda (id lot found) (or found (equal? g (car lot)))) #f *means-lot*))
         g)))
(define (means-carried? spec)            ; some mode of the scope names this means as its mover
  (any (lambda (e) (equal? spec (mrec-good e))) *mode-recipes*))
(define (means-ride? pid)                ; a ride of a means: where a thing stands is one fact in every future
  (let ((i (hash-ref *ride-info* pid #f)))
    (and i (hash-ref *means-lot* (cdr i) #f) #t)))
(define (ride-mode-process pid)          ; the mode process a ride is a run of; #f for any other process
  (let ((i (hash-ref *ride-info* pid #f)))
    (and i (recipe-process-id (mrec-rp (car i))))))
(define (mrec-manner e) (or (recipe-manner (mrec-rp e)) *material-manner*))
(define (bare-run-template)              ; the recipe process of the mode a bare carry rides: the one whose manner is the material manner
  (let ((e (find (lambda (e) (equal? (recipe-manner (mrec-rp e)) *material-manner*)) *mode-recipes*)))
    (and e (recipe-process-id (mrec-rp e)))))
(define (mrec-pace e)                    ; the mover's own hours per km; unstated, the manner's fallback pace
  (let ((eff (recipe-flow-effort-quantity (mrec-self e))))
    (if eff (measure-has-numerical-value eff) (assoc-ref *manner-pace* (mrec-manner e)))))
(define (mode-ok? e rd)                  ; can this rider use this mode? — a mode that names a means is that means' own; else the same list skilled-worker-at? reads
  (let ((means (mode-means e)))
    (if means
        (equal? means (and=> (hash-ref *means-lot* (car rd) #f) car))
        (or (not (mrec-skill e)) (member (mrec-skill e) (caddr rd))))))
;; The scope's recipes, parted: (values mode-entries other-procs). A mode's
;; process leaves the generic compile, since the mover machinery instantiates
;; it per rider. One pass over the flows names the mode processes (a mover's
;; work beside its pickup), a second gathers each mode's own flows in order.
(define (part-mode-recipes procs flows)
  (let ((by-id (make-hash-table)) (own (make-hash-table)))
    (for-each (lambda (f) (hash-set! by-id (recipe-flow-id f) f)) flows)
    (for-each (lambda (f)
                (let ((p (and (eq? 'work (recipe-flow-action f))
                              (hash-ref by-id (recipe-flow-resolve-from-flow f) #f))))
                  (when (and p (eq? 'pickup (recipe-flow-action p))
                             (equal? (recipe-flow-recipe-input-of p) (recipe-flow-recipe-input-of f)))
                    (hash-set! own (recipe-flow-recipe-input-of f) '()))))
              flows)
    (for-each (lambda (f)
                (let ((h (hash-get-handle own (or (recipe-flow-recipe-input-of f)
                                                  (recipe-flow-recipe-output-of f)))))
                  (when h (set-cdr! h (cons f (cdr h))))))
              (reverse flows))
    (call-with-values
        (lambda () (partition (lambda (rp) (hash-get-handle own (recipe-process-id rp))) procs))
      (lambda (modes rest)
        (values (map (lambda (rp) (list rp (hash-ref own (recipe-process-id rp)))) modes)
                rest)))))
;; ── the worker IS the rider (spec §The worker is a rider) ────────────────────
;; `*workers*` and `*riders*` are not two populations — they are two ways to say
;; where one person is. A worker is PINNED: ingest-located! records them at their
;; home (or a position override) once per period, and their labour is supplied
;; there. A rider is MOBILE: the same person, their presence starting at that same
;; home and relocated by rides the plan chooses, supplying labour wherever it
;; rests. So when a shed declares travel MODES, the honest reading of its people
;; is the mobile one — the doctor can be carried to the patients instead of only
;; the patients to the doctor.
;;
;; The two are mutually exclusive per person: each builds its own labour-supply
;; columns, so anyone left in both lists would supply their hours twice. This
;; MOVES them rather than adding, which is what keeps that impossible.
;;
;; A skill a mode asks that reaches the agent as a classifiedAs tag — the same
;; channel agent->subsistence-ctx reads for age and region — is narrowed
;; (mobility-skills) to the skills the scope's modes ask, and folded into the
;; SAME list as the agent's work-skills (workers->riders!, below), tested by
;; the identical bare-membership rule skilled-worker-at? applies to "doctor" —
;; so an untagged crowd is a crowd that walks nowhere rather than one that
;; silently teleports.
(define (mode-skills) (delete-duplicates (filter-map mrec-skill *mode-recipes*)))
;; Narrow any raw classifiedAs-style tag list — an agent's (workers->riders!)
;; or a mobile means's own (means->movers!) — down to the skill NAMES the
;; scope's modes ask, before folding it into a mover's skills
;; list: an unrelated tag never leaks in as a bogus thing rider-columns would
;; otherwise suppose this mover supplies.
(define (mobility-skills tags) (filter (lambda (c) (member c (or tags '()))) (mode-skills)))
(define (workers->riders! agents)
  "Re-read the pinned *workers* as mobile *riders*, one per PERSON, based where
   their earliest period puts them. An organisation stays pinned: a commune is not
   somewhere that travels, and treating one as a mover would put its holdings on
   the road. A no-op without modes, and without workers."
  (when (and (pair? *mode-recipes*) (pair? *workers*))
    (let* ((agent-index (let ((h (make-hash-table)))             ; first agent of an id, read once for the crowd
                          (for-each (lambda (a) (unless (hash-ref h (agent-id a) #f) (hash-set! h (agent-id a) a)))
                                    agents)
                          h))
           (agent-of (lambda (id) (hash-ref agent-index id #f)))
           (by-id (make-hash-table)) (hours-of (make-hash-table)) (stay '()))
      (for-each (lambda (w)
                  (let ((a (agent-of (car w))))
                    (if (and a (eq? 'person (agent-type a)))
                        (let ((prev (hash-ref by-id (car w) #f)))   ; keep their EARLIEST cell…
                          (when (or (not prev)
                                    (< (period-of (caddr w)) (period-of (caddr prev))))
                            (hash-set! by-id (car w) w))
                          (hash-set! hours-of (car w)                ; …and EVERY period's hours
                                     (let* ((t (period-of (caddr w))) (h (hash-ref hours-of (car w) '())))
                                       (assv-replace h t (+ (cadddr w) (or (assv-ref h t) 0.0))))))
                        (set! stay (cons w stay)))))
                *workers*)
      (set! *riders*
            (append *riders*
                    (map (lambda (w)
                           (let ((a (agent-of (car w))))
                             (list (car w)                       ; id
                                   (place-of (caddr w))          ; base = where they start
                                   (append (cadr w)                                            ; work-skills…
                                           (mobility-skills (and a (agent-classified-as a))))   ; …and the skills its modes ask, ONE list
                                   (hash-ref hours-of (car w)))))                               ; hours, by period (rider-hours)
                         (hash-map->list (lambda (k v) v) by-id))))
      (set! *workers* (reverse stay)))))
;; ── SKILL DYNAMICS: a skill is labour-power, its lifecycle on the ResourceSpec ─
(define* (set-skill-spec! skill #:key (decay 0.0) (regen 0.0) (yield 1.0) (lag 1)
                          (teacher 0.0) (trainee 0.0) (endow 0.0) (refresh 0.0))
  ;; refresh = the maintenance YIELD of a DEDICATED refresher activity: regen per hour a worker spends
  ;; keeping the skill warm WITHOUT producing output (recertification/drills, the paper's distinct
  ;; refresher recipe). 0 ⇒ no refresher channel (the default; on-the-job practice is the only upkeep,
  ;; exactly as before). >regen ⇒ dedicated practice is the efficient way to hold a skill in a lull.
  (hash-set! *skill-spec* skill (vector decay regen yield lag teacher trainee endow refresh)))
(define (skill-spec skill) (hash-ref *skill-spec* skill #f))
(define (sk-decay s)(vector-ref s 0)) (define (sk-regen s)(vector-ref s 1)) (define (sk-yield s)(vector-ref s 2))
(define (sk-lag s)(vector-ref s 3)) (define (sk-teacher s)(vector-ref s 4)) (define (sk-trainee s)(vector-ref s 5))
(define (sk-endow s)(vector-ref s 6)) (define (sk-refresh s)(vector-ref s 7))
(define (skill-refreshes? skill) (let ((sp (skill-spec skill))) (and sp (> (sk-refresh sp) 0.0))))   ; has a dedicated refresher channel
(define* (add-trainable! w skill from #:optional (mentor skill))
  (set! *trainable* (cons (list w skill from mentor) *trainable*)))
(define (set-competence! w skill c) (hash-set! *competence-p0* (cons w skill) (exact->inexact c)))
(define (competence-p0 w skill) (hash-ref *competence-p0* (cons w skill) #f))
;; The records door's one way to declare skill dynamics: ENTRIES ((worker skill
;; law c0) …), LAW an alist over set-skill-spec!'s keywords. The laws declared
;; here are the whole of this solve's — a spec from an earlier solve does not
;; linger — and every entry is trainable from the first period, its competence
;; opening at C0 (planner/formulas/skill-law.scm reads C0 off the record).
(define (apply-skill-dynamics! entries)
  (hash-clear! *skill-spec*)
  (for-each (lambda (e)
              (let ((w (car e)) (skill (cadr e)) (law (caddr e)) (c0 (cadddr e)))
                (unless (skill-spec skill)
                  (apply set-skill-spec! skill
                         (append-map (lambda (k) (let ((v (assq-ref law k)))
                                                   (if v (list (symbol->keyword k) v) '())))
                                     '(decay regen yield lag teacher trainee endow refresh))))
                (add-trainable! w skill 0)
                (set-competence! w skill c0)))
            entries))
(define (skill-dynamics?) (and (workers?) (pair? *trainable*) (pair? (hash-map->list cons *skill-spec*))))
;; skill of a process: the recipe's work resourceConformsTo (VF-conformant), with
;; *proc-skill* as an optional manual override.
;; the (skill . hours) list a process needs: the recipe's per-skill work (default),
;; or — if *proc-skill* overrides this proc-id — all its labour under that one skill.
(define (proc-skill-labours-of tpl)
  (let ((ov (hash-ref *proc-skill* (proc-id tpl) #f)))
    (cond (ov (list (cons ov (proc-labour tpl))))
          ((pair? (proc-skill-labours tpl)) (proc-skill-labours tpl))
          ((> (proc-labour tpl) 0.0) (list (cons "general" (proc-labour tpl))))
          (else '()))))
;; a skill is available at cell c if some worker holds it AND lives there, or can
;; COMMUTE there (same period, within *commute-km* of their home).
(define (worker-reaches? w c)
  (or (equal? (caddr w) c)
      (and (= (period-of (caddr w)) (period-of c))
           ;; time gate when opted in (*commute-hours*) AND the arc is in the
           ;; table; the km gate otherwise — today's behaviour, byte-identical.
           (let ((h (and *commute-hours*
                         (hash-ref *arc-hours* (arc-key (caddr w) c *commute-manner*) #f))))
             (if h (<= h *commute-hours*)
                 (<= (km (caddr w) c) *commute-km*))))))
;; Indexed once per *workers* identity, period → skill → workers-with-it: every
;; valid match for cell C is a worker in C's own period (worker-reaches? requires
;; it, or exact cell equality which implies it), so this narrows the candidate
;; set from ALL workers to just those sharing both. skilled-worker-at? is called
;; once per skill requirement of every candidate column in build-columns — an
;; O(workers) scan there made column-building O(columns × workers) worst case.
(define %worker-skill-index (list #f #f))     ; (the *workers* it was read off, period → skill → workers)
(define (worker-skill-index)
  (unless (eq? (car %worker-skill-index) *workers*)
    (let ((idx (make-hash-table)))
      (for-each (lambda (w)
                  (let* ((p (period-of (caddr w)))
                         (per (or (hash-ref idx p #f)
                                  (let ((h (make-hash-table))) (hash-set! idx p h) h))))
                    (for-each (lambda (skill) (hash-set! per skill (cons w (hash-ref per skill '()))))
                              (cadr w))))
                *workers*)
      (set! %worker-skill-index (list *workers* idx))))
  (cadr %worker-skill-index))
(define (skilled-worker-at? skill c)
  (or (let ((per (hash-ref (worker-skill-index) (period-of c) #f)))
        (and per (find (lambda (w) (worker-reaches? w c)) (hash-ref per skill '()))))
      (hash-ref (cadr (rider-skill-index)) skill #f)                      ; a rider can be present at any cell (the presence gate bounds it)
      (let ((cap (hash-ref *cap* (lab-good skill c) #f))) (and cap (> cap 0.0)))))   ; or a raw labour pool capped here (e.g. a driver pool)
(define (km a b)
  (let ((A (hash-ref *latlon* (place-of a))) (B (hash-ref *latlon* (place-of b))) (d2r (/ 3.141592653589793 180.0)))
    (if (or (not A) (not B) (equal? (place-of a) (place-of b))) 0.0
        (let* ((la1 (* d2r (car A))) (la2 (* d2r (car B)))
               (dla (* d2r (- (car B) (car A)))) (dlo (* d2r (- (cdr B) (cdr A))))
               (h (+ (expt (sin (/ dla 2)) 2) (* (cos la1) (cos la2) (expt (sin (/ dlo 2)) 2)))))
          (* 6371.0 2.0 (atan (sqrt h) (sqrt (- 1.0 h))))))))
;; arc-hours: travel TIME (hours) a→b in MANNER. One hash lookup on the hot path;
;; RATE is the call site's existing hours-per-km coefficient, so an absent key —
;; and in particular an empty table — yields exactly rate·km(a,b): strict parity
;; with the geometric planner by construction, not by tuning. The same-place
;; guard comes FIRST so a stray self-arc key can never perturb it.
(define (arc-key a b manner)
  (string-append (place-of a) "|" (place-of b) "|" manner))
;; A table value is HOURS, or (HOURS . NET-KM) when matrix-sourced — the
;; routing engine reports real road distance alongside time, so a tabled arc
;; can answer BOTH "how long does it take" (arc-hours) and "how far is the
;; road" (arc-net-km, for the distance-spent flows: fuel over switchbacks is
;; fuel over switchbacks). Observed-trip entries are bare hours (a trip
;; measures time, not odometry); both shapes coexist in one table.
(define (arc-ref a b manner)
  (and (not (equal? (place-of a) (place-of b)))
       (let ((base (arc-key a b manner)))
         (or (let ((cls (*period-class-of* (period-of a))))   ; departure period's class
               (and cls (hash-ref *arc-hours* (string-append base "|" cls) #f)))
             (hash-ref *arc-hours* base #f)))))
(define (arc-hours a b manner rate)
  (let ((v (arc-ref a b manner)))
    (cond ((pair? v) (car v))
          (v v)
          ((equal? (place-of a) (place-of b)) 0.0)
          (else (* rate (km a b))))))
(define (arc-net-km a b manner)
  (let ((v (arc-ref a b manner)))
    (if (pair? v) (cdr v) (km a b))))
;; STORAGE vs TRANSPORT is DERIVED from the container the recipe uses, never marked on the recipe:
;; a recipe that `use`s a STATIONARY container (warehouse/silo) relocates its good through TIME — it
;; tiles over a temporal arc (same place, next period), scaled by 1 period. A recipe using only MOBILE
;; containers (or none) relocates through SPACE — spatial arcs (place→place), scaled by km. The solver
;; just composes from the recipes; the one arc machinery serves both, loss is a recipe consume.
(define (place-adjacent? pa pb)               ; is there a transport EDGE pa→pb? (a place with a declared neighbour list uses it; one with none is connected to all — the legacy default)
  (let ((nb (hash-ref *neighbours* pa #f))) (if nb (and (member pb nb) #t) #t)))
;; arc TARGETS of a cell — so build-columns iterates only the real edges, O(cells·degree), not O(cells²).
(define (spatial-targets a)                   ; cells one transport edge away: same period, a NEIGHBOUR place (declared edges, else all other places = legacy)
  (let* ((p (place-of a)) (t (period-of a)) (nb (hash-ref *neighbours* p #f)))
    (map (lambda (q) (cell q t)) (or nb (delete p *places*)))))
(define (temporal-target a)                   ; the cell one period forward, same place — or #f at the horizon
  (let ((t1 (+ 1 (period-of a)))) (and (member t1 *periods*) (cell (place-of a) t1))))
;; two periods are BANDS OF ONE DAY when their spans fall on the same single
;; date — the clock refinement cut them from one declared day. What a day
;; holds carries freely between its own bands whatever the spec's
;; storability: storability is a cross-DAY declaration, and a stock that
;; landed on the day's first band (00:00–09:00) is the same stock at noon.
(define (same-day-bands? t t1)
  (let ((d (period-dates t)) (d1 (period-dates t1)))
    (and (pair? d) (null? (cdr d)) (equal? d d1))))
(define (refined-day-present?)               ; does any adjacent period pair share a day?
  (any (lambda (t) (let ((t1 (+ t 1))) (and (member t1 *periods*) (same-day-bands? t t1))))
       *periods*))
;; ── A TRIP TAKES TIME, so it lands in the period it can earliest arrive in ────
;; Storage already says this about its own arc: a good held over lands NEXT period,
;; because the holding took a period. A journey is the same statement about space —
;; three hours of driving is three hours whichever place it ends at — and reading
;; the destination as the DEPARTURE period says a good arrives at the moment it
;; left. At a daily period that is honest aggregation: everything inside one day is
;; simultaneous by construction, and a 3 h haul fits. It stops being honest exactly
;; when the period is shorter than the trip, and that is the case a refined
;; partition creates — so the reading that was fine while periods were coarse gets
;; worse precisely as the lattice gets better (docs/planning/solve/intra-period-time.md
;; makes refinement the answer to everything else; this is where it needed help).
;;
;; The rule: advance until the periods from the departure onward COVER the trip.
;; A trip shorter than its period lands where it always did, so nothing about a
;; coarse scope changes; a longer one lands later, and one that cannot finish inside
;; the horizon does not land at all. That last case is a refusal on purpose — a good
;; arriving after the plan ends has not arrived, and pretending otherwise is the
;; same free lunch as arriving before you left.
(define (arrival-period t hours)
  "The earliest period whose span, accumulated from T's own start, covers HOURS.
   T itself when the trip fits inside it; #f when the horizon runs out first."
  (if (<= hours 0.0) t
      (let loop ((tt t) (acc 0.0))
        (let ((acc (+ acc (period-hours tt))))
          (cond ((>= acc hours) tt)
                ((member (+ tt 1) *periods*) (loop (+ tt 1) acc))
                (else #f))))))
(define (arrival-cell tpl a b)
  "Where and WHEN a trip a→b under TPL puts its cargo: B's place, at the period the
   journey can earliest reach. #f when it reaches past the horizon."
  (let* ((pace (tpl-pace tpl))
         (hrs  (arc-hours a b (tpl-manner tpl) (or pace 0.0)))
         (t    (arrival-period (period-of a) hrs)))
    (and t (cell (place-of b) t))))
(define (spec-stationary? spec) (and (member spec *stationary*) #t))
;; The spec is the single source of truth: keep-in-place is an explicit field on
;; ResourceSpecification, and `resource-spec-keep-in-place?` reads that field and
;; nothing else. The legacy "stationary" classifiedAs tag is normalised into the
;; field by the smart constructor, which also STRIPS it — so a tag never survives
;; construction and is never consulted at query time. Nothing here is dual-sourced.
;; The scope's own ResourceSpecifications, read for the FIELDS the solve needs.
;; Two so far, and they are the same kind of fact: what a spec declares about
;; itself, rather than what a caller remembers to pass. keepInPlace decides
;; whether using a thing as a container moves its contents through time or
;; through space.
;;
;; Whether a holding is a COUNT or a capacity is read off the holding's own unit
;; (`holding-capacity`), because a quotient unit states the whole fact — number,
;; substance and denominator together — and the measure is where a unit lives.
;; `defaultUnitOfResource` stays the catalogue's word for what a kind is counted
;; in, which is what makes a holding that contradicts its spec a FINDING
;; (tests/scope/test-holdings-audit.scm) rather than an arithmetic that quietly
;; splits into two answers depending on which of the two is asked.
;;; ── ELEMENT CLOSURE: conservation as a CONSTRAINT, not a reading ─────────────
;; docs/social-material.typ: "a balanced chemical reaction is a recipe … the convex
;; optimiser solves a reaction network with no new machinery". For a recipe authored
;; AS a reaction that is already true — its elements are specs and the solver balances
;; them like any good. This closes the other half: an ordinary PRODUCT recipe's
;; element accounting, which was a post-solve reading (`plan->material`) rather than
;; a constraint the plan had to satisfy.
;;
;; The rule is one row per element per cell, and it is the residual `check-conservation`
;; already computes, promoted from a check to a good:
;;
;;     El|e  supplied by  Σ_consumed q·frac(s,e)  −  Σ_produced q·frac(s,e)
;;
;; with the ordinary `≥ 0` balance every good gets. Read it as: the element entering a
;; process must cover the element leaving in its products.
;;
;; The law is a property of the TEMPLATE. A run's net is linear in the run, so a
;; template that creates a leaf on one run creates it on every run, and the verdict
;; is read once, here, before any column is laid. `≥ 0` forbids exactly the
;; impossible half, and the two halves land in two places:
;;
;;   CREATION  — carrying out more of a leaf than was drawn, past what the bars on
;;               its flows can explain — REFUSES the
;;               template: it is dropped and named in *why-not* by its process id,
;;               ('creates (leaf . net) …), so the plan's `blocked` tally says so.
;;               Matter is not conjured, and a neighbour's loss pays for nothing:
;;               a loss goes to the surroundings, full stop.
;;   LOSS      — drawing more than is carried out in any named form — is a positive
;;               `El|leaf` output, a SURPLUS nothing consumes: the sink, made visible.
;;               What a recipe returns to the sky by name (the breath, the vapour) is
;;               named, so the row is the loss nobody named, which is what the rift IS
;;               (social-material.typ §conservation as keystone: "each loss is a
;;               named output").
;;
;; THE BARS. How good the chemistry is belongs to the chemistry, so it arrives with
;; it: a composition row carries its bar on a leaf under the leaf's name behind a
;; sign ("±C"), and a run's allowed shortfall on a leaf is each flow's quantity
;; times its row's bar, summed. A row stating no bar is taken at its word. The bars
;; are intervals with no probability over them, and the refusal reads them at their
;; widest, every flow at its own bar at once, since a refusal has to hold whatever
;; the truth inside them is; the budgeted wall below reads a set of the same kind
;; with the other quantifier, a promise that must hold for every member.
;;
;; UNKNOWN IS UNREAD. Of an element, a row that says nothing holds none: absence
;; means zero. Of heat it means the opposite, that nobody has said: a form made of
;; matter whose formation no table states holds SOME heat, unknown. Such a row says
;; so ("?heat"), and a leaf is read on a template only where every row it touches
;; is known on that leaf; the rest of its leaves are judged as ever.
;;
;; WHAT A LOSS TAKES WITH IT. A leaf lost with no name left in SOME form, and that
;; form carried heat. How much is not known, so the judgement grants the most the
;; lost atoms could have taken: a row keyed by a LEAF says what a unit of that leaf
;; carries of another in the form it leaves in at the last (the door states carbon
;; as carbon dioxide and hydrogen as water, the two ends of every burning), and an
;; unnamed loss is credited with it. A recipe that lets a third of its flour go
;; unnamed is lossy; it has made no heat.
;;
;; THE EDGE. Conservation is a claim about an INTERNAL transformation. A template that
;; draws nothing of any leaf has substance on one side only: a harvest or a gift at
;; the system's edge (catalogues/substances.scm `boundary-process?`, the same line the lint
;; draws), the author's word until it names its stock. No balance it was never
;; inside judges it, and what bounds it is the stock or the ecology it names. A
;; process may also SAY it is the edge, by its classification "boundary": the
;; shine (world.scm) is the sky speaking, laying the light and the rain a hectare
;; receives, and says so.
;;
;; And it costs nothing where the knowledge is honest: a conserving recipe has net 0,
;; so it carries no row at all. The constraint is invisible until a recipe is wrong,
;; which is when you want it.
;;
;; No double counting. `soil-n` IS nitrogen, and it keeps its own good and its own
;; stock — how much soil nitrogen exists is a different question from whether the
;; nitrogen leaving in products was drawn from somewhere. Two constraints, both true.
;; ── COMPOSITION IS PER RECIPE, and a spec-level row is the default ───────────
(define (element-closure-on?) (> (hash-count (const #t) *composition*) 0))
(define* (spec-element-fraction spec element #:optional (proc #f))
  "How much of ELEMENT a unit of SPEC carries. PROC, when given, prefers that
   process's own row — the per-recipe composition — and falls back to the spec's."
  (or (and proc (assoc-ref (hash-ref *composition* (cons proc spec) '()) element))
      (assoc-ref (hash-ref *composition* spec '()) element)
      0.0))
(define (composition-elements)             ; the leaves the rows speak of: a row's bars and its unknowns ride beside them and are no leaf
  (delete-duplicates
   (hash-fold (lambda (key edges acc)
                (append (filter (lambda (e) (not (and (string? e) (or (string-prefix? "±" e) (string-prefix? "?" e))))) (map car edges)) acc))
              '() *composition*)))
(define (substance-bearing? good)          ; Svc|/Lab|/El|/credit| carry no substance of their own
  (and (string? good)
       (not (svc-good? good))
       (not (lab-good? good))
       (not (el-good? good))
       (not (credit-good? good))))
(define (slack-key element) (string-append "±" element))   ; a row carries its bar on a leaf under the leaf's name behind the sign (catalogues/substances.scm)
(define (template-element-sides tpl element)
  "(drawn . carried-out) of ELEMENT by ONE run of TPL. Outputs read THIS recipe's own
   composition; inputs read the spec's (see above). What a recipe returns to the
   sky by name (the breath, the vapour) is carried out like any product: a leaf
   that left in a named form is accounted for, and heat is read in the formation
   frame, where leaving a product out would read an ordinary burning as heat made."
  (let ((proc (proc-id tpl)))
    (define (side flows frac)
      (fold (lambda (fq a) (if (substance-bearing? (car fq)) (+ a (* (cdr fq) (frac (car fq)))) a)) 0.0 flows))
    (cons (side (proc-inputs tpl) (lambda (s) (spec-element-fraction s element)))
          (side (proc-outputs tpl) (lambda (s) (spec-element-fraction s element proc))))))
(define (template-element-net tpl element)
  "What ONE run of TPL leaves UNNAMED of ELEMENT: drawn in, less carried out in any
   form it names."
  (let ((s (template-element-sides tpl element))) (- (car s) (cdr s))))
(define (template-element-bar tpl element)
  "How much of ELEMENT the bars on TPL's flows can explain, per run: each flow's
   quantity times its row's bar, summed. The bars are intervals and add as
   intervals do, every flow at its own at once: a refusal has to hold whatever the
   truth inside them is."
  (let ((s (template-element-sides tpl (slack-key element))))
    (+ (abs (car s)) (abs (cdr s)))))
(define (template-unread? tpl element)
  "Does some row TPL touches say ELEMENT is unknown of it? The leaf is then unread on TPL."
  (let ((s (template-element-sides tpl (string-append "?" element))))
    (not (and (zero? (car s)) (zero? (cdr s))))))
(define (template-at-edge? tpl)
  "Does TPL stand at the system's edge: by its own word (classified \"boundary\"), or
   drawing nothing of any leaf, so that substance crosses in one direction only?"
  (or (and (member "boundary" (or (proc-tags tpl) '())) #t)
      (every (lambda (e) (zero? (car (template-element-sides tpl e)))) (composition-elements))))
(define (template-creates tpl)
  "((leaf . net) …): what ONE run of TPL carries out beyond what it draws, past what
   the bars on its flows can explain and what its unnamed losses took with them;
   '() for a conserving or a lossy template, and for one at the edge, which no
   balance judges."
  (if (template-at-edge? tpl) '()
      (let* ((els (filter (lambda (e) (not (template-unread? tpl e))) (composition-elements)))
             (sides (map (lambda (e) (cons e (template-element-sides tpl e))) els))
             ;; what the leaves lost unnamed carried of E at the last: each loss times its leaf's row
             (taken (lambda (e)
                      (fold (lambda (s a)
                              (let ((lost (- (cadr s) (cddr s))))
                                (if (and (> lost 0.0) (not (equal? (car s) e)))
                                    (+ a (* lost (spec-element-fraction (car s) e)))
                                    a)))
                            0.0 sides))))
        (filter-map (lambda (s)
                      (let* ((e (car s)) (in (cadr s)) (out (cddr s)) (net (- in out (taken e))))
                        (and (< net (- (+ (template-element-bar tpl e)
                                          (* 1e-9 (max (abs in) (abs out))) 1e-12)))   ; the bars, and the last digit of a sum
                             (cons e net))))
                    sides))))
(define (close-elements!)
  "Every template its element rows, and a creating template refused. A run's net is
   linear in the run, so the verdict is the template's: one that creates a leaf is
   dropped and named in *why-not* by its process id ('creates (leaf . net) …); the
   rest carry a positive El| output per leaf they lose UNNAMED, the rift visible,
   which nothing consumes, so no neighbour's loss pays for a creation. Idempotent:
   an El| output already present is replaced, so re-ingesting does not double it."
  (when (element-closure-on?)
    (let ((els (composition-elements)))
      (set-templates!
        (filter-map
          (lambda (tpl)
            (let ((made (template-creates tpl)))
              (if (pair? made)
                  (begin (hash-set! *why-not* (proc-id tpl) (cons 'creates made))
                         (when (getenv "PLANNER_RAW_LINT")     ; the lint's own word, beside starved and stranded
                           (format (current-error-port) "[RAW-LINT] ~a creates what it did not draw, per run; the template is refused: ~s~%" (proc-id tpl) made))
                         #f)
                  (let ((outs (filter (lambda (oq) (not (el-good? (car oq)))) (proc-outputs tpl)))
                        (rows (if (template-at-edge? tpl) '()
                                  (filter-map (lambda (e)
                                                (let ((net (template-element-net tpl e)))
                                                  (and (> net 1e-12) (not (template-unread? tpl e))
                                                       (cons (el-good e) net))))
                                              els))))
                    (append (list (proc-id tpl) (append outs rows)) (cddr tpl))))))
          *templates*)))))
(define (absorb-specs! specs)
  (for-each (lambda (s)
    (when (resource-spec-keep-in-place? s)
      (set! *stationary* (cons (resource-specification-id s) *stationary*))))
    specs)
  (for-each (lambda (su) (hash-set! *spec-units* (car su) (cdr su))) (specs->units specs)))
(define (proc-temporal? tpl)                                  ; uses a stationary container ⇒ a storage (through-time) move; else a spatial (transport) move
  (any (lambda (iq) (and (svc-good? (car iq)) (spec-stationary? (bar-spec (car iq))))) (proc-inputs tpl)))
(define (arc-scale tpl a b)                   ; storage scales by one period; transport by ROAD distance plus the climb's equivalent
  (if (proc-temporal? tpl) 1.0
      (let ((manner (tpl-manner tpl)))
        (+ (arc-net-km a b manner) (arc-climb-km a b manner)))))    ; (haversine when the table has no matrix entry — parity)
;; A transport recipe's flows split by PHYSICS: fuel/loss are spent over DISTANCE
;; (arc-scale, true km, always); driver `work` and vehicle `use` are spent over
;; the trip's TIME. arc-scale-time is the EFFECTIVE distance for those time-like
;; flows: real network time at the template's nominal pace — T/pace — so a
;; congested 10 km that takes as long as 15 km costs 15 km worth of driver-hours
;; and vehicle-hours, while still burning 10 km of fuel. The template's manner
;; and pace are its travel mode's own (*ride-info*); a generic transport
;; recipe falls back to *material-manner* + *manner-pace*. No pace, or an empty
;; table (arc-hours fallback = pace·km ⇒ T/pace = km) ⇒ exactly arc-scale: parity.
(define (tpl-mode tpl) (and=> (hash-ref *ride-info* (proc-id tpl)) car))   ; the mode a ride template instantiates, #f for a generic recipe
(define (tpl-manner tpl)
  (let ((e (tpl-mode tpl)))
    (if e (mrec-manner e) *material-manner*)))
(define (tpl-pace tpl)
  (let ((e (tpl-mode tpl)))
    (if e (mrec-pace e) (assoc-ref *manner-pace* *material-manner*))))
(define (arc-scale-time tpl a b)
  (if (proc-temporal? tpl) 1.0
      (let ((p (tpl-pace tpl)))
        (if (and p (> p 0.0))
            (/ (arc-hours a b (tpl-manner tpl) p) p)
            (km a b)))))
(define (mbq-of key) (and (not (hash-ref *mbq-relaxed* key #f))
                          (hash-ref *mbq-procs* (key-process key) #f)))
(define (mbq-floor key)                  ; the floor IGNORING relaxation — the real L
  (hash-ref *mbq-procs* (key-process key) #f))
(define (col-on? key) (or (eq? *config* 'all) (not (mbq-of key)) (member key *config*)))

;; ── WHOLE COUNTS: acts that happen a whole number of times ───────────────────
(define (whole-col? key)
  (and (hash-ref *whole-procs* (key-process key) #f) #t))
(define (declare-whole! . procs)
  "Name the acts that happen a whole number of times."
  (for-each (lambda (p) (hash-set! *whole-procs* p #t)) procs))

;; ── PROCESS FRAGILITY: a barrier on an ACT'S OWN LEVEL ───────────────────────
(define (declare-proc-frag! alist)
  "((proc-id . (lo hi alpha w)) …): the acts whose level is a fragility."
  (for-each (lambda (kv) (hash-set! *proc-frag* (car kv) (cdr kv))) alist))
;;; ─── an UNCERTAIN prohibition is a tension, not a price ───────────────────
(define (requirements key) (hash-ref *requires* key '()))
(define (req-kind r) (list-ref r 0))
(define (req-name r) (list-ref r 1))
(define (req-met? r) (list-ref r 4))
(define (unmet key) (filter (lambda (r) (eq? #f (req-met? r))) (requirements key)))

(define (why-not key) (hash-ref *why-not* key #f))
(define (why-not-tally)
  "((reason . count) …) — what stopped the columns that are not here."
  (let ((t (make-hash-table)))
    (hash-for-each (lambda (k v) (hash-set! t (car v) (+ 1 (hash-ref t (car v) 0)))) *why-not*)
    (sort (hash-map->list cons t) (lambda (a b) (> (cdr a) (cdr b))))))

;;; The two tables as WIRE, for a reader that has never heard of a column.
;;;
;;; A column key is this module's private spelling (`p|<proc>|<place>@<t>`), and
;;; publishing it would make every consumer learn to take it apart — so the
;;; decode lives HERE, beside the one place that builds it. What goes out are
;;; the three facts a calendar event already carries: its process, its place,
;;; its period. A caller joins on what it has.
;;;
;;; Plain process columns only (three fields). A ride is `p|ride.w.mode|a|b` —
;;; four fields, two cells, a different thing — and is left out rather than
;;; misread as an act standing at one place.
(define (requirements->wire)
  "((process place period why needs) …) for every column that recorded what it needs."
  (filter-map
   (lambda (k)
     (let ((kt (key-terms k)))
       (and (assq-ref kt 'process) (not (assq-ref kt 'arc))
            (let ((cell (assq-ref kt 'cell)))
              `((process . ,(assq-ref kt 'process))
                (place   . ,(place-of cell))
                (period  . ,(period-of cell))
                ;; THE JOIN, and the reason it cannot be ambiguous. A commitment
                ;; takes its own `when` from (car (period-span t)) — the very
                ;; call below — so a reader matches process, place and begin by
                ;; EQUALITY on three values that came from one source. Not
                ;; containment, which would need a rule about instants landing on
                ;; a boundary; not (process place) alone, which repeats once per
                ;; period. And the triple IS the column key, so exactly one row
                ;; can answer.
                (begin   . ,(car (period-span (period-of cell))))
                (until   . ,(cdr (period-span (period-of cell))))
                ;; present only when the column is NOT there, and then it is the
                ;; reason — the card asks "why can I not" of the same row it
                ;; asks "what does this need" of
                (why     . ,(let ((w (why-not k)))
                              (and w `((reason . ,(car w)) (detail . ,(cdr w))))))
                (needs   . ,(map (lambda (r)
                                   `((kind . ,(req-kind r))
                                     (name . ,(req-name r))
                                     (qty  . ,(list-ref r 2))
                                     (unit . ,(list-ref r 3))
                                     ;; #t | #f | unknown — never a bare absence
                                     (met  . ,(req-met? r))))
                                 (requirements k))))))))
   (hash-map->list (lambda (k v) k) *requires*)))

(define (legal-frag-forms idx cols)
  "One frag per column the legal layer marked: tip − that column's own level."
  (filter-map
   (lambda (kv)
     (let ((i (hash-ref idx (car kv))))
       (and i (mk-frag (frag-tip (cdr kv)) (list (cons i -1.0)) (frag-w (cdr kv))))))
   (hash-map->list cons *legal-frag*)))

;;; The decoration widened to FOUR values without breaking a producer that gives
;;; three: the frag profile is optional information, and #f — no tension — is the
;;; honest reading of a decorate that does not know about them.
(define (legal-decorate-of proc cell)
  (call-with-values (lambda () (*legal-decorate* proc cell))
    (case-lambda
      ((p c s)     (values p c s #f '()))
      ((p c s f)   (values p c s f '()))
      ((p c s f b) (values p c s f b)))))

(define (proc-frag-forms idx cols)
  "One frag per (declared act, period): tip − Σ of the act's columns in that period."
  ;; COLS grouped by process ONCE: *proc-frag*'s declarations are usually a
  ;; handful, but each used to re-scan every column in COLS to find its own —
  ;; O(declarations × columns) for what one grouping pass makes O(columns).
  (let ((by-process (let ((h (make-hash-table)))
                       (for-each (lambda (c)
                                   (unless (key-arc (col-key c))
                                     (let ((pid (key-process (col-key c))))
                                       (hash-set! h pid (cons c (hash-ref h pid '()))))))
                                 cols)
                       h)))
    (append-map
     (lambda (kv)
       (let* ((pid (car kv)) (profile (cdr kv))
              (by-t (make-hash-table)))
         (for-each (lambda (c)
                     (let ((t (period-of (col-cell c))))
                       (hash-set! by-t t (cons (cons (hash-ref idx (col-key c)) -1.0)
                                               (hash-ref by-t t '())))))
                   (hash-ref by-process pid '()))
         (hash-map->list (lambda (t coeffs) (mk-frag (frag-tip profile) coeffs (frag-w profile)))
                         by-t)))
     (hash-map->list cons *proc-frag*))))

(define (col-bound key) (hash-ref *col-bounds* key '(#f . #f)))
(define (with-col-bounds! alist)
  (hash-clear! *col-bounds*)
  (for-each (lambda (kv) (hash-set! *col-bounds* (car kv) (cdr kv))) alist))

;; ── A DECIDED COUNT IS NOT A VARIABLE ────────────────────────────────────────
(define (col-fixed key) (hash-ref *col-fixed* key #f))
(define (with-col-fixed! alist)
  (hash-clear! *col-fixed*)
  (for-each (lambda (kv) (hash-set! *col-fixed* (car kv) (cdr kv))) alist))
;; κ-weighted labour of the columns that left. Their work is still done, so it
;; still counts — dropping it would make a node with a decided act look cheaper
;; than the same node with it relaxed, and the search would chase the artefact.
(define *fixed-labour* 0.0)

;; worker w's cell (place@period) in period t, or #f — the SAME person across time
;; is its per-period *workers* entries sharing an id; skill membership gates supply,
;; the competence gate (below) bounds how much of it is actually deliverable.
;; Indexed once per *workers* identity (same cache-by-identity shape as
;; template-index above): worker-cell is called once per (trainable, period)
;; pair across skill-dyn-columns/fold-training-into-bundles!/skill-dyn-forms,
;; each call a fresh O(workers) `find` otherwise.
(define %worker-cell-index (list #f #f))      ; (the *workers* it was read off, (w . t) → cell)
(define (worker-cell-index)
  (unless (eq? (car %worker-cell-index) *workers*)
    (let ((h (make-hash-table)))
      (for-each (lambda (x) (hash-set! h (cons (car x) (period-of (caddr x))) (caddr x))) *workers*)
      (set! %worker-cell-index (list *workers* h))))
  (cadr %worker-cell-index))
(define (worker-cell w t) (hash-ref (worker-cell-index) (cons w t) #f))
(define (Tkey w d t) (string-append "T|" w "|" d "@" (number->string t)))
(define (skill-dyn-specs)                     ; (spec w skill from mentor) for each declared trainable with a spec
  (filter-map (lambda (tr) (let ((sp (skill-spec (cadr tr)))) (and sp (cons sp tr)))) *trainable*))
;; new COLUMNS: training activities only.  A training column consumes the MENTOR's
;; hours of the skill (it competes in the Lab|skill balance); its EFFECT — raising
;; the trainee's future competence — is carried by the gate forms below.  No L
;; state variable is materialised: competence is substituted out as a decayed sum
;; over the training/practice history, which keeps every variable strictly interior
;; (an explicit L_0 ≤ endowment=0 would pin L_0 against its own x ≥ 0 barrier).
(define (skill-dyn-columns)
  (append-map (lambda (st)
    (let ((sp (car st)) (w (cadr st)) (d (caddr st)) (from (cadddr st)) (mentor (list-ref st 4)))
      (filter-map (lambda (t)
        (and (>= t from) (member (+ t (sk-lag sp)) *periods*)
             (let ((c (worker-cell w t)))
               (and c (list (Tkey w d t) (list (cons (lab-good mentor c) (- (sk-teacher sp)))) 0.0 c)))))
        *periods*)))
    (skill-dyn-specs)))
;; fold each training column into its worker's HOURS BUNDLE (coeff = trainee-hrs per
;; unit), so working the skill and being trained draw on ONE time budget — and so
;; training falls under the same EMP equal-burden and free-time accounting as work.
;; Same (w . t) index shape as worker-cell above, over *supplier-bundles*: the
;; bundle object itself is cached (mutated in place below via set-car!, so a
;; cached reference stays valid across that mutation), rebuilt only when
;; *supplier-bundles*'s own identity changes.
(define %supplier-bundle-index (list #f #f))
(define (supplier-bundle-index)
  (unless (eq? (car %supplier-bundle-index) *supplier-bundles*)
    (let ((h (make-hash-table)))
      (for-each (lambda (bd) (hash-set! h (cons (car bd) (period-of (caddr bd))) bd)) *supplier-bundles*)
      (set! %supplier-bundle-index (list *supplier-bundles* h))))
  (cadr %supplier-bundle-index))
(define (fold-training-into-bundles!)
  (for-each
   (lambda (st)
     (let ((sp (car st)) (w (cadr st)) (d (caddr st)) (from (cadddr st)))
       (for-each
        (lambda (t)
          (when (and (>= t from) (member (+ t (sk-lag sp)) *periods*) (worker-cell w t))
            (let ((b (hash-ref (supplier-bundle-index) (cons w t) #f)))            ; bundle = (id hours home entries)
              (when b
                (set-car! (cdddr b)
                          (cons (list (Tkey w d t) (worker-cell w t) (sk-trainee sp))
                                (cadddr b)))))))
        *periods*)))
   (skill-dyn-specs)))
;; new FORMS: per period, the deliver-≤-competence gate.  (The trainee-TIME budget —
;; working the skill and being trained sharing the person's hours — is folded into
;; the worker bundle above, so it rides the same hour cap, EMP, and free-time term.)
;; Competence available AT period t is
;;   C_t = (1−decay)·C_{t−1} + regen·practice_{t−1} + yield·train_{t−lag},  C_p0 = endowment,
;; carried as a running (const . Σ coeff·var) and inlined into each gate.  Returns
;; (extra-forms . ()).
(define (skill-dyn-forms idx cols)
  (let ((forms '()))
    (define (I k) (hash-ref idx k #f))
    (define (prac-of w d t) (let ((c (worker-cell w t))) (and c (I (string-append "w|" w "|" d "|" c)))))
    (define (refresh-of w d t) (let ((c (worker-cell w t))) (and c (I (string-append "wr|" w "|" d "|" c)))))   ; dedicated refresher hours
    (for-each (lambda (st)
      (let* ((sp (car st)) (w (cadr st)) (d (caddr st)) (from (cadddr st))
             (ret (- 1.0 (sk-decay sp))) (yld (sk-yield sp)) (rgn (sk-regen sp)) (lag (sk-lag sp)))
        (let loop ((ps (sort *periods* <)) (Cc (or (competence-p0 w d) (sk-endow sp))) (Cx '()))    ; competence = Cc + Σ Cx·x, at period (car ps); the record's figure when it stands, else the endowment
          (when (pair? ps)
            (let* ((t (car ps)) (prac (prac-of w d t)) (rfr (refresh-of w d t)))
              (when prac                                                    ; deliver ≤ competence: C_t − practice_t ≥ 0
                (set! forms (cons (mk-bar Cc (cons (cons prac -1.0) Cx)) forms)))
              (let* ((Cc2 (* ret Cc))                                       ; advance C to the next period
                     (Cx2 (map (lambda (ic) (cons (car ic) (* ret (cdr ic)))) Cx))   ; (1−decay)·C_t
                     (Cx2 (if prac (cons (cons prac rgn) Cx2) Cx2))         ; + regen·practice_t  (incidental, on-the-job)
                     (Cx2 (if rfr (cons (cons rfr (sk-refresh sp)) Cx2) Cx2)) ; + refresh·refresher_t  (dedicated upkeep, no output)
                     (Ts (I (Tkey w d (- (+ t 1) lag))))                    ; + yield·train graduating next period
                     (Cx2 (if (and Ts (>= (- (+ t 1) lag) from)) (cons (cons Ts yld) Cx2) Cx2)))
                (loop (cdr ps) Cc2 Cx2)))))))
      (skill-dyn-specs))
    (cons forms '())))

;; A mover is a PERSON when it declares work-skills, else a piece of CARGO. The thing
;; relocated is the person's presence (Pres|id) or, for cargo, the good itself (id). A
;; person starts at a base and supplies labour where present (gated below); cargo is
;; picked up wherever it exists. Both ride the same MODES — and cargo, having no "walk"
;; skill, can only take a vehicle (exactly the accessibility case, generalised).
;; ── THE MEANS IS A MOVER (the worker-is-a-rider rule, for things) ────────────
;; A durable can travel too — a tractor, a projector, a mobile clinic — and when
;; it does, WHERE it stands each period is a decision the plan makes, exactly as
;; a rider's presence is. So a mobile means is a THIRD kind of mover beside a
;; person and a piece of cargo: it has a PRESENCE (init 1 where it is held,
;; carried by stays, relocated by rides), and what it supplies where present is
;; its SERVICE — the per-period `Svc|spec` its holding renders — through supply
;; columns gated by presence, precisely as a rider's labour is gated. Nothing
;; else changes: the same ride templates, the same arcs, the same budget (a
;; period spent riding is a period not serving).
;;
;;   mover  = (id base skills hours [kind])
;;   person   skills = the work-skills it supplies; presence Pres|id; labour columns w|…
;;   means    skills = (Svc|spec); presence Pres|id; service columns mv|…; kind 'means
;;   cargo    skills = (); the good itself rides, no presence, no gate
;;
;; A mover's rides are WHOLE: a person is in one place, a machine is in one
;; place, so `ride.<id>.<mode>` compiles as a whole-count act and the discrete
;; layer decides the placement on its tree, with the certificate that licenses
;; it (see PRESENCE IS DECIDED, above). Cargo rides stay rates: twenty doses
;; hauled is a quantity, and a quantity divides.
(define (mover-kind rd)
  (cond ((and (> (length rd) 4) (eq? (list-ref rd 4) 'means)) 'means)
        ((pair? (caddr rd)) 'person)
        (else 'cargo)))
(define (mover-presence? rd) (and (memq (mover-kind rd) '(person means)) #t))
(define (mover-supply-prefix rd) (if (eq? (mover-kind rd) 'means) "mv|" "w|"))
(define (mover-supplies rd)              ; what the mover renders where it stands: a person their skills, a means its services (a travel tag is no supply)
  (if (eq? (mover-kind rd) 'means) (filter svc-good? (caddr rd)) (caddr rd)))
(define (mover-supply-key rd skill c) (string-append (mover-supply-prefix rd) (car rd) "|" skill "|" c))
(define (mover-supply-good rd skill c) (if (svc-good? skill) (lg skill c) (lab-good skill c)))   ; a means supplies the service good itself; a person the labour pool
(define (rider-good rd) (if (mover-presence? rd) (pres-good (car rd)) (car rd)))   ; presence (person, means) or the cargo good
;; A ride is JUST A TRANSPORT RECIPE — so we BUILD one (pickup/dropoff the mover's good,
;; `use` the mode's vehicle, `work` its driver) and run it through the canonical
;; compile-recipe; the EXISTING arc-transport tiling then relocates it over arcs. ONE
;; relocation primitive for persons and cargo alike, no hand-replicated template shape.
;; Walking names NO driver, so it is SELF-PROPELLED: no Lab is consumed — the rider's own
;; transit time (charged in rider-forms' budget) is what moves them. Quantities are per-km
;; (vehicle service, driver hours); arc-transport scales them by distance.
(define (mover-ride-flow id action spec rq eff proc-in proc-out)
  (make-recipe-flow #:id id #:action action #:resource-conforms-to spec #:resource-quantity (and rq (make-measure rq %count-unit)) #:effort-quantity (and eff (make-measure eff %effort-unit))
                    #:recipe-input-of proc-in #:recipe-output-of proc-out))
;; Re-home one of the mode recipe's flows under THIS rider's process id. The
;; pickup/dropoff pair swaps the generic mover spec for the rider's own good
;; (Pres|id, or the cargo itself); every other flow keeps its spec and its
;; per-km measures as the recipe states them.
(define (mode-flow->ride-flow f pid g)
  (let ((action (recipe-flow-action f)))
    (make-recipe-flow #:id (string-append pid "." (recipe-flow-id f)) #:action action
                      #:resource-conforms-to (if (relocating-action? action) g (recipe-flow-resource-conforms-to f)) #:resource-quantity (recipe-flow-resource-quantity f) #:effort-quantity (recipe-flow-effort-quantity f)
                      #:recipe-input-of (and (recipe-flow-recipe-input-of f) pid) #:recipe-output-of (and (recipe-flow-recipe-output-of f) pid))))
(define (mover-ride-templates)
  (append-map (lambda (rd)
    (let ((g (rider-good rd)))
      (filter-map (lambda (e)
        (and (mode-ok? e rd)
             (let ((pid (string-append "ride." (car rd) "." (mrec-name e))))
               (hash-set! *ride-info* pid (cons e (car rd)))
               (car (compile-recipe
                     (list (make-recipe-process #:id pid #:name (string-append "Ride " (car rd) " by " (mrec-name e))
                                                ;; a person or a means rides whole; cargo rides by the quantity
                                                #:process-classified-as (if (mover-presence? rd) '("whole-count") '())))
                     ;; the mover's own work is the rider's transit time — charged to
                     ;; their own budget (rider-forms), never drawn from the pooled Lab
                     (map (lambda (f) (mode-flow->ride-flow f pid g))
                          (delq (mrec-self e) (mrec-flows e))))))))
        *mode-recipes*)))
    *riders*))
;; STORAGE IS TRANSPORT THROUGH TIME. A `store` recipe holds `good` from one period to the next by
;; `use`ing a WAREHOUSE (Svc, capacity) and losing `spoil` of the good per period — the loss is a
;; CONSUME of the good, sized by the recipe, exactly parallel to wear (a consume of a durable's
;; condition). It is an ORDINARY recipe — no temporal mark: the engine tiles it over a time arc purely
;; because its warehouse is STATIONARY (a warehouse doesn't move). The solver composes from it like any
;; recipe; the good then persists via this recipe, not via *storable*.
(define* (store-recipe good #:key (warehouse "warehouse") (spoil 0.0) (id #f))
  (unless (spec-stationary? warehouse) (set! *stationary* (cons warehouse *stationary*)))   ; a storage container is stationary, by its nature
  (let* ((pid (or id (string-append "store." good)))
         (flows (append
                 (list (mover-ride-flow (string-append pid ".pu") 'pickup  good 1.0 #f pid #f)
                       (mover-ride-flow (string-append pid ".do") 'dropoff good 1.0 #f #f pid)
                       (mover-ride-flow (string-append pid ".wh") 'use warehouse 1.0 1.0 pid #f))           ; the WAREHOUSE, used (its onhand caps how much fits)
                 (if (> spoil 0.0)                                                                          ; SPOILAGE = consume the lost fraction of the good, per period
                     (list (mover-ride-flow (string-append pid ".loss") 'consume good spoil #f pid #f)) '()))))
    (car (compile-recipe (list (rp pid (string-append "Store " good))) flows))))
;; new COLUMNS for riders: just the Lab|skill SUPPLY at every cell (presence-gated below) +
;; presence init at base. The RIDES are templates (above) tiled by arc-transport; staying is
;; storage of the presence good (the move/storage loop). No bespoke ride or stay columns.
(define (rider-columns)
  (let ((cols '()) (t0 (car (sort *periods* <))))
    (for-each (lambda (rd)
      (let* ((w (car rd)) (base (cadr rd)) (skills (mover-supplies rd)) (g (rider-good rd)))
        (when (and (mover-presence? rd) base) (hash-set! *init* (lg g (cell base t0)) 1.0))   ; a person or a means starts at base; cargo is picked up where it is
        (for-each (lambda (skill)                                                    ; (persons, means) supply available at every cell, gated by presence
          (for-each (lambda (c)
            (set! cols (cons (list (mover-supply-key rd skill c) (list (cons (mover-supply-good rd skill c) 1.0)) 0.0 c) cols))
            (when (and (eq? (mover-kind rd) 'person) (skill-refreshes? skill))     ; a dedicated self-maintenance channel: pure hours, NO output good
              (set! cols (cons (list (string-append "wr|" w "|" skill "|" c) '() 0.0 c) cols))))
            *cells*))
          skills)))
      *riders*)
    cols))
;; Where each presence good is touched: the columns that carry Pres|w@c, read off
;; the column list in ONE pass. → hash, located presence good → ((col . coeff) …)
;; newest first (read through presence-touches, in column order). A column's
;; FIRST flow on a good is its coefficient there. Every reader of "who moves a
;; presence" (the gate, the departures, the placement report) asks this index, so
;; a crowd of R movers over C columns reads the columns once, not R × cells times.
(define (presence-index cols)
  (let ((want (make-hash-table)) (by (make-hash-table)))
    (for-each (lambda (rd)
                (when (mover-presence? rd)
                  (for-each (lambda (c) (hash-set! want (lg (rider-good rd) c) #t)) *cells*)))
              *riders*)
    (for-each (lambda (col)
                (for-each (lambda (fc)
                            (when (hash-ref want (car fc) #f)
                              (let ((l (hash-ref by (car fc) '())))
                                (unless (and (pair? l) (eq? (caar l) col))
                                  (hash-set! by (car fc) (cons (cons col (cdr fc)) l))))))
                          (col-flows col)))
              cols)
    by))
(define (presence-touches pidx g c) (reverse (hash-ref pidx (lg g c) '())))
;; the cells of each period, in cell order — read once, asked per mover × period
(define (cells-by-period)
  (let ((h (make-hash-table)))
    (for-each (lambda (c) (let ((t (period-of c))) (hash-set! h t (cons c (hash-ref h t '())))))
              (reverse *cells*))
    h))
;; new FORMS for riders: the presence GATE (supply ≤ hours·presence@c, per skill×cell)
;; and the per-period BUDGET (Σ supply + transit·rides ≤ hours; transit is per-mode).
;; Presence@c = init@c + Σ ride/stay flows on Pres|w@c; its ≥ 0 balance is auto (a good).
(define (rider-forms idx cols)
  (let ((forms '()) (lab '())
        (rev-idx (let ((h (make-hash-table))) (hash-for-each (lambda (k j) (hash-set! h j k)) idx) h))
        (pidx (presence-index cols))
        (cells-of (cells-by-period)))
    (define (I k) (hash-ref idx k #f))
    (define (skill-col-keys rd skill c)  ; a mover's supply columns for (skill,cell): supply + a person's optional refresher channel
      (cons (mover-supply-key rd skill c)
            (if (and (eq? (mover-kind rd) 'person) (skill-refreshes? skill))
                (list (string-append "wr|" (car rd) "|" skill "|" c)) '())))
    (define (pres-coeffs w c)                                                       ; ride+stay columns' coeffs on presence@c
      (filter-map (lambda (cc) (and (I (col-key (car cc))) (cons (I (col-key (car cc))) (cdr cc))))
                  (presence-touches pidx (pres-good w) c)))
    ;; PRESENCE DURING A BAND. The stay into the next band is a move through time
    ;; (−1 here, +1 there), and it happens at the band's END: a person who is at a
    ;; cell all day and still there tomorrow is fully present today. So what the
    ;; gate reads — and what "somewhere" counts — is the level BEFORE that
    ;; stay-out: init, stays-in, arrivals, less departures. The good's own
    ;; balance keeps the stock honest (a stay-out never exceeds what is there).
    (define (pres-during-coeffs w c)
      (filter (lambda (ic)
                (let ((key (hash-ref rev-idx (car ic) #f)))
                  (not (and key (< (cdr ic) 0.0) (equal? (key-prefix key) "m")))))   ; drop this cell's stay-out
              (pres-coeffs w c)))
    ;; ONE MOVE PER BAND, FROM WHERE THE BAND FOUND YOU. A presence is a unit good,
    ;; and its balance is NET: within one band a ride out and a ride back cancel,
    ;; so the relaxation may circulate a person or a machine any number of times
    ;; between two cells at once — free when transit carries no κ, and a flat
    ;; direction the barrier wanders along until a cut against it lands the
    ;; phase-I nowhere. What is physically true is that a mover LEAVES a cell only
    ;; from the presence it had when the band began: what it started with, what
    ;; stayed into it, and what arrived from an EARLIER band. So the departures
    ;; from a cell are bounded by that — a longer journey spans bands (the band
    ;; dial), a two-hop day is two bands. With rides whole this makes each move
    ;; a 0|1 choice, which is the shape the tree decides.
    (define (pres-before-coeffs w c)          ; (idx . coeff) of what stands at c BEFORE this band's departures
      (let ((t (period-of c)))
        (filter-map (lambda (ic)
                      (let* ((key (hash-ref rev-idx (car ic) #f)) (kt (and key (key-terms key))))
                        (and kt (> (cdr ic) 0.0)                                    ; an arrival or a stay-in…
                             (or (not (ride-key? kt))                               ; a stay: from the band before
                                 (and (assq-ref kt 'arc) (< (assq-ref kt 'period) t)))   ; a ride landing from an earlier band
                             ic)))
                    (pres-coeffs w c))))
    (define (departure-coeffs w c)             ; (idx . coeff<0) of this band's rides OUT of c
      (filter (lambda (ic)
                (let* ((key (hash-ref rev-idx (car ic) #f)) (kt (and key (key-terms key))))
                  (and kt (< (cdr ic) 0.0) (ride-key? kt)
                       (equal? (assq-ref kt 'cell) c))))
              (pres-coeffs w c)))
    ;; every rider's rides, read off the columns once: (rider . departure period)
    ;; → ((idx . transit-hours) …) newest first, arc-transport columns only
    (define rides-by
      (let ((h (make-hash-table)))
        (for-each (lambda (col)
          (let ((kt (key-terms (car col))))
            (when (assq-ref kt 'arc)
              (let ((i (hash-ref *ride-info* (assq-ref kt 'process))))             ; (mode . rider)
                (when i
                  (let* ((a (car (assq-ref kt 'arc))) (b (cdr (assq-ref kt 'arc)))
                         (k (cons (cdr i) (period-of a))))
                    (hash-set! h k (cons (cons (I (car col))
                                               (arc-hours a b (mrec-manner (car i)) (mrec-pace (car i))))
                                         (hash-ref h k '())))))))))
          cols)
        h))
    (define (rides-in w t)                                                          ; (idx . transit-hours) for w's rides departing period t (arc-transport cols)
      (reverse (hash-ref rides-by (cons w t) '())))
    (for-each (lambda (rd)
      (let ((w (car rd)) (skills (mover-supplies rd)))
        (when (mover-presence? rd)
          (for-each (lambda (c)                                                     ; DEPARTURES ≤ presence before the band's moves
            (let ((out (departure-coeffs w c)))
              (when (pair? out)
                (set! forms (cons (mk-bar (hash-ref *init* (lg (pres-good w) c) 0.0)
                                          (append out (pres-before-coeffs w c)))
                                  forms)))))
            *cells*)
          ;; A MOVER IS ALWAYS SOMEWHERE. A good's balance is an inequality — a
          ;; surplus may simply lapse — so a presence that arrived and did not
          ;; stay would evaporate, and a fraction of one could stay on. A person
          ;; or a machine does neither: summed over the cells of a band its
          ;; presence is at least one, and with rides whole that pins the stays.
          ;; The FIRST band holds this by construction (its presence is the init,
          ;; and a ride only moves it), so the wall is stated from the second band
          ;; on — stated at the first it would be an identity, a wall with no
          ;; interior, which no barrier can hold.
          (let ((t0 (car (sort *periods* <))))
            (for-each (lambda (t)
              (unless (= t t0)
                (let ((cT (hash-ref cells-of t '())))
                  (set! forms (cons (mk-bar (- (fold + 0.0 (map (lambda (c) (hash-ref *init* (lg (pres-good w) c) 0.0)) cT)) 1.0)
                                            (merge-coeffs (append-map (lambda (c) (pres-during-coeffs w c)) cT)))
                                    forms)))))
              *periods*)))
        (for-each (lambda (skill)                                                   ; GATE: supply ≤ hours·presence@c
          (for-each (lambda (c)
            (for-each (lambda (key)                                                  ; supply + refresher both gated by presence
              (let ((s (I key)) (hours (rider-hours rd (period-of c) skill)))
                (when s
                  (set! forms (cons (mk-bar (* hours (hash-ref *init* (lg (pres-good w) c) 0.0))
                                            (cons (cons s -1.0)
                                                  (map (lambda (ic) (cons (car ic) (* hours (cdr ic)))) (pres-during-coeffs w c)))) forms)))))
              (skill-col-keys rd skill c)))
            *cells*))
          skills)
        (for-each (lambda (t)                                                       ; BUDGET: Σ supply + transit·rides ≤ hours
          (let* ((cT (hash-ref cells-of t '()))
                 (hours (rider-hours rd t))
                 (sup-of (lambda (skill)                                             ; supply + refresher both draw on the one hour budget
                           (append-map (lambda (c)
                             (filter-map (lambda (key) (let ((s (I key))) (and s (cons s -1.0)))) (skill-col-keys rd skill c))) cT)))
                 ;; a person has ONE budget across everything they do. A means renders
                 ;; each thing it bears out of that thing's own hours — the saw in a
                 ;; carried toolbox is not the toolbox's time — so what it bears is
                 ;; budgeted apart, and the ride is time off the means' own service.
                 (borne (if (eq? (mover-kind rd) 'means)
                            (filter (lambda (skill) (hash-ref *borne-hours* (cons w skill) #f)) skills)
                            '()))
                 (sup (append-map sup-of (filter (lambda (skill) (not (member skill borne))) skills)))
                 (rds (map (lambda (ik) (cons (car ik) (- (cdr ik)))) (rides-in w t))))
            (for-each (lambda (skill)
                        (let ((sk (sup-of skill)))
                          (when (pair? sk) (set! forms (cons (mk-bar (rider-hours rd t skill) sk) forms)))))
                      borne)
            (when (pair? sup)
              (set! forms (cons (mk-bar hours (append sup rds)) forms))
              ;; a PERSON's hours are labour: work and transit both count toward κ
              ;; (free time). A MEANS is need-priced — its service carries no κ.
              (when (eq? (mover-kind rd) 'person)
                (set! lab (append (map (lambda (p) (cons (car p) (- (cdr p)))) sup)   ; work = labour (free-time numerator)
                                  (map (lambda (p) (cons (car p) (- (cdr p)))) rds)   ; transit = real transport time (a committed-labour cost, not "faux frais")
                                  lab))))))
          *periods*)))
      *riders*)
    (cons forms lab)))

;; a COLUMN = (key flows labour labour-cell), flows = alist (located-good . coeff)
(define (col-key c) (car c)) (define (col-flows c) (cadr c))
(define (col-labour c) (caddr c)) (define (col-cell c) (cadddr c))

;; A column key's TERMS are read by `key-terms` (located.scm), the one place a
;; key is split.
(define (ride-key? kt)                   ; an arc-transport column born of a ride template — the instantiator's own record (*ride-info*), never the id's spelling
  (let ((pr (assq-ref kt 'process))) (and pr (hash-ref *ride-info* pr) #t)))

(define (column-terms c)
  "The key's terms, plus what the flows say: the skills it draws (Lab|), the
   means it uses (Svc|), the goods it delivers (positive flows, bare spec), the
   period's window, the act's tags, and the scope path."
  (let ((kt (key-terms (col-key c))) (skills '()) (means '()) (delivers '()) (consumes '()))
    (for-each (lambda (fc)
                (let ((g (car fc)) (q (cdr fc)))
                  (cond ((lab-good? g)
                         (let ((s (bar-field g 1))) (unless (member s skills) (set! skills (cons s skills)))))
                        ((svc-good? g)
                         (let ((s (svc-spec (good-spec g)))) (unless (member s means) (set! means (cons s means)))))
                        ((> q 0.0) (set! delivers (cons (cons (good-spec g) q) delivers)))
                        ((< q 0.0) (set! consumes (cons (cons (good-spec g) (- q)) consumes))))))
              (col-flows c))
    (let* ((t (assq-ref kt 'period))
           (span (and t (period-span t)))
           (window (and span (car span) (cdr span) span))
           (tags (let ((p (assq-ref kt 'process))) (and p (hash-ref *proc-tags* p #f)))))
      (append kt
              (if (pair? skills) (list (cons 'skill (reverse skills))) '())
              (if (pair? means) (list (cons 'means (reverse means))) '())
              (if (pair? delivers) (list (cons 'delivers (reverse delivers))) '())
              (if (pair? consumes) (list (cons 'consumes (reverse consumes))) '())
              (if window (list (cons 'window window)) '())
              (if tags (list (cons 'tag tags)) '())
              (if *scope-path* (list (cons 'scope *scope-path*)) '())))))
(define (build-terms cols) (list->vector (map column-terms cols)))
(define (column-labour-hours c)
  (if (> (col-labour c) 0.0)
      (col-labour c)
      (fold (lambda (fc a) (if (and (lab-good? (car fc)) (< (cdr fc) 0.0)) (- a (cdr fc)) a)) 0.0 (col-flows c))))

;; ── the voice field's inputs for THIS solve ─────────────────────────────────
;; the LEVEL a solved plan leaves of a located good — its starting on-hand plus the
;; net every column delivers to it (produce − consume ± carry) at the solution x.
;; The one reader for "how much of g stands at this cell": what a reserve's tab
;; shows, what a floor was held above.
(define (good-level g cols x idx)
  (fold (lambda (c acc)
          (let ((e (assoc g (col-flows c))))
            (if e (+ acc (* (cdr e) (col-value x idx (col-key c)))) acc)))   ; a decided column reads its fact
        (hash-ref *init* g 0.0) cols))
;; WHERE each mover stands: its presence at every cell, read off the solve. With
;; rides whole this is a placement — one cell per period; under the bare
;; relaxation it is the fractional presence the discrete layer exists to decide.
;; → ((mover-id . ((cell . presence) …)) …), cells with presence > 0 only.
(define (mover-placement cols x idx)
  (define pidx (presence-index cols))
  (define (presence-during g c)              ; the level before the band's stay-out (rider-forms: pres-during-coeffs)
    (fold (lambda (cc acc)
            (let ((col (car cc)) (q (cdr cc)))
              (if (not (and (< q 0.0) (equal? (key-prefix (col-key col)) "m")))
                  (+ acc (* q (col-value x idx (col-key col))))
                  acc)))
          (hash-ref *init* (lg g c) 0.0) (presence-touches pidx g c)))
  (filter-map
   (lambda (rd)
     (and (mover-presence? rd)
          (cons (car rd)
                (filter-map (lambda (c)
                              (let ((p (presence-during (rider-good rd) c)))
                                (and (> p 1e-6) (cons c p))))
                            *cells*))))
   *riders*))
;; a spec is RAW if NO template outputs it; a raw is AVAILABLE at a cell iff it has
;; a positive cap there (its stock / eco bound). A production column whose raw input
;; is unavailable is impossible — don't generate it (cleaner than a degenerate 0-cap
;; barrier). Goods (produced/shipped-in) inputs need no cap. Demos cap every raw at
;; every cell they grow in, so this drops nothing there; ingest, which only caps a
;; raw where it physically exists, gets the right tiling for free.
;; ── arc-aware raw availability ───────────────────────────────────────────────
;; A "raw" (a spec no template outputs) is AVAILABLE at a cell iff it can be
;; SOURCED there: it has a positive cap (stock / eco bound) at that cell, OR it is
;; storable/movable and some positive-cap cell REACHES it along its own carry arcs
;; (storage = one period forward; transport = a neighbour place). A spec with NO
;; cap entry anywhere is unbounded (the demos' uncapped = unlimited convention).
;; This replaces the old "absent cap = unlimited per cell" rule and the no-phantom
;; 0-cap sweep at once: absence-of-source is now DERIVED from the arc graph, so a
;; stocked storable raw correctly feeds production at the cells its storage reaches,
;; while a raw with no reachable source drops the column — no phantom, and no
;; degenerate 0-slack barrier.
(define (raw-source-cap spec c)               ; a raw's REMAINING draw headroom at cell c: a hard *cap*, a per-period fragility tip, or a horizon BUDGET tip — net of the observed prior. All are sources (when headroom > 0).
  (or (hash-ref *cap* (lg spec c) #f)
      (let ((fc (hash-ref *frag-cap* (lg spec c) #f))) (and fc (frag-headroom fc (lg spec c))))
      (let ((fs (hash-ref *frag-spec* spec #f)))     (and fs (frag-headroom fs (lg spec c))))   ; a per-spec rate boundary makes the spec available at every cell it's drawn
      (let ((bg (hash-ref *frag-budget* spec #f))) (and bg (frag-headroom bg spec)))))   ; a cumulative budget makes its spec available at every cell; the total is bound by one aggregate frag form
(define (cap-anywhere? spec)
  (any (lambda (c) (raw-source-cap spec c)) *cells*))
(define (raw-reach-set spec storables movers)
  ;; cells from which raw `spec` can be sourced (a hash set), or 'all if uncapped.
  (let ((any-cap #f) (sources '()))
    (for-each (lambda (c)
                (let ((cap (raw-source-cap spec c)))
                  (when cap (set! any-cap #t) (when (> cap 0.0) (set! sources (cons c sources))))))
              *cells*)
    ;; capped NOWHERE reads as 'all — a boundless ambient flow, the same reading
    ;; `spec-skips-balance?` gives. It is TOO GENEROUS and we know it: a storable
    ;; spec with no stock, no producer and no barrier in THIS program still gets
    ;; carry columns, and a carry of a good that can never exist is an
    ;; empty-interior pin (m ≥ 0 against −m ≥ 0) that no strictly interior point
    ;; satisfies — so every solve exits ~2.3e-4 outside it and certifies
    ;; infeasible however well stocked (measured: 53 such carries on the
    ;; household dish program).
    ;;
    ;; Narrowing it to the `spec-skips-balance?` trio plus standing stock has
    ;; been tried TWICE and reverted twice, and the second attempt is the
    ;; informative one. It broke `means-consensus-test` — the consensus split
    ;; reproducing the monolith — and one cause was found and fixed: a means
    ;; declared as a SUPPLIER BUNDLE was invisible to `svc-held?`, so the same
    ;; economy answered differently depending on how its pool was written down
    ;; (see `refresh-svc-known!`). With that fixed the narrowing STILL breaks the
    ;; parity, so at least one more source of "the scope has this" is missing
    ;; from the same index. Finding it is the work; the generous reading stands
    ;; until then, and the ~2.3e-4 blemish with it — a cosmetic cost against a
    ;; correctness one. docs/planning/federation/labour-assignment-and-rotation.md §9.
    (if (not any-cap) 'all
        (let ((reach (make-hash-table))
              (st? (and (hash-ref storables spec #f) #t))
              (mv? (and (hash-ref movers spec #f) #t)))
          ;; a cell whose STATED headroom is zero is closed to this raw however
          ;; a carry might reach it: its cap wall there reads `0 − Σ a·x ≥ 0`,
          ;; and a column drawing against it has exactly one feasible value —
          ;; an empty-interior pin. Measured: the farm's land and labour at the
          ;; 17:00–24:00 band (hours 0) carried "freely" across the day's bands,
          ;; tiled three grow columns there, and left phase-I no interior.
          (define (open? b) (let ((cb (raw-source-cap spec b))) (not (and cb (<= cb 0.0)))))
          (for-each (lambda (c) (hash-set! reach c #t)) sources)
          (let loop ((wl sources))
            (if (null? wl) reach
                (let ((a (car wl)) (more '()))
                  (let ((b (temporal-target a)))                         ; storage carries forward one period —
                    (when (and b (not (hash-ref reach b #f)) (open? b)   ; and a day's own bands carry freely
                               (or st? (same-day-bands? (period-of a) (period-of b))))
                      (hash-set! reach b #t) (set! more (cons b more))))
                  (when mv?                                              ; transport carries to neighbour places
                    (for-each (lambda (b) (unless (or (hash-ref reach b #f) (not (open? b))) (hash-set! reach b #t) (set! more (cons b more))))
                              (spatial-targets a)))
                  (loop (append more (cdr wl))))))))))
;; ── the lead: a chain's earliest completion within its band (§3.1, §3.4) ─────
;; One question, three routes, stated once at top level. A good is available at
;; hour zero when it is a raw, standing stock, a declared-movable (logistics
;; abstracted by choice), or persisted from an earlier band — by *storable* or
;; by a HOLD recipe, containment's own time-arc. Otherwise its lead is the
;; least over its producers: a SAME-CELL process at its own chain lead, or a
;; SPATIAL carrier at the origin's lead plus the trip's hours (a hold is never
;; a route between places). A run outlasting the band makes no within-band
;; claim — run-spanning has its own machinery — and a column whose lead
;; exceeds its band is not generated, the raw-availability idiom: the plan
;; reroutes through storage instead of claiming a chain's first unit before it
;; can exist. MADE/STORABLES/MOVERS as build-columns assembles them.
;; WHO MAKES A GOOD, AND WHO CARRIES IT, read once per set of templates. The lead is
;; asked at every column and of every input, and a crowd's eats make the templates
;; many: scanned afresh at each question the walk is the crowd squared.
(define %template-index (list #f #f #f #f))    ; (the templates it was read off, good → same-cell makers, good → spatial carriers, proc-id → template)
(define (template-index)
  (unless (eq? (car %template-index) *templates*)
    (let ((makers (make-hash-table)) (carriers (make-hash-table)) (by-id (make-hash-table)))
      (for-each (lambda (tp)
                  (hash-set! by-id (proc-id tp) tp)
                  (cond ((null? (proc-relocated tp))
                         (for-each (lambda (g) (hash-set! makers g (cons tp (hash-ref makers g '()))))
                                   (delete-duplicates (map car (proc-outputs tp)))))
                        ((not (proc-temporal? tp))
                         (for-each (lambda (g) (hash-set! carriers g (cons tp (hash-ref carriers g '()))))
                                   (delete-duplicates (proc-relocated tp))))))
                (reverse *templates*))           ; consing turns the order round: the templates' own comes back
      (set! %template-index (list *templates* makers carriers by-id))))
  %template-index)
;; proc-id → template: a `find` over *templates* at several call sites (each
;; inside its own loop over columns/needs) made them O(columns × templates) or
;; O(needs × templates); this shares template-index's own cache-by-identity.
(define (template-by-id pid) (hash-ref (cadddr (template-index)) pid #f))
(define (band-lead tpl c made held movers)
  "Hours after C's band start at which ONE run of TPL can be complete."
  (let* ((t (period-of c)) (H (period-hours t))
         (makers (cadr (template-index))) (carrying (caddr (template-index))))
    (letrec ((chain-lead
                                ;; earliest availability of G at cell CL, hours after
                                ;; band start — through same-cell producers, AND
                                ;; through the arcs that carry it: a good hauled in
                                ;; arrives its origin's own lead plus the trip later,
                                ;; so a chain routed through transport can no longer
                                ;; compress into a band it cannot fit (§3.4's hole:
                                ;; grow 6 h + haul + bake 2 h claimed one 6 h band)
                                (lambda (g cl visiting)
                                  (cond ((not (hash-ref made g #f)) 0.0)                 ; raw — present at band start
                                        ((> (hash-ref *init* (lg g cl) 0.0) 0.0) 0.0)    ; stock standing here resets the chain
                                        ;; …or from an EARLIER band: HELD is what
                                        ;; persists through time — a *storable*
                                        ;; declaration, a rider's presence, or a HOLD
                                        ;; recipe (the pickup/dropoff pair through a
                                        ;; keep-in-place container) — the one set
                                        ;; build-columns derives for the reach walk too
                                        ((and (> t 0) (hash-ref held g #f)) 0.0)
                                        ((hash-ref movers g #f) 0.0)                      ; a declared-movable good free-carries: logistics abstracted by choice
                                        ((> (length visiting) 64) 0.0)                    ; depth backstop
                                        (else
                                         (let* ((local (filter-map
                                                        (lambda (tp)                        ; same-cell producers (template-index)
                                                          (and (not (member (proc-id tp) visiting))
                                                               (lead tp cl (cons (proc-id tp) visiting))))
                                                        (hash-ref makers g '())))
                                                ;; SPATIAL carriers only: a HOLD moves
                                                ;; its cargo through time and offers no
                                                ;; route between places
                                                (carriers (filter (lambda (tp) (not (member (proc-id tp) visiting)))
                                                                  (hash-ref carrying g '())))
                                                (hauled (append-map
                                                         (lambda (tp)
                                                           (filter-map
                                                            (lambda (a)     ; each origin one edge away
                                                              (let ((key (string-append "@" (place-of a))))
                                                                (and (not (member key visiting))
                                                                     (+ (chain-lead g a (cons key (cons (proc-id tp) visiting)))
                                                                        ;; the trip in HOURS — the same reading
                                                                        ;; arrival-cell makes of the same arc
                                                                        (arc-hours a cl (tpl-manner tp) (or (tpl-pace tp) 0.0))))))
                                                            (spatial-targets cl)))   ; edges are symmetric one hop out
                                                         carriers))
                                                (ls (append local hauled)))
                                           (if (null? ls) 0.0 (apply min ls)))))))
                               (lead
                                (lambda (tp cl visiting)
                                  (let ((d (proc-duration tp)))
                                    (if (> d H) 0.0                                       ; run-spanning: no within-band claim
                                        (+ d (fold (lambda (iq m) (max m (chain-lead (car iq) cl visiting)))
                                                   0.0 (proc-inputs tp))))))))
      (lead tpl c (list (proc-id tpl))))))

(define (band-lead-fits? tpl c made held movers)
  "Does TPL's chain fit C's band? Vacuously yes for a span-less period — an
   abstract period states no length to exceed."
  (let ((t (period-of c)))
    (or (not (car (period-span t)))
        (<= (band-lead tpl c made held movers)
            (+ (period-hours t) 1e-9)))))

;; ── the silence that opts a chain out of coherence, reported ────────────────
;; Within-band coherence (§3.1) holds exactly as far as recipes state run
;; lengths: a process with no has-duration makes no temporal claim, and a
;; CHAIN of such processes balances inside one band like it always did — the
;; §3.2 residual, by contract rather than by accident. This is the report that
;; makes the contract visible at authoring time, in the use-unit-lint register:
;; the processes that consume another process's output while stating no run
;; length, i.e. exactly the links a lead-time prune cannot see. A report,
;; never an error — an aggregate sector's recipe legitimately states none.
(define (chain-duration-gaps)
  "((process-id chained-input-spec …) …) for every template that consumes a
   produced spec while stating no has-duration. Empty when every chained step
   states its length — the condition §3.1's pruning needs to cover the tree."
  (let ((made (produced-spec-set)))
    (filter-map (lambda (tpl)
                  (and (= (proc-duration tpl) 0.0)
                       (let ((chained (filter-map (lambda (iq) (and (hash-ref made (car iq) #f) (car iq)))
                                                  (proc-inputs tpl))))
                         (and (pair? chained) (cons (proc-id tpl) chained)))))
                *templates*)))

;; ── a run longer than its band is a journey through TIME (§3.1's residual) ──
;; The guarantee table already states the rule for space: "a journey lands in
;; the period it can earliest reach, and does not land at all past the horizon."
;; A run that outlasts its band is the same object pointed at time — inputs
;; board at the origin band, the output disembarks when the run is over — so it
;; compiles exactly as transport does, one column with flows at two cells, and
;; the arrival walk is arrival-period's reading over the declared spans.
;; Coverage is what the walk passes through: the bands the run occupies, and
;; for how many hours in each — which is where a `use`d means is genuinely
;; held, so its Svc draw lands in EVERY covered band rather than the first.
;; The run is read from its band's start; a same-band upstream chain would
;; push the true start later, which the lead already prunes for band-fitting
;; steps — the sub-band remainder is the stated approximation.
(define (run-coverage c d)                  ; ((period . hours covered) …), walking declared spans
  (let loop ((t (period-of c)) (left d) (acc '()))
    (if (or (not (memv t *periods*)) (<= left 1e-9)) (reverse acc)
        (let ((h (min left (period-hours t))))
          (loop (+ t 1) (- left h) (cons (cons t h) acc))))))
(define (run-arrival-cell c d)              ; where the run's output lands — #f past the horizon
  ;; arrival-period IS this question — "the earliest period whose spans,
  ;; accumulated from the start, cover these hours" — asked of a run instead
  ;; of a trip. One walker, both journeys.
  (and=> (arrival-period (period-of c) d)
         (lambda (t) (cell (place-of c) t))))
(define (build-columns)
  (let* ((cols '())
         (made (produced-spec-set))                  ; specs some template outputs ⇒ GOODS (rest are raw)
         (pres-goods (if (riders?) (filter-map (lambda (rd) (and (pair? (caddr rd)) (pres-good (car rd)))) *riders*) '()))
         ;; the three persistence classes, each a LIST (the carry loop walks
         ;; the union) beside a HASH-SET (the probes): the reserve recipes
         ;; hold one nutrient|pid per person, so these run O(crowd), and the
         ;; probes below — once per template × cell × input in the lead walk —
         ;; read membership in O(1) where a `member` scan and a pairwise dedup
         ;; each read the crowd once per member.
         (storables-list (append *storable* pres-goods))                                       ; temporal = storable (incl. presence)
         (storables (let ((h (make-hash-table)))
                      (for-each (lambda (s) (hash-set! h s #t)) storables-list)
                      h))
         (movers-list (append *movable* (append-map proc-moved *templates*)))                  ; spatial = movable or `move`d
         (movers (let ((h (make-hash-table)))
                   (for-each (lambda (s) (hash-set! h s #t)) movers-list)
                   h))
         ;; what PERSISTS through time: a storable, a rider's presence, or a
         ;; good a HOLD recipe relocates through a keep-in-place container
         ;; (proc-temporal?). The reach walk and the lead read this one set;
         ;; the free carry columns read `storables` alone — a held good persists
         ;; through the hold's own column, at the hold's own cost, never through
         ;; the carry a *storable* declaration lays for free.
         (held (let ((h (make-hash-table)))
                 (hash-for-each (lambda (k v) (hash-set! h k #t)) storables)
                 (for-each (lambda (tp)
                             (when (proc-temporal? tp)
                               (for-each (lambda (s) (hash-set! h s #t)) (proc-relocated tp))))
                           *templates*)
                 h))
         (reach (let ((tbl (make-hash-table)))              ; raw spec -> reachable-cell hash | 'all (memoised this build)
                  (lambda (spec) (or (hash-ref tbl spec #f)
                                     (let ((r (raw-reach-set spec held movers))) (hash-set! tbl spec r) r)))))
         (raw-here? (lambda (spec c) (let ((r (reach spec))) (if (eq? r 'all) #t (and (hash-ref r c #f) #t)))))
         (raw-available? (lambda (tpl c)
           (every (lambda (iq) (or (hash-ref made (car iq) #f)            ; a good — made or shipped in
                                   (mover-service? (car iq))              ; a service a mover carries — wherever it may stand
                                   (raw-here? (car iq) c)))               ; a raw — stocked here, or storage/transport reaches here
                  (proc-inputs tpl))))
         ;; within-band lead (§3.1/§3.4): the statement lives at `band-lead`,
         ;; top level beside the arrival machinery; only the once-per-build
         ;; guard stays here — a tree with no stated durations makes no claim
         (any-durated? (any (lambda (tp) (> (proc-duration tp) 0.0)) *templates*))
         (lead-fits?
          (lambda (tpl c)
            (or (not any-durated?)
                (band-lead-fits? tpl c made held movers)))))
    (for-each (lambda (tpl)                              ; ordinary templates tile per CELL; TRANSPORT templates (incl. mover rides) per ARC
      (if (pair? (proc-relocated tpl))
          ;; TRANSPORT: pickup@a → dropoff@b of the SAME good — an arc activity that RELOCATES it,
          ;; carrying the recipe's own costs (driver labour, fuel) scaled by distance, with retention.
          (for-each (lambda (a)
            (let ((sklabs (proc-skill-labours-of tpl))
                  (targets (if (proc-temporal? tpl)                               ; only the REAL edges from a: time-forward (storage) or neighbour places (transport)
                               (let ((b (temporal-target a))) (if b (list b) '()))
                               (spatial-targets a))))
              (for-each (lambda (b)
                (when (and (col-on? (string-append "p|" (proc-id tpl) "|" a "|" b))
                           ;; …and the recipe's own inputs must be sourceable at the
                           ;; ORIGIN, exactly as a production column requires at its
                           ;; cell. A haul draws its vehicle, its fuel and its
                           ;; driver where the trip STARTS, so a van stocked at A
                           ;; cannot pull a trip out of B. Without this the arc path
                           ;; skipped the check the per-cell path has always made,
                           ;; and a durable's service was available wherever an arc
                           ;; began — measured: one van at A hauled just as much out
                           ;; of B, which is the same van in two places at once.
                           (raw-available? tpl a)
                           (or (not (skilled?)) (null? sklabs)                     ; the DRIVER must be present at the origin to drive the trip
                               (every (lambda (sl) (skilled-worker-at? (car sl) a)) sklabs)))
                  (let* ((d  (arc-scale tpl a b))                                  ; km for transport, 1 period for storage — DISTANCE-spent flows (fuel, loss)
                         (dt (arc-scale-time tpl a b))                             ; effective km (network T/pace) — TIME-spent flows (driver work, vehicle use)
                         ;; WHERE THE CARGO LANDS. Storage already arrives next
                         ;; period (its target IS t+1); a journey arrives when the
                         ;; journey is over, which is `arrival-cell`. B stays the
                         ;; costing target — the distance and the pace are a→b
                         ;; whatever period the arrival falls in.
                         (dest (if (proc-temporal? tpl) b (arrival-cell tpl a b)))
                         (reloc (and dest (append-map (lambda (g) (list (cons (lg g a) -1.0) (cons (lg g dest) 1.0))) (proc-relocated tpl))))   ; LOSSLESS relocation; any loss is a recipe `consume` of the good (sized by the recipe — like wear)
                         (ins   (map (lambda (iq) (cons (lg (car iq) a)            ; Svc (use, a duration) rides the time scale; consumes ride distance
                                                        (- (* (cdr iq)
                                                              (svc-hours-factor (car iq) tpl (period-of a))
                                                              (if (svc-good? (car iq)) dt d)))))
                                     (proc-inputs tpl)))
                         (drv   (if (skilled?)                                     ; DRIVER routed through work→Lab: consume Lab|skill@origin (×time scale)
                                    (filter-map (lambda (sl) (and (> (cdr sl) 0.0) (cons (lab-good (car sl) a) (- (* (cdr sl) dt))))) sklabs)
                                    '())))
                    ;; a trip that reaches past the horizon does not land, so there
                    ;; is no column for it — the good would arrive after the plan ends
                    (when reloc
                      (set! cols (cons (list (string-append "p|" (proc-id tpl) "|" a "|" b)
                                             (append drv reloc ins) (if (skilled?) 0.0 (* (proc-labour tpl) dt)) a) cols))))))
                targets)))
            *cells*)
          ;; ordinary production: each template per cell
          (for-each (lambda (c)
            (call-with-values (lambda () (legal-decorate-of (proc-id tpl) c))
             (lambda (legal-prune? legal-cost legal-skills legal-frag legal-bill) ; the bill, as planner inputs (§6)
              (let* ((key (string-append "p|" (proc-id tpl) "|" c)) (lab (proc-labour tpl))
                     ;; an uncertain prohibition rides THIS column
                     (_lf (when legal-frag (hash-set! *legal-frag* key legal-frag)))
                     (sklabs (proc-skill-labours-of tpl))      ; ((skill . hours) …) it needs
                     (t (period-of c)) (d (proc-duration tpl))
                     ;; a run outlasting its band is a journey through time:
                     ;; the output lands at the arrival band, or not at all
                     (spanning? (and (car (period-span t)) (> d (period-hours t))))
                     (dest (if spanning? (run-arrival-cell c d) c))
                     ;; WHY, not just whether. Seven facts decide a column, and
                     ;; collapsing them into one boolean destroys the answer at
                     ;; exactly the moment it is worth most: a plan then shows no
                     ;; work here, and nothing can say whether that is because
                     ;; there is none to do, the material is out of reach, the run
                     ;; would outlast the day, or you lack the licence. Absence
                     ;; reads as permission — the failure this planner keeps
                     ;; producing, one layer in.
                     ;;
                     ;; The order is the cheap-first order the `and` already had,
                     ;; so nothing extra is computed for a column that runs; a
                     ;; column that does not costs one hash-set!.
                     (missing (lambda (want at?) (remove at? want)))
                     ;; what this act needs HERE — the recipe's own flows, then
                     ;; what the law asks of it at this cell. Recorded whether or
                     ;; not the column runs: a requirement is a fact about the
                     ;; work, not a complaint about the worker.
                     (raw-ok? (raw-available? tpl c))
                     ;; …AS A BOOLEAN. skilled-worker-at? answers with the worker
                     ;; record it found, and a requirement's met? is #t / #f /
                     ;; 'unknown by contract — a truthy record read as 'unknown,
                     ;; so a competence that WAS held displayed as not known.
                     (skill-ok? (lambda (sk) (and (or (not (skilled?)) (skilled-worker-at? sk c)) #t)))
                     (unheld-names (or (assq-ref legal-bill 'unheld) '()))
                     ;; ONE door for every legal kind: names in, a predicate
                     ;; saying whether each is held, requirements out.
                     ;;
                     ;; The NAMES are an argument and not a lookup because the
                     ;; two sources are not interchangeable. legal-decorate is a
                     ;; case-lambda over 3, 4 and 5 values: `legal-skills` is the
                     ;; THIRD, so every arity carries it, while the bill is the
                     ;; FIFTH. Reading obtain-person from the bill drops the
                     ;; licence requirement of every 3- and 4-value decoration —
                     ;; the older arities go quiet rather than wrong, which is
                     ;; the failure that is hardest to see.
                     (law-req (lambda (k names held?)
                                (map (lambda (nm) (list k nm #f #f (held? nm))) names)))
                     (bill (lambda (k) (or (assq-ref legal-bill k) '())))
                     (reqs
                      (append
                       ;; a `use` flow compiles to a Svc| consume (compile.scm),
                       ;; so the two arrive here as one list and the prefix is
                       ;; the only thing that still tells them apart. Reading it
                       ;; back is what lets this say `use spec-reefer-van` —
                       ;; a means OCCUPIED for a while — rather than report the
                       ;; van as a material the act eats.
                       (map (lambda (iq)
                              (let ((g (car iq)))
                                (if (svc-good? g)
                                    (list 'use (substring g 4) (cdr iq) #f raw-ok?)
                                    (list 'consume g (cdr iq) #f raw-ok?))))
                            (proc-inputs tpl))
                       (map (lambda (sl) (list 'work (car sl) (cdr sl) %effort-unit
                                               (skill-ok? (car sl))))
                            sklabs)
                       (law-req 'obtain-entity (bill 'obtain-entity)
                                (lambda (nm) (not (member nm unheld-names))))
                       (law-req 'obtain-person legal-skills skill-ok?)
                       ;; nothing observes a fee paid or a notice sent, so these
                       ;; are 'unknown and `missing` must never read them as #f
                       (law-req 'pay  (bill 'pay)  (lambda (nm) 'unknown))
                       (law-req 'tell (bill 'tell) (lambda (nm) 'unknown))))
                     (_rq (hash-set! *requires* key reqs))
                     ;; ONE notion of missing, the same one `unmet` exports: met?
                     ;; is #f. Not 'unknown — a fee nobody has checked is not a
                     ;; reason to say the act cannot happen.
                     (missing (lambda (k)
                                (filter (lambda (r) (and (eq? k (req-kind r))
                                                         (eq? #f (req-met? r))))
                                        reqs)))
                     (why
                      (cond ((not (col-on? key))          '(branch-off))
                            ((not dest)                   '(outlasts-horizon))
                            ((not raw-ok?)                '(raw-unreachable))
                            ((not (lead-fits? tpl c))     '(lead-does-not-fit))
                            (legal-prune?                 '(forbidden))
                            ;; …and from here the answer is a FILTER over what the
                            ;; act needs, not a second derivation of it. The kinds
                            ;; whose absence has earned a name of its own, in the
                            ;; order a person would ask them; a kind gaining a
                            ;; met? source later joins by adding its row.
                            (else
                             (let next ((ks '((obtain-person . licence-not-held)
                                              (work          . skill-absent))))
                               (if (null? ks) #f
                                   (let ((m (missing (caar ks))))
                                     (if (pair? m)
                                         (cons (cdar ks) (map req-name m))
                                         (next (cdr ks)))))))))
                     (_wn (when why (hash-set! *why-not* key why)))
                     (runnable (not why)))
                (when runnable
                  ;; a SPANNING run's draws are held ACROSS its coverage — the vat is
                  ;; occupied and the ferment turned in every band the run passes
                  ;; through. ONE spreader serves every draw kind: GOOD-AT names the
                  ;; located good in a band, SHARE says how much of the run's total
                  ;; falls there (pro rata by covered hours, or the hours themselves
                  ;; for an untimed hold). Empty coverage only when not spanning.
                  (let* ((cov (if spanning? (run-coverage c d) '()))
                         (spread (lambda (good-at total share)
                                   (map (lambda (ph)
                                          (cons (good-at (cell (place-of c) (car ph)))
                                                (- (* total (share ph)))))
                                        cov)))
                         (pro-rata (lambda (ph) (/ (cdr ph) d)))
                         (base (append (map (lambda (oq) (cons (lg (car oq) dest) (* (cdr oq) (*flow-period-factor* 'produce (proc-id tpl) (car oq) t (place-of dest))))) (proc-outputs tpl))
                                       (append-map
                                        (lambda (iq)
                                          (let ((g (car iq)))
                                            (if (and spanning? (svc-good? g))
                                                ;; a timed draw is unit-hours for the whole run and
                                                ;; splits pro rata; an untimed one holds the unit for
                                                ;; each band's covered hours
                                                (spread (lambda (cl) (lg g cl))
                                                        (* (cdr iq) (*flow-period-factor* 'consume (proc-id tpl) g t (place-of c)))
                                                        (if (member (substring g 4) (proc-timed-svc tpl)) pro-rata cdr))
                                                (list (cons (lg g c) (- (* (cdr iq) (svc-hours-factor g tpl t) (*flow-period-factor* 'consume (proc-id tpl) g t (place-of c)))))))))
                                        (proc-inputs tpl))))
                         (flows (if (skilled?)
                                    (fold (lambda (sl acc)
                                            (cond ((not (> (cdr sl) 0.0)) acc)
                                                  (spanning?
                                                   (append (spread (lambda (cl) (lab-good (car sl) cl))
                                                                   (* (cdr sl) (*flow-period-factor* 'work (proc-id tpl) (car sl) t (place-of c)))
                                                                   pro-rata)
                                                           acc))
                                                  (else (cons (cons (lab-good (car sl) c)
                                                                    (- (* (cdr sl) (*flow-period-factor* 'work (proc-id tpl) (car sl) t (place-of c)))))
                                                              acc))))
                                          base sklabs)
                                    base)))
                    ;; the `pay` levy rides the labour coefficient — a labour-hour rent on this cell
                    (set! cols (cons (list key flows (+ (if (skilled?) 0.0 lab) legal-cost) c) cols))))))))
            *cells*)))
      (append *templates* (if (riders?) (mover-ride-templates) '())))   ; mover rides are transport templates, tiled by the SAME arc machinery
    (set! *supplier-bundles* '())                        ; fresh per build — workers AND means cons their bundles below
    (when (workers?)                                     ; worker SUPPLY columns: per skill × reachable cell, shared hours
      (for-each (lambda (w)
        (let* ((id (car w)) (skills (cadr w)) (home (caddr w)) (hours (cadddr w)) (entries '()))
          (for-each (lambda (skill)                      ; supply at HOME (free) and any cell within commute range
            (for-each (lambda (c)
              (when (and (worker-reaches? w c)           ; same period, ≤ *commute-km*
                         (*willing?* id skill c))        ; … and willing here (default #t ⇒ unchanged)
                (let ((hrs (+ 1.0 (arc-hours home c *commute-manner* *tau-commute*)))   ; hrs-coeff: 1 worked hr + transport hours to get there
                      (key (string-append "w|" id "|" skill "|" c)))
                  (set! entries (cons (list key c hrs) entries))
                  (set! cols (cons (list key (list (cons (lab-good skill c) 1.0)) 0.0 c) cols))
                  (when (skill-refreshes? skill)         ; dedicated self-maintenance channel: same hour budget, NO output good
                    (let ((rk (string-append "wr|" id "|" skill "|" c)))
                      (set! entries (cons (list rk c hrs) entries))
                      (set! cols (cons (list rk '() 0.0 c) cols)))))))
              *cells*))
            skills)
          (set! *supplier-bundles* (cons (list id hours home entries #t) *supplier-bundles*))))  ; labour? = #t: one time budget across all draws (work + training), earns EMP + κ free-time
        *workers*))
    (when (pair? *resource-suppliers*)                   ; MEANS supply columns: one shared capacity spread across the spec's conformance closure — and across the CELLS it reaches
      (for-each (lambda (r)
        (let* ((id (car r)) (specs (cadr r)) (cap (cadddr r)) (durable? (list-ref r 4))
               ;; A supplier reaches a SET of cells. One cell is the ordinary case
               ;; (a means sits somewhere and serves from there); several is a pool
               ;; that is fungible across them — the seats of a line spendable at
               ;; any of its stations, or a budget spendable in any period of its
               ;; window. The bar below spans whatever the entries cover, so both
               ;; are the same construction and neither needs its own table.
               (cells (let ((c (caddr r))) (if (pair? c) c (list c))))
               (entries '()))
          (for-each (lambda (cl)
            (for-each (lambda (s)                        ; a draw on each spec the closure covers (held spec + everything it substitutes for)
              (let ((key  (string-append "r|" id "|" s "|" cl))
                    (good (if durable? (lg (svc-good s) cl) (lg s cl))))  ; durable ⇒ per-period Svc|; stock ⇒ bare consumable
                (set! entries (cons (list key cl 1.0) entries))
                (set! cols (cons (list key (list (cons good 1.0)) 0.0 cl) cols))))
              specs))
            cells)
          ;; ONE bar over every entry — so a pool spanning cells is bounded in
          ;; TOTAL rather than per cell, which is what makes it a shared pool
          ;; rather than that much capacity repeated at each one.
          (set! *supplier-bundles* (cons (list id cap (car cells) entries #f) *supplier-bundles*))))  ; labour? = #f: one capacity across the closure, no EMP, no κ (means are need-priced)
        *resource-suppliers*))
    ;; LOSSLESS free carry — reuses the outer pres-goods/storables/movers (identical). Simple persistence
    ;; (presence, condition, durable stock) and the bare τ·km / hold move. Iterates each cell's REAL edges
    ;; only (neighbour places, time-forward), so O(cells·degree) not O(cells²). MATERIAL LOSS is not a rail
    ;; here: spoilage/transit-loss is a `consume` on a STORE/HAUL recipe, sized by the recipe (like wear).
    ;; INTRA-DAY carry: under clock refinement every STOCK carries freely
    ;; between the bands of one day (same-day-bands?), storable or not — the
    ;; day is one day, and what it holds at 09:00 it holds at noon. A FLOW
    ;; good stays out: Svc|/Lab| are hours OF a band (svc-hours-factor), and
    ;; the afternoon's oven-hours do not exist in the evening — carrying them
    ;; let work run in bands its means never stood in
    ;; (time-verification-test §4 pins the exclusion). Cross-day carry stays
    ;; the storable's own, at the hold cost.
    (let* ((intra? (refined-day-present?))
           ;; an EXCESS over ambient (a form whose composition carries the leaf "heat",
           ;; knowledge/thermal.scm) relaxes within the day as surely as a band's
           ;; oven-hours end with the band, so it never carries for free either: it
           ;; persists only through the store-shaped recipe that names its enclosure
           ;; and its loss (docs/observation/readings-are-counts.md §1.5 fact 6)
           (excess-good? (lambda (g) (let ((row (hash-ref *composition* g #f)))
                                       (and row (let ((h (assoc-ref row "heat"))) (and h (not (zero? h))))))))
           (flow-good? (lambda (g) (or (svc-good? g) (lab-good? g) (excess-good? g))))
           (all-specs (if intra?
                          (delete-duplicates
                           (remove flow-good?
                                   (append (hash-map->list (lambda (k v) k) made)
                                           (filter-map key-good
                                                       (append (hash-map->list (lambda (k v) k) *init*)
                                                               (hash-map->list (lambda (k v) k) *cap*))))))
                          '())))
    (for-each (lambda (g)
      (let ((mv? (hash-ref movers g #f)) (st? (hash-ref storables g #f)))
        (for-each (lambda (a)
         (when (or (hash-ref made g #f) (raw-here? g a))  ; carry a RAW only from a cell it can be SOURCED at — no phantom carry of stock that isn't there (produced goods are balanced everywhere ⇒ always ok)
          (when mv?                                    ; SPATIAL transport, along network edges (either direction)
            (for-each (lambda (b)
              (set! cols (cons (list (string-append "m|" g "|" a "|" b)
                                     (list (cons (lg g a) -1.0) (cons (lg g b) 1.0))
                                     (arc-hours a b *material-manner* *tau*) a) cols)))
              (spatial-targets a)))
          (let ((b (temporal-target a)))             ; TEMPORAL: storage one period forward (free for a person),
            (when (and b                             ; or the free carry between two bands of ONE day
                       (or st? (and intra? (same-day-bands? (period-of a) (period-of b)))))
              (set! cols (cons (list (string-append "m|" g "|" a "|" b)
                                     (list (cons (lg g a) -1.0) (cons (lg g b) 1.0))
                                     (if (or (member g pres-goods)   ; a day's own bands: no hold charged
                                             (same-day-bands? (period-of a) (period-of b)))
                                         0.0 *hold*)
                                     a) cols))))))
          *cells*)))
      ;; the union, deduplicated by hash in one pass (first-occurrence order):
      ;; per-person goods ride in it, so the distinct set runs O(crowd) too
      (let ((seen (make-hash-table)) (acc '()))
        (for-each (lambda (g) (unless (hash-ref seen g #f) (hash-set! seen g #t) (set! acc (cons g acc))))
                  (append movers-list storables-list all-specs))
        (reverse acc))))
    ;; THE CERTIFICATES: one bundle per citizen with a stated balance, its
    ;; entries every column drawing their credit|aid (the claim columns, at
    ;; the good's crystallized SNLT per unit), its budget their drawable hours
    ;; — the same bar a worker's hours or a pool's capacity is: Σ price·claim ≤
    ;; balance across every cell. labour? #f: no EMP, no κ — a certificate is
    ;; not time. A balance of zero lays the bar at zero; a citizen with no
    ;; entry (no claim column) lays none.
    ;; ONE pass over the columns lays every certificate's entries: each
    ;; column's credit draws bucket by their good as the columns stream by,
    ;; and each certificate reads its own bucket, in the columns' own order.
    ;; Certificates and columns both run O(crowd), so a scan of every column
    ;; per certificate — a key split per flow inside it — read the crowd once
    ;; per member; the buckets read it once.
    (when (pair? *certificates*)
      (let ((bucket (make-hash-table)))
        (for-each
         (lambda (col)
           (let ((draws '()))                             ; ((good . draw) …) of THIS column
             (for-each (lambda (fc)
                         (when (< (cdr fc) 0.0)
                           (let ((g (good-spec (car fc))))
                             (when (credit-good? g)
                               (let ((p (assoc g draws)))
                                 (if p (set-cdr! p (- (cdr p) (cdr fc)))
                                     (set! draws (cons (cons g (- (cdr fc))) draws))))))))
                       (cadr col))
             (for-each (lambda (gd)
                         (hash-set! bucket (car gd)
                                    (cons (list (car col) (cadddr col) (cdr gd))
                                          (hash-ref bucket (car gd) '()))))
                       draws)))
         cols)
        (for-each (lambda (cert)
                    (let* ((aid (car cert)) (hours (max 0.0 (cdr cert))) (good (credit-good aid))
                           (entries (reverse (hash-ref bucket good '()))))
                      (when (getenv "PLANNER_PD_DEBUG")
                        (format (current-error-port) "  [cert] ~a: ~a h over ~a columns ~s~%" aid hours (length entries) (map car entries)))
                      (when (pair? entries)   ; home: the first claim's cell — a bundle's home is read as a cell everywhere
                        (set! *supplier-bundles* (cons (list good hours (cadr (car entries)) entries #f) *supplier-bundles*)))))
                  *certificates*)))
    (let ((dyn (if (skill-dynamics?) (skill-dyn-columns) '()))               ; skills as producible/decaying labour-power
          (rid (if (riders?) (rider-columns) '())))                          ; mobile workers: presence supply + ride relocation
      (when (skill-dynamics?) (fold-training-into-bundles!))                  ; training draws on the person's one time budget
      (lay-budgeted-floors (prune-unreachable-draws (let ((cs (append (reverse cols) dyn rid))) (append cs (acquire-columns cs))))))))
;; WHERE A MADE GOOD CAN BE. A column that DRAWS a made good at a cell the
;; good cannot reach is no column: nothing feeds it, its only feasible
;; value is exactly 0, and the barrier has no interior beside it — the
;; empty-interior pin raw-reach-set names, laid here by "a good — made or
;; shipped in" passing every cell. A made good is present where a surviving
;; column produces or drops it or stock of it stands; it reaches onward
;; through the carries already laid. A draw anywhere else leaves, to a
;; fixpoint (a dropped producer can strand another). Found live: the crowd's
;; delivery and the day's band carries tiled at twelve districts' 00:00–09:00
;; band, where no meal can yet be, and a reproduction floor beside them was
;; refused for the pins.
;; ── A BUDGETED FLOOR (Bertsimas–Sim): a wall that survives any Γ sources lost ──
(define (col-arc c) (key-arc (col-key c)))   ; (from . to) for an arc column — a haul or a hold — else #f
(define (col-origin-place c)                 ; the PLACE a column's delivery originates at: an arc's from-cell, else its own cell
  (place-of (let ((a (col-arc c))) (if a (car a) (col-cell c)))))
(define (lay-budgeted-floors cols)
  (if (or (null? *budgeted-floors*) (not (tier-shape 'floor))) cols
      (append cols
        (append-map
         (lambda (bf)
           ;; the floor's STRETCH: a floor stated for a day the clock refined
           ;; into bands is the day's balance (exactly as *stretch-floor* reads
           ;; a bare one), so its inflows are every band's, its sources' own
           ;; supply counts to the day's last band, and the rows sit at the
           ;; stretch's representative cell. Measured live: read at the first
           ;; band alone, the wall asked the morning for a harvest nobody had
           ;; grown yet and the day starved.
           (let* ((g (*locate-key* (car bf))) (F (cadr bf)) (gamma (caddr bf))
                  (keys (stretch-of g))
                  (spec (key-spec g)) (cell (located-cell g))
                  (t (apply max (map (lambda (k) (period-of (located-cell k))) keys)))
                  (tag (lambda (kind . more) (string-append kind "|" spec (apply string-append (map (lambda (m) (string-append "|" m)) more)) "#" cell)))
                  (inflow-of (lambda (c) (fold + 0.0 (map (lambda (k) (let ((fl (assoc k (col-flows c)))) (if (and fl (> (cdr fl) 0.0)) (cdr fl) 0.0))) keys))))
                  (draws? (lambda (c) (any (lambda (k) (let ((fl (assoc k (col-flows c)))) (and fl (< (cdr fl) 0.0)))) keys)))
                  (inflows (filter (lambda (c) (and (> (inflow-of c) 0.0) (not (draws? c)))) cols))   ; a move within the day feeds and draws the stretch: not a source
                  (cells-at (lambda (d) (filter (lambda (cl) (and (equal? (place-of cl) d) (<= (period-of cl) t))) *cells*)))
                  (own-of (lambda (d)         ; g's producers at d by the floor's period — same-cell columns, never an arc
                            (filter (lambda (c)
                                      (and (not (col-arc c))
                                           (any (lambda (cl) (let ((fl (assoc (lg spec cl) (col-flows c)))) (and fl (> (cdr fl) 0.0))))
                                                (cells-at d))))
                                    cols)))
                  (stock-at (lambda (d) (fold + 0.0 (map (lambda (cl) (let ((k (lg spec cl)))
                                                                        (max 0.0 (or (hash-ref *init* k #f) (raw-source-cap spec cl) 0.0))))
                                                         (cells-at d)))))
                  ;; a SOURCE is a place with supply of its own — a producer of the
                  ;; good there by the floor's period, or stock standing there. An
                  ;; origin that only passes the good on (the ground itself, when
                  ;; yesterday's leftover carries into the day) has an own-supply
                  ;; row of 0: its y would sit between y ≤ 0 and y ≥ 0, a pin.
                  ;; Measured live: `y|meal|berlin-festival` the tightest wall at
                  ;; slack 1e-15 in every future, the solve stalled on it. What such
                  ;; an origin carries is not counted toward the budget — the
                  ;; conservative reading, since the harvest it carries came from a
                  ;; place that could itself be the one lost.
                  (sources (filter (lambda (d) (or (pair? (own-of d)) (> (stock-at d) 0.0)))
                                   (delete-duplicates (map col-origin-place inflows))))
)
             (when (null? inflows)
               (error "a budgeted floor names a good nothing feeds at its cell — it could never be held" g))
             (when (getenv "PLANNER_PD_DEBUG")
               (format (current-error-port) "  [budget] ~a ≥ ~a against any ~a of ~a source(s): ~s~%" g F gamma (length sources) sources))
             (hash-set! *init* (tag "bud") (- (hash-ref *init* (tag "bud") 0.0) F))
             (for-each
              (lambda (d)
                ;; d's stock of the good by the floor's period opens its own-supply row
                (hash-set! *init* (tag "own" d) (+ (hash-ref *init* (tag "own" d) 0.0) (stock-at d)))
                (for-each (lambda (c) (set-car! (cdr c) (cons (cons (tag "in" d) (inflow-of c)) (cadr c))))
                          (filter (lambda (c) (equal? (col-origin-place c) d)) inflows))
                (for-each (lambda (c)
                            (let ((made (fold + 0.0 (map (lambda (cl) (let ((fl (assoc (lg spec cl) (col-flows c)))) (if (and fl (> (cdr fl) 0.0)) (cdr fl) 0.0)))
                                                         (cells-at d)))))
                              (set-car! (cdr c) (cons (cons (tag "own" d) made) (cadr c)))))
                          (own-of d)))
              sources)
             (append
              (list (list (tag "z")                                  ; z: the shared cover, drawn from the budget Γ times
                          (cons (cons (tag "bud") (- gamma)) (map (lambda (d) (cons (tag "cov" d) 1.0)) sources))
                          0.0 cell))
              (append-map (lambda (d)
                            (list (list (tag "y" d)                  ; y_d: d's contribution — from d, of d's own, into the budget, under the cover
                                        (list (cons (tag "in" d) -1.0) (cons (tag "own" d) -1.0)
                                              (cons (tag "bud") 1.0) (cons (tag "cov" d) -1.0))
                                        0.0 cell)
                                  (list (tag "p" d)                  ; p_d: the per-source cover
                                        (list (cons (tag "bud") -1.0) (cons (tag "cov" d) 1.0))
                                        0.0 cell)))
                          sources))))
         *budgeted-floors*))))
(define (pin-check! name const coeffs)          ; PLANNER_PD_DEBUG: a wall no column can loosen — const ≤ 0 and only draws — pins every column it names at 0
  (when (and (getenv "PLANNER_PD_DEBUG") (<= const 0.0) (pair? coeffs)
             (any (lambda (ic) (< (cdr ic) 0.0)) coeffs)
             (not (any (lambda (ic) (> (cdr ic) 0.0)) coeffs)))
    (format (current-error-port) "  [pin] ~a const ~,3f draws ~a~%" name const (length coeffs))))
;; A WALL THE BALANCE MUST REACH: a floor took the good's on-hand below zero
;; (apply-repro-bands!), or a stretch floor stands over its day. THE reading of
;; "a floor pulls on this good", shared by the prune below (what a wall pulls
;; on is kept) and by build-located's fail-closed guard (a wall with no column
;; left is a good nothing could ever raise). A band whose wall is at zero — a
;; held need's insurance margin — asks nothing of the balance and pulls nothing.
(define (floor-pulls? g)
  (and (hash-ref *band* g #f)
       (or (< (hash-ref *init* g 0.0) 0.0)
           (> (hash-ref *stretch-floor* g 0.0) 0.0))))
;; THE GOODS A FLOOR PULLS ON, closed backward over the columns: the floored
;; goods themselves, then every good a column that OUTPUTS a pulled good
;; consumes, to the fixpoint. A column feeding a wall is a column the plan
;; must be allowed to run — and where its own input is absent, its input's
;; ≥0 balance holds it at zero and the certificate says INFEASIBLE, which is
;; the verdict the floor asked for (a possibility-tension, priced by
;; plan-dilemma). Dropped instead, the wall stands on no column and the
;; guard reads a scarcity as a modelling error. Measured: a Kiez whose
;; never-raw grain has no source lost its mill, then its eat recipes, and
;; its subsistence floors died as "no column touches" where alone-and-hungry
;; is exactly the infeasibility federated-repro-test pins.
(define (floor-pulled-set cols)
  (let ((p (make-hash-table)))
    ;; a floor over a refined day pulls on every band of the day: the wall is
    ;; the stretch's balance, the columns output at their own bands
    (hash-for-each (lambda (g _) (when (floor-pulls? g) (for-each (lambda (k) (hash-set! p k #t)) (stretch-of g)))) *band*)
    (let grow ((n (hash-count (const #t) p)))
      (for-each (lambda (c)
                  (when (any (lambda (fl) (and (> (cdr fl) 0.0) (hash-ref p (car fl) #f))) (col-flows c))
                    (for-each (lambda (fl)
                                (when (and (< (cdr fl) 0.0) (key-good (car fl)))
                                  (hash-set! p (car fl) #t)))
                              (col-flows c))))
                cols)
      (let ((m (hash-count (const #t) p)))
        (if (= m n) p (grow m))))))
;; ── A STOCK DRAWN DOWN IS FELT ───────────────────────────────────────────────
(define *stock-draw-hours* 1.0)               ; a governed dial, stated per solve (#:stock-draw-hours)

;; THE SETTINGS A SOLVE IS GIVEN, ONE WRITE: the voice field and the governed dials
;; (scope/policy.scm). Both assemblies call this after they ingest — the single
;; deterministic one in `%plan-from-records`, the robust one in `robust-assemble` —
;; because ingest resets the globals (and it stands after the globals it writes, which a
;; compiled `set!` of a module variable defined further down the file does not reach); a dial stated and unstated is left as it stands.
(define* (apply-solve-settings! #:key (voice-tau 0.0) (voice-pushes '()) (voice-hours #f) (scope-path #f)
                                      (pref-bound #f) (emp-rho #f) (kappa #f) (want-as-cap 'unstated)
                                      (stock-draw-hours #f)
                                #:allow-other-keys)
  (set! *voice-tau* voice-tau) (set! *voice-pushes* voice-pushes) (set! *voice-hours* voice-hours) (set! *scope-path* scope-path)
  (when (number? pref-bound) (set-dial! 'pref-bound pref-bound))
  (when (number? emp-rho) (set-dial! 'emp-rho emp-rho))
  (when (number? kappa) (set-dial! 'kappa kappa))
  (unless (eq? want-as-cap 'unstated) (set-dial! 'want-as-cap want-as-cap))
  (when (number? stock-draw-hours) (set-dial! 'stock-draw-hours stock-draw-hours)))
(define (stock-draw-costs cols idx)           ; → ((column-index . hours) …)
  (let ((made (make-hash-table)) (stock (make-hash-table))
        (nets (map (lambda (c)                  ; each column's NET by spec, read once
                     (let ((net (make-hash-table)))
                       (for-each (lambda (fc)
                                   (let ((sp (good-spec (car fc))))
                                     (hash-set! net sp (+ (cdr fc) (hash-ref net sp 0.0)))))
                                 (col-flows c))
                       net))
                   cols)))
    ;; MADE is read off the columns that stand, never the recipes: an acquisition
    ;; recipe the prune removed makes nothing, and the purse is drawn all the same
    ;; …and a good that comes across the scope's boundary is drawn, where it
    ;; stands in the scope, as the stock it is: the crossing makes none of it
    (for-each (lambda (c net) (unless (or (acq-col? c) (crossing-col? c))
                                (hash-for-each (lambda (sp v) (when (> v 1e-12) (hash-set! made sp #t))) net)))
              cols nets)
    ;; a standing stock is a STARTING BALANCE (*init*): what is left of it is carried.
    ;; A raw's holding (*cap*) is a period's allowance — a raw skips its balance, so
    ;; what a period leaves undrawn is gone, as a bed's empty night is — and weighs
    ;; nothing: weighed, a forest's regrowth allowance read dearer than the forest.
    (hash-for-each (lambda (g v)
                     (when (and (number? v) (> v 0.0))
                       (let ((sp (good-spec g))) (hash-set! stock sp (+ v (hash-ref stock sp 0.0))))))
                   *init*)
    (filter-map
     (lambda (c net)
       (let ((cost (hash-fold
                    (lambda (sp v a)
                      (let ((s (hash-ref stock sp 0.0)))
                        (if (and (< v 0.0) (> s 0.0)
                                 (not (or (hash-ref made sp #f) (structural-raw? sp)
                                          (svc-good? sp) (barrier-bounded? sp))))
                            (+ a (let ((price (hash-ref *stock-price* (spec-base sp) #f)))
                                   (if price (* price (- v)) (* *stock-draw-hours* (/ (- v) s)))))
                            a)))
                    0.0 net)))
         (and (> cost 1e-12) (cons (hash-ref idx (col-key c)) cost))))
     cols nets)))
(define (acq-col? c) (equal? (key-prefix (col-key c)) "acq"))
(define (crossing-col? c) (string-prefix? "p|cross-" (col-key c)))   ; engine/federation-solve.scm `crossing-recipe`
(define (acquire-price spec labour?)
  "The hours one unit of SPEC costs to bring in, by *acquire*: a selector names the
   spec, the spec without its Svc| prefix, \"labour\" for any labour row, or #t for all. #f when nothing sells it."
  (let ((bare (if (svc-good? spec) (bar-spec spec) spec)))
    (any (lambda (a)
           (let ((sel (car a)))
             (and (or (eq? sel #t)
                      (and (string? sel)
                           (or (string=? sel spec) (string=? sel bare) (and labour? (string=? sel "labour")))))
                  (cdr a))))
         *acquire*)))
(define (acquire-cost key)            ; the price of a located row: Lab|skill|cell reads its skill, spec#cell its spec
  (if (lab-good? key)
      (acquire-price (bar-field key 1) #t)
      (acquire-price (key-spec key) #f)))
(define (acquire-columns cols)
  "One zero-labour column per DRAWN located row *acquire* prices: +1 on the row.
   Under aggregate labour (no skill rows) a priced \"labour\" selector adds one
   hire column per cell instead, carrying −1 hour so the cell's cap rises."
  (if (null? *acquire*) '()
      (let ((seen (make-hash-table)) (acc '()))
        (define (add! key flows labour cell cost)
          (hash-set! *acquire-cost-of* key cost)
          (set! acc (cons (list key flows labour cell) acc)))
        (for-each (lambda (c)
                    (for-each (lambda (fl)
                                (let ((row (car fl)))
                                  (when (and (< (cdr fl) 0.0) (not (hash-ref seen row #f)))
                                    (hash-set! seen row #t)
                                    (let ((cost (acquire-cost row)))
                                      (when cost
                                        (hash-set! *acquired-keys* row #t)
                                        (add! (string-append "acq|" row) (list (cons row 1.0)) 0.0
                                              (if (lab-good? row) (bar-field row 2) (col-cell c))
                                              cost))))))
                              (col-flows c)))
                  cols)
        (unless (skilled?)
          (let ((cost (acquire-price "labour" #t)))
            (when cost
              (for-each (lambda (cl) (when (hash-ref *A* cl #f) (add! (string-append "acq|Lab|" cl) '() -1.0 cl cost)))
                        *cells*))))
        (reverse acc))))
(define (bill-net bill base)
  "BILL's rows net of the residue rows BASE (the 'none tier), by row; hours re-priced at the row's own rate."
  (filter-map (lambda (r)
                (let* ((b (assoc (car r) base))
                       (q (- (cadr r) (if b (cadr b) 0.0))))
                  (and (> q 1e-9) (list (car r) q (* q (/ (caddr r) (cadr r)))))))
              bill))
(define (acquire-bill x cols idx)
  "((bill . ((row units hours) …)) (bill-hours . total)): what the solve bought in."
  (let ((rows (filter-map (lambda (c)
                            (and (acq-col? c)
                                 (let ((v (col-value x idx (col-key c))))
                                   (and (> v 1e-6)
                                        (list (bar-spec (col-key c)) v (* v (hash-ref *acquire-cost-of* (col-key c) 0.0)))))))
                          cols)))
    `((bill . ,rows) (bill-hours . ,(fold + 0.0 (map caddr rows))))))
(define (prune-unreachable-draws cols)
  ;; MADE is read ONCE, off the unpruned world: a spec some column produces
  ;; or some stock opens is a good, and stays one however many of its
  ;; sources the prune removes. Re-reading it per pass let a good whose
  ;; every producer had been dropped read as a raw on the next pass, and
  ;; its last draws survive as pins — measured live on the farm with no
  ;; land or water in stock: holds and grows dropped band by band until
  ;; only the grows at the last band stood, on balance rows nothing fed.
  (define made0
    (let ((h (produced-spec-set)))          ; the ONE reading ingest routes stock by: a spec some template outputs or relocates is a good —
      ;; however the columns fall. Read off the columns alone, a one-period
      ;; program has no time arc, so a kept good with no stock read as a raw,
      ;; the reach set's "capped nowhere is everywhere" tiled its draws, and
      ;; their balance rows opened at 0 (Oakland's garden, live: four grows
      ;; pinned on land and water it does not have).
      (for-each (lambda (c) (unless (acq-col? c) (for-each (lambda (fl) (let ((g (and (> (cdr fl) 0.0) (key-good (car fl))))) (when g (hash-set! h g #t)))) (col-flows c)))) cols)
      (hash-for-each (lambda (k v) (let ((g (and (> v 0.0) (key-good k)))) (when g (hash-set! h g #t)))) *init*)
      (for-each (lambda (tbl) (hash-for-each (lambda (k _) (let ((g (key-good k))) (when (and g (let ((cap (raw-source-cap g (located-cell k)))) (and cap (> cap 0.0)))) (hash-set! h g #t)))) tbl))
                (list *cap* *frag-cap*))
      h))
  (define pulled (floor-pulled-set cols))   ; read once too: what a wall pulls on, over the unpruned world
  ;; A column that only MOVES what it takes — a keep, a haul, a hold — puts
  ;; out exactly the goods it draws. It sources nothing, and its dead draw
  ;; is no finding: the good it would have carried is what was missing.
  (define (carry-col? c)
    (let ((taken (filter-map (lambda (fl) (and (< (cdr fl) 0.0) (or (key-good (car fl)) (car fl)))) (col-flows c)))
          (put   (filter (lambda (fl) (> (cdr fl) 0.0)) (col-flows c))))
      (and (pair? put)
           (every (lambda (fl) (member (or (key-good (car fl)) (car fl)) taken)) put))))
  ;; RAW-LINT (PLANNER_RAW_LINT=1) reads the prune's drops in the lint's own
  ;; two words (good-index says the rest). A dropped column drew a good the
  ;; kept world feeds nowhere at its cell; the good's spec is
  ;;   STRANDED — some real column makes it at some cell, or some stock
  ;;     opens it: a carry someone meant to model is missing;
  ;;   STARVED — nothing makes it anywhere and nothing stocks it: a hole in
  ;;     the books, the fail-closed casualty the CI gate on "starved" reads.
  ;; The prune removes these columns before good-index sees them, so the
  ;; report is spoken here, over what was removed.
  (define (lint-dropped! dropped present)     ; PRESENT: the kept world's fed rows, as the last pass read them
    (when (pair? dropped)
      (let ((sourced (make-hash-table)))
        (for-each (lambda (c)
                    (unless (or (carry-col? c) (acq-col? c))
                      (for-each (lambda (fl) (let ((g (and (> (cdr fl) 0.0) (key-good (car fl))))) (when g (hash-set! sourced g #t)))) (col-flows c))))
                  cols)
        (hash-for-each (lambda (k v) (let ((g (and (> v 0.0) (key-good k)))) (when g (hash-set! sourced g #t)))) *init*)
        (for-each (lambda (tbl) (hash-for-each (lambda (k _) (let ((g (key-good k))) (when (and g (let ((cap (raw-source-cap g (located-cell k)))) (and cap (> cap 0.0)))) (hash-set! sourced g #t)))) tbl))
                  (list *cap* *frag-cap*))
        (let* ((unfed (delete-duplicates
                       (append-map (lambda (c)
                                     (if (carry-col? c) '()
                                         (filter-map (lambda (fl)
                                                       (let ((g (and (< (cdr fl) 0.0) (key-good (car fl)))))
                                                         (and g (hash-ref made0 g #f) (not (hash-ref present (car fl) #f)) g)))
                                                     (col-flows c))))
                                   dropped)
                       string=?))
               (stranded (filter (lambda (g) (hash-ref sourced g #f)) unfed))
               (starved  (filter (lambda (g) (not (hash-ref sourced g #f))) unfed)))
          (when (pair? stranded)
            (format (current-error-port)
                    "[RAW-LINT] ~a stranded spec(s) — drawn where nothing makes it and no carry reaches; the column is pruned: ~s~%"
                    (length stranded) stranded))
          (when (pair? starved)
            (format (current-error-port)
                    "[RAW-LINT] ~a starved spec(s) — consumed, no producer/stock/barrier anywhere; the column is pruned: ~s~%"
                    (length starved) starved))))))
  (define lint? (getenv "PLANNER_RAW_LINT"))
  (let loop ((cols cols) (dropped '()))
    (let ((present (make-hash-table)))
      (for-each (lambda (c)
                  (for-each (lambda (fl)
                              (when (and (> (cdr fl) 0.0) (key-good (car fl)))
                                (hash-set! present (car fl) #t)))
                            (col-flows c)))
                cols)
      ;; standing stock is present where it stands — a good's opening level
      ;; (*init*) or a consumed raw's headroom (*cap*, a fragility tip), read
      ;; through `raw-source-cap`, the SAME door the reach set reads
      (hash-for-each (lambda (k v) (when (and (> v 0.0) (key-good k)) (hash-set! present k #t))) *init*)
      (for-each (lambda (tbl)
                  (hash-for-each (lambda (k _)
                                   (let ((g (key-good k)))
                                     (when g
                                       (let ((cap (raw-source-cap g (located-cell k))))
                                         (when (and cap (> cap 0.0)) (hash-set! present k #t))))))
                                 tbl))
                (list *cap* *frag-cap*))
      (let* ((made made0)
             (kept (filter (lambda (c)
                             (or (any (lambda (fl) (and (> (cdr fl) 0.0) (hash-ref pulled (car fl) #f)))   ; feeds a wall: kept, its input's balance judges it
                                      (col-flows c))
                                 (every (lambda (fl)
                                          (or (>= (cdr fl) 0.0)
                                              (let ((g (key-good (car fl))))
                                                (or (not g) (not (hash-ref made g #f))   ; a raw: raw-reach-set's own read
                                                    (hash-ref present (car fl) #f)))))
                                        (col-flows c))))
                           cols)))
        (let ((at (and (getenv "PLANNER_PD_DEBUG") (getenv "PLANNER_COLS_AT"))))
          (when (and at (< (length kept) (length cols)))
            (let ((dropped (filter (lambda (c) (and (string-contains (col-key c) at) (not (memq c kept)))) cols)))
              (format (current-error-port) "  [prune] ~a dropped; naming ~a: ~s~%" (- (length cols) (length kept)) at
                      (map (lambda (c) (cons (col-key c) (col-flows c))) (list-head dropped (min 6 (length dropped)))))
              (format (current-error-port) "  [prune] init at ~a: ~s~%" at
                      (hash-fold (lambda (k v a) (if (string-contains k at) (cons (cons k v) a) a)) '() *init*))
              (format (current-error-port) "  [prune] cap at ~a: ~s~%" at
                      (hash-fold (lambda (k v a) (if (string-contains k at) (cons (cons k v) a) a)) '() *cap*)))))
        (if (= (length kept) (length cols))
            (begin (when lint? (lint-dropped! dropped present)) cols)
            (loop kept
                  (if lint?
                      (let ((kh (make-hash-table)))
                        (for-each (lambda (c) (hash-set! kh (col-key c) #t)) kept)
                        (append (filter (lambda (c) (not (hash-ref kh (col-key c) #f))) cols) dropped))
                      dropped)))))))
(define (good-keys cols)                     ; a good is PRODUCED if some column has a + coeff on it
  (let ((made (make-hash-table)) (all (make-hash-table)))
    (for-each (lambda (c) (for-each (lambda (fc)
                (hash-set! all (car fc) #t) (when (> (cdr fc) 0.0) (hash-set! made (car fc) #t)))
                (col-flows c))) cols)
    (values (filter (lambda (k) (hash-ref made k #f)) (hash-map->list (lambda (k v) k) all))
            (filter (lambda (k) (not (hash-ref made k #f))) (hash-map->list (lambda (k v) k) all)))))
;; ONE pass over the columns that does what the per-good and per-cell rescans did P times each:
;;  · classify each good (produced ⇒ good, else raw) and bin every column's coefficient on it into
;;    good → ((col-idx . coeff) …)  — replaces good-coeffs' O(goods × columns) scan;
;;  · bin every labour-bearing column by its cell into cell → ((col-idx . hours) …) — replaces the
;;    aggregate-labour cap's O(cells × columns) scan.
;; Both were the build's quadratic walls; this is one O(columns × flows) sweep + O(1) lookups.
;; Returns (values goods raws coeff-index labour-by-cell).
(define (good-index cols idx)
  ;; which services the scope actually holds is read from the caps as they stand
  ;; NOW — stock has been ingested, eco-caps applied, suppliers registered — so a
  ;; durable declared by any of those routes counts as held.
  (refresh-svc-known!)
  (let ((made (make-hash-table)) (made-spec (make-hash-table))   ; made HERE · madeANYWHERE
        (cidx (make-hash-table)) (lcell (make-hash-table)))
    (for-each (lambda (c)
      (let ((ci (hash-ref idx (col-key c))) (acq? (acq-col? c))
            ;; the sky lays its own gifts: a declared ambient flow is MADE at a cell only by
            ;; a process that says it is the boundary (the shine, bounding a hectare's
            ;; light). What an ordinary process returns to the surroundings (a body's
            ;; breath, a leaf's oxygen) goes to the surroundings and supplies nobody, so the
            ;; air stays the reservoir it is and a field breathes no town's breath alone.
            (sky? (let ((p (key-process (col-key c)))) (and p (member "boundary" (hash-ref *proc-tags* p '())) #t))))
        (for-each (lambda (fc)
          (when (and (> (cdr fc) 0.0) (not acq?)            ; a bought-in unit is supply on the row, never a producer: the row keeps its own reading (a raw stays a raw)
                     (or sky? (not (hash-ref *raws* (good-spec (car fc)) #f))))
            (hash-set! made (car fc) #t)
            (hash-set! made-spec (good-spec (car fc)) #t))
          (hash-set! cidx (car fc) (cons (cons ci (cdr fc)) (hash-ref cidx (car fc) '()))))
          (col-flows c))
        (unless (= (col-labour c) 0.0)                     ; a hire column carries −1 hour: the cell's cap rises by what it buys
          (hash-set! lcell (col-cell c) (cons (cons ci (col-labour c)) (hash-ref lcell (col-cell c) '()))))))
      cols)
    (let ((goods '()) (raws '()))
      ;; FAIL-CLOSED: a located good SKIPS its ≥0 stock balance (is a solver "raw")
      ;; for exactly the honest reasons — a structural pool (Lab|/Svc|), a
      ;; barrier-bounded draw (its fragility IS its balance), a declared boundless
      ;; ambient flow (*raws*), OR it carries raw stock (*cap*). Everything else is a
      ;; GOOD balanced ≥0, so an UNstocked unproduced input with no recipe and no
      ;; barrier dies instead of conjuring itself free. never-raw (money) stays a
      ;; good. (# split → bare spec.)
      (hash-for-each (lambda (g _)
        (let ((sp (good-spec g)))
          (if (and (not (hash-ref made g #f))
                   (not (hash-ref *never-raw* sp #f))
                   (or (structural-raw? sp) (svc-held? sp) (barrier-bounded? sp) (hash-ref *raws* sp #f) (> (hash-ref *cap* g 0.0) 0.0)))
              (set! raws (cons g raws))
              (set! goods (cons g goods))))) cidx)
      ;; RAW-LINT (PLANNER_RAW_LINT=1): two honesty reports on the ecological books.
      ;; (1) STARVED — consumed, no producer, no stock, no barrier: the fail-closed
      ;;     casualties. Give them a recipe/stock/barrier, or (last resort) declare
      ;;     the spec a boundless ambient flow in #:raws.
      ;; (2) EXTERNALITIES — specs actually DRAWN as free ambient raws (via *raws*,
      ;;     not a barrier or stock): every one is an unpriced appropriation of
      ;;     nature. Confirm each is genuinely boundless (sunlight, rain); anything
      ;;     finite belongs as a regenerating stock or a fragility instead.
      (when (getenv "PLANNER_RAW_LINT")
        ;; A good drawn where nothing makes it splits in two, and only one half is
        ;; a hole in the books:
        ;;
        ;;   STARVED — produced NOWHERE, at any cell, and still consumed. This is
        ;;     the fail-closed casualty: a good with no recipe, no stock and no
        ;;     barrier anywhere in the program.
        ;;   STRANDED — produced somewhere, just not reachable HERE (made in an
        ;;     earlier period with no storage column, or at a place with no route).
        ;;     Its own ≥0 balance already pins the draw to zero, so the column is
        ;;     dead weight rather than free food. Worth saying — a dead column is
        ;;     usually a missing carry path someone meant to model — but it is not
        ;;     the same finding, and calling it starved trains people to ignore the
        ;;     word. Reported under its own name, so a CI gate on "starved" stays a
        ;;     gate on goods conjuring themselves.
        (let* ((drawn-unmade (filter (lambda (g)
                               (and (not (hash-ref made g #f))
                                    (not (hash-ref *acquired-keys* g #f))   ; bought in: fed, by the bill
                                    (= 0.0 (hash-ref *init* g 0.0))
                                    (any (lambda (cc) (< (cdr cc) 0.0)) (hash-ref cidx g '()))))
                             goods))
               (starved (delete-duplicates
                         (filter-map (lambda (g)
                           (and (not (hash-ref made-spec (good-spec g) #f)) (good-spec g)))
                          drawn-unmade) string=?))
               (stranded (delete-duplicates
                          (filter-map (lambda (g)
                            (and (hash-ref made-spec (good-spec g) #f) (good-spec g)))
                           drawn-unmade) string=?))
              (externalities (delete-duplicates
                        (filter-map (lambda (g)
                          (let ((sp (good-spec g)))
                            (and (hash-ref *raws* sp #f)                                  ; a declared ambient flow
                                 (not (structural-raw? sp)) (not (svc-held? sp)) (not (barrier-bounded? sp))   ; not covered by a barrier
                                 (any (lambda (cc) (< (cdr cc) 0.0)) (hash-ref cidx g '())) ; actually drawn
                                 sp))) raws) string=?)))
          (when (pair? stranded)
            (format (current-error-port)
                    "[RAW-LINT] ~a stranded spec(s) — drawn where nothing makes it and no carry reaches; the column is pinned to zero: ~s~%"
                    (length stranded) stranded))
          (when (pair? starved)
            (format (current-error-port)
                    "[RAW-LINT] ~a starved spec(s) — consumed, no producer/stock/barrier: ~s~%"
                    (length starved) starved))
          (when (pair? externalities)
            (format (current-error-port)
                    "[RAW-LINT] ~a externality(ies) — drawn as FREE ambient raws; confirm boundless (else make a stock/fragility): ~s~%"
                    (length externalities) externalities))))
      (values goods raws cidx lcell))))

;; build the unified FORMS (mk-bar/mk-des) + labform from the located columns.
;; activity index = column index. Returns (values forms labform ncol cols goods raws idx).
(define (build-located)
  (let* ((cols (build-columns)) (ncol (length cols)) (idx (make-hash-table)))
    (let ((i 0)) (for-each (lambda (c) (hash-set! idx (col-key c) i) (set! i (+ i 1))) cols))
    (set! *col-terms* (build-terms cols))                       ; what each column is made of, read once, indexed like idx
    (set! *col-ell* (list->vector (map column-labour-hours cols)))   ; …and the labour hours per unit of each, for the field and its price
    (call-with-values (lambda () (good-index cols idx))
      (lambda (goods raws cidx lcell)
        (define (good-coeffs g) (hash-ref cidx g '()))   ; O(1) lookup into the binned index (built in one pass above)
        ;; …and the same reading over a STRETCH: one form for one statement. The
        ;; arcs internal to the stretch cancel in the sum, so this IS the coarse
        ;; balance rather than an approximation of it.
        (define (span-coeffs g)
          (let ((gs (stretch-of g)))
            (if (null? (cdr gs)) (good-coeffs g)
                (merge-coeffs (append-map good-coeffs gs)))))
        ;; ── ecological cascade (Space): effective pressure p = (I−C)^{-1}·draw ────────────────────
        ;; *eco-couple* is C (C[k][j] = how much drawing agent j stresses agent k). A frag-capped agent
        ;; reads its EFFECTIVE pressure — own draw plus propagated stress — via the Leontief row
        ;; B[k] = e_k + B[k]·C (ρ(C)<1): a linear sum-product fixpoint — same FAMILY as the demand
        ;; warm-start (seed-need!) and the value rollup (good-labour-content, which is its min-plus
        ;; generalisation), but its own small DENSE instance over C, not their sparse recipe-graph path.
        ;; a fragility keyed on a LEAF of the composition map (`El|` closes over the
        ;; same keys) reads the leaf DRAWN: every raw carrying it stresses it by its
        ;; mass fraction, which is the cascade's own shape, derived here once per solve
        ;; from the composition map. A nitrogen boundary then feels N however it enters
        ;; (soil-n, ammonia, a fertiliser) with no table naming the routes, and the
        ;; reading has one unit: the raws' own. The leaf itself is no raw, so its
        ;; per-period barrier is emitted below, one per cell the raws are drawn at.
        ;; the raws' DISTINCT specs, read once: RAWS runs O(crowd) (a credit|aid
        ;; good per citizen rides in it), and the distinct set does too, so one
        ;; hash-indexed pass (first-occurrence order, shared by both readers
        ;; below) keeps this linear where a pairwise dedup — twice — and a
        ;; `member` probe per fragility key each read the crowd once per member.
        (define raw-spec-set (make-hash-table))
        (define raw-specs
          (let ((acc '()))
            (for-each (lambda (r)
                        (let ((sp (good-spec r)))
                          (unless (hash-ref raw-spec-set sp #f)
                            (hash-set! raw-spec-set sp #t)
                            (set! acc (cons sp acc)))))
                      raws)
            (reverse acc)))
        (define leaf-keys
          (let ((leaves (composition-elements)))
            (filter (lambda (k) (and (member k leaves) (not (hash-ref raw-spec-set k #f))))
                    (delete-duplicates (append (hash-map->list (lambda (k v) k) *frag-spec*)
                                               (hash-map->list (lambda (k v) k) *frag-budget*))))))
        (define eco-C
          (if (null? leaf-keys) *eco-couple*
              (let ((C (make-hash-table)))
                (hash-for-each (lambda (k v) (hash-set! C k v)) *eco-couple*)
                (for-each (lambda (k)
                            (for-each (lambda (s)
                                        (let ((f (spec-element-fraction s k)))
                                          (when (> f 0.0) (hash-set! C k (cons (cons s f) (hash-ref C k '()))))))
                                      raw-specs))
                          leaf-keys)
                C)))
        (define eco-agents (propagate-agents eco-C))
        ;; every OTHER registered coupling, each paired with its own agent
        ;; set — computed once here, not per good. '() when nothing is
        ;; registered (the common case), so coupled-coeffs below costs
        ;; nothing beyond the empty walk.
        (define coupling-agents
          (filter-map (lambda (kv) (let ((agents (propagate-agents (cdr kv))))
                                     (and (pair? agents) (cons (cdr kv) agents))))
                      (hash-map->list cons *couplings*)))
        ;; a good's coefficients, propagated through whichever registered
        ;; coupling (if any) names it as an agent, plain READER otherwise. A
        ;; new coupling costs *couplings* a new NAME (register-coupling!),
        ;; never a new clause here.
        (define (coupled-coeffs g reader)
          (let loop ((cs coupling-agents))
            (cond ((null? cs) (reader g))
                  ((member g (cdar cs)) (propagate (caar cs) (cdar cs) g reader))
                  (else (loop (cdr cs))))))
        (define (eco-coeffs k cell) (propagate eco-C eco-agents k (lambda (j) (good-coeffs (lg j cell)))))             ; effective pressure at ONE cell (per-period)
        (define (agent-draw j) (append-map good-coeffs (filter (lambda (r) (string=? (good-spec r) j)) raws)))  ; an agent's TOTAL draw columns across the whole horizon
        (define (container-draw container)               ; draws on EVERYTHING contained-in the container, across the horizon (the containment cascade)
          (append-map (lambda (spec) (append-map (lambda (t) (good-coeffs (lg spec (cell container t)))) *periods*))
                      (hash-ref *contained* container '())))
        ;; WITHIN: the named specs over every cell AT OR UNDER a place. Unlike
        ;; `container-draw`, which reads its contents at the container's own
        ;; cell, this walks the containment tree — so a limit shared by many
        ;; places is felt as their SUM by the scope that holds it. The walk is
        ;; the federation's own `containment-chain`, asked from the other end
        ;; (is the container in this place's ancestry?), so there is no second
        ;; notion of "inside" in the system.
        (define (draw-of-agent j)                      ; an agent's total horizon draw: a CONTAINER rolls up its contents; a spec is its own draw
          (if (hash-ref *frag-container* j #f) (container-draw j) (agent-draw j)))
        (let ((forms '()) (labform '()))
          ;; one path for the TABLE-DRIVEN fragilities (cumulative budgets, container roll-ups): each reads its
          ;; agent's effective pressure p = (I−C)^{-1}·draw — cascade-aware via propagate, the draw rolled up by draw-of-agent.
          (define (emit-frag! table)
            (hash-for-each (lambda (key profile)
                             (let ((coeffs (propagate eco-C eco-agents key draw-of-agent)))
                               (when (pair? coeffs) (set! forms (cons (frag-barrier profile coeffs key) forms)))))
                           table))
          ;; delivered ≥ 0. A good declared in *stock-frag-w* carries that same balance
          ;; at a FIXED governance weight instead of the swept one, so a limit held as a
          ;; level is still felt before its wall — one object, both properties. A good
          ;; registered in a coupling (nutrient bioavailability, skill cross-training) is
          ;; checked on its EFFECTIVE, cascade-propagated coefficients instead of its raw
          ;; good-coeffs (the same swap the *stretch-floor* loop below makes for a
          ;; multi-period floor) — so a single-period reproduction floor on iron also
          ;; sees calcium's suppression and vitamin C's assist, not only a week-spanning
          ;; one, and a skill's balance sees a substitute's own net supply.
          ;; A BALANCE NOTHING CAN BREAK is no constraint. A good nothing draws and
          ;; nothing is asked of (on hand at zero or above, every column adding to it)
          ;; stands at or above zero whatever the plan does, so its row is left out: a
          ;; by-product nobody takes up, the vapour and the dung every eat returns, the
          ;; loss a closure row shows. Such a row is also the DENSEST a program has,
          ;; one entry for every column that makes the thing, and a row that touches
          ;; every eat of a crowd makes the whole Newton system dense for nothing.
          (for-each (lambda (g)
                      (let ((w (hash-ref *stock-frag-w* (good-spec g) #f))
                            (gc (coupled-coeffs g good-coeffs))
                            (on-hand (hash-ref *init* g 0.0)))
                        (unless (and (not w) (>= on-hand 0.0) (every (lambda (ic) (>= (cdr ic) 0.0)) gc))
                          (set! forms (cons (if w
                                                (mk-frag on-hand gc w)
                                                (begin (pin-check! g on-hand gc)
                                                       (mk-bar on-hand gc)))
                                            forms)))))
                    goods)
          ;; a bare floor over a STRETCH: the day's balance (every band's
          ;; columns, the stretch's own carry-in) must reach the floor —
          ;; stretch-init already carries the deficit. A good registered in a
          ;; coupling is checked against its EFFECTIVE amount — the same
          ;; (I−C)^{-1} cascade eco-coeffs reads, over span-coeffs instead of
          ;; one cell's good-coeffs — so a floor on iron sees iron net of
          ;; what calcium in the same day's meals suppressed. Every other
          ;; floor (both couplings empty, or this good agent to neither)
          ;; takes the untouched span-coeffs branch.
          (hash-for-each (lambda (g lo)
                           (let ((gc (coupled-coeffs g span-coeffs)))
                             (when (null? gc)
                               (error "a reproduction floor names a good no column of its stretch touches — it could never be held" g))
                             (pin-check! (string-append "floor " g) (stretch-init g) gc)
                             (set! forms (cons (mk-bar (stretch-init g) gc) forms))))
                         *stretch-floor*)
          ;; FAIL-CLOSED: a wall the balance must reach (`floor-pulls?`) on a
          ;; good no column touches anywhere in its stretch would be silently
          ;; inert — a floor the certificate calls feasible with nothing
          ;; produced. It dies here. The prune keeps every column that feeds
          ;; such a wall (`floor-pulled-set`), so a wall standing on no column
          ;; is a good NOTHING COULD EVER RAISE — a floor on cheese in a world
          ;; with no cheese recipe — a modelling error, never a scarcity: a
          ;; scarcity keeps its feeders and fails as a certificate.
          ;; A STOCKED good is the exception: a purse of EUR no recipe
          ;; touches is held by its stock alone (init), and the band reads
          ;; against that — so a held money need over a lent purse is judged,
          ;; not refused.
          ;; A band whose wall is at ZERO (a held need's insurance band) asks
          ;; nothing of the balance: with no column it is simply unmet, and
          ;; `met` says so.
          (hash-for-each (lambda (g b)
                           (when (and (floor-pulls? g) (null? (good-coeffs g)) (null? (span-coeffs g)))
                             (error "a reproduction band names a good no column touches — it could never be held" g)))
                         *band*)
          (for-each (lambda (r)
                      (let ((fc (or (hash-ref *frag-cap* r #f) (hash-ref *frag-spec* (good-spec r) #f))))           ; per-located-good cap, else a per-spec rate boundary
                        (if fc                                                                                      ; a FRAGILITY barrier — felt before the limit, never crossed (frag, fixed weight w)
                            ;; slack s = s_tip − p, where p is the EFFECTIVE pressure (own draw + cascade-propagated stress).
                            ;; eco-coeffs already carries (I−C)^{-1} (identity when uncoupled), and good-coeffs is −draw, so s = s_tip + Σ p-coeffs·x.
                            ;; φ = −w·log s diverges at p=s_tip; the (s_tip−s*) normalisation is omitted (inert for the optimum; raw s gives the dual w/s).
                            (let ((ec (eco-coeffs (good-spec r) (located-cell r))))
                              (when (pair? ec) (set! forms (cons (frag-barrier fc ec r) forms))))
                            (let* ((capv (hash-ref *cap* r #f))                       ; eco ≤ cap (the branch's avail view), or a starting
                                   (cap (if capv (* capv (*avail-factor* r))          ; STOCK (init) of a consumed good — e.g. a durable's condition
                                            (hash-ref *init* r #f)))
                                   ;; a STRUCTURAL raw (Lab|skill|cell, chiefly) can be a
                                   ;; coupled agent too — skill cross-training reads a
                                   ;; substitute's own net supply the identical way a
                                   ;; reproduction floor reads a sibling nutrient's.
                                   (gc (coupled-coeffs r span-coeffs)))
                              (when cap (pin-check! (string-append "cap " r) cap gc) (set! forms (cons (mk-bar cap gc) forms))))))) raws)
          ;; a LEAF's rate barrier: one per cell the raws are drawn at, over the leaf's
          ;; effective pressure there (the derived coupling above); its budget goes through emit-frag! like any agent's
          (for-each (lambda (k)
                      (let ((fc (hash-ref *frag-spec* k #f)))
                        (when fc
                          (for-each (lambda (c)
                                      (let ((ec (eco-coeffs k c)))
                                        (when (pair? ec) (set! forms (cons (frag-barrier fc ec (lg k c)) forms)))))
                                    (delete-duplicates (map located-cell raws))))))
                    leaf-keys)
          (emit-frag! *frag-budget*)     ; CUMULATIVE budgets — Time: a spec's draw summed across the horizon (Space∘Time, max-is-a-no-op)
          (emit-frag! *frag-container*)  ; CONTAINER roll-ups — the Amazon's tipping point feels its trees logged, via the contained-
          ;; WITHIN roll-ups — a COMMONS: one limit, many drawers. 'horizon sums
          ;; the named specs over every cell at or under the place (a shared
          ;; tipping point); 'rate emits one barrier PER PERIOD over the places
          ;; under it (a shared sustainable yield, which resets each period).
          ;; The two windows are the same collector read over a different set of
          ;; cells — which is the whole point of naming the axes apart.
          (hash-for-each
           (lambda (container spec)
             (let* ((profile (car spec)) (specs (cadr spec)) (window (caddr spec))
                    (level (and (pair? (cdddr spec)) (cadddr spec)))
                    ;; A pooled BUDGET carries a measured level, so its headroom
                    ;; is a fact about the world (metres of head, standing
                    ;; timber) rather than the governance-set tip. Same barrier,
                    ;; same fixed weight — a shed already half-drawn starts half
                    ;; drawn. playnet.typ §"Shared budgets": the budget itself
                    ;; is a stock, held in stewardship custody at the scope that
                    ;; speaks for the agent.
                    (barrier (lambda (coeffs)
                               (if level
                                   (mk-frag level coeffs (frag-w profile))
                                   (frag-barrier profile coeffs container))))
                    (places (places-within container *spatial-things* *places*)))
               ;; the specs, over the places under the container, across a set of
               ;; periods — the one collector all three windows read differently
               (define (over ts)
                 (append-map (lambda (s)
                               (append-map (lambda (p)
                                             (append-map (lambda (u) (good-coeffs (lg s (cell p u)))) ts))
                                           places))
                             specs))
               (define (emit! coeffs)
                 (when (pair? coeffs) (set! forms (cons (barrier coeffs) forms))))
               (case window
                 ;; a per-period yield: each period stands alone, headroom resets
                 ((rate) (for-each (lambda (t) (emit! (over (list t)))) *periods*))
                 ;; a CARRIED LEVEL: the level must stand at every period, counting
                 ;; only what has happened UP TO it. Those prefix constraints are
                 ;; what make the carry forward-only — a restore in a late period
                 ;; cannot pay for a draw in an early one, because the early
                 ;; period's constraint was already struck without it. This is
                 ;; playnet.typ's temporal chain "linked only forward by storage",
                 ;; and it is the difference between a level and a total.
                 ((carry) (for-each (lambda (t)
                                      (emit! (over (filter (lambda (u) (<= u t)) *periods*))))
                                    *periods*))
                 ;; one constraint on the whole plan — a genuine total, no carry
                 (else (emit! (over *periods*))))))
           *frag-within*)
          ;; CAPACITY needs no bespoke machinery either: a `use`d durable's per-period SERVICE is a good
          ;; `Svc|durable` (compile-process turns a `use` flow into a consume of it), capped by the
          ;; durable's onhand (*cap* on Svc).  Its balance ≥ 0 — auto, like any raw — and its DUAL is the
          ;; capacity/expand pull (in good-pulls).  Parallel to labour exactly; works per-cell or per-arc.
          ;; WEAR → MAINTENANCE needs NO bespoke machinery: a durable's CONDITION is just a stock GOOD
          ;; (Cond|durable).  Per-recipe wear is a `consume` flow on the using recipe (its quantity =
          ;; the manner), maintenance a `produce` flow; the Cond ≥ 0 balance (above), its maintenance-pull
          ;; dual, the carrying stock (Cond is *storable*), and the embodied depreciation rolled into the
          ;; output (Cond is an input — good-labour-content sums it) ALL fall out of the good machinery.
          (unless (skilled?)                                                                                       ; aggregate labour ≤ cap per cell — O(1) per cell via the binned labour index
            (for-each (lambda (cl) (let ((A (hash-ref *A* cl #f)))
                        (when A (pin-check! (string-append "labour " cl) A (map (lambda (p) (cons (car p) (- (cdr p)))) (hash-ref lcell cl '())))
                                (set! forms (cons (mk-bar A (map (lambda (p) (cons (car p) (- (cdr p)))) (hash-ref lcell cl '()))) forms)))))
                      *cells*))
          (when (pair? *supplier-bundles*)                                                                        ; per-SUPPLIER shared budget cap + (labour only) EMP congestion
            ;; EMP is a FAIRNESS tiebreaker — it sets WHO works (equal standing among
            ;; the qualified), not HOW MUCH (that is the labour balance + κ free-time).
            ;; "Equal standing", with the equal-free-time telos (f = 1 − L/(NT)), means
            ;; equal FRACTIONAL utilization: everyone works the same share of the time
            ;; they offer. A convex penalty Σ_w x_w²/h_w is minimised at x_w/h_w equal.
            ;; Two scale facts make the WEIGHT matter:
            ;;   • penalise raw x_w² (the old ρ·burden²) and the term grows as ρ·h² with
            ;;     the economy while demand stays O(1) — at a national sector's ~10⁴ h it
            ;;     SWAMPS demand and throttles production (a fairness term must never do
            ;;     that). • divide by total offered capacity H so the whole term is
            ;;     (ρ/H)·Σ x_w²/h_w = ρ·u² at the equal-utilisation optimum: bounded by ρ
            ;;     at ANY scale. So per worker w: weight ρ/(h_w·H), coeffs the raw hrs.
            ;; Equal-capacity workers ⇒ identical split (the doc's base case); unequal ⇒
            ;; equal fraction of each one's own offered time, not equal absolute hours.
            (let ((Htot (offered-labour-hours)))                                                                 ; H = total offered LABOUR hours
            (for-each (lambda (bundle)                                                                            ; bundle = (id budget place ((col-key cell coeff) …) labour?)
              (let* ((hours (cadr bundle))
                     ;; (idx . coeff) per draw on the budget; a column pruned since the
                     ;; bundle was laid (an unreachable draw) leaves it, drawing nothing
                     (ec (filter-map (lambda (e) (let ((i (hash-ref idx (car e) #f))) (and i (cons i (caddr e))))) (cadddr bundle)))
                     (w  (if (and (> hours 0.0) (> Htot 0.0)) (/ *emp-rho* (* hours Htot)) *emp-rho*)))          ; ρ/(h_w·H): scale-free fractional-utilisation fairness
                (pin-check! (string-append "supplier " (car bundle)) hours (map (lambda (p) (cons (car p) (- (cdr p)))) ec))
                (set! forms (cons (mk-bar hours (map (lambda (p) (cons (car p) (- (cdr p)))) ec)) forms))        ; Σ coeff·x ≤ budget — EVERY supplier (a worker's hours OR a means' service capacity)
                ;; EMP is a labour FAIRNESS tiebreaker (equal free-time telos) — a means has
                ;; no free time to equalise, so need-priced suppliers get the cap but no EMP.
                ;; 'total ⇒ equal fractional utilisation ACROSS workers;
                ;; 'pool  ⇒ equal share WITHIN each (skill,cell) pool.
                (when (list-ref bundle 4)
                  (if (eq? *emp-mode* 'pool)
                      (for-each (lambda (p) (set! forms (cons (mk-qc 0.0 (list p) w) forms))) ec)
                      (set! forms (cons (mk-qc 0.0 ec w) forms))))))
              *supplier-bundles*)))
          (for-each (lambda (c) (let ((mbq (or (mbq-of (col-key c)) 0.0)))
                      ;; a DECIDED column is substituted out; its own x ≥ L would
                      ;; fold to a constant slack — zero when it is decided at
                      ;; zero, and log(0) is not a number
                      (unless (col-fixed (col-key c))                                           ; x ≥ 0 (or ≥ mbq)
                      (set! forms (cons (mk-bar (- mbq) (list (cons (hash-ref idx (col-key c)) 1.0))) forms))))) cols)
          ;; the search's own cuts, wrapped as METHOD tensions: they steer the
          ;; search and must never appear in what the plan claims to have proven
          (for-each (lambda (c)
                      (let* ((k (col-key c)) (j (hash-ref idx k #f)) (b (col-bound k)))
                        (when (and j (not (col-fixed k)))
                          (when (car b)     ; x ≥ lo
                            (set! forms (cons (mk-method (mk-bar (- (car b)) (list (cons j 1.0)))) forms)))
                          (when (cdr b)     ; x ≤ hi
                            (set! forms (cons (mk-method (mk-bar (cdr b) (list (cons j -1.0)))) forms))))))
                    cols)
          (hash-for-each (lambda (g D)
                           (let ((form (mk-bar (stretch-init g) (span-coeffs g)))
                                 (w    (hash-ref *desire-weight* g *desire-w0*)))
                             (case (tier-shape 'want)
                              ;; a want held as a wall is a floor at its ask, its pull gone — a
                              ;; cap wall beside a floor at the same D would pin the row shut
                              ((wall)
                               (when (pair? (span-coeffs g))
                                 (pin-check! (string-append "promoted want " g) (- (stretch-init g) D) (span-coeffs g))
                                 (set! forms (cons (mk-bar (- (stretch-init g) D) (span-coeffs g)) forms))))
                              ((#f) #f)                     ; a softer tier than the one held: out of the program
                              (else
                               (if (and *want-as-cap?* (spec-owner (key-spec g)))
                                 ;; a citizen's OWN want, the ask a wall: the cap
                                 ;; term pulls by emphasis alone and the wall
                                 ;; D − s ≥ 0 is where the report enters —
                                 ;; docs/planning/solve/quantity-as-a-cap.md
                                 (begin
                                   ;; the ask rides on the cap form as a fifth element: the
                                   ;; solver reads the first four (kind const coeffs Dw); the
                                   ;; maximin reading (engine/robust.scm maximin-extend) takes the
                                   ;; want's captured value as delivered over ASKED, so the
                                   ;; pair — pull and wall — stays one object where it is read
                                   (set! forms (cons (append (mk-cap form w (cap-scale-of g)) (list D)) forms))
                                   (set! forms (cons (mk-bar (- D (stretch-init g))
                                                             (map (lambda (c) (cons (car c) (- (cdr c)))) (span-coeffs g)))
                                                     forms)))
                                   (set! forms (cons (mk-des form D w) forms)))))))
                         *demand*)  ; desires — priority-weighted (w_d), uniform when unset
          ;; RESERVE = the lowest-priority desire tranche: a second satiation pull on
          ;; the same good toward (consumption + reserve) at a small weight, so it is
          ;; filled only after consumption is met and SHED FIRST when resources bind.
          (when (tier-shape 'reserve)          ; the soft tranche: only the ordinary solve carries it
            (hash-for-each (lambda (g rv)
              (let ((Dc (hash-ref *demand* g 0.0)))
                (set! forms (cons (mk-des (mk-bar (stretch-init g) (span-coeffs g)) (+ Dc (car rv)) (cdr rv)) forms))))
              *reserve*))
          ;; ── REPRODUCTION BAND: the two walls a good's level is held between ──
          ;; A bare floor is already in the program: apply-repro-bands! took it as
          ;; a deficit on the good's on-hand, so its ≥0 balance forces the plan
          ;; to provision it — a swept `bar`, no extra term. What is emitted here
          ;; is the floor WITH A MARGIN and the CEILING.
          ;;
          ;; The margin floor is `held`, NOT `frag`, and the difference is not
          ;; cosmetic. A log barrier works on a CEILING because its pressure and
          ;; thrift push the same way — draw less — so it settles. On a FLOOR it
          ;; pushes supply UP without bound, resisted only by κ·labour, and
          ;; equilibrates at w/κ: a number about the weight, not about any
          ;; margin. `held` does what a floor means: it DIVERGES at bare need,
          ;; so nothing can cross it, and it SATIATES at the margin, so nothing
          ;; is over-made for it. lo = bare need (the wall — NOT zero; a wall at
          ;; zero only forbids total collapse), the tip = the margin the plan
          ;; holds, `alpha` places it in [lo, hi] — the direction reverses
          ;; against a cap, where alpha = 0 is most precautious; on a floor,
          ;; more is. This is the calamity reserve: playnet.typ §Reproduction
          ;; labour has it "enter harmony as a HARD possibility-tension rather
          ;; than a soft desire" — the soft buffer is the reserve tranche above,
          ;; a low-weight desire and the FIRST thing shed. Measured (tests/
          ;; planner/test-insurance-reserve.scm): with labour abundant the plan
          ;; holds the margin; as labour tightens the margin erodes toward `lo`
          ;; and stops there, where the bare floor sits at `lo` with no margin
          ;; to give and the soft buffer is shed below it.
          ;;
          ;; The ceiling is a `frag` on the good's own delivered net: slack =
          ;; hi − net, fixed weight w, felt before hi, never crossed. Without it
          ;; a desire correlated with the good — a taste for the salty food —
          ;; has nothing opposing it on that axis and intake is unbounded; a
          ;; floor cannot help, it only says "at least". It reads the good's
          ;; coefficients directly rather than the eco cascade (`eco-coeffs`),
          ;; which is about raws and their coupling; a produced good has no
          ;; cascade. Both walls on one good are the two-sided band the
          ;; fragility dial draws — as two smooth terms, which is why the band
          ;; is convex and Newton-safe (tests/solve/test-nutrition-band.scm).
          (hash-for-each (lambda (g b)
            (let ((fl (band-floor b)) (hi (band-ceiling b)) (w (band-w b)) (gc (good-coeffs g)))
              (when (and (pair? fl) (eq? (tier-shape 'margin) 'soft))   ; a floor with a margin → held; a wall at its ease under a held tier (below), gone under rights
                (let ((lo (car fl)))
                  (set! forms (cons (mk-held (mk-bar (- (hash-ref *init* g 0.0) lo) gc)
                                             (max 1e-9 (- (apply quantile (list (caddr fl) lo (cadr fl))) lo))
                                             w)
                                    forms))))
              (when (and hi (pair? gc))                           ; a ceiling → frag on the net, tip inside its range
                (let ((tip (if (pair? hi) (quantile (caddr hi) (car hi) (cadr hi)) hi)))
                  (set! forms (cons (mk-frag tip (map (lambda (c) (cons (car c) (- (cdr c)))) gc) w)
                                    forms))))))
            *band*)
          ;; a declared-movable good's carry (an `m|` column) costs its τ·km in
          ;; every labour model: with workers the objective is built from their
          ;; bundles, which no carry is in, so the term is appended here — else
          ;; a carry is free and the program is indifferent to sending q units
          ;; out and q back, and lands on any q (test-property-enact pins it)
          (define carry-terms
            (append-map (lambda (c)
                          (if (and (> (col-labour c) 0.0) (equal? (assq-ref (key-terms (col-key c)) 'prefix) "m"))
                              (list (cons (hash-ref idx (col-key c)) (col-labour c)))
                              '()))
                        cols))
          (set! labform                                                                                          ; free-time κ·labour, + commute cost, + skill-time preference:
            (if (workers?)                                                                                       ; per worker column, coeff = 1 + τ·km + π_{w,s}, π = tilt·2ρ/H
                (let* ((tilts (worker-tilts)) (H (offered-labour-hours))
                       ;; one entry per worker on both sides — indexed, so the
                       ;; walk below reads each bundle's tilt in O(1) instead of
                       ;; scanning the roster once per member
                       (tilt-of (let ((h (make-hash-table)))
                                  (for-each (lambda (t) (hash-set! h (car t) (cdr t))) tilts) h))
                       (unit (if (> H 0.0) (/ (* 2.0 *emp-rho*) (* H *kappa*)) 0.0)))                          ; EMP's unit, over κ (applied downstream)
                  (append-map (lambda (bundle)
                    (let ((mine (or (hash-ref tilt-of (car bundle) #f) '())))
                      (map (lambda (e)
                        (let* ((kt (key-terms (car e))) (skill (assq-ref kt 'skill)) (hc (caddr e)))
                          (cons (hash-ref idx (car e))
                                (* hc (+ 1.0                                                                      ; hc already carries the transport hours to reach the work (real committed time)
                                         (* unit (or (assoc-ref mine skill) 0.0)))))))                         ; + the bounded, centred skill-time preference
                        (cadddr bundle))))
                    (filter (lambda (b) (list-ref b 4)) *supplier-bundles*)))                                        ; κ free-time is a LABOUR cost — means draws carry none
                (append-map (lambda (c) (if (> (col-labour c) 0.0)                                               ; or process labour (aggregate path)
                          (list (cons (hash-ref idx (col-key c)) (col-labour c))) '())) cols)))
          (when (workers?) (set! labform (append labform carry-terms)))
          ;; ── a held margin is a wall at its ease when the tier table says so ──
          (when (eq? (tier-shape 'margin) 'wall)
            (hash-for-each (lambda (g b)
                             (let ((fl (band-floor b)) (gc (good-coeffs g)))
                               (when (and (pair? fl) (pair? gc))
                                 (let ((ease (quantile (caddr fl) (car fl) (cadr fl))))
                                   (when (> ease 0.0)
                                     (pin-check! (string-append "promoted need " g) (- (hash-ref *init* g 0.0) ease) gc)
                                     (set! forms (cons (mk-bar (- (hash-ref *init* g 0.0) ease) gc) forms)))))))
                           *band*))
          ;; ── the voice field: how the work is done, re-weighed by those who do it ──
          ;; One extra entry per work column, −τ·s_j·ℓ_j hours, folded into the
          ;; same list (κ is applied downstream to every entry alike), so the one
          ;; linear term reads κ·ℓ_j·(1 − τ·s_j). |τ·s| < 1 keeps it positive: a
          ;; liked way is cheaper, never free. Read before the solve, plain data;
          ;; walls, wants, EMP and the who rail are untouched (finding 18).
          (call-with-values
            (lambda () (voice-labform labform *col-terms* *col-ell* *voice-pushes* (or *voice-hours* (lambda _ 0.0))
                                      ;; the wanted specs are read only when a field stands (τ = 0
                                      ;; or no pushes returns LABFORM itself), and the distinct set
                                      ;; is O(crowd) under owned wants — a hash dedup when it is
                                      ;; read, nothing at all when it is not
                                      (if (and (> *voice-tau* 0.0) (pair? *voice-pushes*))
                                          (let ((seen (make-hash-table)) (acc '()))
                                            (hash-for-each (lambda (k v)
                                                             (let ((sp (good-spec k)))
                                                               (unless (hash-ref seen sp #f)
                                                                 (hash-set! seen sp #t) (set! acc (cons sp acc)))))
                                                           *demand*)
                                            acc)
                                          '())
                                      #:tau *voice-tau*))
            (lambda (lf stances) (set! labform lf) (set! *voice-stances* stances)))
          ;; what is bought in costs hours: the acquire columns' price rides in the labour form
          (for-each (lambda (c)
                      (when (acq-col? c)
                        (set! labform (cons (cons (hash-ref idx (col-key c)) (hash-ref *acquire-cost-of* (col-key c) 0.0)) labform))))
                    cols)
          ;; …and so does what is drawn DOWN: a column's share of a stock nothing here remakes
          (for-each (lambda (ic) (set! labform (cons ic labform))) (stock-draw-costs cols idx))
          (when (skill-dynamics?)                                                                                  ; skill DYNAMICS forms: decay/regen/gate + trainee cost
            (let ((ex (skill-dyn-forms idx cols)))
              (set! forms (append forms (car ex))) (set! labform (append labform (cdr ex)))))
          (when (riders?)                                                                                          ; rider presence-gate + transit budget
            (let ((ex (rider-forms idx cols)))
              (set! forms (append forms (car ex))) (set! labform (append labform (cdr ex)))))
          (set! forms (append forms (proc-frag-forms idx cols)))                                                   ; fragilities on an ACT's own level (*proc-frag*)
          (set! forms (append forms (legal-frag-forms idx cols)))                                                  ; uncertain prohibitions, per column (*legal-frag*)
          (values forms labform ncol cols goods raws idx))))))

;; feasible warm start: chain-consistent production levels (finals-first fixpoint),
;; moves tiny. Native needs this; OSQP ignores x0 (cold ADMM). Returns x0 vector.
(define (located-warm cols ncol idx)
  (define x0 (make-vector ncol 0.05))
  (define need (make-hash-table))               ; bare good → Leontief throughput estimate

  ;; (1) DEMAND ROLLUP — the recipe-backtrace seed: need ≈ (I−A)⁻¹·demand. Jacobi-
  ;; iterate need[g] = (0.5 + demand[g]) + Σ coeff·need[output] over a SPARSE upstream
  ;; adjacency (O(passes·nnz), not the old O(pgoods²·templates) ≈ 10¹⁰ on a national
  ;; table). Seeding from REAL demand (not a flat 0.5) makes the start the Leontief
  ;; throughput, not "0.5 of everything"; the 0.5 floor keeps demand-free callers'
  ;; generic start. ρ(A)<1 ⇒ geometric convergence; the pass cap is the backstop.
  (define (seed-need!)
    (let ((dem-by-good (make-hash-table))       ; bare good → Σ its located demand over cells
          (consumers   (make-hash-table))       ; input good → ((output . coeff) …)
          (pgoods (delete-duplicates (filter-map proc-output-good *templates*))))
      (hash-for-each (lambda (k d)
        (let ((g (good-spec k)))                 ; located good = spec#cell
          (hash-add! dem-by-good g d))) *demand*)
      (for-each (lambda (tpl)
        (let ((og (proc-output-good tpl)))
          (when og
            (for-each (lambda (iq)
                        (hash-set! consumers (car iq) (cons (cons og (cdr iq)) (hash-ref consumers (car iq) '()))))
                      (proc-inputs tpl)))))
        *templates*)
      (let loop ((pass 0))
        (let ((maxd 0.0) (maxv 1.0))
          (for-each (lambda (g)
            (let ((nd (+ 0.5 (hash-ref dem-by-good g 0.0))))
              (for-each (lambda (oc) (set! nd (+ nd (* (cdr oc) (hash-ref need (car oc) 0.0)))))
                        (hash-ref consumers g '()))
              (set! maxd (max maxd (abs (- nd (hash-ref need g 0.0)))))
              (set! maxv (max maxv (abs nd)))
              (hash-set! need g nd)))
            pgoods)
          (when (and (< pass 200) (> maxd (* 1e-6 maxv))) (loop (+ pass 1)))))))

  ;; (2) PRODUCTION columns — seed each at its good's `need`, but only where LOCALLY
  ;; producible: every input a raw present here (cap>0) or an intermediate itself
  ;; producible (acyclic fixpoint from raws). Elsewhere leave it 0 and let the solve
  ;; ship the good in — a wrong-cell seed makes delivered<0 and native's barrier can't
  ;; move. EXCEPT a raw-free recipe set is a CLOSED circular economy (an I-O table):
  ;; the fixpoint has no raws to bootstrap from and finds nothing, but a closed economy
  ;; seeded at its throughput is globally consistent, so skip the guard and seed all.
  (define (seed-production!)
    (let ((made (produced-spec-set))
          (raw-free? (null? (hash-map->list (lambda (k v) k) (raw-spec-set))))
          (producible (make-hash-table)))       ; cell → set of locally-producible goods
      (define (local-set cell)
        (or (hash-ref producible cell #f)
            (let ((prod (make-hash-table)))
              (let loop ()
                (let ((changed #f))
                  (for-each (lambda (tpl)
                    (let ((g (proc-output-good tpl)))
                      (when (and g (not (hash-ref prod g #f))
                                 (every (lambda (iq)
                                          (or (and (hash-ref made (car iq) #f) (hash-ref prod (car iq) #f))
                                              (let ((cap (raw-source-cap (car iq) cell)))                ; *cap* OR a fragility tip — both make the raw locally available
                                                (if cap (> cap 0.0) (not (cap-anywhere? (car iq)))))))
                                        (proc-inputs tpl)))
                        (hash-set! prod g #t) (set! changed #t))))
                    *templates*)
                  (when changed (loop))))
              (hash-set! producible cell prod) prod)))
      (for-each (lambda (c)
        (let ((pid (key-process (col-key c))))
          (when pid
            (let* ((tpl (template-by-id pid))
                   (og (and tpl (proc-output-good tpl))) (mbq (mbq-of (col-key c)))
                   ;; `need` is a throughput in the GOOD's units; a production
                   ;; column's activity is in RUNS. Divide by what one run makes,
                   ;; or the seed is off by the recipe's output coefficient — and
                   ;; that error grows with the unit the good is stated in, which
                   ;; is how the same farm seeded 6 runs in kilograms and 60000 in
                   ;; grams. Absent or non-positive, fall back to 1 (the identity
                   ;; recipe), which is what the seed always assumed.
                   (per-run (let ((oq (and tpl og (assoc-ref (proc-outputs tpl) og))))
                              (if (and (real? oq) (> oq 0.0)) oq 1.0))))
              (vector-set! x0 (hash-ref idx (col-key c))
                           (if (and og (or raw-free? (hash-ref (local-set (col-cell c)) og #f)))
                               (let ((runs (/ (hash-ref need og 0.5) per-run)))
                                 (if mbq (max (+ mbq 1.0) runs) runs))
                               (if mbq (+ mbq 1.0) 0.05)))))))
        cols)))

  ;; (3) LABOUR SUPPLY (per-agent only) — production now consumes Σℓ·x of each
  ;; Lab|skill|cell good, but worker SUPPLY columns (w|…) are still 0.05, so the labour
  ;; balance starts wildly under-supplied. Phase-I repairs a town-sized gap; at national
  ;; scale (~10⁴×) it can't and the solve collapses to negative delivered. So pre-fill
  ;; each Lab good's suppliers to cover its seeded consumption, split EQUALLY (the same
  ;; equal-standing the EMP term enforces). The aggregate path has no Lab goods → no-op.
  (define (seed-labour-supply!)
    (when (workers?)
      (let ((lab-need (make-hash-table)) (suppliers (make-hash-table)))
        (for-each (lambda (c)
          (for-each (lambda (fl)
            (when (lab-good? (car fl))
              (if (< (cdr fl) 0.0)
                  (hash-set! lab-need (car fl)                                        ; hours consumed by seeded production
                             (+ (hash-ref lab-need (car fl) 0.0) (* (- (cdr fl)) (vector-ref x0 (hash-ref idx (col-key c))))))
                  (hash-set! suppliers (car fl)                                       ; w columns supplying this Lab good
                             (cons (cons (col-key c) (cdr fl)) (hash-ref suppliers (car fl) '()))))))
            (col-flows c)))
          cols)
        (hash-for-each (lambda (lg sup)
          (let ((hrs (hash-ref lab-need lg 0.0)) (n (length sup)))
            (when (> n 0)
              (for-each (lambda (kc) (vector-set! x0 (hash-ref idx (car kc)) (max 0.05 (/ hrs (* (cdr kc) n))))) sup))))
          suppliers))))

  ;; (4) BATCH-AWARE — when an ≥MBQ column is pinned on, size each good's non-batch
  ;; producer to cover (consumption + demand − batch output), so the cascade feeds the
  ;; batch and the interior point stays feasible.
  (define (seed-batches!)
    (when (pair? (hash-map->list cons *mbq-procs*))
      (let ((ix (lambda (c) (vector-ref x0 (hash-ref idx (col-key c))))) (goods (call-with-values (lambda () (good-keys cols)) (lambda (g r) g))))
        (do ((pass 0 (+ pass 1))) ((= pass 6))
          (for-each (lambda (g)
            (let* ((consum (fold (lambda (c a) (let ((fc (assoc g (col-flows c)))) (if (and fc (< (cdr fc) 0.0)) (- a (* (cdr fc) (ix c))) a))) 0.0 cols))
                   (dem (hash-ref *demand* g 0.0))
                   (bprod (fold (lambda (c a) (let ((fc (assoc g (col-flows c)))) (if (and fc (> (cdr fc) 0.0) (mbq-of (col-key c))) (+ a (* (cdr fc) (ix c))) a))) 0.0 cols))
                   (nb (find (lambda (c) (let ((fc (assoc g (col-flows c)))) (and fc (> (cdr fc) 0.0) (not (mbq-of (col-key c)))))) cols)))
              (when nb (vector-set! x0 (hash-ref idx (col-key nb)) (max 0.5 (/ (- (+ consum dem 0.5) bprod) (cdr (assoc g (col-flows nb)))))))))
            goods)))))

  (seed-need!)              ; the four passes, in order: each builds on the last
  (seed-production!)
  (seed-labour-supply!)
  (seed-batches!)
  x0)
;; The warm start (located-warm) need only be roughly right: native's PHASE-I
;; (ensure-feasible) repairs an infeasible start to a strictly-feasible one, and
;; the barrier method climbs from there — so hard spatial coupling (demand met only
;; by shipping from a disjoint production cell), which used to leave native stuck at
;; an infeasible start, now just solves. No OSQP crutch.
(define (solve-located)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let ((x0 (located-warm cols ncol idx)))
        (call-with-values (lambda () (solve forms labform x0))
          (lambda (x t . _) (values x forms labform cols goods raws idx)))))))

;; ── world setup (the scenarios) ──────────────────────────────────────────────
;; WHAT A RESET CLEARS is everything a previous solve DECIDED, and nothing a
;; caller told the engine before starting one. The line runs between them:
;; *spatial-things* arrives WITH a problem — ingest-located! resets and then fills
;; it from its own argument — while *templates*, *base-templates* and *fed-procs*
;; are handed over BEFORE the reset that begins the run they belong to. Clearing
;; those erases the question along with the answer: ingest-located! resets as its
;; first act, so a caller who compiled recipes and then ingested would find them
;; gone. Tuning (*kern-*, *osqp-*, the tolerances) is configuration and
;; outlives every solve by design.
;;
;; A global that is neither reset nor deliberately kept is a leak between solves,
;; and it shows up as a test that passes alone and fails in a suite.
(define (reset!)
  (reset-world!)                         ; the world: a fresh instance, every table a new table (solve/world.scm)
  (hash-clear! *period-days*) (hash-clear! *period-spans*))   ; the calendar's tables (vf/formulas/periods), laid again by the door
(define (mkcells!) (set! *cells* (append-map (lambda (p) (map (lambda (t) (cell p t)) *periods*)) *places*)))
;; the roster, layered onto a standing world — ingest-located! computes each
;; agent's located hours AFTER the declaration (the availability windows are
;; measured against the period spans the door laid) and hands them through here,
;; the same shape a fixture's #:workers takes: ((id skills cell hours) …).
(define* (declare-workers! ws #:key (peopled? (pair? ws)))
  (set! *workers* ws) (set! *roster-labour?* peopled?))

;; ── declare-world!: the ONE door a fixture declares a located world through ──
;;
;; A world is places over periods (their cells), the recipes that run in it,
;; who works where, what moves and what keeps, and how people ride. Every
;; keyword below is spelled as the global it fills, without the stars, so the
;; declaration reads as the world it makes: places, then periods, then who and
;; what. The door resets first (a declaration IS a fresh world; #:reset? #f
;; layers onto the world already standing), lays the cells, and applies the
;; declared spans — the exact sequence every fixture wrote by hand as
;; `(reset!) (set! *places* …) (set! *periods* …) (mkcells!) …`, ~130 times.
;;
;; A place is a name, or (name lat lon) when it has coordinates: the *latlon*
;; entry is a fact about the place, so it is declared with the place. Anything
;; that stays a TABLE the caller pours after — demand, stock, caps, bands —
;; is not a declaration but a filling, and hash-set! on those never touched
;; the interface question. Argument expressions are evaluated BEFORE the
;; world is reset, so an argument may not read the world it is declaring
;; (*cells*, *periods*): say the periods twice or bind them first.
;;
;; The door returns the cells it laid, which is what mkcells! left in *cells*.
;; It is THE door: ingest-located! — the records/observer door plan-from-records
;; and the live planner run through — derives its declaration from the records
;; (places from what the resources touch, coordinates from the SpatialThings,
;; periods from the horizon) and then calls this, so the fixture world and the
;; records world are one world by construction: the globals below are assigned
;; HERE and nowhere else, mkcells! has this one caller, and a keyword added here
;; is a keyword ingest passes or gets the default of. worked-example's setup-*
;; declare through it too. What is written after a declaration is a layering
;; onto a standing world, and goes through its own door (set-templates!,
;; adopt-container-pools!, workers->riders!, absorb-specs!, the manners bag).
(define* (declare-world! #:key (places '()) (periods '(0)) (spans '()) (clock #f) (horizon #f)
                         (stretches '())
                         (templates #f) (workers '()) (movable '()) (storable '())
                         (stationary '()) (mode-recipes '()) (riders '())
                         (resource-suppliers '()) (spatial-things '())
                         (neighbours '()) (tau #f) (hold #f)
                         (commute-km #f) (tau-commute #f) (emp-mode #f)
                         (reset? #t))
  "Declare a located world: PLACES (name | (name lat lon)) over PERIODS, with
   SPANS ((t start end) …) as set-period-span! takes them — or CLOCK (start n
   hours), which lays N periods of HOURS each from START and is the periods
   AND their spans at once (set-clock-horizon!), or HORIZON (start . n-days),
   N daily periods from START (set-daily-horizon!) — the records door's own
   spelling (ingest-located! #:horizon), so a fixture and a live scope lay a
   week the same way. STRETCHES ((key key…) …) declares that one located key
   stands for a run of periods (*stretch* — how a date names every period of
   its day under refinement) — TEMPLATES (compiled
   recipes; #f leaves them as they stand), WORKERS/RIDERS/RIDE-MODES/
   RESOURCE-SUPPLIERS/MOVABLE/STORABLE/STATIONARY/SPATIAL-THINGS in each
   global's own shape, NEIGHBOURS ((place . (adjacent …)) …) as the transport
   network, TAU/HOLD the move and hold costs, and the commute settings when
   given. A SpatialThing with coordinates declares them (*latlon*), as a
   (name lat lon) place does. Resets first unless RESET? is #f — ingest-located!
   passes #f, having reset before the pours its declaration is derived from
   (the partition the wall-clock keys resolve against). Returns the cells."
  (when reset? (reset!))
  (set! *places* (map (lambda (p) (if (pair? p) (car p) p)) places))
  (for-each (lambda (p) (when (pair? p) (hash-set! *latlon* (car p) (cons (cadr p) (caddr p))))) places)
  (for-each (lambda (n) (hash-set! *neighbours* (car n) (cdr n))) neighbours)
  (when tau (set! *tau* tau)) (when hold (set! *hold* hold))
  (set! *periods* (cond (clock   (apply set-clock-horizon! clock))
                        (horizon (set-daily-horizon! (car horizon) (cdr horizon)))
                        (else    periods)))
  (mkcells!)
  (for-each (lambda (s) (apply set-period-span! s)) spans)
  ;; every period has a place on the clock. Declared nothing: the periods lie
  ;; from today at the stated length (standing-partition). A declared partition
  ;; names every period — one left off the clock is a fixture's slip, and the
  ;; windows read against it would be guesses, so it is refused here.
  (unless (or clock horizon)
    (if (null? spans)
        (for-each (lambda (t sp) (set-period-span! t (car sp) (cdr sp)))
                  *periods* (standing-partition (length *periods*)))
        (let ((off (filter (lambda (t) (not (car (period-span t)))) *periods*)))
          (unless (null? off)
            (error "a declared partition names every period; these have no span:" off)))))
  (for-each (lambda (r) (hash-set! *stretch* (car r) (cdr r))) stretches)
  (when templates (set-templates! templates))
  (set! *workers* workers) (set! *riders* riders) (set! *mode-recipes* mode-recipes)
  (set! *resource-suppliers* resource-suppliers)
  (set! *movable* movable) (set! *storable* storable) (set! *stationary* stationary)
  ;; the containment tree, kept for the solve: a `within` fragility asks it, at
  ;; barrier-building time, which places lie under the scope that holds the limit
  (set! *spatial-things* spatial-things)
  (for-each (lambda (st)                     ; coordinates and altitude from SpatialThing
              (let ((la (spatial-thing-lat st)) (lo (spatial-thing-long st)) (z (spatial-thing-alt st)))
                (when (and la lo) (hash-set! *latlon* (spatial-thing-id st) (cons la lo)))
                (when (number? z) (hash-set! *alt* (spatial-thing-id st) z))))
            spatial-things)
  (when commute-km (set! *commute-km* commute-km))
  (when tau-commute (set! *tau-commute* tau-commute))
  (when emp-mode (set! *emp-mode* emp-mode))
  *cells*)

;; ════════════════════════════════════════════════════════════════════════════
;; §6b — THE VOCABULARY OF A LOCATED KEY: specs and their owners, stretches,
;;       the dates a period covers. The observer ingest that reads records
;;       into the world through it is (playnet solve ingest).
;; ════════════════════════════════════════════════════════════════════════════

;; ── the dates a period covers ───────────────────────────────────────────────
;; `period-days` answers in WEEKDAYS, which is what a recurring window needs. A
;; one-off names calendar dates, so it needs the other reading of the same span.
(define (span-dates start end)
  "The \"YYYY-MM-DD\" dates a span touches, in order."
  (if (not start) '()
      (let* ((s (iso->epoch start))
             (e (iso->epoch end))
               ;; A bare end DATE is inclusive — `set-period-span! t d d` is one
               ;; whole day, which is the reading period-hours already takes. An
               ;; explicit midnight is the other thing: "…T00:00" closes the date
               ;; before it rather than opening a new one.
             (e* (if (and (> e s) (eqv? 0 (iso-time-of end))) (- e 86400) e)))
        (let loop ((d s) (acc '()))
          (if (> d e*) (reverse acc)
              (loop (+ d 86400) (cons (epoch->iso d) acc)))))))

(define (period-dates t)
  "The dates period T touches, in order. Empty when T has no span."
  (let ((sp (period-span t))) (span-dates (car sp) (cdr sp))))

;; ── A STATEMENT ABOUT A STRETCH STAYS ONE STATEMENT ──────────────────────────
(define (stretch-of g) (hash-ref *stretch* g (list g)))

;; the stretch's balance: what carried in, was made, was drawn, carried out —
;; less the floor the stretch must hold
(define (stretch-init g)
  (- (fold + 0.0 (map (lambda (k) (hash-ref *init* k 0.0)) (stretch-of g)))
     (hash-ref *stretch-floor* g 0.0)))

(define (merge-coeffs cs)                ; sum by column; an arc and its mirror cancel
  (let ((h (make-hash-table)))
    (for-each (lambda (ic) (hash-set! h (car ic) (+ (hash-ref h (car ic) 0.0) (cdr ic)))) cs)
    (filter (lambda (ic) (> (abs (cdr ic)) 1e-12)) (hash-map->list cons h))))

(define (key-good k) (let ((h (string-index k #\#))) (and h (substring k 0 h))))

;; "spec#place@period" → "spec"; a bare spec is itself. THE split of the
;; engine's located-good key, read wherever a located row is shown per spec.
(define (key-spec k) (or (key-good k) k))

;; ── a good FOR ONE CITIZEN: "spec~aid" ───────────────────────────────────
;; A want a citizen states for themselves is felt on the citizen's OWN
;; delivered good, so a padded quantity moves only the padder's term
;; (truth-telling.md, "the path to dominance at scale"). The owned good is
;; the spec's name with the owner's AID after "~" — the same shape as a
;; per-person nutrient floor ("iron|ada"), on a separator no other key uses
;; ("|" is a service prefix and a nutrient's person, "#" a place, "@" a
;; period). A claim column (live.scm claim-recipes)
;; turns the scope's good into the citizen's; `spec-owner` reads the name
;; apart, `spec-base` is the good the scope makes.
(define %owner-sep #\~)

(define (spec-owner g)
  "\"spec~aid\" → (spec . aid); a good nobody owns → #f."
  (let ((i (string-index g %owner-sep)))
    (and i (cons (substring g 0 i) (substring g (+ i 1))))))

(define (spec-base g) (let ((o (spec-owner g))) (if o (car o) g)))

(define (produced-spec-set)                 ; specs some template outputs OR relocates ⇒ GOODS; the rest are raw
  ;; a relocation's dropoff produces the good at its arrival cell exactly as an
  ;; output does — `good-keys` reads the column's + coefficient either way — so
  ;; the stock routing reads it the same: a kept stock is starting INVENTORY.
  ;; Read as outputs alone, a stocked good the ground keeps was routed to *cap*
  ;; as a raw while its balance was emitted as a good's, opening at *init* 0 —
  ;; the pin every grow at the first band sat on (Berlin's farm, SF's and
  ;; Oakland's gardens: land and water rows nothing fed).
  (let ((s (make-hash-table)))
    (for-each (lambda (tpl)
                (for-each (lambda (oq) (hash-set! s (car oq) #t)) (proc-outputs tpl))
                (for-each (lambda (sp) (hash-set! s sp #t)) (proc-relocated tpl)))
              *templates*)
    (hash-for-each (lambda (k v) (hash-set! s k #t)) *never-raw*)   ; never-raw specs are GOODS too (balanced ≥0, stock→init), never free raws
    s))

(define (raw-spec-set)                       ; template INPUT specs that SKIP the ≥0 balance (fail-closed)
  (let ((produced (produced-spec-set)) (s (make-hash-table)))
    (for-each (lambda (tpl) (for-each (lambda (iq)
                (when (spec-skips-balance? (car iq) (hash-ref produced (car iq) #f)) (hash-set! s (car iq) #t)))
                                      (proc-inputs tpl))) *templates*)
    s))

;; ════════════════════════════════════════════════════════════════════════════
;; §7 — THE DISCRETE LAYER: minimum-batch processes (run at ≥MBQ or not at all)
;; ════════════════════════════════════════════════════════════════════════════
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

;; What a column ran at, whether it stayed a variable or became a fact.
(define (col-value x idx key)
  (or (col-fixed key)
      (let ((j (hash-ref idx key #f))) (if j (vector-ref x j) 0.0))))

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
;;                       out, solve. `located-solve` for one world; engine/robust.scm
;;                       supplies the extensive form.
(define *discrete-key?* (make-parameter (lambda (k) #t)))
(define *discrete-program* (make-parameter (lambda () (located-solve))))
(define (batch-keys)
  (hash-clear! *mbq-relaxed*)
  (set! *config* 'all)
  (filter-map (lambda (c) (and (mbq-of (col-key c)) ((*discrete-key?*) (col-key c)) (col-key c))) (build-columns)))
(define (whole-keys)                       ; the columns a whole count decides, in THIS build
  (filter-map (lambda (c) (and (whole-col? (col-key c)) ((*discrete-key?*) (col-key c)) (col-key c))) (build-columns)))
;; The search's tables, as one value — so an assembly that must `reset!` while
;; building (one block per scenario) can put them back before it builds.
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
;; ════════════════════════════════════════════════════════════════════════════
;; §8 — WHO WORKS WHICH CELL: read off the solution, not computed after it
;; ════════════════════════════════════════════════════════════════════════════
;; There is no assignment STAGE. A worker is a supplier bundle: one `bar` capping
;; their offered hours and, when they are labour rather than a means, one `qc`
;; EMP congestion tension — ρ/(h_w·H) per worker, so the fairness is scale-free
;; fractional utilisation. Both live in the same program as everything else
;; (see the *supplier-bundles* section of build-located), so the assignment is
;; the worker-column levels of the ordinary solve and inherits the ordinary
;; certificate. `*emp-mode*` picks the reading of "equal": 'total equalises each
;; worker's total burden, 'pool their share within each (skill, cell) pool.
;; Exercised by tests/solve/test-emp-modes.scm.
;;
;; A SECOND implementation used to live here — `assign-emp`, water-filling each
;; cell's hours across a roster inside 30 fixed sweeps. It was reachable only
;; from a demo, covered by no test, and contradicted by Playnet §EMP in the same
;; repository: "who works which slot is read off the solution … not a separate
;; stage". It also under-covered in silence: water-fill clamps each worker at
;; their remaining capacity, so when the roster could not staff the plan the
;; bisection simply returned a short assignment with no signal — a shortfall
;; reported as an answer. The in-program path cannot do that, because a worker's
;; hours are a barrier and a plan that needs more than exists is infeasible, with
;; a violation quantity attached. Deleted rather than certified: the general
;; mechanism already expressed it, which is the whole reason it was redundant.

;; ════════════════════════════════════════════════════════════════════════════
;; §10 — FEDERATED DECOMPOSED SOLVE: scopes solved in parallel (C + OpenMP),
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
;; (engine/federation-oracle.scm): forms+prox flattened to CSR once, the Scheme forms
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

;; The library's default backend is the READABLE reference — `native`, the Scheme
;; interior-point the C kernel is checked against. It had been set here by the
;; demo script's own scaffolding, unconditionally, since the first solve, and
;; every loader of the engine inherited it without knowing; when the demo moved
;; out (demo.scm) the default silently fell back to `auto`, which reaches for
;; OSQP where none is installed and returns a phase-I point where `native`
;; raises. Stated as what it is: a library default. A caller chooses per solve
;; (plan-scope passes #:backend 'native-c; the tests name theirs).
(set-backend! 'native)

;; a solve read as a list — (x t-final … ) — for the studies that compare
;; backends or sweep a parameter and want the whole return in one value
(define (solve* forms lf x0 . ts)
  (call-with-values (lambda () (apply solve-native forms lf x0 ts)) list))

;; §9 — the self-test, the worked scenarios and the scale benchmarks — is a
;; script, and lives in demo.scm. Run it with:
;;   guile -L module module/playnet/deprecated/planner/attic/demo.scm
