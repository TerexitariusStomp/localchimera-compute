;;; food-surplus-scenario-test.scm — SF food-surplus redistribution, on the CONVEX
;;; planner (a condensed re-expression of the old relational
;;; deprecated-planner-tests/test-food-surplus-scenario.scm).
;;;
;;; The old test ran a 5-scope relational federation (SF Market + Safeway donors →
;;; Food Runners logistics → GLIDE + Mission Meals recipients). The economic content
;;; ports to ONE convex solve with no new machinery:
;;;
;;;   • donor SURPLUS        → an on-hand stock of `produce` (*init*)
;;;   • the SORTING recipe   → consume produce + USE a reefer van (Svc|van) +
;;;                            WORK volunteer-hours → produce `sorted-produce`
;;;   • recipient DEMAND     → demand for `sorted-produce`
;;;   • LOGISTICS is finite  → the van's per-period service is capped (*cap* on Svc|van)
;;;
;;; The point the scenario makes: redistribution is bounded by LOGISTICS, not by the
;;; mountain of surplus. Surplus is ample; what moves is set by how many van-hours the
;;; Food Runners can field — lift the van cap and more of the demand is met, up to the
;;; recipients' need. That is the reefer-van fragility of the digital-domain comms work,
;;; here in its literal form.
;;;
;;; Run:  guile -L module tests/solve/food-surplus-scenario-test.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (srfi srfi-1) (ice-9 format))
(define here (dirname (current-filename)))
(define root (dirname (dirname here)))
(use-modules (playnet solve engine) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver)
             (playnet vf schemas))

;; SORT: 1 kg produce (drawn from donor surplus) + 0.02 van-hours + 0.05 volunteer-hours
;; ⇒ 1 kg sorted-produce a recipient can receive.
(define sort-tpl
  (car (compile-recipe (list (rp "sort" "Pick up & sort donated produce"))
         (list (out "s1" "sorted-produce" 1.0 "sort")                                  ; produce the deliverable
               (make-recipe-flow #:id "s2" #:action 'consume #:resource-conforms-to "produce" #:resource-quantity (make-measure 1.0 "kg")    ; draw down donor surplus
 #:recipe-input-of "sort")
               (wrk "s3" 0.05 "sort")                                                  ; volunteer labour
               (make-recipe-flow #:id "s4" #:action 'use #:resource-conforms-to "van" #:resource-quantity (make-measure 1.0 %count-unit)          ; USE a reefer van (Svc|van)
                                 #:effort-quantity (make-measure 0.02 %effort-unit) #:recipe-input-of "sort")))))

;; One hub, one period. SURPLUS = donor produce on hand. VAN-HOURS = the Food Runners'
;; fielded reefer-van service this period. DEMAND = recipients' sorted-produce need.
(define (run surplus van-hours demand)
  (declare-world! #:places '(("hub" 0.0 0.0)) #:templates (list sort-tpl))
  (hash-set! *A* (cell "hub" 0) 1000.0)                              ; volunteers abundant here — isolate the van bottleneck
  (hash-set! *init* (lg "produce" (cell "hub" 0)) surplus)           ; donor surplus, on hand
  (hash-set! *cap* (lg "Svc|van" (cell "hub" 0)) van-hours)          ; the finite logistics
  (hash-set! *demand* (lg "sorted-produce" (cell "hub" 0)) demand)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let ((x (car (call-with-values
                      (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
            (i (hash-ref idx "p|sort|hub@0")))                      ; #f when the van cap prunes the column
        (if i (vector-ref x i) 0.0)))))                            ; kg sorted-produce delivered (0 if sort can't run)

;; Surplus is ALWAYS ample (600 kg); demand is 250 kg (50 GLIDE + 200 Mission Meals).
;; Vary only the van-hours the logistics coordinator can field.
;; 0.02 van-h/kg ⇒ meeting 250 kg needs 5.0 van-hours.
(define starved   (run 600.0 2.0 250.0))   ; 2 van-h ⇒ can move ~100 kg — surplus rots for want of trucks
(define ample     (run 600.0 6.0 250.0))   ; 6 van-h ⇒ enough to meet the whole 250 kg demand
(define no-van    (run 600.0 0.0 250.0))   ; no van ⇒ nothing moves, however much is donated

(format #t "~%── SF food surplus: 600 kg donated, 250 kg needed; the van is the bottleneck ──~%")
(format #t "  ~26a ~8,1f kg~%" "no van fielded"        no-van)
(format #t "  ~26a ~8,1f kg~%" "2 van-hours (starved)" starved)
(format #t "  ~26a ~8,1f kg~%" "6 van-hours (ample)"   ample)

(let* ((c0 (member "Svc|van" (map car (proc-inputs sort-tpl))))          ; `use` compiled to a Svc consume
       (c1 (< no-van 1e-3))                                              ; no logistics ⇒ no redistribution (solver ε)
       (c2 (and (> starved 95.0) (< starved 105.0)))                    ; van-bound: 2 / 0.02 = 100 kg, NOT the 600 surplus
       (c3 (and (> ample 249.0) (< ample 251.0)))                       ; enough vans ⇒ the whole demand met
       (c4 (> ample starved))                                           ; more logistics ⇒ more redistribution
       (ok (and c0 c1 c2 c3 c4)))
  (format #t "~%  [~a] the sort recipe USEs a reefer van (Svc|van)~%" (if c0 "✓" "✗"))
  (format #t "  [~a] no van ⇒ 0 kg moves, however much is donated        (~,1f kg)~%" (if c1 "✓" "✗") no-van)
  (format #t "  [~a] redistribution is LOGISTICS-bound, not surplus-bound (2 van-h ⇒ ~,1f kg, not 600)~%" (if c2 "✓" "✗") starved)
  (format #t "  [~a] enough van-hours ⇒ the recipients' 250 kg is met     (~,1f kg)~%" (if c3 "✓" "✗") ample)
  (format #t "  [~a] more logistics ⇒ more surplus redistributed~%" (if c4 "✓" "✗"))
  (format #t "~%  ~a a food-surplus network redistributes on the convex planner — donor surplus flows through a van-and-volunteer sort recipe to recipients, bounded by the trucks, not the mountain of food~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
