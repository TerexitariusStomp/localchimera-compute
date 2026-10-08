;;; test-within-band-lead.scm — a chain's first unit must fit its band.
;;;
;;; A band holds no clock, so a dependent chain used to balance inside one
;;; whatever its length — measured (open-threads §3.1): three 10 h steps, three
;;; different workers, strictly sequential, and the plan committed 31 h of
;;; ordered work inside a 24 h day. Nothing objected, because no shared budget
;;; bound and ordering was nobody's constraint.
;;;
;;; The coherent reading is PIPELINE lead time: before any same-band output of C
;;; exists, one run of each unstocked same-cell upstream step must complete. A
;;; production column whose lead exceeds its band is not generated — the same
;;; idiom as raw-availability — so the plan reroutes through storage into the
;;; next band, which is the schedule that can actually happen. Run COUNTS stay
;;; free (parallel crews and batches are real); only the claim that a chain's
;;; first unit appears before it can exist is pruned.
;;;
;;; The chain resets where a claim ends: at a raw, at standing stock, at a
;;; storable in any band after the first, and at a run-spanning process (a run
;;; longer than the band — §3.1's recorded residual, no within-band claim).
;;; Only a stated has-duration claims anything, and only a period with a
;;; declared span prunes.
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-within-band-lead.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner solve compile)
             (playnet planner vf schemas)
             (playnet planner knowledge dsl shorthand))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define PLACE "shop")

;; A → B → C, each HRS hours of a DIFFERENT skill; strictly sequential (B eats
;; A's output, C eats B's). DURATIONS? #f leaves has-duration unstated.
(define (chain-procs durations?)
  (list (rp* "A" "Step A" (and durations? 10)) (rp* "B" "Step B" (and durations? 10))
        (rp* "C" "Step C" (and durations? 10))))
(define chain-flows
  (list (consume* "a-in" "raw" 1.0 "A") (out* "a-out" "mid1" 1.0 "A") (wk* "a-w" "skill-a" 10.0 "A")
        (consume* "b-in" "mid1" 1.0 "B") (out* "b-out" "mid2" 1.0 "B") (wk* "b-w" "skill-b" 10.0 "B")
        (consume* "c-in" "mid2" 1.0 "C") (out* "c-out" "final" 1.0 "C") (wk* "c-w" "skill-c" 10.0 "C")))

(define (held id spec q) (er id spec #f #:place PLACE #:qty q #:unit "kg"))
(define (skill id sk who) (er id sk who #:place PLACE #:unit "each"))
(define agents (map (lambda (n) (person* n #:place PLACE #:window (all-week-window "00:00" "24:00")))
                    '("ann" "ben" "cal")))
(define spatials (list (place* PLACE)))

;; solve and return the commitments: total hours, hours per skill, and the
;; hasBeginning dates each skill's work lands on
(define* (solve-chain #:key (days 1) (durations? #t) (stock '()) (demand-at 0))
  (call-with-values
    (lambda ()
      (plan-from-records
       (append (list (held "raw-1" "raw" 100.0)) stock
               (list (skill "s1" "skill-a" "ann") (skill "s2" "skill-b" "ben") (skill "s3" "skill-c" "cal")))
       agents spatials (chain-procs durations?) chain-flows
       #:horizon (cons "2026-03-03" days)
       #:storable '("mid1" "mid2" "final")
       #:agent-skills (lambda (a) (list (string-append "skill-" (substring (agent-id a) 0 1))))
       #:demand (list (cons (format #f "final#~a@~a" PLACE demand-at) 1.0))
       #:per-agent? #t #:backend 'native-c #:allow-infeasible? #t))
    (lambda args
      (let ((coms (or (find (lambda (v) (and (pair? v) (commitment? (car v)))) args) '()))
            (tot 0.0) (by-skill '()) (dates '()))
        (for-each (lambda (c)
                    (let ((h  (measure-has-numerical-value (commitment-effort-quantity c)))
                          (sk (commitment-resource-conforms-to c))
                          (d  (commitment-has-beginning c)))
                      (set! tot (+ tot h))
                      (set! by-skill (assoc-set! by-skill sk (+ h (or (assoc-ref by-skill sk) 0.0))))
                      (set! dates (cons (cons sk (and (string? d) (substring d 0 10))) dates))))
                  coms)
        (list tot by-skill dates)))))

(define (skill-hours r sk) (or (assoc-ref (cadr r) sk) 0.0))
(define (skill-date r sk) (assoc-ref (caddr r) sk))

(format #t "~%── §1 the measured case: a 30 h chain no longer fits a 24 h day ──~%")
(let ((r (solve-chain #:days 1)))
  (check "the chain's final step commits nothing inside one day"
         (< (skill-hours r "skill-c") 0.5))
  (check "no phantom 31 h of dependent work in a 24 h band"
         (< (car r) 25.0)))

(format #t "~%── §2 two bands: the plan reroutes through storage, and lands ──~%")
(let ((r (solve-chain #:days 2 #:demand-at 1)))
  (check "the final step now commits its 10 h" (> (skill-hours r "skill-c") 9.0))
  (check "the whole 30 h chain is committed"    (> (car r) 29.0))
  (check "the final step lands in the SECOND band"
         (equal? (skill-date r "skill-c") "2026-03-04")))

(format #t "~%── §3 standing stock resets the chain ──~%")
(let ((r (solve-chain #:days 1 #:stock (list (held "mid2-1" "mid2" 5.0)))))
  (check "with mid2 stocked, the final step runs in band one"
         (> (skill-hours r "skill-c") 9.0))
  (check "…and the upstream steps need not run at all"
         (< (+ (skill-hours r "skill-a") (skill-hours r "skill-b")) 21.0)))

(format #t "~%── §4 the boundary of the claim: no stated length, no pruning ──~%")
(let ((r (solve-chain #:days 1 #:durations? #f)))
  (check "a chain that states no lengths keeps today's behaviour (§3.2's residual)"
         (> (skill-hours r "skill-c") 9.0)))

(format #t "~%── §5 the silence is REPORTED: chain-duration-gaps names the opt-outs ──~%")
;; the same two chains, asked directly at the template level — the lint that
;; promotes §3.2 from a residual to authoring feedback
(declare-world! #:templates (compile-recipe (chain-procs #f) chain-flows))
(let ((gaps (chain-duration-gaps)))
  (check "a duration-less chain reports its chained steps (B and C, not A)"
         (equal? (sort (map car gaps) string<?) '("B" "C")))
  (check "…each naming the produced input it consumes without a stated length"
         (equal? (assoc-ref gaps "C") '("mid2"))))
(declare-world! #:templates (compile-recipe (chain-procs #t) chain-flows))
(check "a chain that states its lengths reports nothing"
       (null? (chain-duration-gaps)))

(format #t "~%~a passed, ~a failed~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
