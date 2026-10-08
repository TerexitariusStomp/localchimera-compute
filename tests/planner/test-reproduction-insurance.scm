;;; test-reproduction-insurance.scm — the two ways a plan can refuse to leave
;;; someone short, and what each costs.
;;;
;;; Spec: docs/playnet.typ §Reproduction labour ("Insurance … enters harmony as a
;;;       HARD possibility-tension rather than a soft desire … the fragility
;;;       profiles") + §possibility-tensions.
;;;
;;; The engine had an asymmetry. An ECOLOGICAL limit carries its precautionary
;;; margin INSIDE the barrier: the tip is placed at a quantile of the science
;;; range, it is felt at the optimum because the weight is fixed, and no desire
;;; can outbid it. HUMAN subsistence carried a swept-weight `bar` at bare need —
;;; barely felt until nearly breached, ridden to the edge — with the margin above
;;; it living in the reserve tranche, which is a low-weight desire and therefore
;;; the FIRST thing shed when resources bind. The biosphere's precaution was
;;; structural; reproduction's was discretionary.
;;;
;;; Two mechanisms close that, and they answer different questions:
;;;
;;;   `held`        a desire that does not ABANDON. w·(1−u)²/u for u = s/D. It
;;;                 agrees with an ordinary desire in value, gradient AND
;;;                 curvature at satiation, so it costs nothing in the ordinary
;;;                 range, and diverges as satisfaction collapses, so no finite
;;;                 weight elsewhere can buy someone out of it entirely.
;;;
;;;   `*band*` (a floor with a margin) — a reproduction floor that HOLDS A MARGIN. Emitted as a
;;;                 `held`, not a `frag`, and the difference is not cosmetic: a
;;;                 log barrier works on a CEILING because its pressure and
;;;                 thrift push the same way, but on a FLOOR it pushes supply up
;;;                 without bound and settles at w/κ — a number about the weight
;;;                 rather than about any margin. Measured before the fix, a
;;;                 floor meant to hold 120 produced 283. `held` diverges at bare
;;;                 need so nothing crosses it, and satiates at the margin so
;;;                 nothing is over-made for it.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-reproduction-insurance.scm

(use-modules (playnet test planner prelude)
             (playnet planner solve engine)
             (playnet planner solve solver)
             (srfi srfi-1)
             (ice-9 format))

;; ════════════════════════════════════════════════════════════════════════════
;; (1) `held` — a want that cannot be priced out
;; ════════════════════════════════════════════════════════════════════════════
;; Two needs of equal demand and equal weight, one costing a hundred times the
;; other, against a labour budget that cannot serve both. With ordinary desires
;; the dear need is ABANDONED — its penalty is bounded, so dropping it entirely
;; costs w and no more. Φ, the harmonic mean of satisfaction, collapses with it.
(display "\n── an expensive need, two desire kinds ──\n")

(define (rig mkA mkB)
  (list (mk-bar 0.0 '((0 . 1.0))) (mk-bar 0.0 '((1 . 1.0)))
        (mk-bar 250.0 '((0 . -1.0) (1 . -100.0)))          ; cheap 1h/unit, dear 100h/unit
        (mkA (mk-bar 0.0 '((0 . 1.0))) 100.0 1000.0)
        (mkB (mk-bar 0.0 '((1 . 1.0))) 100.0 1000.0)))

(define (solve-rig mkA mkB)
  (call-with-values (lambda () (solve-native-c (rig mkA mkB) '((0 . 1.0) (1 . 1.0)) (vector 1.0 0.1)))
    (lambda (x . _)
      (let* ((sa (/ (vector-ref x 0) 100.0)) (sb (/ (vector-ref x 1) 100.0)))
        (list sa sb (/ 2.0 (+ (/ 1.0 (max 1e-9 sa)) (/ 1.0 (max 1e-9 sb)))))))))

(define des-des   (solve-rig mk-des  mk-des))
(define held-held (solve-rig mk-held mk-held))

(format #t "  both des : cheap ~6,2f%  dear ~5,2f%  Φ ~,4f\n"
        (* 100 (car des-des)) (* 100 (cadr des-des)) (caddr des-des))
(format #t "  both held: cheap ~6,2f%  dear ~5,2f%  Φ ~,4f\n"
        (* 100 (car held-held)) (* 100 (cadr held-held)) (caddr held-held))

(check "ordinary desires abandon the expensive need"
       (< (cadr des-des) 0.02))
(check "`held` refuses to — the dear need is served better"
       (> (cadr held-held) (cadr des-des)))
(check "…and the worst-off measure rises for it"
       (> (caddr held-held) (caddr des-des)))
;; It is NOT free: the protection is paid for by the cheap need, and saying so is
;; the point — this is a distributive choice the shape makes explicit, not a
;; free lunch the arithmetic conjures.
(check "…paid for out of the cheap need, visibly"
       (< (car held-held) (car des-des)))

;; ── the usage rule, asserted because getting it wrong INVERTS the protection ──
;; An unbounded penalty always outbids a bounded one in the limit. A lone `held`
;; beside ordinary desires does not protect the worst-off: it consumes the budget
;; and the DESIRES are dropped instead. Use it across a class, or not at all.
(display "\n── the usage rule: consistently, or not at all ──\n")
(define mixed (solve-rig mk-des mk-held))
(format #t "  des + held (mixed): cheap ~6,2f%  dear ~5,2f%  Φ ~,4f\n"
        (* 100 (car mixed)) (* 100 (cadr mixed)) (caddr mixed))
(check "a lone `held` starves the bounded desire beside it"
       (< (car mixed) 0.01))
(check "…so mixing is worse for the worst-off than either kind used alone"
       (< (caddr mixed) (caddr held-held)))

;; ── and where nothing binds, it must cost nothing ────────────────────────────
;; The two kinds agree in value, gradient and curvature at satiation, so with
;; labour to spare they should land on the same plan to within barrier residue.
(display "\n── where nothing is scarce, `held` is an ordinary desire ──\n")
(define (ample mk)
  (call-with-values
      (lambda () (solve-native-c (list (mk-bar 0.0 '((0 . 1.0))) (mk-bar 2000.0 '((0 . -1.0)))
                                       (mk (mk-bar 0.0 '((0 . 1.0))) 100.0 1000.0))
                                 '((0 . 1.0)) (vector 1.0)))
    (lambda (x . _) (vector-ref x 0))))
(define a-des (ample mk-des))
(define a-held (ample mk-held))
(format #t "  ample labour: des ~,3f   held ~,3f   |Δ| ~,4f\n" a-des a-held (abs (- a-des a-held)))
(check "with room to spare the two kinds agree"
       (< (abs (- a-des a-held)) 0.05))

;; ════════════════════════════════════════════════════════════════════════════
;; (2) `*band*` floor-with-margin — the margin lives INSIDE the barrier
;; ════════════════════════════════════════════════════════════════════════════
;; A demand of 100 with the thrift term stops at 100: the plan makes what was
;; asked for and no more, which is correct for a want and thin for a need. The
;; floor diverges at bare need and satiates at the margin, so the plan holds the
;; margin where it can and never crosses the floor where it cannot.
;;
;; NOTE the direction of `alpha`. `quantile` reads alpha = 0 as "most
;; precautious", which is true of a CEILING (the lowest tip). On a FLOOR the
;; precaution runs the other way: lo is bare need, hi the comfortable margin, and
;; alpha near 1 holds more back.
(display "\n── a floor that holds a margin, vs one that rides the edge ──\n")

(define (bread-made frag?)
  (declare-world! #:places '(("town" 40.0 -74.0)) #:templates *base-templates*)
  (hash-set! *demand* (lg "bread" "town@0") 100.0)
  (hash-set! *cap* (lg "soil" "town@0") 1e6)
  (hash-set! *A* "town@0" 400.0)
  (when frag?   ; bare need 100, comfortable 140, alpha 0.5 ⇒ the floor sits at 120
    (hash-set! *band* (lg "bread" "town@0") (make-band #:floor '(100.0 140.0 0.5) #:w 5.0)))
  (call-with-values solve-located
    (lambda (x idx)
      (let ((V (Vof x idx)))
        (+ (V "p|bake|town@0") 0.0)))))

(define plain (bread-made #f))
(define insured (bread-made #t))
(format #t "  bare `bar` floor at the demand : bread ~,2f\n" plain)
(format #t "  fragility floor, tip at 120    : bread ~,2f\n" insured)

(check "without it the plan makes what was asked for and stops"
       (< plain 105.0))
(check "with it the plan holds the precautionary margin"
       (> insured 118.0))
(check "…and the margin is the one the profile names, not more"
       (< insured 135.0))

;; ── the margin cannot be shed ────────────────────────────────────────────────
;; A reserve tranche is a low-weight desire and is the first thing dropped when
;; resources bind. A fragility floor is a barrier: scarcity cannot reach it. Same
;; economy, labour cut until the plan is genuinely tight.
(display "\n── under scarcity the margin survives ──\n")
(define (bread-scarce labour floor?)
  (declare-world! #:places '(("town" 40.0 -74.0)) #:templates *base-templates*)
  (hash-set! *demand* (lg "bread" "town@0") 100.0)
  (hash-set! *cap* (lg "soil" "town@0") 1e6)
  (hash-set! *A* "town@0" labour)
  (when floor?
    (hash-set! *band* (lg "bread" "town@0") (make-band #:floor '(100.0 140.0 0.5) #:w 5.0)))
  (call-with-values solve-located
    (lambda (x idx) ((Vof x idx) "p|bake|town@0"))))

(define tight      (bread-scarce 150.0 #t))
(define tight-bare (bread-scarce 150.0 #f))
(format #t "  ample (400h): ~,2f      tight (150h): ~,2f   without the floor: ~,2f\n"
        insured tight tight-bare)

;; The MARGIN is graded and the FLOOR is not — which is the whole point of the
;; shape. `held` diverges at bare need, so scarcity can never reach it; it
;; satiates at the margin, so scarcity erodes the margin first. A reserve tranche
;; would have been dropped outright; this degrades and holds.
(check "scarcity erodes the margin"
       (< tight insured))
(check "…and never the floor beneath it"
       (> tight 100.0))
(check "…so a tight plan still holds more than one with no floor at all"
       (> tight tight-bare))

;; ════════════════════════════════════════════════════════════════════════════
;; (3) the certificate must not be blind to a breached floor
;; ════════════════════════════════════════════════════════════════════════════
;; `held` diverges at its own wall exactly as `frag` diverges at its tip — this
;; is the same shape, and the same class of gap frag once had: pk_frac_to_boundary
;; (kernel.c) originally guarded bar/frag only, and a primal-dual step could ride
;; straight through a fragility tip and certify the result (measured then: tip 10,
;; returned x = 43.74, mu = 6.6e-7 — an ecological limit passed by 4x and reported
;; proven). `held` repeated that gap the moment it was added: `mins`/`feasible?`
;; in kkt-report, `bar-slacks-min`, `plan-grossly-infeasible?`, `augment-phase1`'s
;; Phase-I constraint set, `infeasibility-report`'s named-violation list, the
;; optimal-face room computation, and the C kernel's own `pk_frac_to_boundary` all
;; checked kind ∈ {0,3} (bar, frag) and silently skipped kind 4 (held). A plan
;; breaching a reproduction floor read as FEASIBLE.
(display "\n── a breached floor is infeasible, not silently passed over ──\n")

(define breach-forms
  (list (mk-bar 0.0 '((0 . 1.0))) (mk-bar 0.0 '((1 . 1.0)))
        (mk-held (mk-bar 0.0 '((0 . 1.0) (1 . -1.0))) 40.0 3.0)))  ; s = x0-x1, floor 40
(define breach-x (vector 10.0 15.0))                                ; s = -5: BELOW bare need

(define breach-report (kkt-report (flatten breach-forms) '() breach-x 0.005))
(check "a plan with held's slack negative is reported infeasible"
       (not (assq-ref breach-report 'feasible?)))
(check "…and min-slack reads the true (negative) breach, not some other term"
       (< (assq-ref breach-report 'min-slack) 0.0))

;; the same wall from Phase-I's own side. held's hard wall is s = 0 (bare need)
;; — NOT its satiation target D, which is just where it goes inert — so the
;; isolating case needs the BARE-NEED wall itself unreachable. Three bar forms
;; alone are satisfiable (x0=0, x1=5 clears all of x0≥0, x1≥0, x1≥x0+5); only
;; adding held on s=x0−x1 makes the program infeasible, since x1≥x0+5 forces
;; x0−x1 ≤ −5 always — s can never be positive.
(define infeas-forms
  (list (mk-bar 0.0 '((0 . 1.0)))                          ; x0 ≥ 0
        (mk-bar 0.0 '((1 . 1.0)))                           ; x1 ≥ 0
        (mk-bar -5.0 '((1 . 1.0) (0 . -1.0)))                ; x1 − x0 ≥ 5
        (mk-held (mk-bar 0.0 '((0 . 1.0) (1 . -1.0))) 1.0 2.0)))  ; s = x0−x1, must stay > 0
(call-with-values
    (lambda () (phase1-decide infeas-forms '() (vector 0.0 5.0) solve-native-c-core))
  (lambda (x s*)
    (check "the bar constraints alone are satisfiable (not a trivial contradiction)"
           (> (bar-slacks-min (flatten (list-head infeas-forms 3))
                               (term-values (flatten (list-head infeas-forms 3)) (vector 0.1 5.2)))
              0.0))
    (check "Phase-I proves infeasibility from held's wall, not just the bar caps"
           (> s* 1e-6))))

(check-done "  Reproduction gets the precaution the biosphere already had.~%")
