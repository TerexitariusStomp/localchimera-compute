;;; plan-snapshot-e2e.scm — the WHOLE server path, end to end through the real
;;; ^planner-service actor: a real scope-root with a seeded recipe → the actor's
;;; real `scope-snapshot` carries the recipe topology; after a real `solve`, the
;;; snapshot's `plan` field is populated (need ↦ recipe ↦ coverage), proving the
;;; cache → build-snapshot → dial-plan pipeline — not just the serializers.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/planner/plan-snapshot-e2e.scm
;;; (via the blake3 dev-test shell — see [[reference_blake3_test_profile]])

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules ((playnet wire rows) #:select (wire->plain))   ; a door's rows, read back as alists
             (playnet test harness)
             (playnet scope root) (playnet vf schemas) (srfi srfi-1)
             (playnet doors service)
             (goblins)
             (goblins persistence-store memory)
             ((goblins utils hashmap) #:select (make-hashmap hashmap-set))
             (srfi srfi-1))

(define mem-store (make-memory-store))
(define-values (vat1 scope1)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Riverside Commune"))
    mem-store))

;; seed a real scope: the cooked-meal recipe + one worker who can cook + stock,
;; so a solve actually produces material and work.
(with-vat vat1
  (let ((rs  ($ scope1 'recipe-store))
        (obs ($ scope1 'observer))
        (as  ($ scope1 'agent-store))
        (sts ($ scope1 'spatial-thing-store)))
    ;; place
    ($ sts 'add-location (make-spatial-thing #:id "home" #:name "Home" #:lat 40.0 #:long -74.0))
    ;; specs
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-veg" #:name "Vegetables"
                                    #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-meal" #:name "Cooked Meal"
                                    #:default-unit-of-resource %count-unit))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "skill-cook" #:name "Cooking skill"
                                    #:default-unit-of-resource %effort-unit))
    ($ rs 'add-process-spec
       (make-process-specification #:id "pspec-cook" #:name "Cooking"))
    ;; one-step recipe: consume veg + cook-labour → produce meal
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-cook" #:name "Cook" #:process-conforms-to "pspec-cook"
                            #:has-duration (make-duration 0.6 %effort-unit) #:sequence-group 0))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-veg-in" #:action 'consume #:resource-conforms-to "spec-veg"
                         #:resource-quantity (make-measure 0.5 "kg") #:recipe-input-of "rp-cook"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-cook-work" #:action 'work #:resource-conforms-to "skill-cook"
                         #:effort-quantity (make-measure 0.6 %effort-unit) #:recipe-input-of "rp-cook"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-meal-out" #:action 'produce #:resource-conforms-to "spec-meal"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-cook" #:is-primary #t))
    ($ rs 'add-recipe
       (make-recipe #:id "rp-cooked-meal" #:name "Cooked meal" #:primary-output "spec-meal"
                    #:recipe-processes (list "rp-cook")))
    ;; a worker who holds the cooking skill, available, at home
    (let ((win (list (cons "mon" (cons 0 24)))))
      ($ as 'add-agent (make-agent #:id "chef" #:type 'person #:primary-location "home"
                                   #:classified-as '() #:availability-window win)))
    ($ obs 'seed-resource
       (make-economic-resource #:id "er-skill-chef" #:name "chef can cook" #:conforms-to "skill-cook"
                               #:accounting-quantity (make-measure 8 %effort-unit) #:onhand-quantity (make-measure 8 %effort-unit) #:primary-accountable "chef"))
    ;; some vegetables on hand to consume
    ($ obs 'seed-resource
       (make-economic-resource #:id "er-veg" #:name "veg stock" #:conforms-to "spec-veg"
                               #:accounting-quantity (make-measure 100 "kg") #:onhand-quantity (make-measure 100 "kg") #:primary-accountable "chef" #:custodian-scope "home"))
    (check-pred "scope seeded" #t)))

;; the REAL OCapN-facing service actor, holding this scope
(define svc (with-vat vat1 (spawn ^planner-service (hashmap-set (make-hashmap) "s1" scope1))))

;;; ── 1. snapshot BEFORE any solve: recipes real, plan not yet ────────────────
(define snap0 (with-vat vat1 (wire->plain ($ svc 'scope-snapshot "s1" #f))))
(define recipes0 (assq-ref snap0 'recipes))
(check-pred "snapshot carries recipes" (and (list? recipes0) (pair? recipes0)))
(check "the seeded recipe is in the snapshot"
       (and (find (lambda (r) (equal? (assq-ref r 'id) "rp-cooked-meal")) recipes0) #t) #t)
(check "no plan until a solve has run" (assq-ref snap0 'plan) #f)

;;; ── 2. a real solve through the actor (caches the result) ───────────────────
(define solve-env
  (with-vat vat1 ($ svc 'solve "s1" '((demand . (("spec-meal" "home" 0 20)))))))
(check "solve returns an ok envelope" (car solve-env) 'ok)
(check "solve produced a coverage number" (number? (assq-ref (cdr solve-env) 'met)) #t)

;;; ── 3. snapshot AFTER the solve: the plan field is populated for real ───────
(define snap1 (with-vat vat1 (wire->plain ($ svc 'scope-snapshot "s1" #f))))
(define plan (assq-ref snap1 'plan))
(check-pred "snapshot now carries a plan" (and (pair? plan) #t))
(check "plan names the scope" (assq-ref plan 'scope) "Riverside Commune")
(check-pred "plan carries a coverage number" (number? (assq-ref plan 'coverage)))

(define plan-needs (assq-ref plan 'needs))
(define meal-need (find (lambda (n) (equal? (assq-ref n 'id) "spec-meal")) plan-needs))
(check-pred "a need row for the demanded spec" (and meal-need #t))
(check "need labelled from the real spec" (assq-ref meal-need 'label) "Cooked Meal")
(check "need linked to the recipe that makes it" (assq-ref meal-need 'recipe-id) "rp-cooked-meal")
(check-pred "need met is a fraction in [0,1]"
            (let ((m (assq-ref meal-need 'met))) (and (number? m) (>= m 0) (<= m 1))))
(check-pred "need carries a labour figure" (number? (assq-ref meal-need 'labour-h)))

(test-summary!)
