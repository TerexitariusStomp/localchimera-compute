;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; transit-shed.scm — a shed's transport as mechanism, with the city as data
;;;
;;; The twin of farm-commune-seed.scm. That file says a farm is DATA — its crops,
;;; where it sits, its scarce inputs — and keeps the seeding shared; the per-region
;;; files (berlin-commune-seed.scm, bay-area) are thin config over it. This is the
;;; same split for MOVING: what a city's transport differs in is a table of modes,
;;; a table of specs, who operates the networks and where the market is. The
;;; machinery below is region-free.
;;;
;;; ── What a shed declares ────────────────────────────────────────────────────
;;;   MODES     one transport recipe per mode over the generic mover
;;;             (recipes/transport.scm mode-recipe), seeded into the scope's
;;;             recipe store like any recipe (seed-recipe-entry!); the engine
;;;             finds them there and instantiates each per rider. A transit
;;;             mode `use`s a network and names no driver: boarding occupies a
;;;             seat (so its per-km rate is the mode's own pace, measured in
;;;             seat-hours) while no member of the commune drives the train. A
;;;             shed's own vehicle — a bike — is `use`d the same way, and the
;;;             rider is their own motor. Each mode's process carries the
;;;             router's costing ("multimodal", "bus", "bicycle",
;;;             "pedestrian") as its manner classification.
;;;   PACES     manner → fallback hours/km, until a matrix measures the real one.
;;;   SPECS     one row per ResourceSpecification (knowledge/recipes/store.scm rows).
;;;
;;; ── Quantities are PER UNIT MOVED, PER KM ───────────────────────────────────
;;; The rule and its reasoning live in recipes/transport.scm's header, which these
;;; recipes are shaped after: the arc tiling relocates ±1 of the good per column
;;; unit whatever a pickup flow says, then scales every input by the arc. So a
;;; freight recipe's rates are the per-trip figure DIVIDED BY its payload, and
;;; `#:payload` does that division (transport.scm relocation-recipe) so a caller
;;; states the per-trip figure it actually knows.
;;;
;;; ── Capacity ────────────────────────────────────────────────────────────────
;;; A network, a pass and a vehicle are all `use`d, so each draws a per-period
;;; `Svc|spec` pool, and what bounds that pool is read off the HOLDING — the
;;; seat-hours a network is worth are stated once, on the resource, and the solve
;;; converts them (utils/capacity.scm; a scope assembling its own caps table calls
;;; the same conversion through `held-svc-caps`).
;;;
;;; A holding at a place that CONTAINS other places is bounded across all of them at
;;; once, as one pool, rather than at each — see the note above `network-resource`.
;;;
;;; ── Tenure ──────────────────────────────────────────────────────────────────
;;; None of this says a commune owns a train. A network resource is accountable to
;;; its OPERATOR with the commune as custodian; a pass to the operator or to the
;;; member who commoned it; a loaned vehicle to the pool that lends it. All three
;;; are custody without rights, so `rented-goods` (schemas.scm) lifts them into
;;; the frag wheel's rented sector — the plan can see that its mobility rests on
;;; capacity someone else can withdraw. A bought vehicle is sovereign and draws
;;; nothing.

(define-module (localchimera knowledge recipes transit-shed)
  #:use-module ((localchimera utils units) #:select (%count-unit))
  #:use-module (localchimera vf schemas)
  #:use-module (goblins)
  #:use-module (localchimera knowledge recipes transport)
  #:export (transit-manners seed-relocation-recipe!
            network-vehicle-resource network-resource pass-resource vehicle-resource)
  #:use-module (srfi srfi-1))


(define* (transit-manners #:key (mobile-people? #f))
  "The manners bag a shed hands to plan-scope. The modes reach a solve as recipes, from
   the scope's store, and carry their own costing and pace; a trip's manner is read off
   its mode, and a manner's typical pace off the router's own table. What is left for
   the bag is switches: #:mobile-people? asks for its PEOPLE to be read as movers too
   (off by default — see *mobile-people?* in planner.scm for the degeneracy that gates it)."
  (if mobile-people? '((mobile-people . #t)) '()))

;; ── a shed's own relocation, seeded ──────────────────────────────────────────
;; recipes/transport.scm builds the recipe (relocation-recipe) and seeds it
;; (seed-recipe-entry!); what a shed adds is a process specification of its own,
;; named for the kind of haul.
(define* (seed-relocation-recipe! recipe-store
                                  #:key process recipe name pspec-name
                                  good (payload 1.0) unit duration (tags '())
                                  (uses '()) (work #f) (consumes '()))
  "Seed one pickup→dropoff recipe under its own process specification
   PSPEC-NAME. The rates are per trip per km (relocation-recipe)."
  (let ((pspec (string-append "pspec-" process)))
    (seed-recipe-entry! recipe-store
      (relocation-recipe process name good #:payload payload #:unit unit
                         #:duration duration #:tags tags #:pspec pspec
                         #:uses uses #:work work #:consumes consumes)
      #:recipe recipe
      #:pspec (make-process-specification #:id pspec #:name pspec-name))))

;; ── holdings ─────────────────────────────────────────────────────────────────
;; WHERE A NETWORK'S SEATS ARE. A line is not at a station; it runs THROUGH them,
;; and its seats are boardable at any of them. That is containment, and it is stated
;; the way containment is stated anywhere else:
;;
;;   the SEATS are `contained-in` a train      (an EconomicResource)
;;   the TRAIN sits at the LINE               (a SpatialThing that contains stations)
;;
;; so the seats resolve to the line by the containment walk (`resource-place`), and
;; the line being a container makes their service one POOL over every station under
;; it (`ingest-stock!`): boardable anywhere on the line, and the same seat spent at
;; Alexanderplatz is not still free at Kottbusser Tor.
;;
;; Pinning the seats to one station instead is the reading that fails in both
;; directions at once — rides from that station are bounded, and rides from every
;; other station draw a pool with no bound at all.
(define* (network-vehicle-resource spec scope #:key operator (at #f))
  "The rolling stock a network's seats sit in — one vehicle, standing on the line.
   It carries no capacity of its own: what the plan rations is the SEATS, and this
   exists to say where they are (see `network-resource #:in-vehicle`). AT is the line."
  (let ((q (make-measure 1.0 %count-unit)))
    (make-economic-resource #:id (string-append "res-veh-" spec) #:name spec
                            #:conforms-to (string-append spec "-vehicle")
                            #:classified-as '("infrastructure" "network" "transit" "vehicle")
                            #:accounting-quantity q #:onhand-quantity q #:current-location at #:primary-accountable operator #:custodian-scope scope)))

(define* (network-resource spec scope #:key operator (at #f) (seat-hours 200.0)
                                              (per "day") (in-vehicle #f))
  "A network's service as a held resource: SEAT-HOURS per PER of it that this
   commune plans on, custodied by SCOPE, accountable to its OPERATOR — who can
   withdraw the service, which is why this lands in the rented sector.

   SEAT-HOURS is a governance number, not a physical one: an operator's real
   capacity is orders larger, and what bounds a commune's plan is the share it may
   honestly claim — smaller at 08:30 than at 11:00.

   PER names the period those hours are denominated over — a day by default, a
   week or a month for a pass sold that way. A capacity is a RATE, so it is held
   as one quotient unit (`hours/day`) and means the same number of seat-hours
   however finely the solve slices its periods (utils/units.scm §division units).

   IN-VEHICLE places the seats INSIDE a vehicle resource by id, so where they are is
   read off the vehicle and, through it, the line (see the note above). AT is then
   left to the vehicle. Absent, the seats sit at AT directly — the reading for a
   service with no rolling stock to speak of."
  (let ((q (make-measure seat-hours (string-append "hours/" per))))
    (make-economic-resource #:id (string-append "res-net-" spec) #:name spec
                            #:conforms-to spec #:classified-as '("infrastructure" "network" "transit")
                            #:accounting-quantity q #:onhand-quantity q #:current-location (and (not in-vehicle) at) #:primary-accountable operator #:custodian-scope scope
                            #:contained-in in-vehicle)))

(define* (pass-resource id spec scope #:key operator (rights-holder #f) (at #f) (count 1.0))
  "A held travel pass. RIGHTS-HOLDER defaults to the OPERATOR (a subscription they
   can suspend); pass a member's agent id for one commoned into the use-pool, whose
   holder can recall it. Custody sits with SCOPE either way, and rights do not."
  (let ((q (make-measure count %count-unit)))
    (make-economic-resource #:id id #:name id #:conforms-to spec #:classified-as '("infrastructure" "mobility" "pass")
                            #:accounting-quantity q #:onhand-quantity q #:current-location at #:primary-accountable (or rights-holder operator) #:custodian-scope scope)))

(define* (vehicle-resource id spec scope #:key (lender #f) (at #f) (count 1.0))
  "A held vehicle. Bought by the commune it is sovereign — SCOPE is
   primary-accountable and nobody can pull it. Drawn from a free-loan pool (pass
   #:lender) it is custody without rights, and joins the rented sector."
  (let ((q (make-measure count %count-unit)))
    (make-economic-resource #:id id #:name id #:conforms-to spec #:classified-as '("infrastructure" "vehicle")
                            #:accounting-quantity q #:onhand-quantity q #:current-location at #:primary-accountable (or lender scope) #:custodian-scope scope)))
