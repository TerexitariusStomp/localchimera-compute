;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; solve/periods.scm — what a period is in wall-clock time, as a scope states it.
;;;
;;; The lattice period is an integer. A scope gives it a place on the clock (a
;;; SPAN of dates, or of clock moments for a sub-day band), and a stated LENGTH
;;; for a period that carries none. From those two every reader takes the same
;;; answers: which weekdays a period covers, how many hours it holds, which
;;; period a moment falls in. The horizons (`set-daily-horizon!`,
;;; `set-clock-horizon!`, `standing-partition`) lay spans. The two tables are
;;; fields of the world (solve/world.scm): a fresh world is an empty calendar,
;;; and a world held as a value carries its calendar with it.
;;;
;;; The plan compiles over these and the books date events by them.

(define-module (playnet solve periods)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet solve world) #:select (*period-days* *period-spans*))
  #:use-module ((playnet utils clock) #:select (iso->epoch instant->civil instant->weekday now hhmm->minutes))
  #:use-module ((playnet utils units) #:select (unit-known? convert-unit/strict))
  #:export (*all-days* period-days *weekday-syms* iso-time-of
            iso->epoch/time span-timed? span->days set-period-span! period-span *period-length*
            set-period-length! declared-period-hours period-hours period-contains? time->period
            epoch->iso set-daily-horizon! standing-partition set-clock-horizon!))

(define *all-days* '(monday tuesday wednesday thursday friday saturday sunday))
(define (period-days t) (hash-ref *period-days* t *all-days*))
;; ── period ↔ wall-clock: tie an abstract period to a concrete date span ──────
;; The lattice period is an integer; give it a real interval and (a) availabilityWindow
;; hours land on the right weekdays, (b) emitted commitments carry hasBeginning/hasEnd.
(define *weekday-syms* #(sunday monday tuesday wednesday thursday friday saturday))  ; tm:wday 0=Sun
;; A period boundary may carry a TIME of day — "2026-03-03T09:00" — because a
;; boundary somebody declared ("mornings") is a moment inside a day, not a date.
;; `iso->epoch` reads dates only, so these read the clock part separately rather
;; than changing what a date means anywhere else.
(define (iso-time-of s)                     ; "…THH:MM" → minutes past midnight, else #f
  (let ((i (string-index s #\T)))
    (and i (> (string-length s) (+ i 5))
         (hhmm->minutes (substring s (+ i 1) (+ i 6))))))
(define (iso->epoch/time s)                 ; epoch honouring a time-of-day suffix
  (+ (iso->epoch s) (* 60 (or (iso-time-of s) 0))))
(define (span-timed? t)                     ; does this period carry clock boundaries?
  (let ((sp (period-span t)))
    (and (car sp) (cdr sp) (or (iso-time-of (car sp)) (iso-time-of (cdr sp))) #t)))
(define (span->days start end)              ; weekday symbols covered by [start, end] inclusive
  (let ((e (iso->epoch end)))
    (let loop ((t (iso->epoch start)) (acc '()))
      (if (> t (+ e 1)) (reverse acc)
          (let ((d (vector-ref *weekday-syms* (instant->weekday t))))
            (loop (+ t 86400) (if (memq d acc) acc (cons d acc))))))))
(define (set-period-span! t start end)      ; t :: int, start/end :: ISO date strings
  (hash-set! *period-spans* t (cons start end))
  (hash-set! *period-days* t (span->days start end)))
(define (period-span t) (hash-ref *period-spans* t (cons #f #f)))
;; ── how long a period IS ─────────────────────────────────────────────────────
;; playnet.typ (§One program): "a period is a length of time, not only a place in
;; the order", and "what the plan requires is only that the length be STATED,
;; because every capacity on the lattice is denominated in it". A means is `use`d
;; rather than consumed, so what is rationed is its time — and two ovens across a
;; year are not two ovens across a day though the count is the same.
;;
;; The length is therefore declared, never inferred: `*period-length*` is a
;; (quantity . unit) pair a scope sets to say what one of its periods means. It
;; is not a constant of the engine — the granularity is a governed choice about
;; how finely a scope wants to see its own commitments — so it is stated here as
;; a default rather than assumed silently, and any scope may say otherwise.
;;
;; A period that carries a SPAN (concrete dates, set by a horizon) is measured
;; from the span instead: real days beat a nominal length, and that is the answer
;; for anything wanting calendar exactness rather than a converted month.
(define *period-length* (cons 1.0 "day"))     ; STATED: one period is one day
(define (set-period-length! qty unit)
  (unless (unit-known? unit) (error "unknown unit for a period's length:" unit))
  (set! *period-length* (cons qty unit)))
(define (declared-period-hours)
  "The scope's STATED period length, in hours, independent of any span. This is what
   a number denominated `per period` means when it names no other denominator — and
   it is a declaration (`set-period-length!`), not a reading of whatever partition
   the current solve happens to use, so it holds still while the lattice is refined.
   The home for quantities minted before their unit could carry a denominator."
  (convert-unit/strict (car *period-length*) (cdr *period-length*)
                       #:what "the scope's declared period length"))
(define (period-hours t)
  "How many hours period T contains — measured from its span when it has one,
   else the scope's stated period length."
  (let ((span (period-span t)))
    (cond
     ;; a boundary with a clock time on it — the span is exact, end EXCLUSIVE:
     ;; 09:00→17:00 is eight hours, not nine
     ((span-timed? t)
      (/ (- (iso->epoch/time (cdr span)) (iso->epoch/time (car span))) 3600.0))
     ;; whole dates, both ends inclusive: one date to itself is one day
     ((and (car span) (cdr span))
      (* 24.0 (+ 1.0 (/ (- (iso->epoch (cdr span)) (iso->epoch (car span))) 86400.0))))
     (else (convert-unit/strict (car *period-length*) (cdr *period-length*)
                                #:what "a period's length")))))
;; Inverse of period-span: which period's [start,end] contains WHEN — the missing
;; link that turns a VF hasBeginning (the schema's record of WHEN a worker works)
;; back into the lattice period. WHEN may be an ISO date string or epoch seconds.
;; Falls back to 0 (single-period horizon) when WHEN is #f or no span matches, so
;; single-period planning — where no spans are set — is unaffected.
(define (period-contains? t when)
  "Does WHEN (epoch seconds, or ISO with an optional clock part) fall in
   period T's span? A span boundary carrying a time of day is honoured
   exactly — a sub-day band ends AT its clock, not at its date's end —
   while a date-only end keeps the inclusive-through-its-day reading, so
   daily horizons behave as they always did."
  (let ((span (period-span t)))
    (and (car span) (cdr span)
         (let ((w (if (string? when) (iso->epoch/time when) when)))
           (and (<= (iso->epoch/time (car span)) w)
                (if (iso-time-of (cdr span))
                    (< w (iso->epoch/time (cdr span)))
                    (<= w (+ (iso->epoch (cdr span)) 86399))))))))

(define (time->period when)
  (if (not when) 0
      (let ((w (if (string? when) (iso->epoch/time when) when)))
        (or (hash-fold
              (lambda (t span acc) (or acc (and (period-contains? t w) t)))
              #f *period-spans*)
            0))))
(define (epoch->iso e) (instant->civil e "%Y-%m-%d"))
;; Lay out a PLANNING HORIZON: N daily periods starting START (ISO date). Sets
;; each period's span (and thus its weekday, for availability) and returns the
;; period list (0 … N-1). This is what turns the dormant period↔wall-clock bridge
;; on: with spans set, agent hours land on the right days and emitted
;; commitments carry real hasBeginning/hasEnd. declare-world! lays it on the
;; fresh world it makes. With no horizon the planner stays single-period (period 0, no span).
(define (set-daily-horizon! start n)
  (let ((s (iso->epoch start)))
    (let loop ((t 0) (acc '()))
      (if (>= t n) (reverse acc)
          (let ((d (epoch->iso (+ s (* t 86400)))))
            (set-period-span! t d d)            ; period t = that single day
            (loop (+ t 1) (cons t acc)))))))
;; SUB-DAY bands: N periods of HOURS each. The band is the scheduling atom, so
;; band width is the DIAL between aggregate and exact — the lattice is the
;; classic time-indexed formulation of scheduling, and refining it tightens the
;; convex relaxation of sequencing without ever leaving convexity. Spans carry
;; clock suffixes ("2026-03-03T06:00"), which the span machinery already reads:
;; period-hours measures the timed span, availability windows intersect it,
;; lead pruning and run-spanning arrivals walk it, and emitted commitments
;; carry the clock moment. Hour-level plans are a layout call, not a redesign.
(define (standing-partition n)
  "N periods of the scope's STATED length, laid from today on the one clock:
   the partition a plan stands on when it declares none. A period is a length
   of time (playnet.typ §Space, time, and scope), and a length has to lie
   somewhere on the clock for a window — a calendar object — to meet it; a
   period with no place on the clock left every window to a guess, and the
   guesses disagreed: the agent twin read a week's worth, the means twin a
   share of a week, the labour pool a scheduled day (09:00–10:30 every day
   entered a federated solve as 10.5 h). Whole days lie as dates, any other
   length as clock spans, exactly as set-daily-horizon! and set-clock-horizon!
   lay them, so a fixture that declares nothing and a live scope that declares
   today stand on the same partition."
  (let* ((hours (declared-period-hours))
         (days  (/ hours 24.0))
         (today (epoch->iso (now))))
    (if (and (integer? days) (>= days 1))
        (let ((s (iso->epoch today)) (k (inexact->exact days)))
          (map (lambda (i) (cons (epoch->iso (+ s (* i k 86400)))
                                 (epoch->iso (+ s (* (+ (* i k) (- k 1)) 86400)))))
               (iota n)))
        (let ((s (iso->epoch/time today))
              (step (inexact->exact (round (* hours 3600))))
              (fmt (lambda (e) (instant->civil e "%Y-%m-%dT%H:%M"))))
          (map (lambda (i) (cons (fmt (+ s (* i step))) (fmt (+ s (* (+ i 1) step))))) (iota n))))))
(define (set-clock-horizon! start n hours)
  "N periods of HOURS each, from START (ISO date or datetime, civil UTC).
   Returns the period list (0 … N-1)."
  (let ((s (iso->epoch/time start))
        (step (inexact->exact (round (* hours 3600))))
        (fmt (lambda (e) (instant->civil e "%Y-%m-%dT%H:%M"))))
    (map (lambda (t)
           (set-period-span! t (fmt (+ s (* t step))) (fmt (+ s (* (+ t 1) step))))
           t)
         (iota n))))
