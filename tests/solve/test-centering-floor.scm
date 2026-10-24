;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-centering-floor.scm — the barrier left standing at the path floor is
;;; FELT IN THE PLAN, and the knob that controls it must actually be connected.
;;;
;;; Spec: docs/social-category.typ §8 Obligation 3b; docs/localchimera.typ §7.9
;;;       ("a small free-time term rewards spending less total labour, so the
;;;       plan makes only what someone wants") and §7.11 (the duality gap μ "is
;;;       driven to zero").
;;;
;;; An interior-point method walks the barrier weight t down and stops at a
;;; floor. That floor is usually treated as an implementation detail. It is not:
;;; against a NON-BINDING wall the residual +t/x gradient is held off only by the
;;; free-time thrift κ·ℓ, so an activity settles near 2t/(κℓ) ABOVE its demand
;;; rather than at it. With t = 0.02, κ = 0.02 and ℓ = 0.1 h, a bakery asked for
;;; 5 loaves against abundant flour makes 16.
;;;
;;; That was invisible for two compounding reasons, both fixed here:
;;;   • `pk_meanfill` caps each good's fill at 1, so no reported metric can see
;;;     over-supply at all;
;;;   • the floor was written THREE times — a literal in kernel.c's pk_solve, two
;;;     literals in solve-native-core, and *kern-tmin* in planner.scm — so the
;;;     Scheme knob moved nothing and read as live while being inert.
;;;
;;; The two checks below are therefore: the knob is CONNECTED (changing it
;;; changes the plan), and at a tight floor the plan makes exactly what is
;;; wanted. If the constant is ever duplicated again, the first check fails.
;;;
;;; Run: guile tests/solve/… (discovered by tools/test/run-scm-tests.sh)

(use-modules (localchimera test planner prelude)
             (localchimera solve engine) (localchimera solve records) (localchimera solve world)
             (localchimera solve compile)
             (localchimera solve solver)
             (localchimera vf schemas)
             (srfi srfi-1)
             (ice-9 format))

(define (res spec loc q)
  (make-economic-resource #:id (string-append spec "@" loc) #:conforms-to spec #:classified-as '()
    #:accounting-quantity (make-measure q "kg") #:onhand-quantity (make-measure q "kg") #:current-location loc))
(define (place id lat lon) (make-spatial-thing #:id id #:lat lat #:long lon))
(define (worker id loc) (make-agent #:id id #:type 'person #:name id #:primary-location loc
                                    #:classified-as '("general")))

(define A (place "a-home" 42.70 23.32))
(define bake-p (list (rp "bake" "Bake bread")))
(define bake-f (list (out "o" "bread" 1.0 "bake")
                     (in  "i" "flour" 1.0 "bake")
                     (wrk "w" 0.1 "bake")))
(define want 5.0)

;; THIS FILE MEASURES THE FLOOR ITSELF, so it pins the floor by hand. In ordinary
;; use the floor is DERIVED — t = *target-gap*/m, so the certified duality gap is
;; the same promise whatever the program's size (solver.scm `tmin-for`). Every
;; check below sets a floor and reads the plan that comes back, which only means
;; anything if the setting survives; `*target-gap*` #f is what makes it survive.
;; §6 at the end tests the derived floor, and is the reason it exists.
(set! *target-gap* #f)

(define (bake-at tmin stock)
  "Loaves baked when 5 are wanted and STOCK flour is on hand, at path floor TMIN."
  (set! *kern-tmin* tmin)
  (ingest-records!
    (list (res "flour" "a-home" stock))
    (list (worker "wa" "a-home"))
    (list A) bake-p bake-f
    #:demand (list (cons (lg "bread" (cell "a-home" 0)) want))
    #:never-raw '("flour") #:per-agent? #f)
  (call-with-values solve-located
    (lambda (x idx) ((Vof x idx) "p|bake|a-home@0"))))

(define default-tmin *kern-tmin*)   ; whatever the engine ships with

(display "\n── the surplus, and the floor that causes it ──\n")

(define loose (bake-at 0.02 300.0))    ; the OLD default, kept as the reference point
(define tight (bake-at 1e-4 300.0))

(format #t "  abundant flour (300), demand ~,1f\n" want)
(format #t "    t_min = ~,5f → ~,4f loaves   (surplus ~,4f)\n" 0.02 loose (- loose want))
(format #t "    t_min = ~,5f → ~,4f loaves   (surplus ~,4f)\n" 1e-4 tight (- tight want))

;; 1. THE KNOB IS CONNECTED. This is the regression guard: if the floor is ever
;;    duplicated into C or into the Scheme path-follower again, tightening it
;;    stops moving the plan and this fails.
(check "the path floor is a live knob — tightening it changes the plan"
       (> (abs (- loose tight)) 1e-3))

;; 2. AT A TIGHT FLOOR THE PLAN MAKES WHAT IS WANTED. §7.9's stated purpose.
(check "at a tight floor the plan makes exactly what someone wants"
       (< (abs (- tight want)) 1e-2))

;; 3. THE RESIDUE SHRINKS WITH THE FLOOR — monotone, and in the predicted place.
;;    The balance point is ~2t/(κℓ) above demand, so halving t roughly halves it.
(display "\n── the residue tracks the floor ──\n")
(let* ((s (map (lambda (tm) (cons tm (- (bake-at tm 300.0) want)))
               (list 0.02 0.01 0.005 0.001))))
  (for-each (lambda (p) (format #t "    t_min = ~,5f → surplus ~,4f\n" (car p) (cdr p))) s)
  (check "the surplus falls monotonically as the floor tightens"
         (let lp ((xs (map cdr s)))
           (or (null? (cdr xs))
               (and (>= (+ (car xs) 1e-6) (cadr xs)) (lp (cdr xs)))))))

;; 4. A BINDING INPUT BOUNDS IT — which is why it hid for so long.
;;    With flour scarce the wall binds and the barrier has nowhere to sit, so the
;;    residue cannot grow: instead of a large SURPLUS it becomes a small
;;    SHORTFALL, the iterate held just off a wall it may not touch (4.984 of 5,
;;    ~0.3%). Only abundance turns the same residue into 16 loaves for 5. So the
;;    defect is invisible in exactly the fixtures a planner tests most — the
;;    tight ones, where everything binds.
(display "\n── a binding input bounds it ──\n")
(let* ((scarce (bake-at 0.02 5.0))
       (err    (- scarce want)))
  (format #t "    flour = 5 (binding), t_min = ~,5f → ~,4f loaves  (~,4f)\n"
          0.02 scarce err)
  (check "when the input binds, the residue becomes a small shortfall, not a surplus"
         (and (< err 0.0) (< (abs err) 5e-2))))

;; 5. THE METRIC MUST BE ABLE TO SEE IT.
;;    mean-fill clamps each good at 1, so it cannot express over-supply and read
;;    99.98% throughout. mean-overfill is its uncapped companion: the number that
;;    would have caught this on day one. Report them together or not at all.
(display "\n── the metric can now see over-supply ──\n")
(set! *kern-tmin* 0.05)                  ; deliberately loose ⇒ a visible residue
(ingest-records!
  (list (res "flour" "a-home" 300.0)) (list (worker "wa" "a-home"))
  (list A) bake-p bake-f
  #:demand (list (cons (lg "bread" (cell "a-home" 0)) want))
  #:never-raw '("flour") #:per-agent? #f)
(call-with-values build-located
  (lambda (forms lf ncol cols goods raws idx)
    (call-with-values (lambda () (solve-native forms lf (located-warm cols ncol idx)))
      (lambda (x . _)
        (let* ((C (flatten forms)) (rep (fill-report C lf x)))
          (format #t "    met = ~,3f%   overshoot = ~,3f%   labour = ~,2f h\n"
                  (assq-ref rep 'met) (assq-ref rep 'overshoot) (assq-ref rep 'labour))
          (check "mean-fill still reads ~100% — it is capped, by design"
                 (> (assq-ref rep 'met) 99.0))
          (check "mean-overfill EXPOSES the surplus mean-fill clamps away"
                 (> (assq-ref rep 'overshoot) 1.0))
          (check "and the labour it wastes is reported beside it"
                 (> (assq-ref rep 'labour) 0.0)))))))

(set! *kern-tmin* default-tmin)          ; leave the default as we found it

;;; ── 6. …AND A FIXED FLOOR IS THE WRONG SHAPE ────────────────────────────────
;;; Everything above holds one activity against one floor. Put a ROSTER behind
;;; the activity and the residue grows with it: every worker who could do the job
;;; adds a barrier pressing the same column outward, held off by the same κℓ. So
;;; the fixed floor's error is not a constant — it scales with the program, and a
;;; commons plans proportionally more waste the more members it has.
;;;
;;; Measured at the fixed 0.005, one 0.3 h task wanted ONCE:
;;;   roster  1 → 2.17 runs · 3 → 3.28 · 10 → 7.13 · 30 → 18.19 · 60 → 34.88
;;;
;;; What stays constant across programs is the GUARANTEE, not the floor: the gap
;;; at the floor is bounded by m·t, so t = g/m certifies the same promise at any
;;; size. This section is that invariant, and it is why `*target-gap*` exists.
(display "\n── the derived floor holds the plan as the roster grows ──\n")
(set! *target-gap* 0.005)                ; the shipped default: derive t = g/m

(define (bin-runs n-people)
  "Runs ordered when ONE 0.3 h task is wanted once and N people could do it."
  (declare-world! #:places '("flat")
                  #:templates (list (list "binrun" '(("binsdone" . 1.0)) '() 0.3))
                  #:workers
                    (map (lambda (i) (list (format #f "p~a" i) '("cleaning") (cell "flat" 0) 20.0))
                         (iota n-people 1)))
  (hash-set! *proc-skill* "binrun" "cleaning")
  (hash-set! *demand* (lg "binsdone" (cell "flat" 0)) 1.0)
  (call-with-values build-located
    (lambda (forms lf ncol cols goods raws idx)
      (call-with-values (lambda () (solve forms lf (located-warm cols ncol idx)))
        (lambda (x . _) ((Vof x idx) "p|binrun|flat@0"))))))

(let ((rs (map (lambda (n) (cons n (bin-runs n))) '(1 3 10 30))))
  (for-each (lambda (p) (format #t "    roster ~3a → ~,3f runs   (wanted 1)\n" (car p) (cdr p))) rs)
  (check "the plan makes what is wanted whatever the roster's size"
         (every (lambda (p) (< (abs (- (cdr p) 1.0)) 5e-2)) rs))
  ;; the defect stated as a property, not a number: it must not GROW with people
  (check "…and the residue does not grow with the number of people who could help"
         (let ((first (cdar rs)) (last (cdr (last rs))))
           (< (- last first) 5e-2))))

(check-done "  The centering floor is single-sourced, derived from the guarantee, and bounded.~%")
