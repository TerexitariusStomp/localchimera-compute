;;; test-plan-actor.scm — ^plan-actor unit tests
;;;
;;; Exercises the plan-actor API against a small reified plan with a
;;; produce term (recipe chain), and verifies that:
;;;   - scalars (coherence, residual) are correct and cheap
;;;   - list accessors (deficits, surpluses, retraction-candidates)
;;;     produce the same values as the inline-extract path
;;;   - subplan-of returns a fresh ref for produce terms and #f otherwise
;;;   - the full reified plan round-trips through (full)

(setvbuf (current-output-port) 'line)

(use-modules (playnet test harness)
             (playnet deprecated planner)
             (goblins) (goblins vat))

(define vat (spawn-vat))


;;; ── Fixtures ──────────────────────────────────────────────────────────────

;; A plan with one satisfied demand, one produce demand, one unmet.
;; Shape per plan-walk.scm:6-10:
;;   Plan       := list of DemandPair
;;   DemandPair := (demand-alist plan-term)
;;   PlanTerm   := (satisfied spec-id qty allocated)
;;              |  (unmet spec-id qty)
;;              |  (produce spec-id rid scale sub-plans)

(define sample-plan
  '((((spec-id . "apple") (quantity . 5))
     (satisfied "apple" 5 (("res-1" 5))))
    (((spec-id . "pie") (quantity . 3))
     (produce "pie" "recipe-pie" 3
              ;; sub-plans: produce needs flour + apple internally
              ((((spec-id . "flour") (quantity . 3))
                (satisfied "flour" 3 (("res-2" 3))))
               (((spec-id . "apple") (quantity . 3))
                (satisfied "apple" 3 (("res-1" 3)))))))
    (((spec-id . "bread") (quantity . 4))
     (unmet "bread" 4))))


;;; ── Tests ──────────────────────────────────────────────────────────────

(with-vat vat
  (let ((pa (spawn ^plan-actor sample-plan 'commune-alpha #f)))

    (display "\n── Basic accessors ──\n")
    (check "scope returns scope-id"
           ($ pa 'scope) 'commune-alpha)
    (check "full returns inline plan"
           ($ pa 'full) sample-plan)
    (check "demand-pairs returns the list"
           ($ pa 'demand-pairs) sample-plan)

    (display "\n── Scalars ──\n")
    ;; coherence: 5 satisfied-apple + 3 produce-pie = 8 internal;
    ;; 4 unmet-bread = 4 external. The sub-plans inside produce also
    ;; have satisfied flour=3 + apple=3 = 6 more internal. Total:
    ;; (5 + 3 + 6) / (5 + 3 + 6 + 4) = 14/18.
    ;; Wait — plan-internal-qty counts produce as 0 (sub-allocations
    ;; counted separately via fold-plan-terms recursion). So internal =
    ;; 5 (apple-sat) + 3 (flour-sat) + 3 (apple-sat sub) = 11;
    ;; external = 4 (unmet-bread). total = 11 + 4 = 15. coherence = 11/15.
    (check "coherence is 11/15"
           ($ pa 'coherence) 11/15)
    ;; residual is sum of unmet qty — only top-level bread unmet = 4
    (check "residual is 4"
           ($ pa 'residual) 4)
    (check "harmony is #f without weight-fn"
           ($ pa 'harmony) #f)

    (display "\n── Deficits / surpluses ──\n")
    (let ((defs ($ pa 'deficits)))
      (check "one deficit"
             (length defs) 1)
      (check "deficit spec is bread"
             (assq-ref (car defs) 'spec-id) "bread")
      (check "deficit qty is 4"
             (assq-ref (car defs) 'qty) 4))

    (display "\n── Retraction candidates ──\n")
    (let ((cands ($ pa 'retraction-candidates)))
      ;; Only top-level satisfied demands are candidates (per extract-
      ;; retraction-candidates via fold-demand-pairs, no recursion).
      ;; So we expect one candidate: apple.
      (check "one retraction candidate at top level"
             (length cands) 1)
      (check "candidate is apple"
             (assq-ref (car cands) 'spec-id) "apple"))

    (display "\n── subplan-of ──\n")
    (let* ((pairs ($ pa 'demand-pairs))
           (produce-pair (cadr pairs))
           (produce-term (cadr produce-pair))
           (sub-ref ($ pa 'subplan-of produce-term)))
      (check "subplan-of returns a ref for produce term"
             (not (not sub-ref)))
      (when sub-ref
        (check "sub-actor scope inherits"
               ($ sub-ref 'scope) 'commune-alpha)
        (check "sub-actor full has two sub-demands"
               (length ($ sub-ref 'full)) 2)))

    (let* ((satisfied-term (cadr (car ($ pa 'demand-pairs)))))
      (check "subplan-of #f for satisfied term"
             ($ pa 'subplan-of satisfied-term) #f))
    (let* ((unmet-term (cadr (caddr ($ pa 'demand-pairs)))))
      (check "subplan-of #f for unmet term"
             ($ pa 'subplan-of unmet-term) #f))


    (display "\n── Federation-result constructor ──\n")
    (let ((result (relational-plan->plan-actor-result
                    sample-plan 'commune-beta #f)))
      (check "has plan-ref field"
             (not (not (assq-ref result 'plan-ref))))
      (check "has no inline plan field"
             (assq-ref result 'plan) #f)
      (check "scope matches"
             (assq-ref result 'scope) 'commune-beta)
      (check "coherence matches plan-actor"
             (assq-ref result 'coherence) 11/15)
      (check "residual matches"
             (assq-ref result 'residual) 4)
      (check "federation-result-plan-ref returns ref"
             (not (not (federation-result-plan-ref result))))
      (check "federation-result-plan forces through ref"
             (federation-result-plan result) sample-plan))


    (display "\n── Equivalence: inline mode vs plan-actor mode ──\n")
    ;; relational-plan->federation-result (inline) and
    ;; relational-plan->plan-actor-result (ref) should produce
    ;; observably equivalent federation-results for all scope-boundary
    ;; fields the parent actually reads.
    (let ((inline (relational-plan->federation-result
                    sample-plan 'scope-eq #f))
          (ref-mode (relational-plan->plan-actor-result
                      sample-plan 'scope-eq #f)))
      (check "same scope"
             (assq-ref inline 'scope) (assq-ref ref-mode 'scope))
      (check "same coherence"
             (assq-ref inline 'coherence) (assq-ref ref-mode 'coherence))
      (check "same residual"
             (assq-ref inline 'residual) (assq-ref ref-mode 'residual))
      (check "same deficits"
             (assq-ref inline 'deficits) (assq-ref ref-mode 'deficits))
      (check "same surpluses"
             (assq-ref inline 'surpluses) (assq-ref ref-mode 'surpluses))
      (check "retraction-candidates equal after force"
             (force-cands (assq-ref inline 'retraction-candidates))
             (force-cands (assq-ref ref-mode 'retraction-candidates)))
      ;; Inline has 'plan, ref has 'plan-ref; both represent the same data
      (check "inline plan equals plan-ref's (full)"
             (assq-ref inline 'plan)
             ($ (assq-ref ref-mode 'plan-ref) 'full))
      ;; federation-result-plan should give the same inline structure
      ;; regardless of which mode the result came from
      (check "federation-result-plan works for inline"
             (federation-result-plan inline) sample-plan)
      (check "federation-result-plan works for ref"
             (federation-result-plan ref-mode) sample-plan))))


(format #t "~%=== Results: ~a passed, ~a failed ===~%" pass-count fail-count)
(exit (if (zero? fail-count) 0 1))
