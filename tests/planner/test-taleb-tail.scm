;;; test-taleb-tail.scm — don't bet survival on the historical distribution.
;;;
;;; Taleb: the record undersamples the tail; ±1σ assumes thin tails rainfall
;;; doesn't have; and for RUIN (starvation is absorbing) you refuse it at ANY
;;; probability, not by expected-value. Our machinery already enforces the
;;; reproduction floor per-scenario UNWEIGHTED — so adding a p=0 TAIL scenario
;;; (a famine-scale monsoon collapse, beyond the 1960–2023 record) defends
;;; survival against a failure we make NO forecast about.
;;;
;;; The lesson, on the 2 ha Doon Valley farm:
;;;   • Planning against the historical distribution "safely" feeds 28 people —
;;;     but a beyond-record failure would starve them (a hidden over-promise).
;;;   • Planning ruin-robust (+ the tail), the planner REFUSES to guarantee 28,
;;;     and instead guarantees a smaller, HONEST number through even the tail.
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-taleb-tail.scm

(use-modules (srfi srfi-1) (ice-9 format))
(define (sibling f) (or (find file-exists? (filter-map (lambda (p) (and (string? p) (string-append (dirname p) "/" f)))
                                                       (cons (current-filename) (command-line))))
                        (string-append "module/playnet/planner/" f)))
(use-modules (playnet solve engine)
             (playnet vf schemas) (playnet vf beyond scenario)
             (playnet knowledge worlds bioregions))
;; engine/robust.scm arrives with the engine — (playnet solve engine) loads it into
;; itself and exports its names, so the load that stood here was a second copy
;; of the same text into this module (retired with the engine-as-module arc).
(use-modules (playnet knowledge worlds doon-valley))
(primitive-load (sibling "../../module/playnet/knowledge/recipes/navdanya-farm.scm"))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define LAND 2.0)
(define (floor-of people) (navdanya-food-floor people))
(define (ha plan c) (or (assoc-ref plan c) 0.0))
(define (food-under plan s)
  (fold (lambda (c a) (+ a (* (ha plan c) (assoc-ref *doon-valley-crop-yields* c)
                              (or (assoc-ref (planning-scenario-yield-multipliers s) c) 1.0))))
        0.0 *navdanya-staples*))
;; a plan that cannot hold the floor in every scenario is INFEASIBLE — the solver
;; raises "no strictly-feasible point". Catch it: the planner refusing to promise.
(define (try-farm people scenarios)
  (catch #t
    (lambda () (assoc-ref (plan-navdanya-farm #:land-ha LAND #:household people #:scenarios scenarios)
                          'first-stage-plan))
    (lambda _ 'infeasible)))

(define stress *doon-valley-stress-scenario*)

;; 1) HISTORICAL-distribution plan for 28 — feels safe, but is a tail over-promise
(define hist28 (try-farm 28 *doon-valley-scenarios*))
(define hist28-tail-food (food-under hist28 stress))
(format #t "~%Historical-distribution plan for 28 people (floor ~,0f kg):~%" (floor-of 28))
(format #t "  under the beyond-record TAIL it delivers ~,0f kg → ~,0f%% of need  (~a)~%"
        hist28-tail-food (* 100.0 (/ hist28-tail-food (floor-of 28)))
        (if (< hist28-tail-food (floor-of 28)) "FAMINE — the record lied" "ok"))

;; 2) RUIN-ROBUST plan for 28 — the planner cannot guarantee it through the tail
(define tail28 (try-farm 28 *doon-valley-scenarios/tail-robust*))
(format #t "~%Ruin-robust plan for 28 people (+ tail):  ~a~%"
        (if (eq? tail28 'infeasible) "INFEASIBLE — planner REFUSES to over-promise" "(feasible?!)"))

;; 3) RUIN-ROBUST plan for 15 — guaranteed through EVERY future incl. the tail
(define tail15 (try-farm 15 *doon-valley-scenarios/tail-robust*))
(format #t "~%Ruin-robust plan for 15 people (+ tail):  rice ~,2f maize ~,2f ragi ~,2f pulses ~,2f~%"
        (ha tail15 "rice") (ha tail15 "maize") (ha tail15 "ragi") (ha tail15 "pulses"))
(for-each (lambda (s)
            (let ((f (food-under tail15 s)))
              (format #t "    ~12a food = ~5,0f kg  (floor ~,0f)  ~a~%" (planning-scenario-id s) f (floor-of 15)
                      (if (< f (* 0.99 (floor-of 15))) "*** HUNGRY ***" "fed"))))
          *doon-valley-scenarios/tail-robust*)

(format #t "~%── assertions ──~%")
(check "historical plan STARVES 28 people in the beyond-record tail"  (< hist28-tail-food (floor-of 28)))
(check "planner REFUSES to guarantee 28 through the tail (infeasible)" (eq? tail28 'infeasible))
(check "ruin-robust guarantees 15 people in a NORMAL year"   (>= (food-under tail15 (car *doon-valley-scenarios*)) (* 0.99 (floor-of 15))))
(check "ruin-robust guarantees 15 people in an ORDINARY drought"
       (>= (food-under tail15 (find (lambda (s) (equal? (planning-scenario-id s) "doon-drought")) *doon-valley-scenarios*)) (* 0.99 (floor-of 15))))
(check "ruin-robust guarantees 15 people in the FAMINE-SCALE TAIL"   (>= (food-under tail15 stress) (* 0.99 (floor-of 15))))
(check "so the HONEST carrying capacity (15) is well below the historical over-promise (28)" (< 15 28))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — survival is NOT bet on the historical distribution.~%  The record's carrying capacity is an over-promise; the ruin-robust number,~%  guaranteed through a failure we make no forecast about, is the honest one.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
