;;; test-reading-convert.scm — a reading is a count of a stock: the conversion.
;;;
;;; observation/convert.scm is the one place an intensive reading becomes an
;;; extensive count. This suite pins it to the physics of
;;; docs/observation/readings-are-counts.md §1.5, fixed seed:
;;;   • round trip: convert then invert recovers the reading (fact 1), for
;;;     temperature against any ambient and for moisture on both bases;
;;;   • the count is signed excess: a cold store reads below zero (fact 2);
;;;   • extensive: doubling the mass doubles the count, the reading unchanged;
;;;   • held and left (fact 6): hold-cost equals E·h/τ exactly; the carry
;;;     fraction is 1 at infinite τ, → 0 as τ → 0, and its k-th power is k
;;;     periods; no conductance means no cost and full carry (absence = no loss);
;;;   • latent heat (fact 4): drying a kilogram costs 0.628 kWh; fusion 0.093;
;;;   • refusals are pairs, never numbers: unknown unit, missing mass, missing
;;;     specific heat or ambient, and a substance read in the wrong unit.
;;;
;;; Run:  guile -q -L module tests/planner/test-reading-convert.scm

(use-modules (playnet test harness) (playnet observation convert) (srfi srfi-1))

(define (approx= a b . tol) (< (abs (- a b)) (if (pair? tol) (car tol) 1e-9)))
(define rng (seed->random-state 11))
(define (rand lo hi) (+ lo (* (- hi lo) (random 1.0 rng))))

(display "\n── round trip ──\n")
(check "temperature: convert then invert recovers the reading, 60 random forms"
       (every (lambda (_)
                (let* ((m (rand 0.5 5000)) (c (rand 0.8 4.2)) (ta (rand -20 35)) (t (rand -30 250))
                       (r (reading->count t "degC" #:mass m #:specific-heat c #:ambient ta)))
                  (and (eq? (car r) 'heat) (equal? (caddr r) "kWh")
                       (approx= (count->reading 'heat (cadr r) "degC" #:mass m #:specific-heat c #:ambient ta) t 1e-6))))
              (iota 60)))
(check "moisture, wet basis: round trip"
       (every (lambda (_)
                (let* ((m (rand 1 20000)) (p (rand 0 90))
                       (r (reading->count p "%moisture" #:mass m)))
                  (and (eq? (car r) 'water) (approx= (count->reading 'water (cadr r) "%moisture" #:mass m) p 1e-6))))
              (iota 60)))
(check "moisture, dry basis: round trip, and w = m·r/(1+r)"
       (every (lambda (_)
                (let* ((m (rand 1 20000)) (p (rand 0 150)) (r (/ p 100.0))
                       (c (reading->count p "%moisture-dry" #:mass m)))
                  (and (approx= (cadr c) (* m (/ r (+ 1 r))) 1e-6)
                       (approx= (count->reading 'water (cadr c) "%moisture-dry" #:mass m) p 1e-6))))
              (iota 60)))

(display "\n── signed, extensive ──\n")
(check "a cold store at 4 in 20-degree weather is a negative excess"
       (< (cadr (reading->count 4 "degC" #:mass 100 #:specific-heat 1.0 #:ambient 20)) 0))
(check "the same store on a −5 night is a positive excess (it needs heating)"
       (> (cadr (reading->count 4 "degC" #:mass 100 #:specific-heat 1.0 #:ambient -5)) 0))
(check "a form at ambient holds no excess"
       (= 0.0 (cadr (reading->count 12 "degC" #:mass 50 #:specific-heat 2.5 #:ambient 12))))
(check "doubling the mass doubles the count and leaves the reading"
       (let ((a (reading->count 26 "degC" #:mass 10 #:specific-heat 2.5 #:ambient 20))
             (b (reading->count 26 "degC" #:mass 20 #:specific-heat 2.5 #:ambient 20)))
         (and (approx= (cadr b) (* 2 (cadr a)))
              (approx= (count->reading 'heat (cadr b) "degC" #:mass 20 #:specific-heat 2.5 #:ambient 20) 26))))
(check "six degrees of excess in a dough of c = 2.5 is 0.0042 kWh per kg (the doc's floor)"
       (approx= (cadr (reading->count 26 "degC" #:mass 1 #:specific-heat 2.5 #:ambient 20)) (/ 15.0 3600) 1e-9))

(display "\n── held and left ──\n")
(check "hold-cost is E·h/τ exactly, 60 random enclosures"
       (every (lambda (_)
                (let* ((m (rand 1 5000)) (c (rand 0.8 4.2)) (ua (rand 0.001 5)) (dt (rand -30 40)) (h (rand 0.1 48))
                       (e (/ (* m c dt) 3600.0)) (tau (time-constant m c ua)))
                  (approx= (hold-cost ua dt h) (* (abs e) (/ h tau)) 1e-6)))
              (iota 60)))
(check "k periods left carry the k-th power of one period's fraction"
       (every (lambda (_)
                (let ((tau (rand 0.5 500)) (p (rand 1 48)) (k (+ 1 (random 6 rng))))
                  (approx= (expt (carry-fraction tau p) k) (carry-fraction tau (* k p)) 1e-9)))
              (iota 60)))
(check "a full silo (τ ≫ p) carries nearly all; a room (τ ≪ p) carries nothing"
       (and (> (carry-fraction 5000 24) 0.995) (< (carry-fraction 0.5 24) 1e-9)))
(check "no conductance: τ infinite, no cost, full carry (absence means no loss)"
       (and (not (finite? (time-constant 100 1.0 #f)))
            (= 0.0 (hold-cost #f 10 24))
            (= 1.0 (carry-fraction (time-constant 100 1.0 0) 24))))

(display "\n── latent heat ──\n")
(check "evaporating a kilogram costs 0.678 kWh at 25 °C (derived from the enthalpy table), melting 0.093"
       (and (approx= (latent-heat 'evaporation) 0.678 1e-3) (approx= (latent-heat 'fusion) 0.0928 1e-3)))
(check "the drying floor is linear in the water removed"
       (approx= (drying-energy-floor 12) (* 12 (latent-heat 'evaporation))))

(display "\n── refusals are pairs, never numbers ──\n")
(check "unknown unit" (refused? (reading->count 5 "furlongs" #:mass 1)))
(check "no mass" (refused? (reading->count 5 "degC" #:specific-heat 1 #:ambient 0)))
(check "no specific heat" (refused? (reading->count 5 "degC" #:mass 1 #:ambient 0)))
(check "no ambient" (refused? (reading->count 5 "degC" #:mass 1 #:specific-heat 1)))
(check "a substance read in the wrong unit" (refused? (count->reading 'water 3 "degC" #:mass 1 #:specific-heat 1 #:ambient 0)))
(check "an unknown phase change" (refused? (latent-heat 'sublimation)))

(test-summary!)
