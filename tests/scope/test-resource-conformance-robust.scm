;;; test-resource-conformance-robust.scm — substitution UNDER UNCERTAINTY.
;;;
;;; The resource-supplier channel threads all the way through the robust
;;; (#:scenarios) solve, so a substitutable means is available under every weather
;;; draw — its closure is structural, identical across scenarios. Same bake as
;;; test-resource-conformance-live (a convection-oven filling a plain `oven`), now
;;; wrapped in a two-scenario robust solve. If the channel did NOT reach the robust
;;; path, the Svc|convection-oven cap would stay a plain eco-cap, oven would fall
;;; back to a free structural raw, and fulfilment would be capacity-INSENSITIVE
;;; (met 1.0). Because it does reach it, the convection-oven BOUNDS oven under
;;; uncertainty exactly as in the deterministic solve (cap 2 ⇒ met ~0.5).
;;; Pure solver (no ACDCs) ⇒ no blake3.
;;; Run: guile -L module tests/scope/test-resource-conformance-robust.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness)
             (playnet vf schemas) (playnet vf beyond scenario)
             (playnet scope live)
             (goblins) (goblins vat) (srfi srfi-1))

(define holdings (list (er "res:conv-oven" "convection-oven" "commune" #:qty 1 #:unit %count-unit)))

(define procs (list (rp* "bake" "Bake")))
(define flows (list (out* "b1" "bread" 1.0 "bake") (use* "b2" "oven" "bake" 1.0 #:qty 1.0)))
(define recipes (list (make-recipe #:id "bake-recipe" #:name "Bake" #:primary-output "bread"
                                   #:recipe-processes '() #:recipe-exchanges '())))
(define oven-specs
  (list (make-resource-specification
         #:id "oven" #:name "Oven" #:resource-classified-as '() #:default-unit-of-effort %effort-unit
         #:satisfied-by '((("convection-oven" . 0))))))

;; two weather draws, both leaving the bake yield at 1.0 — the uncertainty is real
;; (two scenarios, recourse columns) but the OVEN's role is unshocked, so the only
;; thing that can bound bread is the convection-oven capacity carried through robust.
(define scenarios
  (list (make-planning-scenario "dry" "sc-dry" 0.5 '(("bake" . 1.0)) "dry spell")
        (make-planning-scenario "wet" "sc-wet" 0.5 '(("bake" . 1.0)) "wet spell")))

(define spatials (list (make-spatial-thing #:id "town" #:lat 40.0 #:long -74.0)))
(define vat (spawn-vat #:name "resource-conformance-robust"))

(define (run cap)
  (with-vat vat
    (let* ((obs (spawn ^mock `((all-resources . ,(lambda () holdings))
                               (skill-hours-of . ,(lambda (aid) '()))
                               (record-event   . ,(lambda (e) "ok")))))
           (as  (spawn ^mock `((all-agents    . ,(lambda () '())))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs  (spawn ^mock `((all-recipes        . ,(lambda () recipes))
                               (all-resource-specs . ,(lambda () oven-specs))
                               (get-process-chain  . ,(lambda (rid) procs))
                               (flows-for-process
                                . ,(lambda (pid)
                                     (cons (filter (lambda (f)
                                                     (or (equal? (recipe-flow-recipe-input-of f) pid)
                                                         (equal? (recipe-flow-recipe-output-of f) pid)))
                                                   flows) '()))))))
           (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs)))
      (assq-ref
       (plan-scope->alist scope
         #:eco-caps `(("Svc|convection-oven#town@0" . ,cap))
         #:demand '(("bread#town@0" . 4.0))
         #:scenarios scenarios
         #:backend 'native-c)
       'met))))

(define rob-2 (run 2.0))
(define rob-4 (run 4.0))

(display "\n── convection-oven substitutes for oven UNDER two scenarios (bake demand 4) ──\n")
(format #t "  robust, cap 2 ⇒ met ~,2f   (bounded to ≈ 2/4)~%" rob-2)
(format #t "  robust, cap 4 ⇒ met ~,2f   (≈ 4/4)~%" rob-4)

(check "substitution survives the robust solve — convection-oven bounds oven (cap 2 ⇒ ~1/2)"
       (and (> rob-2 0.4) (< rob-2 0.6)))
(check "more capacity ⇒ more service under uncertainty too (cap 4 ⇒ ~full)"
       (> rob-4 0.9))
(check "capacity-SENSITIVE under scenarios (proof the supplier channel reached robust)"
       (> (- rob-4 rob-2) 0.3))

(display "\n")
(test-summary!)
