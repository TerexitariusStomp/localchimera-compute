;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-climb.scm — the arc's climb lengthens the road for what is spent over distance.
;;;
;;; A place states its altitude (SpatialThing alt); an arc a→b rises what b stands
;;; above a, and each manner states how many metres of climb cost what a kilometre
;;; of level road does (engine.scm *climb-per-km*, the car's and the walker's by
;;; Naismith). The DISTANCE-spent flows of a haul (fuel, wear, loss) then scale by
;;; the road plus the climb's equivalent; the TIME-spent flows and the descent do
;;; not change. Read off the tiled columns' coefficients, so the property holds
;;; whatever the solve then chooses.
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-climb.scm

(use-modules ((localchimera utils units) #:select (%count-unit %effort-unit)))
(use-modules (srfi srfi-1) (ice-9 format)
             (localchimera solve engine) (localchimera solve plan) (localchimera vf schemas)
             (localchimera knowledge dsl shorthand)
             ((localchimera knowledge recipes transport) #:select (pickup-flow dropoff-flow)))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(define (~= a b) (< (abs (- a b)) 1e-6))

;; two places a tenth of a degree of longitude apart at 52° north (near 6.8 km),
;; the second RISE metres above the first
(define (spatials rise)
  (list (make-spatial-thing #:id "low" #:name "Low" #:lat 52.0 #:long 13.0 #:alt 0.0)
        (make-spatial-thing #:id "high" #:name "High" #:lat 52.0 #:long 13.1 #:alt rise)))
(define procs (list (rp* "haul" "Haul the crate")))
(define flows
  (list (pickup-flow "h/in" "crate" 1.0 %count-unit "haul")
        (dropoff-flow "h/out" "crate" 1.0 %count-unit "haul")
        (consume* "h/fuel" "fuel" 0.1 "haul" "litre")     ; spent over DISTANCE: a tenth of a litre per crate-kilometre
        (wk* "h/drive" "driving" 0.02 "haul")))           ; spent over TIME: a driver's hours per crate-kilometre
(define (resources at)                  ; the crate, the fuel and the driver stand at AT
  (list (er "crate1" "crate" #f #:place at #:qty 1.0 #:unit %count-unit)
        (er "fuel1" "fuel" #f #:place at #:qty 100.0 #:unit "litre")
        (er "drv" "driving" "ada" #:place at #:qty 1.0 #:unit %effort-unit)))

;; the fuel coefficient on the haul column from FROM to TO, litres per crate hauled
(define (fuel-coefficient rise from to)
  (call-with-values
    (lambda () (plan-from-records (resources from)
                 (list (person* "ada" #:name "Ada" #:place from #:window (hours-of 24)))
                 (spatials rise) procs flows
                 #:demand (list (cons (string-append "crate#" to "@0") 1.0)) #:periods '(0) #:per-agent? #f #:backend 'native-c
                 #:allow-infeasible? #t))
    (lambda (i c m fill cols x idx nt rep)
      (let ((col (find (lambda (c) (equal? (car c) (string-append "p|haul|" from "@0|" to "@0"))) cols)))
        (and col (let ((fuel (find (lambda (iq) (string-prefix? "fuel" (car iq))) (cadr col))))
                   (and fuel (- (cdr fuel)))))))))

(define level   (fuel-coefficient 0.0 "low" "high"))
(define uphill  (fuel-coefficient 300.0 "low" "high"))
(define downhill (fuel-coefficient 300.0 "high" "low"))
(format #t "~%fuel per crate: level ~,4f  uphill ~,4f  downhill ~,4f litres~%" level uphill downhill)

(check "a haul on the level burns its rate times the road" (and level (> level 0.5) (< level 0.8)))   ; 0.1 L/km × ~6.8 km
(check "the climb lengthens the road: 300 m up costs the car's metres-per-kilometre figure in fuel, read off *climb-per-km*"
       (and uphill (~= (- uphill level) (* 0.1 (/ 300.0 (assoc-ref *climb-per-km* "auto"))))))
(check "the descent is free: downhill burns what the level does" (and downhill (~= downhill level)))
(check "arc-climb-km reads the manner's figure, and a manner the table does not name climbs at the car's"
       (and (~= (arc-climb-km "low@0" "high@0" "pedestrian") (/ 300.0 (assoc-ref *climb-per-km* "pedestrian")))
            (~= (arc-climb-km "low@0" "high@0" "hovercraft") (arc-climb-km "low@0" "high@0" "auto"))
            (= 0.0 (arc-climb-km "high@0" "low@0" "auto"))))

(format #t "~%=== Results: ~a passed, ~a failed ===~%" *pass* *fail*)
(exit (if (= *fail* 0) 0 1))
