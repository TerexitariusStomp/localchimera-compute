;;; test-control.scm — Tests for relational control systems
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-control.scm

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))

(define pass-count 0)
(define fail-count 0)

(define (check label got expected)
  (if (equal? got expected)
      (begin (set! pass-count (+ pass-count 1))
             (display (string-append "  PASS  " label "\n")))
      (begin (set! fail-count (+ fail-count 1))
             (display (string-append "  FAIL  " label "\n"))
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write got)      (newline))))

(define (check-pred label pred)
  (if pred
      (begin (set! pass-count (+ pass-count 1))
             (display (string-append "  PASS  " label "\n")))
      (begin (set! fail-count (+ fail-count 1))
             (display (string-append "  FAIL  " label "\n")))))

(define ns '())


;;; ── Test facts ──────────────────────────────────────────────────────────────

(define control-facts
  '(;; Proportional temperature controller
    (control-loop "loop-temp" "sensor-temp" "actuator-heater" proportional)
    (setpoint "sensor-temp" 200 "celsius")
    (gain "loop-temp" 3)

    ;; Bang-bang level controller
    (control-loop "loop-pump" "sensor-level" "actuator-pump" bang-bang)
    (setpoint "sensor-level" 100 "liters")

    ;; Deadband HVAC controller
    (control-loop "loop-hvac" "sensor-room" "actuator-hvac" deadband)
    (setpoint "sensor-room" 22 "celsius")
    (deadband "loop-hvac" 2)

    ;; Observations for trace/stability tests
    (observation "sensor-temp" 1000 180)
    (observation "sensor-temp" 2000 190)
    (observation "sensor-temp" 3000 198)
    (observation "sensor-temp" 4000 201)

    ;; Two proportional loops for composition test
    (control-loop "loop-inner" "sensor-inner" "actuator-mid" proportional)
    (setpoint "sensor-inner" 50 "units")
    (gain "loop-inner" 2)
    (control-loop "loop-outer" "sensor-outer" "actuator-final" proportional)
    (gain "loop-outer" 3)

    ;; Signal tag facts (normally loaded from signals.scm)
    (signal-tag replenishment "tag:plan:replenishment")
    (signal-tag surplus       "tag:plan:surplus")
    (signal-tag conservation  "tag:plan:conservation")))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Proportional control
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Proportional control ──\n")

;; Forward: PV=180, SP=200, error=20, gain=3 → action=60
(check "proportional forward"
  (run-plan* ns (q) (control-action-o control-facts "loop-temp" 180 q))
  '(60))

;; Inverse: action=30, gain=3, error=10, SP=200 → PV=190
(check "proportional inverse: action→pv"
  (run-plan* ns (q) (control-action-o control-facts "loop-temp" q 30))
  '(190))

;; At setpoint: PV=200, error=0 → action=0
(check "proportional at setpoint"
  (run-plan* ns (q) (control-action-o control-facts "loop-temp" 200 q))
  '(0))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Bang-bang control
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Bang-bang control ──\n")

;; Below setpoint: PV=80, SP=100, error=20>0 → action=1
(check "bang-bang: below setpoint"
  (run-plan* ns (q) (control-action-o control-facts "loop-pump" 80 q))
  '(1))

;; Above setpoint: PV=120, SP=100, error=-20<=0 → action=0
(check "bang-bang: above setpoint"
  (run-plan* ns (q) (control-action-o control-facts "loop-pump" 120 q))
  '(0))

;; At setpoint: PV=100, error=0<=0 → action=0
(check "bang-bang: at setpoint"
  (run-plan* ns (q) (control-action-o control-facts "loop-pump" 100 q))
  '(0))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Deadband control
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Deadband control ──\n")

;; Below band: PV=18, SP=22, error=4, hw=2, 4>2 → action=1
(check "deadband: below band"
  (run-plan* ns (q) (control-action-o control-facts "loop-hvac" 18 q))
  '(1))

;; Within band: PV=21, SP=22, error=1, |1|<=2 → action=0
(check "deadband: within band"
  (run-plan* ns (q) (control-action-o control-facts "loop-hvac" 21 q))
  '(0))

;; Above band: PV=25, SP=22, error=-3, -3<-2 → action=-1
(check "deadband: above band"
  (run-plan* ns (q) (control-action-o control-facts "loop-hvac" 25 q))
  '(-1))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Error relation (bidirectionality)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Error relation ──\n")

;; Forward: SP=200, PV=180 → error=20
(check "error forward"
  (run-plan* ns (q) (error-o 200 180 q))
  '(20))

;; Inverse: SP=200, error=20 → PV=180
(check "error inverse: error→pv"
  (run-plan* ns (q) (error-o 200 q 20))
  '(180))

;; Inverse: PV=180, error=20 → SP=200
(check "error inverse: error→sp"
  (run-plan* ns (q) (error-o q 180 20))
  '(200))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Gain identification
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Gain identification ──\n")

;; Given PV=180, action=60, SP=200 → gain=3
(check "identify gain from observation"
  (run-plan* ns (q) (identify-gain-o control-facts "loop-temp" 180 60 q))
  '(3))

;; Verify: gain=3, PV=180 → action=60
(check "identify gain: verify forward"
  (run-plan* ns (q) (identify-gain-o control-facts "loop-temp" 180 q 3))
  '(60))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Loop trace
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Loop trace ──\n")

(let ((obs '((observation "sensor-temp" 1000 180)
             (observation "sensor-temp" 2000 190)
             (observation "sensor-temp" 3000 198)
             (observation "sensor-temp" 4000 201))))
  (let ((result (run-plan 1 ns (q)
                  (loop-trace-o control-facts "loop-temp" obs q))))
    (check-pred "loop trace produces 4 entries"
      (and (pair? result) (= 4 (length (car result)))))
    ;; First entry: PV=180, error=20, action=60
    (check "loop trace first entry"
      (car (car result))
      '(1000 180 20 60))
    ;; Last entry: PV=201, error=-1, action=-3
    (check "loop trace last entry"
      (last (car result))
      '(4000 201 -1 -3))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Stability classification
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Stability ──\n")

;; Converging: differences shrink monotonically
(check "stability: converging"
  (run-plan* ns (q)
    (stability-o '((observation "s" 1 200)
                   (observation "s" 2 195)
                   (observation "s" 3 192)
                   (observation "s" 4 190))
                 q))
  '(converging))

;; Oscillating: frequent sign changes
(check "stability: oscillating"
  (run-plan* ns (q)
    (stability-o '((observation "s" 1 100)
                   (observation "s" 2 80)
                   (observation "s" 3 120)
                   (observation "s" 4 70)
                   (observation "s" 5 130))
                 q))
  '(oscillating))

;; Insufficient data
(check "stability: insufficient"
  (run-plan* ns (q)
    (stability-o '((observation "s" 1 100)
                   (observation "s" 2 110))
                 q))
  '(insufficient))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Composition
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Composition ──\n")

;; Inner loop: PV=40, SP=50, error=10, gain=2 → inner-action=20
;; Outer loop: inner-action=20 as error, gain=3 → final-action=60
(check "cascade two proportional loops"
  (run-plan* ns (q)
    (compose-o control-facts "loop-outer" "loop-inner" 40 q))
  '(60))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 9. Signal bridge
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Signal bridge ──\n")

;; PV=180, action=60>0 → replenishment signal
(let ((result (run-plan 1 ns (q)
                (control-signal-o control-facts "loop-temp" 180 q))))
  (check-pred "signal bridge: produces signal"
    (pair? result))
  (check "signal bridge: kind is replenishment"
    (assq-ref (car result) 'kind)
    'replenishment)
  (check "signal bridge: qty is |error|=20"
    (assq-ref (car result) 'qty)
    20))


;;; ════════════════════════════════════════════════════════════════════════════
;;; Summary
;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display "════════════════════════════════════════\n")
(display (string-append "  " (number->string pass-count) " passed, "
                        (number->string fail-count) " failed\n"))
(display "════════════════════════════════════════\n")
(if (> fail-count 0) (exit 1))
