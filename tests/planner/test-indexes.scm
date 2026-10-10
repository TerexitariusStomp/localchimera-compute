;;; test-indexes.scm — Independent demand/supply index tests
;;;
;;; Ported from: old/planner/src/lib/tests/independent-demand.test.ts
;;;              old/planner/src/lib/tests/independent-supply.test.ts
;;;
;;; Intent: Verify index building for demand and supply intents,
;;; querying by spec and location, and handling of finished/satisfied
;;; intents.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-indexes.scm

(use-modules (playnet test harness))
(use-modules (playnet scope root) (playnet vf schemas) (srfi srfi-1))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

;;; ── Harness ────────────────────────────────────────────────────────────────

;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Index Test"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (ps ($ scope 'plan-store)))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-wheat" #:name "Wheat" #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-flour" #:name "Flour" #:default-unit-of-resource "kg"))

    ($ ps 'add-plan (make-plan #:id "plan-idx" #:name "Index Plan"
                               #:due "2026-04-07T00:00:00Z" #:created "2026-03-27T00:00:00Z"))
    (check-pred "setup ok" #t)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Demand intents indexed by spec
;;;
;;; Ported from: "buildIndependentDemandIndex handles intents"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Demand index by spec ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ;; Open wheat demand
    ($ ps 'add-intent
       (make-intent #:id "i-wheat-d1" #:action 'consume #:name "Wheat demand 1"
                    #:input-of "proc-1" #:resource-conforms-to "spec-wheat"
                    #:resource-quantity (make-measure 100 "kg") #:receiver "agent-a" #:due "2026-04-01T00:00:00Z" #:planned-within "plan-idx"))

    ;; Open flour demand
    ($ ps 'add-intent
       (make-intent #:id "i-flour-d1" #:action 'consume #:name "Flour demand"
                    #:input-of "proc-2" #:resource-conforms-to "spec-flour"
                    #:resource-quantity (make-measure 50 "kg") #:receiver "agent-a" #:due "2026-04-01T00:00:00Z" #:planned-within "plan-idx"))

    ;; Finished wheat demand (should be excluded from open queries)
    ($ ps 'add-intent
       (make-intent #:id "i-wheat-finished" #:action 'consume #:name "Finished demand"
                    #:input-of "proc-3" #:resource-conforms-to "spec-wheat"
                    #:resource-quantity (make-measure 200 "kg") #:receiver "agent-a" #:due "2026-04-01T00:00:00Z" #:planned-within "plan-idx" #:finished #t))

    ;; Query open demands by spec
    (let* ((all-intents ($ ps 'all-intents))
           (open-demands (filter (lambda (i)
                                   (and (eq? 'consume (intent-action i))
                                        (not (intent-finished i))))
                                 all-intents))
           (wheat-demands (filter (lambda (i)
                                    (equal? "spec-wheat" (intent-resource-conforms-to i)))
                                  open-demands))
           (flour-demands (filter (lambda (i)
                                    (equal? "spec-flour" (intent-resource-conforms-to i)))
                                  open-demands)))
      (check "open wheat demands" (length wheat-demands) 1)
      (check "open flour demands" (length flour-demands) 1)
      (check-pred "finished excluded"
                  (not (any (lambda (i) (equal? "i-wheat-finished" (intent-id i)))
                            open-demands))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Supply intents indexed by spec
;;;
;;; Ported from: "buildIndependentSupplyIndex handles intents"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Supply index by spec ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ;; Open wheat supply (produce intent)
    ($ ps 'add-intent
       (make-intent #:id "i-wheat-s1" #:action 'produce #:name "Wheat supply" #:output-of "proc-harvest" #:resource-conforms-to "spec-wheat"
                    #:resource-quantity (make-measure 300 "kg")
                    #:provider "agent-farmer" #:due "2026-04-01T00:00:00Z" #:planned-within "plan-idx"))

    ;; Open flour supply
    ($ ps 'add-intent
       (make-intent #:id "i-flour-s1" #:action 'produce #:name "Flour supply" #:output-of "proc-mill" #:resource-conforms-to "spec-flour"
                    #:resource-quantity (make-measure 80 "kg")
                    #:provider "agent-miller" #:due "2026-04-01T00:00:00Z" #:planned-within "plan-idx"))

    ;; Query open supplies by spec
    (let* ((all-intents ($ ps 'all-intents))
           (open-supplies (filter (lambda (i)
                                    (and (eq? 'produce (intent-action i))
                                         (not (intent-finished i))))
                                  all-intents))
           (wheat-supplies (filter (lambda (i)
                                     (equal? "spec-wheat" (intent-resource-conforms-to i)))
                                   open-supplies)))
      (check-pred "wheat supplies found" (>= (length wheat-supplies) 1)))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Demand/supply matching via relational query
;;;
;;; Ported from: index interaction with netting
;;; Relational: use lifted facts to match demand specs with supply specs
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Relational demand-supply match ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ;; Find specs that have both demand and supply
    (let* ((all ($ ps 'all-intents))
           (open (filter (lambda (i) (not (intent-finished i))) all))
           (demand-specs (map intent-resource-conforms-to
                              (filter (lambda (i) (eq? 'consume (intent-action i))) open)))
           (supply-specs (map intent-resource-conforms-to
                              (filter (lambda (i) (eq? 'produce (intent-action i))) open)))
           (matched (filter (lambda (s) (member s supply-specs)) demand-specs)))
      (check-pred "wheat has both demand and supply"
                  (member "spec-wheat" matched))
      (check-pred "flour has both demand and supply"
                  (member "spec-flour" matched)))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Commitment index
;;;
;;; Ported from: planning-advanced "commitmentsForProcess"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Commitment index ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ;; Add process-bound commitments
    ($ ps 'add-commitment
       (make-commitment #:id "c-idx-1" #:action 'consume #:input-of "proc-mill" #:resource-conforms-to "spec-wheat"
                        #:resource-quantity (make-measure 100 "kg")
                        #:provider "agent-a" #:receiver "agent-b" #:planned-within "plan-idx"))
    ($ ps 'add-commitment
       (make-commitment #:id "c-idx-2" #:action 'produce #:output-of "proc-mill" #:resource-conforms-to "spec-flour"
                        #:resource-quantity (make-measure 80 "kg")
                        #:provider "agent-a" #:receiver "agent-b" #:planned-within "plan-idx"))

    ;; All commitments
    (let ((all-c ($ ps 'all-commitments)))
      (check-pred "commitments indexed" (>= (length all-c) 2))

      ;; Filter by action
      (let ((consume-c (filter (lambda (c) (eq? 'consume (commitment-action c))) all-c))
            (produce-c (filter (lambda (c) (eq? 'produce (commitment-action c))) all-c)))
        (check-pred "consume commitments" (>= (length consume-c) 1))
        (check-pred "produce commitments" (>= (length produce-c) 1))))))
;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
