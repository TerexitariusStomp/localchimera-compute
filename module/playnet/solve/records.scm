;;; module/playnet/solve/records.scm — the records pipeline: a scope's VF records become one world.
;;;
;;; `ingest-records!` takes the EconomicResource, Agent and SpatialThing
;;; records and the recipe processes and flows of a scope, with the keywords
;;; of a solve, and leaves the world (solve/world) declared and laid for
;;; `build-located`: per-agent labour, skills resolved from the agents' skill
;;; ERs (`vf-agent-skills`, the VF reading), hours from their availability
;;; windows, the modes among the recipes, the arc table. Every path to a plan
;;; runs through it: the deterministic door (solve/plan), each scenario block of
;;; the robust assembly (solve/robust), a commune's record in the federated
;;; solve (solve/federation-solve). `%world-keywords` names the keywords that
;;; DESCRIBE THE WORLD, the ones a scenario block must be given whole;
;;; `%held-back-world-keywords` the two it reads and a scenario does not take.

(define-module (playnet solve records)
  #:use-module (playnet solve world)
  #:use-module ((playnet solve keywords) #:select (solve-keywords-of))
  #:use-module (srfi srfi-1)
  #:use-module (playnet vf schemas)
  #:use-module (playnet vf formulas actions)
  #:use-module (playnet solve solver)
  #:use-module (playnet solve compile)
  #:use-module (playnet solve engine)
  #:use-module (playnet solve ingest)
  #:export (ingest-records! vf-agent-skills *metabolism-tstart* %world-keywords %held-back-world-keywords))

;; ── END-TO-END: real records → plan → VF work Commitments (Goblins-free) ─────
;; The whole pipeline as one pure call: compile the recipe records into templates,
;; ingest the EconomicResource/Agent/SpatialThing records (per-agent labour, skills
;; resolved from the agents' skill ERs, hours from their availabilityWindow), solve,
;; and emit VF work Commitments. The live service (live.scm) is just this with the
;; record lists gathered from the scope-root actors. Returns
;; (values commitments fill cols x idx). agent-skills defaults to the VF reading:
;; an agent's skills = the conforms-to of the skill ERs it is primaryAccountable for.
(define *metabolism-tstart* 0.03)   ; warm re-solve re-centres near the standing optimum (few Newton steps)
;; The VF reading of an agent's held skills: the resource-conforms-to of every
;; EconomicResource it is primaryAccountable for with positive on-hand WHOSE SPEC
;; IS LABOUR — LABOUR? the one predicate (formulas/actions labour?): the spec
;; states an effort unit or a recipe works it. Returns a (lambda (agent) →
;; (skill …)) closed over RESOURCES — the default `agent-skills`, and the base the
;; live layer expands through satisfied-by (effective-skills).
(define (vf-agent-skills resources labour?)
  ;; indexed once by the holder: the closure answers each agent — once per
  ;; labour row, person × period — off that agent's own resources, where a
  ;; scan of RESOURCES (O(crowd) once the reserves hold a body per person)
  ;; per call read the crowd once per row.
  (let ((by-holder (make-hash-table)))
    (for-each (lambda (r)
                (let ((who (economic-resource-primary-accountable r)))
                  (when who (hash-set! by-holder who (cons r (hash-ref by-holder who '()))))))
              resources)
    (lambda (a)
      (filter-map (lambda (r)
                    (and (or (labour? (economic-resource-conforms-to r))     ; a skill is a worked spec — a stock of water is not one
                             ;; …or a CREDENTIAL the person holds: a licence IS a skill
                             ;; (legal/gate.scm, skill-reqs), and the record says it is one
                             (member "credential" (or (economic-resource-classified-as r) '())))
                         (> (mqty (economic-resource-onhand-quantity r)) 0.0)
                         (economic-resource-conforms-to r)))
                  (reverse (hash-ref by-holder (agent-id a) '()))))))

;; POPULATE the located globals from records and STOP — the shared prelude of
;; plan-from-records, factored out so a caller that wants the built LP (not a
;; solve) can reuse the exact same setup: compile recipes, ingest stock/agents/
;; demand, restore willing?/legal/manners onto the fresh world, pour the travel table.
;; After this, `build-located` yields the scope's forms/cols/idx. Used by
;; plan-from-records (which then solves) and by the federation scope-record
;; builder (which hands the forms to solve-decomposed). Keep the keyword set in
;; sync with plan-from-records.
(define* (ingest-records! resources agents spatials recipe-procs recipe-flows
                          #:key (periods '(0)) (movable '()) (storable '()) (whole '()) (proc-frag '()) (tau 0.0) (hold 0.0)
                                (demand '()) (eco-caps '()) (reserve '()) (backend 'native-c)
                                (eco-frag '()) (eco-spec-frag #f) (eco-budget '()) (eco-container '()) (eco-couple '()) (couplings '()) (eco-prior '())
                                (stock-frag '())
                                (stock-prices '())       ; ((spec . hours/unit) …) — crystallized SNLT of what the plan only draws (stock-draw-costs)
                                (agent-hours agent-window-hours) (agent-skills #f)
                                (skill-dynamics #f)      ; ((worker skill law c0) …) — apply-skill-dynamics!
                                (agent-position (lambda (id t) #f)) (horizon #f)
                                ;; a DECLARED partition ((start . end) …), boundaries carrying an
                                ;; optional THH:MM — the band dial (set-clock-horizon! lays one out)
                                (period-spans #f)
                                ;; refine the partition at the roster's declared clock
                                ;; boundaries (ingest-located!); #f keeps each declared
                                ;; period whole, a window read as its hours within it
                                (refine-periods? #t)
                                (willing? #f) (legal-forbids? #f) (legal-decorate #f)
                                (per-agent? #t) (desire-weights '())
                                (certificates '())       ; ((aid . drawable-hours) …) — the bar over each citizen's claim columns
                                (arc-table '()) (arc-topology? #f) (manners '()) (never-raw '()) (raws '())
                                (resource-suppliers '()) (span-of '())
                                ;; reservation-aware free capacity: (resource-id → available | #f),
                                ;; a scope's live-registry read via live-availability — a registered
                                ;; resource ingests at its `available`, everything else at onhand
                                (live-avail #f)
                                (composition '())        ; the chemistry → element rows (element closure)
                                ;; the scope's ResourceSpecifications. Their keep-in-place flag is
                                ;; what makes a container a container, so a STORE recipe tiles
                                ;; along the time edge. Declared AFTER ingest, which declares a fresh world.
                                (specs '()))
  (define-values (mode-entries plain-procs) (part-mode-recipes recipe-procs recipe-flows))
  (set-templates! (compile-recipe plain-procs recipe-flows))
  (ingest-located! resources agents spatials
    #:per-agent? per-agent? #:periods periods #:movable movable #:storable storable #:whole whole #:proc-frag proc-frag
    #:tau tau #:hold hold #:demand demand #:eco-caps eco-caps #:reserve reserve
    #:eco-frag eco-frag #:eco-spec-frag eco-spec-frag #:eco-budget eco-budget #:eco-container eco-container #:eco-couple eco-couple #:couplings couplings #:eco-prior eco-prior #:stock-frag stock-frag
    #:desire-weights desire-weights #:certificates certificates #:never-raw never-raw #:raws raws
    #:agent-hours agent-hours #:agent-position agent-position #:horizon horizon #:period-spans period-spans
    #:refine-periods? refine-periods?
    #:resource-suppliers resource-suppliers #:composition composition #:span-of span-of
    #:mode-recipes mode-entries
    #:live-avail live-avail #:spec-units (specs->units specs)
    #:agent-skills (or agent-skills (vf-agent-skills resources (labour? recipe-flows specs))))
  ;; the skills' laws and where each worker's competence stands, after the
  ;; roster is declared and before the forms are built
  (when skill-dynamics (apply-skill-dynamics! skill-dynamics))
  (absorb-specs! specs)
  ;; what a drawn stock weighs: the caller's rollup, finite prices alone — an
  ;; unreachable spec (+inf) has no labour basis and reads its share instead
  (for-each (lambda (sp) (when (and (real? (cdr sp)) (> (cdr sp) 0.0) (< (cdr sp) +inf.0))
                           (hash-set! *stock-price* (car sp) (exact->inexact (cdr sp)))))
            stock-prices)
  (set! *willing?* (or willing? (lambda (w s c) #t)))
  (set-legal-decorate!   ; the engine's door: a setting, not a world table
    (cond (legal-decorate legal-decorate)
          (legal-forbids? (lambda (p c) (values (and (legal-forbids? p c) #t) 0.0 '())))
          (else (lambda (p c) (values #f 0.0 '())))))
  (for-each (lambda (kv)
              (case (car kv)
                ;; ── what this bag actually is ─────────────────────────────────
                ;; Not a costing vocabulary: `commute-hours` and `period-class`
                ;; are not manners of moving. It is a shed's MOVEMENT
                ;; CONFIGURATION: each manner is a production function for the same
                ;; relocation (walking spends labour-power alone, a bicycle adds a
                ;; tool's wear, the bus spends a driver's work and a communal
                ;; container's service), and each mode recipe carries its own costing,
                ;; so a trip's manner, the commute's (the walking mode's) and a bare
                ;; material move's (the car's) are read off the recipes. What stays
                ;; here is what no recipe states: when (`period-class` — rush-hour
                ;; transit is not 3am transit). A manner's typical pace is the table's
                ;; to say (`ingest-travel-times!`), so the bag holds none.
                ((commute-hours) (set! *commute-hours*   (cdr kv)))
                ;; whether this shed's PEOPLE are read as movers. A switch on the
                ;; movement model, like commute-hours — not a manner, and not a
                ;; roster: who exists comes from the agents, and workers->riders!
                ;; re-reads them. *riders* is therefore NOT settable from this bag;
                ;; a population restated in a config alist could disagree with the
                ;; agent store, and both halves supply Lab|, so disagreement would
                ;; be double-counting rather than an error.
                ((mobile-people) (set! *mobile-people?*   (cdr kv)))
                ((period-class)  (set! *period-class-of* (cdr kv)))))
            manners)
  ;; the scope's modes, found among its recipes above and declared with the world, are
  ;; known now, so this is where a shed's people can become mobile —
  ;; when it asks, with (mobile-people . #t) in its manners.
  (when *mobile-people?* (workers->riders! agents))
  (means->movers!)
  ;; a mover's rides are whole-count acts (mover-ride-templates); their processes
  ;; are named here, at ingest, so plan-from-records knows there is a tree to
  ;; search before a single column is built
  (when (riders?)
    (for-each (lambda (tpl) (when (proc-whole? tpl) (hash-set! *whole-procs* (proc-id tpl) #t)))
              (mover-ride-templates)))
  (ingest-travel-times! arc-table #:derive-topology? arc-topology?)
  (set-backend! backend)
  ;; the world the records became, in hand now and a value a holder may keep
  ;; and run another solve inside later (call-with-world)
  (current-world))

;; ── the WORLD a scenario ingests ────────────────────────────────────────────
;; A scenario block differs from the base solve in its SHOCKS and in nothing else,
;; so every option that DESCRIBES THE WORLD has to reach it. Re-listing those
;; options by hand at each layer is what silently lost #:manners and #:arc-table.
;; The keywords and their kinds stand once in (playnet solve keywords); these
;; two names are its `world` and `held` kinds, read by robust's forward and by
;; the test that holds this door's keywords to the table.
;;
;; The two HELD back are read here and not forwarded to a scenario's world. Each
;; switches on an engine mode the live solve has never run, and each moves plans
;; that stand today, so each waits on a decision of its own. Measured 2026-10-09,
;; each forwarded alone, after the skill reading became the worked spec's:
;;   #:skill-dynamics  practice laws that make a skill's competence a state carried from
;;                     period to period — test-dev-world: the heavy want and 38 of 40
;;                     hours go unplanned; test-dev-ledger: the issue's lead changes
;;                     (ann → box); the other two suites stand;
;;   #:composition     the chemistry's element rows — reaction-network-test: demand met
;;                     falls from 1.0 and R1 no longer makes the CO that R2 consumes;
;;                     test-bread-seed: the work per process differs; the other two stand.
;; Every live scope takes the robust path (scope/live.scm plan-scope always names a
;; future), so until decided these two reach no live solve, whatever the scope computes.
(define %world-keywords (solve-keywords-of 'world))
(define %held-back-world-keywords (solve-keywords-of 'held))
