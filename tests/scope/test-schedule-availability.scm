;;; SPDX-License-Identifier: AGPL-3.0-or-later
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

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet plan schedule-book) (playnet scope root) (playnet plan recurrence) (playnet vf schemas) (playnet vf beyond schedules) (srfi srfi-1))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))
;;; ── Harness ────────────────────────────────────────────────────────────────

;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "ScheduleAvail Test"))
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
       (make-intent #:id "i-work-alice" #:action 'work #:name "Alice work"
                    #:provider "alice"))
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
       (make-intent #:id "i-deliver-bob" #:action 'deliverService #:name "Deliver to Bob"
                    #:receiver "bob"))
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
       (make-intent #:id "i-use-tool" #:action 'use #:name "Use tool" #:resource-inventoried-as "res:tool1"
                    #:provider "alice"))
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
       (make-commitment #:id "c-work-alice-1" #:action 'work
                        #:effort-quantity (make-measure 6 %effort-unit)
                        #:provider "alice" #:receiver "org:acme" #:due "2026-02-23T10:00:00Z"))
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
       (make-commitment #:id "c-work-alice-2" #:action 'work
                        #:effort-quantity (make-measure 3 %effort-unit)
                        #:provider "alice" #:receiver "org:acme" #:due "2026-02-23T09:00:00Z"))
    ($ ps 'add-commitment
       (make-commitment #:id "c-work-alice-3" #:action 'work
                        #:effort-quantity (make-measure 2 %effort-unit)
                        #:provider "alice" #:receiver "org:beta" #:due "2026-02-23T14:00:00Z"))
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
       (make-commitment #:id "c-consume-carol" #:action 'consume
                        #:effort-quantity (make-measure 4 %effort-unit)
                        #:provider "carol" #:receiver "org:acme" #:due "2026-02-23T09:00:00Z"))
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
(test-summary!)
