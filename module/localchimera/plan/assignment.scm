;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; plan/assignment.scm — from the plan's OFFER to a rota.
;;;
;;; `plan->work` ends with a candidate FIELD: per need, every worker who could
;;; serve it and the share the plan granted them. Its own comment names what it
;;; is — "the offer set, not one provider" — and `live.scm` puts it on the wire
;;; that way. This turns that offer into an assignment: one named person per
;;; atomic act.
;;;
;;; ── why this is a separate act, and not a mode on the solve ─────────────────
;;; Three reasons, and the third is the one that matters.
;;;
;;; LAYERING. `plan->work` lives in the engine, whose only imports are srfi-1,
;;; ice-9 format, system foreign and rnrs bytevectors — no project dependency at
;;; all. Calling a matcher from there would be the engine's first dependency on
;;; the tree it is itself included into.
;;;
;;; MEANING. `plan-from-records` already carries 37 keyword arguments. A 38th
;;; would not add a feature; it would change what the RETURNED COMMITMENTS MEAN
;;; — a pro-rata share of everyone's hours, or one person's whole act — behind a
;;; boolean, and every consumer downstream (observer, credit, rollup) would get
;;; different data from the same call without asking for it.
;;;
;;; POLITICS. Whether an offer becomes an assignment by a matcher, by people
;;; claiming slots, or by a rota agreed in a meeting is a question for the
;;; scope, not for the solver. The planner publishes the offer because that is
;;; the honest end of its authority. This module is ONE answer to it, which a
;;; scope may use or replace; that is why it is importable rather than implied.
;;;
;;; ── what the plan decides, and what is left ────────────────────────────────
;;; The plan decides HOW MUCH each person works — that is the located labour
;;; balance and the EMP congestion, and it is already fair in the sense the
;;; federation set (equal share of the time each offers). What it cannot decide
;;; is WHICH acts are whose, because within one skill it holds a single labour
;;; pool: two tasks drawing the same skill are indistinguishable to it.
;;;
;;; So the plan's grant becomes each person's CAPACITY, in whole acts. The
;;; matching cannot hand anyone more of the week than the plan did, and the
;;; whole-number answer carries out what the fractional one intended.

(define-module (localchimera plan assignment)
  #:use-module (localchimera algorithms deferred-acceptance)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:export (assign-plan-slots slot-key slot-need slot-worker slot-hours))

;;; An assigned act: which need it serves, who holds it, and for how long.
(define (slot-key s)    (list-ref s 0))
(define (slot-need s)   (list-ref s 1))
(define (slot-worker s) (list-ref s 2))
(define (slot-hours s)  (list-ref s 3))

(define* (assign-plan-slots candidates
                            #:key (atoms-of (lambda (need hours) 1))
                                  (rank (lambda (worker need slot) 0))
                                  (eligible? (lambda (worker need slot) #t))
                                  (tilt (lambda (worker need peers) 0.0)))
  "CANDIDATES is `plan->work`'s third value: ((need-id . ((worker share offer-id) …)) …).

   ATOMS-OF (need hours) → how many indivisible acts this need is, or 0 for
   work that divides. ZERO MEANS NOT A ROTA'S BUSINESS: the need keeps the
   fractional commitments the plan already made, because forcing one name onto
   a week of divisible work would be less true, not more. So one function
   answers both questions — whether this is assigned at all, and into how many
   acts — and they cannot drift apart. `whole-atoms-of` (the engine) is the
   answer built from `declare-whole!` and the recipes; the default of 1 treats
   every need as a single act, for a caller that has already filtered.

   RANK (worker need slot) → higher is proposed first. It orders a producer's
   OWN proposals, so it decides what someone reaches for, not who wins it.

   TILT (worker need peers) → in [−1, 1], bends the voice that DOES decide a contested
   act: voice = share × (1 + tilt). This is where rotation acts (see
   plan/rotation.scm) — the plan's grant stays primary and history bends it.
   At −1 a person is quiet rather than silent: they lose ties and still take the
   work if nobody else can.

   → a list of assigned acts, `slot-*` accessors above. Unfilled acts are
   absent rather than assigned to nobody: a rota with a hole in it is a fact
   the scope needs, not an error to swallow."
  (append-map
   (lambda (entry)
     (let* ((need   (car entry))
            (field  (cdr entry))
            (hours  (fold (lambda (c a) (+ a (cadr c))) 0.0 field))
            (n      (inexact->exact (round (atoms-of need hours)))))
       (if (<= n 0) '()                      ; divisible — leave it to the plan
     (let* ((each   (/ hours n))                     ; hours in one act
            (slots  (map (lambda (i) (format #f "~a#~a" need i)) (iota n)))
            (peers  (map car field))          ; who is in contention for this need
            (share  (lambda (w)
                      (let ((c (find (lambda (c) (equal? w (car c))) field)))
                        (if c (cadr c) 0.0))))
            ;; The plan's grant, in whole acts. Floored at one: a share smaller
            ;; than a single act is still a share, and rounding it to zero would
            ;; drop from the rota exactly the people the plan gave least to.
            (cap    (lambda (w) (max 1 (inexact->exact (round (/ (share w) (max each 1e-9)))))))
            (asg    (assign-slots slots peers
                                  #:capacity cap
                                  #:eligible? (lambda (w s) (eligible? w need s))
                                  #:rank (lambda (w s) (rank w need s))
                                  ;; the tie goes to whoever the plan granted
                                  ;; most, so the whole answer tracks the
                                  ;; fractional one it is standing in for —
                                  ;; bent, but never overruled, by the tilt
                                  #:voice (lambda (w)
                                            (* (share w)
                                               (+ 1.0 (max -1.0 (min 1.0 (tilt w need peers)))))))))
       (map (lambda (kv) (list (car kv) need (cdr kv) each)) asg)))))
   candidates))
