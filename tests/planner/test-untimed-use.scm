;;; test-untimed-use.scm — a run occupies a means for as long as the run takes.
;;;
;;; A `use` states two things: how many are engaged, and for how long. When it omits
;;; the second, something has to supply it, and the choice decides whether a plan is
;;; a fact about the world or about the lattice.
;;;
;;; Reading the PERIOD's length is the reading that fails. An untimed use then means
;;; "occupies the means for the whole period", so refining a day into thirds lets
;;; three times as many runs fit — each still yielding ONE output. A finer lattice
;;; manufactures product from nothing. Measured before this changed: three ovens
;;; supported 3 runs over an undivided day and 9 over the same day in thirds.
;;;
;;; Reading the PROCESS's own `has-duration` is the reading that holds. A bake takes
;;; forty minutes whether the scope keeps its books in days or in hours, so the
;;; number holds still while the partition moves — and it is already declared, on the
;;; RecipeProcess, so nothing new has to be said.
;;;
;;; What remains partition-dependent is a process that states NO length anywhere:
;;; neither on the flow nor on itself. That recipe has not said how long anything
;;; takes, and the fallback is the old reading — visible here rather than hidden.
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-untimed-use.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner solve compile)
             (playnet planner vf schemas)
             (playnet planner knowledge dsl shorthand))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(define (near? a b) (< (abs (- a b)) 0.001))

(define PLACE "b")
(define (res id spec qty unit) (er id spec #f #:place PLACE #:qty qty #:unit unit))

;;; One process: `use` an oven, produce a loaf. FLOW-HOURS states the draw's own
;;; duration (#f to omit it); PROC-HOURS is the process's has-duration (#f for none).
(define (recipe flow-hours proc-hours)
  (let ((procs (list (rp* "bake" "Bake" proc-hours)))
        (flows (list (use* "f-use" "oven" "bake" flow-hours #:qty 1.0)
                     (out* "f-out" "loaf" 1.0 "bake" "each" #:primary #f))))
    (compile-recipe procs flows)))

;;; The plan's real question: how many runs can the oven support over the span? That
;;; is Σ_t cap(t)/draw(t) — capacity divided by what one run costs there.
(define (max-runs spans flow-hours proc-hours holding)
  (declare-world! #:periods (iota (length spans)))
  (for-each (lambda (t sp) (set-period-span! t (car sp) (cdr sp))) *periods* spans)
  (set-templates! (recipe flow-hours proc-hours))
  (ingest-stock! (list holding))
  (let ((tpl (car *templates*)))
    (fold + 0.0
          (map (lambda (t)
                 (let* ((cap  (hash-ref *cap* (lg (svc-good "oven") (cell PLACE t)) 0.0))
                        (coef (assoc-ref (proc-inputs tpl) (svc-good "oven")))
                        (draw (* coef (svc-hours-factor (svc-good "oven") tpl t))))
                   (if (> draw 0.0) (/ cap draw) 0.0)))
               *periods*))))

(define ONE   '(("2026-03-03" . "2026-03-03")))
(define THREE '(("2026-03-03T00:00" . "2026-03-03T08:00")
                ("2026-03-03T08:00" . "2026-03-03T16:00")
                ("2026-03-03T16:00" . "2026-03-04T00:00")))

(define (invariant? label flow-hours proc-hours holding)
  (let ((a (max-runs ONE flow-hours proc-hours holding))
        (b (max-runs THREE flow-hours proc-hours holding)))
    (format #t "    ~a: undivided ~,2f runs · in thirds ~,2f runs~%" label a b)
    (and (near? a b) a)))

(define ovens (res "r" "oven" 3.0 "each"))
(define network (res "r" "oven" 200.0 "hours/day"))

(format #t "~%── 1. a flow that states its own duration ──~%~%")

(check "3 ovens, a half-hour bake: the same run count under any partition"
       (let ((n (invariant? "0.5 h stated on the flow" 0.5 #f ovens)))
         (and n (near? 144.0 n))))                 ; 72 oven-hours / 0.5 h

(format #t "~%── 2. a flow that states none, and a PROCESS that does ──~%~%")

;; This is the case that used to move. The process says a bake takes 0.5 h, so a run
;; occupies the oven for 0.5 h — the same answer as stating it on the flow.
(check "the process's has-duration supplies it, and the count holds still"
       (let ((n (invariant? "0.5 h stated on the process" #f 0.5 ovens)))
         (and n (near? 144.0 n))))
(check "…and it agrees with stating the same length on the flow"
       (near? (max-runs ONE #f 0.5 ovens) (max-runs ONE 0.5 #f ovens)))

;; …and for a RATE-denominated means too, where both sides had to move together
(check "a rate-held means behaves the same way"
       (let ((n (invariant? "200 hours/day, 0.5 h process" #f 0.5 network)))
         (and n (near? 400.0 n))))                 ; 200 h / 0.5 h

(format #t "~%── 3. a process that states no length at all ──~%~%")

;; Nothing has said how long a run takes, so the only length in scope is the
;; period's, and the run count moves with the partition. The recipe is what is
;; incomplete; the fallback keeps such a plan solvable and this test keeps it VISIBLE.
(let ((a (max-runs ONE #f #f ovens))
      (b (max-runs THREE #f #f ovens)))
  (format #t "    no duration anywhere: undivided ~,2f runs · in thirds ~,2f runs~%" a b)
  (check "with no stated length the period's is used, and the count moves"
         (and (near? 3.0 a) (near? 9.0 b)))
  (check "…which is exactly what a stated duration removes"
         (not (near? a b))))

(format #t "~%── 4. a non-time effort stays a plain multiplier ──~%~%")

;; An effort in some other unit is a count multiplier, not a duration — a `slot`
;; drawn against a channel stocked in slots. It must not be read as hours.
(declare-world! #:spans '((0 "2026-03-03" "2026-03-03"))
                #:templates
                  (compile-recipe
                    (list (rp* "post" "Post"))
                    (list (make-recipe-flow #:id "f-use" #:action 'use #:resource-conforms-to "channel" #:resource-quantity (make-measure 1.0 "each")
                                            #:effort-quantity (make-measure 2.0 "slot") #:recipe-input-of "post")
                          (out* "f-out" "reach" 1.0 "post" "each" #:primary #f))))
(check "a `slot` effort multiplies the count and is not taken for hours"
       (near? 2.0 (assoc-ref (proc-inputs (car *templates*)) (svc-good "channel"))))
(check "…and the spec is NOT marked as occupied for a stated length"
       (not (member "channel" (proc-timed-svc (car *templates*)))))


;;; ── 5. a worker's window and a machine's are read the same way ───────────────
;;; A declaration is a declaration: `06:00–10:00` means the same whether a person
;;; says it or an oven does. Read one exactly and the other as a weekday sum, and a
;;; refined partition inflates the person — a four-hour shift came back as four
;;; hours in EVERY period of the day it touched, twenty-four in total, so the plan
;;; matched hours that never meet (docs/planning/solve/intra-period-time.md opens on
;;; exactly this). Worse, the inflation GREW with the partition, which is the wrong
;;; direction for the thing refining it is for.
(format #t "~%── 5. an agent's window and a means' agree ──~%~%")

(define DAY-IN-FIVE '(("2026-03-03T00:00" . "2026-03-03T06:00")
                      ("2026-03-03T06:00" . "2026-03-03T10:00")
                      ("2026-03-03T10:00" . "2026-03-03T14:00")
                      ("2026-03-03T14:00" . "2026-03-03T18:00")
                      ("2026-03-03T18:00" . "2026-03-04T00:00")))
(declare-world! #:periods (iota (length DAY-IN-FIVE)))
(for-each (lambda (t sp) (set-period-span! t (car sp) (cdr sp)))
          *periods* DAY-IN-FIVE)
(define shift (all-week-window "06:00" "10:00"))
(define worker (person* "ada" #:name "Ada" #:place PLACE #:window shift))
(define machine (er "oven" "oven" #f #:place PLACE #:qty 1.0 #:unit "each" #:window shift))
(define agent-hrs (map (lambda (t) (agent-window-hours worker t)) *periods*))
(define means-hrs (map (lambda (t) (resource-window-hours machine t)) *periods*))
(format #t "    agent: ~a~%    means: ~a~%" agent-hrs means-hrs)
(check "the same declaration reads the same for a person and for a machine"
       (equal? agent-hrs means-hrs))
(check "a four-hour shift is four hours over the day, not four in every period"
       (near? 4.0 (fold + 0.0 agent-hrs)))
(check "…and it lands in the period that holds it"
       (and (near? 0.0 (car agent-hrs)) (near? 4.0 (cadr agent-hrs))))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — a run occupies a means for the run's own length,~%  and a person's declared hours land where they were declared.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
