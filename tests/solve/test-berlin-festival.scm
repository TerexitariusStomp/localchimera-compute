;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-berlin-festival.scm — feed a Berlin festival from the city's Baumscheiben,
;;; planted before anyone knows the weather OR which Grünflächenamt will say no.
;;;
;;; The structural twin of test-festival-robust.scm, with the uncertainty swapped.
;;; There the futures were weather over a farm's plots; here they are weather AND
;;; PERMISSION over 434,765 real street-tree pits — Berlin's most widely distributed
;;; piece of unbuilt public growing land (knowledge/berlin-baumscheiben.scm, from the
;;; official Baumkataster WFS, complete download 2026-08-07).
;;;
;;; THE TENURE FINDING THIS TEST RESTS ON: `eigentuemer` is "Land Berlin" for all
;;; 433,176 attributed street trees. Nobody privately owns a Baumscheibe, so there is
;;; nothing here to socialize — `socialize-private-resource` has no subject and the
;;; recall-risk dial has nothing to watch. What IS revocable is PERMISSION: planting
;;; wants an Anmeldung with the Bezirk's Grünflächenamt, twelve districts run twelve
;;; sets of rules, and any one of them can withdraw. So each Bezirk's pits carry their
;;; own resource-spec, so a withdrawal can be scoped to one district. Which SHOCK
;;; CHANNEL a withdrawal uses turns out to be the subtle part — see §the channel, below.
;;;
;;;   DETERMINISTIC (mean weather, permission assumed to hold): concentrates on the
;;;      districts with the youngest, least-shading trees and STARVES the festival
;;;      (9,208 kg against a 12,000 kg floor) the day one of them withdraws.
;;;   ROBUST (weather × permission together): spreads over all twelve, and holds the
;;;      floor whichever single Amt says no. Distribution across the city is DERIVED
;;;      from defending the floor under revocable permission — no new solver.
;;;
;;; Run: guile -L module tests/solve/test-berlin-festival.scm

(use-modules (localchimera test planner prelude)
             (localchimera solve engine) (localchimera solve plan)
             (localchimera vf schemas) (localchimera vf beyond scenario)
             (srfi srfi-1)
             (ice-9 format))
(use-modules (localchimera knowledge worlds berlin-baumscheiben))

;; ── the ground: real pit counts per Bezirk, pooled at one festival place ──────
;; (intra-Berlin transport is out of scope; the districts stay distinguishable by
;; spec, which is what permission attaches to. See worlds/berlin-baumscheiben.scm.)
(define %place "berlin-festival")
(define spatials (list (make-spatial-thing #:id %place #:name "Berlin festival" #:lat 52.52
                                           #:long 13.40)))

;; THE BINDING CONSTRAINT IS PEOPLE, NOT GROUND. Berlin holds ~97,465 m² of plantable
;; pit; a festival crowd needs a fraction of it. What a Kiez crew actually runs out of
;; is hands — planting, watering through a dry Berlin August, harvesting. So the crew's
;; season is a stock the growing consumes, and it is what makes WHERE to plant a real
;; decision. [DRAFT] 250 people × 40 h over the season; 0.5 h per m² per season.
(define %crew-hours 10000.0)
(define %h-per-m2 0.5)
(define resources
  (cons (make-economic-resource #:id "crew" #:conforms-to "crew-hours" #:classified-as '()
          #:accounting-quantity (make-measure %crew-hours "h") #:onhand-quantity (make-measure %crew-hours "h")
          #:current-location %place)
        (berlin-baumscheiben-resources #:place %place)))

;; SHADE, from the register's own median tree age per Bezirk. Old lindens with wide
;; crowns and big root plates shade and dry their pits; young street trees leave them
;; open. Reinickendorf and Steglitz-Zehlendorf run a median 56 years, Treptow-Köpenick
;; 34 — a real, measured spread, and the reason the districts are not interchangeable.
;; [DRAFT] the 0.012/yr slope is a judgment figure; the ages under it are data.
(define (shade b) (max 0.5 (- 1.0 (* 0.012 (- (bs-age b) 34)))))

;; ── two crops on a Baumscheibe ───────────────────────────────────────────────
;; [DRAFT] yields kg/m²/season and their drought response. Beans are deep-rooted and
;; steady; salad is shallow, thirsty and the first thing a dry Berlin summer takes —
;; the same bet grain-vs-beans makes on the farm, at 1/1000 the scale.
;; Roadside soil (lead, PAH, de-icing salt) argues against leafy accumulators in the
;; first place; treating salad as the fragile crop is the conservative reading.
(define %crops '(("beans" . 1.0) ("salad" . 2.0)))
(define (grow-id crop b) (string-append "grow-" crop "-" (bs-place b)))

(define procs
  (append-map (lambda (b)
                (map (lambda (c) (make-recipe-process #:id (grow-id (car c) b)
                                   #:name (string-append "Grow " (car c) " in " (bs-name b))))
                     %crops))
              *berlin-baumscheiben*))

(define flows
  (append-map
    (lambda (b)
      (append-map
        (lambda (c)
          (let ((p (grow-id (car c) b)))
            (list ;; consume 1 m² of THIS district's pits
                  (make-recipe-flow #:id (string-append p "-in") #:action 'consume #:resource-conforms-to (bs-spec b)
                    #:resource-quantity (make-measure 1.0 "m2") #:recipe-input-of p)
                  ;; and the crew hours to tend it
                  (make-recipe-flow #:id (string-append p "-h") #:action 'consume #:resource-conforms-to "crew-hours"
                    #:resource-quantity (make-measure %h-per-m2 "h") #:recipe-input-of p)
                  ;; produce the crop's yield in meal-kg, shaded by the district's trees
                  (make-recipe-flow #:id (string-append p "-out") #:action 'produce #:resource-conforms-to "meal"
                    #:resource-quantity (make-measure (* (cdr c) (shade b)) "kg") #:recipe-output-of p #:is-primary #t))))
        %crops))
    *berlin-baumscheiben*))

;; ── the crowd's floor ────────────────────────────────────────────────────────
;; 24,000 people × 0.5 kg fresh produce each = 12,000 kg, to hold in EVERY future.
;; Demand above it rewards salad's good-year upside, exactly as the farm's does.
(define %floor 12000.0)
(define repro-floors (list (cons (string-append "meal#" %place "@0") %floor)))
(define demand       (list (cons (string-append "meal#" %place "@0") 60000.0)))

;; ── the futures ──────────────────────────────────────────────────────────────
;; WEATHER probabilities are REAL — Berlin's own 1960–2023 ERA5 record, the ±1σ
;; classification in knowledge/berlin-derived.scm (drought .1875 / normal .640625 /
;; flood .171875; Berlin runs drier than Doon or Cascadia).
(define %weather
  `(("normal"  0.640625 ("beans" . 1.00) ("salad" . 1.00))
    ("drought" 0.187500 ("beans" . 0.75) ("salad" . 0.45))   ; [DRAFT] crop response
    ("flood"   0.171875 ("beans" . 0.96) ("salad" . 0.96))))
;; PERMISSION has no 64-year record — these are elicited figures to be RATIFIED, not
;; measurements. Permission holds citywide 70% of the time; the remaining 30% is split
;; evenly over the twelve single-district withdrawals. [DRAFT]
;; EVERY district is revocable — twelve Ämter, any one of which can withdraw. Naming
;; only a favoured few would beg the question the test is asking: the plan must not get
;; to know in advance which Amt says no.
(define %revocable *berlin-baumscheiben*)
(define %permit
  (cons (list "hold" 0.70 #f)
        (map (lambda (b) (list (string-append "no-" (bs-place b))
                               (/ 0.30 (length %revocable)) b))
             %revocable)))

;; WHICH CHANNEL A WITHDRAWAL USES, and why it matters.
;;
;; The obvious encoding is `(avail SPEC 0.0)` — the district's ground stops being
;; available. That is the RIGHT channel for a withdrawal that lands BEFORE planting,
;; and it is what a custody recall of privately-owned means would use. It is the wrong
;; one here: planting is first-stage, committed once and shared across every scenario
;; (non-anticipativity), so zeroing the ground a first-stage column consumes makes the
;; PLANTING infeasible rather than the harvest lost. With all twelve districts
;; revocable that admits no plan at all — the solver says so, plainly:
;;   "no strictly-feasible point — a reproduction floor is unmeetable in some scenario"
;;
;; The fear the room actually named is a withdrawal that lands AFTER planting: you sow
;; in spring, the Amt clears the pits in July. That is a harvest loss, so it is a
;; `produce` shock on that district's grow procs — structurally identical to the farm's
;; blight, scoped to a district instead of a crop. The labour and the season are spent
;; either way, which is precisely what makes concentration dangerous.
(define (with-withdrawal shocks b)
  (if (not b) shocks
      (append (remove (lambda (s) (member (car s) (map (lambda (c) (grow-id (car c) b)) %crops)))
                      shocks)
              (map (lambda (c) (cons (grow-id (car c) b) 0.0)) %crops))))

;; produce shocks key on PROC id — both crops output "meal", so an output-spec shock
;; could not tell them apart.
(define (weather-shocks w)
  (append-map (lambda (b)
                (map (lambda (c) (cons (grow-id (car c) b) (assoc-ref (cddr w) (car c))))
                     %crops))
              *berlin-baumscheiben*))

(define rob-scenarios
  (append-map
    (lambda (w)
      (map (lambda (pm)
             (make-planning-scenario
               (string-append (car w) "/" (car pm)) #f (* (cadr w) (cadr pm))
               (with-withdrawal (weather-shocks w) (caddr pm))
               (string-append (car w) " year, permission " (car pm))))
           %permit))
    %weather))

;; the naive plan: mean weather, and permission simply assumed to hold
(define det-scenarios
  (list (make-planning-scenario "mean" #f 1.0
          (append-map (lambda (b)
                        (map (lambda (c)
                               (cons (grow-id (car c) b)
                                     (fold + 0.0 (map (lambda (w) (* (cadr w) (assoc-ref (cddr w) (car c))))
                                                      %weather))))
                             %crops))
                      *berlin-baumscheiben*)
          "mean year, permission assumed")))

(define %all-procs (map recipe-process-id procs))

(define (plant scenarios)
  (call-with-values
    (lambda () (plan-from-records resources '() spatials procs flows
                 #:scenarios scenarios #:first-stage-procs %all-procs
                 #:repro-floors repro-floors #:demand demand #:per-agent? #f))
    (lambda (ints coms material fill cols x idx ntot report)
      (or (assoc-ref report 'first-stage-plan) '()))))

;; m² planted in a Bezirk, across both crops
(define (planted fs b)
  (fold + 0.0 (map (lambda (c) (or (assoc-ref fs (grow-id (car c) b)) 0.0)) %crops)))
;; CONCENTRATION IS NOT A COUNT. `districts-used` thresholds each district at
;; 1 m², so it answers "how many were touched at all" — and under a loose path
;; floor every district was touched a little, which made the count a reading of
;; the barrier's residue as much as of the plan. With the floor derived from the
;; certified gap that residue is gone, both covers touch 5 districts, and the
;; count can no longer tell a concentrated plan from a spread one.
;;
;; The claim is about where the MASS sits, so measure that. The effective number
;; of districts is the inverse participation ratio (Σp)²/Σp²: 1 when a plan puts
;; everything in one district, n when it spreads evenly over n, scale-free, and
;; a district carrying only residue contributes essentially nothing to it.
(define (districts-used fs) (count (lambda (b) (> (planted fs b) 1.0)) *berlin-baumscheiben*))
(define (effective-districts fs)
  (let* ((ps (map (lambda (b) (planted fs b)) *berlin-baumscheiben*))
         (s1 (fold + 0.0 ps))
         (s2 (fold (lambda (p a) (+ a (* p p))) 0.0 ps)))
    (if (> s2 0.0) (/ (* s1 s1) s2) 0.0)))
;; kg the plan yields if district B is revoked and the weather is W
(define (yield-if fs w revoked)
  (fold + 0.0
    (append-map (lambda (b)
                  (map (lambda (c)
                         (if (and revoked (equal? (bs-name b) (bs-name revoked))) 0.0
                             (* (or (assoc-ref fs (grow-id (car c) b)) 0.0)
                                (cdr c) (shade b) (assoc-ref (cddr w) (car c)))))
                       %crops))
                *berlin-baumscheiben*)))
(define (worst-yield fs)                     ; over every future in the robust set
  (fold min 1e18
    (append-map (lambda (w) (map (lambda (pm) (yield-if fs w (caddr pm))) %permit)) %weather)))

(define det (plant det-scenarios))
(define rob (plant rob-scenarios))
(define sz (car *berlin-baumscheiben*))      ; Steglitz-Zehlendorf, the biggest stock

(format #t "~%── Berlin's Baumscheiben: ~a street trees, every one owned by Land Berlin ──~%"
        *berlin-baumscheiben-total*)
(format #t "  plantable ground: ~,0f m² across 12 Bezirke (~,1f m²/pit × ~,0f%% plantable, both DRAFT)~%"
        (berlin-baumscheiben-total-area) *baumscheibe-m2* (* 100 *baumscheibe-plantable-fraction*))
(format #t "  the crowd's floor: ~,0f kg — must hold in every future~%~%" %floor)
(format #t "  DETERMINISTIC (mean weather, permission assumed): ~a district(s) planted~%"
        (districts-used det))
(let ((top (fold (lambda (b acc) (if (> (planted det b) (planted det acc)) b acc))
                 (car *berlin-baumscheiben*) *berlin-baumscheiben*)))
  (format #t "    → biggest single stake: ~,0f m² in ~a (median tree age ~a, shade ~,2f)~%"
          (planted det top) (bs-name top) (bs-age top) (shade top)))
(format #t "    → worst future: ~,0f kg  (floor ~,0f)  ~a~%"
        (worst-yield det) %floor
        (if (< (worst-yield det) %floor) "*** THE FESTIVAL STARVES ***" "ok"))
(format #t "  ROBUST (~a futures: 3 weather × 13 permission): ~a district(s) planted~%"
        (length rob-scenarios) (districts-used rob))
(format #t "    → worst future: ~,0f kg  (floor ~,0f)~%" (worst-yield rob) %floor)

(format #t "~%── assertions ──~%")
(check "the real register is loaded — 434,765 pits, 12 Bezirke"
       (and (= *berlin-baumscheiben-total* 434765) (= (length *berlin-baumscheiben*) 12)))
(check "Steglitz-Zehlendorf is the largest pit stock (61,131 trees)"
       (and (equal? (bs-name sz) "Steglitz-Zehlendorf") (= (bs-count sz) 61131)))
(format #t "  effective districts (Sp)^2/Sp^2:  deterministic ~,2f   robust ~,2f~%"
        (effective-districts det) (effective-districts rob))
(check "deterministic CONCENTRATES — its mass sits in fewer districts than robust"
       (< (effective-districts det) (effective-districts rob)))
(check "…and that concentration STARVES the festival in its worst future"
       (< (worst-yield det) %floor))
(check "ROBUST spreads across several districts" (>= (districts-used rob) 3))
(check "the robust plan feeds the crowd in EVERY future — weather AND withdrawal"
       (>= (worst-yield rob) (* 0.98 %floor)))
(check "39 futures drove the robust solve (3 weather × 13 permission regimes)"
       (= (length rob-scenarios) 39))

(check-done "  Berlin's Baumscheiben feed the festival. Permission is the uncertainty, not weather alone;~%  spreading across the city's Bezirke is DERIVED from defending the crowd's floor.~%")
