;;; test-representation-parity.scm — one limit, two encodings, one answer.
;;;
;;; The engine already parity-locks its two BACKENDS against each other: they
;;; solve the same forms by different methods and must agree on delivered demand,
;;; and it errors loudly if they diverge. It did not lock its two REPRESENTATIONS
;;; of an ecological limit, and that is exactly where a defect hid.
;;;
;;; A limit is expressible twice:
;;;   as a WALL   a fragility whose headroom is tip − prior, a prior that only rises
;;;   as a LEVEL  a regenerating stock whose ≥0 balance the draw spends and labour
;;;               can rebuild
;;; Where both are valid — one period, nothing producing the level, prior zero, so
;;; the headroom and the level are the same number — they are two ways of writing
;;; one question, and they must give one answer.
;;;
;;; They did not. `playnet.typ` is explicit that the two barrier families "differ
;;; only in their weight": a hard constraint carries the SWEPT weight and is
;;; ridden to the edge, a fragility profile carries a FIXED governance weight and
;;; is felt at the optimum, "which is precisely what lets the federation ease off
;;; BEFORE the limit by its own arithmetic". A level's balance is an ordinary
;;; `bar`, so carrying a limit as a level and nothing else silently traded the
;;; fixed weight for the swept one and spent the boundary to its last unit.
;;; `*stock-frag-w*` carries the profile's weight onto the level's balance; this
;;; test is what keeps the two encodings answering alike.
;;;
;;; Appetite is a DESIRE, not a floor, so the plan CHOOSES how much boundary to
;;; spend. Under a floor both encodings would be forced to the same place and the
;;; difference would not show — which is why the regression survived a suite full
;;; of floors.
;;;
;;; Run: guile --no-auto-compile -L module/playnet/planner \
;;;        tests/planner/test-representation-parity.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner vf schemas)
             (playnet planner knowledge dsl shorthand))
(use-modules (playnet planner knowledge catalogues eco))
;; A period here is a WEEK: the roster's Monday 00:00–23:00 is twenty-three hours a period, on any date.
(set-period-length! 1.0 "week")

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define TIP 72.0) (define W 5.0)
(define ENTRY `("nitrogen" rate 62.0 82.0 0.5 ,W "src" "N" "grp" "unit"))  ; quantile_0.5 = 72

(define win (hours-of 23))
(define agents (list (person* "ada" #:name "Ada" #:place "p" #:window win)))
(define spatials (list (place* "p")))
(define skill (er "sk" "skill" "ada" #:place "p" #:unit "kg"))
(define procs (list (rp* "grow" "Grow")))
(define flows
  (list (out* "o" "food" 10.0 "grow")
        (consume* "n" "nitrogen" 1.0 "grow" "unit")
        (wk* "w" "skill" 0.1 "grow")))
;; a DESIRE, so the plan chooses how much of the boundary to spend
(define DEMAND '(("food#p@0" . 2000.0)))

(define* (drawn resources #:key (frag (quote ())) (sf (quote ())))
  (call-with-values
    (lambda () (plan-from-records resources agents spatials procs flows
                 #:demand DEMAND #:eco-frag frag #:stock-frag sf
                 #:periods '(0) #:per-agent? #f #:backend 'native-c))
    (lambda (ints coms material fill cols x idx ntot report)
      (fold (lambda (c a) (if (and (eq? (commitment-action c) 'consume)
                                   (equal? (commitment-resource-conforms-to c) "nitrogen"))
                              (+ a (measure-has-numerical-value (commitment-resource-quantity c))) a))
            0.0 material))))

(define m (migrate-limit ENTRY #:place "p" #:period-years 1.0))

(define as-wall  (drawn (list skill) #:frag `(("nitrogen#p@0" . (,TIP ,TIP 0.0 ,W)))))
(define as-level (drawn (cons skill (migrated->resources (list m)))
                        #:sf (migrated->stock-frag (list m))))
;; the same level with its weight dropped — what a plain stock would do
(define as-plain (drawn (cons skill (migrated->resources (list m)))))

(format #t "~%── one boundary, one appetite, two encodings ──~%~%")
(format #t "  ~34a ~10a ~a~%" "encoding" "drawn" "of tip")
(format #t "  ~34a ~10a ~a~%" "────────" "─────" "──────")
(format #t "  ~34a ~10,2f ~,1f%~%" "as a WALL (fragility, fixed w)"  as-wall  (* 100 (/ as-wall TIP)))
(format #t "  ~34a ~10,2f ~,1f%~%" "as a LEVEL (stock, weight kept)" as-level (* 100 (/ as-level TIP)))
(format #t "  ~34a ~10,2f ~,1f%~%" "as a LEVEL (weight dropped)"     as-plain (* 100 (/ as-plain TIP)))

(define (agree? a b) (< (abs (- a b)) (* 0.01 TIP)))

(format #t "~%")
(check "the wall holds a margin — it is felt at the optimum, not at the edge"
       (< as-wall (* 0.999 TIP)))
;; THE LOCK. Two encodings of one question, one answer.
(check "PARITY: the level answers the same as the wall, to within 1% of the tip"
       (agree? as-level as-wall))
;; …and the lock is not vacuous: dropping the weight visibly breaks it, which is
;; the regression this test exists to catch.
(check "dropping the weight spends the boundary to its edge instead"
       (> as-plain (* 0.999 TIP)))
(check "…so the parity above is carried by the weight, not by accident"
       (not (agree? as-plain as-wall)))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — a limit gives one answer however it is written.~%  The level keeps the profile's governance weight, so migrating a limit~%  changes what its baseline IS without changing how hard it is felt.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED — the two encodings disagree, so one of them is~%  not the limit anyone declared.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
