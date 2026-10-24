;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; catalogues/rest.scm — the time floor of the right to rest: SNIRT.
;;;
;;; catalogues/housing.scm states the CONDITIONS of rest (the place a body rests
;;; in); this file states its TIME. SNIRT — socially necessary individual
;;; reproduction time — is the time a person spends reproducing their own body:
;;; sleep, eating, washing, recovering, being ill, days of rest. The plan
;;; RESERVES it and does not allocate it (docs/planning/reproduction-of-labour-
;;; power.md §2b): a person's schedulable hours are
;;;
;;;     D = period − SNIRT
;;;
;;; the hours a citizen offers sit inside D. This file states D; the schedule
;;; reads the person's own sleep span and away days as tags through
;;; matching/availability.scm (`agent-schedulable-window`). Nothing here is a
;;; decision variable.
;;;
;;; ── the layers, housing-catalogue's own shape ───────────────────────────────
;;;   L0 base      sleep by age band + the day's meals and washing
;;;   L2 person    pregnancy adds sleep; a person's own stated sleep replaces the band
;;;   labour       an increment that rises with the hours worked, by the effort
;;;                the recipe states (the energy floor's twin)
;;; The ratified standard (L4) is a scope's to add; `rest-standard` lifts the
;;; increment-free base the way the housing standard lifts its gradients, and
;;; may only raise.
;;;
;;; ── DRAFT ───────────────────────────────────────────────────────────────────
;;; Every figure is a real source's DIRECTION at a modest, illustrative
;;; magnitude: the sleep bands are the midpoints of the AASM/NSF recommended
;;; ranges, the two hours of meals and washing sit where national time-use
;;; surveys cluster, and the labour increment is a stated rate. None claims to
;;; be the one ratified number.

(define-module (localchimera knowledge catalogues rest)
  #:use-module (srfi srfi-1)
  #:use-module ((localchimera knowledge catalogues subsistence) #:select (ctx-ref ratified-standard))
  #:use-module ((localchimera utils clock) #:select (clock-length-minutes))
  #:export (*sleep-bands* *personal-hours* *rest-labour-increment*
            sleep-hours snirt-hours disposable-hours span-hours))

;;; ── L0 · the base ───────────────────────────────────────────────────────────
;; (max-age hours source): the first band whose max-age exceeds the person's age.
;; Midpoints of the ranges: infants 12–16 → 14, toddlers 11–14 → 12.5, pre-school
;; 10–13 → 11.5, school age 9–12 → 10.5, teens 8–10 → 9, adults 7–9 → 8, older
;; adults 7–8 → 7.5.
(define *sleep-bands*
  '((1   14.0 "AASM/NSF: infants 12–16 h a day")
    (3   12.5 "AASM: toddlers 11–14 h")
    (6   11.5 "AASM: pre-school 10–13 h")
    (13  10.5 "AASM: school age 9–12 h")
    (18   9.0 "AASM: teens 8–10 h")
    (65   8.0 "AASM/SRS adult consensus: at least 7 h, 7–9 recommended")
    (999  7.5 "NSF: older adults 7–8 h")))

;; meals, washing and dressing a day — national time-use surveys (eating and
;; drinking plus personal care outside sleep) cluster near two hours
(define *personal-hours* 2.0)

;; the increment: rest owed per hour of labour, times the effort the work
;; states (1.0 an ordinary hour). The energy floor's twin: it rises with what
;; the day spent.
(define *rest-labour-increment* 0.1)

;;; ── L2 · the person ─────────────────────────────────────────────────────────
;; sleep hours a day: the band, plus an hour in pregnancy; or the person's own
;; stated figure (a body knows its need), kept inside 4–14 h.
(define (sleep-hours ctx)
  (let ((stated (ctx-ref ctx 'sleep-hours #f)))
    (if stated
        (max 4.0 (min 14.0 stated))
        (let* ((age (ctx-ref ctx 'age 30))
               (band (find (lambda (b) (< age (car b))) *sleep-bands*)))
          (+ (cadr band) (if (ctx-ref ctx 'pregnant #f) 1.0 0.0))))))

;;; ── SNIRT, per day ──────────────────────────────────────────────────────────
;; the base (sleep + meals and washing), raised by the labour increment, then
;; lifted by the scope's ratified `rest-standard` — which may only raise.
;; ctx (the person ctx the subsistence and housing floors read): age, pregnant,
;; labour-hours (labour hours a day), plus sleep-hours (the person's own stated
;; need), effort
;; (default 1.0), rest-standard (default 1).
(define (snirt-hours ctx)
  (let* ((base (+ (sleep-hours ctx) *personal-hours*))
         (work (ctx-ref ctx 'labour-hours 0.0))
         (effort (ctx-ref ctx 'effort 1.0))
         (std (ratified-standard (ctx-ref ctx 'rest-standard 1))))
    (+ (* base std) (* *rest-labour-increment* effort work))))

;; schedulable hours of a period of DAYS days: everything but SNIRT
(define* (disposable-hours ctx #:key (days 1))
  (max 0.0 (- (* 24.0 days) (* days (snirt-hours ctx)))))

;;; ── a stated sleep span ─────────────────────────────────────────────────────
;; the hours a clock span FROM→TO ("23:00"→"07:00", wrapping midnight) covers: what a
;; person who states a sleep span states of their need
(define (span-hours from to) (/ (clock-length-minutes from to) 60.0))
