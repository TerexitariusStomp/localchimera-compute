;;; test-household-week.scm — a week of housework, solved.
;;;
;;; test-household-recipe.scm checks that the recipes are SHAPED right. This one
;;; runs them: it hands the household's tasks to the convex planner as located
;;; columns and asks for a week of a three-person flat.
;;;
;;; §1 THE STOCKS ARE REAL. The first thing to establish about any plan is that it
;;;    cannot conjure what it spends. Five solves, each starving one input: the
;;;    draw never crosses the stock, and the output falls to what the stock allows
;;;    — 20 L of water buys at most 20/12 = 1.7 machine loads, and the plan washes
;;;    1.2. (It lands UNDER its ceilings, not on them: a want is soft here and this
;;;    interior solve leaves some on the table. The load-bearing claim is the
;;;    ceiling, which is never crossed.) Written down because the alternative — a
;;;    plan quietly treating an unmodelled input as free — looks exactly like a
;;;    good plan until you check.
;;;
;;; §2 THE WEEK IS PLANNABLE. Every task compiles into a column, every column runs,
;;;    and the bins go out — the part nobody costs. How FULLY each want is met is
;;;    the loose part, and the table prints delivered against wanted so the gap is
;;;    visible rather than implied.
;;;
;;; §3 WHAT THE DISHWASHER IS WORTH, as a controlled experiment: the same 14 loads,
;;;    solved twice, once with a machine in the flat and once without. Everything
;;;    else is held fixed, so the difference is the machine's.
;;;
;;; ── HOW TO READ A PLAN, and one way not to ──────────────────────────────────
;;; The MATERIAL commitments are the trustworthy account of what a plan does: what
;;; each process consumed and produced, which is bounded by the stocks and checked
;;; below. The WORK commitments are labour SUPPLIED by workers, and a worker's
;;; labour balance is an inequality — supply may exceed what the processes draw,
;;; and in this interior solve it does, by a lot. So hours here are computed from
;;; RUNS × the recipe's own labour coefficient, never read off the work
;;; commitments. (An earlier draft of this file did read them off, and reported a
;;; flat washing 201 loads of dishes on 20 litres of water.)
;;;
;;; NOT established: that the week's plan is the BEST allocation of a household's
;;; hours. A demand is a want, not a ceiling, and this interior solve overshoots
;;; the cheap wants. §3 is a CONTROLLED comparison for exactly that reason — one
;;; thing changes between the two solves, so the difference is attributable even
;;; though neither solve is tight.
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-household-week.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test scope))
(use-modules (playnet test planner prelude)
             (playnet solve engine)
             (playnet vf schemas) (playnet vf beyond schedules)
             (srfi srfi-1)
             (ice-9 format))

(use-modules (playnet knowledge recipes household))

(define PLACE "flat")
(define ALL-DAYS '(monday tuesday wednesday thursday friday saturday sunday))

;; The recipes are DATA (household.scm `household-recipe-defs`), so this harness —
;; which never spawns a vat — reads the same lists the store-seeding path pushes.
;; `rp-hh-living` is NOT among them, on purpose: cleaning consumes soil, so a
;; planner handed the process that MAKES soil will make dirt in order to clean it.
;; The week's mess is seeded below as stock, which is what it is.
(define all-defs (append household-recipe-defs household-waste-recipe-defs))
(define dish-defs
  (filter (lambda (d) (member (recipe-process-id (car d))
                              '("rp-hh-dishes-hand" "rp-hh-dishes-machine")))
          household-recipe-defs))

(define (win from to)
  (make-availability-window #f #f (list (make-day-schedule ALL-DAYS
                                          (list (make-time-range from to)))) #f))
(define agents (map (lambda (n) (make-agent #:id n #:type 'person #:name n #:primary-location PLACE
                                            #:classified-as '()
                                            #:availability-window (win "08:00" "20:00")))
                    '("ada" "bo" "kit")))
(define spatials (list (make-spatial-thing #:id PLACE #:name "The flat" #:lat 52.52 #:long 13.40)))

;; a household's stock: SPEC held at the flat by the household, Q UNIT of it
(define (hh id spec q unit) (er id spec "flat-hh" #:place PLACE #:qty q #:unit unit))

(define STORABLE
  '("spec-water" "spec-sp-electricity" "spec-hh-soap" "spec-hh-greywater"
    "spec-hh-soap-spent" "spec-hh-waste" "spec-hh-drain-solids" "spec-hh-soil-load"
    "spec-hh-dishes-soiled" "spec-hh-laundry-dirty" "spec-hh-laundry-clean"
    "spec-hh-laundry-dry" "spec-hh-laundry-ironed" "spec-hh-discards"
    "spec-hh-organics" "spec-hh-paper" "spec-hh-glass" "spec-hh-packaging"
    "spec-hh-residual" "spec-hh-deposit-bottles" "spec-eur"))

;;; ─── reading a plan: the MATERIAL side, and its CERTIFICATE ──────────────────
;; plan-from-records returns (intents work-commitments material-commitments …
;; report). Two of those values are load-bearing here: the material commitments
;; (what was consumed and produced — the stock-bounded account), and the report's
;; `certificate`, the solve's own verdict on itself. `feasible?` there is the
;; difference between a plan and a vector shaped like one, and every solve below
;; ASSERTS it — reading quantities off an uncertified point is how an interior
;; stall gets mistaken for a plan.
(define (solved-of . args)
  (let ((ls (filter (lambda (v) (and (pair? v) (commitment? (car v)))) args))
        (rep (find (lambda (v) (and (list? v) (pair? v) (pair? (car v))
                                    (assq 'certificate v))) args)))
    (cons (if (> (length ls) 1) (cadr ls) '())
          (and rep (assq-ref rep 'certificate)))))
(define (mat-of s) (car s))
(define (feasible? s) (eq? #t (assq-ref (or (cdr s) '()) 'feasible?)))
(define (mq c) (let ((m (commitment-resource-quantity c)))
                 (if m (measure-has-numerical-value m) 0.0)))
(define (drawn mat spec)          ; total of SPEC consumed across the plan
  (fold (lambda (c a) (if (and (eq? 'consume (commitment-action c))
                               (equal? spec (commitment-resource-conforms-to c)))
                          (+ a (mq c)) a))
        0.0 mat))
(define (made mat spec)           ; total of SPEC produced
  (fold (lambda (c a) (if (and (eq? 'produce (commitment-action c))
                               (equal? spec (commitment-resource-conforms-to c)))
                          (+ a (mq c)) a))
        0.0 mat))
(define (made-by mat spec pid)    ; …by one process, which is its RUN COUNT × yield
  (fold (lambda (c a) (if (and (eq? 'produce (commitment-action c))
                               (equal? spec (commitment-resource-conforms-to c))
                               (equal? pid (commitment-output-of c)))
                          (+ a (mq c)) a))
        0.0 mat))

;;; ─── §1 the stocks are real ──────────────────────────────────────────────────
;;; One demand — 14 loads of washed dishes — against a flat starved of one thing
;;; at a time. Every input a wash draws is a stock here, so every one of them can
;;; be made to bind, and the load count has to follow it exactly.
(define* (dish-solve #:key (water 4000.0) (soap 2.0) (soil 5.0) (soiled 14.0) (dishwasher 1.0))
  (call-with-values
    (lambda ()
      (plan-from-records
       (list (hh "water" "spec-water" water "liters")
             (hh "power" "spec-sp-electricity" 60.0 "kWh")
             (hh "soap" "spec-hh-soap" soap "kg")
             (hh "soiled" "spec-hh-dishes-soiled" soiled "load")
             (hh "soil" "spec-hh-soil-load" soil "kg")
             (hh "sink" "spec-hh-sink" 1.0 %count-unit)
             (hh "dw" "spec-hh-dishwasher" dishwasher %count-unit)
             (hh "sk" "skill-hh-domestic" 1.0 %count-unit))
       agents spatials (hh-defs-processes dish-defs) (hh-defs-flows dish-defs)
       #:horizon (cons "2026-03-02" 2) #:storable STORABLE
       #:agent-skills (lambda (a) '("skill-hh-domestic"))
       #:demand (list (cons (format #f "spec-hh-dishes-washed#~a@1" PLACE) 14.0))
       #:per-agent? #t #:backend 'native-c #:allow-infeasible? #t))
    solved-of))

(define (loads s) (made (mat-of s) "spec-hh-dishes-washed"))
(define (~= a b tol) (< (abs (- a b)) tol))
(define (pad s n) (string-append s (make-string (max 0 (- n (string-length s))) #\space)))

;; These binding solves used to certify `feasible? #f` at min-slack ≈ −2.3e-4 —
;; the same small exterior residual whatever bound, inherited from a phase-I that
;; ran its dense-slack-column program under the IC(0) preconditioner and handed
;; every solve a degraded start (solver.scm `phase1-decide`, fixed 2026-08-13:
;; phase-I always runs matrix-free Jacobi now). From a clean start the polish
;; lands at float noise, so the checks demand the full verdict.

(format #t "~%── §1 nothing is free: starve one input at a time, demand 14 loads ──~%")
(define base (dish-solve))
(format #t "    ~a~5,1f loads   water ~,0f L · soap ~,3f kg · soil ~,2f kg~%"
        (pad "well stocked" 20)
        (loads base) (drawn (mat-of base) "spec-water") (drawn (mat-of base) "spec-hh-soap")
        (drawn (mat-of base) "spec-hh-soil-load"))
(check "the well-stocked solve certifies feasible" (feasible? base))
(check "a well-stocked flat washes most of the fourteen" (> (loads base) 8.0))
(check "…and draws no more of anything than it holds"
       (and (<= (drawn (mat-of base) "spec-water") 4000.0)
            (<= (drawn (mat-of base) "spec-hh-soap") 2.0)
            (<= (drawn (mat-of base) "spec-hh-soil-load") 5.0)
            (<= (drawn (mat-of base) "spec-hh-dishes-soiled") 14.0)))

;; CEILING = what the stock physically allows, taking the THRIFTIEST recipe for
;; that input (the machine drinks 12 L a load, the sink 25). The plan may fall
;; short of a ceiling — a demand is a want, and this solve leaves some on the
;; table — but crossing one would mean the stock was never really there.
(define (starved label s spec stock ceiling)
  (let ((got (loads s)) (used (drawn (mat-of s) spec)))
    (format #t "    ~a~5,1f loads   ~a ~,3f of ~,3f  (ceiling ~,1f loads)~%"
            (pad label 20) got spec used stock ceiling)
    (format #t "      cert ~s~%" (cdr s))
    (check (format #f "~a — certified feasible" label) (feasible? s))
    (check (format #f "~a — the draw stays inside the stock" label) (<= used (* stock 1.0001)))
    (check (format #f "~a — the output stays under what the stock allows" label)
           (<= got (+ ceiling 0.05)))
    (check (format #f "~a — and the plan collapses toward it" label) (< got (* 0.6 (loads base))))))

;; 12 L is the machine's draw and 25 L the sink's, so 20 L allows at most 20/12.
(starved "water 20 L"     (dish-solve #:water 20.0)  "spec-water" 20.0 1.7)
;; 15 g a hand wash, 18 g a machine load → 30 g allows at most two
(starved "soap 30 g"      (dish-solve #:soap 0.03)   "spec-hh-soap" 0.03 2.0)
(starved "3 loads soiled" (dish-solve #:soiled 3.0)  "spec-hh-dishes-soiled" 3.0 3.0)
;; 0.25 kg of soil comes off each load — dishes cannot come out cleaner than the
;; dirt there was to take off them
(starved "soil 1.2 kg"    (dish-solve #:soil 1.2)    "spec-hh-soil-load" 1.2 4.8)
(starved "soil 0.5 kg"    (dish-solve #:soil 0.5)    "spec-hh-soil-load" 0.5 2.0)

;;; ─── §2 a week of the whole household ────────────────────────────────────────
(define (at g) (format #f "~a#~a@0" g PLACE))
(define week-demand
  (append
   (list (cons (at "spec-hh-dishes-washed")  14.0)
         (cons (at "spec-hh-floor-cleaned")  60.0)
         (cons (at "spec-hh-floor-washed")   40.0)
         (cons (at "spec-hh-surface-dusted") 30.0)
         (cons (at "spec-hh-bathroom-clean")  1.0)
         (cons (at "spec-hh-rooms-tidy")      4.0)
         (cons (at "spec-hh-laundry-dry")     5.0)
         (cons (at "spec-eur")                3.0))
   (map (lambda (row) (cons (at (string-append "spec-hh-" (car row) "-collected"))
                            (* 1.0 (cadr row))))
        *household-bin-runs*)))

;; the week's standing stocks, and the mess a week of living leaves —
;; `rp-hh-living`'s outputs, seeded rather than solved
(define week-stocks
  (append
   (list (hh "water" "spec-water" 4000.0 "liters")
         (hh "power" "spec-sp-electricity" 60.0 "kWh")
         (hh "soap" "spec-hh-soap" 2.0 "kg")
         (hh "soiled" "spec-hh-dishes-soiled" 14.0 "load")
         (hh "dirty" "spec-hh-laundry-dirty" 8.0 "kg")
         (hh "soil" "spec-hh-soil-load" 5.0 "kg")
         (hh "discard" "spec-hh-discards" 24.0 "kg")
         (hh "pfand" "spec-hh-deposit-bottles" 12.0 %count-unit))
   (map (lambda (row) (hh (string-append (car row) "-pool") (car row) (* 1.0 (cdr row)) "each"))
        (cons '("spec-hh-bin" . 4) (cons '("spec-hh-iron" . 1) *household-kit*)))
   (list (hh "sk" "skill-hh-domestic" 1.0 %count-unit))))

;; THE FULL SEVEN DAYS — and this horizon is itself a regression guard. Before
;; the phase-I preconditioner fix (solver.scm `phase1-decide`, 2026-08-13) the
;; verdict degraded with the horizon on this program: days 1–4 certified
;; feasible, day 5 flipped to #f (min-slack −0.047), days 6–7 grossly crossed
;; the 5 kg soil stock (6.09/6.86 drawn) — phase-I's line search stalled on the
;; garbage Newton directions an IC(0) factor produces for its dense slack
;; column, and every downstream mechanism amplified the exterior start. From a
;; clean phase-I start all horizons certify feasible at float-noise slack. The
;; `feasible?` assertion below is what keeps this from silently regressing.
(define week
  (call-with-values
    (lambda ()
      (plan-from-records
       week-stocks agents spatials
       (hh-defs-processes all-defs) (hh-defs-flows all-defs)
       #:horizon (cons "2026-03-02" 7) #:storable STORABLE
       #:agent-skills (lambda (a) '("skill-hh-domestic"))
       #:demand week-demand
       #:per-agent? #t #:backend 'native-c))
    solved-of))
(define week-mat (mat-of week))

(format #t "~%── §2 a week of a three-person flat: delivered against wanted ──~%")
(check "the week's solve certifies its own feasibility" (feasible? week))
(define week-wants
  `(("dishes washed (loads)" "spec-hh-dishes-washed"  14.0)
    ("floor vacuumed (m²)"   "spec-hh-floor-cleaned"  60.0)
    ("floor mopped (m²)"     "spec-hh-floor-washed"   40.0)
    ("surfaces dusted (m²)"  "spec-hh-surface-dusted" 30.0)
    ("bathrooms"             "spec-hh-bathroom-clean"  1.0)
    ("rooms tidied"          "spec-hh-rooms-tidy"      4.0)
    ("laundry dried (kg)"    "spec-hh-laundry-dry"     5.0)
    ("organics out (kg)"     "spec-hh-organics-collected" 10.0)
    ("paper out (kg)"        "spec-hh-paper-collected"     8.0)
    ("glass out (kg)"        "spec-hh-glass-collected"    10.0)
    ("packaging out (kg)"    "spec-hh-packaging-collected" 6.0)
    ("residual out (kg)"     "spec-hh-residual-collected" 10.0)
    ("euros returned"        "spec-eur"                    3.0)))
(for-each (lambda (g)
            (format #t "    ~a~7,1f / ~5,1f~%" (pad (car g) 26) (made week-mat (cadr g)) (caddr g)))
          week-wants)
(format #t "    ~a~7,1f L of 4000~%" (pad "water drawn" 26) (drawn week-mat "spec-water"))

;; Every want gets SOME delivery — the columns all exist and all run. How MUCH is
;; the loose part: this solve leaves most wants well short, which is a statement
;; about the objective's satiation, not about the recipes. §1 and §3 are where the
;; numbers are load-bearing.
(check "every task the household wants is actually run"
       (every (lambda (g) (> (made week-mat (cadr g)) 0.0)) week-wants))
(check "the bins go out — every stream"
       (every (lambda (row) (> (made week-mat (string-append "spec-hh-" (car row) "-collected")) 0.0))
              *household-bin-runs*))
(check "the deposit return happens, and pays in euros"
       (> (made week-mat "spec-eur") 0.0))
(format #t "    ~a~7,3f kg of 5.000~%" (pad "soil lifted" 26) (drawn week-mat "spec-hh-soil-load"))
(format #t "    ~a~7,3f kg of 2.000~%" (pad "soap used" 26) (drawn week-mat "spec-hh-soap"))
(format #t "    ~a~7,3f kg of 24.00~%" (pad "discards sorted" 26) (drawn week-mat "spec-hh-discards"))
(check "the week draws no more water than the flat holds"
       (<= (drawn week-mat "spec-water") 4000.0))
(check "…and no more soap"
       (<= (drawn week-mat "spec-hh-soap") 2.0))
(check "…and lifts no more soil than a week of living deposited"
       (<= (drawn week-mat "spec-hh-soil-load") 5.0))
(check "every gram of soil lifted leaves by the drain or the bin"
       (~= (drawn week-mat "spec-hh-soil-load")
           (+ (made week-mat "spec-hh-drain-solids") (made week-mat "spec-hh-waste"))
           1e-6))

;;; ─── §3 what the dishwasher is worth ─────────────────────────────────────────
;;; The same 14 loads, once with a machine and once without. Hours are computed
;;; from the MIX the plan chose × each recipe's own labour coefficient — the work
;;; commitments report supplied labour, not the labour these runs draw.
(define %hand-hours 0.5)     ; rp-hh-dishes-hand
(define %machine-hours 0.15) ; rp-hh-dishes-machine (loading and unloading)
(define (mix s)
  (let ((h (made-by (mat-of s) "spec-hh-dishes-washed" "rp-hh-dishes-hand"))
        (m (made-by (mat-of s) "spec-hh-dishes-washed" "rp-hh-dishes-machine")))
    (list h m (+ (* h %hand-hours) (* m %machine-hours)))))

(define with-machine (mix base))
(define by-hand      (mix (dish-solve #:dishwasher 1e-4)))

(format #t "~%── §3 the same 14 loads, with a machine and without ──~%")
(format #t "    with a dishwasher : ~4,1f by hand + ~4,1f by machine → ~,2f h~%"
        (car with-machine) (cadr with-machine) (caddr with-machine))
(format #t "    no dishwasher     : ~4,1f by hand + ~4,1f by machine → ~,2f h~%"
        (car by-hand) (cadr by-hand) (caddr by-hand))

(check "with no machine, every load is washed by hand"
       (< (cadr by-hand) 0.1))
(check "with one, the plan uses it — but not for everything"
       (and (> (cadr with-machine) 1.0) (> (car with-machine) 1.0)))
(check "and the washing-up costs less of somebody's evening"
       (< (caddr with-machine) (caddr by-hand)))
(format #t "~%    the machine is worth ~,2f h across the fourteen~%"
        (- (caddr by-hand) (caddr with-machine)))
;; It does not take all fourteen, and the reason is the `use` doing its job: one
;; dishwasher engaged for a 2 h cycle is a hard ceiling of ~6 loads in a 12 h band,
;; so the rest go in the sink. Drop the duration from that `use` and this ceiling
;; disappears — which is the whole argument for stating both quantities.
(check "the machine's own cycle time caps how much it can take"
       (< (cadr with-machine) 7.0))

(check-done "  Housework is plannable, the stocks bind, and the dishwasher's hours are a number.~%")
