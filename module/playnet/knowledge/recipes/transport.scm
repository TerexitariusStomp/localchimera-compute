;;; transport.scm — transport as a VF recipe: a vehicle is USED, the rider is
;;; PICKED UP / DROPPED OFF and CONTAINED in it for the trip.
;;;
;;; The frame, the right way up (VF-native):
;;;
;;;   • A vehicle is NOT a recipe and not "capacity" in the abstract. It is an
;;;     EconomicResource conforming to a ResourceSpecification ("Car"). Like any
;;;     means of provisioning, it is `use`d by a process — occupied, not consumed:
;;;     it still exists afterward, but is unavailable (and finite) during the trip.
;;;
;;;   • Transport is the RECIPE (a RecipeProcess). Its flows say what the trip does:
;;;       pickup   the rider at the origin      (input;  onhand −, locationEffect)
;;;       work     the rider's own time         (input;  resolved from the pickup)
;;;       use      the car for the trip's hours (input;  occupies the vehicle)
;;;       work     the driver's labour          (input)
;;;       consume  fuel/energy                  (input;  onhand −)
;;;       dropoff  the rider at the destination (output; onhand +, locationEffect,
;;;                                              containedEffect)
;;;     `pickup` and `dropoff` PAIR — the SAME resource enters and leaves; the rider
;;;     is not created or destroyed, only relocated. While in transit the rider is
;;;     `containedIn` the car (combine on pickup, separate on dropoff): not available
;;;     on its own until dropped off. The trip's DURATION is the transit time — the
;;;     faux frais — and it is the rider's, paid off their one time budget.
;;;
;;;     That containment is OURS. VF's own transport example (examples/ex-complex.md
;;;     §Transportation with transfer) does not model it, and moves custody between
;;;     AGENTS — the carrier Claudia receives custody of Alice's apples, and the
;;;     truck never appears in the custody chain at all. Containment says what a
;;;     thing is INSIDE; custody says which agent HOLDS it. Keeping them apart is
;;;     what stops a thing in a commune's own box from reading as held under
;;;     somebody else's rights (`resource-rented?`), and it is what lets a
;;;     socialized stash be the commune's while sitting in the same box.
;;;
;;;   • In the convex plan this compiles as a MOVE: pickup (onhand decrement ⇒ an
;;;     input that consumes rider@origin) + dropoff (onhand increment ⇒ an output
;;;     that produces rider@destination) = rider@A → rider@B. The driver `work`s
;;;     and fuel is `consume`d as costs. `use` compiles too: compile-process turns
;;;     it into a consume of the vehicle's per-period SERVICE good `Svc|spec-car`,
;;;     which is what makes the vehicle a FINITE shared resource (seats are
;;;     capacity; many riders + freight share one car; a scarce fleet gets a pull
;;;     to grow, as its Svc dual). That pool is capped by `#:eco-caps`, built with
;;;     `svc-eco-caps` (vf/formulas/capacity.scm) — a held vehicle's own onhand
;;;     caps the BARE good, never the per-period service, so a fleet seeded
;;;     without those caps is a fleet whose seats are free.
;;;
;;;   • STORAGE is the same recipe rotated from space into time: a warehouse/silo is
;;;     an EconomicResource `use`d by a "hold" process that `accept`s a resource at
;;;     (place,t) and `modify`s it out at (place,t+1) — `containedIn` the store
;;;     meanwhile, with retention < 1 as spoilage. Vehicle and warehouse are one
;;;     kind of thing (a provisioning resource being used); transport and storage are
;;;     one kind of recipe, differing only in whether pickup→dropoff crosses a
;;;     spatial or a temporal arc.
;;;
;;;   • QUANTITIES ON THE FLOWS ARE RATES, per rider and per km. The arc tiling
;;;     relocates ±1 of the good per column unit whatever the pickup flow says —
;;;     the pickup quantity declares the shape of a load, it does not scale the
;;;     costs — and then scales every input by the arc: `use`/`work` by the
;;;     network-time scale (T/pace, so congestion costs real vehicle- and
;;;     driver-hours), `consume` by true road km. So one column unit = one rider,
;;;     and the numbers below are what ONE rider costs for ONE kilometre. Only
;;;     `has-duration` on the process is a whole-journey figure.
;;;
;;;     The ride seeded here is a solo trip: one rider takes a whole car, so the
;;;     per-rider rates equal the per-vehicle rates. Sharing divides them by
;;;     occupancy — a full 4-seat car costs each rider a quarter of the driver's
;;;     hours and a quarter of the fuel, which is the same division a freight
;;;     recipe makes by its payload.
;;;
;;; This file seeds the concrete car-ride below; the same shape carries freight
;;; (swap the rider spec for a goods spec, and divide the rates by the payload) or
;;; a worker commuting to a worksite. A worked example of the same shape over a
;;; whole city — modes, capped networks, tenure — is
;;; knowledge/recipes/berlin-transit.scm.

;; ─── flow helpers for the transport actions (planner.scm has in/out/wrk) ─────
;; make-recipe-flow fields: id action conforms classified resource-qty effort
;;   input-of output-of clause stage state note is-primary resolve-from-flow
(define-module (playnet knowledge recipes transport)
  #:use-module ((playnet utils units) #:select (%count-unit %effort-unit))
  #:use-module (playnet vf schemas)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:export (pickup-flow dropoff-flow use-flow consume-flow* work-flow* recipe-hold
            recipe-carry relocation-recipe mode-recipe seed-recipe-entry!
            spec-car spec-petrol spec-rider transport-specs pspec-transport
            car-ride baseline-modes seed-baseline-modes! seed-transport-specs seed-transport-recipe))

(define* (pickup-flow id spec qty unit proc #:key (tags #f))
  (make-recipe-flow #:id id #:action 'pickup #:resource-conforms-to spec
                    #:resource-classified-as tags #:resource-quantity (make-measure qty unit)
                    #:recipe-input-of proc))
(define* (dropoff-flow id spec qty unit proc #:key (tags #f) (primary #t))
  (make-recipe-flow #:id id #:action 'dropoff #:resource-conforms-to spec
                    #:resource-classified-as tags #:resource-quantity (make-measure qty unit)
                    #:recipe-output-of proc #:is-primary primary))
(define (use-flow id spec count hours proc)     ; occupy COUNT of the resource for HOURS (both quantities)
  (make-recipe-flow #:id id #:action 'use #:resource-conforms-to spec
                    #:resource-quantity (make-measure count %count-unit)
                    #:effort-quantity (make-measure hours %effort-unit) #:recipe-input-of proc))
(define (consume-flow* id spec qty unit proc)
  (make-recipe-flow #:id id #:action 'consume #:resource-conforms-to spec
                    #:resource-quantity (make-measure qty unit) #:recipe-input-of proc))
(define (work-flow* id hours skill proc)
  (make-recipe-flow #:id id #:action 'work #:resource-conforms-to skill
                    #:effort-quantity (make-measure hours %effort-unit) #:recipe-input-of proc))

;; ─── The two bare shapes, as builders ───────────────────────────────────────
;; The car ride below is one filled-in instance of the frame above. These are the
;; frame itself, with nothing in it: HOLD (the pair through a container, so the
;; arc is time) and CARRY (the pair with no container, so the arc is space).
;; Everything else here — a ride, a freight run, a silo, a fridge, a box left
;; under a bridge — is one of the two with its blanks filled.
;;
;; Which arc a recipe tiles along is never marked on the recipe: the engine reads
;; it off the container's `keep-in-place` (proc-temporal?). So HOLD is not a
;; different KIND of process from CARRY; it is the same process using a thing
;; that stays put.

(define* (recipe-hold spec container-spec
                      #:key (id "rp-hold") (unit %count-unit) (hours 0.02) (loss 0.0)
                            (name "Keep it where it is"))
  "SPEC waits in a CONTAINER-SPEC container: pick it up, `use` the container,
   drop it off. When that container's spec is keep-in-place, the pair is an arc
   through TIME — the good is there tomorrow, having paid HOURS of the
   container's service for the stay. LOSS is spoilage, pilferage, weather: an
   ordinary consume, sized like wear. Returns (values recipe-process flows)."
  (values
   (make-recipe-process #:id id #:name name #:process-conforms-to "pspec-transport")
   (append
    (list (pickup-flow  (string-append id "/in")  spec 1.0 unit id)
          (dropoff-flow (string-append id "/out") spec 1.0 unit id)
          ;; a container's `use` is EFFORT alone — hours of holding. A vehicle's
          ;; counts seats as well, because a seat is a thing you occupy; a box
          ;; just keeps what is in it.
          (make-recipe-flow #:id (string-append id "/box") #:action 'use #:resource-conforms-to container-spec
                            #:effort-quantity (make-measure hours %effort-unit) #:recipe-input-of id))
    (if (> loss 0.0)
        (list (consume-flow* (string-append id "/loss") spec loss unit id))
        '()))))

(define* (recipe-carry spec skill
                       #:key (id "rp-carry") (unit %count-unit) (hours-per-km 0.21)
                             (name "Carry it there"))
  "SPEC moves between places under its own carrier: pick it up, work the
   journey, drop it off. No container, so the arc is through SPACE — and the
   same recipe carries a thing OUT as carries it IN, because a relocation arc
   runs both ways. HOURS-PER-KM is the carrier's pace (0.21 = walking, 4.8 km/h),
   per unit carried, per kilometre. Returns (values recipe-process flows)."
  (values
   (make-recipe-process #:id id #:name name #:process-conforms-to "pspec-transport")
   (list (pickup-flow  (string-append id "/in")   spec 1.0 unit id)
         (dropoff-flow (string-append id "/out")  spec 1.0 unit id)
         (work-flow*   (string-append id "/legs") hours-per-km skill id))))

;; ─── A relocation with its blanks filled: the one builder ───────────────────
;; A trip picks a good up, occupies whatever it rides in, spends somebody's
;; hours and maybe some fuel, and puts the good down. Which of those lines
;; appear is what separates a passenger ride (a seat and a pass) from a
;; hand-carried haul (a standing space and a courier) from a vehicle haul (the
;; commune's own bike, its courier, a little charge). A caller states the
;; per-TRIP rates it knows and PAYLOAD divides them into the per-unit·km rates
;; the arc tiling reads.
(define* (relocation-recipe id name good
                            #:key (payload 1.0) (unit %count-unit)
                                  (uses '())       ; ((spec . hours-per-trip-km) …) — a vehicle, a network seat, a pass held
                                  (work #f)        ; (skill . hours-per-trip-km) — a driver, a courier
                                  (consumes '())   ; ((spec qty-per-trip-km unit) …) — fuel, charge
                                  (duration #f) (tags '("tag:transport"))
                                  (pspec "pspec-transport"))
  "The pickup→dropoff recipe ID as (recipe-process flows): PAYLOAD of GOOD
   picked up and put down, with USES, WORK and CONSUMES at their per-trip rates
   per km, each divided by PAYLOAD."
  (let ((per (lambda (x) (/ x payload)))
        (fid (lambda parts (apply string-append id parts))))
    (list
     (make-recipe-process #:id id #:name name #:process-conforms-to pspec
                          #:process-classified-as tags #:has-duration duration)
     (append
      (list (pickup-flow (fid ".pu") good payload unit id))
      (map (lambda (u) (use-flow (fid ".use." (car u)) (car u) 1.0 (per (cdr u)) id)) uses)
      (if work (list (work-flow* (fid ".work") (per (cdr work)) (car work) id)) '())
      (map (lambda (c) (consume-flow* (fid ".in." (car c)) (car c) (per (cadr c)) (caddr c) id))
           consumes)
      (list (dropoff-flow (fid ".do") good payload unit id))))))

;; ─── A travel MODE is a relocation whose mover works the journey ────────────
;; What makes a relocation a way for PEOPLE (and whatever else moves itself) to
;; travel is one flow: a `work` resolved from the recipe's own pickup — the
;; work of the one being moved. Its skill is what the mover bears to travel
;; this way ("walk", "cycle"); naming the moved spec itself says being carried
;; is all it takes. Its hours per km are the mover's own time on the way. The
;; engine finds a scope's modes by that flow and instantiates each per rider,
;; swapping the generic mover for the rider's own good
;; (engine.scm mover-ride-templates). The router's costing is the process's
;; "manner:<costing>" classification.
(define* (mode-recipe name
                      #:key skill pace manner
                            (uses '()) (work #f) (consumes '()) (duration #f)
                            (good "spec-rider")
                            (id (string-append "rp-mode-" name))
                            (pspec (string-append "pspec-" name)))
  "The travel mode NAME as (recipe-process flows): relocation-recipe's one GOOD,
   worked on the way by the mover — SKILL (the moved spec itself when anyone may
   ride) at PACE hours per km, the manner's fallback pace when unstated. PSPEC is
   the mode's own process specification: a ride performed under it names this mode."
  (let* ((entry (relocation-recipe id name good
                                   #:uses uses #:work work #:consumes consumes #:duration duration #:pspec pspec
                                   #:tags (append (if manner (list (string-append "manner:" manner)) '())
                                                  '("tag:transport"))))
         (pickup (find (lambda (f) (eq? 'pickup (recipe-flow-action f))) (cadr entry))))
    (list (car entry)
          (append (cadr entry)
                  (list (make-recipe-flow #:id (string-append id ".self") #:action 'work #:resource-conforms-to (or skill good)
                                          #:effort-quantity (and pace (make-measure pace %effort-unit)) #:recipe-input-of id #:resolve-from-flow (recipe-flow-id pickup)))))))

;; ─── Resource specifications (the TYPES; instances conform to these) ─────────
(define spec-car
  (make-resource-specification
    #:id "spec-car" #:name "Car"
    #:resource-classified-as '("vf:vehicle" "vf:passenger" "vf:seats:4")   ; capability advertisement; 4 seats = its capacity when `use` is read
    #:default-unit-of-resource %count-unit))

(define spec-petrol
  (make-resource-specification
    #:id "spec-petrol" #:name "Petrol"
    #:resource-classified-as '("vf:energy" "vf:fuel")
    #:default-unit-of-resource "litre"))

(define spec-rider
  (make-resource-specification
    #:id "spec-rider" #:name "Rider (person in transit)"
    #:resource-classified-as '("vf:person" "vf:passenger")                 ; the SAME resource is picked up and dropped off — only its location changes
    #:default-unit-of-resource %count-unit))

(define transport-specs (list spec-car spec-petrol spec-rider))

;; ─── Process specification + recipe-process (the trip itself) ────────────────
(define pspec-transport
  (make-process-specification
    #:id "pspec-transport" #:name "Transport (pick-up → drop-off)"))

;; ─── The car ride: USE the car, PICK UP the rider, drive, burn fuel, DROP OFF ─
;; A travel mode like any other — anyone may be driven, so the rider's own
;; work names no skill, only their 0.02 h/km on the way. Rates per rider·km: a
;; 20 km trip costs 0.4 car-hours, 0.4 driver-hours and 1.2 litres, the
;; whole-journey figures the 0.4 h duration describes.
(define car-ride
  (mode-recipe "car" #:id "rp-ride" #:pace 0.02 #:manner "auto"
               #:uses '(("spec-car" . 0.02))             ; the car is occupied while it drives
               #:work '("spec-driving" . 0.02)           ; the driver's labour
               #:consumes '(("spec-petrol" 0.06 "litre")) ; ~6 L/100 km
               #:duration (make-duration 0.4 %effort-unit)))

;; ─── Seeding ─────────────────────────────────────────────────────────────────
(define (seed-transport-specs recipe-store)
  "Register the car / petrol / rider resource specs."
  (for-each (lambda (s) ($ recipe-store 'add-resource-spec s)) transport-specs))

(define* (seed-recipe-entry! recipe-store entry #:key (pspec #f) (recipe #f))
  "Seed one relocation — (recipe-process flows), as relocation-recipe and
   mode-recipe build it — into the catalogue: its process spec (PSPEC, else the
   one its process names), its process, its flows, and the recipe whose output is
   the good it puts down."
  (let* ((rp (car entry)) (flows (cadr entry)) (pid (recipe-process-id rp))
         (spec-id (recipe-process-process-conforms-to rp))
         (pspec (or pspec
                    (if (or (not spec-id) (equal? spec-id "pspec-transport"))
                        pspec-transport
                        (make-process-specification #:id spec-id #:name (recipe-process-name rp))))))
    ($ recipe-store 'add-process-spec pspec)
    ($ recipe-store 'add-recipe-process rp)
    (for-each (lambda (f) ($ recipe-store 'add-recipe-flow f)) flows)
    ($ recipe-store 'add-recipe
       (make-recipe #:id (or recipe (string-append "recipe-" pid)) #:name (recipe-process-name rp)
                    #:primary-output (recipe-flow-resource-conforms-to
                     (find (lambda (f) (eq? 'dropoff (recipe-flow-action f))) flows))
                    #:recipe-processes (list pid)))))

;; ─── Every scope's own ways to travel ───────────────────────────────────────
;; Walking, a bicycle and a car are modes of any scope (a journey is filed under
;; the scope's mode for the way it was made, so a scope with no transit shed still
;; records a trip against a recipe). They cost nothing in a solve until a shed
;; reads its people as movers. A seeder with its own definition of one (Berlin's
;; bike rides the commune's bikes) seeds it after, and its definition replaces.
(define baseline-modes
  (list (mode-recipe "walk" #:skill "walk" #:pace 0.200 #:manner "pedestrian")
        (mode-recipe "bike" #:skill "cycle" #:pace 0.055 #:manner "bicycle")
        car-ride))

(define (seed-baseline-modes! recipe-store)
  "Seed the baseline modes into RECIPE-STORE, those it does not hold already."
  (seed-transport-specs recipe-store)
  (for-each (lambda (entry)
              (unless ($ recipe-store 'get-recipe-process (recipe-process-id (car entry)))
                (seed-recipe-entry! recipe-store entry)))
            baseline-modes))

(define (seed-transport-recipe recipe-store)
  "Seed the car ride. Assumes seed-transport-specs has been called on the same store."
  (seed-recipe-entry! recipe-store car-ride #:recipe "recipe-transport"))
