;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-one-off-window.scm — availability stated as calendar dates.
;;;
;;; A recurring window says "Tuesdays, 09:00–17:00". A one-off names the dates
;;; outright: "we have the hall on the 14th", "we get the oven on the 14th and
;;; keep it". `<specific-date-window>` has been in schemas.scm all along and the
;;; solve did not read it — it fell through to "not an availability-window", which
;;; meant AVAILABLE FOR THE WHOLE PERIOD. A means nobody had yet was free to use.
;;;
;;; Both notations describe one thing, a set of moments, so both answer the same
;;; question through `temporal-hours-within` and the callers do not branch.
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-one-off-window.scm

(use-modules ((localchimera utils units) #:select (%count-unit)))
(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (localchimera solve engine) (localchimera solve ingest) (localchimera solve world)
             (localchimera vf schemas) (localchimera vf beyond schedules)
             ((localchimera knowledge dsl shorthand) #:select (er all-week-window)))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(define (near? a b tol) (< (abs (- a b)) tol))

(define (res id window) (er id "oven" #f #:place "shop" #:unit %count-unit #:window window))

;; a five-day horizon, one date per period
(define DATES '("2026-03-12" "2026-03-13" "2026-03-14" "2026-03-15" "2026-03-16"))
(define P5 '(0 1 2 3 4))
(define (whole-days!)
  (declare-world! #:periods P5 #:spans (map (lambda (t d) (list t d d)) P5 DATES)))
(define (hours-of r) (map (lambda (t) (resource-window-hours r t)) P5))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. The dates a period covers
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 1. a period knows its dates, not only its weekdays ──~%~%")

(whole-days!)
(check "a whole-date period covers that one date"
       (equal? '("2026-03-14") (period-dates 2)))
(check "a period with no span covers none"
       (begin (reset-world!) (null? (period-dates 0))))

(whole-days!)
(set-period-span! 0 "2026-03-12T09:00" "2026-03-12T17:00")
(check "clock boundaries inside a day still cover that one date"
       (equal? '("2026-03-12") (period-dates 0)))

(whole-days!)
(set-period-span! 0 "2026-03-12" "2026-03-14")
(check "a span across three dates covers all three"
       (equal? '("2026-03-12" "2026-03-13" "2026-03-14") (period-dates 0)))

(whole-days!)
(set-period-span! 0 "2026-03-12T17:00" "2026-03-13T00:00")
(check "…and a midnight end closes the date rather than opening the next"
       (equal? '("2026-03-12") (period-dates 0)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Arrival — the case that named this thread
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 2. we get the oven on the 14th, and keep it ──~%~%")

(whole-days!)
(define arrives (res "A" (make-specific-date-window
                          (dates-through "2026-03-14" "2026-03-16") #f)))
(format #t "    ~a~%~%" (hours-of arrives))

(check "no capacity on any date before it arrives"
       (equal? '(0.0 0.0) (list (car (hours-of arrives)) (cadr (hours-of arrives)))))
(check "the whole day it arrives"        (near? (caddr (hours-of arrives)) 24.0 0.001))
(check "and every day after"             (equal? '(24.0 24.0) (cdddr (hours-of arrives))))

;; the control: an unwindowed twin is available throughout, so the zeroes above
;; are the window talking and not the fixture
(check "an unwindowed twin is available throughout"
       (equal? '(24.0 24.0 24.0 24.0 24.0) (hours-of (res "B" #f))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Enumeration — "the 14th and the 21st", not a run
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 3. a hall on two named days ──~%~%")

(whole-days!)
(define two-days (res "H" (make-specific-date-window '("2026-03-13" "2026-03-15") #f)))
(format #t "    ~a~%~%" (hours-of two-days))
(check "exactly the named dates, nothing between them"
       (equal? '(0.0 24.0 0.0 24.0 0.0) (hours-of two-days)))
(check "a date outside the horizon simply never lands"
       (equal? '(0.0 0.0 0.0 0.0 0.0)
               (hours-of (res "X" (make-specific-date-window '("2026-09-01") #f)))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. A one-off with clock ranges
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 4. the hall, on the 14th, 09:00–17:00 ──~%~%")

(whole-days!)
(define timed (res "T" (make-specific-date-window '("2026-03-14")
                                                  (list (make-time-range "09:00" "17:00")))))
(check "eight hours on the named date, zero elsewhere"
       (equal? '(0.0 0.0 8.0 0.0 0.0) (hours-of timed)))

;; and when the period itself carries clock boundaries, the two ranges meet
(whole-days!)
(set-period-span! 2 "2026-03-14T12:00" "2026-03-14T24:00")
(check "against a 12:00–24:00 period it is the overlap, five hours"
       (near? (resource-window-hours timed 2) 5.0 0.001))

;; a night range still measures correctly through the shared clock
(whole-days!)
(check "a 22:00–02:00 one-off is four hours, not minus twenty"
       (near? (resource-window-hours
               (res "N" (make-specific-date-window '("2026-03-14")
                                                   (list (make-time-range "22:00" "02:00"))))
               2)
              4.0 0.001))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Fail-closed, and degeneracy
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 5. what happens when the dates cannot be placed ──~%~%")

(declare-world! #:places '("shop"))
(check "a one-off against a period with no dates draws nothing"
       (= 0.0 (resource-window-hours
               (res "U" (make-specific-date-window '("2026-03-14") #f)) 0)))
(check "…while an unwindowed resource is unaffected — this is not a blanket zero"
       (near? (resource-window-hours (res "V" #f) 0) 24.0 0.001))

;; the recurring path must be byte-identical to before
(whole-days!)
(define recurring
  (res "R" (all-week-window "09:00" "17:00")))
(check "a recurring window still reads exactly as it did"
       (equal? '(8.0 8.0 8.0 8.0 8.0) (hours-of recurring)))

(format #t "~%~a passed, ~a failed~%~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
