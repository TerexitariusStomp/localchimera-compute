;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; matching/availability.scm — Overlap and intersection of availability
;;; windows for the matching layer.
;;;
;;; Pure VF: operates only on the <availability-window>,
;;; <month-schedule>, <week-schedule>, <day-schedule>, <time-range>
;;; records defined in (playnet vf schemas). No <intent-binding> coupling
;;; — the feasibility layer pulls the window off
;;; (intent-availability-window …) before calling in here.
;;;
;;; Time zones are intentionally simplified for the first port: HH:MM
;;; strings are compared lexicographically (the same trick the TS code
;;; uses for single-TZ paths). The cross-TZ helpers in match.ts depend
;;; on JavaScript Date math; bringing them across is a follow-up.
;;;
;;; Pure: no I/O, no mutation. Hoot/WASM compatible.

(define-module (playnet vf facts availability)
  ;; ONE statement of what "HH:MM to HH:MM" means, shared with the solve. Strings
  ;; rather than records, which is what lets it cross the primitive-load seam.
  #:use-module ((playnet utils clock)
                #:select (hhmm->minutes minutes->hhmm
                          clock-length-minutes clock-pieces union-minutes clock-ranges-minutes clock-overlaps? clock-overlap-minutes civil->instant instant->civil instant->weekday days->seconds))
  ;; the parse itself needs no wrapper — callers get the shared one directly
  #:re-export (hhmm->minutes)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils alist) #:select (assq-replace))
  #:use-module (srfi srfi-9)
  #:use-module (playnet vf schemas)    ; <time-range>, <day-schedule>,
  #:use-module (playnet vf beyond schedules)
                                            ; <week-schedule>, <month-schedule>,
                                            ; <availability-window>, …
  #:export (;; Atomic predicates
            time-ranges-overlap?
            any-time-ranges-overlap?
            intersect-time-ranges
            day-schedules-overlap?

            ;; Window-level
            availability-windows-overlap?
            calculate-availability-intersection

            ;; Window analysis (used by feasibility scorers)
            window-day-schedules
            window-time-ranges
            window-first-time-range
            window-block-count
            window-slots
            slot-minutes
            window-total-minutes
            window-max-block-minutes
            window-weekly-hours
            window-hours-on-dates
            window-net-of-span withdraw-dates
            iso-dates-through
            iso-date-weekday
            %week-days

            ;; A week with dated exceptions: the offer a citizen actually makes
            make-dated-week dated-week? dated-week-week dated-week-dated
            dated-week-overrides

            ;; Time/range helpers
            range-length-minutes
            extract-day-schedules-from-month
            extract-day-schedules-from-week
            common-days))


;;; ── Time-range primitives ──────────────────────────────────────────────────

(define (range-length-minutes tr)
  "Duration of a <time-range> in minutes, correct across midnight: a 22:00-02:00
   shift is four hours. Read as a plain subtraction it was MINUS twenty."
  (clock-length-minutes (time-range-start-time tr) (time-range-end-time tr)))

(define (time-ranges-overlap? r1 r2)
  "Do two ranges share any time? Correct when either crosses midnight — compared
   as bare strings, a 22:00-02:00 shift reported NO overlap with 00:00-06:00,
   which it overlaps by two hours."
  (clock-overlaps? (time-range-start-time r1) (time-range-end-time r1)
                   (time-range-start-time r2) (time-range-end-time r2)))

(define (any-time-ranges-overlap? rs1 rs2)
  "True if any pair in RS1 × RS2 overlaps. Optimistic when either side
   is empty — 'no time constraint' is treated as 'all day'."
  (cond
    ((or (null? rs1) (null? rs2)) #t)
    (else
     (any (lambda (a)
            (any (lambda (b) (time-ranges-overlap? a b)) rs2))
          rs1))))

(define (intersect-time-ranges rs1 rs2)
  "Return the list of <time-range>s that are the intersection of RS1
   with RS2. Empty list if no overlap."
  (filter-map
   (lambda (pair)
     (let* ((a (car pair)) (b (cdr pair))
            (s (if (string<? (time-range-start-time a)
                             (time-range-start-time b))
                   (time-range-start-time b)
                   (time-range-start-time a)))
            (e (if (string<? (time-range-end-time a)
                             (time-range-end-time b))
                   (time-range-end-time a)
                   (time-range-end-time b))))
       (if (string<? s e) (make-time-range s e) #f)))
   (concatenate (map (lambda (a) (map (lambda (b) (cons a b)) rs2)) rs1))))


;;; ── Day-schedule helpers ───────────────────────────────────────────────────

(define (common-days days1 days2)
  "Symbols in DAYS1 that also appear in DAYS2."
  (filter (lambda (d) (memq d days2)) days1))

(define (day-schedules-overlap? ds1-list ds2-list)
  "True when any pair of <day-schedule>s shares a day with overlapping
   time-ranges. Empty time-ranges count as 'all day'."
  (any (lambda (a)
         (any (lambda (b)
                (and (pair? (common-days (day-schedule-days a)
                                         (day-schedule-days b)))
                     (any-time-ranges-overlap?
                      (day-schedule-time-ranges a)
                      (day-schedule-time-ranges b))))
              ds2-list))
       ds1-list))


;;; ── Extracting day-schedules from higher levels ────────────────────────────

(define (extract-day-schedules-from-week ws)
  "All day-schedules nested under a <week-schedule>."
  (or (week-schedule-day-schedules ws) '()))

(define (extract-day-schedules-from-month ms)
  "All day-schedules implied by a <month-schedule>, walking the
   week-schedules > day-schedules > time-ranges priority. If only
   time-ranges are present, return a single 7-day schedule covering
   them — the TS code does the same thing implicitly."
  (cond
    ((let ((ws (month-schedule-week-schedules ms)))
       (and ws (pair? ws)))
     (append-map extract-day-schedules-from-week
                 (month-schedule-week-schedules ms)))
    ((let ((ds (month-schedule-day-schedules ms)))
       (and ds (pair? ds)))
     (month-schedule-day-schedules ms))
    ((let ((trs (month-schedule-time-ranges ms)))
       (and trs (pair? trs)))
     (list (make-day-schedule
            '(monday tuesday wednesday thursday friday saturday sunday)
            (month-schedule-time-ranges ms))))
    (else '())))

(define (window-day-schedules w)
  "Best-effort flatten of an <availability-window> down to its
   day-schedules level. Walks priority month > week > day > time-ranges
   and returns a (possibly empty) list of <day-schedule>."
  (cond
    ((not w) '())
    ((not (availability-window? w)) '())
    ((let ((ms (availability-window-month-schedules w)))
       (and ms (pair? ms)))
     (append-map extract-day-schedules-from-month
                 (availability-window-month-schedules w)))
    ((let ((ws (availability-window-week-schedules w)))
       (and ws (pair? ws)))
     (append-map extract-day-schedules-from-week
                 (availability-window-week-schedules w)))
    ((let ((ds (availability-window-day-schedules w)))
       (and ds (pair? ds)))
     (availability-window-day-schedules w))
    ((let ((trs (availability-window-time-ranges w)))
       (and trs (pair? trs)))
     (list (make-day-schedule
            '(monday tuesday wednesday thursday friday saturday sunday)
            (availability-window-time-ranges w))))
    (else '())))

(define (window-time-ranges w)
  "All <time-range>s appearing anywhere in W, flat list."
  (append-map day-schedule-time-ranges (window-day-schedules w)))

(define (window-slots w)
  "Every bookable (day . <time-range>) in W: each day-schedule's days crossed
   with its ranges. Reads W through window-day-schedules, so a window that
   states its hours at the month or week level yields slots too."
  (append-map
   (lambda (ds)
     (let ((trs (or (day-schedule-time-ranges ds) '())))
       (append-map (lambda (day) (map (lambda (tr) (cons day tr)) trs))
                   (or (day-schedule-days ds) '()))))
   (window-day-schedules w)))

(define (slot-minutes slot)
  "How long a (day . <time-range>) slot runs, correct across midnight."
  (range-length-minutes (cdr slot)))

(define (day-minutes slots)
  "((day . minutes) …): the minutes SLOTS offer on each day they name, the
   ranges of one day taken as the stretch of the day they cover. A person who
   offers 09:00-17:00 twice, or 09:00-13:00 and 11:00-15:00, offers the
   day once: one body has one day."
  (let ((by-day (fold (lambda (slot acc)
                        (let ((d (car slot)))
                          (assq-replace acc d
                                        (append (clock-pieces (time-range-start-time (cdr slot))
                                                              (time-range-end-time (cdr slot)))
                                                (or (assq-ref acc d) '())))))
                      '() slots)))
    (map (lambda (p) (cons (car p) (union-minutes (cdr p)))) by-day)))

(define (window-first-time-range w)
  "First <time-range> reachable through W, or #f if W has none.
   Walks the priority hierarchy via window-day-schedules."
  (cond ((not (availability-window? w)) #f)
        ((and (availability-window-time-ranges w)
              (pair? (availability-window-time-ranges w)))
         (car (availability-window-time-ranges w)))
        (else
         (let ((trs (window-time-ranges w)))
           (if (pair? trs) (car trs) #f)))))

(define (window-block-count w)
  "Number of (day, time-range) blocks W expresses."
  (length (window-time-ranges w)))

(define (window-total-minutes w)
  "Sum of minutes across all of W's time-ranges."
  (apply + 0 (map range-length-minutes (window-time-ranges w))))

;;; ── A week with dated exceptions ────────────────────────────────────────────
;;; The offer a citizen actually makes: a recurring week (the availability ring,
;;; painted per weekday, net of committed recurring events) and, on the dates a
;;; one-time commitment falls, that day's offer stated outright. VF's
;;; availabilityWindow has no exceptions and playnet's <specific-date-window>
;;; names dates without a week, so the two are held together here: DATED is a
;;; list of <specific-date-window>s, and on a date any of them names, its
;;; ranges are the day's whole offer — a stated day beats the week. A date named
;;; with no ranges is a day withdrawn.
(define-record-type <dated-week>
  (make-dated-week week dated)
  dated-week?
  (week  dated-week-week)     ; <availability-window>: the recurring offer
  (dated dated-week-dated))   ; (<specific-date-window> …): the exceptions

(define (dated-week-overrides w)
  "((\"YYYY-MM-DD\" . (<time-range> …)) …): every date the exceptions name, with
   the ranges offered on it — empty ranges for a day withdrawn."
  (append-map (lambda (sdw)
                (let ((trs (or (specific-date-window-time-ranges sdw) '())))
                  (map (lambda (d) (cons d trs))
                       (or (specific-date-window-specific-dates sdw) '()))))
              (dated-week-dated w)))

(define (window-weekly-hours w)
  "Hours W offers in a week: every (day . range) slot it names, summed.

   A recurring window has exactly one date-free measure, and this is it — the
   number a standing roster carries, the number a person offers who paints
   their week. `window-total-minutes` sums each schedule's ranges once, which
   is the same total on the windows the app produces (one schedule per
   weekday) and a smaller one on a schedule that names several days at once
   (Monday–Friday 09:00–17:00 read as 8 h there, 40 h here). A dated week's
   is its week's: an exception moves hours on a date, never the week."
  (let ((w (if (dated-week? w) (dated-week-week w) w)))
    (/ (fold + 0 (map cdr (day-minutes (window-slots w)))) 60)))

(define (window-hours-on-dates w dates)
  "Hours W offers on DATES, ISO \"YYYY-MM-DD\" strings: each date's weekday
   meets the slots that name it. The recurring week, read against the days a
   plan actually asks for — the same intersection the solver takes over a
   period's span (engine `temporal-hours-within`), here for a roster read
   that knows the dates and not the period. A dated week answers a date it
   names with the exception's ranges instead — a stated day beats the week."
  (let* ((week   (if (dated-week? w) (dated-week-week w) w))
         (over   (if (dated-week? w) (dated-week-overrides w) '()))
         (by-day (day-minutes (window-slots week))))
    (/ (fold (lambda (date acc)
               (+ acc (cond ((assoc date over)
                             => (lambda (p) (clock-ranges-minutes (map (lambda (r) (cons (time-range-start-time r) (time-range-end-time r))) (cdr p)))))
                            (else (or (assq-ref by-day (iso-date-weekday date)) 0)))))
             0 dates)
       60)))

(define %weekday-syms #(sunday monday tuesday wednesday thursday friday saturday))
(define (iso-date-weekday d)
  "The weekday symbol of an ISO date (a datetime's date part serves too) — the
   civil UTC day, read off the one clock."
  (vector-ref %weekday-syms (instant->weekday (civil->instant (substring d 0 10)))))

(define (iso-dates-through from until)
  "Every ISO date from FROM to UNTIL inclusive (either may carry a clock part),
   walked on the one clock."
  (let ((a (civil->instant (substring from 0 10)))
        (b (civil->instant (substring until 0 10)))
        (day (days->seconds 1)))
    (let loop ((t a) (acc '()))
      (if (> t b) (reverse acc)
          (loop (+ t day) (cons (instant->civil t "%Y-%m-%d") acc))))))

(define (window-max-block-minutes w)
  "Longest single time-block in W, in minutes. 0 if W has no ranges."
  (let ((mins (map range-length-minutes (window-time-ranges w))))
    (if (null? mins) 0 (apply max mins))))


;;; ── Public API ─────────────────────────────────────────────────────────────

(define (availability-windows-overlap? w1 w2)
  "Single-timezone overlap test between two <availability-window>s.
   Optimistic when either window is #f (no time constraint).

   This is a SIMPLIFICATION of the TS availabilityWindowsOverlap:
   it flattens both windows to their day-schedule level and tests
   pairwise. That's correct for the dominant case (weekly recurring
   office hours), and loses precision only when the two windows
   express patterns at different levels of the hierarchy — in which
   case the TS code also coerces to day-schedules before comparing.

   For month-level windows it still respects month restriction by
   intersecting common months first."
  (cond
    ((or (not w1) (not w2)) #t)

    ;; Both have month_schedules — must share at least one month with
    ;; overlapping inner patterns.
    ((and (availability-window? w1) (availability-window? w2)
          (let ((m1 (availability-window-month-schedules w1))
                (m2 (availability-window-month-schedules w2)))
            (and m1 (pair? m1) m2 (pair? m2))))
     (let* ((m1 (availability-window-month-schedules w1))
            (m2 (availability-window-month-schedules w2))
            (months1 (map month-schedule-month m1))
            (months2 (map month-schedule-month m2))
            (common  (filter (lambda (m) (memv m months2)) months1)))
       (and (pair? common)
            (any (lambda (month)
                   (let ((ms1 (find (lambda (s) (= (month-schedule-month s) month)) m1))
                         (ms2 (find (lambda (s) (= (month-schedule-month s) month)) m2)))
                     (day-schedules-overlap?
                      (extract-day-schedules-from-month ms1)
                      (extract-day-schedules-from-month ms2))))
                 common))))

    ;; Fallback: flatten both sides to day-schedules and test overlap.
    (else
     (let ((ds1 (window-day-schedules w1))
           (ds2 (window-day-schedules w2)))
       (cond
         ((null? ds1) #t)   ;; w1 is effectively all-day
         ((null? ds2) #t)   ;; w2 is effectively all-day
         (else (day-schedules-overlap? ds1 ds2)))))))


(define (calculate-availability-intersection w1 w2)
  "Compute the AvailabilityWindow that is the intersection of W1 and W2.
   Returns a freshly-built <availability-window> whose day-schedules
   list reflects all (day, time-range) pairs common to both.

   Always normalizes to day_schedules — same convention as the TS
   calculateAvailabilityIntersection — so the caller can iterate it
   uniformly without re-walking the priority hierarchy."
  (let* ((ds1 (window-day-schedules w1))
         (ds2 (window-day-schedules w2))
         (common-schedules
          (filter-map
           (lambda (pair)
             (let* ((a (car pair)) (b (cdr pair))
                    (shared-days
                     (common-days (day-schedule-days a)
                                  (day-schedule-days b)))
                    (overlap-ranges
                     (intersect-time-ranges
                      (day-schedule-time-ranges a)
                      (day-schedule-time-ranges b))))
               (if (and (pair? shared-days) (pair? overlap-ranges))
                   ;; One DaySchedule per (a, b) pair — keep granular so
                   ;; downstream code can detect fragmentation.
                   (make-day-schedule shared-days overlap-ranges)
                   #f)))
           (concatenate (map (lambda (a) (map (lambda (b) (cons a b)) ds2)) ds1)))))
    (make-availability-window
     #f                  ;; month-schedules
     #f                  ;; week-schedules
     common-schedules    ;; day-schedules
     #f)))               ;; time-ranges


;;; ── A window net of the sleep span ──────────────────────────────────────────
;;; The sleep window is a protected span of the day (docs/planning/reproduction-
;;; of-labour-power.md §2b): the schedule never enters it, whatever the person's
;;; offer covers. WINDOW-NET-OF-SPAN takes a window and one clock span FROM→TO
;;; ("23:00"→"07:00", wrapping midnight) and returns the window with that span
;;; taken out of every slot: the same offer on the days it names, less the hours
;;; the body reserves. A slot that crosses midnight lands its second part on
;;; the next day, so each day's pieces are that day's. A slot the span does not
;;; touch is kept as it stands. Pure: minutes on a clock face.
;;;
;;; #:days restricts which days the span cuts from — #f (the default) touches
;;; every day, matching every caller before this keyword existed; a list of
;;; weekday symbols reads it on those days only and leaves the rest untouched,
;;; for a person whose sleep genuinely varies by day (a night-shift week, a
;;; biphasic sleeper who states one span for weekdays and another for the
;;; weekend). Checked against the SLOT's own day, before any midnight wrap, so
;;; the restriction reads as the person states it: which nights this span
;;; applies to. A dated week's one-off exceptions are date-keyed, not weekday-
;;; keyed, and a restricted span does not reach them — a stated day already
;;; beats the week, and a "these weekdays only" pattern is a recurring-week
;;; concept, not a one-off override's.

(define %week-days '(monday tuesday wednesday thursday friday saturday sunday))
(define (day-after d)
  (let ((tail (memq d %week-days)))
    (if (and tail (pair? (cdr tail))) (cadr tail) (car %week-days))))

(define (piece-hhmm m)                     ; a piece's end at midnight closes the day at 23:59, the app's own convention
  (minutes->hhmm (min m 1439)))

(define (span-intervals from to)           ; the intervals of one clock day a span covers
  (let ((s (hhmm->minutes from)) (e (hhmm->minutes to)))
    (cond ((= s e) '())
          ((< s e) (list (cons s e)))
          (else (list (cons s 1440) (cons 0 e))))))

(define (subtract-intervals ivs cuts)      ; IVS less CUTS, both lists of (lo . hi)
  (fold (lambda (c acc)
          (append-map (lambda (iv)
                        (let ((lo (car iv)) (hi (cdr iv)))
                          (if (or (>= (car c) hi) (<= (cdr c) lo))
                              (list iv)
                              (append (if (< lo (car c)) (list (cons lo (car c))) '())
                                      (if (< (cdr c) hi) (list (cons (cdr c) hi)) '())))))
                      acc))
        ivs cuts))

(define* (net-slots slots from to #:key (days #f))
  "SLOTS, (day . <time-range>) pairs, less the span: an alist day → (<time-range> …).
   DAYS restricts the cut to those weekdays; #f cuts every day."
  (let ((span (make-time-range from to)) (cuts (span-intervals from to)) (by-day '()))
    (define (add! day tr)
      (set! by-day (assq-replace by-day day (append (or (assq-ref by-day day) '()) (list tr)))))
    (for-each
     (lambda (slot)
       (let ((day (car slot)) (tr (cdr slot)))
         (if (or (not (time-ranges-overlap? tr span)) (and days (not (memq day days))))
             (add! day tr)
             (let* ((s (hhmm->minutes (time-range-start-time tr)))
                    (e (hhmm->minutes (time-range-end-time tr)))
                    (parts (if (< s e)
                               (list (cons day (cons s e)))
                               (list (cons day (cons s 1440)) (cons (day-after day) (cons 0 e))))))
               (for-each
                (lambda (part)
                  (for-each (lambda (iv)
                              (when (< (car iv) (cdr iv))
                                (add! (car part) (make-time-range (piece-hhmm (car iv)) (piece-hhmm (cdr iv))))))
                            (subtract-intervals (list (cdr part)) cuts)))
                parts)))))
     slots)
    by-day))

(define* (window-net-of-span w from to #:key (days #f))
  "W with the clock span FROM→TO taken out of every slot DAYS names (#f: every
   slot). A dated week is netted in its week, and on each date it names when
   DAYS is #f — a restricted span does not reach one-off dated exceptions (see
   the header above); W is returned as it is when it is no window at all."
  (cond
    ((dated-week? w)
     (make-dated-week
      (window-net-of-span (dated-week-week w) from to #:days days)
      (if days
          (dated-week-dated w)
          (map (lambda (sdw)
                 (let ((netted (assq-ref (net-slots (map (lambda (tr) (cons 'date tr))
                                                         (or (specific-date-window-time-ranges sdw) '()))
                                                    from to)
                                         'date)))
                   (make-specific-date-window (specific-date-window-specific-dates sdw) (or netted '()))))
               (dated-week-dated w)))))
    ((availability-window? w)
     (make-availability-window
      #f #f
      (map (lambda (d) (make-day-schedule (list (car d)) (cdr d)))
           (net-slots (window-slots w) from to #:days days))
      #f))
    (else w)))

;;; ── A window with dates withdrawn ───────────────────────────────────────────
(define (withdraw-dates w dates)
  "W with each of DATES withdrawn: a stated day with no ranges beats the week, so
   the plan finds nobody on it. A dated week keeps the exceptions it has."
  (if (null? dates)
      w
      (make-dated-week (if (dated-week? w) (dated-week-week w) w)
                       (cons (make-specific-date-window dates '())
                             (if (dated-week? w) (dated-week-dated w) '())))))
