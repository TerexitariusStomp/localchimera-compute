;;; test-scenario-shocks.scm — a scenario generalizes BEYOND crop yields to ANY
;;; (action, spec) intent — the same unit the Observer measures ex-post. A shock is
;;; (action key factor):
;;;   produce           → OUTPUT yield ×r        (the crop case, one instance)
;;;   consume|use|work  → INPUT/effort intensity ×r
;;;   avail             → a spec's raw SUPPLY ×r
;;; and calibrate-shocks folds observed (action spec intended realized) tuples — what
;;; the Observer records — back into empirical shocks. Plan forward, observe backward:
;;; one relation, intent conforms to specification.
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-scenario-shocks.scm

(use-modules (playnet test planner prelude)
             (playnet solve engine)
             (playnet vf formulas shocks)
             (playnet vf schemas) (playnet vf beyond scenario)
             (playnet knowledge dsl shorthand)
             (srfi srfi-1)
             (ice-9 format))
(define (~= a b) (< (abs (- a b)) 1e-6))

;; ── A. one shock abstraction reaches every action, keyed by proc OR spec ──────
(format #t "~%── A. shocks generalize to any (action, spec) intent ──~%")
;; the factor a branch puts on each flow of `warm` (fuel + stoking → heat), read
;; off the matcher the build itself consults (shocks.scm branch-flow-factor;
;; its own properties: test-shocks.scm)
(define (factor-under shocks)
  (branch-flow-factor (scenario-shocks (make-planning-scenario "s" #f 1.0 shocks #f))))
;; scenario shocks: output yield, input intensity, work-effort intensity — one per action
(define mix (factor-under '((produce "heat" 0.5) (consume "fuel" 1.5) (work "stoke-skill" 2.0))))
(check "produce shock scales OUTPUT yield (heat ×0.5)"           (~= (mix 'produce "warm" "heat" 0 "z") 0.5))
(check "consume shock scales INPUT intensity (fuel ×1.5)"        (~= (mix 'consume "warm" "fuel" 0 "z") 1.5))
(check "work shock scales EFFORT hours (×2)"                     (~= (mix 'work "warm" "stoke-skill" 0 "z") 2.0))
(check "a bare (key . factor) = produce shock (heat ×0.25)"
       (~= ((factor-under '(("heat" . 0.25))) 'produce "warm" "heat" 0 "z") 0.25))
(check "a shock can key by PROCESS not just spec (consume warm → fuel ×3)"
       (~= ((factor-under '((consume "warm" 3.0))) 'consume "warm" "fuel" 0 "z") 3.0))

;; ── B. calibration: the Observer's ratios BECOME the scenario ─────────────────
;; observations = (action spec intended realized) — exactly committed-vs-fulfilled.
(format #t "~%── B. calibrate-shocks: observed fulfillment → empirical shocks ──~%")
(define obs
  '((produce "rice"    100.0 45.0)   ; two rice harvests: 45% then 55% ⇒ mean 0.50
    (produce "rice"    100.0 55.0)
    (work    "surgery"  10.0  8.0)   ; surgeons delivered 80% of committed hours
    (consume "fuel"    100.0 150.0))) ; a cold year burned 1.5× the fuel per unit
(define shocks (calibrate-shocks obs))
(define (shock-of a s) (any (lambda (x) (and (eq? (car x) a) (string=? (cadr x) s) (caddr x))) shocks))
(check "rice produce ratio = mean(0.45,0.55) = 0.50"    (~= (shock-of 'produce "rice") 0.5))
(check "surgery work ratio = 0.80"                       (~= (shock-of 'work "surgery") 0.8))
(check "fuel consume intensity = 1.50"                   (~= (shock-of 'consume "fuel") 1.5))
(check "these ARE valid scenario shocks (round-trips)"   (= (length (scenario-shocks
         (make-planning-scenario "cal" #f 1.0 shocks #f))) 3))

;; ── C. end-to-end: a NON-crop shock changes a real solved plan ────────────────
;; A heat scope: `warm` consumes fuel → produces heat, fuel a capped raw (4 u). Same
;; recipe under three futures shifts what the solver can deliver — no crop in sight.
(format #t "~%── C. a non-crop shock flows through a real solve ──~%")
(define spatials (list (place* "z")))
(define resources (list (er "fuel1" "fuel" #f #:place "z" #:qty 4.0 #:unit "u")))
(define procs (list (rp* "warm" "Warm")))
(define wflows
  (list (consume* "wf" "fuel" 1.0 "warm" "u")
        (out* "wh" "heat" 1.0 "warm" "u")))
(define (heat-under scenario)
  (call-with-values
    (lambda () (plan-robust-from-records resources '() spatials procs wflows
                 #:scenarios (list scenario) #:first-stage-procs '("warm") #:raws '("fuel")
                 #:demand '(("heat#z@0" . 10.0)) #:repro-floors '(("heat#z@0" . 1.0)) #:per-agent? #f))
    (lambda (x fs . _) (first-stage-activity x fs "warm"))))
(define h-normal (heat-under (make-planning-scenario "normal" #f 1.0 '() "no shock")))
(define h-cold   (heat-under (make-planning-scenario "cold"   #f 1.0 '((consume "warm" 2.0)) "×2 fuel/heat")))
(define h-scarce (heat-under (make-planning-scenario "scarce" #f 1.0 '((avail "fuel" 0.5)) "half the fuel")))
(format #t "  heat from 4u fuel:  normal ~,2f   cold(2× intensity) ~,2f   scarce(½ supply) ~,2f~%" h-normal h-cold h-scarce)
(define (near h v) (< (abs (- h v)) 0.05))    ; interior-point convergence tolerance
(check "normal: 4 fuel → ~4 heat"                          (near h-normal 4.0))
(check "consume-INTENSITY shock halves output (→~2 heat)"  (near h-cold 2.0))
(check "avail-SUPPLY shock halves output (→~2 heat)"       (near h-scarce 2.0))
(check "the heat floor (1.0) still holds under every shock" (and (>= h-normal 1.0) (>= h-cold 1.0) (>= h-scarce 1.0)))

(check-done "  one scenario abstraction shocks any verb, any product, any supply;~%  the Observer's fulfillment ratios calibrate it. Crops were the test tube.~%")
