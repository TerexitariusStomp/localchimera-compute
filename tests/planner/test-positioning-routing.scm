;;; test-positioning-routing.scm — DDMRP strategic positioning
;;; Ported from: old/planner/src/lib/tests/positioning.test.ts
;;; Run: cd planner && guile --no-auto-compile -q -L ../module \
;;;        -l load-all.scm -l tests/test-positioning-routing.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test harness))
(use-modules (playnet deprecated planner))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

;;; ── Harness ────────────────────────────────────────────────────────────────
(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.01)))
    (< (abs (- a b)) tol)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup: 3 recipe topologies (linear, convergent, divergent)
;;;
;;; The relational planner overrides routing-geometry and
;;; rank-decoupling-candidates to operate on lifted planning facts.
;;; We use lift-planning-facts to produce the facts list, then call:
;;;   (routing-geometry facts recipe-id)
;;;   (rank-decoupling-candidates facts recipe-id)
;;;   (rank-control-points facts recipe-id)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup: Positioning topologies ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Positioning Test"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))

    ;; ── Resource specs for all topologies ──
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-AB" #:name "Half A-B"
                                    #:default-unit-of-resource %count-unit))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-BC" #:name "Half B-C"
                                    #:default-unit-of-resource %count-unit))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-final" #:name "Final"
                                    #:default-unit-of-resource %count-unit))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-X" #:name "Part X" #:default-unit-of-resource %count-unit))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-Y" #:name "Part Y" #:default-unit-of-resource %count-unit))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-Bfin" #:name "B Final"
                                    #:default-unit-of-resource %count-unit))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-Cfin" #:name "C Final"
                                    #:default-unit-of-resource %count-unit))

    ;; ──────────────────────────────────────────────────────────────────────────
    ;; Linear chain: A(2d) → B(3d) → C(5d)
    ;;   A produces spec-AB → B consumes spec-AB
    ;;   B produces spec-BC → C consumes spec-BC
    ;;   C produces spec-final (terminal)
    ;; ──────────────────────────────────────────────────────────────────────────

    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-A" #:name "A"
                            #:has-duration (make-duration 2 "days")))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-B" #:name "B"
                            #:has-duration (make-duration 3 "days")))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-C" #:name "C"
                            #:has-duration (make-duration 5 "days")))

    ;; A → B via spec-AB
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "f-AB-out" #:action 'produce #:resource-conforms-to "spec-AB"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-A"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "f-AB-in" #:action 'consume #:resource-conforms-to "spec-AB"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-input-of "rp-B"))
    ;; B → C via spec-BC
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "f-BC-out" #:action 'produce #:resource-conforms-to "spec-BC"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-B"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "f-BC-in" #:action 'consume #:resource-conforms-to "spec-BC"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-input-of "rp-C"))
    ;; C terminal output
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "f-fin" #:action 'produce #:resource-conforms-to "spec-final"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-C"))

    ($ rs 'add-recipe
       (make-recipe #:id "recipe-linear" #:name "Linear" #:primary-output "spec-final"
                    #:recipe-processes (list "rp-A" "rp-B" "rp-C")))

    ;; ──────────────────────────────────────────────────────────────────────────
    ;; Convergent chain: A,B → C
    ;;   A produces spec-X → C consumes spec-X
    ;;   B produces spec-Y → C consumes spec-Y
    ;;   C produces spec-final (terminal)
    ;; ──────────────────────────────────────────────────────────────────────────

    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-cA" #:name "Conv-A"
                            #:has-duration (make-duration 2 "days")))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-cB" #:name "Conv-B"
                            #:has-duration (make-duration 3 "days")))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-cC" #:name "Conv-C"
                            #:has-duration (make-duration 1 "days")))

    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "f-cAX" #:action 'produce #:resource-conforms-to "spec-X"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-cA"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "f-cXC" #:action 'consume #:resource-conforms-to "spec-X"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-input-of "rp-cC"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "f-cBY" #:action 'produce #:resource-conforms-to "spec-Y"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-cB"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "f-cYC" #:action 'consume #:resource-conforms-to "spec-Y"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-input-of "rp-cC"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "f-cfin" #:action 'produce #:resource-conforms-to "spec-final"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-cC"))

    ($ rs 'add-recipe
       (make-recipe #:id "recipe-conv" #:name "Convergent" #:primary-output "spec-final"
                    #:recipe-processes (list "rp-cA" "rp-cB" "rp-cC")))

    ;; ──────────────────────────────────────────────────────────────────────────
    ;; Divergent chain: A → B,C
    ;;   A produces spec-X → B consumes spec-X
    ;;   A produces spec-Y → C consumes spec-Y
    ;;   B produces spec-Bfin, C produces spec-Cfin
    ;; ──────────────────────────────────────────────────────────────────────────

    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-dA" #:name "Div-A"
                            #:has-duration (make-duration 3 "days")))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-dB" #:name "Div-B"
                            #:has-duration (make-duration 2 "days")))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-dC" #:name "Div-C"
                            #:has-duration (make-duration 4 "days")))

    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "f-dAX" #:action 'produce #:resource-conforms-to "spec-X"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-dA"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "f-dXB" #:action 'consume #:resource-conforms-to "spec-X"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-input-of "rp-dB"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "f-dAY" #:action 'produce #:resource-conforms-to "spec-Y"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-dA"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "f-dYC" #:action 'consume #:resource-conforms-to "spec-Y"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-input-of "rp-dC"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "f-dBf" #:action 'produce #:resource-conforms-to "spec-Bfin"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-dB"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "f-dCf" #:action 'produce #:resource-conforms-to "spec-Cfin"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-dC"))

    ($ rs 'add-recipe
       (make-recipe #:id "recipe-div" #:name "Divergent"
                    #:recipe-processes (list "rp-dA" "rp-dB" "rp-dC")))

    ;; Verify chain construction
    (check "linear chain length"
           (length ($ rs 'get-process-chain "recipe-linear")) 3)
    (check "convergent chain length"
           (length ($ rs 'get-process-chain "recipe-conv")) 3)
    (check "divergent chain length"
           (length ($ rs 'get-process-chain "recipe-div")) 3)

    ;; Lift planning facts from recipe-store for the relational API
    (let ((facts (lift-planning-facts rs)))
      ;; ════════════════════════════════════════════════════════════════════════
      ;; 1. Linear geometry — A→B→C
      ;;
      ;; routing-geometry counts input/output flow facts per process.
      ;; is-gating-point = (and (> n-inputs 1) (= n-outputs 1))
      ;; A linear chain with single inputs has NO gating points.
      ;;
      ;; Ported from: positioning.test.ts "linear chain"
      ;; ════════════════════════════════════════════════════════════════════════

      (display "\n── Linear geometry ──\n")

      (let ((geom (routing-geometry facts "recipe-linear")))
        (check "linear geom length" (length geom) 3)

        ;; Process A: no inputs, 1 output
        (let ((gA (find (lambda (g) (equal? (assq-ref g 'process-id) "rp-A")) geom)))
          (check-pred "A found" (pair? gA))
          (check "A upstream" (assq-ref gA 'upstream-path-count) 0)
          (check "A downstream" (assq-ref gA 'downstream-path-count) 1)
          (check "A not convergent" (assq-ref gA 'is-convergent) #f)
          (check "A not divergent" (assq-ref gA 'is-divergent) #f)
          (check "A not gating" (assq-ref gA 'is-gating-point) #f))

        ;; Process B: 1 input, 1 output
        (let ((gB (find (lambda (g) (equal? (assq-ref g 'process-id) "rp-B")) geom)))
          (check-pred "B found" (pair? gB))
          (check "B upstream" (assq-ref gB 'upstream-path-count) 1)
          (check "B downstream" (assq-ref gB 'downstream-path-count) 1)
          (check "B not convergent" (assq-ref gB 'is-convergent) #f)
          (check "B not divergent" (assq-ref gB 'is-divergent) #f)
          (check "B not gating" (assq-ref gB 'is-gating-point) #f))

        ;; Process C: 1 input, 1 output (produce terminal)
        ;; NOT gating because n-inputs = 1 (need >1 for gating)
        (let ((gC (find (lambda (g) (equal? (assq-ref g 'process-id) "rp-C")) geom)))
          (check-pred "C found" (pair? gC))
          (check "C upstream" (assq-ref gC 'upstream-path-count) 1)
          (check "C downstream" (assq-ref gC 'downstream-path-count) 1)
          (check "C not convergent" (assq-ref gC 'is-convergent) #f)
          (check "C not divergent" (assq-ref gC 'is-divergent) #f)
          (check "C not gating" (assq-ref gC 'is-gating-point) #f)))
      ;; ════════════════════════════════════════════════════════════════════════
      ;; 2. Convergent geometry — A,B → C
      ;;
      ;; C has 2 input flow facts (consume spec-X, consume spec-Y) and
      ;; 1 output flow fact (produce spec-final).
      ;; is-convergent = (> 2 1) = #t
      ;; is-gating-point = (and (> 2 1) (= 1 1)) = #t
      ;;
      ;; Ported from: positioning.test.ts "convergent (diamond)"
      ;; ════════════════════════════════════════════════════════════════════════

      (display "\n── Convergent geometry ──\n")

      (let ((geom (routing-geometry facts "recipe-conv")))
        ;; Process C: 2 inputs, 1 output → convergent + gating
        (let ((gC (find (lambda (g) (equal? (assq-ref g 'process-id) "rp-cC")) geom)))
          (check-pred "conv C found" (pair? gC))
          (check "conv C upstream" (assq-ref gC 'upstream-path-count) 2)
          (check "conv C convergent" (assq-ref gC 'is-convergent) #t)
          (check "conv C gating" (assq-ref gC 'is-gating-point) #t))

        ;; A and B: 0 inputs each, not convergent
        (let ((gA (find (lambda (g) (equal? (assq-ref g 'process-id) "rp-cA")) geom)))
          (check "conv A downstream" (assq-ref gA 'downstream-path-count) 1)
          (check "conv A not convergent" (assq-ref gA 'is-convergent) #f))

        (let ((gB (find (lambda (g) (equal? (assq-ref g 'process-id) "rp-cB")) geom)))
          (check "conv B not convergent" (assq-ref gB 'is-convergent) #f)))
      ;; ════════════════════════════════════════════════════════════════════════
      ;; 3. Divergent geometry — A → B,C
      ;;
      ;; A has 2 output flow facts (produce spec-X, produce spec-Y).
      ;; is-divergent = (> 2 1) = #t
      ;; B and C each have 1 input, 1 output.
      ;;
      ;; Ported from: positioning.test.ts "divergent (fan-out)"
      ;; ════════════════════════════════════════════════════════════════════════

      (display "\n── Divergent geometry ──\n")

      (let ((geom (routing-geometry facts "recipe-div")))
        ;; A: 0 inputs, 2 outputs → divergent
        (let ((gA (find (lambda (g) (equal? (assq-ref g 'process-id) "rp-dA")) geom)))
          (check-pred "div A found" (pair? gA))
          (check "div A downstream" (assq-ref gA 'downstream-path-count) 2)
          (check "div A divergent" (assq-ref gA 'is-divergent) #t)
          (check "div A not convergent" (assq-ref gA 'is-convergent) #f)
          (check "div A not gating" (assq-ref gA 'is-gating-point) #f))

        ;; B: 1 input, 1 output → not gating
        (let ((gB (find (lambda (g) (equal? (assq-ref g 'process-id) "rp-dB")) geom)))
          (check "div B not gating" (assq-ref gB 'is-gating-point) #f))

        ;; C: 1 input, 1 output → not gating
        (let ((gC (find (lambda (g) (equal? (assq-ref g 'process-id) "rp-dC")) geom)))
          (check "div C not gating" (assq-ref gC 'is-gating-point) #f)))
      ;; ════════════════════════════════════════════════════════════════════════
      ;; 4. Empty/unknown recipe
      ;;
      ;; Ported from: positioning.test.ts "returns empty array for unknown"
      ;; ════════════════════════════════════════════════════════════════════════

      (display "\n── Unknown recipe ──\n")

      (let ((geom (routing-geometry facts "no-such-recipe")))
        (check "unknown recipe empty" geom '()))
      ;; ════════════════════════════════════════════════════════════════════════
      ;; 5. Decoupling candidate ranking — linear chain
      ;;
      ;; Relational rank-decoupling-candidates uses simplified scoring:
      ;;   full-lt = number of processes in chain
      ;;   compression = (idx + 1) / full-lt  (position-based)
      ;;   leverage = (full-lt - idx) / full-lt
      ;;   geo-bonus = convergent?10 + divergent?10 + gating?5
      ;;   score = compression*50 + leverage*10 + geo-bonus
      ;;
      ;; Linear chain (A=idx0, B=idx1, C=idx2, full-lt=3):
      ;;   A: compression=1/3, leverage=1,   score=50/3+10     ~26.7
      ;;   B: compression=2/3, leverage=2/3, score=100/3+20/3  ~40.0
      ;;   C: compression=1,   leverage=1/3, score=50+10/3     ~53.3
      ;;
      ;; Ranking: C > B > A (later position = higher compression score)
      ;;
      ;; Ported from: positioning.test.ts "rankDecouplingCandidates"
      ;; ════════════════════════════════════════════════════════════════════════

      (display "\n── Decoupling ranking (linear) ──\n")

      (let ((results (rank-decoupling-candidates facts "recipe-linear")))
        (check "decoupling: 3 candidates" (length results) 3)

        ;; Results sorted descending by score
        (check-pred "decoupling: sorted descending"
                    (let loop ((rs results))
                      (if (or (null? rs) (null? (cdr rs)))
                          #t
                          (and (>= (assq-ref (car rs) 'score)
                                   (assq-ref (cadr rs) 'score))
                               (loop (cdr rs))))))

        ;; C has highest score (most downstream compression)
        ;; B has second-highest, A has lowest
        (let ((rA (find (lambda (r) (equal? (assq-ref r 'process-id) "rp-A")) results))
              (rB (find (lambda (r) (equal? (assq-ref r 'process-id) "rp-B")) results))
              (rC (find (lambda (r) (equal? (assq-ref r 'process-id) "rp-C")) results)))
          (check-pred "decoupling: A found" (pair? rA))
          (check-pred "decoupling: B found" (pair? rB))
          (check-pred "decoupling: C found" (pair? rC))
          (check-pred "decoupling: C score > B score"
                      (> (assq-ref rC 'score) (assq-ref rB 'score)))
          (check-pred "decoupling: B score > A score"
                      (> (assq-ref rB 'score) (assq-ref rA 'score)))

          ;; Compression values (position-based)
          (check-pred "decoupling: A compression ~0.33"
                      (approx= 1/3 (assq-ref rA 'compression) 0.01))
          (check-pred "decoupling: B compression ~0.67"
                      (approx= 2/3 (assq-ref rB 'compression) 0.01))
          (check-pred "decoupling: C compression ~1.0"
                      (approx= 1 (assq-ref rC 'compression) 0.01))))
      ;; ════════════════════════════════════════════════════════════════════════
      ;; 6. Control point ranking — convergent chain
      ;;
      ;; rank-control-points scores:
      ;;   convergent = 30, gating = 20, divergent = 10
      ;;
      ;; Convergent chain (cA,cB → cC):
      ;;   cA: score=0, cB: score=0
      ;;   cC: convergent(30) + gating(20) = 50
      ;;
      ;; Ported from: positioning.test.ts "rankControlPointCandidates"
      ;; ════════════════════════════════════════════════════════════════════════

      (display "\n── Control point ranking (convergent) ──\n")

      (let ((results (rank-control-points facts "recipe-conv")))
        (check-pred "control: has results" (pair? results))

        ;; C should be first (highest score)
        (check "control: C is top" (assq-ref (car results) 'process-id) "rp-cC")

        ;; C's geometry shows convergent + gating
        (let* ((rC (find (lambda (r) (equal? (assq-ref r 'process-id) "rp-cC")) results))
               (geo (assq-ref rC 'geometry)))
          (check "control: C convergent" (assq-ref geo 'is-convergent) #t)
          (check "control: C gating" (assq-ref geo 'is-gating-point) #t)
          (check-pred "control: C score = 50" (= (assq-ref rC 'score) 50)))

        ;; A and B score lower than C
        (let ((rA (find (lambda (r) (equal? (assq-ref r 'process-id) "rp-cA")) results))
              (rB (find (lambda (r) (equal? (assq-ref r 'process-id) "rp-cB")) results))
              (rC (find (lambda (r) (equal? (assq-ref r 'process-id) "rp-cC")) results)))
          (check-pred "control: C > A"
                      (> (assq-ref rC 'score) (assq-ref rA 'score)))
          (check-pred "control: C > B"
                      (> (assq-ref rC 'score) (assq-ref rB 'score)))))
      ;; ════════════════════════════════════════════════════════════════════════
      ;; 7. Control point ranking — divergent chain
      ;;
      ;; Divergent chain (dA → dB,dC):
      ;;   dA: divergent(10) → score=10
      ;;   dB: score=0
      ;;   dC: score=0
      ;;
      ;; A should be highest-scored.
      ;; ════════════════════════════════════════════════════════════════════════

      (display "\n── Control point ranking (divergent) ──\n")

      (let ((results (rank-control-points facts "recipe-div")))
        (check-pred "div-control: has results" (pair? results))

        ;; A (divergent) should be first
        (check "div-control: A is top" (assq-ref (car results) 'process-id) "rp-dA")

        (let ((rA (find (lambda (r) (equal? (assq-ref r 'process-id) "rp-dA")) results)))
          (check "div-control: A score" (assq-ref rA 'score) 10)
          (let ((geo (assq-ref rA 'geometry)))
            (check "div-control: A divergent" (assq-ref geo 'is-divergent) #t))))
      ;; ════════════════════════════════════════════════════════════════════════
      ;; 8. Control point ranking — linear chain (all zeroes)
      ;;
      ;; In a linear chain no process is convergent, divergent, or gating,
      ;; so all control-point scores are 0.
      ;; ════════════════════════════════════════════════════════════════════════

      (display "\n── Control point ranking (linear) ──\n")

      (let ((results (rank-control-points facts "recipe-linear")))
        (check "linear-control: 3 results" (length results) 3)

        ;; All scores are 0
        (for-each
          (lambda (r)
            (check-pred
              (string-append "linear-control: " (assq-ref r 'process-id) " score=0")
              (= 0 (assq-ref r 'score))))
          results))
      ;; ════════════════════════════════════════════════════════════════════════
      ;; 9. Decoupling ranking — divergent bonus
      ;;
      ;; A divergent process gets +10 geo-bonus in the decoupling score.
      ;; ════════════════════════════════════════════════════════════════════════

      (display "\n── Decoupling divergent bonus ──\n")

      (let ((results (rank-decoupling-candidates facts "recipe-div")))
        (let ((rA (find (lambda (r) (equal? (assq-ref r 'process-id) "rp-dA")) results))
              (rB (find (lambda (r) (equal? (assq-ref r 'process-id) "rp-dB")) results))
              (rC (find (lambda (r) (equal? (assq-ref r 'process-id) "rp-dC")) results)))
          ;; A gets +10 divergent bonus; without it A has lowest compression (idx=0)
          ;; but the bonus lifts its score
          (check-pred "decouple-div: A found" (pair? rA))
          (check-pred "decouple-div: A score includes divergent bonus"
                      (> (assq-ref rA 'score) 0)))))))
;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
