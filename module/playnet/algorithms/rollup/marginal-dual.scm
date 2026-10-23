;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; rollup/marginal-dual.scm — joint-production rollup variant (4):
;;; MARGINAL / LP-DUAL imputation.
;;;
;;; Spec: docs/planning/solve/planner-open-questions.md §3 (joint production), option (4).
;;;
;;; The principled answer to joint production is not to SPLIT a joint cost at all
;;; but to read each good's MARGINAL labour value — the pull on its
;;; balance constraint. In an activity-analysis program the dual distributes
;;; joint labour across co-products automatically and jointly-consistently, and
;;; is non-negative under convexity (no Steedman negatives). Its costs: the value
;;; is PLAN-DEPENDENT (it shifts with demand and which processes are active), and
;;; it is non-unique at a degenerate/flat optimum (the §1 underdetermination).
;;;
;;; Two entry points:
;;;
;;;   (a) marginal-snlt-from-duals — the FAITHFUL version. The engine already
;;;       computes the dual: it is the `good-pulls` (μ) alist in a solve report
;;;       (planner.scm tension-duals → good-pulls). This projects those located
;;;       pulls to a per-spec marginal labour value. Joint production is resolved
;;;       for free; nothing here splits anything.
;;;
;;;   (b) marginal-snlt-adjoint — a SELF-CONTAINED local solve for callers without
;;;       a full plan. It builds the activity (net-put) matrix B and direct-labour
;;;       vector l over a chosen set of goods and solves the value equation
;;;       B·v = l (square) or the least-squares normal equations BᵀB·v = Bᵀl
;;;       (over-determined). This is the LINEAR (Leontief-joint) adjoint: exact
;;;       when the technology pins the goods, but it CAN return negative values —
;;;       and that negativity is surfaced as the Steedman diagnostic. The true LP
;;;       dual (a) would instead zero out an over-produced good; (b) tells you
;;;       when you are in that regime.
;;;
;;; Assumes rollup/common.scm loaded. Pure functions; store consulted via $.

(use-modules (srfi srfi-1)
             (goblins utils hashmap))

;; ===========================================================================
;; (a) the faithful dual: project the engine's good-pulls to per-spec μ
;; ===========================================================================

(define* (marginal-snlt-from-duals good-pulls
                                    #:key (key->spec identity) (aggregate 'max))
  "Per-spec marginal labour value from a solve report's `good-pulls`
   (an alist (located-good . μ), the pulls of material/eco scarcity). `key->spec`
   maps a located-good key to its bare spec (default: identity — pass a splitter
   when keys are 'spec@cell'). `aggregate` collapses a spec's per-location pulls:
   'max (default — the tightest binding scarcity) or 'mean.
   Returns ((spec . μ̄) …). This is the joint-production-correct, non-negative
   (under convexity), plan-DEPENDENT value the engine already produces."
  (let ((h (make-hash-table)))
    (for-each (lambda (kv)
                (let ((spec (key->spec (car kv))) (mu (cdr kv)))
                  (hash-set! h spec (cons mu (hash-ref h spec '())))))
              good-pulls)
    (map (lambda (kv)
           (let ((vs (cdr kv)))
             (cons (car kv)
                   (case aggregate
                     ((mean) (/ (apply + vs) (length vs)))
                     (else   (apply max vs))))))
         (hash-map->list cons h))))

;; ===========================================================================
;; tiny dense linear solver — Gaussian elimination with partial pivoting
;; ===========================================================================

(define (rollup-solve-linear A b)
  "Solve A·x = b for square A (list of n rows, each a list of n reals) and b
   (list of n). Returns the solution as a list, or #f if A is singular."
  (let* ((n (length b))
         (M (list->vector
              (map (lambda (row bi) (list->vector (append row (list bi)))) A b)))
         (row (lambda (i) (vector-ref M i)))
         (el  (lambda (i j) (vector-ref (vector-ref M i) j)))
         (set-el! (lambda (i j v) (vector-set! (vector-ref M i) j v))))
    (let elim ((c 0))
      (if (= c n)
          ;; back-substitution
          (let ((x (make-vector n 0.0)))
            (let bsub ((i (- n 1)))
              (if (< i 0)
                  (vector->list x)
                  (let ((s (el i n)))
                    (do ((j (+ i 1) (+ j 1))) ((= j n))
                      (set! s (- s (* (el i j) (vector-ref x j)))))
                    (let ((d (el i i)))
                      (if (< (abs d) 1e-12) #f
                          (begin (vector-set! x i (/ s d)) (bsub (- i 1)))))))))
          ;; pivot on column c
          (let ((piv c) (best (abs (el c c))))
            (do ((r (+ c 1) (+ r 1))) ((= r n))
              (when (> (abs (el r c)) best) (set! best (abs (el r c))) (set! piv r)))
            (if (< best 1e-12)
                #f
                (begin
                  (unless (= piv c)
                    (let ((tmp (row c))) (vector-set! M c (row piv)) (vector-set! M piv tmp)))
                  (do ((r (+ c 1) (+ r 1))) ((= r n))
                    (let ((f (/ (el r c) (el c c))))
                      (do ((j c (+ j 1))) ((> j n))
                        (set-el! r j (- (el r j) (* f (el c j)))))))
                  (elim (+ c 1)))))))))

(define (rollup-mat*vec A x) (map (lambda (row) (apply + (map * row x))) A))
(define (rollup-transpose A) (if (null? (car A)) '() (apply map list A)))
(define (rollup-mat*mat A B) (let ((Bt (rollup-transpose B)))
                               (map (lambda (ar) (map (lambda (bc) (apply + (map * ar bc))) Bt)) A)))

;; ===========================================================================
;; (b) the self-contained activity adjoint over a chosen set of goods
;; ===========================================================================

(define (rollup-all-processes store)
  "All distinct <recipe-process> across all recipes (dedup by process id)."
  (delete-duplicates
    (append-map (lambda (r) (rollup-store-procs store (recipe-id r)))
                ($ store 'all-recipes))
    (lambda (a b) (equal? (recipe-process-id a) (recipe-process-id b)))))

(define* (rollup-process-row store rp specs sne-index #:optional (price #f))
  "For one process and an ordered list of goods SPECS, return
   (values netput-row direct-labour), where netput-row[g] = produced − consumed
   of specs[g], and direct-labour = work hours + embodied cost of consumed inputs
   that are NOT among SPECS (those carry a known SNE; the goods in SPECS are the
   unknowns being solved for)."
  (let* ((io   ($ store 'flows-for-process (recipe-process-id rp)))
         (ins  (car io)) (outs (cdr io))
         (idx  (let ((h (make-hash-table)) (i 0))
                 (for-each (lambda (s) (hash-set! h s i) (set! i (+ i 1))) specs) h))
         (net  (make-vector (length specs) 0.0))
         (l    0.0))
    (define (bump! spec delta)
      (let ((i (hash-ref idx spec #f)))
        (when i (vector-set! net i (+ (vector-ref net i) delta)))))
    (for-each (lambda (f)
                (let ((s (recipe-flow-resource-conforms-to f))
                      (q (rollup-mval (recipe-flow-resource-quantity f))))
                  (when (and s q) (bump! s q))))
              outs)
    (for-each (lambda (f)
                (let ((act (recipe-flow-action f))
                      (s   (recipe-flow-resource-conforms-to f)))
                  (cond
                    ((eq? act 'work)
                     (let ((e (rollup-mval (recipe-flow-effort-quantity f))))
                       (when e (set! l (+ l e)))))
                    ((and s (not (memq act *rollup-non-consuming*)))
                     (let ((q (rollup-mval (recipe-flow-resource-quantity f))))
                       (when q
                         (if (member s specs)
                             (bump! s (- q))                                   ; net-put on a solved good
                             (set! l (+ l (* q (rollup-input-price price sne-index s)))))))))))  ; outside cost — unpriceable ⇒ 0, see common.scm
              ins)
    (values (vector->list net) l)))

(define* (marginal-snlt-adjoint store specs #:key (sne-index (hashmap)) (price #f))
  "Self-contained marginal (Leontief-joint) labour values for the goods SPECS,
   from the activity adjoint over every process that touches them. Solves B·v = l
   when #processes = #goods, else the least-squares normal equations. Returns:
     ((values . ((spec . v) …))
      (processes . m) (goods . n)
      (regime . determined|over-determined|under-determined|singular)
      (any-negative? . bool)   ; the Steedman flag — see file header
      (residual . r))          ; ‖B·v − l‖₁ (0 in the determined, non-singular case)
   When any-negative? is #t, the linear adjoint is degenerate for this technology
   and the true LP dual (marginal-snlt-from-duals) is the honest value."
  (let* ((procs (rollup-all-processes store))
         (rows  (filter-map
                  (lambda (rp)
                    (call-with-values (lambda () (rollup-process-row store rp specs sne-index price))
                      (lambda (net l)
                        (and (any (lambda (x) (> (abs x) 1e-12)) net) (cons net l)))))
                  procs))
         (B (map car rows)) (l (map cdr rows))
         (m (length B)) (n (length specs)))
    (define (package v regime resid)
      `((values . ,(map cons specs v))
        (processes . ,m) (goods . ,n) (regime . ,regime)
        (any-negative? . ,(any (lambda (x) (< x -1e-9)) v))
        (residual . ,resid)))
    (cond
      ((< m n) (package (map (lambda (_) +nan.0) specs) 'under-determined +nan.0))
      ((= m n)
       (let ((v (rollup-solve-linear B l)))
         (if v (package v 'determined
                        (apply + (map (lambda (a b) (abs (- a b))) (rollup-mat*vec B v) l)))
             (package (map (lambda (_) +nan.0) specs) 'singular +nan.0))))
      (else                                                       ; over-determined ⇒ least squares
       (let* ((Bt (rollup-transpose B))
              (v (rollup-solve-linear (rollup-mat*mat Bt B) (rollup-mat*vec Bt l))))
         (if v (package v 'over-determined
                        (apply + (map (lambda (a b) (abs (- a b))) (rollup-mat*vec B v) l)))
             (package (map (lambda (_) +nan.0) specs) 'singular +nan.0)))))))
