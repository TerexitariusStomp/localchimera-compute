;;; federation.scm — Recursive streamed federation (relational/lazy)
;;;
;;; This is the relational counterpart to plan-federation.scm. Both do
;;; hierarchical scope planning + lateral matching + cross-scope
;;; retraction, but they use different substrates and have different
;;; capability profiles. See docs/federation-comparison.md for a full
;;; side-by-side.
;;;
;;; Protocol — same at every level:
;;;
;;;   scope-stream : scope → lazy stream of federation-result
;;;
;;;   federation-result = ((scope . id)
;;;                        (plan . ...)
;;;                        (deficits . list of deficit-record)
;;;                        (surpluses . list of surplus-record)
;;;                        (retraction-candidates . list)
;;;                        (lateral-matches . list of match-record)
;;;                        (retractions . list of retraction-record)
;;;                        (harmony . (total . n) ...)      ; when weight-fn
;;;                        (residual . number))
;;;
;;;   deficit-record  = ((scope-id . id) (spec-id . s) (qty . q))
;;;   surplus-record  = ((scope-id . id) (spec-id . s) (qty . q))
;;;   match-record    = ((from-scope . s) (to-scope . t) (spec-id . x) (qty . q))
;;;
;;; Key names align with plan-federation.scm for consistency.
;;;
;;; Leaf: miniKanren search over local facts (plan-o from plan-relation.scm).
;;; Parent: interleave children's streams + lateral matching.
;;; When lateral matching exhausts surpluses but deficits remain, the
;;; retraction stream lazily retracts satisfied demands across scopes
;;; to free capacity for higher-priority needs. In harmony mode, the
;;; candidate with smallest expected weighted-harmony loss is retracted
;;; first, and the remaining candidates are re-sorted after each step.
;;; Consumers don't know or care which kind of stream they're pulling from.
;;;
;;; NETTING EQUIVALENCE
;;; -------------------
;;; The imperative plan-federation.scm uses a pure-state-monad netter
;;; (<netter-state> in netting.scm) to track allocated flows and call
;;; netter-retract when reclaiming resources for cross-scope reuse.
;;;
;;; This relational version has NO explicit netter. Its equivalent is
;;; the CLP(FD) global sum constraint system in allocation.scm:
;;;
;;;   - Each allocation posts a claim into the N field of the cstate
;;;     (see claim-from-o in allocation.scm)
;;;   - sum-leq-check enforces sum(claims) ≤ inventory globally
;;;   - Backtracking in miniKanren automatically restores the cstate,
;;;     which automatically unclaims flows — no explicit retract call
;;;     is needed because there was no mutation
;;;
;;; So "retraction" in this file means something narrower than in
;;; plan-federation.scm. Here it's a bookkeeping move on the already-
;;; reified plan: the satisfied demand is removed from
;;; retraction-candidates and its resources become surplus, allowing
;;; lateral matching to give them to another scope. The underlying
;;; CLP(FD) claims from the original search are untouched — we're
;;; editing the OUTPUT, not re-running the search.
;;;
;;; This is why retract-demand-from-state doesn't need to call
;;; anything like netter-retract: there's no stateful allocation to
;;; unwind. The plan was produced by a single relational search; the
;;; federation layer edits that plan's presentation for rebalancing.
;;;
;;; CAPABILITY GAP
;;; --------------
;;; federation.scm currently uses plan-o (plan-relation.scm) directly,
;;; which does single-pass relational BOM explosion. It does NOT run
;;; the multi-pass DDMRP pipeline (plan-for-unit.scm: buffer-zone
;;; evaluation, TOY-gated primary demand, derived replenishment,
;;; retry, supply phase). That pipeline is currently only available
;;; through the imperative plan-federation.scm path. Closing this gap
;;; is a future architectural decision; see docs/federation-comparison.md
;;; for options.

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Hierarchy
;;; ══════════════════════════════════════════════════════════════════════════════

(define (scope-parent-o facts child parent)
  (in-list-o `(scope-parent ,child ,parent) facts))

(define (peer-scopes-o facts scope-a scope-b)
  (fresh (parent)
    (scope-parent-o facts scope-a parent)
    (scope-parent-o facts scope-b parent)
    (=/= scope-a scope-b)))

(define (build-hierarchy facts scope-ids parent-map)
  "scope-id → list of child-ids."
  (let ((ch (make-hash-table)))
    (for-each (lambda (id) (hash-set! ch id '())) scope-ids)
    (for-each (lambda (id)
                (let ((parent (assoc-ref parent-map id)))
                  (when (and parent (member parent scope-ids))
                    (hash-set! ch parent (cons id (hash-ref ch parent '()))))))
              scope-ids)
    (hash-map->list cons ch)))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; scope-stream — the universal protocol
;;; ══════════════════════════════════════════════════════════════════════════════

(define* (scope-stream facts scope-id ctx-map children-of
                       #:key (priority-fn #f) (weight-fn #f))
  (scope-stream* facts scope-id ctx-map children-of '()
                 #:priority-fn priority-fn #:weight-fn weight-fn))

(define* (scope-stream* facts scope-id ctx-map children-of visited
                        #:key (priority-fn #f) (weight-fn #f))
  "Produce a lazy stream of federation-results for SCOPE-ID.
   VISITED guards against cycles in the scope-parent graph.
   WEIGHT-FN is an optional (spec-id) → weight function; when provided,
   each result carries a harmony score."
  (if (member scope-id visited)
      '()  ;; cycle detected — stop
      (let ((children (or (assoc-ref children-of scope-id) '()))
            (visited* (cons scope-id visited)))
        (if (null? children)
            (leaf-stream scope-id ctx-map #:weight-fn weight-fn)
            (parent-stream facts scope-id children ctx-map children-of visited*
                           #:priority-fn priority-fn
                           #:weight-fn weight-fn)))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Leaf stream
;;; ══════════════════════════════════════════════════════════════════════════════

(define* (leaf-stream scope-id ctx-map #:key (weight-fn #f))
  "Lazy stream of federation-results from a miniKanren search.
   When WEIGHT-FN is provided, each result carries a harmony score."
  (let* ((ctx (assoc-ref ctx-map scope-id))
         (raw (if ctx
                  ((fresh (plan) (plan-o ctx plan #:max-depth 5))
                   (empty-cstate #f))
                  '())))
    (stream-map-lazy
      (lambda (state)
        (let* ((plan (reify-from-state state))
               (defs (extract-deficits plan scope-id))
               (surps (extract-surpluses plan scope-id))
               (cands (extract-retraction-candidates plan scope-id))
               (resid (fold (lambda (d a) (+ a (assq-ref d 'qty))) 0 defs))
               (harmony-result (and weight-fn
                                    (plan-harmony plan #:priority-fn weight-fn)))
               (base `((scope . ,scope-id) (plan . ,plan)
                       (deficits . ,defs) (surpluses . ,surps)
                       (retraction-candidates . ,cands)
                       (residual . ,resid))))
          (if harmony-result
              (cons `(harmony . ,harmony-result) base)
              base)))
      raw)))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Parent stream
;;; ══════════════════════════════════════════════════════════════════════════════

(define *max-steps* 50)

(define* (parent-stream facts scope-id children ctx-map children-of visited
                        #:key (priority-fn #f) (weight-fn #f))
  "Lazy stream: interleave children's streams + lateral matching + retraction."
  (let* ((child-streams
           (map (lambda (cid)
                  (cons cid (scope-stream* facts cid ctx-map children-of visited
                                           #:priority-fn priority-fn
                                           #:weight-fn weight-fn)))
                children))
         (initial (pull-from-all child-streams)))
    (if (null? initial)
        '()
        (search-stream facts scope-id initial *max-steps*
                       priority-fn weight-fn))))

(define (search-stream facts scope-id state steps priority-fn weight-fn)
  "Lazy stream of improving federation-results.
   When advance-worst exhausts stream positions, chains into retraction.
   When WEIGHT-FN is provided, advance steering uses weighted harmony
   (advance the child with the lowest weighted harmony) instead of raw
   deficit quantity."
  (let ((result (evaluate-state facts scope-id state priority-fn weight-fn)))
    (if (or (<= steps 0) (= (assq-ref result 'residual) 0))
        (list result)
        (cons result
              (lambda ()
                (let ((advanced (if weight-fn
                                    (advance-worst-by-harmony state result weight-fn)
                                    (advance-worst state result))))
                  (if advanced
                      (search-stream facts scope-id advanced (- steps 1)
                                     priority-fn weight-fn)
                      ;; No more stream positions — try retraction
                      (retraction-stream facts scope-id state result
                                         priority-fn weight-fn))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Evaluate: match children's results at this level
;;; ══════════════════════════════════════════════════════════════════════════════

(define* (evaluate-state facts scope-id state priority-fn
                         #:optional (weight-fn #f))
  "state = list of (child-id federation-result rest-stream).
   Returns a federation-result for this scope. When WEIGHT-FN is
   provided, child harmonies are aggregated into the parent result."
  (let* (;; Each child's deficits, re-attributed to the CHILD (not the leaf)
         (child-defs
           (append-map (lambda (s)
             (let* ((cid (car s))
                    (child-result (cadr s))
                    (raw-defs (or (and (pair? child-result)
                                       (assq-ref child-result 'deficits))
                                  '())))
               (map (lambda (d) (cons (cons 'child cid) d)) raw-defs)))
             state))
         (child-surps
           (append-map (lambda (s)
             (let* ((child-result (cadr s))
                    (raw-surps (or (and (pair? child-result)
                                        (assq-ref child-result 'surpluses))
                                   '())))
               raw-surps))
             state))
         ;; Collect retraction candidates from all children, assign priority
         (child-cands
           (append-map (lambda (s)
             (let* ((cid (car s))
                    (child-result (cadr s))
                    (raw-cands (or (and (pair? child-result)
                                        (assq-ref child-result 'retraction-candidates))
                                   '())))
               (map (lambda (c)
                      (if (and priority-fn (not (assq-ref c 'priority)))
                          (cons `(priority . ,(priority-fn cid (assq-ref c 'spec-id))) c)
                          c))
                    raw-cands)))
             state))
         ;; Match laterally
         (match-result (match-at-level child-defs child-surps))
         (matches (car match-result))
         (unmatched (cdr match-result))
         (residual (fold (lambda (d a) (+ a (assq-ref d 'qty))) 0 unmatched))
         ;; Combined plan
         (child-plans (map (lambda (s)
           (let ((cr (cadr s)))
             (cons (car s) (if (pair? cr) (assq-ref cr 'plan) '()))))
           state))
         ;; Aggregate harmony from children when weight-fn is provided
         (child-harmonies
           (if weight-fn
               (filter-map
                 (lambda (s)
                   (let ((cr (cadr s)))
                     (and (pair? cr) (assq-ref cr 'harmony))))
                 state)
               '()))
         (total-harmony
           (if weight-fn
               (fold (lambda (h acc) (+ acc (or (assq-ref h 'total) 0)))
                     0 child-harmonies)
               #f)))
    `((scope . ,scope-id)
      (plan . ,child-plans)
      ,@(if total-harmony
            `((harmony . ((total . ,total-harmony)
                          (per-child . ,child-harmonies))))
            '())
      (deficits . ,unmatched)
      (surpluses . ,(subtract-matched child-surps matches))
      (retraction-candidates . ,child-cands)
      (lateral-matches . ,matches)
      (residual . ,residual))))

(define (subtract-matched surpluses matches)
  "Reduce surpluses by matched quantities. Fully consumed surpluses are removed."
  (fold (lambda (m sups)
    (filter-map (lambda (s)
      (if (and (equal? (assq-ref s 'scope-id) (assq-ref m 'from-scope))
               (equal? (assq-ref s 'spec-id) (assq-ref m 'spec-id)))
          (let ((new-qty (- (assq-ref s 'qty) (assq-ref m 'qty))))
            (if (<= new-qty 0) #f
                (cons (cons 'qty new-qty)
                      (filter (lambda (p) (not (eq? (car p) 'qty))) s))))
          s))
      sups))
    surpluses matches))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Lateral matching
;;; ══════════════════════════════════════════════════════════════════════════════

(define (match-at-level deficits surpluses)
  "Match deficits with surpluses (same spec-id, different scope).
   Returns (matches . unmatched-deficits).
   Matches: ((from-scope . s) (to-scope . t) (spec-id . x) (qty . q))"
  (let loop ((defs deficits) (sups surpluses) (matches '()) (unmatched '()))
    (if (null? defs)
        (cons (reverse matches) (reverse unmatched))
        (let* ((d (car defs))
               (dsp (assq-ref d 'spec-id)) (dq (assq-ref d 'qty))
               (d-scope (or (assq-ref d 'child) (assq-ref d 'scope-id)))
               (m (find (lambda (s)
                          (and (equal? (assq-ref s 'spec-id) dsp)
                               (not (equal? (assq-ref s 'scope-id) d-scope))
                               (> (assq-ref s 'qty) 0)))
                        sups)))
          (if (not m)
              (loop (cdr defs) sups matches (cons d unmatched))
              (let* ((sq (assq-ref m 'qty)) (q (min dq sq))
                     (match `((from-scope . ,(assq-ref m 'scope-id))
                              (to-scope . ,d-scope)
                              (spec-id . ,dsp) (qty . ,q)))
                     (new-sups (map (lambda (s)
                       (if (eq? s m)
                           (cons (cons 'qty (- sq q))
                                 (filter (lambda (p) (not (eq? (car p) 'qty))) s))
                           s))
                       sups)))
                (if (>= q dq)
                    (loop (cdr defs) new-sups (cons match matches) unmatched)
                    (let ((remaining-d (cons (cons 'qty (- dq q))
                                             (filter (lambda (p) (not (eq? (car p) 'qty))) d))))
                      (loop (cons remaining-d (cdr defs)) new-sups
                            (cons match matches) unmatched)))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Retraction stream — lazy cross-scope priority-aware retraction
;;; ══════════════════════════════════════════════════════════════════════════════

(define (retraction-stream facts scope-id state result priority-fn weight-fn)
  "Lazy stream: retract satisfied demands to free capacity for deficits.
   When WEIGHT-FN is provided, candidates are ordered by expected
   harmony loss given the current deficits — this accounts for the
   quadratic nature of partial retraction. Otherwise falls back to
   legacy priority-sort (lowest priority first)."
  (let* ((candidates (or (assq-ref result 'retraction-candidates) '()))
         (deficits (or (assq-ref result 'deficits) '()))
         (sorted
           (if weight-fn
               (sort candidates
                 (lambda (a b)
                   (< (expected-retraction-loss a deficits weight-fn)
                      (expected-retraction-loss b deficits weight-fn))))
               (sort candidates
                 (lambda (a b)
                   (> (or (assq-ref a 'priority) 53)
                      (or (assq-ref b 'priority) 53)))))))
    (if (or (null? sorted) (null? deficits))
        (list result)
        (retract-one-stream facts scope-id state sorted result
                            priority-fn weight-fn))))

(define (deficit-spec d)
  "Extract spec-id from a deficit alist."
  (assq-ref d 'spec-id))

(define (expected-retraction-loss cand deficits weight-fn)
  "Expected weighted-harmony loss from retracting CAND, given the
   current deficits. Uses retraction-loss-exact with the expected
   transfer amount (the sum of deficits matching this candidate's
   spec, clamped to the candidate's qty)."
  (let* ((spec (assq-ref cand 'spec-id))
         (cand-qty (or (assq-ref cand 'qty) 0))
         (total-matching-deficit
           (fold (lambda (d acc)
                   (if (equal? (deficit-spec d) spec)
                       (+ acc (or (assq-ref d 'qty) 0))
                       acc))
                 0 deficits))
         (expected-transfer (min cand-qty total-matching-deficit)))
    (if (<= expected-transfer 0)
        ;; No matching deficit — this candidate won't be retracted usefully.
        ;; Rank it as "infinitely bad" so it's never picked first.
        (+ 1e18 (retraction-loss-upper cand weight-fn))
        (retraction-loss-exact cand expected-transfer weight-fn))))

(define (retraction-harmony-loss cand weight-fn)
  "Upper-bound weighted-harmony loss for sort ordering.
   Deprecated in favor of expected-retraction-loss (which is
   deficit-aware). Kept for backward compatibility."
  (retraction-loss-upper cand weight-fn))

(define (retract-one-stream facts scope-id state candidates prev-result
                             priority-fn weight-fn)
  "Each step: retract one candidate, re-evaluate lateral matching.
   When WEIGHT-FN is given, candidates are re-sorted between steps so
   that the sort key reflects the post-retraction deficits."
  (if (null? candidates)
      (list prev-result)
      (let* ((cand (car candidates))
             (transfer-qty (expected-transfer-for-cand cand prev-result))
             (new-state (retract-demand-from-state state cand))
             (new-result (evaluate-state facts scope-id new-state
                                         priority-fn weight-fn))
             (enriched-cand (enrich-retraction-record cand transfer-qty prev-result)))
        (cond
          ((= (assq-ref new-result 'residual) 0)
           (list (add-retraction-record new-result enriched-cand)))
          ((< (assq-ref new-result 'residual)
              (assq-ref prev-result 'residual))
           (let* ((result* (add-retraction-record new-result enriched-cand))
                  (rest-cands (cdr candidates))
                  ;; Re-sort remaining candidates against updated deficits
                  (resorted (if weight-fn
                                (sort rest-cands
                                  (lambda (a b)
                                    (< (expected-retraction-loss a
                                         (or (assq-ref result* 'deficits) '())
                                         weight-fn)
                                       (expected-retraction-loss b
                                         (or (assq-ref result* 'deficits) '())
                                         weight-fn))))
                                rest-cands)))
             (cons result*
                   (lambda ()
                     (retract-one-stream facts scope-id new-state
                       resorted result* priority-fn weight-fn)))))
          (else
           (retract-one-stream facts scope-id new-state
             (cdr candidates) prev-result priority-fn weight-fn))))))

(define (expected-transfer-for-cand cand result)
  "How much of CAND is expected to be transferred in a retraction,
   given the deficits in RESULT. Used for informational purposes
   when recording retractions."
  (let* ((spec (assq-ref cand 'spec-id))
         (cand-qty (or (assq-ref cand 'qty) 0))
         (deficits (or (assq-ref result 'deficits) '()))
         (total-def
           (fold (lambda (d acc)
                   (if (equal? (deficit-spec d) spec)
                       (+ acc (or (assq-ref d 'qty) 0))
                       acc))
                 0 deficits)))
    (min cand-qty total-def)))

(define (enrich-retraction-record cand transfer-qty prev-result)
  "Wrap a retraction candidate with additional fields for the
   retraction record: transferred quantity and target scope(s).
   Target scopes are inferred from deficits that match this candidate."
  (let* ((spec (assq-ref cand 'spec-id))
         (deficits (or (assq-ref prev-result 'deficits) '()))
         (target-scopes
           (filter-map
             (lambda (d)
               (and (equal? (deficit-spec d) spec)
                    (or (assq-ref d 'child) (assq-ref d 'scope-id))))
             deficits)))
    `((from-scope . ,(assq-ref cand 'scope-id))
      (to-scopes . ,target-scopes)
      (spec-id . ,spec)
      (qty . ,transfer-qty)
      (retracted-plan-id . ,(assq-ref cand 'plan-id))
      ,@cand)))

(define (retract-demand-from-state state candidate)
  "Federation-level retraction: remove a satisfied demand from its child's
   result and convert its resources to surplus."
  (let ((target-scope (assq-ref candidate 'scope-id))
        (target-spec (assq-ref candidate 'spec-id))
        (target-qty (assq-ref candidate 'qty)))
    (map (lambda (entry)
           (let ((cid (car entry))
                 (child-result (cadr entry))
                 (stream (caddr entry)))
             (if (not (equal? cid target-scope))
                 entry
                 (let* ((old-cands (or (and (pair? child-result)
                                            (assq-ref child-result 'retraction-candidates))
                                       '()))
                        (new-cands (filter
                                     (lambda (c)
                                       (not (and (equal? (assq-ref c 'spec-id) target-spec)
                                                 (equal? (assq-ref c 'plan-id)
                                                         (assq-ref candidate 'plan-id)))))
                                     old-cands))
                        (old-surps (or (and (pair? child-result)
                                            (assq-ref child-result 'surpluses))
                                       '()))
                        (new-surps (cons `((scope . ,cid) (spec . ,target-spec)
                                          (qty . ,target-qty))
                                        old-surps))
                        (new-result
                          (map (lambda (pair)
                                 (cond
                                   ((eq? (car pair) 'retraction-candidates)
                                    (cons 'retraction-candidates new-cands))
                                   ((eq? (car pair) 'surpluses)
                                    (cons 'surpluses new-surps))
                                   (else pair)))
                               child-result)))
                   (list cid new-result stream)))))
         state)))

(define (add-retraction-record result candidate)
  "Add a retraction to the result's retractions list."
  (let ((existing (or (assq-ref result 'retractions) '())))
    (cons (cons 'retractions (cons candidate existing))
          (filter (lambda (p) (not (eq? (car p) 'retractions))) result))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Advance: move the worst child's stream forward one step
;;; ══════════════════════════════════════════════════════════════════════════════

(define (advance-worst state result)
  "Advance the child whose deficit is largest (legacy: deficit-quantity)."
  (let ((unmatched (or (assq-ref result 'deficits) '())))
    (if (null? unmatched) #f
        (let* ((sorted (sort unmatched
                  (lambda (a b) (> (assq-ref a 'qty) (assq-ref b 'qty)))))
               (worst-child (or (assq-ref (car sorted) 'child)
                                (assq-ref (car sorted) 'scope-id))))
          (advance-child state worst-child)))))

(define (advance-worst-by-harmony state result weight-fn)
  "Advance the child whose weighted harmony is lowest.
   STATE = list of (child-id federation-result rest-stream).
   Falls back to deficit-based advance if no child has a harmony score."
  (let* ((scored
           (filter-map
             (lambda (entry)
               (let* ((cid (car entry))
                      (cr (cadr entry))
                      (h (and (pair? cr) (assq-ref cr 'harmony)))
                      (total (and h (assq-ref h 'total))))
                 (and total (cons cid total))))
             state)))
    (if (null? scored)
        (advance-worst state result)  ;; fallback
        (let* ((sorted (sort scored (lambda (a b) (< (cdr a) (cdr b)))))
               (worst-child (car (car sorted))))
          (advance-child state worst-child)))))

(define (advance-child state child-id)
  "Pull next result from CHILD-ID's stream. Returns updated state or #f."
  (let loop ((entries state) (acc '()))
    (if (null? entries) #f
        (let ((entry (car entries)))
          (if (not (equal? (car entry) child-id))
              (loop (cdr entries) (cons entry acc))
              (let* ((stream (caddr entry))
                     (next (stream-take-1 stream)))
                (if (not next) #f
                    (append (reverse acc)
                            (list (list child-id (car next) (cdr next)))
                            (cdr entries)))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Stream utilities
;;; ══════════════════════════════════════════════════════════════════════════════

(define (stream-map-lazy f $)
  (cond
    ((null? $) '())
    ((procedure? $) (lambda () (stream-map-lazy f ($))))
    (else (cons (f (car $)) (stream-map-lazy f (cdr $))))))

(define (stream-take-1 $)
  (cond
    ((null? $) #f)
    ((procedure? $) (stream-take-1 ($)))
    (else (cons (car $) (cdr $)))))

(define (stream-take-best $)
  "Force the entire stream, return the last (most improved) result."
  (let loop (($ $) (last #f))
    (cond
      ((null? $) last)
      ((procedure? $) (loop ($) last))
      (else (loop (cdr $) (car $))))))

(define (pull-from-all child-streams)
  "Pull one federation-result from each child's stream.
   Returns list of (child-id result rest-stream) triples."
  (let loop ((cs child-streams) (acc '()))
    (if (null? cs) (reverse acc)
        (let* ((cid (caar cs)) (stream (cdar cs))
               (pulled (stream-take-1 stream)))
          (loop (cdr cs)
                (cons (if pulled
                          (list cid (car pulled) (cdr pulled))
                          (list cid '() '()))
                      acc))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Helpers
;;; ══════════════════════════════════════════════════════════════════════════════

(define (reify-from-state state)
  (let* ((S (cstate-S state))
         (v (walk* (var 0) S))
         (R (reify-s v '())))
    (walk* v R)))

(define (reify-s v subst)
  (let ((v (walk v subst)))
    (cond
     ((var? v) (cons (cons v (string->symbol
                    (string-append "_." (number->string (length subst))))) subst))
     ((pair? v) (reify-s (cdr v) (reify-s (car v) subst)))
     (else subst))))

(define (extract-deficits plan scope-id)
  "Extract unmet demands as deficit records.
   Each deficit: ((scope-id . id) (spec-id . s) (qty . q))."
  (if (not (list? plan)) '()
      (filter-map (lambda (entry)
        (and (pair? entry) (pair? (cadr entry))
             (eq? (caadr entry) 'unmet)
             `((scope-id . ,scope-id) (spec-id . ,(cadadr entry))
               (qty . ,(caddr (cadr entry))))))
        plan)))

(define (extract-surpluses plan scope-id)
  "Extract over-produced output as surplus records.
   Each surplus: ((scope-id . id) (spec-id . s) (qty . q))."
  (if (not (list? plan)) '()
      (filter-map (lambda (entry)
        (and (pair? entry) (pair? (cadr entry))
             (eq? (caadr entry) 'satisfied)
             (let* ((pt (cadr entry))
                    (alloc (cadddr pt))
                    (needed (caddr pt))
                    (total (if (list? alloc)
                               (fold (lambda (a acc) (+ acc (cadr a))) 0 alloc) 0))
                    (surplus (- total needed)))
               (and (> surplus 0)
                    `((scope-id . ,scope-id) (spec-id . ,(cadr pt)) (qty . ,surplus))))))
        plan)))

(define (extract-retraction-candidates plan scope-id)
  "Extract satisfied demands as retraction candidates from a relational plan."
  (if (not (list? plan)) '()
      (filter-map (lambda (entry)
        (and (pair? entry) (pair? (cadr entry))
             (eq? (caadr entry) 'satisfied)
             (let* ((pt (cadr entry))
                    (spec-id (cadr pt))
                    (qty (caddr pt)))
               (and (> qty 0)
                    `((scope-id . ,scope-id)
                      (spec-id . ,spec-id)
                      (qty . ,qty))))))
        plan)))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Entry point
;;; ══════════════════════════════════════════════════════════════════════════════

(define* (plan-federation-o facts scope-ids parent-map ctx-map result
                            #:key (priority-fn #f) (weight-fn #f))
  "Recursive streamed federation. Same protocol at every level.
   priority-fn: (scope-id spec-id) → number (lower = more urgent).
   weight-fn: (spec-id) → number (higher = more important). When
   provided, federation results carry harmony scores."
  (project (facts scope-ids parent-map ctx-map)
    (let* ((children-of (build-hierarchy facts scope-ids parent-map))
           (root (or (find (lambda (id) (not (assoc-ref parent-map id))) scope-ids)
                     (and (pair? scope-ids) (car scope-ids))))
           (root-stream (if root
                            (scope-stream facts root ctx-map children-of
                                          #:priority-fn priority-fn
                                          #:weight-fn weight-fn)
                            '()))
           (best (stream-take-best root-stream)))
      (== result (if best best
                     `((scope . ,(or root "none")) (plan . ()) (residual . 0)))))))
