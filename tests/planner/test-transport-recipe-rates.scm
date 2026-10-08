;;; test-transport-recipe-rates.scm — the car ride's flows are rates, per rider·km
;;;
;;; knowledge/recipes/transport.scm seeds one concrete trip. Its numbers are what
;;; ONE rider costs for ONE kilometre, because the arc tiling relocates ±1 of the
;;; good per column unit (the pickup quantity declares a load's shape, it does not
;;; scale the costs) and then scales every input by the arc — `use`/`work` by the
;;; network-time scale, `consume` by road km.
;;;
;;; This pins that reading against the whole-journey story the file tells: at the
;;; car's 0.02 h/km pace the recipe's 0.4 h duration is a ~20 km ride, and over 20
;;; km the rates come to exactly the 0.4 car-hours, 0.4 driver-hours and 1.2 litres
;;; the prose describes. Read as per-trip figures instead, the same column would
;;; charge a 20 km ride 8 hours of driving and 24 litres of petrol.
;;;
;;; Run:  guile --no-auto-compile -q -L module \
;;;         tests/planner/test-transport-recipe-rates.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner solve compile))
;; transport.scm is a module now — use-modules, not primitive-load. A
;; define-module inside a primitive-loaded file switches current-module for
;; the REST of this file and never switches back.
(use-modules (playnet planner knowledge recipes transport))

(define *pass* 0) (define *fail* 0)
(define (check label ok)
  (if ok (set! *pass* (+ *pass* 1)) (set! *fail* (+ *fail* 1)))
  (format #t "  [~a] ~a~%" (if ok "✓" "✗") label))
(define (~= a b tol) (and a b (< (abs (- a b)) tol)))

(declare-world! #:places '(("A" 0.0 0.0) ("B" 0.0 0.18))   ; ~20 km east
                #:templates '()
                #:riders (list (list "Dana" "A" '("doctor") 40.0))
                #:mode-recipes (list car-ride))
;; the ride's column stands where its inputs are supplied: a car, and a driver's hours
(hash-set! *cap* (lg "Svc|spec-car" (cell "A" 0)) 10.0)
(hash-set! *cap* (lab-good "spec-driving" (cell "A" 0)) 10.0)
(hash-set! *demand* (lg "care" (cell "B" 0)) 1.0)

(define d   (km (cell "A" 0) (cell "B" 0)))
(define cols (build-columns))
(define arc  (find (lambda (c) (equal? (col-key c) "p|ride.Dana.car|A@0|B@0")) cols))
(define (coeff good) (and arc (and=> (assoc (lg good (cell "A" 0)) (col-flows arc)) cdr)))
(define rider-out (and arc (and=> (assoc (lg "Pres|Dana" (cell "B" 0)) (col-flows arc)) cdr)))
(define rider-in  (coeff "Pres|Dana"))
(define car-svc   (coeff "Svc|spec-car"))
(define fuel      (coeff "spec-petrol"))
;; the driver's hours are a draw on the Lab| pool of their skill where the ride departs
(define driver    (and arc (and=> (assoc (lab-good "spec-driving" (cell "A" 0)) (col-flows arc)) cdr)))

(format #t "~%── one rider, ~,1f km ──~%" d)
(format #t "  rider   @A ~,3f → @B ~,3f   (relocated, ±1 per column unit)~%" rider-in rider-out)
(format #t "  car     ~,3f Svc-hours   (0.02 h/km × ~,1f km)~%" (- car-svc) d)
(format #t "  driver  ~,3f hours       (0.02 h/km × ~,1f km)~%" (- driver) d)
(format #t "  petrol  ~,3f litres      (0.06 L/km × ~,1f km)~%" (- fuel) d)

(check "the ride tiles over the A→B arc" (and arc #t))
(check "the rider is relocated ±1 — the pickup's 1.0 sets the shape, not the scale"
       (and (~= rider-in -1.0 1e-9) (~= rider-out 1.0 1e-9)))
(check "`use` compiles: the car's per-period SERVICE good is drawn, so a fleet is finite"
       (and car-svc (< car-svc 0.0)))
(check "car service = 0.02 h/km × distance"   (~= (- car-svc) (* 0.02 d) 1e-6))
(check "driver hours = 0.02 h/km × distance"  (~= (- driver)  (* 0.02 d) 1e-6))
(check "petrol = 0.06 L/km × distance"        (~= (- fuel)    (* 0.06 d) 1e-6))

(format #t "~%── and the whole-journey story the file tells holds at 20 km ──~%")
(check "a ~20 km ride costs the 0.4 car-hours the duration describes" (~= (- car-svc) 0.4 0.01))
(check "…0.4 driver-hours"                                            (~= (- driver)  0.4 0.01))
(check "…and 1.2 litres of petrol"                                    (~= (- fuel)    1.2 0.02))

(format #t "~%  ~a the car ride prices one rider per km, and a 20 km trip comes to the~%    0.4 h and 1.2 L its duration and prose describe.~%~%"
        (if (= *fail* 0) "✓" "✗"))
(when (> *fail* 0) (exit 1))
