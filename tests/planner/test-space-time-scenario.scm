;;; test-space-time-scenario.scm — Scenario operations
;;;
;;; Tests scenario and scenario-definition CRUD, inline scoring of
;;; coverage from intents/commitments, monoidal merge of two plan-stores,
;;; and order-independent hashing of commitment ID sets.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-space-time-scenario.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet planner plan store) (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

;;; -- Harness ----------------------------------------------------------------
(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.01)))
    (< (abs (- a b)) tol)))
;;; -- Setup ------------------------------------------------------------------

(display "\n-- Setup --\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Scenario Test"))
    store))
;;; ============================================================================
;;; All actor operations in a single with-vat block
;;; ============================================================================

(with-vat vat
  (let ((ps ($ scope 'plan-store)))

    ;; ========================================================================
    ;; 1. Scenario CRUD
    ;; ========================================================================

    (display "\n-- 1. Scenario CRUD --\n")

    ($ ps 'add-scenario '((id . "scen-1") (name . "Baseline") (note . "test")))

    (let ((s ($ ps 'get-scenario "scen-1")))
      (check-pred "scenario stored" s)
      (check "scenario name" (assq-ref s 'name) "Baseline")
      (check "scenario note" (assq-ref s 'note) "test"))

    (check "all-scenarios count" (length ($ ps 'all-scenarios)) 1)
    ;; ========================================================================
    ;; 2. ScenarioDefinition CRUD
    ;; ========================================================================

    (display "\n-- 2. ScenarioDefinition CRUD --\n")

    ($ ps 'add-scenario-definition '((id . "sdef-1") (name . "Weekly Plan") (note . #f)))

    (let ((sd ($ ps 'get-scenario-definition "sdef-1")))
      (check-pred "sdef stored" sd)
      (check "sdef name" (assq-ref sd 'name) "Weekly Plan"))

    (check "all-scenario-definitions count"
           (length ($ ps 'all-scenario-definitions)) 1)
    ;; ========================================================================
    ;; 3. Multiple scenarios stored independently
    ;; ========================================================================

    (display "\n-- 3. Multiple scenarios --\n")

    ($ ps 'add-scenario '((id . "scen-2") (name . "Optimistic") (note . "alt")))

    (let ((s1 ($ ps 'get-scenario "scen-1"))
          (s2 ($ ps 'get-scenario "scen-2")))
      (check-pred "scen-1 still present" s1)
      (check-pred "scen-2 present" s2)
      (check "scen-1 name" (assq-ref s1 'name) "Baseline")
      (check "scen-2 name" (assq-ref s2 'name) "Optimistic"))

    (check "all-scenarios = 2" (length ($ ps 'all-scenarios)) 2)
    ;; ========================================================================
    ;; 4. Scenario scoring (inline)
    ;;    4 demand intents tagged "tag:plan:deficit"
    ;;    2 work commitments with effort-quantity
    ;;    Coverage = satisfied / total where satisfied means the intent's
    ;;    resource-conforms-to has a matching commitment.
    ;;    Total effort = sum of work commitments' effort-quantity.
    ;; ========================================================================

    (display "\n-- 4. Scenario scoring --\n")

    ;; 4 demand intents (2 for spec-bread, 2 for spec-flour)
    ($ ps 'add-intent
       (make-intent #:id "i-d1" #:action 'consume #:resource-conforms-to "spec-bread"
                    #:resource-classified-as '("tag:plan:deficit")
                    #:resource-quantity (make-measure 10 "kg")))
    ($ ps 'add-intent
       (make-intent #:id "i-d2" #:action 'consume #:resource-conforms-to "spec-bread"
                    #:resource-classified-as '("tag:plan:deficit")
                    #:resource-quantity (make-measure 5 "kg")))
    ($ ps 'add-intent
       (make-intent #:id "i-d3" #:action 'consume #:resource-conforms-to "spec-flour"
                    #:resource-classified-as '("tag:plan:deficit")
                    #:resource-quantity (make-measure 20 "kg")))
    ($ ps 'add-intent
       (make-intent #:id "i-d4" #:action 'consume #:resource-conforms-to "spec-flour"
                    #:resource-classified-as '("tag:plan:deficit")
                    #:resource-quantity (make-measure 8 "kg")))

    ;; 2 work commitments (spec-bread and spec-flour) with effort
    ($ ps 'add-commitment
       (make-commitment #:id "c-w1" #:action 'work #:resource-conforms-to "spec-bread" #:effort-quantity (make-measure 5 %effort-unit)
                        #:provider "alice"))
    ($ ps 'add-commitment
       (make-commitment #:id "c-w2" #:action 'work #:resource-conforms-to "spec-flour" #:effort-quantity (make-measure 10 %effort-unit)
                        #:provider "bob"))

    ;; Score inline: coverage = fraction of deficit intents whose spec
    ;; has a matching commitment (by resource-conforms-to).
    (let* ((all-intents ($ ps 'intents-for-tag "tag:plan:deficit"))
           (total (length all-intents))
           ;; Specs that have at least one commitment
           (satisfied-specs
             (map commitment-resource-conforms-to ($ ps 'all-commitments)))
           ;; Count intents whose spec appears in satisfied-specs
           (satisfied
             (length (filter (lambda (i)
                               (member (intent-resource-conforms-to i)
                                       satisfied-specs))
                             all-intents)))
           (coverage (if (> total 0) (/ satisfied total) 0)))
      (check "total intents = 4" total 4)
      (check "satisfied = 4" satisfied 4)
      (check-pred "coverage = 1.0" (approx= (exact->inexact coverage) 1.0)))

    ;; Total effort from work commitments
    (let* ((all-commits ($ ps 'all-commitments))
           (total-effort
             (fold (lambda (c acc)
                     (let ((eq (commitment-effort-quantity c)))
                       (if eq (+ acc (measure-has-numerical-value eq)) acc)))
                   0 all-commits)))
      (check "total effort = 15 hours" total-effort 15))
    ;; ========================================================================
    ;; 5. Scenario merging (inline)
    ;;    Plan-store A has deficit intent for spec-bread (10 kg).
    ;;    Plan-store B has surplus intent for spec-bread (50 kg).
    ;;    Merge B into A. After merge, both deficit and surplus present.
    ;;    Net: surplus (50) > deficit (10) -> 40 remaining surplus.
    ;; ========================================================================

    (display "\n-- 5. Scenario merging --\n")

    ;; Create a second plan-store B inside the same vat
    (let ((ps2 (spawn ^plan-store (empty-plan-store-state) '())))

      ;; A: deficit intent for spec-bread
      ($ ps 'add-intent
         (make-intent #:id "i-deficit-bread" #:action 'consume #:resource-conforms-to "spec-bread"
                      #:resource-classified-as '("tag:plan:deficit")
                      #:resource-quantity (make-measure 10 "kg")))

      ;; B: surplus intent for spec-bread
      ($ ps2 'add-intent
         (make-intent #:id "i-surplus-bread" #:action 'produce #:resource-conforms-to "spec-bread"
                      #:resource-classified-as '("tag:plan:surplus")
                      #:resource-quantity (make-measure 50 "kg")))

      ;; Verify B has the surplus before merge
      (check "ps2 surplus count"
             (length ($ ps2 'intents-for-tag "tag:plan:surplus")) 1)

      ;; Merge B into A
      ($ ps 'merge ps2)

      ;; After merge: A has both deficit and surplus intents
      (let ((deficits ($ ps 'intents-for-tag "tag:plan:deficit"))
            (surpluses ($ ps 'intents-for-tag "tag:plan:surplus")))
        ;; deficit count: original 4 from section 4 + 1 new = 5
        (check "deficit intents after merge = 5"
               (length deficits) 5)
        (check "surplus intents after merge = 1"
               (length surpluses) 1)

        ;; Net calculation for bread only: surplus (50 kg) vs deficit from
        ;; i-deficit-bread (10 kg). The surplus intent covers it with 40 remaining.
        (let* ((surplus-qty
                 (measure-has-numerical-value
                   (intent-resource-quantity
                     ($ ps 'get-intent "i-surplus-bread"))))
               (deficit-qty
                 (measure-has-numerical-value
                   (intent-resource-quantity
                     ($ ps 'get-intent "i-deficit-bread"))))
               (net (- surplus-qty deficit-qty)))
          (check "surplus qty = 50" surplus-qty 50)
          (check "deficit qty = 10" deficit-qty 10)
          (check "net remaining surplus = 40" net 40))))
    ;; ========================================================================
    ;; 6. Order-independent hashing (inline)
    ;;    Compute a deterministic hash over sorted commitment IDs.
    ;;    Same set in different order -> same hash.
    ;; ========================================================================

    (display "\n-- 6. Order-independent hashing --\n")

    (define (djb2-hash str)
      (let loop ((i 0) (h 5381))
        (if (>= i (string-length str)) h
            (loop (+ i 1) (+ (* h 33) (char->integer (string-ref str i)))))))

    (define (scenario-hash ids)
      (djb2-hash (string-join (sort ids string<?) ",")))

    (let ((h1 (scenario-hash '("c-1" "c-2" "c-3")))
          (h2 (scenario-hash '("c-3" "c-1" "c-2")))
          (h3 (scenario-hash '("c-1" "c-2" "c-4"))))
      (check "order-independent: same" h1 h2)
      (check-pred "different content: different" (not (= h1 h3))))))
;;; -- Summary ----------------------------------------------------------------

(newline)
(display (string-append "-- Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed --\n"))
(test-summary!)
