;;; catalogues/housing-substance.scm — the closure: what a night in THIS dwelling delivers.
;;;
;;; dwelling.scm's `spec-shelter` answers WHETHER a body is sheltered — one
;;; undifferentiated person-night. This file answers HOW WELL, the closure
;;; docs/rights.md and form-and-substance.typ ("shelter adequacy") name: a
;;; dwelling (the form) reduces to the ten rows catalogues/housing.scm states
;;; its bands over (the substance), blind to which dwelling delivered them.
;;; It is food's chain, row for row:
;;;
;;;     food        *food-nutrition*   eat~food~pid      subsistence-bands  scope-consumption
;;;     dwelling    this file's two    live-in~unit~pid  housing-bands      scope-housing
;;;                 tables, below
;;;
;;; ── two kinds of row, and where each is read ───────────────────────────────
;;; A GRADIENT (area, warmth, privacy) is what a dwelling MEASURES: its floor
;;; area and rooms shared by the beds it houses, and the warmth it is kept at.
;;; A unit states those three and its nights deliver them; a unit that states
;;; only a TYPE delivers the type's row of `*dwelling-composition*`, the twin
;;; of `*food-nutrition*` — the fallback a seeded fixture uses. A GATE (safety,
;;; sanitation, accessibility) is a fact about ONE DWELLING — this flat holds
;;; the certificate or it does not, and the flat next door, same size, may
;;; differ; it can lapse last month and be restored next. So a gate is carried
;;; by the UNIT: what an inspection of it would attest (`attests`), and whether
;;; its certificate stands today (`certified?`).
;;;
;;; ── the certificate is a whole act ──────────────────────────────────────────
;;; A standing certificate is `capacity` certified person-nights on hand
;;; (`hs-cert.<unit>`). A certified night consumes one; a bare night in the
;;; same flat delivers its gradients and no gate. Where the certificate has
;;; lapsed, `certify~<unit>` restores it: an inspector's hours in, a period's
;;; certified nights out — named WHOLE (scope-housing's `whole` part), because no one
;;; four-tenths certifies a flat. That is the licensing gate the tension table
;;; names, on the search the engine already has (`solve-discrete`): the plan
;;; decides, as a yes or a no, whether re-certifying this flat is how the
;;; floor gets met.
;;;
;;; ── one night per body per period, and it FALLS ────────────────────────────
;;; The rows are intensive (catalogues/housing.scm), so each person holds one
;;; night per period (`hs-night|pid`) and every live-in run spends it. What
;;; reaches a row is then the mix of dwellings the night was spent across.
;;; Where does the night come from? It is a FACT, the way family.scm's week of
;;; living is: `nightfall~pid` hands a body its night, `stands~unit` hands a
;;; dwelling its rooms and its standing certificate's nights, and both are
;;; PINNED — 1 at the cell where the fact holds that period, 0 at every other,
;;; because a template exists at every cell and an unpinned copy would mint a
;;; town flat's rooms in the next village. Pins are the door the live solve
;;; already reads (standing accepts, commitment-horizon.md), and a fact is the
;;; same in every future, which is what first-stage means.
;;; "At most one night" and "a whole night certified" are two walls that meet
;;; at exactly 1, and an interior-point solve holds each wall off by its path
;;; floor. `%night-allowance` is the one night plus that floor once per wall —
;;; the solver's own tolerance stated where it is spent, and the whole of the
;;; slack a gradient floor sees (1 %).
;;;
;;; Excluded on purpose, per docs/rights.md: tenure is custody, location is a
;;; spatial relation the plan already reads, affordability has no wall.

(define-module (playnet planner knowledge catalogues housing-substance)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner vf schemas)
  #:use-module ((playnet planner knowledge catalogues substances) #:select (closure-rows closure-reduction closure-bands substance-content %delivered-heat))
  #:use-module (playnet planner knowledge catalogues housing)
  #:use-module ((playnet planner knowledge recipes dwelling) #:select (%rent-eur-per-night))
  #:export (*dwelling-composition* *dwelling-eur-per-night* *dwelling-envelope* %certify-hours %inspector-skill %night-allowance
            dwelling-unit unit-id unit-type unit-place unit-attests unit-certified? unit-capacity unit-eur unit-gradients unit-ua night-heat-kwh
            housing-content unit-content scope-housing resource->dwelling-unit housing-specs)
  #:use-module ((playnet utils catch) #:select (catch* throw* with-throw-handler*)))

;;; ─── the type table: gradients for a unit that states no measurements ────────
;; DWELLING TYPE → what one person-night delivers of each gradient row.
;; DRAFT, illustrative — the direction is real (an unlicensed subdivision is
;; smaller, colder and more crowded than a family flat), the magnitudes are
;; for a scope's housing committee to ratify against its own stock. A unit
;; that states its area, rooms and warmth reads those instead (`dwelling-unit`).
(define *dwelling-composition*
  '(("informal-room" . (("hs-area" .  6.0) ("hs-warmth" . 14.0) ("hs-privacy" . 0.3)))
    ("studio"        . (("hs-area" . 10.0) ("hs-warmth" . 19.0) ("hs-privacy" . 0.6)))
    ("family-flat"   . (("hs-area" . 22.0) ("hs-warmth" . 21.0) ("hs-privacy" . 1.2)))))

;; €/person-night by type — a market rate like dwelling.scm's own
;; %rent-eur-per-night, political and edited here; a unit may state its own.
(define *dwelling-eur-per-night*
  '(("informal-room" . 10.0) ("studio" . 25.0) ("family-flat" . 45.0)))

;; THE ENVELOPE: what the whole dwelling leaks per kelvin it is kept above the
;; outdoors, kW/K (U·A, the proofing box's figure at a dwelling's scale: an
;; uninsulated room near a fifth of a kilowatt a kelvin, a flat's walls more
;; area but better built). A warm night is then a WARMED FORM held in its
;; envelope (docs/observation/physics.md §3, §6): keeping it costs U·A·ΔT over
;; the night's hours, drawn as delivered heat, and the same dwelling unheated
;; is at the outdoors. Illustrative like the type table above; a unit states
;; its own with `ua-kw-per-k:`.
(define *dwelling-envelope*
  '(("informal-room" . 0.20) ("studio" . 0.12) ("family-flat" . 0.18)))
(define %certify-hours 4.0)      ; an inspector's visit — the fixed cost that makes certifying a whole act
(define %night-allowance 1.01)   ; 1 + two path floors (solver.scm *kern-tmin-default* 0.005): one for each wall, see the header

;; housing-content: nutrient-content's twin — the same closure, another table.
(define (housing-content type qty)
  (substance-content type qty #:contains *dwelling-composition* #:tracked *housing-rows*))

;;; ─── the unit: one dwelling, and the certificate it holds ───────────────────
(define* (dwelling-unit id type place #:key (attests '()) (certified? #t) (capacity 1.0) (eur #f)
                        (area #f) (rooms #f) (warmth #f) (warmth-winter warmth) (warmth-summer warmth) (ua #f))
  "One dwelling, standing at PLACE. AREA (m²) and ROOMS are the whole
   dwelling's, shared by the CAPACITY person-nights it houses per period, so
   a night there delivers area/capacity and rooms/capacity; WARMTH-WINTER and
   WARMTH-SUMMER (°C) are what it is kept at in each season (WARMTH states
   both at once), and a night reads the season's. A measurement not stated
   falls back to TYPE's row of the type table; a unit stating all three needs no type. ATTESTS: the gate
   rows an inspection of it would certify — what the flat physically has.
   CERTIFIED?: whether that certificate stands today. EUR: its own rent, else
   its type's, else the rent recipe's. UA (kW/K) is what the whole dwelling
   leaks per kelvin above the outdoors, else its type's envelope, else #f: a
   dwelling stating no envelope draws no heat and is unread by the law. A unit
   attests GATES only: a gradient is measured or its type's, and naming one
   here is refused."
  (let* ((stray (remove housing-gate? attests))
         (typed (and type (assoc-ref *dwelling-composition* type)))
         (per   (lambda (x) (and x (/ x (max capacity 1e-9)))))
         (row   (lambda (id measured)
                  (or measured (and typed (assoc-ref typed id))
                      (error "dwelling-unit: no such dwelling type, and this row is not measured" type id)))))
    (when (pair? stray) (error "dwelling-unit: a certificate attests gates, and these are not" stray))
    (list id type place attests certified? capacity
          (or eur (and typed (assoc-ref *dwelling-eur-per-night* type)) %rent-eur-per-night)
          (list (cons "hs-area"    (exact->inexact (row "hs-area" (per area))))
                (cons "hs-warmth"  (exact->inexact (row "hs-warmth" warmth-winter)))
                (cons "hs-privacy" (exact->inexact (row "hs-privacy" (per rooms)))))
          (exact->inexact (row "hs-warmth" warmth-summer))
          (or ua (and type (assoc-ref *dwelling-envelope* type))))))
(define (unit-id u) (list-ref u 0))
(define (unit-type u) (list-ref u 1))
(define (unit-place u) (list-ref u 2))
(define (unit-attests u) (list-ref u 3))
(define (unit-certified? u) (list-ref u 4))
(define (unit-capacity u) (list-ref u 5))
(define (unit-eur u) (list-ref u 6))
;; what one person-night in this unit delivers of each gradient row — measured,
;; else its type's; warmth is the SEASON's
(define* (unit-gradients u #:key (season 'winter) (warmth #f))
  "WARMTH, when given, is what the night is kept at instead: the outdoors, for a
   night the dwelling stands unheated."
  (let ((g (list-ref u 7))
        (w (or warmth (and (eq? season 'summer) (list-ref u 8)))))
    (if w (map (lambda (p) (if (equal? (car p) "hs-warmth") (cons "hs-warmth" (exact->inexact w)) p)) g) g)))
(define (unit-ua u) (list-ref u 9))
(define* (night-heat-kwh u #:key (season 'winter) (outdoor #f))
  "The heat, kWh, one person-night in U draws to be kept at the season's warmth
   above OUTDOOR °C: U·A·ΔT over the night's 24 hours, the whole dwelling's leak
   shared by its capacity. 0 when the outdoors is as warm, #f when the envelope
   or the outdoors is unstated."
  (let ((ua (unit-ua u)))
    (and ua outdoor
         (/ (* ua (max 0.0 (- (assoc-ref (unit-gradients u #:season season) "hs-warmth") outdoor)) 24.0)
            (max (unit-capacity u) 1e-9)))))

(define (shelter-of u) (string-append "spec-shelter." (unit-id u)))
(define (room-of u)    (string-append "hs-room." (unit-id u)))
(define (cert-of u)    (string-append "hs-cert." (unit-id u)))
(define (night-of pid) (string-append "hs-night|" pid))

(define* (unit-content u qty #:key (certified? #f) (season 'winter) (warmth #f))
  "What QTY person-nights in U deliver: its gradients (measured, else its
   type's; warmth the SEASON's, or WARMTH when the night is kept at another),
   and — on a CERTIFIED? night — a 1 on every gate its certificate attests."
  (append (substance-content (unit-id u) qty #:contains (list (cons (unit-id u) (unit-gradients u #:season season #:warmth warmth))) #:tracked *housing-rows*)
          (if certified? (map (lambda (g) (cons g (* 1.0 qty))) (unit-attests u)) '())))

;;; ─── the recipes ─────────────────────────────────────────────────────────────
;; Process ids use '~' and '.', never '|' — the planner reserves '|' as its
;; column-key delimiter; GOODS keep '|' for the per-person rows, as nutrients do.
(define (proc id name tags hours)
  (make-recipe-process #:id id #:name name #:process-classified-as tags
                       #:has-duration (and hours (make-duration hours "hours"))))
(define (flow id action spec qty unit proc-in proc-out)
  (make-recipe-flow #:id id #:action action #:resource-conforms-to spec
                    #:resource-quantity (make-measure qty unit) #:recipe-input-of proc-in
                    #:recipe-output-of proc-out))
(define (work id skill hours proc)
  (make-recipe-flow #:id id #:action 'work #:resource-conforms-to skill
                    #:effort-quantity (make-measure hours "hours") #:recipe-input-of proc))

;; claim the form: rent in, one of the unit's rooms taken, a night of THIS dwelling out.
;; No `work` flow: paying rent is not labour here, as living-in is not — and
;; labour is exactly what the work flows state (compile.scm: a duration is time).
(define (occupy u)
  (let ((rid (string-append "occupy~" (unit-id u))))
    (cons (proc rid (string-append "occupy " (unit-id u)) '("tag:housing" "tag:market") #f)
          (list (flow (string-append rid "<eur")  'consume "spec-eur" (unit-eur u) "EUR" rid #f)
                (flow (string-append rid "<room") 'consume (room-of u) 1.0 "person-nights" rid #f)
                (flow (string-append rid ">")     'produce (shelter-of u) 1.0 "person-nights" #f rid)))))

;; reduce it: live.scm's `eat`, for a night. A CERTIFIED night also spends one
;; of the certificate's nights and delivers the gates it attests.
;; THE WARMED FORM. A night kept at the season's warmth draws the heat its
;; envelope leaks (night-heat-kwh) as delivered heat; where the outdoors is
;; known and the dwelling would leak, the same night UNHEATED is offered too, at
;; the outdoors' warmth and drawing nothing: the plan keeps the dwelling warm when
;; it has the heat and a floor asks, and a cold night says what it is.
(define* (live-in u pid #:key (certified? #f) (season 'winter) (outdoor #f) (cold? #f))
  (let* ((heat (night-heat-kwh u #:season season #:outdoor outdoor))
         (warmth (and cold? outdoor)))
    (closure-reduction
     (proc (string-append (if certified? "live-in-certified~" "live-in~") (if cold? "cold~" "") (unit-id u) "~" pid)
           (string-append "live in " (unit-id u) (if cold? ", unheated" "")) '("tag:housing") #f)
     (append (list (list "night" (night-of pid) 1.0 "person-nights")
                   (list "shelter" (shelter-of u) 1.0 "person-nights"))
             (if (and heat (> heat 0.0) (not cold?)) (list (list "heat" %delivered-heat heat "kWh")) '())
             (if certified? (list (list "cert" (cert-of u) 1.0 "person-nights")) '()))
     (closure-rows u 1 #:content (lambda (u q) (unit-content u q #:certified? certified? #:season season #:warmth warmth)))
     #:name (lambda (row) (string-append row "|" pid)))))
(define (cold-night? u season outdoor)     ; the unheated night is a real alternative only where heating costs something
  (let ((heat (night-heat-kwh u #:season season #:outdoor outdoor))) (and heat (> heat 0.0))))

;; restore a lapsed certificate: the inspector's hours in, a period's certified nights out.
;; The work names its SKILL — scope-inspection's `verifier`, for dwellings — so in a
;; live scope the act is staffed by whoever holds that skill, and where nobody
;; does the prune removes it: a lapsed certificate then stays lapsed, and says so
;; through the gate rows the uncertified night cannot deliver.
(define %inspector-skill "housing-inspector")
(define (certify u inspector)
  (let ((rid (string-append "certify~" (unit-id u))))
    (cons (proc rid (string-append "certify " (unit-id u)) '("tag:housing" "whole-count") %certify-hours)
          (list (work (string-append rid "<work") inspector %certify-hours rid)
                (flow (string-append rid ">") 'produce (cert-of u) (unit-capacity u) "person-nights" #f rid)))))

(define (lapsed? u) (and (pair? (unit-attests u)) (not (unit-certified? u))))

;; the facts a period brings, each its own boundary process (nothing in, the
;; fact out), pinned by scope-housing: a body's night, and a dwelling standing
;; — its rooms, and its certificate's nights where the certificate stands
(define (nightfall pid)
  (let ((rid (string-append "nightfall~" pid)))
    (cons (proc rid "night falls" '("tag:housing" "tag:boundary") #f)
          (list (flow (string-append rid ">") 'produce (night-of pid) %night-allowance "person-nights" #f rid)))))
(define (stands u)
  (let ((rid (string-append "stands~" (unit-id u))))
    (cons (proc rid (string-append (unit-id u) " stands") '("tag:housing" "tag:boundary") #f)
          (cons (flow (string-append rid ">room") 'produce (room-of u) (unit-capacity u) "person-nights" #f rid)
                (if (and (unit-certified? u) (pair? (unit-attests u)))
                    (list (flow (string-append rid ">cert") 'produce (cert-of u) (unit-capacity u) "person-nights" #f rid))
                    '())))))

;;; ─── scope-housing: scope-consumption's twin ─────────────────────────────────
;; PEOPLE × UNITS → the parts a solve appends to its own lists, as ONE alist —
;; scope-inspection's convention, since housing too brings more than recipes
;; and bands:
;;   procs flows  occupy per unit, certify per lapsed unit, live-in per (person, unit)
;;   bands        ((row|pid#place@t floor ceiling w) …) off the catalogue, per
;;                period at the cell WHERE says the person occupies — the rule
;;                the nutrient floors read. Guarded to what the units at hand
;;                can deliver at all: a row no dwelling here supplies gets no
;;                band, and the gap is said out loud, never a silent zero.
;;   whole        the certify acts. The RECIPE already states it (its
;;                "whole-count" classification, which the records path reads
;;                off the template — engine.scm, "two doors, one table each");
;;                this part is for the fixture door, `declare-world!`, which
;;                reads no classification and must be told
;;   facts        the fact-processes' ids. A fact is the same in every future,
;;                so a robust solve holds these FIRST-STAGE — a pin names a
;;                shared column; living-in, like eating, stays recourse
;;   pins         ((column . 0|1) …): the period's facts, at EVERY cell of PLACES —
;;                a body's night where WHERE puts it, a dwelling where it
;;                stands, and 0 everywhere else
;; CTX-OF reads a person's attributes — live.scm's agent->subsistence-ctx,
;; which carries age, region, standard and step-free. SEASON is the period's,
;; winter or summer (catalogues/housing.scm season-of): which of a dwelling's
;; two warmths every night in it reads.
(define* (scope-housing people units periods where places
                        #:key (ctx-of (lambda (a) '())) (inspector %inspector-skill) (season 'winter) (outdoor #f))
  (define deliverable
    (delete-duplicates (append-map (lambda (u) (map car (unit-content u 1 #:certified? #t #:season season))) units)))
  (define (cell-of pid t) (or (where pid t) "?"))
  (define (bands a)
    (let* ((pid (agent-id a))
           (rows (housing-bands (ctx-of a)))
           (lost (remove (lambda (r) (member (car r) deliverable)) rows)))
      (when (pair? lost)
        (format (current-error-port) "  [housing] ~a: no dwelling here delivers ~s — no floor stands for it~%"
                pid (map car lost)))
      (closure-bands pid rows deliverable periods where)))
  (define (pins-of rec here?)          ; REC's column at every cell: 1 where HERE? holds, else 0
    (append-map (lambda (t)
                  (map (lambda (place)
                         (cons (string-append "p|" (recipe-process-id (car rec)) "|" place "@" (number->string t))
                               (if (here? place t) 1.0 0.0)))
                       places))
                periods))
  (let* ((lapsed (filter lapsed? units))
         (nights (map (lambda (a) (cons a (nightfall (agent-id a)))) people))
         (stand  (map (lambda (u) (cons u (stands u))) units))
         (recs (append
                (map cdr nights) (map cdr stand)
                (map occupy units)
                (map (lambda (u) (certify u inspector)) lapsed)
                (append-map (lambda (a)
                              (append-map (lambda (u)
                                            (append-map
                                             (lambda (cold?)
                                               (cons (live-in u (agent-id a) #:season season #:outdoor outdoor #:cold? cold?)
                                                     (if (pair? (unit-attests u))
                                                         (list (live-in u (agent-id a) #:certified? #t #:season season #:outdoor outdoor #:cold? cold?))
                                                         '())))
                                             (if (cold-night? u season outdoor) '(#f #t) '(#f))))
                                          units))
                            people))))
    `((procs . ,(map car recs))
      (flows . ,(append-map cdr recs))
      (bands . ,(append-map bands people))
      (whole . ,(map (lambda (u) (recipe-process-id (car (certify u inspector)))) lapsed))
      (facts . ,(map (lambda (r) (recipe-process-id (cadr r))) (append nights stand)))
      (pins  . ,(append
                 (append-map (lambda (n) (pins-of (cdr n) (lambda (place t) (equal? place (cell-of (agent-id (car n)) t))))) nights)
                 (append-map (lambda (s) (pins-of (cdr s) (lambda (place t) (equal? place (unit-place (car s)))))) stand))))))

;; a scope's own dwellings, read off its resources: an EconomicResource that
;; states its measurements (`area-m2:`, `rooms:`, `warmth-winter-degc:` and
;; `warmth-summer-degc:`, or one `warmth-degc:` for both) or a
;; `dwelling-type:` is a unit — its id, where it stands, what its certificate
;; attests (`attests:<gate>`), whether it stands (`certified`), how many it
;; houses a night (`beds:<n>`), its own rent where a landlord is paid
;; (`rent-eur-night:<x>`, else its type's). A dwelling stating neither is
;; dwelling.scm's undifferentiated flat, and is left to it; one stating a
;; measurement the type table cannot fill in reads as no unit, said out loud.
(define (resource->dwelling-unit r)
  (let* ((tags (filter string? (or (economic-resource-classified-as r) '())))
         (val  (lambda (prefix) (and=> (find (lambda (t) (string-prefix? prefix t)) tags)
                                       (lambda (t) (substring t (string-length prefix))))))
         (num  (lambda (prefix) (and=> (val prefix) string->number)))
         (type (val "dwelling-type:")))
    (and (or type (num "area-m2:")) (economic-resource-current-location r)
         (catch* #t
           (lambda ()
             (dwelling-unit (economic-resource-id r) type (economic-resource-current-location r)
                            #:attests (filter-map (lambda (t) (and (string-prefix? "attests:" t) (substring t 8))) tags)
                            #:certified? (and (member "certified" tags) #t)
                            #:capacity (or (num "beds:") 1.0)
                            #:eur (num "rent-eur-night:")
                            #:area (num "area-m2:") #:rooms (num "rooms:") #:warmth (num "warmth-degc:")
                            #:warmth-winter (or (num "warmth-winter-degc:") (num "warmth-degc:"))
                            #:warmth-summer (or (num "warmth-summer-degc:") (num "warmth-degc:"))
                            #:ua (num "ua-kw-per-k:")))
           (lambda (k . args)
             (format (current-error-port) "  [housing] ~a: not read as a dwelling — ~s~%" (economic-resource-id r) args)
             #f)))))

;; the standard's rows as ResourceSpecifications, for a scope's store — nutrient-specs' twin.
;; The per-unit and per-person goods are made per solve, as `food~pid` is.
(define housing-specs
  (cons (make-resource-specification #:id %delivered-heat #:name "Delivered heat"
                                     #:default-unit-of-resource "kWh")   ; what a warm night draws
        (map (lambda (row) (make-resource-specification #:id row #:name (housing-row-name row)
                                                        #:default-unit-of-resource (housing-row-unit row)))
             *housing-rows*)))
