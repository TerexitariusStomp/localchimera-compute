;;; test-container-mediation.scm — Container-mediated resource consumption
;;;
;;; Intent: Verify the resolveFromFlow pattern in VF recipes. When a recipe
;;; needs to consume a resource that is contained inside another resource,
;;; it resolves the contained resource from the anchor flow (the `use` of
;;; the container). Example: Soil contains nitrogen. A harvest recipe uses
;;; soil (anchor) and consumes nitrogen (resolved from the soil container).
;;;
;;; Tests data-level correctness: recipe flow linkage, containment
;;; relationships, flow validation, relational queries, and scale factors.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-container-mediation.scm

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (playnet kanren-constraints)
             (srfi srfi-1))


;;; -- Harness ---------------------------------------------------------------

(define pass-count 0)
(define fail-count 0)

(define (check label got expected)
  (if (equal? got expected)
      (begin (set! pass-count (+ pass-count 1))
             (display (string-append "  PASS  " label "\n")))
      (begin (set! fail-count (+ fail-count 1))
             (display (string-append "  FAIL  " label "\n"))
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write got)      (newline))))

(define (check-pred label pred)
  (if pred
      (begin (set! pass-count (+ pass-count 1))
             (display (string-append "  PASS  " label "\n")))
      (begin (set! fail-count (+ fail-count 1))
             (display (string-append "  FAIL  " label "\n")))))

(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.01)))
    (< (abs (- a b)) tol)))


;;; ==========================================================================
;;; Setup
;;; ==========================================================================

(display "\n-- Setup: Container mediation scope --\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Container Mediation Test"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (obs ($ scope 'observer)))

    ;; -- Resource specifications --
    ;; spec-soil: plot-based (container)
    ;; spec-nitrogen: kg-based (contained resource)
    ;; spec-food: kg-based (output)
    ($ rs 'add-resource-spec
       (make-resource-specification
         "spec-soil" "Soil" #f #f #f "plot" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification
         "spec-nitrogen" "Nitrogen" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification
         "spec-food" "Food" #f #f #f "kg" #f #f #f #f #f))

    ;; -- Process specification --
    ($ rs 'add-process-spec
       (make-process-specification
         "pspec-harvest" "Harvesting" #f #f #f #f #f #f #f))

    ;; -- Recipe process: harvest (4 hours) --
    ($ rs 'add-recipe-process
       (make-recipe-process
         "rp-harvest" "Harvest" #f #f "pspec-harvest" #f
         (make-duration 4 "hours") #f #f))

    ;; -- Recipe flows --
    ;; rf-use-soil: use soil (anchor flow, the container)
    ($ rs 'add-recipe-flow
       (make-recipe-flow
         "rf-use-soil" 'use "spec-soil" #f
         (make-measure 1 "plot") #f
         "rp-harvest" #f #f #f #f #f #f #f))

    ;; rf-consume-n: consume nitrogen, resolved from the soil anchor
    ($ rs 'add-recipe-flow
       (make-recipe-flow
         "rf-consume-n" 'consume "spec-nitrogen" #f
         (make-measure 5 "kg") #f
         "rp-harvest" #f #f #f #f #f #f "rf-use-soil"))

    ;; rf-produce-food: produce food
    ($ rs 'add-recipe-flow
       (make-recipe-flow
         "rf-produce-food" 'produce "spec-food" #f
         (make-measure 10 "kg") #f
         #f "rp-harvest" #f #f #f #f #f #f))

    ;; -- Recipe --
    ($ rs 'add-recipe
       (make-recipe
         "recipe-harvest" "Harvest Production" #f #f "spec-food"
         (list "rp-harvest") #f))

    ;; -- Resources --
    ;; r-field-a: a plot of soil (the container)
    ($ obs 'seed-resource
       (make-economic-resource
         "r-field-a" "Field A" #f #f #f "spec-soil" #f
         (make-measure 1 "plot") (make-measure 1 "plot")
         #f #f "agent-farm" #f #f #f
         #f #f #f #f #f))

    ;; r-nitrogen-a: nitrogen contained in field-a
    ($ obs 'seed-resource
       (make-economic-resource
         "r-nitrogen-a" "Nitrogen in Field A" #f #f #f "spec-nitrogen" #f
         (make-measure 20 "kg") (make-measure 20 "kg")
         #f #f "agent-farm" #f #f #f
         "r-field-a" #f #f #f #f))

    (check-pred "setup: recipe seeded"
                (pair? ($ rs 'get-process-chain "recipe-harvest")))
    (check-pred "setup: resources seeded"
                (= 2 (length ($ obs 'all-resources))))))


;;; ==========================================================================
;;; 1. Recipe flow structure -- verify resolve-from-flow linkage
;;; ==========================================================================

(display "\n-- 1. Recipe flow structure --\n")

(with-vat vat
  (let* ((rs ($ scope 'recipe-store))
         (rf-n ($ rs 'get-recipe-flow "rf-consume-n"))
         (rf-soil ($ rs 'get-recipe-flow "rf-use-soil"))
         (rf-food ($ rs 'get-recipe-flow "rf-produce-food")))

    (check "rf-consume-n: resolve-from-flow = rf-use-soil"
           (recipe-flow-resolve-from-flow rf-n)
           "rf-use-soil")

    (check "rf-use-soil: resolve-from-flow = #f"
           (recipe-flow-resolve-from-flow rf-soil)
           #f)

    (check "rf-produce-food: resolve-from-flow = #f"
           (recipe-flow-resolve-from-flow rf-food)
           #f)))


;;; ==========================================================================
;;; 2. Containment relationship -- verify contained-in on resources
;;; ==========================================================================

(display "\n-- 2. Containment relationship --\n")

(with-vat vat
  (let* ((obs ($ scope 'observer))
         (r-n ($ obs 'get-resource "r-nitrogen-a"))
         (r-s ($ obs 'get-resource "r-field-a")))

    (check "r-nitrogen-a: contained-in = r-field-a"
           (economic-resource-contained-in r-n)
           "r-field-a")

    (check "r-field-a: contained-in = #f (top-level)"
           (economic-resource-contained-in r-s)
           #f)

    (check "r-nitrogen-a: conforms-to = spec-nitrogen"
           (economic-resource-conforms-to r-n)
           "spec-nitrogen")

    (check "r-nitrogen-a: qty = 20"
           (measure-has-numerical-value (economic-resource-accounting-quantity r-n))
           20)))


;;; ==========================================================================
;;; 3. Anchor flow is use action
;;; ==========================================================================

(display "\n-- 3. Anchor flow is use action --\n")

(with-vat vat
  (let* ((rs ($ scope 'recipe-store))
         (rf-soil ($ rs 'get-recipe-flow "rf-use-soil")))

    (check "anchor flow action = use"
           (recipe-flow-action rf-soil)
           'use)

    (check-pred "anchor flow action is not consume"
                (not (eq? (recipe-flow-action rf-soil) 'consume)))

    (check-pred "anchor flow action is not cite"
                (not (eq? (recipe-flow-action rf-soil) 'cite)))))


;;; ==========================================================================
;;; 4. Dependent flow is consume
;;; ==========================================================================

(display "\n-- 4. Dependent flow is consume --\n")

(with-vat vat
  (let* ((rs ($ scope 'recipe-store))
         (rf-n ($ rs 'get-recipe-flow "rf-consume-n")))

    (check "dependent flow action = consume"
           (recipe-flow-action rf-n)
           'consume)

    (check "dependent flow spec = spec-nitrogen"
           (recipe-flow-resource-conforms-to rf-n)
           "spec-nitrogen")

    (check "dependent flow qty = 5 kg"
           (measure-has-numerical-value (recipe-flow-resource-quantity rf-n))
           5)))


;;; ==========================================================================
;;; 5. Contained resource invisible to normal queries
;;;
;;; conforming-resources returns all resources for a spec, but the
;;; dependent-demand algorithm filters out contained resources (those
;;; with contained-in set). Verify the filtering logic here.
;;; ==========================================================================

(display "\n-- 5. Contained resource invisible to normal queries --\n")

(with-vat vat
  (let* ((obs ($ scope 'observer))
         (all-nitrogen ($ obs 'conforming-resources "spec-nitrogen"))
         (free-nitrogen (filter
                          (lambda (r) (not (economic-resource-contained-in r)))
                          all-nitrogen)))

    ;; conforming-resources finds the nitrogen (it exists)
    (check "conforming-resources: finds nitrogen"
           (length all-nitrogen)
           1)

    ;; But when filtered by not-contained-in (as dependent-demand does),
    ;; no free-standing nitrogen exists
    (check "free nitrogen: empty (all contained)"
           (length free-nitrogen)
           0)))


;;; ==========================================================================
;;; 6. Free-standing resource visible
;;; ==========================================================================

(display "\n-- 6. Free-standing resource visible --\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed a free-standing nitrogen resource (not contained in anything)
    ($ obs 'seed-resource
       (make-economic-resource
         "r-free-nitrogen" "Free Nitrogen" #f #f #f "spec-nitrogen" #f
         (make-measure 10 "kg") (make-measure 10 "kg")
         #f #f "agent-supplier" #f #f #f
         #f #f #f #f #f))

    (let* ((all-nitrogen ($ obs 'conforming-resources "spec-nitrogen"))
           (free-nitrogen (filter
                            (lambda (r) (not (economic-resource-contained-in r)))
                            all-nitrogen)))

      (check "conforming-resources: finds 2 nitrogen resources"
             (length all-nitrogen)
             2)

      (check "free nitrogen: 1 free-standing"
             (length free-nitrogen)
             1)

      (check "free nitrogen is r-free-nitrogen"
             (economic-resource-id (car free-nitrogen))
             "r-free-nitrogen"))))


;;; ==========================================================================
;;; 7. Relational flow verification
;;;
;;; The lifted fact base encodes flows as:
;;;   (flow pid direction spec-id qty unit action)
;;; The resolve-from-flow linkage is not in the lifted facts (it stays
;;; at the record level). Verify via flow-o that the structural facts
;;; exist: harvest process has both a use-soil input and a consume-nitrogen
;;; input, plus a produce-food output.
;;; ==========================================================================

(display "\n-- 7. Relational flow verification --\n")

(with-vat vat
  (let* ((ns (empty-netter-state))
         (facts (lift-planning-facts ($ scope 'recipe-store))))

    ;; Verify use-soil flow exists as an input to rp-harvest
    (let ((results (run-plan* ns (q)
                     (fresh (qty unit)
                       (flow-o facts "rp-harvest" 'input "spec-soil" qty unit 'use)
                       (== q (list qty unit))))))
      (check-pred "flow-o: use-soil input exists" (pair? results))
      (when (pair? results)
        (check "flow-o: soil qty = 1"
               (car (car results))
               1)))

    ;; Verify consume-nitrogen flow exists as an input to rp-harvest
    (let ((results (run-plan* ns (q)
                     (fresh (qty unit)
                       (flow-o facts "rp-harvest" 'input "spec-nitrogen" qty unit 'consume)
                       (== q (list qty unit))))))
      (check-pred "flow-o: consume-nitrogen input exists" (pair? results))
      (when (pair? results)
        (check "flow-o: nitrogen qty = 5"
               (car (car results))
               5)))

    ;; Verify produce-food flow exists as an output of rp-harvest
    (let ((results (run-plan* ns (q)
                     (fresh (qty unit)
                       (flow-o facts "rp-harvest" 'output "spec-food" qty unit 'produce)
                       (== q (list qty unit))))))
      (check-pred "flow-o: produce-food output exists" (pair? results))
      (when (pair? results)
        (check "flow-o: food qty = 10"
               (car (car results))
               10)))

    ;; Cross-check: the resolve-from-flow linkage at the record level
    ;; matches the structural flow facts
    (let* ((rs ($ scope 'recipe-store))
           (rf-n ($ rs 'get-recipe-flow "rf-consume-n"))
           (anchor-id (recipe-flow-resolve-from-flow rf-n))
           (rf-anchor ($ rs 'get-recipe-flow anchor-id)))
      (check-pred "anchor flow record exists"
                  (recipe-flow? rf-anchor))
      (check "anchor is input of same process"
             (recipe-flow-recipe-input-of rf-anchor)
             (recipe-flow-recipe-input-of rf-n))
      (check "anchor action is use"
             (recipe-flow-action rf-anchor)
             'use))))


;;; ==========================================================================
;;; 8. Scale factor
;;;
;;; Recipe produces 10kg food per execution, consuming 5kg nitrogen.
;;; Demand 30kg food -> scale = 3 -> needs 15kg nitrogen.
;;;
;;; We derive scale and scaled input quantities from the lifted flow
;;; facts using flow-o, avoiding functions not yet in the codebase.
;;; ==========================================================================

(display "\n-- 8. Scale factor --\n")

(with-vat vat
  (let* ((ns (empty-netter-state))
         (facts (lift-planning-facts ($ scope 'recipe-store))))

    ;; Extract the per-execution output quantity for food via flow-o
    (let ((food-out (run-plan* ns (q)
                      (fresh (unit)
                        (flow-o facts "rp-harvest" 'output "spec-food" q unit 'produce)))))
      (check-pred "food output qty found" (pair? food-out))
      (let ((output-per-run (car food-out)))  ;; 10
        (check "output per run = 10" output-per-run 10)

        ;; Scale = demand / output-per-run
        (check-pred "food scale 30->3" (approx= 3 (/ 30 output-per-run)))
        (check-pred "food scale 10->1" (approx= 1 (/ 10 output-per-run)))
        (check-pred "food scale 50->5" (approx= 5 (/ 50 output-per-run)))))

    ;; Extract nitrogen input quantity per execution via flow-o
    (let ((n-in (run-plan* ns (q)
                  (fresh (unit)
                    (flow-o facts "rp-harvest" 'input "spec-nitrogen" q unit 'consume)))))
      (check-pred "nitrogen input qty found" (pair? n-in))
      (let ((n-per-run (car n-in)))  ;; 5
        (check "nitrogen per run = 5" n-per-run 5)

        ;; At scale 3 (demand 30kg food): nitrogen = 5 * 3 = 15
        (check-pred "nitrogen qty = 15 at scale 3"
                    (approx= 15 (* n-per-run 3)))

        ;; At scale 1 (demand 10kg food): nitrogen = 5 * 1 = 5
        (check-pred "nitrogen qty = 5 at scale 1"
                    (approx= 5 (* n-per-run 1)))

        ;; At scale 5 (demand 50kg food): nitrogen = 5 * 5 = 25
        (check-pred "nitrogen qty = 25 at scale 5"
                    (approx= 25 (* n-per-run 5)))))))


;;; ==========================================================================
;;; 9. Multiple containers
;;;
;;; Two soil containers (field-a, field-b), each with contained nitrogen.
;;; Verify containment queries across multiple containers.
;;; ==========================================================================

(display "\n-- 9. Multiple containers --\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed field-b (a second container)
    ($ obs 'seed-resource
       (make-economic-resource
         "r-field-b" "Field B" #f #f #f "spec-soil" #f
         (make-measure 1 "plot") (make-measure 1 "plot")
         #f #f "agent-farm" #f #f #f
         #f #f #f #f #f))

    ;; Seed nitrogen-b contained in field-b
    ($ obs 'seed-resource
       (make-economic-resource
         "r-nitrogen-b" "Nitrogen in Field B" #f #f #f "spec-nitrogen" #f
         (make-measure 30 "kg") (make-measure 30 "kg")
         #f #f "agent-farm" #f #f #f
         "r-field-b" #f #f #f #f))

    ;; Both contained nitrogens exist
    (let ((r-na ($ obs 'get-resource "r-nitrogen-a"))
          (r-nb ($ obs 'get-resource "r-nitrogen-b")))
      (check-pred "nitrogen-a exists" (economic-resource? r-na))
      (check-pred "nitrogen-b exists" (economic-resource? r-nb))
      (check "nitrogen-a contained-in = field-a"
             (economic-resource-contained-in r-na) "r-field-a")
      (check "nitrogen-b contained-in = field-b"
             (economic-resource-contained-in r-nb) "r-field-b"))

    ;; Free-standing query excludes both contained nitrogens
    (let* ((all-nitrogen ($ obs 'conforming-resources "spec-nitrogen"))
           (free-nitrogen (filter
                            (lambda (r) (not (economic-resource-contained-in r)))
                            all-nitrogen)))
      ;; We have: r-nitrogen-a (contained), r-nitrogen-b (contained), r-free-nitrogen (free)
      (check "total nitrogen resources = 3" (length all-nitrogen) 3)
      (check "free nitrogen = 1 (r-free-nitrogen only)" (length free-nitrogen) 1)
      (check "free nitrogen id"
             (economic-resource-id (car free-nitrogen)) "r-free-nitrogen"))

    ;; Add a third uncontained nitrogen and verify it IS visible
    ($ obs 'seed-resource
       (make-economic-resource
         "r-nitrogen-loose" "Loose Nitrogen" #f #f #f "spec-nitrogen" #f
         (make-measure 7 "kg") (make-measure 7 "kg")
         #f #f "agent-supplier" #f #f #f
         #f #f #f #f #f))

    (let* ((all-nitrogen ($ obs 'conforming-resources "spec-nitrogen"))
           (free-nitrogen (filter
                            (lambda (r) (not (economic-resource-contained-in r)))
                            all-nitrogen)))
      (check "total nitrogen after loose = 4" (length all-nitrogen) 4)
      (check "free nitrogen after loose = 2" (length free-nitrogen) 2))))


;;; ==========================================================================
;;; 10. Anchor validation — recipe flow direction checks
;;;
;;; The recipe-store's add-recipe-flow validates action direction.
;;; A produce flow with recipe-input-of set should error because
;;; produce is an output action (io='output), not valid as input.
;;; A consume flow with recipe-input-of set should succeed because
;;; consume is an input action (io='input).
;;; ==========================================================================

(display "\n-- 10. Anchor validation --\n")

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    ;; produce + recipe-input-of should error
    (check-pred "validation: produce as input errors"
      (catch #t
        (lambda ()
          ($ rs 'add-recipe-flow
             (make-recipe-flow
               "rf-bad-produce" 'produce "spec-food" #f
               (make-measure 5 "kg") #f
               "rp-harvest" #f #f #f #f #f #f #f))
          #f)  ;; should not reach here
        (lambda (key . args) #t)))  ;; caught error → pass

    ;; consume + recipe-input-of should succeed
    (check-pred "validation: consume as input succeeds"
      (catch #t
        (lambda ()
          ($ rs 'add-recipe-flow
             (make-recipe-flow
               "rf-ok-consume" 'consume "spec-nitrogen" #f
               (make-measure 2 "kg") #f
               "rp-harvest" #f #f #f #f #f #f #f))
          #t)  ;; success → pass
        (lambda (key . args) #f)))))  ;; error → fail


;;; ==========================================================================

(newline)
(display (string-append "-- Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed --\n"))
(when (> fail-count 0) (exit 1))
