;;; beyond/schedules.scm — recurring availability: the temporal expressions.
;;;
;;; ValueFlows states when with `hasBeginning`, `hasEnd`, `hasPointInTime` and
;;; `due`, each one instant, and defines no recurrence. A person's week, a
;;; means' opening hours and a dated absence are patterns over time, so they are
;;; stated here: a time range, the day, week and month schedules that compose
;;; ranges, the availability window they add up to, and the window of specific
;;; dates. An agent and a resource hold one as a field value.
;;;
;;; Route into the core (docs/planning/codebase-organization.md §7): one dated
;;; Intent per concrete interval over the horizon, against keeping the pattern as
;;; the one recurrence extension (valueflows-native-inventory.md Part D step 9).

(define-module (playnet planner beyond schedules)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils records) #:select (vf-record-type vf-record-constructor vf-record-predicate vf-record-accessor vf-record-modifier vf-record-type-name vf-record-type-fields vf-record-copier))
  #:use-module ((playnet planner vf serdes) #:select (register-vf-records!))
  #:export (<time-range> make-time-range time-range? time-range-start-time
            time-range-end-time *days-of-week* day-of-week? <day-schedule>
            make-day-schedule day-schedule? day-schedule-days day-schedule-time-ranges
            <week-schedule> make-week-schedule week-schedule? week-schedule-weeks
            week-schedule-day-schedules <month-schedule> make-month-schedule
            month-schedule? month-schedule-month month-schedule-week-schedules
            month-schedule-day-schedules month-schedule-time-ranges <availability-window>
            make-availability-window availability-window?
            availability-window-month-schedules availability-window-week-schedules
            availability-window-day-schedules availability-window-time-ranges
            <specific-date-window> make-specific-date-window specific-date-window?
            specific-date-window-specific-dates specific-date-window-time-ranges
            temporal-expression?))

;; ═══════════════════════════════════════════════════════════════════════
;; TEMPORAL (from utils/time.ts)
;; ═══════════════════════════════════════════════════════════════════════

;;; TimeRange — a time span within a day.
;;; Fields: start-time (string "HH:MM"), end-time (string "HH:MM").

;; a type is its name — the same object on both sides of the load seam

(define <time-range>
  (vf-record-type 'TimeRange
    '((immutable start-time)
      (immutable end-time))))

(define make-time-range       (vf-record-constructor <time-range>))
(define time-range?           (vf-record-predicate   <time-range>))
(define time-range-start-time (vf-record-accessor    <time-range> 'start-time))
(define time-range-end-time   (vf-record-accessor    <time-range> 'end-time))


;;; DaySchedule — associates specific days of the week with time ranges.
;;; Fields: days (list of day-of-week symbols), time-ranges (list of <time-range>).
(define *days-of-week*
  '(monday tuesday wednesday thursday friday saturday sunday))

(define (day-of-week? x)
  (and (symbol? x) (memq x *days-of-week*) #t))

(define <day-schedule>
  (vf-record-type 'DaySchedule
    '((immutable days)
      (immutable time-ranges))))

(define make-day-schedule           (vf-record-constructor <day-schedule>))
(define day-schedule?               (vf-record-predicate   <day-schedule>))
(define day-schedule-days           (vf-record-accessor    <day-schedule> 'days))
(define day-schedule-time-ranges    (vf-record-accessor    <day-schedule> 'time-ranges))


;;; WeekSchedule — associates specific weeks of a month with day/time patterns.
;;; Fields: weeks (list of integers 1-5), day-schedules (list of <day-schedule>).
(define <week-schedule>
  (vf-record-type 'WeekSchedule
    '((immutable weeks)
      (immutable day-schedules))))

(define make-week-schedule              (vf-record-constructor <week-schedule>))
(define week-schedule?                  (vf-record-predicate   <week-schedule>))
(define week-schedule-weeks             (vf-record-accessor    <week-schedule> 'weeks))
(define week-schedule-day-schedules     (vf-record-accessor    <week-schedule> 'day-schedules))


;;; MonthSchedule — associates a specific month with week/day/time patterns.
;;; Fields: month (integer 1-12),
;;;         week-schedules (optional: list of <week-schedule> | #f),
;;;         day-schedules  (optional: list of <day-schedule>  | #f),
;;;         time-ranges    (optional: list of <time-range>    | #f).
(define <month-schedule>
  (vf-record-type 'MonthSchedule
    '((immutable month)
      (immutable week-schedules)
      (immutable day-schedules)
      (immutable time-ranges))))

(define make-month-schedule              (vf-record-constructor <month-schedule>))
(define month-schedule?                  (vf-record-predicate   <month-schedule>))
(define month-schedule-month             (vf-record-accessor    <month-schedule> 'month))
(define month-schedule-week-schedules    (vf-record-accessor    <month-schedule> 'week-schedules))
(define month-schedule-day-schedules     (vf-record-accessor    <month-schedule> 'day-schedules))
(define month-schedule-time-ranges       (vf-record-accessor    <month-schedule> 'time-ranges))


;;; AvailabilityWindow — hierarchical recurring availability definition.
;;; Priority: month-schedules > week-schedules > day-schedules > time-ranges.
;;; All fields optional (but at least one must be non-#f at runtime).
(define <availability-window>
  (vf-record-type 'AvailabilityWindow
    '((immutable month-schedules)
      (immutable week-schedules)
      (immutable day-schedules)
      (immutable time-ranges))))

(define make-availability-window              (vf-record-constructor <availability-window>))
(define availability-window?                  (vf-record-predicate   <availability-window>))
(define availability-window-month-schedules   (vf-record-accessor    <availability-window> 'month-schedules))
(define availability-window-week-schedules    (vf-record-accessor    <availability-window> 'week-schedules))
(define availability-window-day-schedules     (vf-record-accessor    <availability-window> 'day-schedules))
(define availability-window-time-ranges       (vf-record-accessor    <availability-window> 'time-ranges))


;;; SpecificDateWindow — one-time or ad-hoc multi-date temporal expression.
;;; Fields: specific-dates (list of "YYYY-MM-DD" strings),
;;;         time-ranges (optional: list of <time-range> | #f).
(define <specific-date-window>
  (vf-record-type 'SpecificDateWindow
    '((immutable specific-dates)
      (immutable time-ranges))))

(define make-specific-date-window              (vf-record-constructor <specific-date-window>))
(define specific-date-window?                  (vf-record-predicate   <specific-date-window>))
(define specific-date-window-specific-dates    (vf-record-accessor    <specific-date-window> 'specific-dates))
(define specific-date-window-time-ranges       (vf-record-accessor    <specific-date-window> 'time-ranges))


;;; TemporalExpression — union of SpecificDateWindow | AvailabilityWindow.
;;; Discriminate at runtime via specific-date-window? / availability-window?.
(define (temporal-expression? x)
  (or (specific-date-window? x)
      (availability-window? x)))

;; ── persistence: these records register their own types ─────────────────────
(register-vf-records!
  <time-range>
  <day-schedule>
  <week-schedule>
  <month-schedule>
  <availability-window>
  <specific-date-window>)
