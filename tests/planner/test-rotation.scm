;;; test-rotation.scm — taking turns, over a sequence of whole assignments.
;;;
;;; One bin run a week. Three people who could all do it. The plan is EMP-fair
;;; every single week — everyone is granted the same share of their offered time
;;; — and yet, once the run is assigned to ONE person (which is the only way a
;;; bin actually goes down), the same person can carry it every week forever.
;;; Equal hours, unequal lives. That gap is what rotation closes, and it cannot
;;; be closed inside a single solve: no plan can see last week.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-rotation.scm

(use-modules (playnet test harness)
             (playnet planner plan assignment)
             (playnet planner plan rotation)
             (srfi srfi-1))

;;; The offer a week's plan makes: one need, three equally-granted people.
;;; (Taken in this shape rather than re-solving each week because the point is
;;; what happens ACROSS solves; test-whole-assignment already proves this field
;;; is what the planner really emits.)
(define (weekly-offer people share)
  (list (cons "ni|binrun|cleaning|flat@0"
              (map (lambda (p) (list p share (string-append "oi|" p))) people))))

(define PEOPLE '("ada" "bo" "kit"))

(define* (run-weeks n #:key (rotate? #t) (weights '()))
  "Assign the week's bin run N times, feeding each week's result back as
   history. → ((worker . turns) …)"
  (let loop ((week 0) (history '()))
    (if (= week n)
        (map (lambda (p)
               (cons p (fold (lambda (h a) (if (equal? p (car h)) (+ a (cddr h)) a)) 0 history)))
             PEOPLE)
        (let* ((offer (weekly-offer PEOPLE 0.3))
               (tilt (if rotate?
                         (rotation-tilt history #:weights weights)
                         (lambda (w need peers) 0.0)))
               (asg (assign-plan-slots offer #:tilt tilt))
               (who (slot-worker (car asg))))
          (loop (+ week 1)
                (cons (cons who (cons "ni|binrun|cleaning|flat@0" 1)) history))))))

(display "\n── six weeks, no rotation: an EMP-fair plan, and one person's bins ──\n")
(define plain (run-weeks 6 #:rotate? #f))
(format #t "    ~s\n" plain)
(check "without rotation the same person takes it every week"
       (= 6 (apply max (map cdr plain))))

(display "\n── six weeks, rotation on ──\n")
(define rota (run-weeks 6))
(format #t "    ~s\n" rota)
(check "with rotation everybody takes a turn"
       (every (lambda (p) (> (cdr p) 0)) rota))
(check "…and the turns come out even over six weeks"
       (= 2 (apply max (map cdr rota)) (apply min (map cdr rota))))

;;; ── the tilt is a tilt, not a rule ─────────────────────────────────────────
;;; Fair share follows what each person OFFERS, for the same reason EMP
;;; equalises fractions: somebody who offers half the time owes half of every
;;; task, not the same number of turns.
(display "\n── unequal offers: fair share follows what you can give ──\n")
(define weighted (run-weeks 6 #:weights '(("ada" . 2.0) ("bo" . 1.0) ("kit" . 1.0))))
(format #t "    ada offers double → ~s\n" weighted)
(check "the person who offers most takes most turns"
       (> (assoc-ref weighted "ada") (assoc-ref weighted "bo")))
(check "…and still not all of them — a tilt, not a rule"
       (< (assoc-ref weighted "ada") 6))

;;; ── it settles ─────────────────────────────────────────────────────────────
;;; The tilt is the normalised deviation from fair share, so it goes to zero as
;;; the shares converge: rotation stops pushing once the work is even, which is
;;; the shape of EMP's own quadratic applied to history.
(display "\n── the tilt goes to zero when the shares are level ──\n")
(let* ((even-history (append-map (lambda (p) (list (cons p (cons "binrun" 2)))) PEOPLE))
       (t (rotation-tilt even-history)))
  (format #t "    tilts at parity: ~s\n" (map (lambda (p) (t p "ni|binrun|cleaning|flat@0" PEOPLE)) PEOPLE))
  (check "nobody is pushed when everybody has done the same"
         (every (lambda (p) (< (abs (t p "ni|binrun|cleaning|flat@0" PEOPLE)) 1e-9)) PEOPLE)))

(let* ((lopsided (list (cons "ada" (cons "binrun" 6))))
       (t (rotation-tilt lopsided)))
  (format #t "    after ada does six: ada ~,3f · bo ~,3f\n"
          (t "ada" "ni|binrun|cleaning|flat@0" PEOPLE) (t "bo" "ni|binrun|cleaning|flat@0" PEOPLE))
  (check "the one who has done it is quieted, the one who has not is raised"
         (and (< (t "ada" "ni|binrun|cleaning|flat@0" PEOPLE) 0.0)
              (> (t "bo"  "ni|binrun|cleaning|flat@0" PEOPLE) 0.0))))

;;; ── memory is per TASK, not per located need ───────────────────────────────
;;; A need id carries its cell, and the cell carries the period — so it never
;;; repeats. What repeats is the process: this week's bin run and last week's
;;; are the same task, and rotation is only meaningful because they are.
(display "\n── the memory keys on the task, not the week ──\n")
(check "two different weeks of the same run are one task"
       (equal? (task-of-need "ni|binrun|cleaning|flat@0")
               (task-of-need "ni|binrun|cleaning|flat@6")))
(check "…and a different task is a different memory"
       (not (equal? (task-of-need "ni|binrun|cleaning|flat@0")
                    (task-of-need "ni|bathroom|cleaning|flat@0"))))


;;; ── the two readings this file does not choose between ──────────────────────
(display "\n── commensurable work: one tally or several ──\n")
;; ada has done four bathrooms, bo four bins. PER TASK they are each even with
;; nobody — separate memories. POOLED (a class-of that calls both "chores")
;; they are level with each other, and a third person owes both.
(define mixed (list (cons "ada" (cons "ni|bathroom|cleaning|flat@0" 4))
                    (cons "bo"  (cons "ni|binrun|cleaning|flat@0"  4))))
(define per-task (rotation-tilt mixed))
(define pooled   (rotation-tilt mixed #:class-of (lambda (need) "chores")))
(format #t "    per task — ada asked for a bin run: ~,3f  (her bathrooms are invisible)\n"
        (per-task "ada" "ni|binrun|cleaning|flat@0" PEOPLE))
(format #t "    pooled   — ada asked for a bin run: ~,3f  (they count)\n"
        (pooled "ada" "ni|binrun|cleaning|flat@0" PEOPLE))
(check "per task, work done elsewhere does not earn you a lighter turn here"
       (> (per-task "ada" "ni|binrun|cleaning|flat@0" PEOPLE) 0.0))
(check "pooled, it does — ada is no longer owed a bin run over kit"
       (< (pooled "ada" "ni|binrun|cleaning|flat@0" PEOPLE)
          (pooled "kit" "ni|binrun|cleaning|flat@0" PEOPLE)))

(display "\n── what a turn COSTS: equal turns, or equal satisfaction ──\n")
;; ada and bo have each taken three bin runs. ada does not mind them; bo does.
;; Counting turns they are even. Weighting each turn by what it cost the person
;; who took it, bo has given more — so the next one goes to ada.
(define even-turns (list (cons "ada" (cons "ni|binrun|cleaning|flat@0" 3))
                         (cons "bo"  (cons "ni|binrun|cleaning|flat@0" 3))))
(define by-count (rotation-tilt even-turns))
(define by-cost  (rotation-tilt even-turns
                                #:burden (lambda (w class) (if (equal? w "bo") 2.0 0.5))))
(format #t "    counting turns  — ada ~,3f · bo ~,3f\n"
        (by-count "ada" "ni|binrun|cleaning|flat@0" '("ada" "bo"))
        (by-count "bo"  "ni|binrun|cleaning|flat@0" '("ada" "bo")))
(format #t "    counting cost   — ada ~,3f · bo ~,3f  (bo minds it more)\n"
        (by-cost "ada" "ni|binrun|cleaning|flat@0" '("ada" "bo"))
        (by-cost "bo"  "ni|binrun|cleaning|flat@0" '("ada" "bo")))
(check "by turns the two are even and neither is pushed"
       (and (< (abs (by-count "ada" "ni|binrun|cleaning|flat@0" '("ada" "bo"))) 1e-9)
            (< (abs (by-count "bo"  "ni|binrun|cleaning|flat@0" '("ada" "bo"))) 1e-9)))
(check "by cost the one who minds it is relieved and the one who does not takes more"
       (and (> (by-cost "ada" "ni|binrun|cleaning|flat@0" '("ada" "bo")) 0.0)
            (< (by-cost "bo"  "ni|binrun|cleaning|flat@0" '("ada" "bo")) 0.0)))
(check "…and preference is READ, not overridden — it never exempts anyone"
       (> (by-cost "bo" "ni|binrun|cleaning|flat@0" '("ada" "bo")) -1.0))


;;; ── burden read off the declarations a scope already makes ──────────────────
(display "\n── burden from declared preferences ──\n")
(define prefs '(("bo" "binrun" . 1.0)      ; bo minds the bins
                ("ada" "binrun" . -0.5)))  ; ada does not
(define b (burden-from-prefs prefs))
(format #t "    a turn costs: ada ~,2f · bo ~,2f · kit ~,2f (undeclared)\n"
        (b "ada" "binrun") (b "bo" "binrun") (b "kit" "binrun"))
(check "reluctance makes a turn weigh more, eagerness less"
       (and (< (b "ada" "binrun") 1.0) (> (b "bo" "binrun") 1.0)))
(check "an undeclared preference changes nothing"
       (= 1.0 (b "kit" "binrun")))
(check "eagerness is never exemption — a turn always costs something"
       (> (b "ada" "binrun") 0.0))

;; and it composes: three turns each, ada eager and bo reluctant → ada next
(define by-pref (rotation-tilt (list (cons "ada" (cons "ni|binrun|cleaning|flat@0" 3))
                                     (cons "bo"  (cons "ni|binrun|cleaning|flat@0" 3)))
                               #:burden b))
(format #t "    after three each — ada ~,3f · bo ~,3f\n"
        (by-pref "ada" "ni|binrun|cleaning|flat@0" '("ada" "bo"))
        (by-pref "bo"  "ni|binrun|cleaning|flat@0" '("ada" "bo")))
(check "the declaration alone moves the next turn to the one who minds least"
       (and (> (by-pref "ada" "ni|binrun|cleaning|flat@0" '("ada" "bo")) 0.0)
            (< (by-pref "bo"  "ni|binrun|cleaning|flat@0" '("ada" "bo")) 0.0)))

(test-summary!)
