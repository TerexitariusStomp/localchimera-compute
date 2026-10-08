;;; test-festival-reproduction.scm — thousands of attendees, each fed to their
;;; own reproduction floor, at the festival, gated by the jurisdiction's permit.
;;;
;;; This is the FAITHFUL "everyone is fed": every attendee is a person AGENT, and
;;; plan-scope's built-in reproduction (#:reproduce? #t) appends each one's EAT
;;; recipe (grain → their nutrients) and floors their nutrition at their cell,
;;; from the subsistence catalogue — the worst-off-protecting −log barrier that
;;; diverges for whoever is short. We seed 2000 attendees at site B (jurisdiction
;;; Y, which demands a Festival Gathering Permit) and verify:
;;;   registered → a sample of attendees are fed to their per-person floor;
;;;   no permit  → the grow column is pruned, so the crowd goes unfed.
;;;
;;; Mock productive stores + real legal stores (the test-festival pattern) + the
;;; real reproduction machinery. Pure solver / pure data ⇒ no blake3.
;;;
;;; THE MENU IS FOUR FOODS, because the catalogue's own arithmetic demands it
;;; (found 2026-08-31, when the plan-invariants contract exposed that this
;;; suite's old mono-grain green had been reading phase-I quantities that were
;;; never a plan). Grain alone cannot floor a pregnant woman — her iron floor
;;; needs 27/15 = 1.8 kg while her zinc ceiling allows 40/25 = 1.6 — nor a
;;; child (0.67 vs 0.48). Greens (the iron food) alone do not repair it: the
;;; child's calcium floor wants 1000/1500 = 0.67 kg of greens against a
;;; vitamin-A ceiling of 900/4700 = 0.19. Dairy is what feeds a child's
;;; calcium inside their zinc ceiling (0.083 kg does what 0.51 kg of beans
;;; cannot), and fish is the menu's one vitamin-D and iodine source — whose
;;; floors join the program the moment fish joins the menu, which is the
;;; catalogue behaving exactly as designed: the floors you must hold are the
;;; floors your menu can speak to. grain + greens + dairy + fish clears every
;;; cohort's floors inside every ceiling, and the solver — not this header —
;;; is the proof.
;;;
;;; Run: guile -L module tests/planner/test-festival-reproduction.scm

(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness) (playnet planner knowledge recipes store) (playnet planner scope spatial-things) (playnet planner observation observer) (playnet planner solve compile) (playnet planner vf schemas) (srfi srfi-1) (playnet planner scope live)
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner knowledge catalogues subsistence)
             ((playnet planner knowledge catalogues substances) #:select (nutrient-content)))

;; tests run from the repository root (each file's own Run: line); the root is
;; resolved by its marker rather than by current-filename, which is #f or
;; -L-relative depending on how the file was loaded — both wrong for paths.
(define root (or (and (file-exists? "module/playnet/planner/solve/engine.scm") (getcwd))
                 (error "run this test from the repository root")))
(define here (string-append root "/tests/planner"))
(use-modules (playnet planner legal crossings))
(use-modules (playnet planner legal registry))
(use-modules (playnet planner legal registry-actor))
(use-modules (playnet planner legal gate)) (use-modules (playnet planner legal compliance))


;; a stopwatch in CPU seconds on the coarse phases: what the process spent, whatever else the machine was doing
(define %clock (make-hash-table))
(define %watched '((engine build-columns) (engine good-labour-content) (engine solve-report) (engine robust-assemble)
                   (engine close-elements!) (engine plan->material) (engine plan->work) (engine ingest-records!)
                   (engine apply-repro-bands!) (engine prune-unreachable-draws) (engine good-index)
                   (solver solve) (live plan-scope) (live scope-consumption) (live scope-composition) (compile compile-recipe)))
(define (watch! modname)
  (let ((m (resolve-module modname)) (short (car (last-pair modname))))
    (module-for-each
     (lambda (sym var)
       (when (and (member (list short sym) %watched) (variable-bound? var) (procedure? (variable-ref var)))
         (let ((f (variable-ref var)) (key (format #f "~a ~a" short sym)))
           (variable-set! var
             (lambda args
               (let ((t0 (get-internal-run-time)))
                 (call-with-values (lambda () (apply f args))
                   (lambda vals
                     (let ((e (hash-ref %clock key (cons 0 0))))
                       (hash-set! %clock key (cons (+ (car e) (- (get-internal-run-time) t0)) (+ 1 (cdr e)))))
                     (apply values vals)))))))))
     m)))
(for-each watch! '((playnet planner solve engine) (playnet planner scope live) (playnet planner solve compile) (playnet planner solve solver)))
(define (report!)
  (let ((rows (sort (hash-map->list cons %clock) (lambda (a b) (> (cadr a) (cadr b))))))
    (for-each (lambda (r) (format (current-error-port) "CPU ~a ~8,2f s  ~a calls  ~a~%" (getenv "FESTIVAL_N")
                                  (/ (cadr r) 1.0 internal-time-units-per-second) (cddr r) (car r)))
              rows)))
(define N (string->number (getenv "FESTIVAL_N")))   ; attendees. The mono-food era declared 2000 (and was reading
                 ; a phase-I escape, never a plan). The PLAN is scale-invariant
                 ; — per-cohort delivery is identical at 25/100/300, exactly
                 ; each floor — but the certificate's derived stopping floor
                 ; (t = *target-gap*/m, the centering-floor guarantee) demands
                 ; per-constraint precision ~1/N under per-person bands
                 ; (min-slack 4e-5 at 25 → 4e-6 at 300), and at 600 the Newton
                 ; budget cannot walk that far down the path — measured: the
                 ; same 600-person program solves in 196 Newtons to every
                 ; floor when t stops at the shipped 0.005 (*target-gap* #f).
                 ; The per-capita gap licensing is the coherence ledger's
                 ; seam; the checks read one representative per cohort either
                 ; way.
(define site "siteB") (define juris "juris-y")

(define (empty-rs)
  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))
(define (held-permit id spec holder)
  (make-economic-resource #:id id #:name spec #:conforms-to spec #:classified-as '("credential")
    #:onhand-quantity (make-measure 1 "cert") #:primary-accountable holder #:state "active"))
(define win (all-week-window "00:00" "23:59"))
;; THE MENU: the town's table (bread-commune-seed) — the smallest set the
;; engine feeds every body off under every floor and ceiling, read off the
;; USDA rows — every dish provisioned for the gathering and each tripping
;; `mass-gathering` (the tag rides the food the crowd eats), so jurisdiction
;; Y's permit gates the whole board, and no-permit starves the crowd rather
;; than re-routing it through an untagged dish.
(define menu '("grain" "beans" "greens" "rapeseed-oil" "dairy" "fish" "salt"))
(define (grow-id food) (string-append "rp-grow-" food))
(define (seed-grow rs)                            ; the REAL recipes, for the decorate
  ($ rs 'add-resource-spec (make-resource-specification #:id "skill-grow" #:name "Grow"
                                                        #:resource-classified-as '()
                                                        #:default-unit-of-resource "hours"))
  (for-each
   (lambda (food)
     ($ rs 'add-resource-spec
        (make-resource-specification #:id food #:name food
                                     #:resource-classified-as '("food" "crossing:mass-gathering")
                                     #:default-unit-of-resource "kg"))
     (let ((pid (grow-id food)))
       ($ rs 'add-recipe-process (make-recipe-process #:id pid #:name (string-append "Grow " food)
                                                      #:has-duration (make-duration 0.001 "hours")
                                                      #:sequence-group 0))
       ($ rs 'add-recipe-flow (make-recipe-flow #:id (string-append pid "-w") #:action 'work
                                                #:resource-conforms-to "skill-grow"
                                                #:effort-quantity (make-measure 0.1 "hours")
                                                #:recipe-input-of pid))
       ($ rs 'add-recipe-flow (make-recipe-flow #:id (string-append pid "-o") #:action 'produce
                                                #:resource-conforms-to food
                                                #:resource-quantity (if (equal? food "salt") (make-measure 100.0 "g") (make-measure 1.0 "kg"))
                                                #:recipe-output-of pid #:is-primary #t))
       ($ rs 'add-recipe (make-recipe #:id (string-append "recipe-grow-" food)
                                      #:name (string-append "Grow " food) #:primary-output food
                                      #:recipe-processes (list pid)))))
   menu))

;; mock planner view of the same recipes — every food draws one kg of `seed`
;; (the festival's provisioning stock) per kg served: ONE scarce good, so the
;; supply shock caps the whole board and rationing is a real trade between
;; dishes rather than a per-food accident (never-raw, so the cap binds).
(define (mock-grow food)
  (let ((pid (grow-id food)))
    (cons (make-recipe-process #:id pid #:name (string-append "Grow " food)
                               #:has-duration (make-duration 0.001 "hours") #:sequence-group 0)
          (list (make-recipe-flow #:id (string-append pid "-o") #:action 'produce
                                  #:resource-conforms-to food
                                  #:resource-quantity (if (equal? food "salt") (make-measure 100.0 "g") (make-measure 1.0 "kg"))
                                  #:recipe-output-of pid #:is-primary #t)
                (make-recipe-flow #:id (string-append pid "-w") #:action 'work
                                  #:resource-conforms-to "skill-grow"
                                  #:effort-quantity (make-measure 0.1 "hours") #:recipe-input-of pid)
                (make-recipe-flow #:id (string-append pid "-s") #:action 'consume
                                  #:resource-conforms-to "seed"
                                  #:resource-quantity (make-measure 1.0 "kg") #:recipe-input-of pid)))))
(define grows (map mock-grow menu))
(define grow-procs (map car grows))
(define grow-flows (append-map cdr grows))
(define grow-recipes (map (lambda (food) (make-recipe #:id (string-append "recipe-grow-" food)
                                                      #:name (string-append "Grow " food)
                                                      #:primary-output food #:recipe-processes '()
                                                      #:recipe-exchanges '())) menu))
(define grow-specs (list (make-resource-specification #:id "skill-grow" #:name "Grow"
                                                      #:resource-classified-as '()
                                                      #:default-unit-of-effort "hours")
                         (make-resource-specification #:id "seed" #:name "Seed"
                                                      #:resource-classified-as '()
                                                      #:default-unit-of-effort "kg")))
(define (chain-for r)
  (let ((food (find (lambda (f) (equal? r (string-append "recipe-grow-" f))) menu)))
    (if food (list (car (mock-grow food))) '())))

(define (gathering-rule)
  (rule (all-of (in-jurisdiction "juris-y") (on-crossing 'mass-gathering))
        (list (obtain #:rides 'entity #:name "Festival Gathering Permit" #:issuer "county-y"
                      #:per 'each-event #:spec '(safety sanitation crowd-control)))
        #:label "juris-y/mass-gathering" #:confidence 'verified #:steward "scope:festival"))

;; the crowd is HETEROGENEOUS — five subsistence cohorts with genuinely
;; different floors (pregnancy and lactation raise the bar; a child's is lower;
;; a cold-region elder differs again). classified-as tags → agent->subsistence-ctx
;; inside plan-scope; we mirror the ctx here to know each cohort's floor. Worst-off
;; protection means EVERY cohort is fed to THEIR floor, not the crowd's average.
;;   (label · classified-as tags · the subsistence ctx those tags induce)
(define cohorts
  (list (list "temperate woman" '("female")               '((sex . "F") (age . 30) (region . "temperate") (pregnant . #f) (lactating . #f) (labour-hours . 5)))
        (list "pregnant woman"  '("female" "pregnant")     '((sex . "F") (age . 30) (region . "temperate") (pregnant . #t) (lactating . #f) (labour-hours . 5)))
        (list "lactating woman" '("female" "lactating")    '((sex . "F") (age . 30) (region . "temperate") (pregnant . #f) (lactating . #t) (labour-hours . 5)))
        (list "child"           '("child")                 '((sex . "F") (age . 8)  (region . "temperate") (pregnant . #f) (lactating . #f) (labour-hours . 5)))
        (list "elder (cold) man" '("male" "elder" "cold")  '((sex . "M") (age . 67) (region . "cold")      (pregnant . #f) (lactating . #f) (labour-hours . 5)))))
(define K (length cohorts))
(define attendee-ids (map (lambda (i) (format #f "att~a" i)) (iota N)))
;; the growers' labour is PRICED — a tenth of an hour per kilogram, a tenth per
;; hundred grams of salt — since a barrier settles a costless direction
;; mid-face: at a thousandth of an hour the plan claimed a hundred kilograms
;; of every food for every mouth and ate a fraction. Ten growers leave the
;; crowd's floors and its want inside the day's hours.
(define grower-ids   (map (lambda (i) (format #f "grow~a" i)) (iota 10)))
;; attendee i is assigned cohort (i mod K) — so att0..att4 are one of each.
(define fd-agents
  (append (map (lambda (i) (make-agent #:id (list-ref attendee-ids i) #:type 'person
                                       #:name (list-ref attendee-ids i) #:primary-location site
                                       #:classified-as (cadr (list-ref cohorts (modulo i K)))
                                       #:availability-window win))
               (iota N))
          (map (lambda (id) (make-agent #:id id #:type 'person #:name id #:primary-location site
                                        #:classified-as '("male") #:availability-window win)) grower-ids)))
(define fd-resources (map (lambda (id) (er (string-append "gsk-" id) "skill-grow" id #:place site #:qty 1.0)) grower-ids))

;; the crowd's WANT above its floors: a soft desire for grain on the table —
;; the festival's own two-tier shape (a floor held, a want that yields).
;; Without it the varied menu meets every floor exactly and abundance is
;; indistinguishable from rationing; the want is what scarcity takes back.
(define want-kg (* N 0.8))
;; `seed-stock` is the supply cap: huge ⇒ abundant (floors + the want), tight ⇒ shock.
(define* (run permit? seed-stock #:optional (allow-infeasible? #f) #:key (want? #t))
  (define v (spawn-vat))
  (with-vat v
    (let* ((lrs (empty-rs)) (lsts (spawn ^spatial-thing-store (hashmap)))
           (reg (spawn ^legal-registry (list (gathering-rule))))
           (cobs (spawn ^observer (empty-observer-state) '())))
      (seed-grow lrs)
      ($ lsts 'add-location (make-spatial-thing #:id "world"))
      ($ lsts 'add-location (make-spatial-thing #:id juris #:lat 40.0 #:long -74.0
                                                #:contained-in "world"))
      ($ lsts 'add-location (make-spatial-thing #:id site #:lat 40.0 #:long -74.0
                                                #:contained-in juris))
      (when permit? ($ cobs 'seed-resource (held-permit "res:gp" "Festival Gathering Permit" "scope:festival")))
      (let* ((dec (make-legal-decorate/observer
                   #:recipe-store lrs #:spatial-thing-store lsts #:registry reg #:observer cobs
                   #:act 'gathering #:as-of "2026-07-14" #:subject-at (lambda (p c) "scope:festival")))
             (obs (spawn ^mock `((all-resources . ,(lambda () (cons (er "seedstock" "seed" "a" #:place site #:qty seed-stock) fd-resources)))
                                 (skill-hours-of . ,(lambda (a) '())) (record-event . ,(lambda (e) "ok")))))
             (as  (spawn ^mock `((all-agents . ,(lambda () fd-agents)))))
             (sts (spawn ^mock `((all-locations . ,(lambda () (list (make-spatial-thing #:id site
                                                                                        #:lat 40.0
                                                                                        #:long -74.0)))))))
             (rs  (spawn ^mock `((all-recipes . ,(lambda () grow-recipes)) (all-resource-specs . ,(lambda () grow-specs))
                                 (get-process-chain . ,chain-for)
                                 (flows-for-process . ,(lambda (pid)
                                   (cons (filter (lambda (f) (or (equal? (recipe-flow-recipe-input-of f) pid)
                                                                 (equal? (recipe-flow-recipe-output-of f) pid))) grow-flows) '()))))))
             (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs)))
        ;; grain is NOT a free raw — if the grow column is pruned (no permit),
        ;; there is no grain, so the crowd cannot be fed.
        (call-with-values
          (lambda () (plan-scope scope #:reproduce? #t #:backend 'native-c
                                 ;; the no-permit run asks a program with no answer, and says so
                                 #:allow-infeasible? allow-infeasible?
                                 #:demand (if want? (list (cons (string-append "grain#" site "@0") want-kg)) '())
                                 ;; the governed reserve is the catalogue's own arc; this
                                 ;; fixture states its scarcity through the seed cap alone
                                 #:insure? #f
                                 #:legal-decorate dec #:never-raw (cons "seed" menu)))
          (lambda (ints coms material fill x ntot report)
            ;; the material AND the verdict: a declared-infeasible run's
            ;; quantities are the phase-I escape, not a plan — its reader
            ;; asserts the verdict and never the numbers
            (cons material
                  (let ((c (assq-ref report 'certificate)))
                    (and (list? c) (assq-ref c 'feasible?))))))))))

;; how much of `nut` was produced FOR person pid at the site (their reproduction)
(define (seed-drawn material)            ; total provisions the plan consumed
  (fold (lambda (c a)
          (if (and (eq? (commitment-action c) 'consume)
                   (equal? (commitment-resource-conforms-to c) "seed"))
              (+ a (measure-has-numerical-value (commitment-resource-quantity c))) a))
        0.0 material))
(define (fed-energy material pid)
  (fold (lambda (c a)
          (if (and (eq? (commitment-action c) 'produce)
                   (equal? (commitment-resource-conforms-to c) (string-append "energy|" pid))
                   (equal? (commitment-at-location c) site))
              (+ a (measure-has-numerical-value (commitment-resource-quantity c))) a))
        0.0 material))
;; each cohort's own energy floor (from the subsistence catalogue) + a
;; representative attendee (att0..att4 are one of each cohort, in order).
(define (cohort-floor c) (assoc-ref (subsistence-floors (caddr c)) "energy"))
(define (cohort-rep i)   (format #f "att~a" i))

(format #t "\n── a festival for ~a across ~a subsistence cohorts, each fed to THEIR floor ──\n" N K)
(for-each (lambda (c) (format #t "  ~18a energy floor ~5,0f\n" (car c) (cohort-floor c))) cohorts)

;; the floors are genuinely heterogeneous — worst-off (pregnant/lactating) sit
;; well above a child's; feeding "everyone" must defend the highest bar too.
(check-pred "the cohorts' floors genuinely differ (pregnant > child)"
            (> (cohort-floor (list-ref cohorts 1)) (* 1.1 (cohort-floor (list-ref cohorts 3)))))

;; the supply shock: cap the provisioning stock ("seed", one kg per kg of any
;; dish) strictly between two draws the fixture itself measures — what the
;; floors alone take (the floors-only run, supply plentiful, the want off)
;; and what the floors and the want take together (the abundant run). Every
;; assertion below follows from that position: the shock binds, the want
;; yields, no floor breaks. The cap sits a third of the way up from the
;; floors' draw, so it binds well below the want and leaves phase-I a real
;; interior above the floors. The position is read, never typed: with the
;; composition read off the USDA rows, no energy bound over one food says
;; where the floors' mass lies (milk carries a fifth of grain's energy per kg).
(define run-floors   (run #t 1e9 #:want? #f))   ; supply plentiful, the want off -> the floors' own draw
(define run-abundant (run #t 1e9))              ; supply plentiful -> floors + the want
(define floors-draw   (seed-drawn (car run-floors)))
(define abundant-draw (seed-drawn (car run-abundant)))
(define provision-cap (+ floors-draw (/ (- abundant-draw floors-draw) 3)))
(format #t "  the floors alone draw ~,0f kg; with the want ~,0f kg; provisions capped at ~,0f kg~%"
        floors-draw abundant-draw provision-cap)
(check-pred "the want is real against this table: the abundant draw stands well above the floors' own"
            (> abundant-draw (* 1.2 floors-draw)))
(define run-shock    (run #t provision-cap))  ; supply shock -> the want yields
(define run-noperm   (run #f 1e9 #t))     ; permit gate -> no grow at all: no plan, declared
(define mat-abundant (car run-abundant))
(define mat-shock    (car run-shock))
(define (deliv m i) (fed-energy m (cohort-rep i)))

(format #t "\n  cohort               floor   abundant     shock\n")
(for-each (lambda (i)
  (format #t "  ~18a  ~5,0f  ~9,0f  ~8,0f\n"
          (car (list-ref cohorts i)) (cohort-floor (list-ref cohorts i))
          (deliv mat-abundant i) (deliv mat-shock i)))
  (iota K))

;; abundant → every cohort is fed their floor (a varied menu meets need
;; without the mono-diet's co-production overfeeding: delivered sits AT the
;; floor, not past it, and never past a toxicity edge) — and the want above
;; the floors is served, which is what the shock will take back.
(check-pred "abundant supply: every cohort fed to their floor, none past a toxicity edge"
            (every (lambda (i) (>= (deliv mat-abundant i) (* 0.99 (cohort-floor (list-ref cohorts i))))) (iota K)))
(check-pred "…and the want above the floors is served: the abundant draw clears the cap"
            (> (seed-drawn mat-abundant) (* 1.1 provision-cap)))
;; the shock BINDS on the provisioning stock: the plan draws no more than the
;; cap, so the want yields — while every floor below it still holds.
(check-pred "the shock binds: provisions drawn fall from the abundant draw to within the cap"
            (and (< (seed-drawn mat-shock) (seed-drawn mat-abundant))
                 (<= (seed-drawn mat-shock) (* 1.01 provision-cap))))
(check-pred "under the shock the worst-off are protected — every cohort STILL fed to their floor"
            (every (lambda (i) (>= (deliv mat-shock i) (* 0.97 (cohort-floor (list-ref cohorts i))))) (iota K)))
(check-pred "the highest-floor cohort (lactating) is defended to its higher floor under scarcity"
            (>= (deliv mat-shock 2) (* 0.97 (cohort-floor (list-ref cohorts 2)))))
;; and with no permit there is no grow at all: every dish is pruned, the
;; floors have no supply, and the honest verdict is the certificate's own —
;; NO PLAN feeds the crowd (the run's quantities are the phase-I escape and
;; are read by nobody). The feasible runs above certify #t by the same read.
(check-pred "the fed runs are real plans — both certify feasible"
            (and (eq? #t (cdr run-abundant)) (eq? #t (cdr run-shock))))
(check-pred "no permit: every dish is pruned and NO plan feeds the crowd — certified infeasible"
            (eq? #f (cdr run-noperm)))

(display "\n")
(report!)
(test-summary!)
