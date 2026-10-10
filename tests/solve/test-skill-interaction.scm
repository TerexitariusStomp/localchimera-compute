;;; test-skill-interaction.scm — a substitute's slack changes what a shift sees.
;;;
;;; Two things to prove: the pure math (effective-skill-supply — a mutual,
;;; asymmetric fixed point between a cook and a baker, via the SAME
;;; propagate.scm the eco cascade and nutrient bioavailability already use),
;;; and the real wiring — register-coupling! 'skill, read by engine.scm's
;;; structural-raw loop through the SAME coupled-coeffs both couplings share.
;;; A kitchen with a token cook and an idle baker cannot serve three meals
;;; without cross-training registered, and can with it.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/solve/test-skill-interaction.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve compile) (playnet solve solver) (playnet vf schemas)
             (playnet knowledge dsl shorthand))
(use-modules (playnet knowledge catalogues skill-interaction))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (format #t "  [~a] ~a~%" (if ok "✓" "✗") name)
  (if ok (set! *pass* (+ *pass* 1)) (set! *fail* (+ *fail* 1))))

(format #t "~%── the pure math: cook and baker, a mutual and asymmetric fixed point ──~%")
(define supply (list (cons "Lab|skill-cook" 2.0) (cons "Lab|skill-bake" 5.0)))
(define eff (effective-skill-supply supply))
(format #t "  raw:       ~a~%  effective: ~a~%" supply eff)
;; p_cook = 2 + 0.4·p_bake; p_bake = 5 + 0.25·p_cook ⇒ p_cook = 40/9 ≈ 4.444, p_bake ≈ 6.111
(check "cook's effective supply rises past its own raw hours, reading baker's own net"
       (< (abs (- (assoc-ref eff "Lab|skill-cook") (/ 40.0 9.0))) 0.001))
(check "baker's own effective supply rises too, reading cook's OWN corrected value back — the cycle closes"
       (< (abs (- (assoc-ref eff "Lab|skill-bake") (/ 55.0 9.0))) 0.001))
(check "the boost is asymmetric, not a coincidence of equal coefficients"
       (not (= (- (assoc-ref eff "Lab|skill-cook") 2.0) (- (assoc-ref eff "Lab|skill-bake") 5.0))))

(format #t "~%── the real wiring: a kitchen, one token cook, one idle baker, coupling on or off ──~%")
;; "serve" needs skill-cook alone; a floor of 3 meals forces 3 hours of
;; skill-cook. Bob holds a TOKEN 0.01 hours of it (just enough for the
;; process to exist as a column at all — a skill with NO worker anywhere
;; never compiles a column, coupling or not). Alice holds 10 idle hours of
;; skill-bake and never bakes in this test — pure slack for cook to draw on.
(define (recipes)
  (compile-recipe
   (list (rp "serve" "Serve"))
   (list (wk* "s1" "skill-cook" 1.0 "serve")
         (out "s2" "meal" 1.0 "serve"))))
(define FLOOR 3.0)
(define SUFFIX "kitchen@0")

(define* (attempt #:key (coupled? #f))
  (declare-world! #:places '(("kitchen" 0.0 0.0)) #:templates (recipes)
                  #:workers '(("alice" ("skill-bake") "kitchen@0" 10.0)
                              ("bob"   ("skill-cook") "kitchen@0" 0.01)))
  (hash-set! *init* "meal#kitchen@0" (- FLOOR))
  (when coupled?
    (register-coupling! 'skill (expand-skill-couple *skill-interactions* (list SUFFIX))))
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (call-with-values (lambda () (solve-native forms labform (located-warm cols ncol idx)))
        (lambda (x . _) (vector-ref x (hash-ref idx "p|serve|kitchen@0")))))))

(define bare-result (false-if-exception (attempt #:coupled? #f)))
(define coupled-result (false-if-exception (attempt #:coupled? #t)))
(format #t "  no coupling:   ~a~%  with coupling: ~,3f meal(s)~%" (or bare-result "infeasible, as expected") coupled-result)

(check "one token cook (0.01 h) cannot serve 3 meals without cross-training"
       (not bare-result))
(check "with it, the SAME token cook clears the floor (bake's slack propagates in, ~4.4 h effective)"
       (and coupled-result (>= coupled-result (- FLOOR 0.5)) (<= coupled-result (+ FLOOR 2.5))))

(format #t "~%── the default is silent: an unregistered coupling changes nothing ──~%")
(define plain-floor
  (let ()
    (declare-world! #:places '(("kitchen" 0.0 0.0)) #:templates (recipes)
                    #:workers '(("bob" ("skill-cook") "kitchen@0" 5.0)))
    (hash-set! *init* "meal#kitchen@0" -3.0)
    (call-with-values build-located
      (lambda (forms labform ncol cols goods raws idx)
        (call-with-values (lambda () (solve-native forms labform (located-warm cols ncol idx)))
          (lambda (x . _) (vector-ref x (hash-ref idx "p|serve|kitchen@0"))))))))
(check "a floor no coupling table names solves exactly as before — bob alone, nothing propagated"
       (and plain-floor (< (abs (- plain-floor 3.0)) 0.05)))

(format #t "~%  ~a — ~a passed, ~a failed~%~%" (if (= *fail* 0) "✓" "✗") *pass* *fail*)
(exit (if (= *fail* 0) 0 1))
