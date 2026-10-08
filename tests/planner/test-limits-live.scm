;;; test-limits-live.scm — a planetary limit carried as a stock, on a LIVE scope.
;;;
;;; The migration proved as records (limit-migration-test) now runs through the
;;; real entry point: the tension registry — the governance actor that custodies
;;; the ratified catalogue — hands `plan-scope` its `eco-stocks` view, and the
;;; scope draws its nitrogen boundary as a LEVEL rather than a wall.
;;;
;;; Two views of one catalogue, and the registry serves both:
;;;   eco-policy  a limit as a wall the draw approaches — a fragility whose prior
;;;               only rises. Right where crossing is a commitment.
;;;   eco-stocks  a limit as a level the draw spends and labour rebuilds. Right
;;;               where the witnessed character says it returns.
;;; A limit is in exactly one: `migrate-limit` yields #f for an irreversible one,
;;; which `eco-policy` then carries as the fragility it is.
;;;
;;; What this closes: before it, `catalogue->stock-records` was a compiler with no
;;; live caller, so a scope's planetary limits could not actually be drawn down
;;; and rebuilt on the real path. Now #:limits carries them into plan-scope beside
;;; #:reproduce?, and a commune that spends its nitrogen headroom feeding people
;;; can spend labour getting it back.
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-limits-live.scm

(use-modules (playnet test scope))
(use-modules (playnet test harness) (playnet planner knowledge catalogues eco) (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1) (playnet planner scope live)
             (goblins) (goblins persistence-store memory)
             (srfi srfi-1) (ice-9 format))

(define SEASONS '(0 1 2 3))
(define PLACE "commons")

;; the registry's stock view of the ratified catalogue, placed at this commune
;; `^tension-registry` serves exactly this list as its `eco-stocks` message — the
;; governance-custodied way to obtain it. Called directly here so the test needs
;; no vat for the registry itself.
(define limits
  (migrated-limits *planetary-catalogue*
                   #:place PLACE #:period-years 1.0))

(define nitrogen (find (lambda (m) (equal? "nitrogen" (migrated-spec m))) limits))

(format #t "~%── the registry's two views of one ratified catalogue ──~%")
(format #t "  eco-stocks → ~a limit(s) carried as levels~%" (length limits))
(format #t "  nitrogen headroom = ~,1f ~a · nature returns ~,3f/season~%"
        (rstock-init (migrated-stock nitrogen))
        (rstock-unit (migrated-stock nitrogen))
        (migrated-rate nitrogen))

;; ── a commune that draws nitrogen to eat ─────────────────────────────────────
(define mem (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Commons")) mem))
;; A period here is a WEEK — the fixture's "season" — so Ada's 09:00–17:00 every
;; day is 56 h of land work a period, the labour these limits were sized on.
(use-modules ((playnet planner solve engine) #:select (set-period-length!)))
(set-period-length! 1.0 "week")
(define win (all-week-window "09:00" "17:00"))

(with-vat vat
  (let ((rs ($ scope 'recipe-store)) (obs ($ scope 'observer))
        (as ($ scope 'agent-store)) (sts ($ scope 'spatial-thing-store)))
    ($ sts 'add-location (make-spatial-thing #:id PLACE #:name "The commons" #:lat 40.0 #:long -74.0))
    (for-each (lambda (id nm u)
                ($ rs 'add-resource-spec (make-resource-specification #:id id #:name nm
                                                                      #:default-unit-of-resource u)))
              '("food" "nitrogen" "skill-land") '("Food" "Reactive N" "Land work") '("kg" "Tg N/yr" "hours"))
    ($ rs 'add-process-spec (make-process-specification #:id "ps" #:name "Land"))
    ;; FERTILISE — draws the boundary to make food
    ($ rs 'add-recipe-process (make-recipe-process #:id "fertilise" #:name "Fertilise"
                                                   #:process-conforms-to "ps"
                                                   #:has-duration (make-duration 0.5 "hours")
                                                   #:sequence-group 0))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id "fp" #:action 'produce
                                             #:resource-conforms-to "food"
                                             #:resource-quantity (make-measure 10.0 "kg")
                                             #:recipe-output-of "fertilise" #:is-primary #t))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id "fd" #:action 'consume
                                             #:resource-conforms-to "nitrogen"
                                             #:resource-quantity (make-measure 1.0 "Tg N/yr")
                                             #:recipe-input-of "fertilise"))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id "fw" #:action 'work
                                             #:resource-conforms-to "skill-land"
                                             #:effort-quantity (make-measure 0.5 "hours")
                                             #:recipe-input-of "fertilise"))
    ($ rs 'add-recipe (make-recipe #:id "r-f" #:name "Fertilise" #:primary-output "food"
                                   #:recipe-processes (list "fertilise")))
    ;; SCRUB — the commune's OWN removal recipe: its labour cost is its technology,
    ;; not something the planetary catalogue asserts for everyone.
    ($ rs 'add-recipe-process (make-recipe-process #:id "scrub" #:name "Effluent works"
                                                   #:process-conforms-to "ps"
                                                   #:has-duration (make-duration 4.0 "hours")
                                                   #:sequence-group 0))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id "sr" #:action 'produce
                                             #:resource-conforms-to "nitrogen"
                                             #:resource-quantity (make-measure 2.0 "Tg N/yr")
                                             #:recipe-output-of "scrub" #:is-primary #t))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id "sw" #:action 'work
                                             #:resource-conforms-to "skill-land"
                                             #:effort-quantity (make-measure 4.0 "hours")
                                             #:recipe-input-of "scrub"))
    ($ rs 'add-recipe (make-recipe #:id "r-s" #:name "Effluent works" #:primary-output "nitrogen"
                                   #:recipe-processes (list "scrub")))
    ($ as 'add-agent (make-agent #:id "ada" #:type 'person #:name "Ada" #:primary-location PLACE
                                 #:classified-as '() #:availability-window win))
    ($ obs 'seed-resource (make-economic-resource #:id "sk" #:name "Ada can work land" #:conforms-to "skill-land"
                            #:accounting-quantity (make-measure 40 "hours") #:onhand-quantity (make-measure 40 "hours") #:primary-accountable "ada"))
    (check-pred "commune seeded" #t)))

(define FOOD 150.0)
(define food-floors (map (lambda (t) (cons (format #f "food#~a@~a" PLACE t) FOOD)) SEASONS))
(define keep-90 (cons (format #f "nitrogen#~a@~a" PLACE (last SEASONS))
                      (* 0.9 (rstock-init (migrated-stock nitrogen)))))

(define (run floors)
  (with-vat vat
    (call-with-values
      (lambda () (plan-scope scope #:periods SEASONS #:limits limits
                             #:repro-floors floors #:reproduce? #f #:backend 'native-c))
      (lambda (ints coms material fill x ntot report)
        (let ((scrub-h (fold (lambda (c a)
                               (if (equal? "scrub" (commitment-input-of c))
                                   (+ a (or (and=> (commitment-effort-quantity c)
                                                   measure-has-numerical-value) 0))
                                   a))
                             0.0 coms)))
          (list scrub-h (assq-ref (assq-ref report 'certificate) 'feasible?)))))))

(define without (run food-floors))
(define with-t  (run (append food-floors (list keep-90))))

(format #t "~%── the commune, over four seasons ──~%")
(format #t "  feed everyone, no headroom target        : ~,1f h at the effluent works~%" (car without))
(format #t "  …and hold 90%% of the headroom by season 3: ~,1f h~%" (car with-t))
(format #t "~%  The first number is the point: nobody asked for it. A migrated limit keeps~%")
(format #t "  its profile's FIXED weight, so the boundary is felt at the optimum and the~%")
(format #t "  commune eases off — and pays to ease off — by its own arithmetic. Carried as~%")
(format #t "  a plain level it would ride the boundary to its edge and restore nothing.~%")

(check-pred "the registry serves a stock view of the ratified catalogue" (= 4 (length limits)))
(check-pred "nitrogen arrives with its level and nature's rate"
            (and (> (rstock-init (migrated-stock nitrogen)) 0) (> (migrated-rate nitrogen) 0)))
(check-pred "a live scope plans with its limits carried as levels"
            (eq? #t (cadr without)))
;; The migrated limit keeps its profile's fixed governance weight (planner.scm
;; *stock-frag-w*), so it is felt AT THE OPTIMUM rather than at the wall — the
;; property playnet.typ names as what lets a federation "ease off BEFORE the limit
;; by its own arithmetic rather than merely halt at it". A level carrying the
;; swept weight instead would spend the boundary to its edge and restore nothing.
(check-pred "the boundary is felt at the optimum — the commune restores UNASKED"
            (> (car without) 1.0))
(check-pred "an explicit headroom target does not reduce that"
            (>= (car with-t) (* 0.99 (car without))))
(check-pred "…and that recovering plan is a real plan" (eq? #t (cadr with-t)))

(format #t "~%")
(test-summary!)
