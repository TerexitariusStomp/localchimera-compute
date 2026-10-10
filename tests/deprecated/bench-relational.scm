;;; bench-relational.scm — Parameterized benchmark for the relational planner
;;;
;;; This is NOT part of run-tests.sh — it's a standalone driver that
;;; exercises (relational-plan) at varying problem sizes and prints
;;; a table of (wall-ms, residual, satisfied, unmet, coherence) per
;;; configuration. The output is what was missing before: a real
;;; answer to "how does the planner scale".
;;;
;;; Run:
;;;   guile --no-auto-compile -q -L module tests/deprecated/bench-relational.scm
;;;
;;; The instrumentation layer (instrumentation.scm) already records
;;; per-call wall-ms, residual, satisfied/unmet counts, and coherence.
;;; This file's contribution is the parameterized scenario generator
;;; and the table-printing driver.
;;;
;;; Two scenario shapes are exercised:
;;;
;;;   1. Linear BOM chain. spec[0] → spec[1] → … → spec[N]. Each
;;;      recipe has one consume input and one produce output. Inventory
;;;      seeded only at spec[0]. Demand on spec[N]. Tests how depth
;;;      affects search cost.
;;;
;;;   2. Wide allocation. One spec with K inventory resources of
;;;      varying sizes. One demand for total qty that requires
;;;      claiming from multiple resources. Tests how the global
;;;      sum constraint scales as the claim chain grows.
;;;
;;; Honest disclaimer: this is a single-host single-run benchmark. It
;;; gives you a number, not a distribution. Run multiple times if you
;;; want variance. Don't use it as a regression gate without first
;;; characterizing the noise floor.

(use-modules (playnet deprecated planner))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (playnet deprecated kanren-constraints)
             (srfi srfi-1))


;;; ── Scenario generators ────────────────────────────────────────────────────────

(define (make-linear-chain-scenario! scope chain-length base-inventory demand-qty)
  "Populate SCOPE with a linear BOM chain of CHAIN-LENGTH steps.

   Builds:
     spec-0 (raw, has inventory)
     spec-1 (intermediate, made from spec-0)
     spec-2 (intermediate, made from spec-1)
     ...
     spec-N (final product, has open demand)

   Each recipe: 1 consume input, 1 produce output, ratio 1:1, MBQ 1.
   Returns the final spec-id."
  (let ((rs ($ scope 'recipe-store))
        (as ($ scope 'agent-store)))
    ;; Add agent
    ($ as 'add-agent
       (make-agent #:id "agent-bench" #:type 'organization #:name "Bench Org"))
    ;; Add all specs
    (let loop ((i 0))
      (when (<= i chain-length)
        ($ rs 'add-resource-spec
           (make-resource-specification
             #:id (string-append "spec-" (number->string i))
             #:name (string-append "Spec " (number->string i)) #:default-unit-of-resource "kg"))
        (loop (+ i 1))))
    ;; Add a recipe per chain step
    (let loop ((i 1))
      (when (<= i chain-length)
        (let* ((in-spec  (string-append "spec-" (number->string (- i 1))))
               (out-spec (string-append "spec-" (number->string i)))
               (pspec    (string-append "pspec-" (number->string i)))
               (rp       (string-append "rp-"    (number->string i)))
               (recipe   (string-append "recipe-" (number->string i)))
               (in-flow  (string-append "rf-in-"  (number->string i)))
               (out-flow (string-append "rf-out-" (number->string i))))
          ($ rs 'add-process-spec
             (make-process-specification #:id pspec
               #:name (string-append "Process " (number->string i))))
          ($ rs 'add-recipe-process
             (make-recipe-process #:id rp
               #:name (string-append "Step " (number->string i)) #:process-conforms-to pspec #:has-duration (make-duration 1 "hours")))
          ($ rs 'add-recipe-flow
             (make-recipe-flow #:id in-flow #:action 'consume #:resource-conforms-to in-spec
               #:resource-quantity (make-measure 1 "kg") #:recipe-input-of rp))
          ($ rs 'add-recipe-flow
             (make-recipe-flow #:id out-flow #:action 'produce #:resource-conforms-to out-spec
               #:resource-quantity (make-measure 1 "kg") #:recipe-output-of rp))
          ($ rs 'add-recipe
             (make-recipe #:id recipe
               #:name (string-append "Recipe " (number->string i)) #:primary-output out-spec #:recipe-processes (list rp))))
        (loop (+ i 1))))
    ;; Seed inventory at spec-0
    (let ((obs ($ scope 'observer)))
      ($ obs 'seed-resource
         (make-economic-resource #:id "r-raw" #:name "Raw Stock"
           #:conforms-to "spec-0"
           #:accounting-quantity (make-measure base-inventory "kg")
           #:onhand-quantity (make-measure base-inventory "kg")
           #:current-location "loc-bench" #:primary-accountable "agent-bench")))
    ;; Add demand for the final spec
    (let ((ps ($ scope 'plan-store))
          (final-spec (string-append "spec-" (number->string chain-length))))
      ($ ps 'add-intent
         (make-intent #:id "i-bench-final" #:action 'consume #:name "Final demand" #:resource-conforms-to final-spec
                      #:resource-quantity (make-measure demand-qty "kg")
                      #:provider "agent-bench" #:planned-within "bench-plan"))
      final-spec)))

(define (make-wide-allocation-scenario! scope num-resources resource-size demand-qty)
  "Populate SCOPE with NUM-RESOURCES inventory resources of one spec,
   each of size RESOURCE-SIZE, plus a demand for DEMAND-QTY units.
   Tests how the global sum constraint scales with the number of
   co-claimed resources for a single allocation."
  (let ((rs ($ scope 'recipe-store))
        (as ($ scope 'agent-store)))
    ($ as 'add-agent
       (make-agent #:id "agent-wide" #:type 'organization #:name "Wide Bench"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-wide" #:name "Wide Spec"
                                    #:default-unit-of-resource "kg")))
  (let ((obs ($ scope 'observer)))
    (let loop ((i 0))
      (when (< i num-resources)
        ($ obs 'seed-resource
           (make-economic-resource
             #:id (string-append "r-wide-" (number->string i))
             #:name (string-append "Pool " (number->string i)) #:conforms-to "spec-wide"
             #:accounting-quantity (make-measure resource-size "kg")
             #:onhand-quantity (make-measure resource-size "kg")
             #:current-location "loc-wide" #:primary-accountable "agent-wide"))
        (loop (+ i 1)))))
  (let ((ps ($ scope 'plan-store)))
    ($ ps 'add-intent
       (make-intent #:id "i-wide-demand" #:action 'consume #:name "Wide demand" #:resource-conforms-to "spec-wide"
                    #:resource-quantity (make-measure demand-qty "kg")
                    #:provider "agent-wide" #:planned-within "wide-plan"))))


;;; ── Benchmark driver ───────────────────────────────────────────────────────────

(define (bench-once name scenario-thunk)
  "Run SCENARIO-THUNK in a fresh vat, time it via instrumented-plan,
   print one row of the results table. SCENARIO-THUNK takes the scope
   actor and populates its stores."
  (let* ((store (make-memory-store))
         (log (make-perf-log)))
    (let-values (((vat scope)
                  (spawn-persistent-vat
                    scope-root-env
                    (lambda () (spawn-scope-root (string-append "Bench " name)))
                    store)))
      (with-vat vat (scenario-thunk scope))
      (with-vat vat
        (let* ((facts (lift-planning-facts ($ scope 'recipe-store)
                                            ($ scope 'observer)
                                            ($ scope 'plan-store)
                                            #f #f))
               (ctx (make-plan-ctx facts
                                    ($ scope 'plan-store)
                                    ($ scope 'observer)
                                    #f
                                    (string-append "bench-" name)
                                    (build-indexes facts))))
          (instrumented-plan 1 ctx log #:max-depth 12)
          (let* ((entries (perf-log-entries log))
                 (e (if (null? entries) #f (car entries))))
            (if e
                (format #t "  ~16a  ~6dms  ~6d  ~5d  ~5d  ~5d  ~5,2f\n"
                        name
                        (assq-ref e 'wall-ms)
                        (assq-ref e 'residual)
                        (assq-ref e 'satisfied)
                        (assq-ref e 'unmet)
                        (assq-ref e 'produced)
                        (exact->inexact (assq-ref e 'coherence)))
                (format #t "  ~16a  (no result)\n" name))))))))

(define (header)
  (format #t "  ~16a  ~8a  ~6a  ~5a  ~5a  ~5a  ~5a\n"
          "scenario" "wall" "resid" "sat" "unmet" "prod" "coh")
  (format #t "  ~16a  ~8a  ~6a  ~5a  ~5a  ~5a  ~5a\n"
          "----------------" "--------" "------" "-----" "-----" "-----" "-----"))


;;; ── Main ──────────────────────────────────────────────────────────────────────

(display "\n=== Linear BOM chain ===\n")
(display "  Recipe chain depth × inventory_at_root × demand\n\n")
(header)
(bench-once "chain-1"
  (lambda (s) (make-linear-chain-scenario! s 1 100 10)))
(bench-once "chain-2"
  (lambda (s) (make-linear-chain-scenario! s 2 100 10)))
(bench-once "chain-3"
  (lambda (s) (make-linear-chain-scenario! s 3 100 10)))
(bench-once "chain-5"
  (lambda (s) (make-linear-chain-scenario! s 5 100 10)))
(bench-once "chain-8"
  (lambda (s) (make-linear-chain-scenario! s 8 100 10)))

(display "\n=== Wide allocation ===\n")
(display "  Single demand spread across N inventory resources\n\n")
(header)
(bench-once "wide-2"
  (lambda (s) (make-wide-allocation-scenario! s 2 50 80)))
(bench-once "wide-4"
  (lambda (s) (make-wide-allocation-scenario! s 4 50 150)))
(bench-once "wide-8"
  (lambda (s) (make-wide-allocation-scenario! s 8 50 300)))
(bench-once "wide-16"
  (lambda (s) (make-wide-allocation-scenario! s 16 50 600)))
(bench-once "wide-32"
  (lambda (s) (make-wide-allocation-scenario! s 32 50 1200)))

(newline)
(display "Done. Read each row as: scenario wall-ms residual sat unmet prod coherence\n")
(display "Coherence in [0,1] (1 = fully internally satisfied).\n")
