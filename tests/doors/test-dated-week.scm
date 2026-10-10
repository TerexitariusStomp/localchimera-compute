;;; test-dated-week.scm — the offer a citizen makes: a week with dated exceptions.
;;;
;;; The availability ring is recurring, painted per weekday; a one-time
;;; committed event blocks one date. The wire carries both — recurring arcs
;;; and dated arcs — and every reader answers a date the exceptions name with
;;; their ranges instead: a stated day beats the week. Proved on the three
;;; readers that exist: the roster's week and on-dates reads
;;; (matching/availability), the solver's period intersection (engine
;;; temporal-hours-within on the standing partition), and the arcs wire both
;;; ways (service arcs-json->window / window->arcs, and the availability-day table).
;;;
;;; Run: guile --no-auto-compile -q -L module tests/doors/test-dated-week.scm
(use-modules (playnet test harness)
             (playnet vf schemas) (playnet vf beyond schedules)
             (playnet vf facts availability)
             ((playnet solve engine) #:select (declare-world! agent-window-hours))
             (playnet doors service)
             (playnet knowledge dsl shorthand)
             (srfi srfi-1))
;; the engine's period reader and the service's wire are internal doors
(define temporal-hours-within (@@ (playnet solve engine) temporal-hours-within))
(define arcs-json->window (@@ (playnet doors service) arcs-json->window))
(define window->arcs (@@ (playnet doors service) window->arcs))
(use-modules (playnet wire rows))
;; a window's rows as the page reads them (record-rows.scm), read back as plain alists
(define (availability-window->alist aw)
  (wire->plain (map (lambda (r) (wire-row* (wire-table-ref 'availability-day) r))
                    ((@@ (playnet doors record-rows) availability-rows) aw))))

;; 2026-09-07 is a Monday; the exception falls on Tuesday the 8th
(define week (weekday-window "09:00" "17:00"))
(define busy-tuesday (make-specific-date-window '("2026-09-08")
                                                (list (make-time-range "09:00" "14:00")
                                                      (make-time-range "16:00" "17:00"))))
(define gone-friday (make-specific-date-window '("2026-09-11") '()))
(define offer (make-dated-week week (list busy-tuesday gone-friday)))

(display "\n── the roster's reads ──\n")
(check "the week is the week: an exception moves hours on a date, never the week"
       (window-weekly-hours offer) 40)
(check "the stated Tuesday offers its own ranges (5 + 1)"
       (window-hours-on-dates offer '("2026-09-08")) 6)
(check "the withdrawn Friday offers nothing"
       (window-hours-on-dates offer '("2026-09-11")) 0)
(check "an ordinary Wednesday is the week's"
       (window-hours-on-dates offer '("2026-09-09")) 8)
(check "the week read on its dates: 40 − 2 − 8"
       (window-hours-on-dates offer (iso-dates-through "2026-09-07" "2026-09-13")) 30)

(display "\n── the solver's read ──\n")
(declare-world! #:places '("town") #:horizon (cons "2026-09-07" 7))
(check "day 1, the Tuesday: 6 h inside the period"
       (temporal-hours-within offer 1) 6.0)
(check "day 4, the Friday: withdrawn"
       (temporal-hours-within offer 4) 0.0)
(check "day 2, a Wednesday: the week's 8"
       (temporal-hours-within offer 2) 8.0)
(let ((ann (person* "ann" #:name "Ann" #:window offer)))
  (check "agent-window-hours reads the dated week on the Tuesday"
         (agent-window-hours ann 1) 6.0))
(declare-world! #:places '("town") #:clock (list "2026-09-08" 3 8.0))   ; three 8-hour bands of the Tuesday
(check "the 08:00–16:00 band of the stated Tuesday: 09:00–14:00 of it (5 h)"
       (temporal-hours-within offer 1) 5.0)
(check "the 16:00–24:00 band: 16:00–17:00 of it (1 h)"
       (temporal-hours-within offer 2) 1.0)

(display "\n── the wire, both ways ──\n")
(define json "[{\"start\":\"09:00\",\"end\":\"17:00\",\"days\":[\"monday\",\"tuesday\",\"wednesday\",\"thursday\",\"friday\"]},{\"start\":\"09:00\",\"end\":\"14:00\",\"dates\":[\"2026-09-08\"]},{\"start\":\"16:00\",\"end\":\"17:00\",\"dates\":[\"2026-09-08\"]},{\"start\":\"00:00\",\"end\":\"00:00\",\"dates\":[\"2026-09-11\"]}]")
(define parsed (arcs-json->window json))
(check-pred "dated arcs parse to a dated week" (dated-week? parsed))
(check "…whose week is the recurring arcs" (window-weekly-hours parsed) 40)
(check "…and whose Tuesday is stated" (window-hours-on-dates parsed '("2026-09-08")) 6)
(check "…and whose Friday is withdrawn" (window-hours-on-dates parsed '("2026-09-11")) 0)
(let ((arcs (window->arcs parsed)))
  (check "window->arcs carries the week's arc and the three dated ones"
         (length arcs) 4)
  (check "a withdrawn day flattens to a zero-length dated arc"
         (assq-ref (last arcs) 'dates) '("2026-09-11")))
(let ((rows (availability-window->alist parsed)))
  (check "the snapshot rows: the week's, then one per exception"
         (map (lambda (r) (if (assq 'dates r) 'dated 'week)) rows) '(week dated dated)))
(check "a wire with no dated arcs is the plain window, as before"
       (dated-week? (arcs-json->window "[{\"start\":\"09:00\",\"end\":\"17:00\",\"days\":[\"monday\"]}]")) #f)

(test-summary!)
