;;; test-trajectory.scm — position as a consistent TRAJECTORY, not a flat table.
;;;
;;; agent-position-predicate resolves where each agent is, per period, by priority:
;;;   1. live/manual override   (pos| meta — GPS 'now' or a declared future place)
;;;   2. committed work location (their accepted work IS where they'll be — the
;;;      "expected" position falls out of the plan, closing the plan↔position loop)
;;;   3. home                    (#f ⇒ the planner uses primary-location)
;;;
;;; Run:  guile -L module tests/doors/test-trajectory.scm

(use-modules (playnet test harness)
             (playnet vf schemas)              ; make-commitment
             (playnet doors service)      ; agent-position-predicate
             (playnet scope live)         ; set-period-span! (period ↔ wall-clock)
             ((playnet utils clock) #:select (now))
             ((playnet vf facts person-facts) #:select (fix-lease-seconds))
             (goblins) (goblins vat)
             (srfi srfi-1))

(define (^mock bcom table)
  (lambda (msg . args) (let ((p (assq msg table))) (if p (apply (cdr p) args) (error "mock: no method" msg)))))

;; a `work` commitment for PROVIDER at PLACE, optionally WHEN (hasBeginning, ISO).
(define (wc id provider place . when)
  (make-commitment #:id id #:action 'work #:provider provider
                   #:has-beginning (and (pair? when) (car when))   ; has-beginning
 #:at-location place))

(define vat (spawn-vat #:name "traj"))
(define (predicate-over meta commitments)
  (with-vat vat
    (let* ((ps    (spawn ^mock `((all-meta . ,(lambda () meta))
                                 (all-commitments . ,(lambda () commitments)))))
           (scope (spawn ^mock `((plan-store . ,(lambda () ps))))))
      (agent-position-predicate scope))))

(display "\n── position trajectory: live/manual override > committed > home ──\n")

;; (1) committed work at market, no override → derived expected = market
(let ((p (predicate-over '() (list (wc "c1" "ada" "market")))))
  (check "committed work → derived 'expected' position"  (p "ada" 0) "market")
  (check "a different agent with no info → home (#f)"     (p "bob" 0) #f)
  (check "a later period with no info → home (#f)"        (p "ada" 1) #f))

;; (2) live override (GPS says you're home now) WINS over the committed location
;; a fix for now is a lease: it carries the instant it was sent and counts while fresh
(define (fix-at sent) (list (cons "pos|ada|0" `((place . "home") (agent . "ada") (period . 0) (at . ,sent)))))
(let ((p (predicate-over (fix-at (now)) (list (wc "c1" "ada" "market")))))
  (check "a fresh live fix beats committed"               (p "ada" 0) "home"))
(let ((p (predicate-over (fix-at (- (now) fix-lease-seconds 60)) (list (wc "c1" "ada" "market")))))
  (check "a fix past its lease no longer pins anyone: committed shows through" (p "ada" 0) "market"))

;; (3) manual EXPECTED at a future period; other periods unaffected
(let ((p (predicate-over
           (list (cons "pos|ada|2" '((place . "depot") (agent . "ada") (period . 2))))
           '())))
  (check "manual expected pins a future period"           (p "ada" 2) "depot")
  (check "and only that period (others → home)"           (p "ada" 0) #f))

;; (4) nothing pins anyone → #f predicate (planner uses everyone's home)
(check "no positions at all → #f predicate (all home)"    (predicate-over '() '()) #f)

;; (5) MULTI-PERIOD: with period spans set, a commitment's hasBeginning (the
;; schema's record of WHEN) maps to its period via time->period — the worker is
;; positioned at their committed place IN that period, not collapsed to 0.
(set-period-span! 0 "2026-06-01" "2026-06-01")
(set-period-span! 1 "2026-06-02" "2026-06-02")
(set-period-span! 2 "2026-06-03" "2026-06-03")
(let ((p (predicate-over '() (list (wc "c2" "ada" "market" "2026-06-03")))))  ; hasBeginning in period 2
  (check "committed at period 2 (by hasBeginning) → positioned there" (p "ada" 2) "market")
  (check "and NOT at period 0 or 1"  (and (p "ada" 0) (p "ada" 1)) #f))

(test-summary!)
