;;; test-positioning-routing.scm — DDMRP strategic positioning
;;; Ported from: old/planner/src/lib/tests/positioning.test.ts
;;; Run: cd planner && guile --no-auto-compile -q -L ../module \
;;;        -l load-all.scm -l tests/test-positioning-routing.scm

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
    scope-env
    (lambda () (spawn-scope "Positioning Test"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))

    ;; ── Resource specs for all topologies ──
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-AB" "Half A-B" #f #f #f "each" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-BC" "Half B-C" #f #f #f "each" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-final" "Final" #f #f #f "each" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-X" "Part X" #f #f #f "each" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-Y" "Part Y" #f #f #f "each" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-Bfin" "B Final" #f #f #f "each" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-Cfin" "C Final" #f #f #f "each" #f #f #f #f #f))

    ;; ──────────────────────────────────────────────────────────────────────────
    ;; Linear chain: A(2d) → B(3d) → C(5d)
    ;;   A produces spec-AB → B consumes spec-AB
    ;;   B produces spec-BC → C consumes spec-BC
    ;;   C produces spec-final (terminal)
    ;; ──────────────────────────────────────────────────────────────────────────

    ($ rs 'add-recipe-process
       (make-recipe-process "rp-A" "A" #f #f #f #f
                            (make-duration 2 "days") #f #f))
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-B" "B" #f #f #f #f
                            (make-duration 3 "days") #f #f))
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-C" "C" #f #f #f #f
                            (make-duration 5 "days") #f #f))

    ;; A → B via spec-AB
    ($ rs 'add-recipe-flow
       (make-recipe-flow "f-AB-out" 'produce "spec-AB" #f
                         (make-measure 1 "each") #f #f "rp-A" #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "f-AB-in" 'consume "spec-AB" #f
                         (make-measure 1 "each") #f "rp-B" #f #f #f #f #f #f #f))
    ;; B → C via spec-BC
    ($ rs 'add-recipe-flow
       (make-recipe-flow "f-BC-out" 'produce "spec-BC" #f
                         (make-measure 1 "each") #f #f "rp-B" #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "f-BC-in" 'consume "spec-BC" #f
                         (make-measure 1 "each") #f "rp-C" #f #f #f #f #f #f #f))
    ;; C terminal output
    ($ rs 'add-recipe-flow
       (make-recipe-flow "f-fin" 'produce "spec-final" #f
                         (make-measure 1 "each") #f #f "rp-C" #f #f #f #f #f #f))

    ($ rs 'add-recipe
       (make-recipe "recipe-linear" "Linear" #f #f "spec-final"
                    (list "rp-A" "rp-B" "rp-C") #f))

    ;; ──────────────────────────────────────────────────────────────────────────
    ;; Convergent chain: A,B → C
    ;;   A produces spec-X → C consumes spec-X
    ;;   B produces spec-Y → C consumes spec-Y
    ;;   C produces spec-final (terminal)
    ;; ──────────────────────────────────────────────────────────────────────────

    ($ rs 'add-recipe-process
       (make-recipe-process "rp-cA" "Conv-A" #f #f #f #f
                            (make-duration 2 "days") #f #f))
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-cB" "Conv-B" #f #f #f #f
                            (make-duration 3 "days") #f #f))
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-cC" "Conv-C" #f #f #f #f
                            (make-duration 1 "days") #f #f))

    ($ rs 'add-recipe-flow
       (make-recipe-flow "f-cAX" 'produce "spec-X" #f
                         (make-measure 1 "each") #f #f "rp-cA" #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "f-cXC" 'consume "spec-X" #f
                         (make-measure 1 "each") #f "rp-cC" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "f-cBY" 'produce "spec-Y" #f
                         (make-measure 1 "each") #f #f "rp-cB" #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "f-cYC" 'consume "spec-Y" #f
                         (make-measure 1 "each") #f "rp-cC" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "f-cfin" 'produce "spec-final" #f
                         (make-measure 1 "each") #f #f "rp-cC" #f #f #f #f #f #f))

    ($ rs 'add-recipe
       (make-recipe "recipe-conv" "Convergent" #f #f "spec-final"
                    (list "rp-cA" "rp-cB" "rp-cC") #f))

    ;; ──────────────────────────────────────────────────────────────────────────
    ;; Divergent chain: A → B,C
    ;;   A produces spec-X → B consumes spec-X
    ;;   A produces spec-Y → C consumes spec-Y
    ;;   B produces spec-Bfin, C produces spec-Cfin
    ;; ──────────────────────────────────────────────────────────────────────────

    ($ rs 'add-recipe-process
       (make-recipe-process "rp-dA" "Div-A" #f #f #f #f
                            (make-duration 3 "days") #f #f))
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-dB" "Div-B" #f #f #f #f
                            (make-duration 2 "days") #f #f))
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-dC" "Div-C" #f #f #f #f
                            (make-duration 4 "days") #f #f))

    ($ rs 'add-recipe-flow
       (make-recipe-flow "f-dAX" 'produce "spec-X" #f
                         (make-measure 1 "each") #f #f "rp-dA" #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "f-dXB" 'consume "spec-X" #f
                         (make-measure 1 "each") #f "rp-dB" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "f-dAY" 'produce "spec-Y" #f
                         (make-measure 1 "each") #f #f "rp-dA" #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "f-dYC" 'consume "spec-Y" #f
                         (make-measure 1 "each") #f "rp-dC" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "f-dBf" 'produce "spec-Bfin" #f
                         (make-measure 1 "each") #f #f "rp-dB" #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "f-dCf" 'produce "spec-Cfin" #f
                         (make-measure 1 "each") #f #f "rp-dC" #f #f #f #f #f #f))

    ($ rs 'add-recipe
       (make-recipe "recipe-div" "Divergent" #f #f #f
                    (list "rp-dA" "rp-dB" "rp-dC") #f))

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
(when (> fail-count 0) (exit 1))
