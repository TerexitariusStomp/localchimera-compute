;;; test-provenance-explain.scm — the provenance bridge, all the way to the solve.
;;;
;;; Spawns the real ^planner-service over a seeded scope and calls `explain` — the
;;; method that joins the (pure, decoupled) prose-claim graph to this scope's convex
;;; plan. The seed includes a recipe-process that PERFORMS the `plan-review` aspect
;;; (process-conforms-to), so the live `recipes-conforming` gate finds it. This
;;; proves the whole chain end to end, through the actual OCapN-facing surface:
;;;
;;;   claim → provenance graph → realized aspect id → recipes-conforming (live rs)
;;;         → gated recipes ; structural legal claim ⇒ no priced number.
;;;
;;; Run: guile -L module tests/planner/test-provenance-explain.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet scope root) (playnet vf schemas))
(use-modules (playnet doors service))
(use-modules (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(define vat (spawn-vat))
(define svc-ref
  (with-vat vat
    (let* ((sr  (spawn-scope-root "Provenance Scope"))
           (rs  ($ sr 'recipe-store))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "s1" sr))))
      ;; a bread recipe whose process PERFORMS the plan-review aspect — the very
      ;; shell aspect duress-from-diff realizes. So the live gate returns this recipe.
      ($ rs 'add-recipe-process
         (make-recipe-process #:id "rp-bake" #:name "Bake" #:process-conforms-to "plan-review"
                              #:has-duration (make-duration 3 %effort-unit)))
      ($ rs 'add-recipe-flow
         (make-recipe-flow #:id "rf-bake-work" #:action 'work #:resource-conforms-to "spec-labor"
                           #:effort-quantity (make-measure 3 %effort-unit) #:recipe-input-of "rp-bake"))
      ($ rs 'add-recipe-flow
         (make-recipe-flow #:id "rf-bake-out" #:action 'produce #:resource-conforms-to "spec-bread"
                           #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-bake"))
      ($ rs 'add-recipe (make-recipe #:id "recipe-bread" #:name "Bread" #:primary-output "spec-bread"
                                     #:recipe-processes (list "rp-bake")))
      svc)))

(with-vat vat
  (let* ((r    ($ svc-ref 'explain "s1" 'duress-from-diff))
         (body (cdr r)))
    (display "\n── explain over the live ^planner-service ──\n")

    (check "explain returns ok"      (car r) 'ok)

    (check "claim echoed"            (assq-ref body 'claim) 'duress-from-diff)

    (check "grounds = whole basis (legal-aspects, reform)"
           (sort (map symbol->string (assq-ref body 'grounds)) string<?)
           (sort (map symbol->string '(legal-aspects reform)) string<?))

    (check "proof chain present"     (not (null? (assq-ref body 'proof))) #t)

    (check "realizes the plan-review aspect"
           (assq-ref body 'realizes) '(plan-review))

    (check "LIVE gate: plan-review is performed by recipe-bread"
           (assq-ref body 'gated) '((plan-review "recipe-bread")))

    (check "structural legal claim prices no number"
           (assq-ref body 'numbers) '())

    ;; an unknown/unrealized claim still resolves cleanly (no gate, no number)
    (let ((e2 (cdr ($ svc-ref 'explain "s1" 'eco-tipping-ratchet))))
      (check "ungrounded claim: empty realizes"
             (assq-ref e2 'realizes) '())
      (check "ungrounded claim: empty gated"
             (assq-ref e2 'gated) '()))))

(display "\n")
(test-summary!)
