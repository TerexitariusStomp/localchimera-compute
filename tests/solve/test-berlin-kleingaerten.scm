;;; test-berlin-kleingaerten.scm — what a tenure register is worth.
;;;
;;; Third in the Berlin series, and the control case for the other two.
;;;   test-berlin-festival      (Baumscheiben)        — ownership uniform, permission unrecorded
;;;   test-berlin-garden-notice (Gemeinschaftsgärten) — tenure decisive, recorded NOWHERE
;;;   this one                  (Kleingärten)         — tenure PUBLISHED, graded, per site
;;;
;;; Berlin's allotments dwarf both the others: 2,917 ha against 9.7 ha of plantable tree
;;; pit and 10.7 ha of mapped community garden — about 140× the two combined. 1,065
;;; sites, 71,382 parcels, mean parcel 409 m² (knowledge/berlin-kleingaerten.scm, from
;;; the official Kleingartenentwicklungsplan 2030 WFS, complete download 2026-08-07).
;;;
;;; THE QUESTION. The KEP grades every site by how secure its tenure is, from "dauerhaft
;;; gesichert" down to "bauliche Entwicklung" — earmarked for building. Roughly 82% of
;;; the area is durable, 18% (515 ha, 13,105 parcels) is not, and the city has already
;;; said which is which. So Berlin can plan its allotments with the tenure ladder in
;;; hand. What is that worth?
;;;
;;;   BLIND  — plan as if every site were equally at risk. This is not a strawman: it is
;;;            exactly the position the community gardens are in, because nobody has
;;;            collected their leases.
;;;   GRADED — plan against the KEP's own ordering.
;;;
;;; Both commit one season (first-stage), and both are then scored against the SAME true
;;; world — the graded one, because that is the world that exists. The gap is the value
;;; of the register.
;;;
;;; THE ANSWER IS "ALMOST NOTHING", AND THAT IS THE POINT. The register buys about 5 t a
;;; season across 2,917 ha — food for ~56 people, next to nothing. Not because tenure
;;; information is worthless, but because BERLIN'S ALLOTMENT STOCK IS ALREADY SECURE:
;;; 82% of it is durable by the city's own reckoning, so there is very little left to
;;; hedge and the plan can hardly go wrong. The KEP's protection is doing the work; the
;;; planning has almost nothing to add.
;;;
;;; Set beside the community gardens, that is the general law:
;;;   TENURE INFORMATION IS WORTH MOST WHERE TENURE IS WORST.
;;; A notice period was worth 3,513 kg on 4.9 ha of precarious garden — a large relative
;;; effect, because every one of those gardens can be taken. A full graded register is
;;; worth 5 t on 2,917 ha of mostly-secured allotment. So the case for going and
;;; collecting the community gardens' leases is not that registers are generically
;;; valuable — it is that those gardens are exactly where a register would pay.
;;;
;;; Honest about direction vs magnitude: the SIGN of the gap (graded ≥ blind in
;;; expectation) is structural. The tonnage is not — it rides on the [DRAFT] mapping
;;; from KEP category to loss probability, and on %severity.
;;;
;;; Run: guile -L module tests/solve/test-berlin-kleingaerten.scm

(use-modules (playnet test planner prelude)
             (playnet solve engine) (playnet solve plan)
             (playnet vf schemas) (playnet vf beyond scenario)
             (srfi srfi-1)
             (ice-9 format))
(use-modules (playnet knowledge worlds berlin-kleingaerten))

(define %place "berlin-kg")
;; a FLAT place, as in both companion tests: the harvest pools at one node so a single
;; reproduction floor can name it. (kleingarten-spatials in the knowledge file gives the
;; nested biosphere ⊃ germany ⊃ shed ⊃ place tree a bioregion-aware scope wants instead.)
(define spatials (list (make-spatial-thing #:id %place #:name "Berlin Kleingärten" #:lat 52.52
                                           #:long 13.40)))

;; UNITS: hectares and tonnes, not m² and kg. Berlin's allotment stock is 2.9e7 m²,
;; and carrying that through to a 1e8 kg demand gives the interior-point solve a
;; condition number it will not accept — it reports "no strictly-feasible point" for a
;; problem that is comfortably feasible. Scaling the whole model down by 10^4 (m²→ha,
;; kg→t) fixes it and reads better besides. The two companion tests are small enough
;; not to need this.
(define (ha k) (/ (kg-area k) 1e4))

;; THE SEASON'S LABOUR, from the register's own parcel count: 71,382 parcels, each
;; worked by its household for [DRAFT] ~132 h across the season, expressed in
;; thousand-hours. At [DRAFT] 3.5 kh/ha that tends 2,692 ha of the 2,917 ha that
;; exist — so the ground is genuinely scarce, and ~290 ha of the season has to be
;; spent OUTSIDE the 2,402 ha the KEP calls durable. Risk here is not optional; the
;; only question is which risk you take.
(define %h-per-parcel 132.0)
(define %crew-hours (/ (* *berlin-kg-parcels* %h-per-parcel) 1e3))   ; kh
(define %kh-per-ha 3.5)
(define %tendable (/ %crew-hours %kh-per-ha))                        ; ha

(define resources
  (cons (make-economic-resource #:id "crew" #:conforms-to "crew-hours" #:classified-as '()
          #:accounting-quantity (make-measure %crew-hours "kh") #:onhand-quantity (make-measure %crew-hours "kh")
          #:current-location %place)
        (kleingarten-resources #:place %place #:unit 'ha)))

;; [DRAFT] t/ha/season — the same 1.0 and 2.0 kg/m² the two companion tests use, so
;; the three stay comparable.
(define %crops '(("beans" . 10.0) ("salad" . 20.0)))
(define (grow-id crop k) (string-append "grow-" crop "-" (kg-id k)))

(define procs
  (append-map (lambda (k)
                (map (lambda (c) (make-recipe-process #:id (grow-id (car c) k)
                                   #:name (string-append "Grow " (car c) " on " (kg-name k))))
                     %crops))
              *berlin-kleingaerten*))

(define flows
  (append-map
    (lambda (k)
      (append-map
        (lambda (c)
          (let ((p (grow-id (car c) k)))
            (list (make-recipe-flow #:id (string-append p "-in") #:action 'consume #:resource-conforms-to (kg-spec k)
                    #:resource-quantity (make-measure 1.0 "ha") #:recipe-input-of p)
                  (make-recipe-flow #:id (string-append p "-h") #:action 'consume #:resource-conforms-to "crew-hours"
                    #:resource-quantity (make-measure %kh-per-ha "kh") #:recipe-input-of p)
                  (make-recipe-flow #:id (string-append p "-out") #:action 'produce #:resource-conforms-to "meal"
                    #:resource-quantity (make-measure (cdr c) "t") #:recipe-output-of p #:is-primary #t))))
        %crops))
    *berlin-kleingaerten*))

;; [DRAFT] 90 kg of fresh produce per person per season; a floor for 200,000 people,
;; in tonnes. The floor is a PARAMETER here, not a constant — §the tail, below, needs to
;; push it until it breaks.
(define %t-per-person 0.090)
(define %base-floor (* 200000.0 %t-per-person))
(define %demand (* 6.0 %base-floor))
(define (floors-at f) (list (cons (string-append "meal#" %place "@0") f)))
(define demand (list (cons (string-append "meal#" %place "@0") %demand)))

;; WEATHER — real, Berlin's own 1960–2023 ERA5 record (knowledge/berlin-derived.scm).
(define %weather
  `(("normal"  0.640625 ("beans" . 1.00) ("salad" . 1.00))
    ("drought" 0.187500 ("beans" . 0.75) ("salad" . 0.45))   ; [DRAFT] crop response
    ("flood"   0.171875 ("beans" . 0.96) ("salad" . 0.96))))

;; TENURE — one future per KEP category losing a slice of its ground, at that category's
;; own risk. GRADED reads the ladder (kg-risk); BLIND flattens it to the same total risk
;; spread evenly, which is what you are forced to assume when no register exists.
;;
;; SCALE is the sensitivity handle. The mapping from KEP category to a probability is
;; [DRAFT] judgment, so no single run of this test can be trusted on magnitude. Scaling
;; every rung together and re-running says which conclusions survive the guess and which
;; were artefacts of it (§sensitivity, below).
(define (risks-at scale) (map (lambda (k) (* scale (kg-risk k))) *berlin-kleingaerten*))
(define (tenure-set graded? scale)
  (let* ((rs (risks-at scale))
         (tot (fold + 0.0 rs))
         (flat (/ tot (length rs))))
    (cons (list "all-hold" (- 1.0 tot) #f)
          (map (lambda (k r) (list (string-append "lost-" (kg-id k))
                                   (if graded? r flat) k))
               *berlin-kleingaerten* rs))))

(define (weather-shocks w)
  (append-map (lambda (k)
                (map (lambda (c) (cons (grow-id (car c) k) (assoc-ref (cddr w) (car c))))
                     %crops))
              *berlin-kleingaerten*))

;; A loss event takes a SLICE of a category, not all of it. [DRAFT] 25%. Whole-category
;; wipeout is not a real event — a Senate reclassification moves some sites in a
;; category, and modelling it as all of them makes any serious food floor infeasible
;; for a trivial reason: 68% of Berlin's allotment ground is in one category, so
;; "lose category 1" is not a risk anyone can plan against, it is the end of the stock.
;; The season's labour is already in the ground either way, so the slice is a harvest
;; loss — the produce channel, as in both companion tests.
(define %severity 0.25)
(define (with-loss shocks k)
  (if (not k) shocks
      (append (remove (lambda (s) (member (car s) (map (lambda (c) (grow-id (car c) k)) %crops)))
                      shocks)
              (map (lambda (c) (cons (grow-id (car c) k)
                                     (* (- 1.0 %severity) (assoc-ref shocks (grow-id (car c) k)))))
                   %crops))))

(define (scenarios-for graded? scale)
  (append-map
    (lambda (w)
      (map (lambda (tn)
             (make-planning-scenario
               (string-append (car w) "/" (car tn)) #f (* (cadr w) (cadr tn))
               (with-loss (weather-shocks w) (caddr tn))
               (string-append (car w) " year, " (car tn))))
           (tenure-set graded? scale)))
    %weather))

(define %all-procs (map recipe-process-id procs))

;; a solve at a given floor; #f when the floor is unmeetable in some scenario
(define (try-plan scenarios floor)
  (catch #t
    (lambda ()
      (call-with-values
        (lambda () (plan-from-records resources '() spatials procs flows
                     #:scenarios scenarios #:first-stage-procs %all-procs
                     #:repro-floors (floors-at floor) #:demand demand #:per-agent? #f))
        (lambda (ints coms material fill cols x idx ntot report)
          (or (assoc-ref report 'first-stage-plan) '()))))
    (lambda _ #f)))
(define (plan-with scenarios) (try-plan scenarios %base-floor))

;; ── scoring: every plan judged against the TRUE world at the given scale ─────
(define (planted fs k)
  (fold + 0.0 (map (lambda (c) (or (assoc-ref fs (grow-id (car c) k)) 0.0)) %crops)))
(define (yield-if fs w lost)
  (fold + 0.0
    (append-map (lambda (k)
                  (map (lambda (c)
                         (* (or (assoc-ref fs (grow-id (car c) k)) 0.0)
                            (cdr c) (assoc-ref (cddr w) (car c))
                            (if (and lost (equal? (kg-id k) (kg-id lost)))
                                (- 1.0 %severity) 1.0)))
                       %crops))
                *berlin-kleingaerten*)))
(define* (expected-yield fs #:optional (scale 1.0))
  (fold + 0.0
    (append-map (lambda (w)
                  (map (lambda (tn) (* (cadr w) (cadr tn) (yield-if fs w (caddr tn))))
                       (tenure-set #t scale)))
                %weather)))
(define (worst-yield fs)                     ; the tail: min over every future
  (fold min 1e18
    (append-map (lambda (w) (map (lambda (tn) (yield-if fs w (caddr tn))) (tenure-set #t 1.0)))
                %weather)))
(define (at-risk-planted fs)
  (fold + 0.0 (map (lambda (k) (if (kg-secured? k) 0.0 (planted fs k)))
                   *berlin-kleingaerten*)))
(define %worst-rungs '("baulich" "erholung" "bahn"))
(define (worst-rung-planted fs)
  (fold + 0.0 (map (lambda (k) (if (member (kg-id k) %worst-rungs) (planted fs k) 0.0))
                   *berlin-kleingaerten*)))

(define graded (plan-with (scenarios-for #t 1.0)))
(define blind  (plan-with (scenarios-for #f 1.0)))
(define gain (- (expected-yield graded) (expected-yield blind)))

;; ── FIX 1 · SENSITIVITY — does the conclusion survive the [DRAFT] mapping? ───
;; Re-run the whole comparison with every rung of the ladder scaled together. If the
;; sign of the gap flips under a plausible re-guess, the result is an artefact of the
;; guess and must not be quoted; if it holds, the DIRECTION is safe to quote and only
;; the magnitude stays [DRAFT].
(define %scales '(0.5 1.0 2.0))
(define (gain-at scale)
  (let ((g (plan-with (scenarios-for #t scale)))
        (b (plan-with (scenarios-for #f scale))))
    (and g b (list scale
                   (- (expected-yield g scale) (expected-yield b scale))
                   (expected-yield g scale)))))
(define sensitivity (filter identity (map gain-at %scales)))
(define all-positive? (every (lambda (r) (> (cadr r) 0.0)) sensitivity))
(define all-tiny? (every (lambda (r) (< (cadr r) (* 0.01 (caddr r)))) sensitivity))

;; ── FIX 2 · THE TAIL — and why the register cannot touch it ─────────────────
;; The earlier caveat was that GRADED optimizes the MEAN, so its worst case came out
;; marginally below BLIND's. Chasing that with a better objective would be the wrong
;; move, because of a structural fact worth stating plainly:
;;
;;   BLIND and GRADED face IDENTICAL scenario SHOCKS. They differ only in the
;;   PROBABILITIES attached to those shocks. A reproduction floor is a hard per-scenario
;;   constraint — it must hold in every future regardless of how likely that future is —
;;   so probabilities do not enter it at all.
;;
;; Therefore the largest floor a plan can defend is the SAME whether or not you have the
;; register. The ladder buys expected yield; only the FLOOR buys the tail. Bisecting for
;; the maximum defensible floor proves it rather than asserting it.
(define (max-floor scenarios)
  (let loop ((lo %base-floor) (hi (* 3.0 %base-floor)) (n 0))
    (if (or (> n 20) (< (- hi lo) 1.0)) lo
        (let ((mid (/ (+ lo hi) 2.0)))
          (if (try-plan scenarios mid) (loop mid hi (+ n 1)) (loop lo mid (+ n 1)))))))
(define max-floor-graded (max-floor (scenarios-for #t 1.0)))
(define max-floor-blind  (max-floor (scenarios-for #f 1.0)))
;; the plans you get when you actually ask for the tail
(define graded-tail (try-plan (scenarios-for #t 1.0) (* 0.999 max-floor-graded)))
(define blind-tail  (try-plan (scenarios-for #f 1.0) (* 0.999 max-floor-blind)))

;; ── FIX 3 · A SCALE GUARD, so the units trap cannot come back ───────────────
;; In m² and kg this model carries 1e7 areas against a 1e8 demand, and the
;; interior-point solve refuses it — "no strictly-feasible point" for a comfortably
;; feasible problem. That is a conditioning failure wearing an infeasibility costume,
;; and it cost real debugging time. This check fails loudly if any magnitude in the
;; model drifts back out of a range the solver is happy with, instead of leaving a
;; caveat in prose for the next person to rediscover.
(define %magnitudes
  (append (map ha *berlin-kleingaerten*)
          (list %crew-hours %kh-per-ha %base-floor %demand)
          (map cdr %crops)))
(define %mag-max (fold max 0.0 %magnitudes))
(define %mag-min (fold min 1e18 (filter (lambda (m) (> m 0.0)) %magnitudes)))
(define %spread (/ %mag-max %mag-min))

(format #t "~%── Berlin's Kleingärten: ~a sites · ~,0f ha · ~a parcels (mean ~,0f m²) ──~%"
        *berlin-kg-sites* (/ (berlin-kg-total-area) 1e4) *berlin-kg-parcels*
        *berlin-kg-mean-parcel*)
(format #t "  the KEP 2030 ladder, by area:~%")
(for-each (lambda (k)
            (format #t "    ~a ~,0f ha (~,1f%%) · ~a parcels · loss risk ~,3f  ~a~%"
                    (if (kg-secured? k) "durable  " "at risk  ")
                    (ha k) (* 100 (/ (kg-area k) (berlin-kg-total-area)))
                    (kg-parcels k) (kg-risk k) (kg-name k)))
          *berlin-kleingaerten*)
(format #t "  durable ~,0f ha (~,1f%%) · at risk ~,0f ha (~,1f%%)~%"
        (/ (berlin-kg-secured-area) 1e4) (* 100 (/ (berlin-kg-secured-area) (berlin-kg-total-area)))
        (/ (berlin-kg-at-risk-area) 1e4) (* 100 (/ (berlin-kg-at-risk-area) (berlin-kg-total-area))))
(format #t "~%  the season tends ~,0f ha of ~,0f ha — ~,0f ha MUST come from at-risk ground~%~%"
        %tendable (/ (berlin-kg-total-area) 1e4)
        (max 0.0 (- %tendable (/ (berlin-kg-secured-area) 1e4))))

(format #t "  BLIND  (no register — every site assumed equally at risk):~%")
(format #t "    expected ~,0f t · worst ~,0f t · ~,0f ha at-risk (~,0f ha on the worst rungs)~%"
        (expected-yield blind) (worst-yield blind)
        (at-risk-planted blind) (worst-rung-planted blind))
(format #t "  GRADED (planning against the KEP's own ordering):~%")
(format #t "    expected ~,0f t · worst ~,0f t · ~,0f ha at-risk (~,0f ha on the worst rungs)~%"
        (expected-yield graded) (worst-yield graded)
        (at-risk-planted graded) (worst-rung-planted graded))
(format #t "~%  → THE VALUE OF THE REGISTER: ~,1f t a season = food for ~,0f people~%"
        gain (/ gain %t-per-person))
(format #t "    ~,3f%% of the harvest — near nothing, because 82%% of this stock is already~%"
        (* 100 (/ gain (expected-yield graded))))
(format #t "    durable. Tenure information is worth most where tenure is WORST.~%")

(format #t "~%── sensitivity: is that an artefact of the [DRAFT] risk mapping? ──~%")
(for-each (lambda (r)
            (format #t "    ladder ×~,1f → gain ~,1f t  (~,3f%% of harvest)~%"
                    (car r) (cadr r) (* 100 (/ (cadr r) (caddr r)))))
          sensitivity)
(format #t "    sign holds across the sweep: ~a · stays under 1%% of harvest: ~a~%"
        (if all-positive? "yes" "NO") (if all-tiny? "yes" "NO"))

(format #t "~%── the tail: what the register CANNOT do ──~%")
(format #t "    largest floor defensible WITH the ladder:    ~,0f t~%" max-floor-graded)
(format #t "    largest floor defensible WITHOUT it:         ~,0f t~%" max-floor-blind)
(format #t "    identical, because a floor is a hard per-scenario constraint and both~%")
(format #t "    plans face the same shocks — only the probabilities differ, and a floor~%")
(format #t "    never reads a probability. The ladder buys the MEAN; only the floor~%")
(format #t "    buys the TAIL.~%")
(format #t "    asking for the tail lifts the worst case ~,0f t → ~,0f t (+~,0f t)~%"
        (worst-yield graded) (worst-yield graded-tail)
        (- (worst-yield graded-tail) (worst-yield graded)))

(format #t "~%── scale guard ──~%")
(format #t "    magnitudes ~,2f … ~,0f (spread ~,0f×) — in ha/t, a range the solver accepts~%"
        %mag-min %mag-max %spread)

(format #t "~%── assertions ──~%")
(check "the KEP register is loaded — 1,065 sites, 2,917 ha, 71,382 parcels"
       (and (= *berlin-kg-sites* 1065) (= *berlin-kg-parcels* 71382)
            (< (abs (- (berlin-kg-total-area) 29180000.0)) 20000.0)))
(check "the two official registers cross-check to within 1.5% on area and parcels"
       (and (< (abs (- *berlin-kg-area* *berlin-kg-bestand-area*)) (* 0.015 *berlin-kg-area*))
            (< (abs (- *berlin-kg-parcels* *berlin-kg-bestand-parcels*)) (* 0.015 *berlin-kg-parcels*))))
(check "Kleingärten dwarf the other two candidates — >100× pits + community gardens"
       (> (berlin-kg-total-area) (* 100.0 (+ 97465.0 106558.0))))
(check "the city itself calls ~82% durable and ~18% not"
       (and (> (/ (berlin-kg-secured-area) (berlin-kg-total-area)) 0.80)
            (< (/ (berlin-kg-secured-area) (berlin-kg-total-area)) 0.84)))
(check "risk is unavoidable — the season outruns the durable ground"
       (> %tendable (/ (berlin-kg-secured-area) 1e4)))
(check "GRADED keeps more off the worst rungs than BLIND"
       (< (worst-rung-planted graded) (worst-rung-planted blind)))
(check "GRADED beats BLIND in the world that actually exists"
       (> gain 0.0))
;; FIX 1
(check "…and it does so at EVERY rung-scaling tried — the sign is not an artefact"
       (and (= (length sensitivity) (length %scales)) all-positive?))
(check "…while staying under 1% of harvest throughout — the smallness is not one either"
       all-tiny?)
;; FIX 2
(check "the tail is probability-free: the same floor is defensible with or without the ladder"
       (< (abs (- max-floor-graded max-floor-blind)) 1.0))
(check "asking for the tail actually lifts it — the floor is the instrument that works"
       (> (worst-yield graded-tail) (worst-yield graded)))
(check "both base plans still clear the base floor at their worst"
       (and (>= (worst-yield graded) (* 0.98 %base-floor))
            (>= (worst-yield blind) (* 0.98 %base-floor))))
;; FIX 3
(check "scale guard: every magnitude inside the band the solver accepts"
       (and (< %mag-max 1e6) (> %mag-min 1e-3) (< %spread 1e6)))
(check "27 futures drove each solve (3 weather × 9 tenure regimes)"
       (= (length (scenarios-for #t 1.0)) 27))

(check-done "  Tenure information is worth most where tenure is worst. Berlin's allotments are~%  82% durable, so reading the ladder adds almost nothing — and the ladder cannot touch~%  the tail at all; only the floor can. The notice period on the all-precarious~%  community gardens was worth 3,513 kg on 1/600th the ground.~%")
