;;; test-window-union.scm — a person's day is offered once, in the roster and in the solve.
;;;
;;; Ranges that overlap are one stretch of the day. The roster (matching/
;;; availability.scm) has read it so since a body has one day; the solve's own
;;; reading of the same window (engine `window-hours`, `agent-window-hours`)
;;; takes the same union, in a whole week, inside a timed period, and on the
;;; dates a dated week names — so the two cannot drift on how many hours a
;;; person who states 09-13 and 11-15 offers.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/planner/test-window-union.scm

(use-modules (playnet test harness)
             (playnet planner vf schemas) (playnet planner beyond schedules)
             ((playnet planner solve engine) #:select (window-hours agent-window-hours set-period-span!))
             ((playnet planner facts availability)
              #:select (window-weekly-hours window-hours-on-dates make-dated-week))
             (srfi srfi-1))

(define (ranges rs) (map (lambda (r) (make-time-range (car r) (cdr r))) rs))
(define overlap '(("09:00" . "13:00") ("11:00" . "15:00")))

(display "\n── a week: one schedule naming two overlapping ranges ──\n")
(let ((w (make-availability-window #f #f (list (make-day-schedule '(monday) (ranges overlap))) #f)))
  (check "the solve reads six hours on a Monday" (window-hours w '(monday)) 6.0)
  (check "and the roster reads the same" (window-weekly-hours w) 6))

(display "\n── a week: two schedules naming the same day ──\n")
(let ((w (make-availability-window
          #f #f (list (make-day-schedule '(monday) (ranges (list (car overlap))))
                      (make-day-schedule '(monday) (ranges (list (cadr overlap))))) #f)))
  (check "the solve reads six hours" (window-hours w '(monday)) 6.0)
  (check "and the roster reads the same" (window-weekly-hours w) 6))

(display "\n── a week with a day stated outright ──\n")
(let* ((week (make-availability-window #f #f (list (make-day-schedule '(monday) (ranges '(("09:00" . "17:00"))))) #f))
       (w (make-dated-week week (list (make-specific-date-window '("2026-10-12") (ranges overlap))))))
  (check "the roster reads the stated day's union"
         (window-hours-on-dates w '("2026-10-12")) 6))

(display "\n── a timed period inside a stretch the ranges cover twice ──\n")
(let* ((w (make-availability-window #f #f (list (make-day-schedule '(monday) (ranges overlap))) #f))
       (a (make-agent #:id "ada" #:type 'person #:name "ada" #:classified-as '()
                      #:availability-window w)))
  (set-period-span! 0 "2026-10-05T10:00" "2026-10-05T12:00")
  (check "ten to twelve is two hours, not four" (agent-window-hours a 0) 2.0))

(test-summary!)
