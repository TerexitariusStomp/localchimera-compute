;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-doctor-ride.scm — the worker-as-rider, composed from the aligned pieces.
;;;
;;; Dr. Dana is at A; doctoring is demanded at B (far). She is a WORKER, so her
;;; labour is available only where her PRESENCE is. To get her to B the plan runs a
;;; RIDE that consumes a CAR (a finite economic resource — its service Svc|car) and a
;;; DRIVER (another worker — Bob's Lab|driving), and costs Dana her own transit time.
;;; Once at B she doctors. The whole thing is goods, flows and pulls:
;;;   ride ⇒ presence@B ;  doctor@B ≤ hours·presence@B ;  ride consumes Svc|car + Lab|driving + Dana's transit
;;;
;;; With a car available the plan picks her up and she meets demand; with no car
;;; (Svc|car = 0) she cannot reach B and the demand goes unmet — the vehicle and the
;;; driver are real, scarce, and necessary, exactly as you'd expect.
;;;
;;; (Forms-level proof on the real solver — the substrate for wiring Pres|worker into
;;;  build-located; it reuses Svc (car) and Lab (driver) verbatim.)
;;;
;;; Run:  tools/test/run-suite.sh tests/solve/test-doctor-ride.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine)
             (playnet solve solver))

(define H    40.0)   ; Dana's hours
(define HBOB 40.0)   ; Bob the driver's hours
(define TRAN 5.0)    ; Dana's transit time for a full ride (off her budget)
(define DRV  5.0)    ; Bob's driving hours for a full ride
(define CARS 1.0)    ; one car needed per full ride
(define D    30.0)   ; doctoring demanded at B
(define W    1000.0)

;; activities: ride ∈ [0,1] (fraction of Dana relocated A→B), doc (her doctoring hours @B)
(define RIDE 0) (define DOC 1) (define NA 2)

(define (build car-cap)
  (list
   (mk-bar 0.0 (list (cons RIDE 1.0)))                                   ; ride ≥ 0
   (mk-bar 0.0 (list (cons DOC  1.0)))                                   ; doc  ≥ 0
   (mk-bar 1.0 (list (cons RIDE -1.0)))                                  ; ride ≤ 1 (one Dana)
   (mk-bar car-cap (list (cons RIDE (- CARS))))                          ; Svc|car: ride ≤ car capacity (the car is a finite resource)
   (mk-bar HBOB (list (cons RIDE (- DRV))))                              ; Lab|driving: Bob drives DRV·ride ≤ his hours
   (mk-bar 0.0 (list (cons DOC -1.0) (cons RIDE H)))                     ; PRESENCE gate: doc ≤ hours·presence@B (= H·ride)
   (mk-bar H (list (cons DOC -1.0) (cons RIDE (- TRAN))))               ; Dana's budget: doctoring + her transit ≤ hours
   (mk-des (mk-bar 0.0 (list (cons DOC 1.0))) D W)))                     ; demand: doctoring@B → D

(define labform (list (cons DOC 1.0) (cons RIDE (+ TRAN DRV))))          ; free-time: Dana's work + (her transit + Bob's driving = faux frais)

(define (run car-cap)
  (let* ((res (solve* (build car-cap) labform (make-vector NA 0.0))) (x (car res)))
    (list (vector-ref x RIDE) (vector-ref x DOC))))

(define with-car (run 1.0))    ; a car is available
(define no-car   (run 0.0))    ; no car
(define (ride r)(first r)) (define (doc r)(second r))

(format #t "~%── Dr. Dana at A, doctoring demanded at B (~a h); pick her up by car + driver ──~%" D)
(format #t "  ~12a  ride  doctor@B  car-used  driver-hrs~%" "scenario")
(format #t "  ~12a  ~4,2f  ~7,1f  ~8,2f  ~9,1f~%" "car here"  (ride with-car) (doc with-car) (* CARS (ride with-car)) (* DRV (ride with-car)))
(format #t "  ~12a  ~4,2f  ~7,1f  ~8,2f  ~9,1f~%" "no car"    (ride no-car)   (doc no-car)   (* CARS (ride no-car))   (* DRV (ride no-car)))

;; THRESHOLD NOTE. `0.8` was calibrated when the central-path floor sat at 0.02,
;; which inflated every non-binding activity (see tests/solve/test-centering-floor.scm
;; — the residue ran plans at ~2× the needed level). With the floor at 0.005 the
;; ride settles at its true optimum, 0.77. The CLAIM here is qualitative — the plan
;; really does run the trip, and does not when the car is absent — so it is stated
;; against the control rather than against a magic constant.
(let* ((c1 (and (> (ride with-car) 0.5)            ; the plan picks Dana up …
                (> (ride with-car) (+ (ride no-car) 0.5))))  ; … and only because the car exists
       (c2 (> (doc with-car) (- D 1.0)))           ; she reaches B and meets demand
       (c3 (< (ride no-car) 0.05))                 ; no car ⇒ no ride
       (c4 (< (doc no-car) 1.0))                   ; ⇒ she cannot doctor at B (demand unmet)
       (ok (and c1 c2 c3 c4)))
  (format #t "~%  [~a] with a car: the plan rides Dana to B            (ride = ~,2f)~%" (if c1 "✓" "✗") (ride with-car))
  (format #t "  [~a] …and she meets the doctoring demand              (doctor@B = ~,1f)~%" (if c2 "✓" "✗") (doc with-car))
  (format #t "  [~a] no car ⇒ no ride (the vehicle is necessary)      (ride = ~,2f)~%" (if c3 "✓" "✗") (ride no-car))
  (format #t "  [~a] …so demand at B goes unmet                       (doctor@B = ~,1f)~%" (if c4 "✓" "✗") (doc no-car))
  (format #t "~%  ~a worker-as-rider: presence gates her labour; the RIDE consumes a car (Svc) + a driver (Lab) + her transit~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
