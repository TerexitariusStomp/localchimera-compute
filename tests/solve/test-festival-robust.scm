;;; test-festival-robust.scm — the supply shock as UNCERTAINTY: plant before the
;;; harvest is known, and let diversity emerge from defending the crowd's floor.
;;;
;;; The festival must feed its crowd (a reproduction floor on `meal`) from land it
;;; plants NOW, before it knows the season. Two crops make the same meal:
;;;   grain — high yield in a good year, but wiped out by blight
;;;   beans — steady in both
;;; The planting (grow-grain / grow-beans) is FIRST-STAGE — committed once, shared
;;; across every future — because you sow before you know. The floor must hold in
;;; EVERY scenario.
;;;
;;;   DETERMINISTIC (plan for the mean year): plants a grain monoculture (best
;;;      expected yield) — and STARVES the crowd if blight hits.
;;;   ROBUST (plan good-year AND blight together): diversifies into beans, so the
;;;      floor holds even under blight. Diversity is DERIVED from the floor +
;;;      uncertainty — no new solver, just a scenario-aware assembly (engine/robust.scm).
;;;
;;; Uses the flat prelude bootstrap (like robust-records-test) so plan-from-records,
;;; robust-plan-report and the <planning-scenario> accessors share one namespace.
;;; Pure solver ⇒ no blake3.
;;;
;;; Run: guile -L module tests/solve/test-festival-robust.scm

;; from the repository root (the Run: line); current-filename is #f or
;; -L-relative depending on invocation — both wrong for building paths
(use-modules (playnet test planner prelude)
             (playnet solve engine) (playnet solve plan)
             (playnet vf schemas) (playnet vf beyond scenario)
             (srfi srfi-1)
             (ice-9 format))

;; a festival plot (LAND): 2000 units on hand — a raw consumed by growing, no
;; producer, so it is a hard cap (you have the field you have).
(define spatials (list (make-spatial-thing #:id "farm" #:lat 0.0 #:long 0.0)))
(define resources
  (list (make-economic-resource #:id "plot" #:conforms-to "land" #:classified-as '()
          #:accounting-quantity (make-measure 2000.0 "plot") #:onhand-quantity (make-measure 2000.0 "plot") #:current-location "farm")))
;; two grows, same output `meal`; each consumes 1 plot → 1 meal (BASE; scenarios scale it).
(define procs (list (make-recipe-process #:id "grow-grain" #:name "Grow Grain")
                    (make-recipe-process #:id "grow-beans" #:name "Grow Beans")))
(define flows
  (list (make-recipe-flow #:id "gl" #:action 'consume #:resource-conforms-to "land"
                          #:resource-quantity (make-measure 1.0 "plot")
                          #:recipe-input-of "grow-grain")
        (make-recipe-flow #:id "gm" #:action 'produce #:resource-conforms-to "meal"
                          #:resource-quantity (make-measure 1.0 "meal")
                          #:recipe-output-of "grow-grain" #:is-primary #t)
        (make-recipe-flow #:id "bl" #:action 'consume #:resource-conforms-to "land"
                          #:resource-quantity (make-measure 1.0 "plot")
                          #:recipe-input-of "grow-beans")
        (make-recipe-flow #:id "bm" #:action 'produce #:resource-conforms-to "meal"
                          #:resource-quantity (make-measure 1.0 "meal")
                          #:recipe-output-of "grow-beans" #:is-primary #t)))
;; feed 2000, and a surplus demand that rewards grain's high good-year yield.
(define repro-floors '(("meal#farm@0" . 2000.0)))
(define demand       '(("meal#farm@0" . 10000.0)))

;; scenarios keyed by grow PROC — yield multipliers on that proc's output.
;;   good year (p .7): grain 4.0/plot, beans 1.3/plot
;;   blight   (p .3): grain 0.0,      beans 1.2/plot
(define det-scenarios                                  ; the naive "plan for the mean"
  (list (make-planning-scenario "mean" #f 1.0 '(("grow-grain" . 2.8) ("grow-beans" . 1.27)) "mean year")))
(define rob-scenarios                                  ; the two real futures
  (list (make-planning-scenario "good"   "sc-good"   0.7 '(("grow-grain" . 4.0) ("grow-beans" . 1.3)) "good year")
        (make-planning-scenario "blight" "sc-blight" 0.3 '(("grow-grain" . 0.0) ("grow-beans" . 1.2)) "blight year")))

(define (plant scenarios)
  (call-with-values
    (lambda () (plan-from-records resources '() spatials procs flows
                 #:scenarios scenarios #:first-stage-procs '("grow-grain" "grow-beans")
                 #:repro-floors repro-floors #:demand demand #:per-agent? #f))
    (lambda (ints coms material fill cols x idx ntot report)
      (let ((fs (or (assoc-ref report 'first-stage-plan) '())))
        (list (or (assoc-ref fs "grow-grain") 0.0) (or (assoc-ref fs "grow-beans") 0.0)
              (assoc-ref report 'robust) (assoc-ref report 'nscenarios))))))

(define det (plant det-scenarios))
(define rob (plant rob-scenarios))
(define det-grain (car det)) (define det-beans (cadr det))
(define rob-grain (car rob)) (define rob-beans (cadr rob))
;; meal each plan yields IF blight hits (grain→0, beans→1.2) / in a good year
(define (blight-food grain beans) (+ (* 0.0 grain) (* 1.2 beans)))
(define (good-food   grain beans) (+ (* 4.0 grain) (* 1.3 beans)))

(format #t "~%── plant before the season: the crowd's floor must hold in every future ──~%")
(format #t "  DETERMINISTIC (mean year): grain ~,0f plots · beans ~,0f plots~%" det-grain det-beans)
(format #t "    → if BLIGHT hits: meal = ~,0f   (floor 2000)  ~a~%"
        (blight-food det-grain det-beans)
        (if (< (blight-food det-grain det-beans) 2000.0) "*** THE CROWD STARVES ***" "ok"))
(format #t "  ROBUST (~a scenarios):     grain ~,0f plots · beans ~,0f plots~%"
        (cadddr rob) rob-grain rob-beans)
(format #t "    → good year: meal = ~,0f   ·   blight: meal = ~,0f   (floor 2000)~%"
        (good-food rob-grain rob-beans) (blight-food rob-grain rob-beans))

(format #t "~%── assertions ──~%")
(check "deterministic plants a grain MONOCULTURE (grain ≫ beans)" (> det-grain (* 5.0 (+ det-beans 1.0))))
(check "…and that monoculture STARVES the crowd if blight hits (meal < floor)"
       (< (blight-food det-grain det-beans) 2000.0))
(check "ROBUST diversifies into beans (≫ the deterministic plan's beans)" (> rob-beans (+ det-beans 500.0)))
(check "…keeping some grain for the good-year upside" (> rob-grain 1.0))
(check "the robust plan feeds the crowd in the GOOD year (≥ floor)"
       (>= (good-food rob-grain rob-beans) (* 0.98 2000.0)))
(check "the robust plan STILL feeds the crowd under BLIGHT (≥ floor) — diversity is the hedge"
       (>= (blight-food rob-grain rob-beans) (* 0.98 2000.0)))
(check "the <planning-scenario> set drove a 2-scenario robust solve"
       (and (eq? (caddr rob) #t) (= (cadddr rob) 2)))

(check-done "  robust festival: plant before the harvest, defend the crowd's floor in every future →~%  diversity (beans as the hedge) emerges, no new solver.~%")
