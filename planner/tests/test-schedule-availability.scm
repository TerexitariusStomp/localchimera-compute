;;; test-schedule-availability.scm — Schedule book and availability queries
;;;
;;; Ported from: old/planner/src/lib/tests/schedule-book.test.ts
;;;              old/planner/src/lib/tests/availability.test.ts
;;;
;;; Intent: Verify schedule-blocks-for entity matching, committed-effort-on
;;; date summation, and date-matches-window availability checking in
;;; combination with the plan store.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-schedule-availability.scm

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))


;;; ── Harness ────────────────────────────────────────────────────────────────

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


;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "ScheduleAvail Test"))
    store))

(with-vat vat
  (check-pred "scope ready" (not (not scope))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Empty schedule — schedule-blocks-for returns '()
;;;
;;; Ported from: "returns empty array when planStore is empty"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Empty schedule ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    (check "empty schedule for alice"
           (schedule-blocks-for "alice" ps) '())))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Provider match — work intent with provider "alice"
;;;
;;; Ported from: "includes intent where provider matches"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Provider match ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ;; make-intent: 28 fields
    ;; id action name note image input-of output-of resource-inventoried-as
    ;; resource-conforms-to resource-classified-as resource-quantity
    ;; effort-quantity available-quantity minimum-quantity provider receiver
    ;; has-beginning has-end has-point-in-time due at-location stage state
    ;; planned-within satisfies in-scope-of finished availability-window
    ($ ps 'add-intent
       (make-intent "i-work-alice" 'work "Alice work" #f #f
                    #f #f #f #f #f
                    #f #f #f #f
                    "alice" #f
                    #f #f #f #f
                    #f #f #f #f #f #f #f #f))
    (let ((blocks (schedule-blocks-for "alice" ps)))
      (check-pred "provider match: 1 block" (= 1 (length blocks)))
      (check "provider match: type = intent"
             (assq-ref (car blocks) 'type) 'intent)
      (check "provider match: action = work"
             (assq-ref (car blocks) 'action) 'work))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Receiver match — intent with receiver "bob"
;;;
;;; Ported from: "includes intent where receiver matches"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Receiver match ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ($ ps 'add-intent
       (make-intent "i-deliver-bob" 'deliverService "Deliver to Bob" #f #f
                    #f #f #f #f #f
                    #f #f #f #f
                    #f "bob"
                    #f #f #f #f
                    #f #f #f #f #f #f #f #f))
    (let ((blocks (schedule-blocks-for "bob" ps)))
      (check-pred "receiver match: has blocks" (>= (length blocks) 1))
      (check-pred "receiver match: includes deliver intent"
                  (any (lambda (b) (equal? (assq-ref b 'id) "i-deliver-bob"))
                       blocks)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Resource match — use intent with resource-inventoried-as "res:tool1"
;;;
;;; Ported from: "includes intent where resourceInventoriedAs matches"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Resource match ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ($ ps 'add-intent
       (make-intent "i-use-tool" 'use "Use tool" #f #f
                    #f #f "res:tool1" #f #f
                    #f #f #f #f
                    "alice" #f
                    #f #f #f #f
                    #f #f #f #f #f #f #f #f))
    (let ((blocks (schedule-blocks-for "res:tool1" ps)))
      (check-pred "resource match: has blocks" (>= (length blocks) 1))
      (check-pred "resource match: includes use intent"
                  (any (lambda (b) (equal? (assq-ref b 'id) "i-use-tool"))
                       blocks)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Committed effort on date — single work commitment
;;;
;;; Ported from: "sums effortQuantity of work commitments that overlap the date"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Committed effort on date ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ;; make-commitment: 27 fields
    ;; id action note input-of output-of resource-inventoried-as
    ;; resource-conforms-to resource-classified-as resource-quantity
    ;; effort-quantity provider receiver has-beginning has-end
    ;; has-point-in-time due created at-location in-scope-of stage state
    ;; satisfies clause-of independent-demand-of planned-within finished
    ;; availability-window
    ($ ps 'add-commitment
       (make-commitment "c-work-alice-1" 'work #f #f #f
                        #f #f #f #f
                        (make-measure 6 "hours")
                        "alice" "org:acme"
                        #f #f #f "2026-02-23T10:00:00Z"
                        #f #f #f #f #f #f #f #f #f #f #f))
    (check "effort on 2026-02-23 = 6"
           (committed-effort-on "alice" "2026-02-23" ps) 6)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Multiple commitments summed — 3h + 2h on same day
;;;
;;; Ported from: "sums multiple overlapping work commitments"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Multiple commitments summed ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ($ ps 'add-commitment
       (make-commitment "c-work-alice-2" 'work #f #f #f
                        #f #f #f #f
                        (make-measure 3 "hours")
                        "alice" "org:acme"
                        #f #f #f "2026-02-23T09:00:00Z"
                        #f #f #f #f #f #f #f #f #f #f #f))
    ($ ps 'add-commitment
       (make-commitment "c-work-alice-3" 'work #f #f #f
                        #f #f #f #f
                        (make-measure 2 "hours")
                        "alice" "org:beta"
                        #f #f #f "2026-02-23T14:00:00Z"
                        #f #f #f #f #f #f #f #f #f #f #f))
    ;; Total = 6 (from test 5) + 3 + 2 = 11
    ;; All three work commitments on 2026-02-23 for alice
    (check "summed effort on 2026-02-23 = 11"
           (committed-effort-on "alice" "2026-02-23" ps) 11)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Ignores non-work — consume commitment with effort not counted
;;;
;;; Ported from: "ignores commitments with different action"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Ignores non-work ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ($ ps 'add-commitment
       (make-commitment "c-consume-carol" 'consume #f #f #f
                        #f #f #f #f
                        (make-measure 4 "hours")
                        "carol" "org:acme"
                        #f #f #f "2026-02-23T09:00:00Z"
                        #f #f #f #f #f #f #f #f #f #f #f))
    ;; Carol has only a consume commitment, not work → effort = 0
    (check "non-work effort = 0"
           (committed-effort-on "carol" "2026-02-23" ps) 0)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Availability window via date-matches-window
;;;
;;; Ported from: availability.test.ts "AvailabilityWindow day_schedules"
;;;
;;; Mon-Fri 9-5 window:
;;;   - Monday 2026-02-23 matches (weekday)
;;;   - Saturday 2026-02-28 does not match (weekend)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Availability window ──\n")

(let ((mon-fri-window
        (make-availability-window
          #f #f
          (list (make-day-schedule
                  '(monday tuesday wednesday thursday friday)
                  #f))
          #f)))

  ;; 2026-02-23 = Monday → matches
  (check-pred "Monday matches Mon-Fri"
    (date-matches-window "2026-02-23" mon-fri-window))

  ;; 2026-02-24 = Tuesday → matches
  (check-pred "Tuesday matches Mon-Fri"
    (date-matches-window "2026-02-24" mon-fri-window))

  ;; 2026-02-28 = Saturday → does not match
  (check-pred "Saturday does not match Mon-Fri"
    (not (date-matches-window "2026-02-28" mon-fri-window)))

  ;; 2026-03-01 = Sunday → does not match
  (check-pred "Sunday does not match Mon-Fri"
    (not (date-matches-window "2026-03-01" mon-fri-window))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(when (> fail-count 0) (exit 1))
