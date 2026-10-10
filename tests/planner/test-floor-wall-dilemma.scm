;;; test-floor-wall-dilemma.scm — when the only route to bare need crosses a wall.
;;;
;;; A household whose ONLY food is fished from a reef, and a reef whose fragility
;;; has 5 units of headroom left. Feeding the household needs 30. Both limits are
;;; hard — a subsistence floor states what a plan may never do, and a tipping
;;; point is not a thing desire can buy — so no plan satisfies both, and the
;;; honest report is not the word "infeasible" but the PRICE OF EACH HORN:
;;;
;;;   hold the floor → the reef is crossed by how much
;;;   hold the wall  → the household is short by how much
;;;
;;; `plan-dilemma` runs both as ordinary solves of the same program (the move
;;; engine/robust.scm makes for scenarios) and reports the two costs. It does not
;;; choose: which horn to take is a governance question about whose reproduction
;;; and which boundary, and the planner's job is to put the number in front of it.
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-floor-wall-dilemma.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test scope))
(use-modules (playnet test harness) (playnet planner vf schemas) (playnet planner scope live)
             (srfi srfi-1) (ice-9 format))

;; A period here is a WEEK: Ada's 09:00–17:00 every day is 56 h of fishing, the
;; labour this dilemma was sized on, and the same on any date.
(use-modules ((playnet planner solve engine) #:select (set-period-length!)))
(set-period-length! 1.0 "week")
(define win (all-week-window "09:00" "17:00"))
(define agents (list (make-agent #:id "ada" #:type 'person #:name "Ada" #:primary-location "town"
                                 #:classified-as '() #:availability-window win)))
(define spatials (list (make-spatial-thing #:id "town" #:lat 0.0 #:long 0.0)))
(define resources (list (make-economic-resource #:id "sk" #:conforms-to "skill-fish" #:classified-as '()
    #:accounting-quantity (make-measure 1.0 "kg") #:onhand-quantity (make-measure 1.0 "kg") #:current-location "town" #:primary-accountable "ada")))
(define procs (list (make-recipe-process #:id "fish" #:name "Fish")))
;; 1 reef unit + 1 h → 10 kcal, so a 300 kcal floor costs 30 reef.
(define flows
  (list (make-recipe-flow #:id "f1" #:action 'produce #:resource-conforms-to "kcal"
                          #:resource-quantity (make-measure 10.0 "kcal") #:recipe-output-of "fish"
                          #:is-primary #t)
        (make-recipe-flow #:id "f2" #:action 'consume #:resource-conforms-to "reef"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-input-of "fish")
        (make-recipe-flow #:id "f3" #:action 'work #:resource-conforms-to "skill-fish"
                          #:effort-quantity (make-measure 1.0 %effort-unit) #:recipe-input-of "fish")))

(define FLOOR  300.0)
(define FLOORS (list (cons "kcal#town@0" FLOOR)))
(define FRAG   '(("reef#town@0" . (100.0 100.0 0.0 50.0))))   ; alpha 0 ⇒ tip = 100
(define PRIOR  '(("reef#town@0" . 95.0)))                     ; 5 units of headroom left

(define d (plan-dilemma resources agents spatials procs flows
                        #:repro-floors FLOORS #:eco-frag FRAG #:eco-prior PRIOR))

(define a         (assq-ref d 'horn-a))
(define b         (assq-ref d 'horn-b))
(define overshoot (assoc-ref (assq-ref a (quote overshoot)) "reef#town@0"))
(define shortfall (assoc-ref (assq-ref b (quote shortfall)) "kcal#town@0"))

(format #t "~%── the only food crosses the only wall ──~%")
(format #t "  reef headroom 5 · feeding the household costs 30~%")
(format #t "  HORN A — hold the floor: the reef is crossed by ~,1f~%" overshoot)
(format #t "  HORN B — hold the wall:  the household is short by ~,0f of ~,0f kcal~%"
        shortfall FLOOR)

(check "the two cannot hold together" (assq-ref d 'feasible-together?) #f)
(check-pred "holding the floor IS a plan — the wall stood aside, not deleted"
            (eq? #t (assq-ref (assq-ref a 'plan) 'feasible)))
(check-pred "holding the wall IS a plan — the floor became a desire, and yielded"
            (eq? #t (assq-ref (assq-ref b 'plan) 'feasible)))
(check-pred "holding the floor costs a real overshoot past the tip" (> overshoot 1.0))
(check-pred "holding the wall costs real hunger" (> shortfall 1.0))
;; Each horn pays in its OWN currency and neither is free: that is what makes this
;; a choice for governance rather than an arithmetic the planner can settle.
(check-pred "neither horn is free" (and (> overshoot 0.0) (> shortfall 0.0)))

(format #t "~%")
(test-summary!)
