;;; test-eisenberg-gale.scm — the E–G door against its closed forms.
;;; Competitive equilibrium from (un)equal incomes as one convex solve
;;; (solve/federation-solve.scm eisenberg-gale-split).
(use-modules (playnet test harness)  (playnet solve engine) (playnet solve federation-solve) (srfi srfi-1))
(define (~= a b) (< (abs (- a b)) 0.02))
(display "\n── one good, budgets 1 and 3: allocation ∝ budget ──\n")
(call-with-values
    (lambda () (eisenberg-gale-split '("grain") '(("grain" . 1.0))
                                     '(("A" . (("grain" . 1.0))) ("B" . (("grain" . 1.0))))
                                     #:budgets '(("A" . 1.0) ("B" . 3.0))))
  (lambda (alloc pulls us)
    (check "A takes a quarter" (~= (assoc-ref (assoc-ref alloc "A") "grain") 0.25) #t)
    (check "B takes three quarters" (~= (assoc-ref (assoc-ref alloc "B") "grain") 0.75) #t)
    (check "the pull settles at Σb/S = 4" (~= (assoc-ref pulls "grain") 4.0) #t)))
(display "\n── two goods, mirrored tastes, equal budgets: each takes their own ──\n")
(call-with-values
    (lambda () (eisenberg-gale-split '("g1" "g2") '(("g1" . 1.0) ("g2" . 1.0))
                                     '(("A" . (("g1" . 2.0) ("g2" . 1.0)))
                                       ("B" . (("g1" . 1.0) ("g2" . 2.0))))))
  (lambda (alloc pulls us)
    (check "A takes its preferred good whole" (~= (assoc-ref (assoc-ref alloc "A") "g1") 1.0) #t)
    (check "B takes its preferred good whole" (~= (assoc-ref (assoc-ref alloc "B") "g2") 1.0) #t)
    (check "utilities land at 2 each" (and (~= (assoc-ref us "A") 2.0) (~= (assoc-ref us "B") 2.0)) #t)
    (check "the mirrored goods pull equally" (~= (assoc-ref pulls "g1") (assoc-ref pulls "g2")) #t)))
(test-summary!)
