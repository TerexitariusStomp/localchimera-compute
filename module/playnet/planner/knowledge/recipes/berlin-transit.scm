;;; berlin-transit.scm — Berlin's public transport as VF recipes
;;;
;;; Berlin already has a bioregion (knowledge/berlin.scm) and a commune placed
;;; contained-in it (recipes/berlin-commune-seed.scm). What it lacks is a way to
;;; MOVE: every arc priced by rate×haversine under one generic manner. This file
;;; gives the shed its actual modes — U-Bahn, S-Bahn, the M-line trams, buses,
;;; the Lastenrad, and walking — as recipes, every one of them.
;;;
;;; ── Travel MODES: a person moves ────────────────────────────────────────────
;;; Each mode is a transport recipe over the generic mover (transport.scm
;;; mode-recipe), seeded into the scope's store like any other recipe. The
;;; planner finds it there, instantiates it per rider and tiles one arc column
;;; per (rider, mode, arc): "p|ride.{rider}.{mode}|A@t|B@t". The interesting
;;; flow in that recipe is the vehicle's `use`, and the U-Bahn fills it exactly
;;; the way a car does: `spec-bt-ubahn` is a ResourceSpecification, a ride `use`s it, and the
;;; use draws its per-period SERVICE good `Svc|spec-bt-ubahn`, which is capped.
;;; A seat is capacity. Boarding occupies one for the length of the trip, so the
;;; per-km vehicle coefficient IS the mode's pace and the service is measured in
;;; SEAT-HOURS — which is what makes a rush-hour M10 a scarce thing the plan must
;;; ration rather than a free teleport. What differs from the car is the DRIVER:
;;; the recipe carries no driver's `work` flow, since no member of the commune
;;; drives the train, so no hours come off its labour budget. The one `work` flow
;;; it does carry is the rider's own — resolved from the pickup, at the mode's
;;; pace — which is their transit time, charged as faux frais. A transit mode
;;; also `use`s the pass, held for the journey.
;;;
;;; The four networks are separate specs (U-Bahn, S-Bahn, tram, bus) because they
;;; are separately scarce — the U8 filling up says nothing about the M10 — and
;;; because each is separately revocable. Nothing here says the commune OWNS a
;;; train: the tenure section below gives the network resources to the operator
;;; as primary-accountable with the commune as custodian, which is the same split
;;; a loaned Lastenrad carries.
;;;
;;; The rider's work flow names the skill the journey takes: "walk" and "cycle"
;;; are held by riders who can; transit modes ask "transit-access" — a step-free
;;; journey is a different mode from a stairs-and-escalators one, and someone who
;;; lacks the skill is routed a different way instead of being quietly assumed
;;; able. It sits in the same skills list a rider's other work-skills do
;;; (engine.scm's *riders*) — holding "walk" is the same fact, read the same
;;; bare-membership way, as holding "doctor".
;;;
;;; ── FREIGHT: a good moves ───────────────────────────────────────────────────
;;; Two recipes in the same shape — pickup → use → work → consume → dropoff, the
;;; pickup/dropoff pair relocating one resource rather than creating another:
;;;   recipe-bt-transit-haul  — crates carried by hand, off-peak, on the U/S-Bahn
;;;   recipe-bt-cargo-bike    — a Lastenrad haul: vehicle from the pool, courier's
;;;                             own legs, no fuel
;;;
;;; ── The divisions the freight recipes carry ─────────────────────────────────
;;; A transport recipe's flow numbers are rates PER UNIT MOVED, PER KM — the rule
;;; and its reasoning live in recipes/transport.scm's header, which this file's
;;; recipes are shaped after. What is local here is the arithmetic those rates
;;; needed: a courier spends 0.060 h/km carrying a 25 kg crate, so the flow reads
;;; 0.0024 per kg·km (÷25); a Lastenrad's 0.075 h/km moves a 100 kg box, so ÷100.
;;; A travel mode divides by nothing — one column unit is already one rider, so
;;; the U-Bahn's 0.050 seat-hours per km is both the per-unit and the per-trip
;;; figure.
;;;
;;; ── Where the real times come from ──────────────────────────────────────────
;;; The per-km paces below are each mode's own door-to-door pace, what its rider's
;;; hours cost when the router has measured nothing. The live path prefers,
;;; in order: an observed EWMA over trips the federation actually performed
;;; (service.scm's journey-begin/journey-end file each trip as a Process based on
;;; its mode's specification, with a pickup and a dropoff; the observer's
;;; arc-observations recovers (from to process hours) from them, the live boundary
;;; reads the process's manner off the mode recipe, and solve/routing.scm folds it at
;;; α=0.3), then Valhalla's matrix prior for the mode's
;;; costing, and only then pace×haversine. So these numbers are what the planner
;;; uses on day one and stops using as soon as anyone rides anywhere. A manner's
;;; typical pace, which a generic haul's time-like flows are normalised against,
;;; is read off that table (the median of its (hours . km) entries); no shed states
;;; one.
;;;
;;; Each mode names its Valhalla costing as its manner: U-/S-Bahn are
;;; "multimodal", trams and buses "bus", the bikes "bicycle", walking
;;; "pedestrian". The M-lines (M1, M4, M10 …) are trams, and they are the mode
;;; where the period class earns its keep: solve/routing.scm keys a 4th segment
;;; ("from|to|manner|wd-am") off the departure period, and BVG headways at 08:00
;;; are not BVG headways at 03:00. Berlin's U-Bahn runs all night at weekends and
;;; the night buses take over on weekdays — a "we" arc and a "wd-night" arc over
;;; the same two stations are honestly different numbers, and the table can hold
;;; both.
;;;
;;; ── The GTFS gap, stated plainly ────────────────────────────────────────────
;;; The local Valhalla engine has berlin.osm.pbf and a transit_tiles directory,
;;; but its gtfs_feeds hold no VBB feed. Until one is ingested and the tiles
;;; rebuilt, "multimodal" and "bus" matrix calls return nothing for Berlin and
;;; every transit arc here falls through to pace×haversine — which is why the
;;; paces are chosen as door-to-door effective speeds rather than headline
;;; vehicle speeds. Riding is unaffected: observed trips need no tiles at all,
;;; so the EWMA half starts learning the moment anyone uses the map. To close it:
;;;   fetch the VBB GTFS feed into <valhalla>/gtfs_feeds/vbb, rebuild the transit
;;;   tiles, then refresh with
;;;     guile module/playnet/planner/solve/refresh-priors.scm \
;;;       --manners pedestrian,bicycle,auto,bus,multimodal
;;; and ingest-travel-times! will derive each manner's true median pace from the
;;; matrix, overriding every constant below.
;;;
;;; Cargo bikes need none of that: bicycle costing routes on OSM alone, which is
;;; already built. For hauls under ~8 km across Berlin's flat, cycle-laned inner
;;; districts the Lastenrad is the mode that actually competes with the van.

(define-module (playnet planner knowledge recipes berlin-transit)
  #:use-module (playnet planner vf schemas)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner formulas capacity)
  #:use-module (playnet planner knowledge recipes transit-shed)
  #:use-module (playnet planner knowledge recipes store)
  #:use-module (playnet planner knowledge recipes transport)
  #:export (*berlin-mode-recipes*
            berlin-transit-manners *berlin-transit-specs* seed-berlin-transit-specs
            seed-berlin-transit-haul-recipe
            seed-berlin-cargo-bike-recipe %bt-transit-operator %bt-network-specs
            %bt-bike-lender bt-transit-pass-resource bt-network-resource
            berlin-network-resources berlin-transit-svc-caps bt-cargo-bike-resource
            berlin-transit-resources seed-berlin-transit!)
  #:use-module (srfi srfi-1))


;; Flow helpers come from recipes/transport.scm, which this file's recipes are
;; shaped after: pickup-flow · dropoff-flow · use-flow · consume-flow* · work-flow*.
;; One set of builders for every pickup/dropoff recipe in the library.

;; ─── Travel modes ───────────────────────────────────────────────────────────
;; Each mode is a catalogue transport recipe over the generic mover
;; (recipes/transport.scm mode-recipe): the network or bike as a `use` flow at
;; its per-km rate, the capability the mover must bear, the router's costing
;; manner, and the rider's own pace.
;; Paces are DOOR-TO-DOOR effective, including the walk to the platform and the
;; wait: a U-Bahn train runs at ~30 km/h between stations, but a 5 km U-Bahn
;; journey takes about 15 minutes end to end, so 0.05 h/km is the honest arc
;; coefficient for a mode whose access time is not modelled separately.
(define *berlin-mode-recipes*
  ;; The mover works every journey: on foot and by bike the skill is their own
  ;; ("walk", "cycle"); on the network it is transit-access. Its rate is the
  ;; mode's door-to-door pace. A seat is held for the whole ride, so a transit
  ;; mode `use`s its network at that same rate, and the pass with it — HELD for
  ;; the journey, never spent. No mode names a driver: no member drives the
  ;; train, and a cyclist is their own motor.
  (let ((transit (lambda (name network pace manner)
                   (mode-recipe name #:skill "transit-access" #:pace pace #:manner manner
                                #:uses `((,network . ,pace) ("spec-bt-transit-pass" . ,pace)))))
        (cycle   (lambda (name bike pace)
                   (mode-recipe name #:skill "cycle" #:pace pace #:manner "bicycle"
                                #:uses `((,bike . ,pace))))))
    (list (mode-recipe "walk" #:skill "walk" #:pace 0.200 #:manner "pedestrian")
          (transit "ubahn" "spec-bt-ubahn" 0.050 "multimodal")
          (transit "sbahn" "spec-bt-sbahn" 0.042 "multimodal")
          (transit "tram"  "spec-bt-tram"  0.070 "bus")
          (transit "bus"   "spec-bt-bus"   0.075 "bus")
          (cycle "bike"       "spec-bt-bike"       0.055)
          (cycle "cargo-bike" "spec-bt-cargo-bike" 0.075))))

;; The manners alist the live boundary wants (plan-scope's #:manners). The modes
;; themselves are recipes in the scope's store (seed-berlin-transit!), and each
;; carries its own costing and its own door-to-door pace; a manner's typical pace is
;; read off the router's table.
(define berlin-transit-manners
  (transit-manners))

;; ─── Resource specifications ────────────────────────────────────────────────
;; The transit pass is the one that carries an argument. A Deutschlandticket is
;; not consumed by a ride — it is a durable the commune HOLDS and every member
;; `use`s, which is exactly the socialized-means shape: custody sits with the
;; commune, rights stay with whoever bought it, and a recalled pass shows up as
;; a rented-fragility sector rather than as a price on each trip. Modelling it
;; as `use` of one spec rather than `consume` of a fare is what makes a monthly
;; pass and a single ticket structurally different objects instead of two
;; numbers.
(define *berlin-transit-specs*
  ;; (id name unit class …)
  '(("spec-bt-freight"      "Crated Goods (hand-portable)"     "kg"    "vf:goods")
    ("spec-bt-ubahn"        "U-Bahn Service (seat-hours)"      "hours/day" "vf:vehicle" "vf:passenger" "vf:network")
    ("spec-bt-sbahn"        "S-Bahn Service (seat-hours)"      "hours/day" "vf:vehicle" "vf:passenger" "vf:network")
    ("spec-bt-tram"         "Tram Service, the M-lines (seat-hours)" "hours/day" "vf:vehicle" "vf:passenger" "vf:network")
    ("spec-bt-bus"          "Bus Service (seat-hours)"         "hours/day" "vf:vehicle" "vf:passenger" "vf:network")
    ("spec-bt-transit-pass" "Transit Pass (Deutschlandticket, monthly)" "each" "vf:entitlement" "vf:socializable")
    ("spec-bt-single-fare"  "Single Transit Fare (AB)"         "each"  "vf:entitlement")
    ("spec-bt-bike"         "Bicycle"                          "each"  "vf:vehicle" "vf:passenger" "vf:seats:1")
    ("spec-bt-cargo-bike"   "Cargo Bike (Lastenrad)"           "each"  "vf:vehicle" "vf:freight" "vf:payload-kg:100")
    ("spec-bt-charge"       "Electricity (e-assist charge)"    "kWh"   "vf:energy")
    ("spec-bt-courier"      "Courier Labour"                   "hours" "vf:skill")))

(define (seed-berlin-transit-specs recipe-store)
  "Register Berlin's transit and cycle-logistics resource specs, and the generic
   rider every mode moves (recipes/transport.scm)."
  ($ recipe-store 'add-resource-spec spec-rider)
  (seed-spec-rows! recipe-store *berlin-transit-specs*))

;; ─── The freight trips, as data over transit-shed.scm's one seeder ──────────
;; Rates below are PER TRIP per km — what a caller actually knows ("a courier
;; spends 0.060 h/km carrying a crate") — and #:payload does the division into the
;; per-unit·km rates the arc tiling reads. Durations are whole-journey figures the
;; arc-time table replaces per origin/destination pair.

(define (seed-berlin-transit-haul-recipe recipe-store)
  "Crates on the network: 25 kg carried by hand on the U-/S-Bahn.

   A real Berlin logistics mode at commune volumes, and the same flows as any other
   haul — minus the vehicle line, because the network is not the commune's to
   occupy. What bounds it is the payload one person carries and the PERIOD: 25 kg
   through Alexanderplatz at 08:30 is not the same act as at 11:00, which is why
   the process is tagged off-peak and the arc it prices reads the departure
   period's class."
  (seed-relocation-recipe! recipe-store
    #:process "rp-bt-transit-haul" #:recipe "recipe-bt-transit-haul"
    #:name "Transit haul: crates by hand"
    #:pspec-name "Hand-Carried Transit Haul"
    #:good "spec-bt-freight" #:payload 25.0 #:unit "kg"
    #:duration (make-duration 0.8 "hours")
    #:tags '("tag:transport" "tag:transit" "tag:freight" "tag:off-peak")
    #:uses '(("spec-bt-ubahn" . 0.050)          ; crates take a standing space
             ("spec-bt-transit-pass" . 0.050))
    #:work '("spec-bt-courier" . 0.060)))

(define (seed-berlin-cargo-bike-recipe recipe-store)
  "The Lastenrad: a 100 kg box, the commune's own vehicle, the courier's own legs.

   Unlike the transit recipes this one needs no GTFS at all — bicycle costing routes
   on the OSM tiles already built — so its arc times are real from the first
   refresh. It is also the recipe that puts a vehicle back under the commune's own
   capacity: the bike is `use`d, so a fleet of two bounds simultaneous hauls and a
   scarce fleet pulls to grow."
  (seed-relocation-recipe! recipe-store
    #:process "rp-bt-cargo-bike" #:recipe "recipe-bt-cargo-bike"
    #:name "Cargo-bike haul: pick-up → drop-off"
    #:pspec-name "Cargo-Bike Haul"
    #:good "spec-bt-freight" #:payload 100.0 #:unit "kg"
    #:duration (make-duration 0.75 "hours")
    #:tags '("tag:transport" "tag:freight" "tag:cycle")
    #:uses '(("spec-bt-cargo-bike" . 0.075))
    #:work '("spec-bt-courier" . 0.075)
    #:consumes '(("spec-bt-charge" 0.015 "kWh"))))

;; ─── Tenure: the pass and the Lastenrad as held resources ───────────────────
;; The recipes above say a ride `use`s a pass. WHOSE pass, and who can take it
;; away, is the tenure question, and it is answered by the same custody/rights
;; split comms/fragility.scm reads for a platform account — no new state model:
;;
;;   primary-accountable — holds the rights, can revoke
;;   custodian-scope     — holds it, uses it, depends on it
;;
;; A Deutschlandticket the commune subscribes to is accountable to the operator,
;; who can suspend it; one a member commons into the use-pool stays accountable
;; to that member, who can recall it. Both are SPLIT, so resource-rented? is true
;; of both and rented-goods lifts "Svc|spec-bt-transit-pass" into the frag wheel's
;; rented sector — the plan can see that its mobility rests on capacity it does
;; not hold rights over, and the barrier gets steeper the harder it leans.
;;
;; That is the difference worth having. A fare consumed per trip prices mobility;
;; a pass held under someone else's rights prices DEPENDENCE, which is the thing
;; that actually fails — a suspended subscription cancels every ride at once,
;; and no per-trip cost anywhere in the plan would have predicted that. The
;; single-fare spec stays seeded for the trips that really are bought one at a
;; time, as a `consume` flow the caller adds.
;;
;; Berlin makes the same contrast available for the bikes: a Lastenrad from a
;; free-loan pool (fLotte and the district Kiez schemes) is custody without
;; rights and belongs in the same sector; one the commune bought is sovereign and
;; draws nothing.
(define %bt-transit-operator "org:vbb")
(define %bt-network-specs
  '("spec-bt-ubahn" "spec-bt-sbahn" "spec-bt-tram" "spec-bt-bus"))
(define %bt-bike-lender     "org:cargo-bike-pool")

(define* (bt-transit-pass-resource id scope #:key (rights-holder #f) (at #f) (count 1.0))
  "Berlin's pass: the operator can suspend a subscription, a member can recall one
   they commoned. Both are custody without rights (transit-shed.scm)."
  (pass-resource id "spec-bt-transit-pass" scope #:operator %bt-transit-operator
                 #:rights-holder rights-holder #:at at #:count count))

(define* (bt-network-resource spec scope #:key (at #f) (seat-hours 200.0)
                                        (operator %bt-transit-operator))
  "One of Berlin's four networks as a held resource — the U-Bahn in the same sense
   spec-car is the car: a means the plan `use`s and can run out of. Not property:
   the operator holds the rights and can withdraw the service (a strike, a closed
   line, a fare regime change), so it lands in the rented sector beside the pass."
  (network-resource spec scope #:operator operator #:at at #:seat-hours seat-hours))

(define* (berlin-network-resources scope #:key (at #f) (seat-hours 200.0)
                                              (specs %bt-network-specs))
  "One held service resource per network the commune plans on."
  (map (lambda (spec) (bt-network-resource spec scope #:at at #:seat-hours seat-hours))
       specs))

(define* (berlin-transit-svc-caps resources periods #:key (specs '()) (hours-of #f))
  "The per-period service caps the solve consumes, read off what the commune HOLDS:
   every mobility holding, not only the four networks — the pass, the bought bike
   and the loaned one all have a `use` drawing their pool, and an uncapped pool is a
   free one. The number lives on the resource and is stated exactly once."
  (held-svc-caps resources periods #:specs specs #:hours-of hours-of))

(define* (bt-cargo-bike-resource id scope #:key (loaned? #f) (at #f) (count 1.0))
  "The held Lastenrad: bought it is the commune's own, drawn from a free-loan pool
   (#:loaned? #t) it is custody without rights, like the networks."
  (vehicle-resource id "spec-bt-cargo-bike" scope
                    #:lender (and loaned? %bt-bike-lender) #:at at #:count count))

(define* (berlin-transit-resources scope #:key (pass-holders '()) (loaned-bikes 0)
                                              (owned-bikes 1) (at #f))
  "The commune's mobility holdings as VF resources: one pass per entry in
   PASS-HOLDERS (an agent id, or #f for an operator subscription), plus the bikes.
   Feed the result to rented-goods to get the frag wheel's rented sector."
  (append
   (map (lambda (h i)
          (bt-transit-pass-resource
           (string-append "res-bt-pass-" (number->string i)) scope
           #:rights-holder h #:at at))
        pass-holders (iota (length pass-holders)))
   (map (lambda (i) (bt-cargo-bike-resource
                     (string-append "res-bt-cargo-loan-" (number->string i))
                     scope #:loaned? #t #:at at))
        (iota loaned-bikes))
   (map (lambda (i) (bt-cargo-bike-resource
                     (string-append "res-bt-cargo-own-" (number->string i))
                     scope #:at at))
        (iota owned-bikes))))

(define (seed-berlin-transit! recipe-store)
  "Seed the whole Berlin transport arm — specs, the seven travel modes and the
   two freight recipes — and return the modes."
  (seed-berlin-transit-specs recipe-store)
  (for-each (lambda (mode) (seed-recipe-entry! recipe-store mode)) *berlin-mode-recipes*)
  (seed-berlin-transit-haul-recipe recipe-store)
  (seed-berlin-cargo-bike-recipe recipe-store)
  *berlin-mode-recipes*)
