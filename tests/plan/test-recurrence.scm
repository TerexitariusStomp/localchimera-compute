;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-recurrence.scm — Recurring schedule matching and occurrence tracking
;;;
;;; Ported from: old/planner/src/lib/tests/recurrence.test.ts
;;;
;;; Intent: Verify date-matches-window for day/week/month patterns,
;;; materialize-occurrence-dates enumeration, and occurrence fulfillment
;;; status tracking.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-recurrence.scm

(use-modules (playnet test harness))
(use-modules (playnet plan recurrence) (playnet vf schemas) (playnet vf beyond schedules))
(use-modules (srfi srfi-1))
;;; ── Harness ───────────────────────────────────────────────────────────────────

;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Day schedules — Monday window
;;;
;;; Ported from: "Monday matches Monday schedule"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Day schedules ──\n")

(let ((monday-window (make-availability-window
                       #f #f
                       (list (make-day-schedule '(monday) #f))
                       #f)))
  ;; 2026-03-02 = Monday
  (check-pred "Mon 2026-03-02 matches"
    (date-matches-window "2026-03-02" monday-window))
  ;; 2026-03-09 = Monday
  (check-pred "Mon 2026-03-09 matches"
    (date-matches-window "2026-03-09" monday-window))
  ;; 2026-03-03 = Tuesday
  (check-pred "Tue 2026-03-03 does not match"
    (not (date-matches-window "2026-03-03" monday-window)))
  ;; 2026-03-07 = Saturday
  (check-pred "Sat 2026-03-07 does not match"
    (not (date-matches-window "2026-03-07" monday-window)))
  ;; 2026-03-08 = Sunday
  (check-pred "Sun 2026-03-08 does not match"
    (not (date-matches-window "2026-03-08" monday-window))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Multi-day pattern — Mon/Wed/Fri
;;;
;;; Ported from: "Multi-day pattern"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Multi-day pattern ──\n")

(let ((mwf-window (make-availability-window
                    #f #f
                    (list (make-day-schedule '(monday wednesday friday) #f))
                    #f)))
  (check-pred "Mon matches MWF"
    (date-matches-window "2026-03-02" mwf-window))
  (check-pred "Wed matches MWF"
    (date-matches-window "2026-03-04" mwf-window))
  (check-pred "Fri matches MWF"
    (date-matches-window "2026-03-06" mwf-window))
  (check-pred "Tue does not match MWF"
    (not (date-matches-window "2026-03-03" mwf-window)))
  (check-pred "Sat does not match MWF"
    (not (date-matches-window "2026-03-07" mwf-window))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Week schedules — weeks 1 and 3 only
;;;
;;; Ported from: "Week schedules"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Week schedules ──\n")

(let ((w13-window (make-availability-window
                    #f
                    (list (make-week-schedule
                            '(1 3)
                            (list (make-day-schedule
                                    '(monday tuesday wednesday thursday friday saturday sunday)
                                    #f))))
                    #f #f)))
  ;; Day 1-7 = week 1
  (check-pred "day 3 (week 1) matches"
    (date-matches-window "2026-03-03" w13-window))
  ;; Day 15-21 = week 3
  (check-pred "day 17 (week 3) matches"
    (date-matches-window "2026-03-17" w13-window))
  ;; Day 8-14 = week 2
  (check-pred "day 10 (week 2) does not match"
    (not (date-matches-window "2026-03-10" w13-window)))
  ;; Day 22-28 = week 4
  (check-pred "day 24 (week 4) does not match"
    (not (date-matches-window "2026-03-24" w13-window))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Week + day combined — week 1, Mondays only
;;;
;;; Ported from: "Week + day schedules"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Week + day ──\n")

(let ((w1-mon (make-availability-window
                #f
                (list (make-week-schedule
                        '(1)
                        (list (make-day-schedule '(monday) #f))))
                #f #f)))
  ;; 2026-03-02 = Monday, day 2 = week 1
  (check-pred "week 1 Monday matches"
    (date-matches-window "2026-03-02" w1-mon))
  ;; 2026-03-09 = Monday, day 9 = week 2
  (check-pred "week 2 Monday does not match"
    (not (date-matches-window "2026-03-09" w1-mon)))
  ;; 2026-03-01 = Sunday, day 1 = week 1
  (check-pred "week 1 Sunday does not match"
    (not (date-matches-window "2026-03-01" w1-mon))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Month schedules — March only
;;;
;;; Ported from: "Month schedules"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Month schedules ──\n")

(let ((march-only (make-availability-window
                    (list (make-month-schedule 3 #f #f
                            (list (make-time-range "00:00" "23:59"))))
                    #f #f #f)))
  (check-pred "March 15 matches"
    (date-matches-window "2026-03-15" march-only))
  (check-pred "Feb 15 does not match"
    (not (date-matches-window "2026-02-15" march-only)))
  (check-pred "Apr 15 does not match"
    (not (date-matches-window "2026-04-15" march-only))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Month + week + day — March, week 1, Mondays only
;;;
;;; Ported from: "Month + week + day"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Month + week + day ──\n")

(let ((m3w1mon (make-availability-window
                 (list (make-month-schedule 3
                         (list (make-week-schedule
                                 '(1)
                                 (list (make-day-schedule '(monday) #f))))
                         #f #f))
                 #f #f #f)))
  ;; 2026-03-02 = Monday, week 1 of March
  (check-pred "March week 1 Monday matches"
    (date-matches-window "2026-03-02" m3w1mon))
  ;; 2026-03-09 = Monday, week 2 of March
  (check-pred "March week 2 Monday does not match"
    (not (date-matches-window "2026-03-09" m3w1mon)))
  ;; 2026-03-01 = Sunday, week 1 of March
  (check-pred "March week 1 Sunday does not match"
    (not (date-matches-window "2026-03-01" m3w1mon))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Materialize occurrence dates
;;;
;;; Ported from: "materializeOccurrenceDates 2 Mondays"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Materialize dates ──\n")

(let ((monday-window (make-availability-window
                       #f #f
                       (list (make-day-schedule '(monday) #f))
                       #f)))
  (let ((dates (materialize-occurrence-dates monday-window "2026-03-02" "2026-03-15")))
    (check "two Mondays materialized" (length dates) 2)
    (check-pred "includes 03-02"
      (member "2026-03-02" dates))
    (check-pred "includes 03-09"
      (member "2026-03-09" dates)))

  ;; Start/end inclusive
  (let ((dates (materialize-occurrence-dates monday-window "2026-03-02" "2026-03-02")))
    (check "single day inclusive" (length dates) 1)
    (check "is 03-02" (car dates) "2026-03-02"))

  ;; Empty result (no Saturdays in Mon window)
  (let ((sat-window (make-availability-window
                      #f #f
                      (list (make-day-schedule '(saturday) #f))
                      #f)))
    (let ((dates (materialize-occurrence-dates sat-window "2026-03-02" "2026-03-06")))
      (check "no Saturdays in Mon-Fri range" (length dates) 0))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Unfulfilled occurrences
;;;
;;; Ported from: "unfulfilledOccurrences returns second Monday"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Unfulfilled occurrences ──\n")

(let* ((monday-window (make-availability-window
                        #f #f
                        (list (make-day-schedule '(monday) #f))
                        #f))
       ;; Events on first Monday only
       (events-map '(("2026-03-02" . (dummy-event)))))
  (let ((gaps (unfulfilled-occurrences monday-window "2026-03-02" "2026-03-15"
                                        events-map)))
    (check-pred "gap on 03-09"
      (member "2026-03-09" gaps))
    (check-pred "no gap on 03-02"
      (not (member "2026-03-02" gaps)))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 9-11. Occurrence status (fulfilled / partial / summed)
;;;
;;; Ported from: "getOccurrenceStatus fully fulfilled", "Partial", "Multiple"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Occurrence status ──\n")

;; We need real commitment and event records for get-occurrence-status.
;; Build minimal stubs with the required accessors.

(let* ((c100 (make-commitment
               #:id "c-100" #:action 'produce #:resource-conforms-to "spec-bread"
               #:resource-quantity (make-measure 100 "kg")
               #:provider "agent-a" #:receiver "agent-a"))

       ;; Fully fulfilled: one event with qty=100
       (ev-full (make-economic-event
                  #:id "ev-full" #:action 'produce #:resource-conforms-to "spec-bread"
                  #:provider "agent-a" #:receiver "agent-a"
                  #:resource-quantity (make-measure 100 "kg") #:has-point-in-time "2026-03-02T10:00:00Z"))
       (full-groups (group-events-by-occurrence (list ev-full)))
       (full-status (get-occurrence-status c100 full-groups)))
  (check-pred "full: one date"
    (= 1 (length full-status)))
  (let ((entry (cdar full-status)))
    (check "full: fulfilled=100" (assq-ref entry 'fulfilled) 100)
    (check "full: committed=100" (assq-ref entry 'committed) 100)
    (check "full: complete=#t"   (assq-ref entry 'complete)  #t)))

;; Partial fulfillment: qty=40 of 100
(let* ((c100 (make-commitment
               #:id "c-100" #:action 'produce #:resource-conforms-to "spec-bread"
               #:resource-quantity (make-measure 100 "kg")
               #:provider "agent-a" #:receiver "agent-a"))
       (ev-partial (make-economic-event
                     #:id "ev-part" #:action 'produce #:resource-conforms-to "spec-bread"
                     #:provider "agent-a" #:receiver "agent-a"
                     #:resource-quantity (make-measure 40 "kg") #:has-point-in-time "2026-03-02T10:00:00Z"))
       (groups (group-events-by-occurrence (list ev-partial)))
       (status (get-occurrence-status c100 groups)))
  (let ((entry (cdar status)))
    (check "partial: fulfilled=40" (assq-ref entry 'fulfilled) 40)
    (check "partial: complete=#f"  (assq-ref entry 'complete)  #f)))

;; Multiple events summed: 60 + 40 = 100
(let* ((c100 (make-commitment
               #:id "c-100" #:action 'produce #:resource-conforms-to "spec-bread"
               #:resource-quantity (make-measure 100 "kg")
               #:provider "agent-a" #:receiver "agent-a"))
       (ev-a (make-economic-event
               #:id "ev-a" #:action 'produce #:resource-conforms-to "spec-bread"
               #:provider "agent-a" #:receiver "agent-a"
               #:resource-quantity (make-measure 60 "kg") #:has-point-in-time "2026-03-02T08:00:00Z"))
       (ev-b (make-economic-event
               #:id "ev-b" #:action 'produce #:resource-conforms-to "spec-bread"
               #:provider "agent-a" #:receiver "agent-a"
               #:resource-quantity (make-measure 40 "kg") #:has-point-in-time "2026-03-02T14:00:00Z"))
       (groups (group-events-by-occurrence (list ev-a ev-b)))
       (status (get-occurrence-status c100 groups)))
  (let ((entry (cdar status)))
    (check "summed: fulfilled=100" (assq-ref entry 'fulfilled) 100)
    (check "summed: complete=#t"   (assq-ref entry 'complete)  #t)))
;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
