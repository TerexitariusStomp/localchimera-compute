;;; test-transboundary-commons.scm — the metabolic border (playnet.typ §"The
;;; metabolic border" / §"A transboundary commons is one pooled budget").
;;;
;;; Two festival sites straddle a jurisdiction line and both draw on ONE shared
;;; river. The river is a cumulative possibility-tension (`eco-budget`) on total
;;; `water` — ONE barrier on the sum of the draw across every cell, whatever
;;; jurisdiction holds each straw. So:
;;;   • without the budget, the river is drawn freely and both sites are fed;
;;;   • WITH the river's envelope, the total draw is capped BELOW both needs — the
;;;     sites share the scarce river, the pooled budget binds ACROSS the border;
;;;   • and the cap is IDENTICAL whether the sites sit in two jurisdictions or one
;;;     — "the possibility-tension does not count borders." The envelope follows
;;;     the metabolism (the river), not the map. The gap between them is a
;;;     duress-gap (refederation would draw the scope around the loop; the
;;;     jurisdiction stays put).
;;;
;;; Uses the flat prelude bootstrap for plan-from-records + #:eco-budget.
;;; Pure solver ⇒ no blake3.
;;;
;;; Run: guile -L module tests/planner/test-transboundary-commons.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test scope))
(use-modules (playnet test planner prelude)
             (playnet planner solve engine)
             (playnet planner vf schemas)
             (srfi srfi-1)
             (ice-9 format))

;; a festival process: draw 1 water + a little crew labour → serve 1 meal.
(define procs (list (make-recipe-process #:id "rp-fest" #:name "Festival draws the river")))
(define flows
  (list (make-recipe-flow #:id "f-water" #:action 'consume #:resource-conforms-to "water"
                          #:resource-quantity (make-measure 1.0 "m3") #:recipe-input-of "rp-fest")
        (make-recipe-flow #:id "f-cook"  #:action 'work #:resource-conforms-to "cook"
                          #:effort-quantity (make-measure 0.01 %effort-unit) #:recipe-input-of "rp-fest")
        (make-recipe-flow #:id "f-meal"  #:action 'produce #:resource-conforms-to "meal"
                          #:resource-quantity (make-measure 1.0 "meal") #:recipe-output-of "rp-fest"
                          #:is-primary #t)))
;; total `water` drawn across ALL cells (the pooled river draw).
(define (drawn-of material spec)
  (fold (lambda (c a) (if (and (eq? (commitment-action c) 'consume)
                               (equal? (commitment-resource-conforms-to c) spec))
                          (+ a (measure-has-numerical-value (commitment-resource-quantity c))) a))
        0.0 material))

;; one solve: `budget?` seats the river's envelope; `one-juris?` puts both sites
;; in the SAME jurisdiction instead of straddling the border.
(define (run budget? one-juris?)
  (define spatials
    (list (make-spatial-thing #:id "world")
          (make-spatial-thing #:id "jurisA" #:lat 40.0 #:long -70.0 #:contained-in "world")
          (make-spatial-thing #:id "jurisB" #:lat 40.0 #:long -60.0 #:contained-in "world")
          (make-spatial-thing #:id "siteA" #:lat 40.0 #:long -70.0 #:contained-in "jurisA")
          (make-spatial-thing #:id "siteB" #:lat 40.0 #:long -60.0
                              #:contained-in (if one-juris? "jurisA" "jurisB"))))
  (define agents (list (make-agent #:id "crewA" #:type 'person #:name "Crew A" #:classified-as '())
                       (make-agent #:id "crewB" #:type 'person #:name "Crew B" #:classified-as '())))
  (define resources (list (er "skA" "cook" "crewA" #:place "siteA" #:qty 1.0 #:unit "u") (er "skB" "cook" "crewB" #:place "siteB" #:qty 1.0 #:unit "u")))
  (call-with-values
    (lambda () (plan-from-records resources agents spatials procs flows
                 #:demand '(("meal#siteA@0" . 10.0) ("meal#siteB@0" . 10.0))
                 #:periods '(0) #:per-agent? #f #:agent-hours (lambda (a t) 20.0)
                 #:eco-budget (if budget? '(("water" . (8.0 12.0 0.5 50.0))) '())  ; river envelope, s_tip≈10
                 #:raws       (if budget? '() '("water"))))                        ; else water is a free raw
    (lambda (ints coms material fill cols x idx ntot report)
      (list fill (drawn-of material "water")))))

(define free   (run #f #f))          ; no envelope — draw the river freely
(define shared (run #t #f))          ; the river's envelope, sites in TWO jurisdictions
(define same   (run #t #t))          ; the same envelope, sites in ONE jurisdiction
(define (fill r) (first r)) (define (water r) (second r))

(format #t "~%── one shared river, two festival sites across a jurisdiction line ──~%")
(format #t "  no envelope:            fill ~,3f   total water drawn ~,1f  (both fed; free draw unbounded)~%" (fill free) (water free))
(format #t "  river envelope (2 juris): fill ~,3f   total water drawn ~,1f  (capped near s_tip 10)~%" (fill shared) (water shared))
(format #t "  river envelope (1 juris): fill ~,3f   total water drawn ~,1f  (SAME — border-blind)~%" (fill same) (water same))

(format #t "~%── assertions ──~%")
(check "without the envelope, the river is drawn freely and both sites are fed"
       (and (> (fill free) 0.95) (> (water free) 18.0)))
(check "the shared river envelope caps the TOTAL draw below both needs (pooled budget binds)"
       (and (< (water shared) 14.0) (< (fill shared) 0.8)))
(check "…so feeding is scarcer under the shared river than with a free one"
       (< (fill shared) (fill free)))
(check "the cap is IDENTICAL across a border vs within one jurisdiction (does not count borders)"
       (and (< (abs (- (water shared) (water same))) 0.5)
            (< (abs (- (fill shared) (fill same))) 0.02)))
(check "the envelope binds near the river's tipping point (s_tip 10, not 20)"
       (and (> (water shared) 7.0) (< (water shared) 13.0)))

(check-done "  a transboundary commons is ONE pooled budget: the possibility-tension caps the~%  total draw across the border, following the metabolism (the river), not the map.~%")
