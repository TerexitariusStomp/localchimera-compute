;;; test-demand-critique.scm — solvability critique via relational planner.

(use-modules (playnet test harness)
             (playnet deprecated planner)
             (playnet deprecated governance demand-critique)
             (goblins)
             (srfi srfi-1))


(define* (make-demand-intent spec qty unit #:optional (at-loc #f))
  ;; Minimal demand-side intent (receiver=scope, provider=#f).
  (make-intent #:action 'use #:name "test demand" #:resource-conforms-to spec #:resource-classified-as '()
    #:resource-quantity (and spec qty (make-measure qty unit)) #:receiver "test-scope"
    #:at-location at-loc #:in-scope-of '("test-scope")))


;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup: scope with a bread recipe (wheat → flour → bread)
;;; ════════════════════════════════════════════════════════════════════════════

(define vat (spawn-vat))

(with-vat vat
  (define scope (spawn-scope-root "test-scope"))
  (let ((rs ($ scope 'recipe-store)))

    ;; Specs
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-wheat" #:name "Wheat" #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-flour" #:name "Flour" #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-bread" #:name "Bread"
                                    #:default-unit-of-resource "each"))
    ;; Caviar spec EXISTS but has NO recipe → infeasible path.
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-caviar" #:name "Caviar"
                                    #:default-unit-of-resource "g"))

    ;; Bread recipe (mill + bake)
    ($ rs 'add-process-spec
       (make-process-specification #:id "pspec-mill" #:name "Milling"))
    ($ rs 'add-process-spec
       (make-process-specification #:id "pspec-bake" #:name "Baking"))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-mill" #:name "Mill" #:process-conforms-to "pspec-mill"
                            #:has-duration (make-duration 2 "hours")))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-bake" #:name "Bake" #:process-conforms-to "pspec-bake"
                            #:has-duration (make-duration 4 "hours")))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-wheat-in" #:action 'consume #:resource-conforms-to "spec-wheat"
                         #:resource-quantity (make-measure 10 "kg") #:recipe-input-of "rp-mill"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-flour-out" #:action 'produce #:resource-conforms-to "spec-flour"
                         #:resource-quantity (make-measure 8 "kg") #:recipe-output-of "rp-mill"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-flour-in" #:action 'consume #:resource-conforms-to "spec-flour"
                         #:resource-quantity (make-measure 8 "kg") #:recipe-input-of "rp-bake"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-bread-out" #:action 'produce #:resource-conforms-to "spec-bread"
                         #:resource-quantity (make-measure 20 "each") #:recipe-output-of "rp-bake"))
    ($ rs 'add-recipe
       (make-recipe #:id "recipe-bread" #:name "Bread Production" #:primary-output "spec-bread"
                    #:recipe-processes (list "rp-mill" "rp-bake"))))


  ;; ════════════════════════════════════════════════════════════════════
  ;; 1. Vague: no spec at all
  ;; ════════════════════════════════════════════════════════════════════

  (display "\n── 1. Vague (no spec) ──\n")
  (let* ((wish (make-demand-intent #f #f #f))
         (c (critique-demand scope wish)))
    (check-pred "no spec → vague"
                (eq? 'vague (critique-category c)))
    (check-pred "vague offers a suggestion"
                (pair? (critique-suggestions c))))


  ;; ════════════════════════════════════════════════════════════════════
  ;; 2. Vague: spec but no quantity
  ;; ════════════════════════════════════════════════════════════════════

  (display "\n── 2. Vague (no quantity) ──\n")
  (let* ((wish (make-demand-intent "spec-bread" #f "each"))
         (c (critique-demand scope wish)))
    (check-pred "spec without qty → vague"
                (eq? 'vague (critique-category c))))


  ;; ════════════════════════════════════════════════════════════════════
  ;; 3. Infeasible: spec with no recipe
  ;; ════════════════════════════════════════════════════════════════════

  (display "\n── 3. Infeasible (no recipe) ──\n")
  (let* ((wish (make-demand-intent "spec-caviar" 50 "g"))
         (c (critique-demand scope wish)))
    (check-pred "no recipe → infeasible"
                (eq? 'infeasible (critique-category c)))
    (check-pred "infeasible offers suggestions"
                (pair? (critique-suggestions c))))


  ;; ════════════════════════════════════════════════════════════════════
  ;; 4. Tractable: bread has a full recipe chain
  ;; ════════════════════════════════════════════════════════════════════

  (display "\n── 4. Tractable (full recipe chain) ──\n")
  (let* ((wish (make-demand-intent "spec-bread" 20 "each"))
         (c (critique-demand scope wish)))
    (check-pred "bread with recipe → tractable"
                (eq? 'tractable (critique-category c)))
    (check-pred "plan-preview carries a plan-term"
                (and (critique-plan-preview c) #t))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
