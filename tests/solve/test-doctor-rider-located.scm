;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-doctor-rider-located.scm — worker-as-rider: travel MODES, accessibility, stay.
;;;
;;; A mobile worker (a RIDER) is present where the plan puts them. Their PRESENCE is a
;;; unit good, init=1 at base at the first period, carried forward by free STAY columns
;;; (so relocate-AND-stay falls out), relocated spatially by a RIDE. A rider's tuple
;;; carries ONE list of things this mover can do: real work-skills (e.g. "doctor") and
;;; ride-mode capabilities (e.g. "walk") sit side by side in it, read by the SAME bare-
;;; membership rule — holding "walk" is holding "walk", whether a recipe's labour gate or
;;; a ride mode is the one asking. A ride picks a travel MODE — each with its own vehicle
;;; (Svc, #f = your legs), driver (Lab, #f = self), transit speed, and a CAPABILITY it
;;; requires:
;;;   walk : needs "walk", no vehicle, self-driven, slow
;;;   ride : needs nothing, a car (Svc) + a driver (Lab), fast
;;; Labour is supplied where present (supply ≤ hours·presence). Solved with OSQP, which
;;; (unlike the native barrier) prunes idle supply to 0.
;;;
;;; Shows: (1) MODAL CHOICE — with no car, a walker walks; (2) ACCESSIBILITY — someone
;;; who doesn't hold "walk" is stranded without a car and needs a vehicle routed to
;;; them; (3) RELOCATE-AND-STAY — over many periods the rider travels ONCE and stays,
;;; rather than commuting every period.
;;;
;;; Run:  tools/test/run-suite.sh tests/solve/test-doctor-rider-located.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (localchimera solve engine) (localchimera solve world)
             (localchimera solve compile)
             (localchimera solve solver)
             (localchimera vf schemas)
             (localchimera knowledge dsl shorthand)
             ((localchimera knowledge recipes transport) #:select (mode-recipe)))


(define WALK (mode-recipe "walk" #:skill "walk" #:pace 0.15))                                       ; the mover walks: bears "walk", 0.15 h/km (slow)
(define RIDE (mode-recipe "ride" #:pace 0.02 #:uses '(("car" . 0.01)) #:work '("driving" . 0.05)))   ; anyone; a car + a driver; 0.02 h/km (fast)

;; rider = (id base (work-skills ∪ capabilities) hours).  Dana holds "walk"; Wendy doesn't.
(define (run rider periods car-cap demand-per car-at)     ; car-at = periods where a car is available
  (declare-world! #:places '(("A" 0.0 0.0) ("B" 0.0 0.045))   ; ~5 km — walkable
                  #:periods periods
                  #:templates
                    (compile-recipe (list (rp "treat" "Treat"))
                       (list (out "t1" "treated" 1.0 "treat") (wk* "t2" "doctor" 1.0 "treat")))
                  #:riders (list rider)
                  #:mode-recipes (list WALK RIDE)) (hash-set! *raws* "vaccine" #t)
  (for-each (lambda (t)                                      ; a car + driver available at A only on car-at periods
    (hash-set! *cap* (lg "Svc|car" (cell "A" t)) (if (member t car-at) car-cap 0.0))
    (hash-set! *cap* (lab-good "driving" (cell "A" t)) 40.0)  ; a driver labour pool (lab-good key: Lab|driving|cell)
    (hash-set! *demand* (lg "treated" (cell "B" t)) demand-per)) periods)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values (lambda () (solve-osqp forms labform ncol)) list)))
             (w (car rider))
             (S (lambda (pred) (hash-fold (lambda (k i a) (if (pred k) (+ a (vector-ref x i)) a)) 0.0 idx))))
        (list (S (lambda (k) (string-prefix? (string-append "p|ride." w ".walk|") k)))   ; walking trips (transport templates)
              (S (lambda (k) (string-prefix? (string-append "p|ride." w ".ride|") k)))   ; car-ride trips
              (S (lambda (k) (string-prefix? "p|treat|B@" k))))))))                       ; patients treated at B

(define (walk r)(first r)) (define (ridec r)(second r)) (define (treated r)(third r))

(define DANA  (list "Dana"  "A" '("doctor" "walk") 40.0))   ; holds "walk"
(define WENDY (list "Wendy" "A" '("doctor") 40.0))           ; doesn't hold "walk" — needs a vehicle

;; the SAME mover machinery moves CARGO: a mover with an EMPTY skills/capabilities list
;; is freight — the relocated good is the cargo itself, there is no labour-gate, and
;; (holding no "walk", like Wendy) it can only take a vehicle. General pickup/dropoff, one path.
(define (run-cargo car-cap)
  (declare-world! #:places '(("A" 0.0 0.0) ("B" 0.0 0.045)) #:templates '()   ; no production — vaccine is a stock at A
                  #:riders (list (list "vaccine" #f '() 0.0))   ; CARGO: empty list (no gate, no "walk") ⇒ must take a vehicle
                  #:mode-recipes (list WALK RIDE)) (hash-set! *raws* "vaccine" #t)
  (hash-set! *cap* (lg "vaccine" (cell "A" 0)) 100.0)           ; vaccine available at A
  (hash-set! *cap* (lg "Svc|car" (cell "A" 0)) car-cap)
  (hash-set! *cap* (lab-good "driving" (cell "A" 0)) 40.0)       ; a driver labour pool
  (hash-set! *demand* (lg "vaccine"  (cell "B" 0)) 20.0)         ; 20 doses needed at B
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values (lambda () (solve-osqp forms labform ncol)) list)))
             (S (lambda (pred) (hash-fold (lambda (k i a) (if (pred k) (+ a (vector-ref x i)) a)) 0.0 idx))))
        (list (S (lambda (k) (string-prefix? "p|ride.vaccine.walk|" k)))    ; walked (impossible: cargo can't walk)
              (S (lambda (k) (string-prefix? "p|ride.vaccine.ride|" k))))))))   ; hauled by vehicle
(define cargo-car   (run-cargo 1.0))
(define cargo-nocar (run-cargo 0.0))

(define dana-nocar (run DANA  '(0) 0.0 20.0 '(0)))         ; walker, no car
(define dana-car   (run DANA  '(0) 1.0 20.0 '(0)))         ; walker, a car available
(define wendy-nocar(run WENDY '(0) 0.0 20.0 '(0)))         ; non-walker, no car
(define wendy-car  (run WENDY '(0) 1.0 20.0 '(0)))         ; non-walker, a car available
(define wendy-stay (run WENDY '(0 1 2) 1.0 10.0 '(0)))     ; non-walker, car ONLY at period 0 ⇒ must ride once and STAY

(format #t "~%── travel modes (walk needs the \"walk\" capability; ride needs a car + driver) ──~%")
(format #t "  ~16a  walk-trips  ride-trips  treated~%" "scenario")
(format #t "  ~16a  ~10,2f  ~10,2f  ~7,1f~%" "Dana,  no car"  (walk dana-nocar) (ridec dana-nocar) (treated dana-nocar))
(format #t "  ~16a  ~10,2f  ~10,2f  ~7,1f~%" "Dana,  a car"   (walk dana-car)   (ridec dana-car)   (treated dana-car))
(format #t "  ~16a  ~10,2f  ~10,2f  ~7,1f~%" "Wendy, no car"  (walk wendy-nocar)(ridec wendy-nocar)(treated wendy-nocar))
(format #t "  ~16a  ~10,2f  ~10,2f  ~7,1f~%" "Wendy, a car"   (walk wendy-car)  (ridec wendy-car)  (treated wendy-car))
(format #t "  ~16a  ~10,2f  ~10,2f  ~7,1f   (3 periods, car only @0)~%" "Wendy, stay"    (walk wendy-stay) (ridec wendy-stay) (treated wendy-stay))
(format #t "  ~16a  ~10,2f  ~10,2f          (cargo: vaccine A→B, no person)~%" "vaccine, car"   (walk cargo-car)  (ridec cargo-car))
(format #t "  ~16a  ~10,2f  ~10,2f~%" "vaccine, no car" (walk cargo-nocar) (ridec cargo-nocar))

(let* ((c1 (and (> (walk dana-nocar) 0.4) (> (treated dana-nocar) 18.0)))   ; Dana walks when there's no car
       (c2 (> (ridec dana-car) 0.4))                                        ; with a car she rides (faster)
       (c3 (< (treated wendy-nocar) 1.0))                                   ; Wendy can't walk + no car ⇒ stranded
       (c4 (and (> (ridec wendy-car) 0.4) (> (treated wendy-car) 18.0)))    ; a car routed to her ⇒ she's treated
       (c5 (> (treated wendy-stay) 28.0))                                  ; car only @0, yet treats all 30 ⇒ presence CARRIED across periods by stay
       (c6 (and (> (ridec cargo-car) 18.0) (< (walk cargo-car) 0.01)))     ; CARGO: a vehicle hauls the vaccine; it never "walks"
       (c7 (< (ridec cargo-nocar) 0.01))                                   ; no car ⇒ cargo can't move (no walk capability) — same logic as Wendy
       (ok (and c1 c2 c3 c4 c5 c6 c7)))
  (format #t "~%  [~a] MODE: no car ⇒ Dana walks to B and treats          (walk ~,2f, treated ~,1f)~%" (if c1 "✓" "✗") (walk dana-nocar) (treated dana-nocar))
  (format #t "  [~a] MODE: a car ⇒ she rides instead (faster)            (ride ~,2f)~%" (if c2 "✓" "✗") (ridec dana-car))
  (format #t "  [~a] ACCESS: Wendy cannot walk + no car ⇒ stranded       (treated ~,1f)~%" (if c3 "✓" "✗") (treated wendy-nocar))
  (format #t "  [~a] ACCESS: a vehicle routed to her ⇒ she is treated    (ride ~,2f, treated ~,1f)~%" (if c4 "✓" "✗") (ridec wendy-car) (treated wendy-car))
  (format #t "  [~a] STAY: car only @0 ⇒ one trip, then presence carries (trips ~,2f, treated ~,1f / 30)~%" (if c5 "✓" "✗") (+ (walk wendy-stay) (ridec wendy-stay)) (treated wendy-stay))
  (format #t "  [~a] CARGO: a vehicle hauls the vaccine (never walks)     (vehicle ~,1f, walk ~,2f)~%" (if c6 "✓" "✗") (ridec cargo-car) (walk cargo-car))
  (format #t "  [~a] CARGO: no car ⇒ it can't move (no walk capability)   (vehicle ~,2f)~%" (if c7 "✓" "✗") (ridec cargo-nocar))
  (format #t "~%  ~a one mover machinery: persons (presence + labour-gate + self-propel) AND cargo (general pickup/dropoff) — modes, capabilities, stay-as-storage~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
