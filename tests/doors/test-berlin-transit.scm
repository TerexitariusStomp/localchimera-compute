;;; test-berlin-transit.scm — Berlin's modes, recipes and mobility tenure
;;;
;;; Run from repo root:
;;;   guile --no-auto-compile -q -L module \
;;;     tests/doors/test-berlin-transit.scm
;;;
;;; Three things are checked, and the third is the one that matters: that a pass
;;; the commune holds under someone else's rights reaches the frag wheel's rented
;;; sector by the SAME custody/rights test a rented platform account does.

(use-modules (playnet solve world) ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet knowledge recipes store) (playnet knowledge recipes berlin-commune-seed) (playnet knowledge recipes berlin-transit) (playnet knowledge recipes transit-shed) (playnet knowledge recipes transport) (playnet vf formulas capacity) (playnet scope root) (playnet vf schemas) (srfi srfi-1))
(use-modules (playnet doors service))
(use-modules (playnet scope live))   ; plan-scope->alist
(use-modules (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1)
             (srfi srfi-13))

(display "\n── Setup: Berlin transit ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Berlin Transit Test"))
    store))

;; a mode is a transport recipe, (recipe-process flows), and every fact about it
;; is read off the recipe: the network and the pass as `use` flows, a driver as a
;; `work` flow, the mover's own skill and pace on the work flow resolved from the
;; pickup (engine mrec-skill / mrec-pace)
(define mrec-name  (@ (playnet solve engine) mrec-name))
(define mrec-skill (@ (playnet solve engine) mrec-skill))
(define mrec-pace  (@ (playnet solve engine) mrec-pace))
(define mrec-manner (@ (playnet solve engine) mrec-manner))
(define (entry-flows e action)
  (filter (lambda (f) (eq? action (recipe-flow-action f))) (cadr e)))
(define (entry-vehicle e)
  (let ((u (entry-flows e 'use))) (and (pair? u) (recipe-flow-resource-conforms-to (car u)))))
(define (mode-of name) (find (lambda (m) (equal? name (mrec-name m))) *berlin-mode-recipes*))
(define (mode-skill n) (mrec-skill (mode-of n)))
(define (mode-vehicle n)    (entry-vehicle (mode-of n)))
(define (entry-driver e)     ; a `work` flow beside the mover's own
  (and=> (find (lambda (f) (not (recipe-flow-resolve-from-flow f))) (entry-flows e 'work))
         recipe-flow-resource-conforms-to))
(define (mode-driver n)     (entry-driver (mode-of n)))
(define (mode-veh/km n)     (let ((u (entry-flows (mode-of n) 'use)))
                              (if (pair? u) (measure-has-numerical-value (recipe-flow-effort-quantity (car u))) 0.0)))
(define (mode-h/km n)       (mrec-pace (mode-of n)))

(display "\n── Ride modes ──\n")
(check-pred "the shed's modes cover walk, U-Bahn, S-Bahn, tram, bus and both bikes"
            (every mode-of '("walk" "ubahn" "sbahn" "tram" "bus" "bike" "cargo-bike")))
(define *networks* '("ubahn" "sbahn" "tram" "bus"))
(check-pred "the U-Bahn is a VEHICLE the ride occupies, like the car in transport.scm"
            (and (equal? "spec-bt-ubahn" (mode-vehicle "ubahn"))
                 (> (mode-veh/km "ubahn") 0.0)))       ; seats are drawn
(check-pred "a seat is held for the whole ride: seat-hours per km = the mode's pace"
            (every (lambda (n) (= (mode-veh/km n) (mode-h/km n))) *networks*))
(check-pred "the four networks are separately scarce — one spec each"
            (= 4 (length (delete-duplicates (map mode-vehicle *networks*)))))
(check-pred "no member drives the train — the driver column stays empty"
            (every (lambda (n) (not (mode-driver n))) *networks*))
(check-pred "the cargo bike DOES draw a vehicle, and the courier is their own driver"
            (and (equal? "spec-bt-cargo-bike" (mode-vehicle "cargo-bike"))
                 (not (mode-driver "cargo-bike"))
                 (> (mode-veh/km "cargo-bike") 0.0)))
(check-pred "transit asks a skill of its rider, so nobody is silently assumed able"
            (every (lambda (n) (equal? "transit-access" (mode-skill n))) *networks*))
(check-pred "every mode maps onto a real Valhalla costing"
            (every (lambda (m)
                     (member (mrec-manner m)
                             '("pedestrian" "bicycle" "auto" "bus" "multimodal")))
                   *berlin-mode-recipes*))
(check-pred "rail is faster per km than the tram, which beats the bike, which beats walking"
            (and (< (mode-h/km "sbahn") (mode-h/km "ubahn"))
                 (< (mode-h/km "ubahn") (mode-h/km "tram"))
                 (< (mode-h/km "tram")  (mode-h/km "cargo-bike"))
                 (< (mode-h/km "cargo-bike") (mode-h/km "walk"))))

(display "\n── The manners bag carries no copy of the modes ──\n")
(check-pred "a trip's costing is read off its mode recipe, so the bag holds no mode→costing map"
            (not (assq-ref berlin-transit-manners 'mode)))
(check-pred "…no copy of the modes, and no manner for bare moves or the commute"
            (and (not (assq-ref berlin-transit-manners 'mode-recipes))
                 (not (assq-ref berlin-transit-manners 'material))
                 (not (assq-ref berlin-transit-manners 'commute))))

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    (seed-berlin-transit! rs)

    (display "\n── Recipes ──\n")
    (check-pred "all seven modes are recipes in the store"
                (every (lambda (m) ($ rs 'get-recipe-process (recipe-process-id (car m))))
                       *berlin-mode-recipes*))
    (check-pred "the U-Bahn mode relocates ONE rider — picked up and put down"
                (and (find-flow (process-inputs rs "rp-mode-ubahn") "spec-rider" #:action 'pickup)
                     (find-flow (process-outputs rs "rp-mode-ubahn") "spec-rider" #:action 'dropoff)))
    ;; quantities on a transport recipe are RATES — the arc tiling multiplies every
    ;; input by the distance covered, so 0.050 is seat-hours PER KM (a 10 km ride
    ;; draws 0.5).
    (check-pred "the ride occupies a seat at 0.050 seat-hours per km"
                (let ((f (find-flow (process-inputs rs "rp-mode-ubahn") "spec-bt-ubahn" #:action 'use)))
                  (and f (= 0.050 (measure-has-numerical-value (recipe-flow-effort-quantity f))))))
    (check-pred "…and the rider's own time rides beside it, as work resolved from the pickup"
                (let ((f (find-flow (process-inputs rs "rp-mode-ubahn") "transit-access" #:action 'work)))
                  (and f (recipe-flow-resolve-from-flow f)
                       (= 0.050 (measure-has-numerical-value (recipe-flow-effort-quantity f))))))
    (check-pred "crates take up a standing space too"
                (find-flow (process-inputs rs "rp-bt-transit-haul") "spec-bt-ubahn" #:action 'use))
    (check-pred "the pass is USED for the journey, never consumed by it"
                (and (find-flow (process-inputs rs "rp-mode-ubahn") "spec-bt-transit-pass" #:action 'use)
                     (not (find-flow (process-inputs rs "rp-mode-ubahn")
                                     "spec-bt-transit-pass" #:action 'consume))))
    (check-pred "a transit ride still costs no driver labour and no fuel"
                (not (any (lambda (f) (or (eq? 'consume (recipe-flow-action f))
                                          (and (eq? 'work (recipe-flow-action f))
                                               (not (recipe-flow-resolve-from-flow f)))))
                          (process-inputs rs "rp-mode-ubahn"))))
    (check-pred "crates ride the network too: 25 kg in, 25 kg out, one courier hour"
                (and (= 25.0 (measure-has-numerical-value
                              (recipe-flow-resource-quantity
                               (find-flow (process-inputs rs "rp-bt-transit-haul") "spec-bt-freight" #:action 'pickup))))
                     (= 25.0 (measure-has-numerical-value
                              (recipe-flow-resource-quantity
                               (find-flow (process-outputs rs "rp-bt-transit-haul") "spec-bt-freight" #:action 'dropoff))))
                     (find-flow (process-inputs rs "rp-bt-transit-haul") "spec-bt-courier" #:action 'work)))
    (check-pred "the Lastenrad haul occupies the commune's own bike and burns a little charge"
                (and (find-flow (process-inputs rs "rp-bt-cargo-bike") "spec-bt-cargo-bike" #:action 'use)
                     (find-flow (process-inputs rs "rp-bt-cargo-bike") "spec-bt-charge" #:action 'consume)))))

(display "\n── Tenure: what the plan depends on but does not hold rights over ──\n")
(define commune "berlin-commune")
(define op-pass     (bt-transit-pass-resource "res-p1" commune))
(define member-pass (bt-transit-pass-resource "res-p2" commune #:rights-holder "agent-jo"))
(define own-bike    (bt-cargo-bike-resource   "res-b1" commune))
(define loan-bike   (bt-cargo-bike-resource   "res-b2" commune #:loaned? #t))

(check-pred "an operator subscription is custody without rights — they can suspend it"
            (resource-rented? op-pass commune))
(check-pred "a pass commoned by a member is likewise split — they can recall it"
            (and (resource-rented? member-pass commune)
                 (equal? "agent-jo" (economic-resource-primary-accountable member-pass))))
(check-pred "a bike the commune bought is sovereign — nobody can pull it"
            (and (resource-sovereign? own-bike commune)
                 (not (resource-rented? own-bike commune))))
(check-pred "a free-loan Lastenrad joins the rented family"
            (resource-rented? loan-bike commune))
(define ubahn (bt-network-resource "spec-bt-ubahn" commune))
(check-pred "the network is held, not owned: the operator can withdraw the service"
            (and (resource-rented? ubahn commune)
                 (equal? "org:vbb" (economic-resource-primary-accountable ubahn))
                 (= 200.0 (measure-has-numerical-value
                           (economic-resource-onhand-quantity ubahn)))))
(check-pred "…so the U-Bahn joins the rented sector beside the pass"
            (equal? '("Svc|spec-bt-ubahn") (rented-goods (list ubahn) commune)))
(check-pred "capacity is read off the HOLDINGS, so the number is stated once"
            (let* ((held (berlin-network-resources commune #:at "a" #:seat-hours 200.0))
                   (caps (berlin-transit-svc-caps held '(0 1) #:hours-of resource-window-hours)))
              (and (= 8 (length caps))                     ; 4 networks × 2 periods
                   (= 200.0 (assoc-ref caps "Svc|spec-bt-ubahn#a@0"))
                   (= 200.0 (assoc-ref caps "Svc|spec-bt-tram#a@1")))))
(check-pred "…and it covers the bikes and the pass, not only the networks"
            (let* ((held (berlin-transit-resources commune #:pass-holders (list #f)
                                                   #:owned-bikes 1 #:loaned-bikes 0 #:at "a"))
                   (caps (berlin-transit-svc-caps held '(0) #:hours-of resource-window-hours)))
              ;; a COUNT renders itself for every hour it is there, so one bike over a
              ;; day is twenty-four bike-hours — the same number ingest-stock! derives
              ;; from the same holding, which is the point of reading it off the holding
              (and (= 24.0 (assoc-ref caps "Svc|spec-bt-cargo-bike#a@0"))
                   (= 24.0 (assoc-ref caps "Svc|spec-bt-transit-pass#a@0")))))
(check-pred "the rented sector lifts the pass and the loaned bike, and only those"
            (equal? '("Svc|spec-bt-transit-pass" "Svc|spec-bt-cargo-bike")
                    (rented-goods (list op-pass member-pass own-bike loan-bike) commune)))
(check-pred "a commune holding only its own bike depends on nothing revocable"
            (null? (rented-goods (list own-bike) commune)))
(check-pred "the holdings builder assembles passes and both kinds of bike"
            (let ((rs (berlin-transit-resources commune
                                                #:pass-holders (list #f "agent-jo")
                                                #:loaned-bikes 1 #:owned-bikes 2)))
              (and (= 5 (length rs))
                   (= 3 (length (filter (lambda (r) (resource-rented? r commune)) rs))))))

(display "\n── The commune's transport arm (seed-berlin-commune! #:transit? #t) ──\n")
(define-values (cvat croot)
  (let ((v (spawn-vat #:name "berlin-commune-transit")))
    (values v (with-vat v (spawn-scope-root "Berlin")))))
(define seeded (with-vat cvat (seed-berlin-commune! croot #:transit? #t)))
(define c-locs (with-vat cvat ($ ($ croot 'spatial-thing-store) 'all-locations)))
(define c-recipes (with-vat cvat (map recipe-id ($ ($ croot 'recipe-store) 'all-recipes))))
(define c-res (with-vat cvat ($ ($ croot 'observer) 'all-resources)))
(define c-commune "commune-berlin-commune-farm")

(check-pred "the seed still returns the farm place — the existing contract holds"
            (equal? "berlin-commune-farm" seeded))
(check-pred "there is now somewhere to go: the market hangs under the shed, not the farm"
            (let ((m (find (lambda (l) (equal? "berlin-markthalle" (spatial-thing-id l))) c-locs)))
              (and m (equal? "berlin" (spatial-thing-contained-in m)))))
(check-pred "the transport recipes — modes and hauls — sit in the commune's own store beside the crops"
            (every (lambda (r) (member r c-recipes))
                   '("recipe-rp-mode-ubahn" "recipe-rp-mode-walk" "recipe-bt-transit-haul" "recipe-bt-cargo-bike")))
(check-pred "the courier's hours are a real budget the hauls draw on"
            (find (lambda (r) (equal? "spec-bt-courier" (economic-resource-conforms-to r))) c-res))
(check-pred "the commune holds a pass and both kinds of bike, all at the farm"
            (= 3 (length (filter (lambda (r)
                                   (member (economic-resource-conforms-to r)
                                           '("spec-bt-transit-pass" "spec-bt-cargo-bike")))
                                 c-res))))
(check-pred "the commune holds all four networks as seat-hour resources"
            (= 4 (length (filter (lambda (r)
                                   (member (economic-resource-conforms-to r)
                                           '("spec-bt-ubahn" "spec-bt-sbahn"
                                             "spec-bt-tram" "spec-bt-bus")))
                                 c-res))))
(check-pred "and the plan can SEE what it holds under another's rights — networks included"
            (equal? '("Svc|spec-bt-bus" "Svc|spec-bt-cargo-bike" "Svc|spec-bt-sbahn"
                      "Svc|spec-bt-tram" "Svc|spec-bt-transit-pass" "Svc|spec-bt-ubahn")
                    (sort (rented-goods c-res c-commune) string<?)))
(check-pred "the farm alone is still the farm alone — transit is opt-in"
            (let* ((v (spawn-vat #:name "berlin-plain"))
                   (r (with-vat v (spawn-scope-root "Berlin"))))
              (with-vat v (seed-berlin-commune! r))
              (with-vat v (null? (filter (lambda (x) (string-prefix? "res-bt-" (economic-resource-id x)))
                                         ($ ($ r 'observer) 'all-resources))))))

(display "\n── The library's one set of flow builders ──\n")
;; recipes/transport.scm is part of the umbrella now, and its pickup-flow /
;; dropoff-flow / use-flow / consume-flow* / work-flow* are what every
;; pickup→dropoff recipe in the library is built from — this file included.
(check-pred "the canonical car ride is a mode like the shed's own: anyone may be driven"
            (and (not (mrec-skill car-ride))
                 (equal? "spec-car" (entry-vehicle car-ride))
                 (equal? "spec-driving" (entry-driver car-ride))
                 (equal? "auto" (mrec-manner car-ride))
                 (= 0.02 (mrec-pace car-ride))))
(check-pred "…and it seeds beside them, through the same seeder"
            ;; into a scope of its own: the solves below read croot, and a probe
            ;; that seeded extra recipes there would silently change their shape.
            (let* ((v (spawn-vat #:name "bt-car-probe"))
                   (r (with-vat v (spawn-scope-root "Berlin"))))
              (with-vat v
                (let ((rs ($ r 'recipe-store)))
                  (seed-transport-specs rs)
                  (seed-transport-recipe rs)
                  (and ($ rs 'get-recipe "recipe-transport")
                       (equal? "spec-rider"
                               (recipe-primary-output ($ rs 'get-recipe "recipe-transport"))))))))
(check-pred "its builders are the ones this file's recipes used"
            (let ((f (pickup-flow "probe" "spec-x" 2.0 "kg" "p")))
              (and (eq? 'pickup (recipe-flow-action f))
                   (= 2.0 (measure-has-numerical-value (recipe-flow-resource-quantity f)))
                   (equal? "p" (recipe-flow-recipe-input-of f)))))
(check-pred "a dropoff is the primary flow, an input-of nothing"
            (let ((f (dropoff-flow "probe2" "spec-x" 2.0 "kg" "p")))
              (and (eq? 'dropoff (recipe-flow-action f))
                   (recipe-flow-is-primary f)
                   (equal? "p" (recipe-flow-recipe-output-of f)))))

(display "\n── The worker is a rider (spec §The worker is a rider) ──\n")
;; *workers* and *riders* are not two populations: a worker is PINNED where
;; ingest-located! records them, a rider is the same person with their location
;; handed to the plan. A shed asks for the mobile reading with (mobile-people . #t)
;; beside its modes; without it the roster stays where it stands.
(define (engine-after-solve manners)
  (with-vat cvat
    (plan-scope->alist croot #:manners manners
      #:demand (list (cons "food#berlin-commune-farm@0" 5000.0))))
  (list *workers* *riders*))   ; the world's tables, read where the solve left them (solve/world)
(define pinned (engine-after-solve berlin-transit-manners))
(define mobile (engine-after-solve (cons '(mobile-people . #t) berlin-transit-manners)))
(check-pred "modes alone leave the roster pinned — mobility is asked for, not implied"
            (and (pair? (first pinned)) (null? (second pinned))))
(check-pred "asked for, the PERSON becomes a rider based where she stood"
            (let ((rd (assoc "worker-berlin-commune-farm" (second mobile))))
              (and rd (equal? "berlin-commune-farm" (second rd)))))
(check-pred "…carrying the capabilities Berlin's modes gate on"
            (let ((rd (assoc "worker-berlin-commune-farm" (second mobile))))
              (every (lambda (c) (member c (third rd))) '("walk" "transit-access" "cycle"))))
(check-pred "…and her hours and skills came with her"
            (let ((rd (assoc "worker-berlin-commune-farm" (second mobile))))
              (and (pair? (list-ref rd 3))                                          ; hours by period (rider-hours)
                   (every (lambda (th) (> (cdr th) 0.0)) (list-ref rd 3))
                   (member "spec-bt-courier" (third rd)))))
(check-pred "nobody supplies their hours twice — a rider is MOVED out of the roster"
            (not (assoc "worker-berlin-commune-farm" (first mobile))))
(check-pred "an organisation stays put: a commune is not somewhere that travels"
            (and (assoc "commune-berlin-commune-farm" (first mobile))
                 (not (assoc "commune-berlin-commune-farm" (second mobile)))))

(display "\n── Rates are per unit moved, per km ──\n")
;; build-columns relocates ±1 of the good per column unit whatever the pickup flow
;; says, so a freight recipe's costs are per KG·km — the per-trip figure divided by
;; the payload. Priced per trip instead, a 20-hour courier budget buys 100 kg.
(define (rate pid spec action)
  (with-vat cvat
    (let* ((rs ($ croot 'recipe-store))
           (f  (find-flow (process-inputs rs pid) spec #:action action)))
      (and f (measure-has-numerical-value (recipe-flow-effort-quantity f))))))
(check-pred "the 25 kg crate haul costs a courier 0.060 h/km ÷ 25 kg"
            (< (abs (- (rate "rp-bt-transit-haul" "spec-bt-courier" 'work) (/ 0.060 25.0))) 1e-9))
(check-pred "…and one standing space, 0.050 seat-h/km ÷ 25 kg"
            (< (abs (- (rate "rp-bt-transit-haul" "spec-bt-ubahn" 'use) (/ 0.050 25.0))) 1e-9))
(check-pred "the 100 kg Lastenrad box divides by its own payload"
            (and (< (abs (- (rate "rp-bt-cargo-bike" "spec-bt-cargo-bike" 'use) (/ 0.075 100.0))) 1e-9)
                 (< (abs (- (rate "rp-bt-cargo-bike" "spec-bt-courier" 'work) (/ 0.075 100.0))) 1e-9)))
(check-pred "a rider needs no such division — one column unit is already one rider"
            (= 0.050 (rate "rp-mode-ubahn" "spec-bt-ubahn" 'use)))

(display "\n── End to end: the modes reach a live solve from the scope's recipes ──\n")
;; The modes are recipes in the commune's store, so the solve finds them there;
;; berlin-transit-manners is the shed's switches; the modes carry their own costing and pace.
;;
;; This scope sits in a bioregion, so it inherits Berlin's futures and the solve
;; takes the ROBUST branch. That branch forwards the whole world it was given
;; (solve/robust.scm's %world-keywords) — assert the engine's own state afterwards, not
;; merely that a plan came back, because a branch that quietly dropped these
;; keywords is exactly the failure this guards.
(define %engine (resolve-module '(playnet scope live)))
(define (engine sym) (module-ref %engine sym))
(define probe-arc "berlin-commune-farm|berlin-markthalle|auto")
(define plan
  (with-vat cvat
    (plan-scope->alist croot
      #:manners berlin-transit-manners
      #:arc-table (list (cons probe-arc 0.25))
      #:eco-caps (berlin-transit-svc-caps c-res '(0) #:hours-of resource-window-hours)
      #:demand (list (cons "food#berlin-commune-farm@0" 20000.0)))))
(check-pred "the commune plans with its transport arm seeded and its modes installed"
            (> (or (assq-ref plan 'met) 0) 0.0))
(check-pred "…and the shed's seven modes and the baseline car really are in the engine after the solve"
            (= 8 (length *mode-recipes*)))
(check-pred "…with every mode's Valhalla costing"
            (every (lambda (m) (member (mrec-manner m) '("pedestrian" "bicycle" "bus" "multimodal" "auto")))
                   *mode-recipes*))
(check-pred "…and the arc table survived the robust branch, so routing beats geometry"
            (equal? 0.25 (hash-ref *arc-hours* probe-arc #f)))
;; the band dial reaches the live solve the same way: a day declared as three
;; bands (08–11, 11–13, 13–16) is three periods, each its own hours — what lets
;; a mover make two hops in one day (discrete-records-test §7b)
(define banded
  (with-vat cvat
    (plan-scope->alist croot
      #:manners berlin-transit-manners
      #:period-spans '(("2026-08-17T08:00" . "2026-08-17T11:00")
                       ("2026-08-17T11:00" . "2026-08-17T13:00")
                       ("2026-08-17T13:00" . "2026-08-17T16:00"))
      #:demand (list (cons "food#berlin-commune-farm@0" 20000.0)))))
(check-pred "a declared partition of bands is the live solve's periods"
            (and (assq 'met banded) (equal? '(0 1 2) *periods*)))
(check-pred "…each band its own hours: the midday band is two"
            (and (= 3.0 ((engine 'period-hours) 0)) (= 2.0 ((engine 'period-hours) 1)) (= 3.0 ((engine 'period-hours) 2))))

;; …and the crates actually reach the market, in a quantity the seat pool governs.
;; ONE seeded commune serves every probe below: plan-scope reads the scope's stores
;; and returns an alist, so a solve leaves nothing behind for the next one.
(define hvat (spawn-vat #:name "bt-haul"))
(define hroot (with-vat hvat (spawn-scope-root "Berlin")))
(with-vat hvat
  (seed-berlin-commune! hroot #:transit? #t)
  ($ ($ hroot 'observer) 'seed-resource
     (make-economic-resource #:id "crates" #:name "crates" #:conforms-to "spec-bt-freight" #:classified-as '()
       #:accounting-quantity (make-measure 500.0 "kg") #:onhand-quantity (make-measure 500.0 "kg") #:current-location "berlin-commune-farm"
       #:primary-accountable "commune-berlin-commune-farm")))

(define %market-freight "spec-bt-freight#berlin-markthalle@0")
;; The commune's own holdings ARE the caps. FLEET scales the pass and the bikes —
;; one of each is what the seed hands out, and that is a real bound on how much
;; can be carried at all; multiply it to ask what the plan would do with a depot.
(define h-res (with-vat hvat ($ ($ hroot 'observer) 'all-resources)))
;; The bike pool scales on its own knob, because the Lastenrad is a SUBSTITUTE
;; for the rail haul rather than a complement to it: a shed with bikes in it
;; answers "what happens when the U-Bahn is full" with "we cycle", and a probe
;; that means to ask about seats has to put the bikes away first.
(define* (haul-caps #:key (seat-hours 200.0) (fleet 1.0) (bikes fleet))
  (append (map (lambda (kv)
                 (cons (car kv)
                       (* (cdr kv)
                          (if (string-contains (car kv) "cargo-bike") bikes fleet))))
               (held-svc-caps h-res '(0) #:hours-of resource-window-hours
                              #:specs '("spec-bt-transit-pass" "spec-bt-cargo-bike")))
          (svc-eco-caps (map (lambda (spec) (list spec "berlin-commune-farm" seat-hours))
                             '("spec-bt-ubahn" "spec-bt-sbahn" "spec-bt-tram" "spec-bt-bus"))
                        '(0))))
(define* (haul #:key (seat-hours 200.0) (fleet 50.0) (bikes fleet) (floor #f) (ask 400.0))
  "Plan the crate haul; `met` when a plan exists, #f when none does — the solve
   threw, or came back with its own verdict `feasible` #f (the engine puts that
   beside `met` because `met` alone cannot say it). Under a FLOOR, met reports
   delivery above it — total = floor + met×ask."
  (catch #t
    (lambda ()
      (feasible-met (with-vat hvat
                  (plan-scope->alist hroot
                    #:manners berlin-transit-manners
                    #:eco-caps (haul-caps #:seat-hours seat-hours #:fleet fleet #:bikes bikes)
                    #:repro-floors (if floor (list (cons %market-freight floor)) '())
                    #:demand (list (cons %market-freight ask))))))
    (lambda (k . a) #f)))
(define (feasible-met r) (and (eq? #t (assq-ref r 'feasible)) (assq-ref r 'met)))

;; Bikes in the shed: what the rail haul carries, and what starving it costs.
(define met-ample  (haul #:bikes 0.0))
(define met-scarce (haul #:bikes 0.0 #:seat-hours 0.5))
(define met-none   (haul #:bikes 0.0 #:seat-hours 0.0))
(format #t "  crates by rail: 200 seat-hours → met ~,3f · 0.5 → ~,3f · 0 → ~,3f~%"
        met-ample met-scarce met-none)
(check-pred "the commune hauls a real share of its crates to the market"
            (> met-ample 0.3))
(check-pred "starving the seat pool starves the delivery"
            (< met-scarce (* 0.5 met-ample)))
(check-pred "no seats ⇒ no crates arrive"
            (< met-none 0.01))

;; …and the substitution itself, which is the reason the probes above had to put
;; the bikes away. A shed holding Lastenräder does NOT lose its crates when the
;; network closes: the courier cycles them, at their own pace and their own cost.
;; This is the plan being right rather than the seats being inert — take the bike
;; away, as directly above, and the seats bind exactly.
(define met-cycled (haul #:seat-hours 0.0))
(format #t "  the same closure with the Lastenräder back → met ~,3f~%" met-cycled)
(check-pred "with no seats at all the bikes still carry the crates"
            (> met-cycled 0.9))
(check-pred "…so the network is a means the commune can do without, not one it needs"
            (> met-cycled met-none))

;; …and the vehicles bound it too, which is what capping every HELD durable buys:
;; before the caps were read off the holdings those pools were drawn free. The
;; commune's one pass is held the whole day the plan stands on — 24 pass-hours —
;; and the day's 400 kg draws under three of them, so one pass carries the haul
;; whole. It binds exactly where there is less of it than the haul needs: held
;; for an hour or so of the day (0.05 of it), it carries a share; held not at
;; all, nothing rides.
(define met-one-pass  (haul #:fleet 1.0  #:bikes 0.0))
(define met-hour-pass (haul #:fleet 0.05 #:bikes 0.0))
(define met-no-pass   (haul #:fleet 0.0  #:bikes 0.0))
(format #t "  one pass → met ~,3f · the pass for ~~an hour → ~,3f · no pass → ~,3f (a depot: ~,3f)~%"
        met-one-pass met-hour-pass met-no-pass met-ample)
(check-pred "the commune's single pass carries the day's crates"
            (> met-one-pass 0.9))
(check-pred "the pass binds as well — held for an hour of the day it carries less"
            (< met-hour-pass (* 0.9 met-one-pass)))
(check-pred "…and with no pass nothing rides the network"
            (< met-no-pass 0.01))

;; What bounds delivery is the STOCK, not the seats or the courier's day. #:demand
;; is a want — weighed against the marginal cost of labour and of drawing down the
;; crate pile, so the solve stops partway. #:repro-floors is a NEED, and under one
;; the same commune moves its entire 500 kg.
;;
;; A floor the stock cannot cover comes back with the verdict `feasible` #f — the
;; plan says no plan holds it, rather than throwing or handing over a number
;; shaped like one. `haul` reads that verdict, so an unmeetable floor is #f here.
(define (delivered-under floor)
  (and=> (haul #:floor floor) (lambda (m) (+ floor (* m 400.0)))))
(define all-of-it (delivered-under 500.0))
(define too-much  (delivered-under 501.0))
(format #t "  under a hard floor: 500 kg → ~a delivered · 501 kg → ~a~%"
        (if all-of-it (format #f "~,1f" all-of-it) "infeasible")
        (if too-much "feasible" "infeasible"))
(check-pred "asked as a NEED, the commune moves its whole 500 kg to the market"
            (and all-of-it (> all-of-it 499.0)))
(check-pred "…and one kilo more is infeasible — the stock is the real ceiling"
            (not too-much))

(display "\n── The seams hold: a SECOND shed from the generic side alone ──\n")
;; transit-shed.scm is the mechanism and Berlin is data over it (the
;; farm-commune-seed.scm split). The only honest test of that is to build another
;; shed from the generic pieces and nothing else — no berlin-* anything.
(define dv-modes
  (list (mode-recipe "vikram-bus" #:skill "transit-access" #:pace 0.090 #:manner "bus"
                     #:uses '(("spec-dv-bus" . 0.090)))
        (mode-recipe "walk" #:skill "walk" #:pace 0.200 #:manner "pedestrian")))
(define dv-manners (transit-manners))
(define dv-vat (spawn-vat #:name "doon-transit"))
(define dv-root (with-vat dv-vat (spawn-scope-root "Doon")))
(define dv-caps
  (with-vat dv-vat
    (let ((rs ($ dv-root 'recipe-store)))
      (seed-spec-rows! rs
        '(("spec-dv-rider"   "Rider (person in transit)" "each" "vf:person")
          ("spec-dv-freight" "Sacked Grain"              "kg"   "vf:goods")
          ("spec-dv-bus"     "City Bus Service (seat-hours)" "hours" "vf:vehicle" "vf:network")
          ("spec-dv-porter"  "Porter Labour"             "hours" "vf:skill")))
      (seed-relocation-recipe! rs
        #:process "rp-dv-haul" #:recipe "recipe-dv-haul" #:name "Bus haul: sacks by hand"
        #:pspec-name "Hand-Carried Bus Haul"
        #:good "spec-dv-freight" #:payload 40.0 #:unit "kg"
        #:duration (make-duration 0.9 %effort-unit) #:tags '("tag:transport")
        #:uses '(("spec-dv-bus" . 0.090)) #:work '("spec-dv-porter" . 0.070))
      (held-svc-caps (list (network-resource "spec-dv-bus" "commune-doon"
                                            #:operator "org:doon-transport"
                                            #:at "doon-farm" #:seat-hours 120.0))
                     '(0) #:hours-of resource-window-hours))))
(check-pred "another shed's modes carry their own costings, out of the generic constructor"
            (equal? '("bus" "pedestrian") (map mrec-manner dv-modes)))
(check-pred "…and its bag holds switches only: no pace, no costing map"
            (null? dv-manners))
(check-pred "its haul seeded, with the payload division done by the mechanism"
            (with-vat dv-vat
              (let* ((rs ($ dv-root 'recipe-store))
                     (w (find-flow (process-inputs rs "rp-dv-haul") "spec-dv-porter" #:action 'work))
                     (u (find-flow (process-inputs rs "rp-dv-haul") "spec-dv-bus" #:action 'use)))
                (and w u
                     (< (abs (- (measure-has-numerical-value (recipe-flow-effort-quantity w))
                                (/ 0.070 40.0))) 1e-9)
                     (< (abs (- (measure-has-numerical-value (recipe-flow-effort-quantity u))
                                (/ 0.090 40.0))) 1e-9)))))
(check-pred "its network is held under the operator's rights, like Berlin's"
            (let ((r (network-resource "spec-dv-bus" "commune-doon" #:operator "org:doon-transport")))
              (and (resource-rented? r "commune-doon")
                   (equal? "org:doon-transport" (economic-resource-primary-accountable r)))))
(check-pred "and its seat pool is capped off that holding"
            (= 120.0 (assoc-ref dv-caps "Svc|spec-dv-bus#doon-farm@0")))

(test-summary!)
