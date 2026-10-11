;;; test-scale-invariance.scm — the same problem, in different units, is the same plan.
;;;
;;; A physical question does not change when you restate it in grams instead of
;;; kilograms. If the plan does, the difference is the solver's, not the world's —
;;; and it is a defect no behavioural test can see, because each run looks
;;; perfectly reasonable on its own.
;;;
;;; The property: multiply every MATERIAL quantity by k — stocks, recipe inputs
;;; and outputs, demands, caps — and leave labour alone (restating masses does not
;;; change how many hours a day has). Then every process's ACTIVITY, the number of
;;; runs, must be identical. Runs are counts; only the units the counts are
;;; expressed in moved.
;;;
;;; This is the property that made the engine's old acceptance gate visible in a
;;; single measurement. It compared a constraint's slack against an ABSOLUTE −1.0,
;;; so one unit of violation was noise beside a kcal-scale floor (~2383) and an
;;; enormous quantity beside a kg-scale stock (0.001) — the same Doon farm grew
;;; 18.2 kg of grain stated in kilograms and 0.28 kg stated in grams. The gate now
;;; reads `plan-grossly-infeasible?`, which measures a violation against the
;;; constraint's own magnitude, and this test is what keeps it that way.
;;;
;;; Scarcity is deliberate: soil binds well before labour or demand, so the
;;; tolerance is what stands between the plan and drawing stock that is not there.
;;; The 0.001 scale is the one that matters most — that is the direction in which
;;; an absolute threshold silently becomes enormous.
;;;
;;; Run: guile --no-auto-compile -L module/playnet/planner \
;;;        tests/solve/test-scale-invariance.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve plan)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define win (hours-of 23))
(define agents (list (person* "ada" #:name "Ada" #:place "p" #:window win)))
(define spatials (list (place* "p")))

;; SOIL is scarce: 5 units at unit scale, and one run spends one. Labour and the
;; appetite for food are both far larger, so soil is what binds — and the slack on
;; soil's balance is exactly where a scale-blind tolerance does its damage.
(define* (plan-at-scale k #:key (may-fail? #f))
  (let* ((soil  (er "soil" "soil" #f #:place "p" #:qty (* 5.0 k) #:unit "u"))
         (skill (er "sk" "skill" "ada" #:place "p" #:unit "kg"))
         (procs (list (rp* "grow" "Grow")))
         (flows (list (out* "o" "food" (* 10.0 k) "grow" "u")
                      (consume* "s" "soil" (* 1.0 k) "grow" "u")
                      ;; labour is NOT scaled: restating masses does not change the day
                      (wk* "w" "skill" 0.1 "grow"))))
    (call-with-values
      (lambda () (plan-from-records (list soil skill) agents spatials procs flows
                   #:demand (list (cons "food#p@0" (* 60.0 k)))    ; wants 6 runs where soil allows 5
                   #:periods '(0) #:per-agent? #f #:backend 'native-c
                   #:allow-infeasible? may-fail?))
      (lambda (ints coms material fill cols x idx ntot report)
        (let ((i (hash-ref idx "p|grow|p@0" #f))
              (cert (assq-ref report 'certificate)))
          (list (if i (vector-ref x i) 0.0) (assq-ref cert 'feasible?)))))))

(define scales '(0.001 1.0))                       ; the pair the table prints
(define results (map (lambda (k) (cons k (plan-at-scale k))) scales))
(define big (cons 1000.0 (plan-at-scale 1000.0)))

(format #t "~%── one farm, three unit systems ──~%")
(format #t "  soil is scarce (5 units at 1×, one spent per run); the plan wants 50 runs' worth of food~%~%")
(format #t "  ~10a ~12a ~a~%" "scale" "grow runs" "feasible")
(format #t "  ~10a ~12a ~a~%" "─────" "─────────" "────────")
(for-each (lambda (r) (format #t "  ~10a ~12,4f ~a~%" (car r) (first (cdr r)) (second (cdr r)))) results)

(define runs (map (lambda (r) (first (cdr r))) results))
(define base (second runs))                                   ; the 1× reading
(define (agrees? v) (< (abs (- v base)) (* 0.01 (max 1e-9 base))))

(format #t "~%")
(check "every scale produces a real plan"
       (every (lambda (r) (eq? #t (second (cdr r)))) results))
(check "soil actually binds — the plan is held below what it wants"
       (< base 40.0))
;; the direction that matters for a tolerance: an ABSOLUTE one is enormous down
;; here, so a scale-blind gate would let this run draw soil that does not exist
(check "0.001× agrees with 1× to within 1% — three orders of magnitude apart"
       (agrees? (first runs)))
(check "so the plan is a fact about the farm, not about the units it is stated in"
       (every agrees? runs))

(check "1000× agrees with 1× too — six orders of magnitude across the sweep"
       (agrees? (first (cdr big))))
(check "…and that solve is a real plan, not a seed the solver could not walk back from"
       (eq? #t (second (cdr big))))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — the same farm plans the same way in grams,~%  units and kilotons. A tolerance that forgets scale cannot hide here.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED — the plan changed with the unit, which is the~%  solver's doing and not the world's.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
