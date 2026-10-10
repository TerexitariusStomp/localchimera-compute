;;; test-horizon.scm — a real MULTI-PERIOD plan over a wall-clock horizon.
;;;
;;; This is the end-to-end proof that the period↔wall-clock bridge is live: give
;;; the planner a horizon (start date + N daily periods) and it (a) lays out the
;;; period spans, (b) lands each agent's availability on the right weekday, and
;;; (c) emits commitments whose hasBeginning is the real date of their period —
;;; which is exactly what the position trajectory reads back.
;;;
;;; Bread wanted at town on day 0 (4) and day 2 (4); Ada bakes (8h/day available,
;;; Mon–Sun). Horizon = 2026-06-01 + 3 days ⇒ periods 0/1/2 = Jun 1/2/3.
;;;
;;; Run:  guile -L module/playnet/planner module/playnet/planner/horizon-test.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))

;; ── records ──────────────────────────────────────────────────────────────────
(define win (all-week-window "09:00" "17:00"))   ; 8h any day
(define agents (list (person* "ada" #:name "Ada" #:window win)))
(define spatials (list (place* "town")))
(define resources (list (er "sk-ada" "skill-bake" "ada" #:qty 1.0 #:unit "kg")))  ; Ada's skill ER
;; bake: 1 bake-hour → 1 bread (labour-only, so no raw-input modelling clouds the
;; horizon question — isolating WHEN work happens across the wall-clock days).
(define procs (list (rp* "bake" "Bake")))
(define flows (list (out* "f1" "bread" 1.0 "bake")
                    (wk* "f3" "skill-bake" 1.0 "bake")))
(define demand (list (cons "bread#town@0" 4.0) (cons "bread#town@2" 4.0)))   ; day 0 and day 2

;; ── the multi-period plan ─────────────────────────────────────────────────────
(set! *emp-rho* 0.0001)
(define-values (intents coms material fill cols x idx ntot report)
  (plan-from-records resources agents spatials procs flows
    #:demand demand #:horizon (cons "2026-06-01" 3) #:backend 'native-c))

;; group Ada's work commitments by the period their hasBeginning maps to
(define (work-coms-by-period)
  (let ((h (make-hash-table)))
    (for-each (lambda (c)
                (when (eq? (commitment-action c) 'work)
                  (let ((p (time->period (commitment-has-beginning c))))
                    (hash-set! h p (cons c (hash-ref h p '()))))))
              coms)
    h))
(define byp (work-coms-by-period))
(define (hours-at p) (fold (lambda (c a) (+ a (measure-has-numerical-value (commitment-effort-quantity c)))) 0.0 (hash-ref byp p '())))
(define (when-at p) (and (pair? (hash-ref byp p '())) (commitment-has-beginning (car (hash-ref byp p '())))))
;; A DAY is a stretch of periods, not a period index. Ada declares working hours,
;; so the partition is derived from them and each day is several periods — ask by
;; wall clock and the question survives however finely the day is cut.
(define (periods-on date) (filter (lambda (t) (member date (period-dates t))) *periods*))
(define (hours-on date) (fold + 0.0 (map hours-at (periods-on date))))
(define (when-on date) (any when-at (periods-on date)))
(define DAY0 "2026-06-01") (define DAY2 "2026-06-03")

(format #t "~%── horizon 2026-06-01 +3 days · bread 4@day0 + 4@day2 · Ada bakes ──~%")
(format #t "  periods planned: ~s   demand met: ~,1f%~%" *periods* (* 100 fill))
(format #t "  work @period 0: ~,1f h  (hasBeginning ~s)~%" (hours-on DAY0) (when-on DAY0))
(format #t "  work @period 1: ~,1f h~%" (hours-at 1))
(format #t "  work @period 2: ~,1f h  (hasBeginning ~s)~%" (hours-on DAY2) (when-on DAY2))

(let* ((c1 (equal? '(3 3 3) (map (lambda (d) (length (periods-on d)))
                                 (list DAY0 "2026-06-02" DAY2))))   ; three days, each a stretch
       (c2 (> fill 0.95))                                         ; demand met across days
       (c3 (and (> (hours-on DAY0) 3.0) (> (hours-on DAY2) 3.0)))  ; work happens on BOTH demanded days
       (c5 (string-prefix? DAY0 (or (when-on DAY0) "")))                     ; period 0's commitment dated day 0
       (c6 (string-prefix? DAY2 (or (when-on DAY2) "")))                     ; period 2's commitment dated day 2
       (ok (and c1 c2 c3 c5 c6)))
  (format #t "~%  [~a] horizon laid out daily periods                    (~s)~%" (if c1 "✓" "✗") *periods*)
  (format #t "  [~a] demand met across the horizon                     (~,1f%)~%" (if c2 "✓" "✗") (* 100 fill))
  (format #t "  [~a] work lands on BOTH demanded days, not collapsed    (~,1fh @0, ~,1fh @2)~%" (if c3 "✓" "✗") (hours-on DAY0) (hours-on DAY2))
  (format #t "  [~a] period-0 commitment carries real hasBeginning      (~s)~%" (if c5 "✓" "✗") (when-on DAY0))
  (format #t "  [~a] period-2 commitment carries real hasBeginning      (~s)~%" (if c6 "✓" "✗") (when-on DAY2))
  (format #t "   (·  EMP also spread ~,1fh onto the idle day — load-balancing, a feature, not the horizon)~%" (hours-at 1))
  (format #t "~%  ~a multi-period planning is live: WHEN flows from the horizon into the commitments~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
