;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-housing-substance.scm — housing's floor on the substance, derived from
;;; the person, met by the dwelling, its certificate a whole act.
;;;
;;; Four things to prove:
;;;   1. the STANDARD (catalogues/housing.scm) — a base every night is owed, a
;;;      layer for the body housed, a ratified standard that may only raise;
;;;   2. the DERIVATION (scope-housing) — bands read off the person, per period
;;;      at their cell, guarded to what the dwellings at hand can deliver;
;;;   3. the SOLVE — the floor forces the mix: an adequate dwelling is reached
;;;      when the purse allows and refused when it does not, and a night is a
;;;      night (intensive rows do not add across nights);
;;;   4. the CERTIFICATE — a gate is a fact about one flat; where it has
;;;      lapsed, re-certifying is a whole act the search decides.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/solve/test-housing-substance.scm

(use-modules ((localchimera utils units) #:select (%count-unit)))
(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (localchimera solve engine) (localchimera solve discrete) (localchimera solve ingest) (localchimera solve world) (localchimera solve compile) (localchimera solve solver) (localchimera vf schemas))
(use-modules ((localchimera knowledge catalogues subsistence) #:select (region-for-lat %hot-latitude %cold-latitude %high-latitude)))
(use-modules (localchimera knowledge catalogues housing) (localchimera knowledge catalogues housing-substance)
             ((localchimera knowledge catalogues substances) #:select (%delivered-heat))
             (localchimera knowledge dsl shorthand))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (format #t "  [~a] ~a~%" (if ok "✓" "✗") name)
  (if ok (set! *pass* (+ *pass* 1)) (set! *fail* (+ *fail* 1))))
(define (floor-of bands row) (and=> (assoc row bands) cadr))

;;; ════ 1. the standard ═══════════════════════════════════════════════════════
(format #t "~%── 1. the standard: a base, the body housed, the ratified factor ──~%")
(define adult (housing-bands '((age . 30))))
(define elder (housing-bands '((age . 70))))
(define child (housing-bands '((age . 4))))
(define wheel (housing-bands '((age . 30) (step-free . #t))))
(define decent (housing-bands '((age . 30) (standard . 1.5))))
(format #t "  adult: ~a~%" adult)
(check "an adult's night is owed 9 m2, 18-26 degC, a third of a room, safety, sanitation, energy and dryness"
       (and (= 9.0 (floor-of adult "hs-area")) (= 18.0 (floor-of adult "hs-warmth"))
            (= 26.0 (caddr (assoc "hs-warmth" adult))) (< (abs (- 1/3 (floor-of adult "hs-privacy"))) 1e-9)
            (= 1.0 (floor-of adult "hs-safety")) (= 1.0 (floor-of adult "hs-energy")) (= 1.0 (floor-of adult "hs-dry"))))
(define tropics (housing-bands '((age . 70) (region . "hotArid"))))
(check "L1: a climate without a winter asks no floor of warmth, even of the old — and its overheating ceiling is the acclimatised 30 degC"
       (and (= 0.0 (floor-of tropics "hs-warmth")) (= 30.0 (caddr (assoc "hs-warmth" tropics)))))
(check "a scope may owe a child the full privacy floor (child-share-age 0), and the halving stays the default"
       (and (< (abs (- 1/3 (floor-of (housing-bands '((age . 4) (child-share-age . 0))) "hs-privacy"))) 1e-9)
            (< (abs (- 1/6 (floor-of child "hs-privacy"))) 1e-9)))
(check "every row names what it does for rest: a gradient is an outcome or a proxy, a gate an outcome, a service or access"
       (every (lambda (row)
                (memq (housing-row-function row)
                      (if (housing-gate? row) '(outcome service access) '(outcome proxy))))
              *housing-rows*))
(check "no winter is one list of regions, and the outdoor space credit follows it: 20 m2 indoors + 16 m2 of veranda is 28 m2 in the hot region, 20 elsewhere"
       (and (winterless? "hotArid") (not (winterless? "temperate")) (equal? '("hotArid") %winterless-regions)
            (= 28.0 (effective-area 20.0 16.0 "hotArid")) (= 20.0 (effective-area 20.0 16.0 "temperate"))
            (= 20.0 (effective-area 20.0 -5.0 "hotArid"))))
(check "a latitude implies its region by one rule, and the hot region is the one without a winter: Lagos, Berlin, Oslo, Tromsø, the equator's edge"
       (and (equal? "hotArid" (region-for-lat 6.5)) (equal? "temperate" (region-for-lat 45.0))
            (equal? "cold" (region-for-lat 52.5)) (equal? "highLatitude" (region-for-lat 69.6))
            (equal? "hotArid" (region-for-lat -30.0)) (equal? "cold" (region-for-lat -50.0))
            (winterless? (region-for-lat %hot-latitude)) (not (winterless? (region-for-lat 45.0)))
            (< %hot-latitude %cold-latitude %high-latitude)))
(check "the season a night reads: January is winter north of the equator and summer south of it; July the reverse"
       (and (eq? 'winter (season-of 1 52.5)) (eq? 'summer (season-of 1 -33.9))
            (eq? 'summer (season-of 7 52.5)) (eq? 'winter (season-of 7 -33.9)) (eq? 'winter (season-of 12 #f))))
(check "accessibility carries no base floor — no band stands for someone who does not need it"
       (not (assoc "hs-accessibility" adult)))
(check "…and a floor of 1 for the person who does"
       (= 1.0 (floor-of wheel "hs-accessibility")))
(check "the old and the very young are owed 20 degC; a young child's privacy floor halves"
       (and (= 20.0 (floor-of elder "hs-warmth")) (= 20.0 (floor-of child "hs-warmth"))
            (< (abs (- 1/6 (floor-of child "hs-privacy"))) 1e-9)))
(check "the ratified standard raises the gradients (9 -> 13.5 m2) and leaves a gate whole at 1"
       (and (= 13.5 (floor-of decent "hs-area")) (= 1.0 (floor-of decent "hs-safety"))))
(check "…and may only raise: a standard below 1 reads as 1"
       (= 9.0 (floor-of (housing-bands '((standard . 0.5))) "hs-area")))
(check "every row carries the source it was read from — the standard is a governance object"
       (every housing-row-source *housing-rows*))

;;; ════ 2. the derivation ═════════════════════════════════════════════════════
(format #t "~%── 2. scope-housing: bands off the person, recipes off the pairs ──~%")
(define (person id tags) (person* id #:tags tags))
(define (ctx-of a)
  (let ((tags (or (agent-classified-as a) '())))
    `((age . ,(cond ((member "elder" tags) 70) (else 30)))
      (step-free . ,(and (member "step-free" tags) #t)))))
(define (where pid t) "town")
(define ada (person "ada" '()))
(define wil (person "wil" '("step-free")))

(define GATES '("hs-safety" "hs-sanitation" "hs-energy" "hs-dry" "hs-quiet" "hs-dark"))
(define room   (dwelling-unit "room-3"  "informal-room" "town"))
(define studio (dwelling-unit "studio-1" "studio"      "town" #:attests GATES))
(define flat   (dwelling-unit "flat-7"  "family-flat" "town" #:attests (cons "hs-accessibility" GATES)))
(define lapsed (dwelling-unit "flat-7"  "family-flat" "town" #:attests (cons "hs-accessibility" GATES) #:certified? #f #:capacity 4.0))

(define (housing people units) (scope-housing people units '(0) where '("town") #:ctx-of ctx-of))
(define (part h k) (assq-ref h k))
(define h (housing (list ada wil) (list room studio flat)))
(define ids (map recipe-process-id (part h 'procs)))
(check "one occupy per unit; a bare live-in per (person, unit); a certified one where the unit attests"
       (and (member "occupy~flat-7" ids) (member "live-in~room-3~ada" ids)
            (member "live-in-certified~flat-7~wil" ids)
            (not (member "live-in-certified~room-3~ada" ids))))
(check "no certify act where every certificate stands"
       (not (any (lambda (i) (string-prefix? "certify~" i)) ids)))
(check "wil's accessibility band stands at his cell; ada has none"
       (and (assoc "hs-accessibility|wil#town@0" (part h 'bands))
            (not (assoc "hs-accessibility|ada#town@0" (part h 'bands)))))
(define err (open-output-string))
(define gap (with-error-to-port err (lambda () (housing (list wil) (list room studio)))))
(check "a row no dwelling here delivers gets no band, and the gap is said out loud"
       (and (not (assoc "hs-accessibility|wil#town@0" (part gap 'bands)))
            (string-contains (get-output-string err) "[housing] wil")))
(check "a lapsed certificate adds the certify act, and names it whole"
       (let ((l (housing (list wil) (list lapsed))))
         (and (member "certify~flat-7" (map recipe-process-id (part l 'procs)))
              (equal? '("certify~flat-7") (part l 'whole)))))
(check "…staffed by a NAMED skill — the inspector's — which a scope may state as its own"
       (let ((skill-of (lambda (l) (any (lambda (f) (and (eq? 'work (recipe-flow-action f))
                                                         (recipe-flow-resource-conforms-to f)))
                                        (part l 'flows)))))
         (and (equal? %inspector-skill (skill-of (housing (list wil) (list lapsed))))
              (equal? "surveyor" (skill-of (scope-housing (list wil) (list lapsed) '(0) (lambda (pid t) "town") '("town")
                                                          #:inspector "surveyor"))))))
(check "a certificate attests gates: a unit claiming to attest a gradient is refused"
       (not (false-if-exception (dwelling-unit "x" "studio" "town" #:attests '("hs-warmth")))))
(check "the period's facts are pinned: wil's night falls where he is, the flat stands where it stands"
       (and (equal? 1.0 (assoc-ref (part h 'pins) "p|nightfall~wil|town@0"))
            (equal? 1.0 (assoc-ref (part h 'pins) "p|stands~flat-7|town@0"))))
(check "…and nowhere else — a town flat mints no rooms in the village"
       (let ((two (scope-housing (list wil) (list flat) '(0) where '("town" "village") #:ctx-of ctx-of)))
         (and (equal? 0.0 (assoc-ref (part two 'pins) "p|stands~flat-7|village@0"))
              (equal? 0.0 (assoc-ref (part two 'pins) "p|nightfall~wil|village@0")))))
(define (produces rec-id h good)
  (any (lambda (f) (and (equal? rec-id (recipe-flow-recipe-output-of f)) (equal? good (recipe-flow-resource-conforms-to f))))
       (part h 'flows)))
(check "a standing certificate arrives with the flat each period; a lapsed one does not"
       (and (produces "stands~flat-7" h "hs-cert.flat-7")
            (not (produces "stands~flat-7" (housing (list wil) (list lapsed)) "hs-cert.flat-7"))))

;;; ════ 3 & 4. the solve ══════════════════════════════════════════════════════
(define (world! people units budget hours)
  (let ((h (housing people units)))
    (declare-world! #:places '(("town" 0.0 0.0)) #:templates (compile-recipe (part h 'procs) (part h 'flows)))
    (apply declare-whole! (part h 'whole))
    (hash-set! *A* (cell "town" 0) hours)
    (hash-set! *init* "spec-eur#town@0" budget)
    (with-col-fixed! (part h 'pins))
    (apply-repro-bands! (repro-bands #:bands (part h 'bands)))))
(define (col x idx id) (col-value x idx (string-append "p|" id "|town@0")))
(define (relaxed people units budget hours ids)
  (false-if-exception
   (begin (world! people units budget hours)
          (call-with-values located-solve
            (lambda (x forms lf idx) (map (lambda (i) (col x idx i)) ids))))))
(define (discrete people units budget hours ids)
  (false-if-exception
   (begin (world! people units budget hours)
          (call-with-values solve-discrete
            (lambda (cfg certified? . _)
              (call-with-values located-solve
                (lambda (x forms lf idx) (cons certified? (map (lambda (i) (col x idx i)) ids)))))))))

(format #t "~%── 3. the floor forces the mix ──~%")
(define poor (relaxed (list ada) (list room studio) 12.0 20.0 '("live-in~room-3~ada")))
(define fair (relaxed (list ada) (list room studio) 40.0 20.0 '("live-in~room-3~ada" "live-in-certified~studio-1~ada")))
(format #t "  ada, informal room + studio:  €12 → ~a   €40 → ~a~%" (or poor "no plan") fair)
(check "a purse that reaches only the informal room has no plan — 6 m2 at 14 degC, uncertified, is not housing"
       (not poor))
(check "a purse that reaches the studio houses her there, certified, for the night"
       (and fair (> (cadr fair) 0.9) (< (car fair) 0.1)))
(define two-rooms (relaxed (list ada) (list room (dwelling-unit "room-4" "informal-room" "town")) 100.0 20.0 '("live-in~room-3~ada")))
(check "two informal rooms do not add up to one adequate night — a body has one night, and warmth is not a sum"
       (not two-rooms))
(define wil-studio (relaxed (list wil) (list room studio) 100.0 20.0 '("live-in~room-3~wil")))
(define wil-flat   (relaxed (list wil) (list room studio flat) 100.0 20.0 '("live-in-certified~flat-7~wil")))
(check "where no dwelling is step-free, wil's accessibility band is dropped and said, and the rest of his night is met by the studio"
       (and wil-studio #t))
(check "…and where one is, his night is spent in it: the floor on HIS row picks the flat the studio cannot replace"
       (and wil-flat (> (car wil-flat) 0.9)))

(format #t "~%── 4. the certificate: a fact about one flat, restored by a whole act ──~%")
(define standing (discrete (list wil) (list flat) 100.0 20.0 '("live-in-certified~flat-7~wil")))
(check "a standing certificate: the night is certified and nothing needs deciding"
       (and standing (> (cadr standing) 0.9)))
(define half-visit-relaxed (relaxed (list wil) (list lapsed) 100.0 2.0 '("certify~flat-7")))
(define half-visit-whole   (discrete (list wil) (list lapsed) 100.0 2.0 '("certify~flat-7")))
(check "the same flat, certificate lapsed, two inspector-hours on hand: the relaxation finds a plan, certifying a fraction of it…"
       (and half-visit-relaxed (< (car half-visit-relaxed) 0.9)))
(check "…and the whole act does not fit — no plan. The type never changed; the fact did"
       (not (and half-visit-whole (car half-visit-whole) (> (cadr half-visit-whole) 0.9))))
(define frac (relaxed (list wil) (list lapsed) 100.0 20.0 '("certify~flat-7")))
(define whole (discrete (list wil) (list lapsed) 100.0 20.0 '("certify~flat-7" "live-in-certified~flat-7~wil")))
(format #t "  certify~~flat-7:  relaxed ~a   discrete ~a~%" frac whole)
(check "the relaxation certifies a fraction of the flat — one night's worth of a four-night certificate"
       (and frac (> (car frac) 0.05) (< (car frac) 0.9)))
(check "declared whole, the search certifies it once, and certifies the answer"
       (and whole (car whole) (< (abs (- 1.0 (cadr whole))) 1e-3)))
(check "…and wil's night is spent there, certified"
       (and whole (> (caddr whole) 0.9)))

(format #t "~%── 6. a unit read off a resource: its rent rides its tag ──~%")
(define (res id tags)
  (make-economic-resource #:id id #:name id #:conforms-to "spec-dwelling" #:classified-as tags #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit)
                          #:current-location "town"))
(define rented (resource->dwelling-unit (res "room-9" '("dwelling-type:informal-room" "beds:2" "rent-eur-night:12.5" "tenure:rent"))))
(check "rent-eur-night: is the unit's own price of a night" (and rented (= 12.5 (unit-eur rented))))
(check "beds: is its capacity" (and rented (= 2 (unit-capacity rented))))
(check "a unit stating no rent prices a night at its type's"
       (= 25.0 (unit-eur (resource->dwelling-unit (res "studio-1" '("dwelling-type:studio"))))))
(check "tenure is custody, not a row: the unit carries no trace of it"
       (and rented (null? (unit-attests rented))))

(format #t "~%── 7. a measured unit: area and rooms shared by its beds, warmth as kept ──~%")
(define measured (resource->dwelling-unit (res "flat-m" '("area-m2:60" "rooms:3" "warmth-degc:20" "beds:4" "attests:hs-safety"))))
(define (grad u row) (assoc-ref (unit-gradients u) row))
(check "a 60 m² flat housing four gives each night 15 m²" (and measured (= 15.0 (grad measured "hs-area"))))
(check "…three rooms shared by four is 0.75 rooms a person" (and measured (= 0.75 (grad measured "hs-privacy"))))
(check "…and the warmth it is kept at" (and measured (= 20.0 (grad measured "hs-warmth"))))
(check "a night there delivers exactly those, plus its gates when certified"
       (and measured (lset= equal? (unit-content measured 1 #:certified? #t)
                            '(("hs-area" . 15.0) ("hs-warmth" . 20.0) ("hs-privacy" . 0.75) ("hs-safety" . 1.0)))))
(check "a measured unit needs no type, and prices a night at the rent recipe's" (and measured (not (unit-type measured)) (= 25.0 (unit-eur measured))))
(define seasons (resource->dwelling-unit (res "flat-s" '("area-m2:60" "rooms:3" "warmth-winter-degc:15" "warmth-summer-degc:28" "beds:2"))))
(check "a unit states a winter and a summer warmth, and a night reads the season's"
       (and seasons (= 15.0 (assoc-ref (unit-gradients seasons) "hs-warmth"))
            (= 28.0 (assoc-ref (unit-gradients seasons #:season 'summer) "hs-warmth"))
            (= 28.0 (assoc-ref (unit-content seasons 1 #:season 'summer) "hs-warmth"))))
(check "one warmth-degc: states both seasons" (and measured (= 20.0 (assoc-ref (unit-gradients measured #:season 'summer) "hs-warmth"))))
(check "scope-housing hands the season to every live-in"
       (let* ((h (scope-housing (list ada) (list seasons) '(0) where '("town") #:ctx-of ctx-of #:season 'summer))
              (f (find (lambda (f) (and (equal? "hs-warmth|ada" (recipe-flow-resource-conforms-to f))
                                        (equal? "live-in~flat-s~ada" (recipe-flow-recipe-output-of f))))
                       (part h 'flows))))
         (and f (= 28.0 (measure-has-numerical-value (recipe-flow-resource-quantity f))))))
(check "a type's row fills a measurement not stated"
       (= 19.0 (grad (dwelling-unit "s" "studio" "town" #:area 30 #:rooms 1) "hs-warmth")))
(check "a typed unit reads its type's row per night, as before" (= 10.0 (grad studio "hs-area")))
(check "a measurement the type table cannot fill in is refused"
       (not (false-if-exception (dwelling-unit "x" #f "town" #:area 30))))
(check "…and off a resource reads as no unit"
       (not (resource->dwelling-unit (res "half" '("area-m2:30")))))

(format #t "~%── 8. the dwelling as a warmed form: a warm night draws what its envelope leaks ──~%")
(define berlin-winter (outdoor-degc "berlin" 'winter))
(define berlin-summer (outdoor-degc "berlin" 'summer))
(format #t "  Berlin outdoors: winter ~,1f · summer ~,1f °C~%" berlin-winter berlin-summer)
(check "the shed's cold quarter mirrors its warm one about the annual mean: Berlin near 2 °C in winter, near 20 in summer"
       (and (< 0.0 berlin-winter 4.0) (< 18.0 berlin-summer 22.0)))
(check "a shed with no record states no outdoors" (not (outdoor-degc "nowhere" 'winter)))
(check "a typed unit carries its type's envelope; a unit states its own; one with neither has none"
       (and (= 0.12 (unit-ua studio))
            (= 0.3 (unit-ua (resource->dwelling-unit (res "flat-u" '("area-m2:60" "rooms:3" "warmth-degc:20" "beds:2" "ua-kw-per-k:0.3")))))
            (not (unit-ua measured))))
(define studio-heat (night-heat-kwh studio #:season 'winter #:outdoor berlin-winter))
(format #t "  a studio's winter night in Berlin draws ~,1f kWh~%" studio-heat)
(check "a studio's winter night draws U·A·ΔT over 24 hours: 0.12 kW/K times 19 − 1.7 K, near fifty kilowatt-hours"
       (< (abs (- studio-heat (/ (* 0.12 (- 19.0 berlin-winter) 24.0) 1.0))) 1e-9))
(check "…in summer, at 20 °C outside, a studio kept at 19 draws nothing" (= 0.0 (night-heat-kwh studio #:season 'summer #:outdoor berlin-summer)))
(check "…and without an outdoors or an envelope the law is unread" (and (not (night-heat-kwh studio)) (not (night-heat-kwh measured #:outdoor berlin-winter))))
(define hw (scope-housing (list ada) (list studio) '(0) where '("town") #:ctx-of ctx-of #:season 'winter #:outdoor berlin-winter))
(define (flow-of h out spec) (find (lambda (f) (and (equal? spec (recipe-flow-resource-conforms-to f)) (equal? out (recipe-flow-recipe-input-of f)))) (part h 'flows)))
(check "housed in winter, the warm night consumes delivered heat, exactly the envelope's leak"
       (let ((f (flow-of hw "live-in~studio-1~ada" %delivered-heat)))
         (and f (< (abs (- studio-heat (measure-has-numerical-value (recipe-flow-resource-quantity f)))) 1e-9))))
(check "…and the same night unheated is offered too: no heat drawn, the warmth the outdoors'"
       (let ((cold (find (lambda (f) (and (equal? "hs-warmth|ada" (recipe-flow-resource-conforms-to f))
                                          (equal? "live-in~cold~studio-1~ada" (recipe-flow-recipe-output-of f))))
                         (part hw 'flows))))
         (and cold (< (abs (- berlin-winter (measure-has-numerical-value (recipe-flow-resource-quantity cold)))) 1e-9)
              (not (flow-of hw "live-in~cold~studio-1~ada" %delivered-heat)))))
(check "with no outdoors stated, the night is as before: one live-in, no heat, no cold twin"
       (let ((h0 (scope-housing (list ada) (list studio) '(0) where '("town") #:ctx-of ctx-of)))
         (and (not (flow-of h0 "live-in~studio-1~ada" %delivered-heat))
              (not (member "live-in~cold~studio-1~ada" (map recipe-process-id (part h0 'procs)))))))
(check "the heat carrier is a spec of every housed scope" (and (find (lambda (s) (equal? %delivered-heat (resource-specification-id s))) housing-specs) #t))

(format #t "~%  ~a — ~a passed, ~a failed~%~%" (if (= *fail* 0) "✓" "✗") *pass* *fail*)
(exit (if (= *fail* 0) 0 1))
