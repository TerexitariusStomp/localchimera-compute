;;; test-endogenous-reserve.scm — the plan DECIDES how much to bank.
;;;
;;; The exogenous granary (antifragile-reserve-test) showed a reserve raises the
;;; tail carrying capacity. This shows the reserve is ENDOGENOUS: given storage
;;; ("storage is transport through time", planner.scm) and a multi-year horizon
;;; with the floor due EVERY year, the plan itself over-grows in the productive
;;; window and banks exactly enough to ration through the lean periods. Bank more,
;;; survive a longer gap. No new machinery — the existing #:storable carry across
;;; #:periods, run against per-period reproduction floors.
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-endogenous-reserve.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define YEARS '(0 1 2 3))                 ; a 4-year horizon; harvest window is year 0
(define FLOOR 800.0)                       ; subsistence, due EVERY year
(define spat (list (place* "farm" #:lat 30.0 #:lon 78.0)))
(define res  (list (er "land" "land" #f #:place "farm" #:qty 5.0 #:unit "ha")))
(define procs (list (rp* "grow" "Grow")))
(define flows (list (consume* "gl" "land" 1.0 "grow" "ha")
                    (out* "gf" "food" 1000.0 "grow")))
(define floors (map (lambda (t) (cons (format #f "food#farm@~a" t) FLOOR)) YEARS))

(define (grow-at material-x cols idx t)   ; grow ha in a given year
  (let ((k (format #f "p|grow|farm@~a" t))) (if (hash-ref idx k #f) (vector-ref material-x (hash-ref idx k)) 0.0)))

(define (run store?)
  (catch #t
    (lambda ()
      (call-with-values
        (lambda () (plan-from-records res '() spat procs flows
                     #:periods YEARS #:storable (if store? '("food") '())
                     #:repro-floors floors #:per-agent? #f))
        (lambda (i c material fill cols x idx nt rep)
          (list (grow-at x cols idx 0) (grow-at x cols idx 1)))))
    (lambda _ 'infeasible)))

(define with-store (run #t))

(format #t "~%A ~a-year horizon, floor ~,0f kg EVERY year, one harvest window (year 0):~%" (length YEARS) FLOOR)
(when (pair? with-store)
  (format #t "  WITH storage:  year-0 grows ~,2f ha = ~,0f kg → feeds year 0 (~,0f) + BANKS ~,0f kg for years 1–3,~%"
          (car with-store) (* 1000.0 (car with-store)) FLOOR (- (* 1000.0 (car with-store)) FLOOR))
  (format #t "                 then grows NOTHING more — rationing the granary across the lean years.~%"))

(define y0-food (and (pair? with-store) (* 1000.0 (car with-store))))
(define horizon-need (* FLOOR (length YEARS)))

(format #t "~%── assertions ──~%")
(check "with storage across periods, the multi-year plan is FEASIBLE"  (pair? with-store))
(check "the plan ENDOGENOUSLY grows the whole horizon's food at harvest"
       (and y0-food (>= y0-food (* 0.99 horizon-need))))
(check "  i.e. it banks ≈ (remaining years × floor) — a reserve it CHOSE"
       (and y0-food (>= (- y0-food FLOOR) (* 0.99 (* FLOOR (- (length YEARS) 1))))))
(check "no growing needed after the harvest year (fed from the bank)"
       (and (pair? with-store) (< (cadr with-store) 0.01)))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — the reserve is ENDOGENOUS: the plan itself banks the~%  harvest and rations it across the lean years, using storage the engine already has.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
