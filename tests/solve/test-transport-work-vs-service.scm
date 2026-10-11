;;; test-transport-work-vs-service.scm — two economically DIFFERENT kinds of transport.
;;;
;;; (1) PLANNED WORK transport — getting a worker to where their labour is NEEDED. This is
;;;     the MOVER machinery: the rider's transit time is charged to THEIR labour budget (the
;;;     faux frais of spatial separation), and a driver's driving is productive work. The
;;;     "doctor drives a common car to the hospital" case is a mode with a vehicle but NO
;;;     separate driver — self-propelled with a vehicle; her own driving time is the cost.
;;;     Both the driver and (when self-driving) the rider are work-intents in the plan.
;;;
;;; (2) MEANS-OF-CONSUMPTION transport — ride-hailing. A driver WORKS to PRODUCE a "ride"
;;;     service good; people DEMAND it and consume it in their FREE TIME, paying credits
;;;     (= its crystallized SNLT). This is an ordinary deliver-service recipe + a demand —
;;;     NOT the mover machinery. The consumer's labour budget is never touched; only the
;;;     driver's labour (and the vehicle) are planned. Society plans that ENOUGH rides exist,
;;;     not that a specific person rides at a specific time.
;;;
;;; Run:  tools/test/run-suite.sh tests/solve/test-transport-work-vs-service.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve report) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand)
             ((playnet knowledge recipes transport) #:select (mode-recipe)))
(define (svc id spec rq proc)(make-recipe-flow #:id id #:action 'deliver-service
                                               #:resource-conforms-to spec
                                               #:resource-quantity (make-measure rq %count-unit)
                                               #:recipe-output-of proc))
(define (S x idx pred)(hash-fold (lambda (k i a)(if (pred k)(+ a (vector-ref x i)) a)) 0.0 idx))

;; ── (1) PLANNED: the doctor drives a common car to the hospital (vehicle, no driver) ──
(define (planned)
  (declare-world! #:places '(("A" 0.0 0.0) ("B" 0.0 0.045))
                  #:templates (compile-recipe (list (rp "treat" "Treat")) (list (out "t1" "treated" 1.0 "treat") (wk* "t2" "doctor" 1.0 "treat")))
                  #:riders (list (list "Dana" "A" '("doctor" "drive") 40.0))   ; Dana holds "drive"
                  #:mode-recipes (list (mode-recipe "self-drive" #:skill "drive" #:pace 0.05 #:uses '(("car" . 0.01)))))   ; vehicle=car, no driver ⇒ she drives herself
  (hash-set! *cap* (lg "Svc|car" (cell "A" 0)) 1.0)
  (hash-set! *demand* (lg "treated" (cell "B" 0)) 20.0)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let ((x (car (call-with-values (lambda () (solve-osqp forms labform ncol)) list))))
        (list (S x idx (lambda (k) (string-prefix? "p|ride.Dana.self-drive|" k)))   ; she self-drives
              (S x idx (lambda (k) (string-prefix? "p|treat|B@" k)))                ; patients treated
              (S x idx (lambda (k) (string-prefix? "Lab|driving" k))))))))          ; a SEPARATE driver's labour (should be none)

;; ── (1b) AUTOMATED: no driver AND no capability — serves someone who can't walk/drive ──
(define (automated)
  (declare-world! #:places '(("A" 0.0 0.0) ("B" 0.0 0.045))
                  #:templates (compile-recipe (list (rp "treat" "Treat")) (list (out "t1" "treated" 1.0 "treat") (wk* "t2" "doctor" 1.0 "treat")))
                  #:riders (list (list "Wendy" "A" '("doctor") 40.0))   ; Wendy holds neither "walk" nor "drive"
                  #:mode-recipes (list (mode-recipe "auto" #:pace 0.05 #:uses '(("auto-car" . 0.01)))))   ; AUTOMATED: no capability (anyone), no driver (no one drives)
  (hash-set! *cap* (lg "Svc|auto-car" (cell "A" 0)) 1.0)
  (hash-set! *demand* (lg "treated" (cell "B" 0)) 20.0)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let ((x (car (call-with-values (lambda () (solve-osqp forms labform ncol)) list))))
        (list (S x idx (lambda (k) (string-prefix? "p|ride.Wendy.auto|" k)))         ; the automated car carries her
              (S x idx (lambda (k) (string-prefix? "p|treat|B@" k)))                 ; treated
              (S x idx (lambda (k) (string-prefix? "Lab|driving" k))))))))           ; living DRIVER labour (should be zero)

;; ── (2) CONSUMPTION: ride-hailing as a produced & demanded SERVICE good ──
(define (service)
  (declare-world! #:places '(("town" 0.0 0.0))
                  #:templates
                    (compile-recipe (list (rp "hail" "Ride-hail"))                 ; a driver + a car PRODUCE a "ride" service
                       (list (svc "h1" "ride" 1.0 "hail") (wk* "h2" "driving" 0.2 "hail") (use* "h3" "car" "hail" 0.1 #:qty 1.0))))
  (hash-set! *A* (cell "town" 0) 1000.0)                       ; a driver labour pool (aggregate)
  (hash-set! *cap* (lg "Svc|car" (cell "town" 0)) 1000.0)      ; cars
  (hash-set! *demand* (lg "ride" (cell "town" 0)) 10.0)        ; people want 10 rides (means of consumption)
  (let ((credits (cdr (or (assoc "ride" (good-labour-content)) '("ride" . 0.0)))))   ; the ride's crystallized SNLT = its credit price
    (call-with-values build-located
      (lambda (forms labform ncol cols goods raws idx)
        (let ((x (car (call-with-values (lambda () (solve-native forms labform (located-warm cols ncol idx))) list))))
          (list (S x idx (lambda (k) (string-prefix? "p|hail|town@0" k)))           ; rides produced
                credits))))))                                                       ; credits per ride (SNLT)

(define p (planned)) (define a (automated)) (define s (service))
(define (sd r)(first r))(define (treated r)(second r))(define (drv r)(third r))
(define (rides r)(first r))(define (credits r)(second r))

(format #t "~%── (1) PLANNED work transport: the doctor self-drives a common car to the hospital ──~%")
(format #t "  self-drive trips ~,2f , treated ~,1f , SEPARATE-driver labour ~,2f~%" (sd p) (treated p) (drv p))
(format #t "── (1b) AUTOMATED: Wendy (can't walk/drive) rides a self-driving car, no driver ──~%")
(format #t "  auto trips ~,2f , treated ~,1f , living DRIVER labour ~,2f~%" (sd a) (treated a) (drv a))
(format #t "── (2) CONSUMPTION transport: ride-hailing as a service good ──~%")
(format #t "  rides produced ~,1f , credits/ride (crystallized SNLT) ~,2f~%" (rides s) (credits s))

(let* ((c1 (and (> (sd p) 0.4) (> (treated p) 18.0)))     ; she self-drives to B and treats
       (c2 (< (drv p) 0.01))                              ; with NO separate driver (she IS the driver)
       (c3 (and (> (sd a) 0.4) (> (treated a) 18.0)))     ; the automated car carries Wendy (no capability needed)
       (c4 (< (drv a) 0.01))                              ; …with ZERO living driver labour (the machine drives)
       (c5 (> (rides s) 9.0))                             ; the ride service is produced to meet the demand
       (c6 (> (credits s) 0.15))                          ; and it carries a credit price = the driver's SNLT (~0.2)
       (ok (and c1 c2 c3 c4 c5 c6)))
  (format #t "~%  [~a] PLANNED: doctor self-drives (own time = the cost), treats         (trips ~,2f, treated ~,1f)~%" (if c1 "✓" "✗") (sd p) (treated p))
  (format #t "  [~a] …with no separate driver — she IS the driver (self-propelled+car)  (driver-Lab ~,2f)~%" (if c2 "✓" "✗") (drv p))
  (format #t "  [~a] AUTOMATED: serves Wendy who can't walk OR drive (no capability)     (trips ~,2f, treated ~,1f)~%" (if c3 "✓" "✗") (sd a) (treated a))
  (format #t "  [~a] …with ZERO living driver labour — the cost is the vehicle, not a person  (driver-Lab ~,2f)~%" (if c4 "✓" "✗") (drv a))
  (format #t "  [~a] CONSUMPTION: ride-hailing produces the service for the demand       (rides ~,1f)~%" (if c5 "✓" "✗") (rides s))
  (format #t "  [~a] …consumed in free time, paid in credits = its crystallized SNLT     (credits ~,2f)~%" (if c6 "✓" "✗") (credits s))
  (format #t "~%  ~a planned work transport (mover) · automated (vehicle cost, no driver) · means-of-consumption service (deliver-service, credits, free time)~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
