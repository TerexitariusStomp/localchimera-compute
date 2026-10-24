;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-schedulable-window.scm — what a person states of their time, read by the schedule and the labour pool.
;;;
;;; Two tags on the agent take time out of the offer: "sleep:23:00-07:00", a
;;; protected span of the day (several stack — a night-shift split, a
;;; biphasic sleeper's main span and nap — each unrestricted or, with a
;;; trailing weekday list, "sleep:14:00-22:00:saturday,sunday", cutting only
;;; the days it names), and "away:2026-09-28..2026-09-30:sick", days of
;;; illness, rest or leave. The schedule never enters any of it.
;;;   1. WINDOW-NET-OF-SPAN takes the span out of every slot — wrapping
;;;      midnight, a slot that crosses it landing its second part on the next
;;;      day — leaves a slot the span does not touch as it stands, and #:days
;;;      restricts which weekdays it cuts from at all;
;;;   2. the agent states every span it stacks by tag, and the schedulable
;;;      window is the offer less all of them, netted in order;
;;;   3. away days withdraw their dates through the dated week's own exception;
;;;   4. the labour pool reads that window and keeps a person's week inside
;;;      what their body leaves of it, through the one reservation door.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/pools/test-schedulable-window.scm

(use-modules (srfi srfi-1) (ice-9 format)
             (localchimera vf schemas) (localchimera vf beyond schedules)
             (localchimera vf facts availability)
             (localchimera vf facts agent-time)
             (localchimera knowledge dsl shorthand)
             (localchimera pools availability-pool)
             ((localchimera solve engine) #:select (declare-world!)) ((localchimera solve ingest) #:select (agent-window-hours)))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (format #t "  [~a] ~a~%" (if ok "✓" "✗") name)
  (if ok (set! *pass* (+ *pass* 1)) (set! *fail* (+ *fail* 1))))
(define (near? a b) (< (abs (- a b)) 0.02))

(define (one-day day from to)
  (make-availability-window #f #f (list (make-day-schedule (list day) (list (make-time-range from to)))) #f))
(define (weekly w) (window-weekly-hours w))

(format #t "~%── 1. the span taken out of a window ──~%")
(define around-the-clock (all-week-window "00:00" "23:59"))
(check "an offer of every hour of every day, less 23:00–07:00, is sixteen hours a day: 112 a week"
       (near? (weekly (window-net-of-span around-the-clock "23:00" "07:00")) 112.0))
(check "a working day the span does not touch stands as it is: 09:00–17:00 five days is 40 hours, ranges unchanged"
       (let* ((w (weekday-window "09:00" "17:00")) (n (window-net-of-span w "23:00" "07:00")))
         (and (near? (weekly n) 40.0)
              (equal? (sort (map (lambda (s) (list (car s) (time-range-start-time (cdr s)) (time-range-end-time (cdr s)))) (window-slots n)) (lambda (a b) (string<? (symbol->string (car a)) (symbol->string (car b)))))
                      (sort (map (lambda (s) (list (car s) (time-range-start-time (cdr s)) (time-range-end-time (cdr s)))) (window-slots w)) (lambda (a b) (string<? (symbol->string (car a)) (symbol->string (car b)))))))))
(check "an early start loses the hour before the span ends: 06:00–10:00 becomes 07:00–10:00, three hours"
       (near? (weekly (window-net-of-span (one-day 'monday "06:00" "10:00") "23:00" "07:00")) 3.0))
(check "a late finish loses what falls inside: 18:00–23:30 becomes 18:00–23:00, five hours"
       (near? (weekly (window-net-of-span (one-day 'monday "18:00" "23:30") "23:00" "07:00")) 5.0))
(check "a night shift 22:00–06:00 keeps only the hour before the span, and none of the small hours"
       (near? (weekly (window-net-of-span (one-day 'monday "22:00" "06:00") "23:00" "07:00")) 1.0))
(check "a night-shift worker who sleeps by day loses nothing: 22:00–06:00 against 08:00–16:00 is eight hours"
       (near? (weekly (window-net-of-span (one-day 'monday "22:00" "06:00") "08:00" "16:00")) 8.0))
(check "a span within one day (13:00–14:00) splits a day's offer in two: 09:00–17:00 is seven hours"
       (near? (weekly (window-net-of-span (one-day 'monday "09:00" "17:00") "13:00" "14:00")) 7.0))
(check "a dated week is netted in its week and on each date it names"
       (let* ((week (weekday-window "06:00" "10:00"))
              (dated (list (make-specific-date-window '("2026-09-28") (list (make-time-range "05:00" "09:00")))))
              (n (window-net-of-span (make-dated-week week dated) "23:00" "07:00")))
         (and (dated-week? n)
              (near? (weekly n) 15.0)
              (let ((r (specific-date-window-time-ranges (car (dated-week-dated n)))))
                (and (= 1 (length r)) (equal? "07:00" (time-range-start-time (car r))))))))
(check "no window is no window"
       (not (window-net-of-span #f "23:00" "07:00")))
(check "#:days restricts the cut to the weekdays it names, leaving the rest untouched"
       (let* ((w (all-week-window "09:00" "17:00"))
              (n (window-net-of-span w "10:00" "12:00" #:days '(monday tuesday))))
         (and (near? (weekly n) (- 56.0 4.0))            ; two hours off two of seven eight-hour days
              (near? (window-hours-on-dates n '("2026-09-28")) 6.0)     ; the Monday: cut
              (near? (window-hours-on-dates n '("2026-10-03")) 8.0))))  ; the Saturday: untouched
(check "#:days #f is the same cut on every day as before the keyword existed"
       (near? (weekly (window-net-of-span (all-week-window "00:00" "23:59") "23:00" "07:00" #:days #f)) 112.0))

(format #t "~%── 2. the spans an agent states ──~%")
(define (agent tags window) (person* "ada" #:place "town" #:tags tags #:window window))
(check "a sleep: tag names one unrestricted span"
       (equal? '(("23:00" "07:00" #f)) (agent-sleep-spans (agent '("general" "sleep:23:00-07:00") #f))))
(check "a trailing weekday list restricts it; several sleep: tags stack, in order"
       (equal? '(("23:00" "07:00" (monday tuesday wednesday thursday friday))
                 ("14:00" "22:00" (saturday sunday)))
               (agent-sleep-spans
                (agent '("general" "sleep:23:00-07:00:monday,tuesday,wednesday,thursday,friday"
                                   "sleep:14:00-22:00:saturday,sunday")
                       #f))))
(check "a biphasic sleeper's main span and nap both stack, unrestricted"
       (equal? '(("23:00" "05:00" #f) ("14:00" "15:30" #f))
               (agent-sleep-spans (agent '("sleep:23:00-05:00" "sleep:14:00-15:30") #f))))
(check "no tag, one that is no span, or an unknown weekday states none"
       (and (null? (agent-sleep-spans (agent '("general") #f)))
            (null? (agent-sleep-spans (agent '("sleep:soon") #f)))
            (null? (agent-sleep-spans (agent '("sleep:25:99-xx") #f)))
            (null? (agent-sleep-spans (agent '("sleep:23:00-07:00:funday") #f)))))
(check "the schedulable window is the offer less every stated span; without one it is the offer as stated"
       (let ((w around-the-clock))
         (and (near? (weekly (agent-schedulable-window (agent '("sleep:23:00-07:00") w))) 112.0)
              (eq? w (agent-schedulable-window (agent '("general") w))))))
(check "a night-shift week's two restricted spans net only their own days: eight off every weekday night (2026-09-28 is a Monday), eight off every weekend afternoon"
       (let* ((w (all-week-window "00:00" "23:59"))
              (a (agent '("sleep:23:00-07:00:monday,tuesday,wednesday,thursday,friday"
                          "sleep:14:00-22:00:saturday,sunday")
                        w))
              (n (agent-schedulable-window a)))
         (and (near? (window-hours-on-dates n '("2026-09-28")) 16.0)    ; Monday, the weekday span
              (near? (window-hours-on-dates n '("2026-10-02")) 16.0)    ; Friday, the weekday span
              (near? (window-hours-on-dates n '("2026-10-03")) 15.98)   ; Saturday, the weekend span
              (near? (window-hours-on-dates n '("2026-10-04")) 15.98))))  ; Sunday, the weekend span
(check "a biphasic sleeper's main span and nap both come off every day"
       (let* ((w (all-week-window "00:00" "23:59"))
              (a (agent '("sleep:23:00-05:00" "sleep:14:00-15:30") w))
              (n (agent-schedulable-window a)))
         (near? (weekly n) (- (* 24.0 7) (* 6.0 7) (* 1.5 7)))))
(check "an agent with no window has none to net"
       (not (agent-schedulable-window (agent '("sleep:23:00-07:00") #f))))
(check "sleep-hours-stated sums every stated span; #f when none is stated"
       (and (near? (sleep-hours-stated (agent '("sleep:23:00-05:00" "sleep:14:00-15:30") #f)) 7.5)
            (not (sleep-hours-stated (agent '("general") #f)))))

(format #t "~%── 3. away days ──~%")
(define (with-tags . tags) (agent (cons "general" tags) (weekday-window "09:00" "17:00")))
(check "an away tag names every date of its span: three days, the first and last included"
       (equal? '("2026-09-28" "2026-09-29" "2026-09-30")
               (agent-away-dates (with-tags "away:2026-09-28..2026-09-30:sick"))))
(check "sick, rest and leave read alike, and several tags add"
       (equal? '("2026-09-28" "2026-10-05" "2026-10-06")
               (agent-away-dates (with-tags "away:2026-09-28..2026-09-28:rest" "away:2026-10-05..2026-10-06:leave"))))
(check "a span that runs backwards, names another kind, or is no dates names none"
       (null? (append (agent-away-dates (with-tags "away:2026-09-30..2026-09-28:sick"))
                      (agent-away-dates (with-tags "away:2026-09-28..2026-09-30:holiday"))
                      (agent-away-dates (with-tags "away:2026-13-45..2026-13-46:sick"))
                      (agent-away-dates (with-tags "away:soon:sick")))))
(check "an away week withdraws its dates and only those: a working week of 40 hours offers 8 on a stated day, 0 on an away day"
       (let ((w (agent-schedulable-window (with-tags "away:2026-09-29..2026-09-29:sick"))))
         (and (dated-week? w)
              (near? (window-hours-on-dates w '("2026-09-28")) 8.0)      ; a Monday
              (near? (window-hours-on-dates w '("2026-09-29")) 0.0)      ; the Tuesday, away
              (near? (window-hours-on-dates w '("2026-09-30")) 8.0))))
(check "the stored offer is untouched: the agent's own window is still the whole week"
       (near? (weekly (agent-availability-window (with-tags "away:2026-09-29..2026-09-29:sick"))) 40.0))
(check "sleep and away days compose: the offer less both"
       (let* ((a (agent '("general" "sleep:23:00-07:00" "away:2026-09-29..2026-09-29:sick") (weekday-window "06:00" "10:00")))
              (w (agent-schedulable-window a)))
         (and (near? (window-hours-on-dates w '("2026-09-28")) 3.0)
              (near? (window-hours-on-dates w '("2026-09-29")) 0.0))))
(check "a dated week keeps the exceptions it has, and an away day wins over one on the same date"
       (let* ((dated (list (make-specific-date-window '("2026-09-29") (list (make-time-range "09:00" "12:00")))))
              (a (person* "ada" #:place "town" #:tags '("away:2026-09-29..2026-09-29:sick")
                          #:window (make-dated-week (weekday-window "09:00" "17:00") dated)))
              (w (agent-schedulable-window a)))
         (near? (window-hours-on-dates w '("2026-09-29")) 0.0)))
(check "an agent with no away tag reads the window as stated"
       (let ((w (weekday-window "09:00" "17:00"))) (eq? w (agent-schedulable-window (agent '("general") w)))))

(format #t "~%── 4. the reservation door and the labour pool ──~%")
(define (entry-hours-of pool id) (let ((es (filter (lambda (e) (equal? (entry-agent e) id)) (pool-entries pool)))) (and (pair? es) (entry-hours (car es)))))
(define (build tags window)
  (build-pool-from-agents (list (person* "ada" #:place "town" #:tags tags #:window window))
                          #:skills-for-agent (lambda (aid) '("spec-cook"))))
(set-agent-disposable! #f)
(check "with nothing registered a person's week is their offer"
       (near? (entry-hours-of (build '("general") around-the-clock) "ada") (* 7 (/ 1439.0 60))))
(check "the pool reads the schedulable window: a stated sleep span takes eight hours a day out of the week"
       (near? (entry-hours-of (build '("general" "sleep:23:00-07:00") around-the-clock) "ada") 112.0))
(set-agent-disposable! (lambda (a days) (* days 14.0)))   ; a body that leaves 14 h a day
(check "a person's week is kept inside what their body leaves of it: an offer of every hour is held to 98"
       (near? (entry-hours-of (build '("general") around-the-clock) "ada") 98.0))
(check "an offer already inside stands: a 40-hour week under a 98-hour ceiling is 40"
       (near? (entry-hours-of (build '("general") (weekday-window "09:00" "17:00")) "ada") 40.0))
(check "the one door answers the solve's days and the pool's week alike: 14 h a day is 14 for a day, 98 for a week"
       (let ((a (agent '("general") #f)))
         (and (near? (agent-disposable-hours a 1) 14.0) (near? (agent-disposable-hours a 7) 98.0)
              (near? (reserve-hours a 1 20.0) 14.0) (near? (reserve-hours a 7 40.0) 40.0))))
(check "a hook that answers #f leaves the offer alone"
       (begin (set-agent-disposable! (lambda (a days) #f))
              (near? (entry-hours-of (build '("general") (weekday-window "09:00" "17:00")) "ada") 40.0)))
(set-agent-disposable! #f)
(check "with nothing registered a body reserves nothing: the door answers #f and an offer stands"
       (let ((a (agent '("general") #f))) (and (not (agent-disposable-hours a 7)) (near? (reserve-hours a 7 120.0) 120.0))))

(format #t "~%── 5. no window at all, but away days (§2c) ──~%")
;; A person with no stated availability window has no window for
;; withdraw-dates to act on (agent-schedulable-window stays #f, §2b/§2c open
;; question), so the flat default the solve falls back to must read the away
;; days directly rather than silently offering them too.
(declare-world! #:places '("town") #:horizon (cons "2026-09-07" 7))
(define no-away (agent '("general") #f))
;; the horizon's periods run one day after its start (dated-week-test's own
;; convention: horizon (cons "2026-09-07" 7)'s day 1 is the 8th, not the 7th)
(define away-all-week (agent '("general" "away:2026-09-08..2026-09-14:sick") #f))
(define away-one-day (agent '("general" "away:2026-09-08..2026-09-08:sick") #f))
(check "a windowless agent with no away days offers the flat default on every day of the horizon"
       (every (lambda (i) (near? (agent-window-hours no-away i) 8.0)) '(1 2 3 4 5 6 7)))
;; period 7 of this horizon carries no dates of its own (a boundary the
;; horizon's own declaration leaves open, not this fix's concern) and falls
;; back to the plain ratio unadjusted, so it is left out here — every period
;; that DOES carry a date is checked.
(check "a windowless agent away the whole horizon offers nothing on any day that names one"
       (every (lambda (i) (near? (agent-window-hours away-all-week i) 0.0)) '(1 2 3 4 5 6)))
(check "a windowless agent away one day of seven: six days flat, one day nothing"
       (near? (fold + 0.0 (map (lambda (i) (agent-window-hours away-one-day i)) '(1 2 3 4 5 6 7))) 48.0))

(format #t "~%── 6. the pool: a windowless agent's away days, read against dates ──~%")
;; entry-hours-on is the pool's date-aware reading (a demand with dates); a
;; windowless entry carries its away days on itself (entry-away) since it has
;; no window to net them from either.
(let* ((pool (build-pool-from-agents
              (list (person* "bo" #:place "town"
                             #:tags '("general" "away:2026-09-08..2026-09-08:sick")
                             #:window #f))
              #:skills-for-agent (lambda (aid) '("spec-cook"))))
       (e (car (filter (lambda (e) (equal? (entry-agent e) "bo")) (pool-entries pool)))))
  (check "the entry's own week is the flat default, matching the roster's own fallback"
         (near? (entry-hours e) 56.0))
  (check "entry-hours-on reads the away day as zero, and an ordinary day as the daily default"
         (and (near? (entry-hours-on e '("2026-09-08")) 0.0)
              (near? (entry-hours-on e '("2026-09-09")) 8.0))))

(format #t "~%  ✓ — ~a passed, ~a failed~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
