;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-boundary-conservation-law.scm — the boundary pull is the dual of the
;;; fold; primal feasibility at convergence IS the conservation law.
;;;
;;; Across scopes the convex layer is coupled by pull, never folded: each
;;; commune solves its own program and a scalar λ on the crossing good is all
;;; that crosses (solve/federation-solve.scm). What the ADMM drives λ to is exactly
;;; the condition a fold over both communes would state directly —
;;;
;;;     Σ supplied  =  Σ drawn  =  the deficit of the commune that lacks the good
;;;
;;; so the dual idiom and the primal keyed sums answer to one law. Held here
;;; on the demo federation: a flour-rich granary and a flour-poor table that
;;; wants 40 loaves at one kilo each.
;;;
;;; Run:  guile --no-auto-compile -q -L module -L tests tests/scope/test-boundary-conservation-law.scm

(use-modules (playnet solve federation-solve))
(use-modules (playnet test harness) (playnet knowledge recipes federation-demo) (playnet scope root) (srfi srfi-1) (playnet scope live)
             (playnet knowledge recipes federation-demo)
             (goblins) (srfi srfi-1))

(define (record root sid demand)
  (let ((obs ($ root 'observer)) (as ($ root 'agent-store))
        (sts ($ root 'spatial-thing-store)) (rs ($ root 'recipe-store)))
    (call-with-values (lambda () (gather-recipes rs))
      (lambda (procs flows)
        (commune->scope-record ($ obs 'all-resources) ($ as 'all-agents)
                               ($ sts 'all-locations) procs flows
                               #:id sid #:demand demand
                               #:never-raw '("flour")
                               #:crossing '("flour"))))))

(define (flour-of rec plan) (assoc-ref (federated-flows rec plan) "flour"))   ; signed: supplied above nothing, drawn below

(define (federate! granary-stock)
  "Solve the demo federation with GRANARY-STOCK kg of flour at the granary;
   returns (Σ supplied Σ drawn λ(flour))."
  (let ((gr (spawn-scope-root "Granary")) (tb (spawn-scope-root "Table")))
    (seed-fed-commune! gr "fed" "commune-granary" "Granary" "venue-granary" 42.70 23.32 granary-stock)
    (seed-fed-commune! tb "fed" "commune-table"   "Table"   "venue-table"   42.75 23.40 0.0)
    (let ((recs (list (record gr "Granary" '(("bread#venue-granary@0" . 5.0)))
                      (record tb "Table"   '(("bread#venue-table@0" . 40.0))))))
      (call-with-values (lambda () (federated-solve recs))
        (lambda (plans met rounds pulls)
          (let ((ys (map flour-of recs plans)))
            (list (fold + 0.0 (map (lambda (y) (max y 0.0)) ys))        ; what is supplied
                  (fold + 0.0 (map (lambda (y) (max (- y) 0.0)) ys))    ; what is drawn
                  (hash-ref pulls "flour" 0.0))))))))

(with-vat (spawn-vat)
  (display "\n── abundance: the row closes, the need is met, the dual is ~0 ──\n")
  (let* ((r (federate! 300.0)) (exp (car r)) (imp (cadr r)) (pull (caddr r)))
    (format #t "   stock 300   Σ supplied ~,3f   Σ drawn ~,3f   λ(flour) ~,4f~%" exp imp pull)
    (check "Σ supplied = Σ drawn — primal feasibility is the conservation law"
           (< (abs (- exp imp)) 0.05) #t)
    (check "the table's deficit is covered: it draws ≥ 40 loaves at 1 kg"
           (>= imp 39.5) #t)
    (check "within what the granary holds" (<= exp 300.0) #t)
    (check "an abundant good pulls ~0: the dual of a slack bound"
           (< (abs pull) 0.01) #t))

  (display "\n── scarcity: the stock fold binds, and the pull is its dual ──\n")
  (let* ((r (federate! 20.0)) (exp (car r)) (imp (cadr r)) (pull (caddr r)))
    (format #t "   stock 20    Σ supplied ~,3f   Σ drawn ~,3f   λ(flour) ~,4f~%" exp imp pull)
    (check "the row still closes" (< (abs (- exp imp)) 0.05) #t)
    (check "the flow is the stock fold's bound net of the granary's own floor: 20 − 5"
           (and (<= imp 20.05) (> imp 14.0)) #t)
    ;; the pull is reported as ρ·u, the one number every participant solves
    ;; against, negative when more is asked than would be given; its
    ;; magnitude is the dual of the binding fold, ~0 when slack, large here
    (check "and the boundary pull stands — the dual of the binding fold (|λ| ≫ 0)"
           (> (abs pull) 1.0) #t)))

(test-summary!)
