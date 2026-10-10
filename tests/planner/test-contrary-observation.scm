;;; test-contrary-observation.scm — the world as observed, in every future.
;;;
;;; A contrary observation reaches a scope's solve as `#:observed` rows
;;; ((process action nominal reading) …), laid over EVERY scenario of the solve
;;; (planner/scope/live.scm plan-scope, engine/robust.scm observed-shocks). Pinned here on
;;; the bread town: an oven observed at half its mapped yield makes the plan
;;; stop claiming the want is met (the labour on hand cannot double the runs),
;;; a run observed at twice its mapped labour doubles the bake hours, and a
;;; flattering reading changes nothing.
;;;
;;; Run:  guile -q -L module tests/planner/test-contrary-observation.scm

(use-modules (playnet test harness)
             
             (playnet scope live)
             (playnet test planner bread)
             (goblins) (goblins vat)
             (srfi srfi-1))

(define demand '(("bread#town@0" . 10.0)))

(define (solve observed)
  "(bake-hours . met) of the town's solve under OBSERVED."
  (with-vat (spawn-vat #:name "contrary")
    (call-with-values (lambda () (spawn-bread-scope))
      (lambda (root ps as)
        (let ((r (plan-scope->alist root #:demand demand #:observed observed)))
          (cons (bread-hours r "bake") (assq-ref r 'met)))))))

(define plain     (solve '()))
(define half-oven (solve '(("bake" produce 1.0 0.5))))   ; the oven yields half of what the map says
(define slow-bake (solve '(("bake" work 0.5 1.0))))      ; a run takes twice the mapped labour
(define flattered (solve '(("bake" produce 1.0 2.0))))   ; a reading better than the map

(display "\n── the world as observed, in every future ──\n")
(check-pred "the town bakes, and the plan says the want is met" (and (> (car plain) 0.0) (> (cdr plain) 0.99)))
(check-pred "an oven observed at half its mapped yield: the plan no longer claims the want is met — feasibility followed the map"
            (< (cdr half-oven) (* 0.8 (cdr plain))))
(check-pred "…and it bakes no less for it: the shortfall is stated, never hidden"
            (>= (car half-oven) (* 0.95 (car plain))))
(check-pred "a run observed at twice its mapped labour: about twice the bake hours for the same bread, still met"
            (and (> (car slow-bake) (* 1.8 (car plain))) (< (car slow-bake) (* 2.2 (car plain)))
                 (> (cdr slow-bake) 0.99)))
(check-pred "a flattering reading leaves the map, and the plan, where it stood"
            (and (< (abs (- (car flattered) (car plain))) 1e-6) (< (abs (- (cdr flattered) (cdr plain))) 1e-6)))

(test-summary!)
