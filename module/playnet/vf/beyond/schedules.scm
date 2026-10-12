;;; vf/beyond/schedules.scm — recurring availability: the temporal expressions.
;;;
;;; ValueFlows states when with `hasBeginning`, `hasEnd`, `hasPointInTime` and
;;; `due`, each one instant, and defines no recurrence. A person's week, a
;;; means' opening hours and a dated absence are patterns over time, so they are
;;; stated here: a time range, the day, week and month schedules that compose
;;; ranges, the availability window they add up to, and the window of specific
;;; dates. An agent and a resource hold one as a field value.
;;;
;;; This is the ONE recurrence extension, settled 2026-10-12 (beyond-valueflows.md
;;; §6.6): the pattern is the fact a person states; the intervals it covers over
;;; a horizon are a reading of it that depends on today and on the horizon
;;; asked, derived where they are needed (the engine's standing partition at
;;; ingest, plan/recurrence.scm's occurrences, matching/temporal-index's
;;; overlap) and never stored. The dated shape appears where the pattern is
;;; realized: a shift accepted is a commitment with hasBeginning and hasEnd,
;;; which is core ValueFlows already.

(define-module (playnet vf beyond schedules)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils records) #:select (define-vf-record vf-record-type vf-record-constructor vf-record-predicate vf-record-accessor vf-record-modifier vf-record-type-name vf-record-type-fields vf-record-copier))
  #:use-module ((playnet vf serdes) #:select (register-vf-records! register-vf-record!))
  #:export (make-time-range
            *days-of-week*
            day-of-week?
            make-day-schedule
            make-week-schedule
            make-month-schedule
            make-availability-window
            make-specific-date-window
            temporal-expression?
            ;; the record declarations below define these (define-vf-record; check-record-exports holds the list)
            <time-range> time-range? time-range-start-time time-range-end-time <day-schedule> day-schedule?
            day-schedule-days day-schedule-time-ranges <week-schedule> week-schedule? week-schedule-weeks week-schedule-day-schedules
            <month-schedule> month-schedule? month-schedule-month month-schedule-week-schedules month-schedule-day-schedules month-schedule-time-ranges
            <availability-window> availability-window? availability-window-month-schedules availability-window-week-schedules availability-window-day-schedules availability-window-time-ranges
            <specific-date-window> specific-date-window? specific-date-window-specific-dates specific-date-window-time-ranges))

;; ═══════════════════════════════════════════════════════════════════════
;; TEMPORAL (from utils/time.ts)
;; ═══════════════════════════════════════════════════════════════════════

;;; TimeRange — a time span within a day.
;;; Fields: start-time (string "HH:MM"), end-time (string "HH:MM").

;; a type is its name — the same object on both sides of the load seam

(define-vf-record <time-range> TimeRange
  (start-time end-time)
  #:register register-vf-record!)

(define make-time-range       (vf-record-constructor <time-range>))


;;; DaySchedule — associates specific days of the week with time ranges.
;;; Fields: days (list of day-of-week symbols), time-ranges (list of <time-range>).
(define *days-of-week*
  '(monday tuesday wednesday thursday friday saturday sunday))

(define (day-of-week? x)
  (and (symbol? x) (memq x *days-of-week*) #t))

(define-vf-record <day-schedule> DaySchedule
  (days time-ranges)
  #:register register-vf-record!)

(define make-day-schedule           (vf-record-constructor <day-schedule>))


;;; WeekSchedule — associates specific weeks of a month with day/time patterns.
;;; Fields: weeks (list of integers 1-5), day-schedules (list of <day-schedule>).
(define-vf-record <week-schedule> WeekSchedule
  (weeks day-schedules)
  #:register register-vf-record!)

(define make-week-schedule              (vf-record-constructor <week-schedule>))


;;; MonthSchedule — associates a specific month with week/day/time patterns.
;;; Fields: month (integer 1-12),
;;;         week-schedules (optional: list of <week-schedule> | #f),
;;;         day-schedules  (optional: list of <day-schedule>  | #f),
;;;         time-ranges    (optional: list of <time-range>    | #f).
(define-vf-record <month-schedule> MonthSchedule
  (month week-schedules day-schedules time-ranges)
  #:register register-vf-record!)

(define make-month-schedule              (vf-record-constructor <month-schedule>))


;;; AvailabilityWindow — hierarchical recurring availability definition.
;;; Priority: month-schedules > week-schedules > day-schedules > time-ranges.
;;; All fields optional (but at least one must be non-#f at runtime).
(define-vf-record <availability-window> AvailabilityWindow
  (month-schedules week-schedules day-schedules time-ranges)
  #:register register-vf-record!)

(define make-availability-window              (vf-record-constructor <availability-window>))


;;; SpecificDateWindow — one-time or ad-hoc multi-date temporal expression.
;;; Fields: specific-dates (list of "YYYY-MM-DD" strings),
;;;         time-ranges (optional: list of <time-range> | #f).
(define-vf-record <specific-date-window> SpecificDateWindow
  (specific-dates time-ranges)
  #:register register-vf-record!)

(define make-specific-date-window              (vf-record-constructor <specific-date-window>))


;;; TemporalExpression — union of SpecificDateWindow | AvailabilityWindow.
;;; Discriminate at runtime via specific-date-window? / availability-window?.
(define (temporal-expression? x)
  (or (specific-date-window? x)
      (availability-window? x)))

;; ── persistence: these records register their own types ─────────────────────
;; each type registers itself as it is declared (define-vf-record #:register)
