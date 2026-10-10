;;; catalogues/housing.scm — the adequacy standard: what a night's housing owes
;;; a person, as bands.
;;;
;;; catalogues/subsistence.scm's twin. There, a person's nutritional means of
;;; subsistence is a stack of bands — a deficiency floor, a toxicity ceiling, a
;;; weight — folded essential→contingent over a species base. Here the same
;;; stack states housing: a base every person is owed, a layer for the body in
;;; question (age, mobility), and the ratified standard above bare adequacy.
;;; Same band shape `(spec group unit rda ul w)`, same shift helpers, same
;;; reading by the solve (`housing-bands` → plan-scope #:bands): one object, so
;;; the plan and any face that draws the standard agree.
;;;
;;; ── a governance object, in two parts ───────────────────────────────────────
;;; THE STANDARD is what a scope ratifies: `*housing-standard*` below, each row
;;; carrying the source it was read from, and `standard` (L4) — the historical-
;;; moral element, which may only RAISE the gradient floors above bare adequacy.
;;; Moving a number here is a decision about how much is owed (form-and-
;;; substance.typ, "Governing the vector": raise or lower an entry).
;;; THE CLOSURE — which dwelling delivers how much of each row — is
;;; catalogues/housing-substance.scm's, and a dispute there is about measurement. The two
;;; are kept in two files for the reason that note gives: the first is closer
;;; to a vote, the second to a standards body.
;;;
;;; ── per NIGHT, and intensive ────────────────────────────────────────────────
;;; A band is stated per person-night. Warmth, area and privacy are INTENSIVE —
;;; two nights in a 14 °C room are not 28 °C — so catalogues/housing-substance.scm gives a
;;; body exactly one night per period, and what reaches a row is the mix of
;;; dwellings that night was spent across. A floor of 18 then reads as it
;;; should: the night, however divided, averaged 18 °C.
;;;
;;; ── DRAFT ───────────────────────────────────────────────────────────────────
;;; Every figure is a real standard's DIRECTION at a modest, illustrative
;;; magnitude, sourced row by row; none claims to be the one ratified number.

(define-module (playnet knowledge catalogues housing)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet knowledge catalogues subsistence)
                #:select (sub-nut sub-spec sub-group sub-unit sub-rda sub-ul sub-w
                          sub-set* ctx-ref shed-derived-figure))
  #:export (*housing-standard* *housing-rows* *housing-gates* housing-gate?
            housing-row-name housing-row-unit housing-row-source housing-row-function housing-species-base
            housing-L1-climate housing-L2-person housing-L4-standard
            housing-profile housing-bands season-of outdoor-degc
            %acclimatised-ceiling %warmth-raised %warmth-elder-age %warmth-young-age %child-share-age
            %winterless-regions %outdoor-credit winterless? effective-area))

;;; ── L0 · THE BASE — what every person's night is owed ───────────────────────
;; (row name group unit floor ceiling w source function). A GRADIENT row is a quantity the
;; night delivers; a GATE row is a certificate the dwelling holds (1) or does
;; not (0) — a floor of 1 means every part of the night is spent certified.
;; Accessibility carries NO base floor: it is owed to the body that needs it
;; (L2), and a floor nobody needs would refuse every walk-up flat for everyone.
(define *housing-standard*
  '(("hs-area"          "Floor area, per person" "gradient" "m2"    9.0  #f   6
     "Minimum habitable floor space per person — municipal space codes cluster around 9–12 m² (e.g. Berlin WoAufG 9 m² per adult)." proxy)
    ("hs-warmth"        "Indoor warmth" "gradient" "degC" 18.0 26.0  8
     "WHO Housing and Health Guidelines (2018): 18 °C minimum indoor temperature where the climate has a winter (L1 lifts the floor where it has none); the ceiling is the overheating edge heat-health guidance places in the mid-20s, and L1 lifts it where the climate is hot and a body is acclimatised." outcome)
    ("hs-privacy"       "Private sleeping places, per person" "gradient" "places" 0.3333333333333333 #f   5
     "UN-Habitat's overcrowding line (SDG 11.1.1 slum criterion): more than three people to a sleeping place. A place is a walled room, a curtained or screened sleeping place in a hall or yurt, or a hut of a compound — whichever way a household keeps privacy; a ratified standard (L4) raises it toward the one-per-two of Eurostat and Canada's National Occupancy Standard." proxy)
    ("hs-safety"        "Structural safety" "gate"     "cert"  1.0 #f   9
     "Structural and fire safety: a habitability certificate held by the dwelling (UN-Habitat durability criterion), read in whatever the dwelling is built of — earth, bamboo, timber, brick or stone." outcome)
    ("hs-sanitation"    "Sanitation and water" "gate"     "cert"  1.0 #f   9
     "WHO/UNICEF JMP basic service: an improved water source on the premises and an improved sanitation facility not shared with other households." service)
    ("hs-energy"        "Electricity and light" "gate"     "cert"  1.0 #f   7
     "CESCR General Comment 4 §8(b), availability of services: energy for lighting, cooking and heating, from the grid, a household solar system or a shared source (SDG 7.1.1 counts each as access)." service)
    ("hs-dry"           "Dry and ventilated" "gate"     "cert"  1.0 #f   7
     "WHO Housing and Health Guidelines (2018): damp and mould, ventilation — a dwelling free of persistent damp and mould, however its walls breathe." outcome)
    ("hs-quiet"         "Quiet enough to sleep" "gate"     "cert"  1.0 #f   8
     "WHO Environmental Noise Guidelines for the European Region (2018), the night-noise guideline: freedom from din, traffic or machinery noise disruptive enough to break sleep through the sleeping hours, however the dwelling achieves it." outcome)
    ("hs-dark"          "Dark enough to sleep" "gate"     "cert"  1.0 #f   6
     "Light-at-night and circadian sleep-health guidance (WHO/IARC on artificial light at night): a sleeping place that can be made dark enough for uninterrupted sleep — shutters, curtains, or their equivalent." outcome)
    ("hs-accessibility" "Step-free access" "gate"     "cert"  0.0 #f   9
     "CRPD art. 9 / step-free access: owed to the person who needs it (L2), floor 0 otherwise." access)))

(define *housing-rows*  (map car *housing-standard*))
(define *housing-gates* (filter-map (lambda (r) (and (equal? "gate" (caddr r)) (car r))) *housing-standard*))
(define (housing-gate? row) (and (member row *housing-gates*) #t))
(define (housing-row-name row) (and=> (assoc row *housing-standard*) cadr))
(define (housing-row-unit row) (and=> (assoc row *housing-standard*) (lambda (r) (list-ref r 3))))
(define (housing-row-source row) (and=> (assoc row *housing-standard*) (lambda (r) (list-ref r 7))))
;; What the row DOES for rest (docs/planning/food/reproduction-of-labour-power.md §3), the
;; 9th field of the row itself so no row exists without one: an OUTCOME is a
;; property of the night; a PROXY stands in for one that is harder to measure
;; (area and sleeping places for crowding and privacy); a SERVICE supports the
;; acts around sleep (washing, light); ACCESS is reaching the place at all. A
;; label the walk and the plan read; it changes no floor.
(define (housing-row-function row) (and=> (assoc row *housing-standard*) (lambda (r) (list-ref r 8))))

(define (housing-species-base)
  (map (lambda (r) (sub-nut (list-ref r 0) (list-ref r 2) (list-ref r 3)
                            (list-ref r 4) (list-ref r 5) (list-ref r 6)))
       *housing-standard*))

;;; ── L1 · THE CLIMATE — a winter, or none ────────────────────────────────────
;; WHO's 18 °C floor is its figure for climates with a winter, and the
;; guideline itself says the evidence does not carry it to warm ones. The
;; region the geography layer already reads (catalogues/subsistence.scm's
;; coarse latitude table) says which is which: hotArid — within 30° of the
;; equator — has no winter, and asks no floor of warmth; the overheating
;; ceiling stands everywhere but rises where a body is acclimatised: the
;; mid-20s edge is a temperate-climate figure, and heat-health thresholds are
;; set locally, so the hot region's ceiling is 30 °C. The named figures below
;; are emitted to the browser (tools/emit/housing-emit.scm), so no copy of them is
;; typed twice.
(define %acclimatised-ceiling 30.0)
;; the regions that have no winter — one list, emitted to the browser with the rest
(define %winterless-regions '("hotArid"))
(define (winterless? region) (and (member region %winterless-regions) #t))

;; Where the climate has no winter, daily life is carried outdoors: covered outdoor
;; and shared living space (a veranda, a roofed yard, a courtyard) counts toward a
;; person's floor area at this share. The floor area a night reads is the indoor area
;; plus that share; the solve is handed the result, so its closure reads one number.
(define %outdoor-credit 0.5)
(define* (effective-area area outdoor region)
  (+ area (if (winterless? region) (* %outdoor-credit (max 0 outdoor)) 0)))
(define (housing-L1-climate prof ctx)
  (if (winterless? (ctx-ref ctx 'region "temperate"))
      (sub-set* prof `(("hs-warmth" #:rda 0.0 #:ul ,%acclimatised-ceiling)))
      prof))

;; which of a dwelling's two warmths a night reads: winter or summer, by the
;; month and the hemisphere — the ctx carries both (live.scm's month, a coarse
;; lat), and a horizon of days does not cross a season
(define (season-of month lat)
  (let ((north? (or (not lat) (>= lat 0))))
    (if (if north? (or (>= month 11) (<= month 3)) (and (>= month 5) (<= month 9)))
        'winter 'summer)))

;; what the season is like OUTSIDE, off the shed's real record (its generated
;; table: the warmest quarter and the annual mean): summer's outdoors is the warm
;; quarter, and the cold quarter mirrors it about the mean, 2·mean − warm (Berlin:
;; 10.8 and 19.9 give 1.7 °C). What a dwelling's envelope leaks against
;; (catalogues/housing-substance.scm night-heat-kwh); #f where the shed states no record.
(define (outdoor-degc shed season)
  (let ((warm (and shed (shed-derived-figure shed "warm-quarter-degc")))
        (mean (and shed (shed-derived-figure shed "annual-mean-degc"))))
    (and warm mean (if (eq? season 'summer) warm (- (* 2.0 mean) warm)))))

;;; ── L2 · THE PERSON — the body the night houses ─────────────────────────────
;; WHO's 18 °C is the general-population figure; the same guideline asks more
;; for the old, the young and the ill — 20 °C here, where a winter is. A young
;; child sleeps beside others as a matter of course where a household keeps to
;; that, so the privacy floor halves below CHILD-SHARE-AGE — a choice of the
;; scope (ctx 'child-share-age, 10 by default, 0 for a scope that owes a child
;; the full floor), never a verdict on how a household sleeps. A
;; person who needs step-free access is owed it: the gate's floor rises from 0 to 1.
;; the named figures of this layer — the ages the guideline asks 20 °C for, that
;; 20, and the age below which a child's privacy floor halves unless the scope
;; says otherwise — are emitted to the browser with the rest of the standard
(define %warmth-elder-age 65)
(define %warmth-young-age 5)
(define %warmth-raised 20.0)
(define %child-share-age 10)
(define (housing-L2-person prof ctx)
  (let ((age (ctx-ref ctx 'age 30))
        (base-privacy (list-ref (assoc "hs-privacy" *housing-standard*) 4)))
    (sub-set* prof
      (append (if (and (or (>= age %warmth-elder-age) (< age %warmth-young-age)) (not (winterless? (ctx-ref ctx 'region "temperate"))))
                  `(("hs-warmth" #:rda ,%warmth-raised)) '())
              (if (< age (ctx-ref ctx 'child-share-age %child-share-age)) `(("hs-privacy" #:rda ,(/ base-privacy 2))) '())
              (if (ctx-ref ctx 'step-free #f) '(("hs-accessibility" #:rda 1.0)) '())))))

;;; ── L4 · THE RATIFIED STANDARD — may only raise, gradients only ─────────────
;; The historical-moral element: a scope's decent life above bare adequacy.
;; A gate is already whole at 1 and has nothing above it; a gradient rises by
;; the ratified factor, and never past its own ceiling.
(define (housing-L4-standard prof ctx)
  (let ((s (max 1 (ctx-ref ctx 'standard 1))))
    (map (lambda (n)
           (let ((raised (* (sub-rda n) s)))
             (if (and (> s 1) (equal? "gradient" (sub-group n))
                      (or (not (sub-ul n)) (< raised (sub-ul n))))
                 (sub-nut (sub-spec n) (sub-group n) (sub-unit n) raised (sub-ul n) (sub-w n))
                 n)))
         prof)))

(define (housing-profile ctx)
  (housing-L4-standard (housing-L2-person (housing-L1-climate (housing-species-base) ctx) ctx) ctx))

;; the BANDS for the planner, subsistence-bands' own shape: ((row floor ceiling w) …),
;; a row whose floor is 0 and ceiling absent asks nothing and is dropped.
(define (housing-bands ctx)
  (filter-map (lambda (n) (and (or (> (sub-rda n) 0) (sub-ul n))
                               (list (sub-spec n) (sub-rda n) (sub-ul n) (sub-w n))))
              (housing-profile ctx)))
