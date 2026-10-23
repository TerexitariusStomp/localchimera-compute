;;; SPDX-License-Identifier: AGPL-3.0-or-later
 ;;; test-composition-complexity.scm — PlanStore tag/spec indexes and
;;; StoreRegistry cross-scope resolution
;;;
;;; Intent: Verify secondary index correctness (tag, spec) across
;;; add / remove / remove-for-plan lifecycle, and cross-scope qualified
;;; reference resolution via ^store-registry.
;;;
;;; Run: cd planner && guile --no-auto-compile -q -L ../module \
;;;        -l load-all.scm -l tests/test-composition-complexity.scm

(use-modules (playnet test harness))
(use-modules (playnet federation store-registry) (playnet scope root) (playnet vf schemas) (srfi srfi-1))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

;;; -- Harness ----------------------------------------------------------------
(define (approx= a b tolerance)
  (< (abs (- a b)) tolerance))
;;; ============================================================================
;;; Setup
;;; ============================================================================

(display "\n-- Setup --\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Composition Test"))
    store))
;;; ============================================================================
;;; All actor operations in a single with-vat block
;;; ============================================================================

(with-vat vat
  (let ((ps ($ scope 'plan-store)))

    ;; ========================================================================
    ;; 1. Tag index: basic query
    ;; ========================================================================

    (display "\n-- 1. Tag index: basic query --\n")

    ;; i-def-1: deficit tag, spec-wheat, plan-1
    ($ ps 'add-intent
       (make-intent #:id "i-def-1" #:action 'consume #:name "Deficit wheat" #:resource-conforms-to "spec-wheat"
                    #:resource-classified-as '("tag:plan:deficit")
                    #:resource-quantity (make-measure 100 "kg") #:receiver "agent-a" #:planned-within "plan-1"))

    ;; i-def-2: deficit tag, spec-corn, plan-1
    ($ ps 'add-intent
       (make-intent #:id "i-def-2" #:action 'consume #:name "Deficit corn" #:resource-conforms-to "spec-corn"
                    #:resource-classified-as '("tag:plan:deficit")
                    #:resource-quantity (make-measure 50 "kg") #:receiver "agent-a" #:planned-within "plan-1"))

    ;; i-surp-1: surplus tag, spec-wheat
    ($ ps 'add-intent
       (make-intent #:id "i-surp-1" #:action 'produce #:name "Surplus wheat" #:resource-conforms-to "spec-wheat"
                    #:resource-classified-as '("tag:plan:surplus")
                    #:resource-quantity (make-measure 200 "kg")
                    #:provider "agent-b"))

    (check "deficit tag count = 2"
           (length ($ ps 'intents-for-tag "tag:plan:deficit")) 2)
    (check "surplus tag count = 1"
           (length ($ ps 'intents-for-tag "tag:plan:surplus")) 1)
    ;; ========================================================================
    ;; 2. Tag index: after removeRecords
    ;; ========================================================================

    (display "\n-- 2. Tag index: after removeRecords --\n")

    ($ ps 'remove-records '() '() '("i-def-1"))

    (check "deficit tag count after remove = 1"
           (length ($ ps 'intents-for-tag "tag:plan:deficit")) 1)

    ;; The remaining deficit intent should be i-def-2
    (let ((remaining ($ ps 'intents-for-tag "tag:plan:deficit")))
      (check "remaining deficit is i-def-2"
             (intent-id (car remaining)) "i-def-2"))
    ;; ========================================================================
    ;; 3. Tag index: after removeRecordsForPlan
    ;; ========================================================================

    (display "\n-- 3. Tag index: after removeRecordsForPlan --\n")

    ;; Add a deficit intent under plan-2
    ($ ps 'add-intent
       (make-intent #:id "i-def-3" #:action 'consume #:name "Deficit rice" #:resource-conforms-to "spec-rice"
                    #:resource-classified-as '("tag:plan:deficit")
                    #:resource-quantity (make-measure 30 "kg") #:receiver "agent-a" #:planned-within "plan-2"))

    ;; Verify it was added
    (check-pred "i-def-3 exists before removal"
                (intent? ($ ps 'get-intent "i-def-3")))

    ;; Remove all records for plan-2
    ($ ps 'remove-records-for-plan "plan-2")

    ;; i-def-3 should be gone
    (check "i-def-3 removed" ($ ps 'get-intent "i-def-3") #f)

    ;; deficit tag should still have 1 (i-def-2 from plan-1)
    (check "deficit tag count after plan removal = 1"
           (length ($ ps 'intents-for-tag "tag:plan:deficit")) 1)
    ;; ========================================================================
    ;; 4. Spec index: intentsForSpec
    ;; ========================================================================

    (display "\n-- 4. Spec index: intentsForSpec --\n")

    ;; After removing i-def-1 (spec-wheat) and i-def-3 (spec-rice),
    ;; spec-wheat intents remaining: i-surp-1
    ;; spec-corn intents remaining: i-def-2
    (check "intents-for-spec spec-wheat = 1"
           (length ($ ps 'intents-for-spec "spec-wheat")) 1)
    (check "intents-for-spec spec-corn = 1"
           (length ($ ps 'intents-for-spec "spec-corn")) 1)
    (check "intents-for-spec nonexistent = 0"
           (length ($ ps 'intents-for-spec "spec-nonexistent")) 0)

    ;; Verify the wheat intent is i-surp-1
    (let ((wheat-intents ($ ps 'intents-for-spec "spec-wheat")))
      (check "wheat intent is i-surp-1"
             (intent-id (car wheat-intents)) "i-surp-1"))
    ;; ========================================================================
    ;; 5. Spec index: commitmentsForSpec
    ;; ========================================================================

    (display "\n-- 5. Spec index: commitmentsForSpec --\n")

    ;; Add a wheat commitment
    ($ ps 'add-commitment
       (make-commitment #:id "c-wheat" #:action 'consume
                        #:input-of "proc-mill" #:resource-conforms-to "spec-wheat"
                        #:resource-quantity (make-measure 100 "kg")
                        #:provider "agent-a" #:receiver "agent-b"))

    (check "commitments-for-spec spec-wheat = 1"
           (length ($ ps 'commitments-for-spec "spec-wheat")) 1)

    ;; Verify the commitment identity
    (let ((wheat-commits ($ ps 'commitments-for-spec "spec-wheat")))
      (check "wheat commitment is c-wheat"
             (commitment-id (car wheat-commits)) "c-wheat"))
    ;; ========================================================================
    ;; 6. Spec index: after removeRecords (commitment)
    ;; ========================================================================

    (display "\n-- 6. Spec index: after removeRecords (commitment) --\n")

    ($ ps 'remove-records '() '("c-wheat") '())

    (check "commitments-for-spec spec-wheat after remove = 0"
           (length ($ ps 'commitments-for-spec "spec-wheat")) 0)

    ;; Verify the commitment is gone
    (check "c-wheat removed" ($ ps 'get-commitment "c-wheat") #f)
    ;; ========================================================================
    ;; 7. StoreRegistry: resolve
    ;; ========================================================================

    (display "\n-- 7. StoreRegistry: resolve --\n")

    (let ((reg (spawn ^store-registry (hashmap))))

      ;; Register scope-1 with the plan-store
      ($ reg 'register "scope-1" ps)

      ;; Add a resolvable intent
      ($ ps 'add-intent
         (make-intent #:id "i-reg-1" #:action 'consume #:name "Registry test intent" #:resource-conforms-to "spec-wheat"
                      #:resource-classified-as '("tag:plan:deficit")
                      #:resource-quantity (make-measure 75 "kg") #:receiver "agent-c"))

      ;; Resolve it
      (let ((resolved ($ reg 'resolve (qualify "scope-1" "i-reg-1"))))
        (check-pred "resolve returns non-empty alist"
                    (pair? resolved))
        (check-pred "resolve has intent entry"
                    (assq 'intent resolved))
        (check "resolved intent id"
               (intent-id (cdr (assq 'intent resolved))) "i-reg-1"))
      ;; ====================================================================
      ;; 8. StoreRegistry: resolve nonexistent
      ;; ====================================================================

      (display "\n-- 8. StoreRegistry: resolve nonexistent --\n")

      (let ((resolved ($ reg 'resolve (qualify "scope-1" "missing"))))
        (check "nonexistent resolve is empty" resolved '()))

      ;; Also test unregistered scope
      (let ((resolved ($ reg 'resolve (qualify "scope-unknown" "i-reg-1"))))
        (check "unregistered scope resolve is empty" resolved '()))
      ;; ====================================================================
      ;; 9. StoreRegistry: resolve with meta
      ;; ====================================================================

      (display "\n-- 9. StoreRegistry: resolve with meta --\n")

      ($ ps 'set-meta "i-reg-1" '((kind . "deficit")))

      (let ((resolved ($ reg 'resolve (qualify "scope-1" "i-reg-1"))))
        (check-pred "resolve with meta has meta entry"
                    (assq 'meta resolved))
        (let ((meta (cdr (assq 'meta resolved))))
          (check "meta kind = deficit"
                 (cdr (assq 'kind meta)) "deficit")))
      ;; ====================================================================
      ;; 10. StoreRegistry: intents-for-tag cross-scope
      ;; ====================================================================

      (display "\n-- 10. StoreRegistry: intents-for-tag cross-scope --\n")

      ;; Current deficit intents: i-def-2 and i-reg-1 (both tagged deficit)
      (let ((pairs ($ reg 'intents-for-tag "tag:plan:deficit")))
        (check-pred "cross-scope deficit query returns pairs"
                    (pair? pairs))
        ;; Each result is (scope-id . intent)
        (check-pred "all pairs have scope-id = scope-1"
                    (every (lambda (p) (equal? "scope-1" (car p))) pairs))
        (check "cross-scope deficit count = 2"
               (length pairs) 2)

        ;; Verify the intents are the correct ones
        (let ((ids (map (lambda (p) (intent-id (cdr p))) pairs)))
          (check-pred "i-def-2 in cross-scope results"
                      (member "i-def-2" ids))
          (check-pred "i-reg-1 in cross-scope results"
                      (member "i-reg-1" ids))))

      ;; Surplus query
      (let ((surplus-pairs ($ reg 'intents-for-tag "tag:plan:surplus")))
        (check "cross-scope surplus count = 1"
               (length surplus-pairs) 1)
        (check "surplus pair scope-id"
               (car (car surplus-pairs)) "scope-1")
        (check "surplus pair intent id"
               (intent-id (cdr (car surplus-pairs))) "i-surp-1"))

      ;; Nonexistent tag
      (let ((empty-pairs ($ reg 'intents-for-tag "tag:plan:nonexistent")))
        (check "cross-scope nonexistent tag = 0"
               (length empty-pairs) 0)))))
;;; ============================================================================

(newline)
(display (string-append "-- Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed --\n"))
(test-summary!)
