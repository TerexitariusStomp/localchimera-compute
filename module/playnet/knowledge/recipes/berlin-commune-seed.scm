;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; berlin-commune-seed.scm — the Berlin/Brandenburg commune as DATA over the generic
;;; seed-farm-commune! (farm-commune-seed.scm). Just the three grain staples, their
;;; per-crop summer water + German yields, and where the farm sits in the shed.
;;;
;;; The yields = *berlin-derived-yields* (OWID/FAOSTAT, Germany); kept explicit here so the
;;; live seed has no cross-module load dependency — test-berlin-live-scope asserts they
;;; equal *berlin-crop-yields* so they can never silently drift from the vendored data.

;; staple → (summer-water-ML/ha . yield-kg/ha). maize ~2× as thirsty as the small grains.
(define-module (playnet knowledge recipes berlin-commune-seed)
  #:use-module ((playnet utils units) #:select (%effort-unit))
  #:use-module (playnet knowledge recipes farm-commune-seed)
  #:use-module (playnet vf schemas)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (playnet knowledge recipes berlin-transit)
  #:export (*berlin-commune-crops* seed-berlin-transit-arm! seed-berlin-commune!))

(define *berlin-commune-crops*
  '(("wheat"  . (2.2 . 7442.9))
    ("barley" . (1.8 . 6703.5))
    ("maize"  . (4.0 . 9610.0))))

;; ── the transport arm ────────────────────────────────────────────────────────
;; A farm alone is one cell, and one cell has nothing to move between. This gives
;; the commune a second place in the city — a market hall it delivers to — and
;; the means to reach it: the shed's transit recipes and modes
;; (knowledge/recipes/berlin-transit.scm), a pass, and a Lastenrad or two.
;;
;; Everything here is placed contained-in the SHED, not in the farm, so the
;; market inherits Berlin's futures and limits by the same containment walk the
;; farm does — a drought is a drought at both ends of the trip.
;;
;; The modes are recipes in the same store as the rest, so a solve finds them
;; there. What a caller adds is the shed's costings and fallback paces, as
;; `berlin-transit-manners`:
;;
;;   (plan-scope root #:manners berlin-transit-manners
;;                    #:eco-caps (berlin-transit-svc-caps ($ obs 'all-resources) periods)
;;                    #:demand (list (cons "food#berlin-markthalle@0" …)))
;;
;; …and the mover then tiles this commune's rides by U-Bahn, tram or cargo bike.
;; Without #:manners every recipe still plans; the modes then price their arcs
;; by their own pace over distance.
;;
;; #:eco-caps is what makes a seat SCARCE. A `use` of spec-bt-ubahn draws the
;; per-period service good Svc|spec-bt-ubahn, and a held resource's stock caps
;; the BARE good, never the service — so without those caps the seat pool is
;; unbounded and the whole commune boards the same train for free. The caps are
;; read straight off the holdings seeded here, so the seat-hours a network is
;; worth are declared once, on the resource.
(define* (seed-berlin-transit-arm! scope
                                   #:key (place "berlin-commune-farm") (shed "berlin")
                                         (market "berlin-markthalle")
                                         (market-name "Berlin market hall")
                                         (market-lat 52.5017) (market-lon 13.4344)
                                         (pass-holders (list #f))   ; #f = an operator subscription
                                         (owned-bikes 1) (loaned-bikes 1)
                                         (courier-hours 20.0) (seat-hours 200.0)
                                         (charge-kwh #f))
  (let* ((rs ($ scope 'recipe-store)) (obs ($ scope 'observer))
         (sts ($ scope 'spatial-thing-store)) (as ($ scope 'agent-store))
         (commune (string-append "commune-" place))
         (worker  (string-append "worker-" place)))
    ;; the specs and the three recipes (transit ride, hand-carried haul, Lastenrad)
    (seed-berlin-transit! rs)
    ;; somewhere to go, hanging under the shed like the farm does
    ($ sts 'add-location
       (make-spatial-thing #:id market #:name market-name #:lat market-lat #:long market-lon
                           #:contained-in shed))
    ;; …and somebody there. A SpatialThing alone is not a CELL: the located model
    ;; takes its places from the resources and agents that sit in them, so a
    ;; market with nobody in it generates no cell, no arc, and therefore no haul
    ;; column — the trips would silently not exist. The market hall is an agent
    ;; the commune delivers to, which is both true and what makes the place real.
    ($ as 'add-agent (make-agent #:id market #:type 'organization #:name market-name
                                 #:primary-location market #:classified-as '()))
    ;; the courier's hours — a real budget the hauls draw on, borne by the worker
    ($ obs 'record-resource
       (make-economic-resource #:id (string-append "courier-" place) #:name "courier hours"
                               #:conforms-to "spec-bt-courier" #:classified-as '()
                               #:accounting-quantity (make-measure courier-hours %effort-unit)
                               #:onhand-quantity (make-measure courier-hours %effort-unit) #:primary-accountable worker))
    ;; the ELECTRICITY the e-assist runs on. Without it the Lastenrad haul draws
    ;; charge from nowhere — the recipe consumes 0.015 kWh per trip-km and nothing
    ;; supplies it, so the plan gets free propulsion and the raw-lint says so.
    ;; A battery is a real bound and a small one: ~0.6 kWh per bike per period is
    ;; a typical cargo e-bike pack, which at 15 Wh/km loaded is ~40 km of hauling.
    ;; Scaling the fleet without scaling the charge is exactly the mistake this
    ;; makes visible, so the default rides the bike count.
    ($ obs 'record-resource
       (let ((kwh (or charge-kwh (* 0.6 (+ owned-bikes loaned-bikes)))))
         (make-economic-resource #:id (string-append "charge-" place) #:name "e-assist battery charge" #:conforms-to "spec-bt-charge" #:classified-as '()
                                 #:accounting-quantity (make-measure kwh "kWh") #:onhand-quantity (make-measure kwh "kWh")
                                 #:current-location place #:primary-accountable commune)))
    ;; the mobility holdings, tenure and all: the networks, the passes and the
    ;; loaned bikes are custody without rights (rented-goods lifts them into the
    ;; frag wheel's rented sector), the bought bikes are the commune's own.
    (for-each (lambda (r) ($ obs 'record-resource r))
              (append
                (berlin-network-resources commune #:at place #:seat-hours seat-hours)
                (berlin-transit-resources commune
                                          #:pass-holders pass-holders
                                          #:owned-bikes owned-bikes
                                          #:loaned-bikes loaned-bikes
                                          #:at place)))
    market))

;; Seed a live Berlin commune's stores: the farm placed contained-in "berlin", so the live
;; solve inherits the shed's real drought futures + water/soil limits by containment.
;; #:transit? adds the transport arm above — the market it delivers to and the means to
;; get there. Omitted, the commune is the farm alone and the solve is what it always was.
(define* (seed-berlin-commune! scope #:key (land-ha 2.0) (water 6.0) (labour-h 2.0)
                                     (place "berlin-commune-farm") (shed "berlin")
                                     (transit? #f) (charge-kwh #f))
  (seed-farm-commune! scope
    #:crops *berlin-commune-crops* #:place place #:place-name "Berlin commune farm"
    #:lat 52.48 #:lon 13.40 #:parent shed
    #:tree (list (make-spatial-thing #:id "biosphere" #:name "The biosphere" #:lat 0.0 #:long 0.0)
                 (make-spatial-thing #:id "germany" #:name "Germany" #:lat 51.0 #:long 10.0
                                     #:contained-in "biosphere")
                 (make-spatial-thing #:id shed #:name "Berlin/Brandenburg" #:lat 52.52 #:long 13.40
                                     #:contained-in "germany"))
    #:skill "farming" #:skill-label "Farm labour" #:skill-hours 400.0
    #:worker-name "Brandenburg grower" #:commune-name "Berlin commune"
    ;; with the transport arm the grower is a RIDER, and these are the
    ;; capabilities Berlin's modes gate on (berlin-transit.scm's mode table) —
    ;; folded into her skills list beside "farming", not a separate concept.
    #:worker-tags (if transit? '("walk" "cycle" "transit-access") '())
    #:land-ha land-ha #:water water #:labour-h labour-h)
  (when transit? (seed-berlin-transit-arm! scope #:place place #:shed shed
                                           #:charge-kwh charge-kwh))
  place)
