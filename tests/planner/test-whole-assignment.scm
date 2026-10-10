;;; test-whole-assignment.scm — atomic work gets whole people.
;;;
;;; The convex plan works in DIVISIBLE hours, and that is right: it is deciding
;;; how much of everyone's time the week needs, and hours divide. But its
;;; projection to ValueFlows then splits each need pro-rata across every worker
;;; who could do it, so one 0.3 h bin run comes back as ten commitments of
;;; 0.032 h — ten people each doing a tenth of carrying one bin down.
;;;
;;; Nothing in ValueFlows forbids that: `Commitment.satisfies` is defined as "an
;;; intent satisfied fully or PARTIALLY", and the spec's own matching picture is
;;; many-to-many. But the same page says flows in a Plan are "operational,
;;; defined at the lowest level", and a tenth of a bin run is not operational.
;;; One-to-one is a discipline we impose, not one the spec hands us.
;;;
;;; The pieces to impose it already existed and had never been joined:
;;;   · `plan->work` publishes a CANDIDATE FIELD — per need, every worker who
;;;     could serve it and their share — documented as "the offer set, not one
;;;     provider". It is the offer; nothing collapsed it to an assignment.
;;;   · `deferred-acceptance` matches capacity-1 slots to named producers.
;;;   · `assign-slots` (added with this test) is the many-to-one reduction that
;;;     lets one person hold several slots, lifted out of the one call site that
;;;     had hand-rolled it.
;;;
;;; So the composition is: the plan decides HOW MUCH each person works, and the
;;; matching decides WHICH acts are theirs — the plan's own share becomes their
;;; capacity in whole runs, so the whole-number assignment carries out what the
;;; fractional one intended.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-whole-assignment.scm

(use-modules (playnet test harness)
             (playnet algorithms deferred-acceptance)
             (playnet plan assignment)
             (srfi srfi-1))
(use-modules (playnet solve engine)
             (playnet solve solver)
             (playnet vf schemas)
             (ice-9 format))
(set! *backend* 'native-c)

(define HOURS-PER-RUN 0.3)               ; one bin run

(define (plan n-people runs)
  "Solve for RUNS bin runs against N-PEOPLE, and return the candidate field:
   ((need-id . ((worker share offer-id) …)) …) — the OFFER, per need."
  (declare-world! #:places '("flat")
                  #:templates (list (list "binrun" '(("binsdone" . 1.0)) '() HOURS-PER-RUN))
                  #:workers
                    (map (lambda (i) (list (format #f "p~a" i) '("cleaning") "flat@0" 20.0))
                         (iota n-people 1)))
  (hash-set! *proc-skill* "binrun" "cleaning")
  (hash-set! *demand* (lg "binsdone" "flat@0") runs)
  (call-with-values build-located
    (lambda (forms lf ncol cols goods raws idx)
      (let ((x (call-with-values (lambda () (solve forms lf (located-warm cols ncol idx)))
                 (lambda (x . _) x))))
        (call-with-values (lambda () (plan->work x cols idx))
          (lambda (ints coms cands) (list ints coms cands)))))))

;;; ── the defect, stated as a measurement ──────────────────────────────────────
(display "\n── one atomic run, ten people who could do it ──\n")
(define p10 (plan 10 1.0))
(define coms10 (cadr p10))
(define needs10 (filter (lambda (i) (not (intent-provider i))) (car p10)))

(format #t "    need intents : ~a\n" (length needs10))
(format #t "    commitments  : ~a  (each ~,4f h of a ~,2f h run)\n"
        (length coms10)
        (measure-has-numerical-value (commitment-effort-quantity (car coms10)))
        HOURS-PER-RUN)
(check "the plan states the need once" (= 1 (length needs10)))
(check "…and the pro-rata projection answers it with one commitment per worker"
       (= 10 (length coms10)))
(check "…none of which is a whole run — nobody carries the bin down"
       (every (lambda (c) (< (measure-has-numerical-value (commitment-effort-quantity c))
                             (* 0.9 HOURS-PER-RUN)))
              coms10))

;;; ── the composition ─────────────────────────────────────────────────────────
;;; `assign-plan-slots` (plan/assignment.scm) is the whole of it: the
;;; candidate field in, a rota out. It is a separate act rather than a mode on
;;; the solve — the engine has no project dependencies to spend on a matcher,
;;; plan-from-records already carries 37 keywords and this one would change what
;;; the returned commitments MEAN, and who turns an offer into an assignment is
;;; the scope's question, not the solver's. See that file's header.

(display "\n── the same need, matched to whole people ──\n")
(define asg10 (map (lambda (s) (cons (slot-key s) (slot-worker s)))
                   (assign-plan-slots (caddr p10) #:atoms-of (lambda (n h) 1))))
(format #t "    slots ~a → ~s\n" (length asg10) asg10)
(check "one atomic run becomes ONE slot" (= 1 (length asg10)))
(check "…held by exactly one named person"
       (and (= 1 (length (delete-duplicates (map cdr asg10))))
            (string-prefix? "p" (cdar asg10))))

;;; ── several acts, and the plan's share is what bounds each person ───────────
(display "\n── five runs, three people ──\n")
(define p3 (plan 3 5.0))
(define asg3 (map (lambda (s) (cons (slot-key s) (slot-worker s)))
                  (assign-plan-slots (caddr p3) #:atoms-of (lambda (need hours) 5))))
(define counts
  (map (lambda (w) (cons w (length (filter (lambda (kv) (equal? w (cdr kv))) asg3))))
       (delete-duplicates (map cdr asg3))))
(format #t "    ~s\n" (sort asg3 (lambda (a b) (string<? (car a) (car b)))))
(format #t "    per person: ~s\n" counts)
(check "every run is assigned" (= 5 (length asg3)))
(check "every run has exactly one owner"
       (= 5 (length (delete-duplicates (map car asg3)))))
(check "the work is shared — nobody does all five"
       (every (lambda (c) (< (cdr c) 5)) counts))
(check "…and nobody is given more of the week than the plan granted them"
       (every (lambda (c) (<= (cdr c) 3)) counts))

;;; ── what this does NOT decide ───────────────────────────────────────────────
;;; Which of three equally-placed people takes the fifth run is arbitrary here,
;;; and deliberately so: inside ONE plan they are indistinguishable, and the
;;; matcher has no memory. Making that choice fair is rotation's job — it enters
;;; through `assign-slots`'s own `rank`, the hook `deferred-acceptance` has
;;; carried unused since it was written (every call site passes #f), and which
;;; means "worked here before ⇒ preferred" until its sign is flipped.
(display "\n── the seam rotation will use ──\n")
(define asg-rot
  (let* ((cands (caddr p3))
         (field (cdr (car cands)))
         (slots (map (lambda (i) (format #f "run~a" i)) (iota 5))))
    ;; a rank that PUSHES AWAY the person who has done it most — rotation, in one
    ;; function, with no new machinery anywhere
    (assign-slots slots (map car field)
                  #:capacity (lambda (w) 5)
                  #:rank (lambda (w s) (if (equal? w "p1") -1 0))
                  #:voice (lambda (w) (if (equal? w "p1") 0 1)))))
(format #t "    p1 marked as having done it already → ~s\n" asg-rot)
(check "a rank/voice tilt moves the work off the person who has done it"
       (< (length (filter (lambda (kv) (equal? "p1" (cdr kv))) asg-rot)) 5))


;;; ── what the rota covers is DECLARED, not guessed ───────────────────────────
;;; `declare-whole!` already names "the acts that happen a whole number of
;;; times". That is the same question a rota asks, so `whole-atoms-of` answers
;;; both from it: how many acts a need is, and — by answering ZERO — whether it
;;; is a rota's business at all. Divisible work keeps the fractional commitments
;;; the plan made for it, because a week of farming with one name on it would be
;;; less true, not more.
(display "\n── declare-whole! decides what the rota covers ──\n")
(define (mixed-plan)
  (declare-world! #:places '("flat")
                  #:templates
                    (list (list "binrun" '(("binsdone" . 1.0)) '() HOURS-PER-RUN)
                          (list "farm"   '(("crop" . 1.0))     '() 2.0))
                  #:workers
                    (map (lambda (i) (list (format #f "p~a" i) '("cleaning") "flat@0" 20.0))
                         (iota 3 1)))
  (hash-set! *proc-skill* "binrun" "cleaning") (hash-set! *proc-skill* "farm" "cleaning")
  (hash-set! *demand* (lg "binsdone" "flat@0") 3.0)
  (hash-set! *demand* (lg "crop" "flat@0") 2.0)
  (declare-whole! "binrun")                      ; the bins are whole acts; farming is not
  (call-with-values build-located
    (lambda (forms lf ncol cols goods raws idx)
      (let ((x (call-with-values (lambda () (solve forms lf (located-warm cols ncol idx)))
                 (lambda (x . _) x))))
        (call-with-values (lambda () (plan->work x cols idx))
          (lambda (i c cands) cands))))))

(define mixed (mixed-plan))
(define rota (assign-plan-slots mixed #:atoms-of (whole-atoms-of)))
(format #t "    needs offered : ~a\n" (length mixed))
(for-each (lambda (s) (format #t "    ~a → ~a (~,3f h)\n" (slot-key s) (slot-worker s) (slot-hours s))) rota)
(check "the plan offers both needs" (= 2 (length mixed)))
(check "the WHOLE process becomes one act per run, each with one owner"
       (and (= 3 (length rota))
            (= 3 (length (delete-duplicates (map slot-worker rota))))
            (every (lambda (s) (string-contains (slot-need s) "binrun")) rota)))
(check "…each act is one run's worth of work"
       (every (lambda (s) (< (abs (- (slot-hours s) HOURS-PER-RUN)) 0.05)) rota))
(check "the DIVISIBLE process is left to the plan — absent, not assigned"
       (not (any (lambda (s) (string-contains (slot-need s) "farm")) rota)))

(test-summary!)
