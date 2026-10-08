;;; test-event-interval.scm — one event, one time, whoever reads it.
;;;
;;; An event states when it happened as a beginning, an end, a point in time, or only
;;; when it was recorded (`created`). Every reader of the observer takes that time from
;;; ONE accessor, `event-interval`, on the one clock (utils/clock.scm): a pair of
;;; instants, a point standing for both ends. These properties hold:
;;;
;;;   STAMPS    a date, a date and minutes, a date and seconds all read; an event
;;;             that states no time has no interval
;;;   ORDER     the interval is the time it was worked, before the time it was
;;;             recorded: an event worked on the 21st and logged on the 2nd is of the 21st
;;;   READERS   the vest clock, the skill practice, the voice window and the
;;;             trip's two ends all read that one interval
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-event-interval.scm

(use-modules (playnet test harness)
             (playnet test events)
             (playnet planner observation observer) (playnet planner vf schemas)
             (playnet planner observation observer)
             ((playnet utils clock) #:select (civil->instant now days->seconds instant->civil))
             (goblins) (goblins vat)
             (srfi srfi-1))

(define* (at e #:key begin end point created)
  (copy-economic-event e #:has-beginning begin #:has-end end #:has-point-in-time point #:created created))
(define* (work #:key begin end point created)
  (at (ev "w" 'work #:spec "weld" #:effort (cons 2.0 "hour") #:provider "ana" #:input "P")
      #:begin begin #:end end #:point point #:created created))
(define (instant s) (civil->instant s))

(display "\n── STAMPS: every stamp the planner writes reads; no stamp, no interval ──\n")
(check "a point stands for both ends"
       (event-interval (work #:point "2026-10-02T09:00:00"))
       (cons (instant "2026-10-02T09:00:00") (instant "2026-10-02T09:00:00")))
(check "a date alone reads as the start of that day"
       (event-interval (work #:point "2026-10-02")) (cons (instant "2026-10-02") (instant "2026-10-02")))
(check "a date and minutes read"
       (event-interval (work #:point "2026-10-02T09:30")) (cons (instant "2026-10-02T09:30:00") (instant "2026-10-02T09:30:00")))
(check "a beginning and an end are the interval"
       (event-interval (work #:begin "2026-10-02T09:00:00" #:end "2026-10-02T11:00:00"))
       (cons (instant "2026-10-02T09:00:00") (instant "2026-10-02T11:00:00")))
(check "an end alone is a point at it"
       (event-interval (work #:end "2026-10-02T11:00:00")) (cons (instant "2026-10-02T11:00:00") (instant "2026-10-02T11:00:00")))
(check "a beginning alone is a point at it"
       (event-interval (work #:begin "2026-10-02T09:00:00")) (cons (instant "2026-10-02T09:00:00") (instant "2026-10-02T09:00:00")))
(check "the recording moment is the last resort"
       (event-interval (work #:created "2026-10-03T08:00:00")) (cons (instant "2026-10-03T08:00:00") (instant "2026-10-03T08:00:00")))
(check "an event that states no time has no interval" (event-interval (work)) #f)
(check "a stamp that states its offset is that moment in UTC"
       (event-interval (work #:begin "2026-10-02T11:00:00+02:00" #:end "2026-10-02T13:00:00+02:00"))
       (cons (instant "2026-10-02T09:00:00") (instant "2026-10-02T11:00:00")))
(check "…and a Z stamp is the same moment as the naive one"
       (event-interval (work #:point "2026-10-02T09:00:00Z")) (event-interval (work #:point "2026-10-02T09:00:00")))

(display "\n── ORDER: when it was worked comes before when it was recorded ──\n")
(let ((e (work #:begin "2026-09-21" #:created "2026-10-02T10:00:00")))
  (check "worked on the 21st, logged on the 2nd: the interval is the 21st"
         (event-interval e) (cons (instant "2026-09-21") (instant "2026-09-21")))
  (check "…and the vest clock reads the 21st"
         (event-instant e) (instant "2026-09-21"))
  (check "…and the voice window is the 21st"
         (assq-ref (event-terms e) 'window) '("2026-09-21" . "2026-09-21")))

(display "\n── READERS: the vest clock accepts a date, as the skill practice does ──\n")
(let* ((eight-days (instant->civil (- (now) (days->seconds 8)) "%Y-%m-%d"))
       (e (work #:point eight-days)))
  (check "a work event dated by day alone has a window that lapses"
         (window-lapsed? e) #t))

(define vat (spawn-vat))
(with-vat vat
  (let ((o (spawn ^observer (empty-observer-state) '())))
    ($ o 'record-event (work #:point "2026-10-02"))
    (check "a skill practised on a day alone is dated"
           (map (lambda (p) (and (car p) #t)) ($ o 'skill-practice "ana" "weld")) '(#t))))

(test-summary!)
