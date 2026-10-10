;;; test-nutrient-interaction.scm — bioavailability changes what a floor sees.
;;;
;;; Two things to prove: the pure math (effective-nutrients — calcium and
;;; vitamin C move iron, iron moves zinc, via the same propagate.scm the eco
;;; cascade already uses), and the real wiring — register-coupling! 'nutrient,
;;; read by engine.scm's reproduction-floor loops through coupled-coeffs.
;;; The second is the one that matters: a floor of 16 mg iron is infeasible
;;; against one meal's raw 15 mg alone, and feasible once vitamin C's boost
;;; (net of calcium's suppression) is read — the same floor, the same meal,
;;; the only thing that changed is whether bioavailability is registered.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/planner/test-nutrient-interaction.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve compile) (playnet solve solver))
(use-modules (playnet knowledge catalogues nutrient-interaction))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (format #t "  [~a] ~a~%" (if ok "✓" "✗") name)
  (if ok (set! *pass* (+ *pass* 1)) (set! *fail* (+ *fail* 1))))

(format #t "~%── the pure math: one meal, three interactions, one fixed point ──~%")
(define raw (list (cons "iron" 15.0) (cons "calcium" 1000.0) (cons "vit C" 90.0) (cons "zinc" 10.0)))
(define eff (effective-nutrients raw))
(format #t "  raw:       ~a~%  effective: ~a~%" raw eff)
(check "iron rises: vitamin C's boost outweighs calcium's suppression (15 → 17.5)"
       (< (abs (- (assoc-ref eff "iron") 17.5)) 0.01))
(check "zinc falls, reading iron's OWN corrected value, not iron's raw amount (10 → 9.125)"
       (< (abs (- (assoc-ref eff "zinc") 9.125)) 0.01))
(check "calcium and vitamin C pass through unchanged — nothing reads or feeds them"
       (and (= (assoc-ref eff "calcium") 1000.0) (= (assoc-ref eff "vit C") 90.0)))

(format #t "~%── the real wiring: a floor on iron, one capped meal, coupling on or off ──~%")
;; one recipe: a capped raw ("greens", ≤ 1 run's worth) becomes a meal's fixed
;; nutrient bundle — the SAME numbers as the pure-math check above, so the
;; two halves of this test are the same story once as arithmetic and once as
;; a solve. Floor set to 16 mg: above raw iron (15), below effective iron
;; (17.5) — the one number where coupling is the difference between
;; infeasible and feasible.
(define (recipes)
  (compile-recipe
   (list (rp "eat" "Eat"))
   (list (in "e1" "greens" 1.0 "eat")
         (out/u "e2" "iron|ada" 15.0 "mg" "eat")
         (out/u "e3" "calcium|ada" 1000.0 "mg" "eat")
         (out/u "e4" "vit C|ada" 90.0 "mg" "eat"))))
(define FLOOR 16.0)
(define SUFFIX "ada#kitchen@0")   ; this world's one (person, place, period)

(define* (attempt #:key (coupled? #f))
  (declare-world! #:places '(("kitchen" 0.0 0.0)) #:templates (recipes))
  (hash-set! *cap* (lg "greens" (cell "kitchen" 0)) 1.0)               ; at most one meal
  (hash-set! *init* "iron|ada#kitchen@0" (- FLOOR))                    ; the floor, as every reproduction floor is laid
  (when coupled?
    (register-coupling! 'nutrient (expand-nutrient-couple *nutrient-interactions* (list SUFFIX))))
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (call-with-values (lambda () (solve-native forms labform (located-warm cols ncol idx)))
        (lambda (x . _) (vector-ref x (hash-ref idx "p|eat|kitchen@0")))))))

(define bare-result (false-if-exception (attempt #:coupled? #f)))
(define coupled-result (false-if-exception (attempt #:coupled? #t)))
(format #t "  no coupling:   ~a~%  with coupling: ~,3f meal(s)~%" (or bare-result "infeasible, as expected") coupled-result)

(check "without the interaction, 16 mg iron from a 15 mg meal (capped at one) is infeasible"
       (not bare-result))
(check "with it, the SAME capped meal clears the floor (iron's effective 17.5 mg ≥ 16)"
       (and coupled-result (<= coupled-result 1.0) (>= coupled-result (/ FLOOR 17.5))))

(format #t "~%── the default is silent: an unregistered coupling changes nothing ──~%")
;; the same world, floor lowered to what raw iron alone already clears (15),
;; solved with nothing registered under 'nutrient — the common case every
;; other reproduction floor in this codebase already takes, unmodified by
;; any of the above.
(define plain-floor
  (let ()
    (declare-world! #:places '(("kitchen" 0.0 0.0)) #:templates (recipes))
    (hash-set! *cap* (lg "greens" (cell "kitchen" 0)) 1.0)
    (hash-set! *init* "iron|ada#kitchen@0" -15.0)
    (call-with-values build-located
      (lambda (forms labform ncol cols goods raws idx)
        (call-with-values (lambda () (solve-native forms labform (located-warm cols ncol idx)))
          (lambda (x . _) (vector-ref x (hash-ref idx "p|eat|kitchen@0"))))))))
(check "a floor no coupling table names solves exactly as before — one meal, nothing propagated"
       (and plain-floor (< (abs (- plain-floor 1.0)) 0.05)))

(format #t "~%  ~a — ~a passed, ~a failed~%~%" (if (= *fail* 0) "✓" "✗") *pass* *fail*)
(exit (if (= *fail* 0) 0 1))
