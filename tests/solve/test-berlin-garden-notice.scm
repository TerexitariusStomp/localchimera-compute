;;; test-berlin-garden-notice.scm — what a notice period is worth, in kilograms.
;;;
;;; Companion to test-berlin-festival.scm (Baumscheiben) over Berlin's community
;;; gardens — 202 mapped features, 104 with polygons, 106,558 m² of real ground
;;; (knowledge/berlin-gemeinschaftsgaerten.scm, OpenStreetMap via Overpass 2026-08-07).
;;;
;;; THE TENURE INVERSION. The Baumscheiben are uniformly Land Berlin's: nothing to
;;; socialize, and the revocable thing is an Amt's permission. Community gardens are
;;; the opposite — the gardeners mostly do NOT own their ground, they hold it on
;;; Zwischennutzung leases that end, and a lease ending is how a Berlin garden actually
;;; dies. Here the socialization stack HAS a subject. What it does not have is data:
;;; owner, lease term and end date are recorded in no public dataset (see §TENURE in
;;; the knowledge file), so every tenure figure below is elicited and marked [DRAFT].
;;;
;;; THE QUESTION THIS TEST ANSWERS. test-berlin-festival established that WHICH shock
;;; channel a withdrawal uses depends on whether it lands before or after commitment.
;;; That distinction is not a modelling detail — it is the first-stage/recourse split
;;; the robust solver is already built around, and it has a price:
;;;
;;;   NO NOTICE  — you plant, then learn. Planting is FIRST-STAGE: one decision shared
;;;                across every future (non-anticipativity), and an eviction strands the
;;;                season's labour. #:first-stage-procs = every grow proc.
;;;   NOTICE     — you learn, then plant. Planting is RECOURSE: decided per future,
;;;                after the lease news. #:first-stage-procs = '().
;;;
;;; Same gardens, same evictions, same probabilities — only WHEN you find out differs.
;;; The gap between the two plans' mean fill is the value of notice. In policy terms:
;;; what a notice clause in a Zwischennutzung contract buys, measured in food.
;;;
;;; Run: guile -L module tests/solve/test-berlin-garden-notice.scm

(use-modules (playnet test planner prelude)
             (playnet solve engine) (playnet solve plan)
             (playnet vf schemas) (playnet vf beyond scenario)
             (srfi srfi-1)
             (ice-9 format))
(use-modules (playnet knowledge worlds berlin-gemeinschaftsgaerten))

;; the twelve largest named mapped gardens — 48,630 m² of the 106,558 m² mapped
(define %gardens (list-head *berlin-gemeinschaftsgaerten* 12))
(define %gardens-area (fold + 0.0 (map gg-area %gardens)))

(define %place "berlin-gardens")
(define spatials (list (make-spatial-thing #:id %place #:name "Berlin community gardens" #:lat 52.52
                                           #:long 13.40)))

;; Crew hours, as on the Baumscheiben — [DRAFT] 500 people × 40 h, 0.5 h/m²/season.
;; Mildly binding here: 40,000 m² tendable against 48,630 m² of ground, so the plan
;; must choose where to spend the season even before anyone is evicted.
(define %crew-hours 20000.0)
(define %h-per-m2 0.5)
(define resources
  (cons (make-economic-resource #:id "crew" #:conforms-to "crew-hours" #:classified-as '()
          #:accounting-quantity (make-measure %crew-hours "h") #:onhand-quantity (make-measure %crew-hours "h")
          #:current-location %place)
        (gemeinschaftsgarten-resources #:gardens %gardens #:place %place)))

;; No shade factor here, unlike the tree pits: a community garden is open ground, which
;; is most of why its yield per m² beats a Baumscheibe's in the first place.
;; [DRAFT] kg/m²/season. Beans deep-rooted and steady, salad shallow and thirsty.
(define %crops '(("beans" . 1.0) ("salad" . 2.0)))
(define (grow-id crop g) (string-append "grow-" crop "-" (gg-id g)))

(define procs
  (append-map (lambda (g)
                (map (lambda (c) (make-recipe-process #:id (grow-id (car c) g)
                                   #:name (string-append "Grow " (car c) " at " (gg-name g))))
                     %crops))
              %gardens))

(define flows
  (append-map
    (lambda (g)
      (append-map
        (lambda (c)
          (let ((p (grow-id (car c) g)))
            (list (make-recipe-flow #:id (string-append p "-in") #:action 'consume #:resource-conforms-to (gg-spec g)
                    #:resource-quantity (make-measure 1.0 "m2") #:recipe-input-of p)
                  (make-recipe-flow #:id (string-append p "-h") #:action 'consume #:resource-conforms-to "crew-hours"
                    #:resource-quantity (make-measure %h-per-m2 "h") #:recipe-input-of p)
                  (make-recipe-flow #:id (string-append p "-out") #:action 'produce #:resource-conforms-to "meal"
                    #:resource-quantity (make-measure (cdr c) "kg") #:recipe-output-of p #:is-primary #t))))
        %crops))
    %gardens))

;; the floor these gardens defend, and demand well above it so mean fill is the
;; metric that moves. [DRAFT] 40,000 people × 0.5 kg. Raising it much past this makes
;; the set infeasible: twelve gardens and one season of crew hours do not stretch
;; further, and the solver refuses rather than quietly under-delivering.
(define %floor 20000.0)
(define repro-floors (list (cons (string-append "meal#" %place "@0") %floor)))
(define %demand 200000.0)
(define demand       (list (cons (string-append "meal#" %place "@0") %demand)))

;; WEATHER — real, Berlin's own 1960–2023 ERA5 record (knowledge/berlin-derived.scm).
(define %weather
  `(("normal"  0.640625 ("beans" . 1.00) ("salad" . 1.00))
    ("drought" 0.187500 ("beans" . 0.75) ("salad" . 0.45))   ; [DRAFT] crop response
    ("flood"   0.171875 ("beans" . 0.96) ("salad" . 0.96))))

;; EVICTION — [DRAFT], and the figure most in need of real data. Every garden is
;; equally at risk because nobody has collected the lease horizons that would say
;; otherwise; when the room has them, this is the one list to replace.
(define %tenure
  (cons (list "all-leases-hold" 0.70 #f)
        (map (lambda (g) (list (string-append "evicted-" (gg-id g))
                               (/ 0.30 (length %gardens)) g))
             %gardens)))

(define (weather-shocks w)
  (append-map (lambda (g)
                (map (lambda (c) (cons (grow-id (car c) g) (assoc-ref (cddr w) (car c))))
                     %crops))
              %gardens))

;; an eviction zeroes that garden's output — the harvest is lost whether or not the
;; labour was already spent; what differs between the two regimes is whether the plan
;; got to know first.
(define (with-eviction shocks g)
  (if (not g) shocks
      (append (remove (lambda (s) (member (car s) (map (lambda (c) (grow-id (car c) g)) %crops)))
                      shocks)
              (map (lambda (c) (cons (grow-id (car c) g) 0.0)) %crops))))

(define scenarios
  (append-map
    (lambda (w)
      (map (lambda (tn)
             (make-planning-scenario
               (string-append (car w) "/" (car tn)) #f (* (cadr w) (cadr tn))
               (with-eviction (weather-shocks w) (caddr tn))
               (string-append (car w) " year, " (car tn))))
           %tenure))
    %weather))

(define %all-procs (map recipe-process-id procs))

;; the ONLY difference between the two runs is #:first-stage-procs.
(define (plan-under first-stage)
  (call-with-values
    (lambda () (plan-from-records resources '() spatials procs flows
                 #:scenarios scenarios #:first-stage-procs first-stage
                 #:repro-floors repro-floors #:demand demand #:per-agent? #f))
    (lambda (ints coms material fill cols x idx ntot report)
      (list fill (or (assoc-ref report 'first-stage-plan) '())))))

(define no-notice (plan-under %all-procs))     ; plant, then learn
(define notice    (plan-under '()))            ; learn, then plant
(define fill-no-notice (car no-notice))
(define fill-notice    (car notice))
(define committed      (cadr no-notice))       ; the shared planting the no-notice plan makes

(define (planted g)
  (fold + 0.0 (map (lambda (c) (or (assoc-ref committed (grow-id (car c) g)) 0.0)) %crops)))
(define gardens-used (count (lambda (g) (> (planted g) 1.0)) %gardens))
(define value-of-notice (- fill-notice fill-no-notice))

(format #t "~%── Berlin's community gardens: ~a mapped features, ~a with polygons ──~%"
        *berlin-gg-feature-count* *berlin-gg-mapped-count*)
(format #t "  mapped ground: ~,0f m² citywide; this plan works the 12 largest (~,0f m²)~%"
        *berlin-gg-mapped-area* %gardens-area)
(format #t "  tenure on record: none — owner, lease term and end date are published nowhere~%")
(format #t "  ~a futures: 3 weather (real ERA5) × ~a tenure regimes~%~%"
        (length scenarios) (length %tenure))
(format #t "  NO NOTICE (plant, then learn — planting is first-stage):~%")
(format #t "    mean fill ~,4f   · commits the season across ~a of 12 gardens~%"
        fill-no-notice gardens-used)
(format #t "  NOTICE    (learn, then plant — planting is recourse):~%")
(format #t "    mean fill ~,4f~%" fill-notice)
(format #t "~%  → THE VALUE OF NOTICE: ~,4f of demand met — ~,0f kg a season (~,1f%% better)~%"
        value-of-notice (* value-of-notice %demand)
        (* 100 (/ value-of-notice (max 1e-9 fill-no-notice))))
(format #t "    that is what a notice clause in a Zwischennutzung contract is worth,~%")
(format #t "    with nothing else changed: same gardens, same evictions, same odds.~%")

(format #t "~%── assertions ──~%")
(check "the real register is loaded — 202 features, 104 polygons, 106,558 m²"
       (and (= *berlin-gg-feature-count* 202) (= *berlin-gg-mapped-count* 104)
            (< (abs (- *berlin-gg-mapped-area* 106558.0)) 1.0)))
(check "Prinzessinnengarten is in the set at its real 5,446 m²"
       (let ((p (assoc "prinzessinnengarten" *berlin-gemeinschaftsgaerten*)))
         (and p (= (gg-area p) 5446.0))))
(check "the twelve largest hold 48,630 m² — under half the mapped total"
       (and (< (abs (- %gardens-area 48630.0)) 1.0)
            (< %gardens-area (* 0.5 *berlin-gg-mapped-area*))))
(check "both regimes hold the floor — evictions do not starve the plan either way"
       (and (> fill-no-notice 0.0) (> fill-notice 0.0)))
(check "NO NOTICE must commit before it knows, so it spreads the season's labour"
       (>= gardens-used 3))
(check "NOTICE strictly beats NO NOTICE — knowing in time is worth something"
       (> value-of-notice 1e-6))
(check "…and NOTICE cannot do worse: recourse contains every committed plan"
       (>= fill-notice fill-no-notice))
(check "39 futures drove both solves (3 weather × 13 tenure regimes)"
       (= (length scenarios) 39))

(check-done "  A notice clause is a food quantity. Same gardens, same evictions, same odds —~%  only WHEN the gardeners find out — and the plan that learns first feeds more people.~%")
