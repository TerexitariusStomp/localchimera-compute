;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-regenerating-stock.scm — the REGENERATING-STOCK recurrence, in the small.
;;;
;;; A field carries a CONDITION — "fertility", a storable level that starts at 100.
;;; Growing food MINES it (each meal draws 1 fertility); the level is threaded from
;;; season to season by the ordinary storable carry, so
;;;
;;;     fertility[t+1] = fertility[t] − grown[t] + regenerated[t],   fertility ≥ 0.
;;;
;;; A floor of 30 meals is due EVERY season for 4 seasons (120 in all). But only 100
;;; fertility stands in the ground, and each meal spends one — so a farm that only
;;; MINES tops out at 100 meals and STARVES in the last season. Add a regeneration
;;; recipe (compost: manure → fertility) and the planner rebuilds the condition it
;;; needs and feeds every season. The payoff for tending the stock is not a rule we
;;; wrote — it is the arithmetic of the recurrence.
;;;
;;; Pure solver ⇒ no blake3.
;;; Run: guile --no-auto-compile -L module tests/solve/test-regenerating-stock.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve plan)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand)
             (playnet vf formulas stocks))
;; solve/robust.scm arrives with the engine — (playnet solve engine) loads it into
;; itself and exports its names, so the load that stood here was a second copy
;; of the same text into this module (retired with the engine-as-module arc).
(define *pass* 0) (define *fail* 0)
(define (check name ok) (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
                            (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(define (check-done . banner)
  (format #t "~%════════════════════════════════════════════~%")
  (if (= *fail* 0) (begin (when (pair? banner) (apply format #t banner))
                          (format #t "  All ~a checks passed.~%" *pass*))
      (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)))
  (format #t "════════════════════════════════════════════~%")
  (when (> *fail* 0) (exit 1)))

(define SEASONS '(0 1 2 3))
(define FLOOR 30.0)

;; the field, and its fertility as a regenerating stock (the generic declaration).
(clear-regenerating-stocks!)
(register-regenerating-stock! (make-regenerating-stock "fertility" "Soil fertility" "field" 100.0 "idx"))
(define spatials (list (place* "field")))

;; manure on hand — the raw a compost run turns into fertility (ample, so the ONLY
;; thing scarce is the condition itself).
;; 90 kg manure ⇒ at 3 kg/unit, at most 30 fertility can be rebuilt — just enough,
;; with the 100 standing, to clear the 120 floor-sum. Regeneration is finite too.
(define manure (er "manure" "manure" #f #:place "field" #:qty 90.0 #:unit "kg" #:tags (list "stationary")))

;; grow: MINE 1 fertility → 1 meal.   compost: 3 manure → RESTORE 1 fertility.
(define grow-proc    (rp* "grow" "Grow food"))
(define compost-proc (rp* "compost" "Make compost"))
(define grow-flows
  (list (stock-draw-flow "g-fert" "fertility" 1.0 "grow" "cropping mines fertility" "idx")
        (out* "g-meal" "meal" 1.0 "grow" "meal")))
(define compost-flows
  (list (consume* "c-man" "manure" 3.0 "compost")
        (stock-restore-flow "c-fert" "fertility" 1.0 "compost" "compost rebuilds fertility" "idx")))

;; meal is NOT storable (each season must feed itself); fertility IS (it carries).
(define storables (regenerating-stock-storables))               ; ⇒ ("fertility")
(define floors (map (lambda (t) (cons (format #f "meal#field@~a" t) FLOOR)) SEASONS))

(define (run regenerate?)
  (let ((procs (if regenerate? (list grow-proc compost-proc) (list grow-proc)))
        (flows (if regenerate? (append grow-flows compost-flows) grow-flows))
        (resources (cons manure (regenerating-stock-resources))))
    (call-with-values
      (lambda () (plan-from-records resources '() spatials procs flows
                   ;; The mine-only arm is MEANT to have no answer: with a floor due every
                   ;; season, spending the stock down is not a plan, and that impossibility is
                   ;; the finding. Declared, so PLANNER_INVARIANTS can treat every undeclared
                   ;; infeasible solve in the suite as the bug it usually is.
                   #:allow-infeasible? #t
                   #:periods SEASONS #:storable storables #:repro-floors floors #:per-agent? #f))
      (lambda (ints coms material fill cols x idx ntot report)
        (define (vof k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))
        (define grown  (map (lambda (t) (vof (format #f "p|grow|field@~a" t))) SEASONS))
        (define composted (map (lambda (t) (vof (format #f "p|compost|field@~a" t))) SEASONS))
        ;; fertility level at the START of each season = 100 − Σ grown<t + Σ composted<t
        (define traj
          (let loop ((ts SEASONS) (lvl 100.0) (acc '()))
            (if (null? ts) (reverse acc)
                (let ((g (list-ref grown (car ts))) (c (list-ref composted (car ts))))
                  (loop (cdr ts) (+ lvl (- g) c) (cons lvl acc))))))
        (list grown composted traj (apply + grown))))))

(define mine (run #f))
(define tend (run #t))
(define mine-grown (car mine))   (define mine-traj (caddr mine))   (define mine-total (cadddr mine))
(define tend-grown (car tend))   (define tend-composted (cadr tend)) (define tend-total (cadddr tend))

(format #t "~%── a floor of ~,0f meals every season, 4 seasons (~,0f in all); 100 fertility in the ground ──~%"
        FLOOR (* FLOOR 4))
(format #t "  MINE ONLY:   grown/season = ~a~%" (map (lambda (g) (round g)) mine-grown))
(format #t "               fertility    = ~a  → mines out~%" (map (lambda (l) (round l)) mine-traj))
(format #t "               total meals  = ~,0f   (floor-sum ~,0f)  ~a~%" mine-total (* FLOOR 4)
        (if (< mine-total (* FLOOR 4)) "*** STARVES in the last season ***" "ok"))
(format #t "  TEND (compost available): grown = ~a  · composted = ~a~%"
        (map (lambda (g) (round g)) tend-grown) (map (lambda (c) (round c)) tend-composted))
(format #t "               total meals  = ~,0f   → every season's floor held~%" tend-total)

(format #t "~%── assertions ──~%")
(check "the stock CARRIES + BOUNDS: mine-only tops out near the 100 fertility standing"
       (< mine-total 116.0))   ; ≈100 + the interior-point barrier's give (same softness that flexes a floor)
(check "…so mining STARVES the last season (total meals < the 120 floor-sum)"
       (< mine-total (* 0.98 FLOOR 4)))
(check "fertility is drawn DOWN season to season (a falling trajectory)"
       (and (> (car mine-traj) (cadr mine-traj)) (> (cadr mine-traj) (caddr mine-traj))))
(check "fertility never goes NEGATIVE (you cannot spend a condition you have not got)"
       (>= (apply min mine-traj) -1e-6))
(check "REGENERATION relaxes the bound — tending feeds every season (≥ the floor-sum)"
       (>= tend-total (* 0.98 FLOOR 4)))
(check "…and the planner CHOOSES to rebuild the stock (compost > 0 — the payoff, not a rule)"
       (> (apply + tend-composted) 15.0))
(check "tending out-produces mining over deep time (more total meals)"
       (> tend-total (+ mine-total 10.0)))

(check-done "~%  Regenerating stock: mine vs. tend — the recurrence, and its payoff.~%")
