;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; plan/rotation.scm — taking turns, as a policy over what has already been done.
;;;
;;; EMP equalises each person's share of the TIME THEY OFFER, inside one plan.
;;; Rotation equalises each person's share of EACH KIND OF WORK, across plans.
;;; They are the same principle — equal standing — applied to two different
;;; quantities, and rotation completes EMP rather than competing with it.
;;;
;;; ── why it is not needed until assignments are whole ────────────────────────
;;; Under divisible labour the question does not arise: the plan's projection
;;; splits every need pro-rata across everyone who could serve it, so each
;;; person already holds a proportional slice of every task and nobody waits for
;;; a turn. Rotation becomes meaningful exactly when that answer stops being
;;; enactable — when one person carries the bin down (plan/assignment.scm)
;;; — because a sequence of whole assignments can be perfectly EMP-fair every
;;; week and still hand the same person the same task forever. Equal hours,
;;; unequal lives.
;;;
;;; ── why it lives HERE and not in the solve ──────────────────────────────────
;;; The solve cannot express it. `*worker-pref*` is keyed on (worker . skill),
;;; and a household's tasks all draw one skill — so a preference can say "Ada
;;; would rather not clean" but never "Ada cleaned last week, let someone else".
;;; Within a skill the plan holds ONE labour pool; two tasks drawing it are
;;; indistinguishable to it. The matching layer is the first place the tasks
;;; have separate names, and the first place the acts are discrete, which are
;;; the two things rotation needs.
;;;
;;; ── how it acts, and how far ───────────────────────────────────────────────
;;; Through VOICE, not rank. In `assign-slots` a producer's `rank` only orders
;;; their own proposals; when everyone can do everything, `voice` is what
;;; decides who wins a contested slot. So rotation is a tilt ON voice, bounded
;;; to [-1, 1] and applied multiplicatively to the share the plan granted:
;;;
;;;     voice = share × (1 + tilt)
;;;
;;; The plan's grant stays primary and the tilt bends it. Somebody who has done
;;; more than their share of a task is quieter for that task next time; somebody
;;; who has done less is louder; and as the shares converge the tilt goes to
;;; zero on its own — the shape of EMP's own quadratic, applied to history
;;; instead of to this week. It cannot silence anyone: at tilt = −1 voice is 0,
;;; which loses ties but still takes the work if nobody else can.
;;;
;;; FAIR SHARE is proportional to what each person offers, for the same reason
;;; EMP equalises fractions rather than totals: someone who offers half the time
;;; owes half of every task, not the same number of turns.

(define-module (playnet plan rotation)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet vf facts work-ids) #:select (work-intent-id-terms))
  #:export (rotation-tilt task-of-need rotation-shares burden-from-prefs))

;;; ── WHAT COUNTS AS THE SAME WORK, AND WHAT A TURN COSTS ─────────────────────
;;; Two knobs below open the readings this file does not choose between, and
;;; both default to today's behaviour so choosing nothing changes nothing.
;;;
;;; CLASS-OF says which turns are commensurable — which tally a turn lands in.
;;; Defaulting to the task gives a separate memory per task: even on bins and
;;; uneven on bathrooms passes unnoticed, because assigning a bin run consults
;;; only bin history. A coarser function pools them, and then extra bathrooms
;;; earn you fewer bin runs. The engine cannot supply that grouping: a work flow
;;; carries `classified-as` (VF's own field, unused by every recipe we have
;;; written so far) and the compiler drops it, so the RECIPE is where a scope
;;; says these two are the same kind of work, and the caller passes it here.
;;;
;;; BURDEN says what a turn COSTS THE PERSON TAKING IT, and changes what is
;;; being equalised from turns to something nearer satisfaction. Equal turns is
;;; only fair if a turn weighs the same on everyone, and it does not: somebody
;;; who minds the bins little is not owed relief from them. Weight each turn by
;;; that person's own declared reluctance and the tally measures what the work
;;; took out of them, so equalising it hands the task to whoever minds least
;;; without ever exempting them — they still accrue, just more slowly.
;;;
;;; That also answers a question this file could not: whether rotation OVERRIDES
;;; a declared preference. With burden it does not compete with preference, it
;;; READS it — preference becomes the exchange rate rather than a rival tilt.

;;; A need is named `ni|process|skill|cell` by the engine, and the CELL carries
;;; the period — so a need id never repeats across weeks and is useless as a
;;; memory. What repeats is the PROCESS: this week's bin run and last week's are
;;; the same task. Callers whose ids are shaped otherwise pass their own.
(define (task-of-need need)
  "The repeating task inside a located need id."
  (or (let ((t (work-intent-id-terms need))) (and t (assq-ref t 'subject))) need))

(define (alist-add al key amount)
  "AL with AMOUNT added to KEY's running total. Rebuilds rather than mutates:
   the caller's history is not ours to write on, and a shared tail is exactly
   the kind of thing that survives one call and surprises the next."
  (cons (cons key (+ amount (or (assoc-ref al key) 0)))
        (filter (lambda (p) (not (equal? key (car p)))) al)))

(define* (rotation-shares history #:key (task-of task-of-need) (class-of #f))
  "HISTORY ((worker task-or-need . amount) …) → ((task . ((worker . amount) …)) …).
   Two nested tallies, so it reads as the two questions it answers: which task,
   and then whose."
  (let ((task-of (or class-of task-of)))
   (fold (lambda (h acc)
          (let ((task (task-of (cadr h))))
            (cons (cons task (alist-add (or (assoc-ref acc task) '()) (car h) (cddr h)))
                  (filter (lambda (p) (not (equal? task (car p)))) acc))))
        '() history)))

(define* (rotation-tilt history #:key (weights '()) (task-of task-of-need)
                                     (class-of #f) (burden (lambda (worker class) 1.0))
                                     (strength 1.0))
  "A tilt on VOICE from what has already been done.

   HISTORY  ((worker task . amount) …) — cumulative, in whatever unit the caller
            counts turns in (acts, or hours; only ratios are read).
   WEIGHTS  ((worker . offered) …) — fair share is proportional to this. Absent
            or unlisted ⇒ weight 1, i.e. everyone owes the same share.
   STRENGTH scales the tilt; 0 disables rotation without removing it.

   → (worker need peers) → tilt in [−1, 1]: negative for someone above their
   share of that task, positive for someone below, zero once they are even or
   when the task has no history to go on.

   PEERS is who is actually in contention for this act, and the fair share is
   computed against THEM. It has to be passed in: a share is only fair relative
   to the people it is shared with, and history alone cannot supply that — a
   task nobody but Ada has ever done gives a peer set of {Ada}, against which
   Ada is trivially even and would never be relieved of it. That was a real bug
   this file's own test caught."
  (let* ((class-of (or class-of task-of))
         (shares (rotation-shares history #:task-of class-of)))
    (lambda* (worker need #:optional (peers '()))
      (let* ((task (class-of need))
             (done (or (assoc-ref shares task) '()))
             ;; a turn weighs what it cost the person who took it
             (total (fold (lambda (p a) (+ a (* (burden (car p) task) (cdr p)))) 0.0 done)))
        (if (<= total 0.0) 0.0
            (let* ((mine (* (burden worker task) (or (assoc-ref done worker) 0.0)))
                   ;; whoever is in contention, else everyone who has ever done
                   ;; it — and the asker either way, since a newcomer's fair
                   ;; share is not zero
                   (people (delete-duplicates
                            (cons worker (if (pair? peers) peers (map car done)))))
                   (w-of (lambda (p) (or (assoc-ref weights p) 1.0)))
                   (wsum (fold (lambda (p a) (+ a (w-of p))) 0.0 people))
                   (fair (if (> wsum 0.0) (* total (/ (w-of worker) wsum)) 0.0))
                   ;; normalised deviation: −1 when you have done all of it and
                   ;; owed none, +1 when you owe a full share and have done none
                   (dev (/ (- fair mine) (max fair mine 1e-9))))
              (max -1.0 (min 1.0 (* strength dev)))))))))

;;; ── where BURDEN comes from ─────────────────────────────────────────────────
;;; A turn's cost is the taker's own declared reluctance, and the engine already
;;; has that vocabulary: `set-worker-pref!` records π per (worker, skill) —
;;; negative eager, positive reluctant, zero neutral — read by the solve as a
;;; tilt on the labour it charges them. This reads the SAME declaration for a
;;; different purpose, so a scope states how it feels about a kind of work once.
;;;
;;; The keys need not be skills. `*worker-pref*` is keyed (worker . skill),
;;; which is one level coarser than the class a rota wants — the same coarseness
;;; that kept rotation out of the solve. Where a scope classifies its work flows
;;; (VF's `classified-as`, which the recipes carry and the compiler drops), it
;;; declares preferences against those classes instead and passes them here; the
;;; two line up exactly when a class IS a skill, which is the unclassified case.
;;;
;;; π → weight is 1 + π, floored: reluctance makes a turn weigh more, eagerness
;;; less, and neutral leaves it at 1 so an undeclared preference changes nothing.
;;; The floor is what keeps eagerness from becoming exemption — at any declared
;;; enthusiasm a turn still costs something, so somebody who loves the work
;;; still accrues and is still, eventually, relieved of it. Nobody volunteers
;;; their way into doing all of it forever.
(define* (burden-from-prefs prefs #:key (floor 0.25))
  "PREFS ((worker class . π) …) — π negative eager, positive reluctant.
   → (worker class) → what one turn of that class costs that person."
  (lambda (worker class)
    (let ((p (find (lambda (e) (and (equal? worker (car e)) (equal? class (cadr e)))) prefs)))
      (max floor (+ 1.0 (if p (cddr p) 0.0))))))
