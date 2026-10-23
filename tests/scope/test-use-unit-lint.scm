;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-use-unit-lint.scm — a draw and its capacity, denominated the same way.
;;;
;;; A `use` states two things: HOW MANY are engaged (resourceQuantity) and FOR
;;; HOW LONG (effortQuantity). Below compile-process the solver is unit-free —
;;; `mqty` takes a measure's number and drops its unit — so a wrong denomination
;;; still compiles, still solves, and is silently off by the length of a period.
;;;
;;; WHY THIS LIVES HERE, AND NOT IN THE ENGINE. compile-process sees a flow and
;;; never a catalogue: a template is compiled before any specs are ingested. So
;;; the engine's own PLANNER_UNIT_LINT can only report what a single flow
;;; justifies. The catalogue states the other half — `defaultUnitOfResource` is
;;; what a thing is counted in — and holding the recipe store and the specs
;;; together, one phase later, is what makes the question decidable at all.
;;;
;;; Run from repo root:
;;;   guile --no-auto-compile -q -L module tests/scope/test-use-unit-lint.scm

(use-modules (playnet test harness))
(use-modules (playnet knowledge recipes beenius-wax) (playnet knowledge recipes berlin-transit) (playnet knowledge recipes cold-chain) (playnet knowledge recipes container) (playnet knowledge recipes currency) (playnet knowledge recipes federation) (playnet knowledge recipes food-surplus) (playnet knowledge recipes grow) (playnet knowledge recipes humisoil) (playnet knowledge recipes infrastructure) (playnet knowledge recipes meeting) (playnet knowledge recipes stone-paper) (playnet knowledge recipes transport) (playnet scope root) (playnet vf schemas) (srfi srfi-1))
(use-modules (goblins) (srfi srfi-1) (srfi srfi-13) (ice-9 format))
(use-modules ((playnet knowledge dsl vf-lint) #:select (recipe-seeders)))

;;; Every seeder in knowledge/recipes/ taking a recipe-store and nothing else. A
;;; name absent from the module simply does not run: this is a sweep, not a
;;; registry, and a renamed recipe must not turn it red.
(define %seeders
  '(seed-beenius-specs seed-beenius-wax-recipe seed-beenius-sticks-recipe
    seed-beenius-build-recipe seed-beenius-remelt-recipe
    seed-berlin-transit!
    seed-berlin-transit-haul-recipe seed-berlin-cargo-bike-recipe
    seed-cold-chain-specs seed-cold-chain-recipe
    seed-container-specs seed-currency-specs
    seed-comms-process-catalogue seed-compose-post-recipe seed-publish-recipe
    seed-compliance-process-catalogue seed-obtain-permit-recipe
    seed-renew-recipe seed-file-return-recipe seed-disclose-recipe
    seed-compliance-food-recipe seed-food-distribution-recipes
    seed-federation-specs seed-federation-recipes
    seed-food-surplus-donor-specs seed-food-surplus-recipient-specs
    seed-food-surplus-recipe seed-food-surplus-3step-recipe
    seed-grow-specs seed-grow-recipe
    seed-humisoil-specs seed-humisoil-recipe
    seed-infrastructure-recipes seed-meeting-recipe
    seed-stone-paper-specs seed-stone-paper-recipe seed-stone-paper-reclaim-recipe
    seed-stone-paper-bio-recipe seed-stone-paper-compost-recipe
    seed-transport-specs seed-transport-recipe))

(define %seeder-table (recipe-seeders))   ; (name . procedure), the tree as the registry
(define (seeder sym) (assq-ref %seeder-table sym))

(define vat (spawn-vat #:name "unit-lint"))
(define root (with-vat vat (spawn-scope-root "Unit Lint")))
(define rs (with-vat vat ($ root 'recipe-store)))

(define ran
  (with-vat vat
    (filter-map (lambda (sym)
                  (let ((f (seeder sym)))
                    (and f (begin (false-if-exception (f rs)) sym))))
                %seeders)))

(format #t "\n── ~a of ~a recipe seeders ran ──\n" (length ran) (length %seeders))

;;; ── the invariant ──────────────────────────────────────────────────────────
;;; A `use`'s coefficient and its spec's capacity must be denominated the same
;;; way. Both sides take the period's length in their own manner, and there is
;;; exactly one pairing where they fail to cancel.
;;;
;;; A spec counted in EACH is converted at ingest: cap = stock × the hours it
;;; stands available, in unit-hours. Its `use` may state a duration (`1 each` for
;;; `0.05 h` ⇒ 0.05 unit-hours) or omit one (`1 each` ⇒ held all period ⇒ ×the
;;; period's hours). Both land in unit-hours. Either is sayable.
;;;
;;; A spec counted in HOURS is a capacity ALREADY — `200 seat-hours of U-Bahn` is
;;; not two hundred U-Bahns — so ingest restricts it by the window's share and
;;; does NOT convert it (already-a-flow?). Its `use` must therefore state a
;;; DURATION. An undurated draw is multiplied by the period's length while the cap
;;; is not, and the plan is handed a day's worth of a service for every unit it
;;; asked for.
;;;
;;; That asymmetry is the whole check, and it needs both halves: the flow, which
;;; compile-process has, and the spec, which it does not.
;;;
;;; Note what is NOT checked, because it is not an error. resourceQuantity on a
;;; `use` is HOW MANY ARE ENGAGED — a multiplicity — and `1 each` of a service
;;; counted in seat-hours is the ordinary way to say "one seat". Comms channels
;;; instead draw `1 post-slot`, their spec's own unit, with no duration. Both
;;; forms are coherent and both cancel; VF constrains neither.
(use-modules ((playnet utils units) #:select (time-unit? %count-unit %effort-unit)))   ; the one reader of "is this a time?"
(define (unit-of m) (and m (measure-has-unit m)))

;;; ── the length a run takes, from either place it may be stated ──────────────
;;; A `use` says how many are engaged and for how long. Omitting the duration is
;;; fine — the PROCESS's own `has-duration` supplies it, and a means engaged for a
;;; run is engaged for the run's length (compile-process). What is NOT fine is
;;; stating it in NEITHER place: nothing has then said how long anything takes, the
;;; only length left in scope is the period's, and the plan becomes a function of the
;;; partition — refine a day into thirds and three times as many runs fit, each still
;;; yielding one output (tests/solve/test-untimed-use.scm measures
;;; both readings).
;;;
;;; So the check is over the PAIR, and it covers every `use` of a rationed means
;;; rather than only the time-denominated specs the old rule reached: a spec counted
;;; in `each` is just as capable of being drawn for an unstated length.
(define (process-hours rp)
  (let ((d (recipe-process-has-duration rp)))
    (and d (> (duration-has-numerical-value d) 0.0) (duration-has-numerical-value d))))

(define (finding f rp)
  "What is wrong with this `use` flow, or #f when it is well-formed."
  (let* ((spec-id (recipe-flow-resource-conforms-to f))
         (eff (recipe-flow-effort-quantity f))
         (eu (unit-of eff))
         (durated? (and eff (> (measure-has-numerical-value eff) 0.0) (time-unit? eu))))
    (and (not durated?)
         (not (and rp (process-hours rp)))
         (format #f "~a `use`s ~a for no stated length — neither the flow nor the process says how long a run takes, so the draw takes the PERIOD's length and the plan moves when the partition does"
                 (recipe-flow-recipe-input-of f) spec-id))))

(define findings
  (with-vat vat
    (delete-duplicates
     (append-map
      (lambda (r)
        (append-map
         (lambda (rp)
           ;; the flows are judged BESIDE their process, because the length a run
           ;; takes may be stated on either
           (let ((io ($ rs 'flows-for-process (recipe-process-id rp))))
             (filter-map (lambda (f) (and (eq? 'use (recipe-flow-action f)) (finding f rp)))
                         (append (car io) (cdr io)))))
         ($ rs 'get-process-chain (recipe-id r))))
      ($ rs 'all-recipes)))))

(define all-use
  (with-vat vat
    (filter (lambda (f) (eq? 'use (recipe-flow-action f)))
            (append-map (lambda (r)
                          (append-map (lambda (rp)
                                        (let ((io ($ rs 'flows-for-process (recipe-process-id rp))))
                                          (append (car io) (cdr io))))
                                      ($ rs 'get-process-chain (recipe-id r))))
                        ($ rs 'all-recipes)))))
;; What the sweep actually looked at. A green here is worth only its coverage:
;; the traversal walks `all-recipes`, so a seeder adding bare processes and flows
;; with no enclosing recipe contributes nothing, and says so in this number.
(format #t "  ~a recipes, ~a `use` flows examined\n"
        (length (with-vat vat ($ rs 'all-recipes))) (length all-use))
(for-each (lambda (l) (format #t "  ~a\n" l)) findings)

(check-pred "every `use` in the tree states how long a run takes"
            (null? findings))

;;; NEGATIVE CONTROL. A lint that cannot fire is not a green, it is a silence — and
;;; this one has been silent for the wrong reason before (its first form guarded a
;;; single live spec). So the rule is exercised against a flow that breaks it: a
;;; `use` with no effort, on a process with no duration, is the shape whose run count
;;; moves with the partition, and it must be reported.
(define bad-process (make-recipe-process #:id "rp-nolength" #:name "No length"))
(define bad-flow
  (make-recipe-flow #:id "f-bad" #:action 'use #:resource-conforms-to "spec-anything" #:resource-quantity (make-measure 1.0 %count-unit)
                    #:recipe-input-of "rp-nolength"))
(check-pred "…and the rule reports a `use` that states no length anywhere"
            (string? (finding bad-flow bad-process)))
(check-pred "…while a process duration alone satisfies it"
            (not (finding bad-flow
                          (make-recipe-process #:id "rp-timed" #:name "Timed"
                                               #:has-duration (make-duration 0.5 %effort-unit)))))
(check-pred "…and a duration on the flow alone likewise"
            (not (finding (make-recipe-flow #:id "f-ok" #:action 'use #:resource-conforms-to "spec-anything"
                                            #:resource-quantity (make-measure 1.0 %count-unit)
                                            #:effort-quantity (make-measure 0.25 %effort-unit)
                                            #:recipe-input-of "rp-nolength")
                          bad-process)))

;;; ── the same shape, one field over: `work` ─────────────────────────────────
;;; A `work` flow states its hours in effortQuantity. Nothing below reads
;;; resourceQuantity for labour, so hours written THERE are not a different
;;; denomination — they are not read at all. `eff` comes back #f, the skill
;;; compiles to 0.0 hours, and the process names a worker it never draws.
;;;
;;; compile-process turns a process's own duration into labour when
;;; skill-labours comes out EMPTY, which catches a work flow that is missing.
;;; It does not catch one in the wrong field: that lands present-and-zero, and
;;; present-and-zero suppresses the fallback. The wrong slot is quieter than no
;;; flow at all — a chain ran on volunteer hours it never asked for, met its
;;; demand, and reported a plan (food-surplus.scm, all four work flows).
(define (work-finding f)
  (let* ((eff (recipe-flow-effort-quantity f))
         (rq  (recipe-flow-resource-quantity f))
         (hrs (and eff (measure-has-numerical-value eff)))
         (rqv (and rq (measure-has-numerical-value rq))))
    (and (or (not hrs) (<= hrs 0.0))
         (format #f "~a `work`s ~a for no hours~a"
                 (recipe-flow-recipe-input-of f)
                 (or (recipe-flow-resource-conforms-to f) "general")
                 (if (and rqv (> rqv 0.0))
                     (format #f " — its ~a sits in resourceQuantity, which nothing reads for labour"
                             rqv)
                     "")))))

(define all-work
  (with-vat vat
    (filter (lambda (f) (eq? 'work (recipe-flow-action f)))
            (append-map (lambda (r)
                          (append-map (lambda (rp)
                                        (let ((io ($ rs 'flows-for-process (recipe-process-id rp))))
                                          (append (car io) (cdr io))))
                                      ($ rs 'get-process-chain (recipe-id r))))
                        ($ rs 'all-recipes)))))
(define work-findings (delete-duplicates (filter-map work-finding all-work)))
(format #t "  ~a `work` flows examined\n" (length all-work))
(for-each (lambda (l) (format #t "  ~a\n" l)) work-findings)

(check-pred "every `work` in the tree asks for its hours where labour is read"
            (null? work-findings))

;; NEGATIVE CONTROL, for the same reason as above: the rule is exercised
;; against the exact mistake it exists to catch — hours in resourceQuantity,
;; effortQuantity empty — and against the well-formed flow beside it.
(check-pred "…and the rule reports hours written into resourceQuantity"
            (string? (work-finding
                      (make-recipe-flow #:id "f-slot" #:action 'work #:resource-conforms-to "spec-hands"
                                        #:resource-quantity (make-measure 0.5 %effort-unit)
                                        #:recipe-input-of "rp-x"))))
(check-pred "…and reports a `work` flow with no hours at all"
            (string? (work-finding
                      (make-recipe-flow #:id "f-none" #:action 'work #:resource-conforms-to "spec-hands"
                                        #:recipe-input-of "rp-x"))))
(check-pred "…while hours in effortQuantity pass"
            (not (work-finding
                  (make-recipe-flow #:id "f-ok2" #:action 'work #:resource-conforms-to "spec-hands"
                                    #:effort-quantity (make-measure 0.5 %effort-unit)
                                    #:recipe-input-of "rp-x"))))

(test-summary!)
