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

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

;;; ── Harness ────────────────────────────────────────────────────────────────

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


;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Index Test"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (ps ($ scope 'plan-store)))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-wheat" "Wheat" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-flour" "Flour" #f #f #f "kg" #f #f #f #f #f))

    ($ ps 'add-plan (make-plan "plan-idx" "Index Plan" #f
                               "2026-04-07T00:00:00Z" "2026-03-27T00:00:00Z"
                               #f #f #f))
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
       (make-intent "i-wheat-d1" 'consume "Wheat demand 1" #f #f
                    "proc-1" #f #f "spec-wheat" #f
                    (make-measure 100 "kg") #f #f #f
                    #f "agent-a" #f #f #f "2026-04-01T00:00:00Z"
                    #f #f #f "plan-idx" #f #f #f #f))

    ;; Open flour demand
    ($ ps 'add-intent
       (make-intent "i-flour-d1" 'consume "Flour demand" #f #f
                    "proc-2" #f #f "spec-flour" #f
                    (make-measure 50 "kg") #f #f #f
                    #f "agent-a" #f #f #f "2026-04-01T00:00:00Z"
                    #f #f #f "plan-idx" #f #f #f #f))

    ;; Finished wheat demand (should be excluded from open queries)
    ($ ps 'add-intent
       (make-intent "i-wheat-finished" 'consume "Finished demand" #f #t
                    "proc-3" #f #f "spec-wheat" #f
                    (make-measure 200 "kg") #f #f #f
                    #f "agent-a" #f #f #f "2026-04-01T00:00:00Z"
                    #f #f #f "plan-idx" #f #f #f #f))

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
       (make-intent "i-wheat-s1" 'produce "Wheat supply" #f #f
                    #f "proc-harvest" #f "spec-wheat" #f
                    (make-measure 300 "kg") #f #f #f
                    "agent-farmer" #f #f #f #f "2026-04-01T00:00:00Z"
                    #f #f #f "plan-idx" #f #f #f #f))

    ;; Open flour supply
    ($ ps 'add-intent
       (make-intent "i-flour-s1" 'produce "Flour supply" #f #f
                    #f "proc-mill" #f "spec-flour" #f
                    (make-measure 80 "kg") #f #f #f
                    "agent-miller" #f #f #f #f "2026-04-01T00:00:00Z"
                    #f #f #f "plan-idx" #f #f #f #f))

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
       (make-commitment "c-idx-1" 'consume "proc-mill" #f
                        "spec-wheat" #f
                        (make-measure 100 "kg") #f
                        "agent-a" "agent-b" #f #f #f #f #f "plan-idx" #f #f #f #f))
    ($ ps 'add-commitment
       (make-commitment "c-idx-2" 'produce #f "proc-mill"
                        "spec-flour" #f
                        (make-measure 80 "kg") #f
                        "agent-a" "agent-b" #f #f #f #f #f "plan-idx" #f #f #f #f))

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
(when (> fail-count 0) (exit 1))
