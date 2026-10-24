;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; agent-time.scm — what a person states of their time, and what the schedule reads.
;;;
;;; Two tags on the Agent take time out of the offer, each a fact about the body
;;; and never a reason the plan asks for:
;;;   sleep:23:00-07:00                    a span of the day they sleep, every day
;;;   sleep:14:00-22:00:saturday,sunday    …or on the named weekdays only
;;;   away:2026-09-28..2026-09-30:sick     days they are unavailable — sick, rest
;;;                                        or leave, the plan reading the three alike
;;; Several sleep: tags stack, the same as away: does — a night-shift week states
;;; one span for its work days and another for the rest, and a biphasic sleeper
;;; states a main span and a nap, both naming no days (every day). AGENT-
;;; SCHEDULABLE-WINDOW is the offer less all of it: the one window the solve, the
;;; partition's clock boundaries and the labour pool read. The stored offer stays
;;; as the person stated it. The window algebra itself — net of a clock span, with
;;; dates withdrawn — is matching/availability.scm's; this module reads it off an
;;; Agent.
;;;
;;; ── the reservation of rest ─────────────────────────────────────────────────
;;; A caller that knows what a person's body takes each day registers
;;; `(agent days) → hours`: the hours of DAYS days left after the person's own
;;; reproduction time (docs/planning/food/reproduction-of-labour-power.md §2b), or #f
;;; where nothing is reserved. The solve reads it per period and the labour pool
;;; per week, through one door, so the two cannot disagree about what a body
;;; leaves. With nothing registered every offer stands.
;;;
;;; Hoot/WASM compatible.

(define-module (localchimera vf facts agent-time)
  #:use-module (srfi srfi-1)
  #:use-module ((localchimera utils clock) #:select (hhmm->minutes clock-length-minutes))
  #:use-module ((localchimera vf facts availability)
                #:select (window-net-of-span withdraw-dates iso-dates-through %week-days))
  #:use-module ((localchimera vf facts agent-tags) #:select (agent-tag-value agent-tag-values))
  #:use-module ((localchimera vf schemas) #:select (agent-availability-window))
  #:export (%time-tag-prefixes
            agent-sleep-spans span-from span-to span-days sleep-hours-stated
            agent-away-dates away-count agent-schedulable-window
            set-agent-disposable! agent-disposable-hours reserve-hours))

;; the two tags a person's stated time owns; a profile write replaces exactly their
;; prefixes, and the readers below take these same keys
(define %sleep-key "sleep")
(define %away-key "away")
(define %time-tag-prefixes (map (lambda (k) (string-append k ":")) (list %sleep-key %away-key)))

;; the seven weekday symbols a sleep: tag's day-list names — matching/
;; availability.scm's own %week-days, so a span's restriction lines up with
;; the slot day window-net-of-span checks it against with no translation,
;; and the two modules cannot drift on what a weekday is spelled
(define (parse-weekday s)
  "The weekday symbol S (\"monday\") names, or #f."
  (let ((sym (string->symbol s))) (and (memq sym %week-days) sym)))

(define (parse-days-list s)
  "The weekday symbols a non-empty comma-separated \"monday,tuesday\" names, or
   #f when it is empty or any name is not one of the seven."
  (and (> (string-length s) 0)
       (let ((syms (map parse-weekday (string-split s #\,))))
         (and (every (lambda (x) x) syms) syms))))

(define (span-from s) (car s))
(define (span-to s) (cadr s))
(define (span-days s) (caddr s))    ; #f (every day) or the weekday symbols it is restricted to

(define (sleep-tag-span v)
  "One sleep: tag's value, parsed to (from to days) — DAYS #f for every day — or
   #f when it is not this shape. HH:MM is always five characters, so — like
   away-tag-dates' own dates — the parse is fixed-width rather than a delimiter
   search: nothing inside \"07:00\" is mistaken for the day-list's own ':'."
  (and (>= (string-length v) 11) (char=? (string-ref v 5) #\-)
       (let ((from (substring v 0 5)) (to (substring v 6 11)))
         (and (hhmm->minutes from) (hhmm->minutes to)
              (cond
                ((= (string-length v) 11) (list from to #f))
                ((char=? (string-ref v 11) #\:)
                 (let ((days (parse-days-list (substring v 12))))
                   (and days (list from to days))))
                (else #f))))))

(define (agent-sleep-spans a)
  "Every sleep: tag's span, in order, each (from to days) — DAYS #f for every
   day or the weekday symbols it is restricted to. Several stack: a night-
   shift week states one for its work days and another for the rest; a
   biphasic sleeper states a main span and a nap, both unrestricted."
  (filter-map sleep-tag-span (agent-tag-values a %sleep-key)))

(define (sleep-hours-stated a)
  "The agent's own stated sleep, hours a day, summed across every span they
   state — or #f when they state none, for a caller that falls back to an
   age band. A per-day APPROXIMATION where sleep genuinely varies by day (a
   night-shift split, a nap on top of a main span): the reservation this
   feeds (catalogues/rest.scm's SNIRT) is one constant a day by its own
   construction, the way the age band it replaces already was."
  (let ((spans (agent-sleep-spans a)))
    (and (pair? spans)
         (apply + (map (lambda (s) (/ (clock-length-minutes (span-from s) (span-to s)) 60.0)) spans)))))

(define %away-kinds '("sick" "rest" "leave"))

(define (iso-date-string? s)
  "\"YYYY-MM-DD\" with a month 1–12 and a day 1–31."
  (and (= (string-length s) 10)
       (char=? (string-ref s 4) #\-) (char=? (string-ref s 7) #\-)
       (let ((y (string->number (substring s 0 4)))
             (m (string->number (substring s 5 7)))
             (d (string->number (substring s 8 10))))
         (and y m d (<= 1 m 12) (<= 1 d 31)))))

(define (away-tag-dates v)
  "The dates of one away: value, \"YYYY-MM-DD..YYYY-MM-DD:kind\", or '() when it is
   no such span, runs backwards, or names another kind."
  (if (and (> (string-length v) 23) (string=? (substring v 10 12) "..") (char=? (string-ref v 22) #\:))
      (let ((from (substring v 0 10)) (to (substring v 12 22)) (kind (substring v 23)))
        (if (and (iso-date-string? from) (iso-date-string? to) (member kind %away-kinds) (string<=? from to))
            (iso-dates-through from to)
            '()))
      '()))

(define (agent-away-dates a)
  "Every ISO date the agent's away: tags name, in order."
  (append-map away-tag-dates (agent-tag-values a %away-key)))

(define (away-count away dates)
  "How many of DATES — a list of \"YYYY-MM-DD\" strings — appear in AWAY, a list
   of the same. The one primitive every \"no window at all\" fallback reads: a
   window nets its own away dates through withdraw-dates (below), but a flat
   default rate has no window to net them from, so it reads this instead —
   engine.scm's agent-window-hours and the labour pool's entry-hours-on both
   subtract exactly this count from an otherwise date-blind rate."
  (length (filter (lambda (d) (member d away)) dates)))

(define (agent-schedulable-window a)
  "The agent's availability window less every sleep span they state and their
   away days, or the window as stated when they state neither. Several sleep
   spans net out in the order stated — each its own day-restriction, or none —
   which composes correctly because netting is idempotent per slot: a night-
   shift week's two spans cut only their own weekdays, and a biphasic
   sleeper's main span and nap both cut every day."
  (let* ((w (agent-availability-window a))
         (rested (fold (lambda (sp acc)
                          (and acc (window-net-of-span acc (span-from sp) (span-to sp) #:days (span-days sp))))
                        w (agent-sleep-spans a))))
    (if rested (withdraw-dates rested (agent-away-dates a)) rested)))

;;; ── the reservation of rest ─────────────────────────────────────────────────
(define *agent-disposable* #f)
(define (set-agent-disposable! f) (set! *agent-disposable* f))
;; STANDARD is the scope's ratified rest standard when the caller is a solve of one:
;; the hook is process-wide, so a scope's own number rides the call and is never
;; read from a cell some other scope last wrote. At 1 the hook is called as it
;; always was, with two arguments.
(define* (agent-disposable-hours a days #:optional (standard 1))
  (and *agent-disposable*
       (if (= standard 1) (*agent-disposable* a days) (*agent-disposable* a days standard))))
(define (reserve-hours a days hours)
  "HOURS kept inside what agent A's body leaves of DAYS days.

   Written as a comparison rather than `min`: R7RS's exactness contagion makes
   `(min 56 14.0)` come back `56.0` even though 56 is the exact value chosen,
   because rest-catalogue's disposable-hours is float by construction (§2a's
   base is a plain number, not a ratio). An hour nobody asked to clamp should
   stay whatever kind of number it already was — every caller that is not
   actually inside the reservation (agent-disposable-hours answering #f, or a
   body with room to spare) sees its own HOURS back unchanged."
  (let ((d (agent-disposable-hours a days)))
    (if (and d (< d hours)) d hours)))
