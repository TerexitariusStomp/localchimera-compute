;;; test-manner-pace.scm — a manner's nominal pace comes from the router's own data.
;;;
;;; A travel mode states its own pace (the mover's `work` flow, hours per km). A GENERIC
;;; transport recipe — a freight haul that names a vehicle and a manner but no mover —
;;; has none, so the manner's typical pace is what turns an arc's measured hours into the
;;; effective distance its time-like flows (vehicle `use`, driver `work`) are spent over.
;;; That pace is read off the table, as the median of the manner's (hours . km) entries
;;; (`ingest-travel-times!`; the live table carries the router's km on every arc it has a
;;; prior for). The manners bag holds no pace: a hand-entered constant would stand in for
;;; something the data already says. These properties hold:
;;;
;;;   BAG       no manners bag the planner ships carries a `pace`
;;;   PARITY    with no measurement the arc table is empty and every arc falls back to
;;;             pace × distance, so time over pace is distance
;;;   BARE      a bare measured hour has no distance beside it and says nothing of a
;;;             manner's typical pace: the haul is the plan it was with no measurement
;;;   SPEAKS    arcs measured with their distance move a generic haul's plan: a congested
;;;             arc costs more of the vehicle's and the driver's hours than a free one
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-manner-pace.scm

(use-modules (playnet test harness)
             (playnet knowledge recipes berlin-commune-seed) (playnet knowledge recipes berlin-transit) (playnet knowledge recipes transit-shed) (playnet vf formulas capacity) (playnet scope root) (playnet vf schemas) (srfi srfi-1)
             (playnet scope live)
             (playnet doors service)
             (playnet knowledge recipes berlin-transit)
             (goblins) (goblins vat)
             (srfi srfi-1))

(define hvat (spawn-vat #:name "manner-pace"))
(define hroot (with-vat hvat (spawn-scope-root "Berlin")))
(with-vat hvat
  (seed-berlin-commune! hroot #:transit? #t)
  ($ ($ hroot 'observer) 'seed-resource
     (make-economic-resource #:id "crates" #:name "crates" #:conforms-to "spec-bt-freight" #:classified-as '()
       #:accounting-quantity (make-measure 500.0 "kg") #:onhand-quantity (make-measure 500.0 "kg") #:current-location "berlin-commune-farm"
       #:primary-accountable "commune-berlin-commune-farm")))

(define market "spec-bt-freight#berlin-markthalle@0")
(define held (with-vat hvat ($ ($ hroot 'observer) 'all-resources)))
(define caps
  (append (map (lambda (kv) (cons (car kv) (* 50.0 (cdr kv))))
               (held-svc-caps held '(0) #:hours-of resource-window-hours
                              #:specs '("spec-bt-transit-pass" "spec-bt-cargo-bike")))
          (svc-eco-caps (map (lambda (spec) (list spec "berlin-commune-farm" 200.0))
                             '("spec-bt-ubahn" "spec-bt-sbahn" "spec-bt-tram" "spec-bt-bus"))
                        '(0))))
;; what the router measured, both ways, for every manner the commune travels by
(define measured
  (append-map (lambda (mh)
                (list (cons (string-append "berlin-commune-farm|berlin-markthalle|" (car mh)) (cdr mh))
                      (cons (string-append "berlin-markthalle|berlin-commune-farm|" (car mh)) (cdr mh))))
              '(("auto" . 0.45) ("pedestrian" . 3.1) ("bicycle" . 0.9) ("bus" . 0.8) ("multimodal" . 0.7))))
(define (hauled table)
  "The total quantity the haul's plan commits: one number that moves when any row does."
  (with-vat hvat
    (let ((r (plan-scope->alist hroot #:manners berlin-transit-manners #:eco-caps caps
                                #:arc-table table #:demand (list (cons market 400.0)))))
      (fold + 0.0 (map (lambda (m) (assq-ref m 'quantity)) (assq-ref r 'material))))))

;; what the router measured: bare hours, and the same arcs with their distance (one
;; congested direction, one free) for every manner the commune travels by
(define (arcs-with entry)
  (append-map (lambda (mh)
                (list (cons (string-append "berlin-commune-farm|berlin-markthalle|" (car mh)) (entry (cdr mh) 'slow))
                      (cons (string-append "berlin-markthalle|berlin-commune-farm|" (car mh)) (entry (cdr mh) 'free))))
              '(("auto" . 0.45) ("pedestrian" . 3.1) ("bicycle" . 0.9) ("bus" . 0.8) ("multimodal" . 0.7))))
(define bare-table (arcs-with (lambda (h dir) h)))
(define km-table   (arcs-with (lambda (h dir) (cons (if (eq? dir 'slow) (* 3.0 h) h) 10.0))))

(display "\n── BAG: no shipped manners bag carries a pace ──\n")
(check "the Berlin shed's bag" (assq 'pace berlin-transit-manners) #f)
(check "the shed constructor's bag" (assq 'pace (transit-manners)) #f)

(define bare      (hauled '()))
(define bare-hrs  (hauled bare-table))
(define spoken    (hauled km-table))

(display "\n── BARE: a measured hour with no distance beside it moves nothing ──\n")
(check "the haul is the plan it was with no measurement" (< (abs (- bare-hrs bare)) 1e-6) #t)

(display "\n── SPEAKS: arcs measured with their distance move a generic haul ──\n")
(check "the haul's plan follows the congestion the table shows" (> (abs (- spoken bare)) 1.0) #t)

(test-summary!)
