;;; plan-federation.scm — Hierarchical federation planning
;;;
;;; Orchestrates bottom-up planning across a scope hierarchy,
;;; then performs lateral matching of surpluses against deficits.
;;; When deficits remain after lateral matching, cross-scope retraction
;;; lazily retracts lowest-priority satisfied demands from any scope
;;; to free capacity for highest-priority unmet demands.
;;;
;;; Architecture: The federation planner is a monoidal fold.
;;; Each scope is planned independently (the monoid element).
;;; foldScopes combines them bottom-up (the fold).
;;; Lateral matching is a monoid homomorphism (surplus -> agreement).
;;; Retraction is a lazy priority-ordered exploration of the trade-off space.

(define-module (playnet deprecated planner planning plan-federation)
  #:use-module (goblins)
  #:use-module (playnet deprecated planner algorithms netting)
  #:use-module (playnet deprecated planner relational harmony)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-11)
  #:export (build-scope-hierarchy fold-scopes match-laterally
            collect-remaining-deficits retract-across-scopes propagate-confirmations
            endorse-by-tally run-labour-phase plan-federation
            aggregate-federation-harmony))

(use-modules (srfi srfi-1)
             (goblins utils hashmap)
             (playnet planner federation iteration))


;; ═════════════════════════════════════════════════════════════════════════
;; Hierarchy construction
;; ═════════════════════════════════════════════════════════════════════════

(define (build-scope-hierarchy scope-ids parent-of)
  "Build children-of map and topological sort (post-order: children first).
   parent-of: hashmap of child-id -> parent-id.
   Returns (values children-of plan-order)."
  (let ((children-of (make-hash-table)))
    (for-each (lambda (id) (hash-set! children-of id '())) scope-ids)
    (for-each
      (lambda (id)
        (let ((parent (hashmap-ref parent-of id #f)))
          (when (and parent (member parent scope-ids))
            (hash-set! children-of parent
              (cons id (hash-ref children-of parent '()))))))
      scope-ids)
    (let ((visited (make-hash-table))
          (order '()))
      (define (dfs id)
        (unless (hash-ref visited id #f)
          (hash-set! visited id #t)
          (for-each dfs (hash-ref children-of id '()))
          (set! order (cons id order))))
      (for-each dfs scope-ids)
      (values children-of (reverse order)))))


;; ═════════════════════════════════════════════════════════════════════════
;; Bottom-up scope fold
;; ═════════════════════════════════════════════════════════════════════════

(define (fold-scopes plan-order children-of plan-scope-fn registry)
  "Plan each scope bottom-up, registering results in the registry.
   plan-scope-fn: (scope-id sub-plan-stores) -> plan-result alist.
   Returns hashmap of scope-id -> plan-result."
  (let ((results (hashmap)))
    (fold
      (lambda (scope-id acc)
        (let* ((child-ids (hash-ref children-of scope-id '()))
               (child-results
                 (filter-map (lambda (cid)
                               (hashmap-ref acc cid #f))
                             child-ids))
               (result (plan-scope-fn scope-id child-results)))
          (hashmap-set acc scope-id result)))
      results
      plan-order)))


;; ═════════════════════════════════════════════════════════════════════════
;; Lateral matching — surplus/deficit across sibling scopes
;; ═════════════════════════════════════════════════════════════════════════

(define (match-laterally by-scope-results parent-of)
  "Match surpluses against deficits across unrelated scopes.
   Returns list of match alists."
  (let ((offers '())
        (requests '())
        (matches '()))

    (hashmap-fold
      (lambda (scope-id result _acc)
        (let ((surpluses (or (assq-ref result 'surplus-signals) '())))
          (for-each
            (lambda (s)
              (set! offers
                (cons `((scope-id . ,scope-id)
                        (spec-id . ,(assq-ref s 'spec-id))
                        (quantity . ,(assq-ref s 'qty))
                        (remaining . ,(assq-ref s 'qty)))
                      offers)))
            surpluses))
        #f)
      #f by-scope-results)

    (hashmap-fold
      (lambda (scope-id result _acc)
        (let ((deficits (or (assq-ref result 'deficit-signals) '())))
          (for-each
            (lambda (d)
              (set! requests
                (cons `((scope-id . ,scope-id)
                        (spec-id . ,(assq-ref d 'spec-id))
                        (quantity . ,(assq-ref d 'qty))
                        (remaining . ,(assq-ref d 'qty)))
                      requests)))
            deficits))
        #f)
      #f by-scope-results)

    (for-each
      (lambda (offer)
        (let ((offer-spec (assq-ref offer 'spec-id))
              (offer-scope (assq-ref offer 'scope-id)))
          (for-each
            (lambda (request)
              (let ((req-spec (assq-ref request 'spec-id))
                    (req-scope (assq-ref request 'scope-id))
                    (offer-rem (assq-ref offer 'remaining))
                    (req-rem (assq-ref request 'remaining)))
                (when (and (equal? offer-spec req-spec)
                           (not (equal? offer-scope req-scope))
                           (not (equal? (hashmap-ref parent-of offer-scope #f) req-scope))
                           (not (equal? (hashmap-ref parent-of req-scope #f) offer-scope))
                           (> offer-rem *epsilon-pu*)
                           (> req-rem *epsilon-pu*))
                  (let ((transfer-qty (min offer-rem req-rem)))
                    (set! matches
                      (cons `((from-scope . ,offer-scope)
                              (to-scope . ,req-scope)
                              (spec-id . ,offer-spec)
                              (quantity . ,transfer-qty))
                            matches))
                    (set-cdr! (assq 'remaining offer)
                              (- offer-rem transfer-qty))
                    (set-cdr! (assq 'remaining request)
                              (- req-rem transfer-qty))))))
            requests)))
      offers)

    (reverse matches)))


;; ═════════════════════════════════════════════════════════════════════════
;; Collect remaining deficits after lateral matching
;; ═════════════════════════════════════════════════════════════════════════

(define (collect-remaining-deficits by-scope lateral-matches)
  "Collect deficits that remain unmatched after lateral matching."
  (let ((remaining '()))
    (hashmap-fold
      (lambda (scope-id result _acc)
        (let ((deficits (or (assq-ref result 'deficit-signals) '())))
          (for-each
            (lambda (d)
              (let* ((spec (assq-ref d 'spec-id))
                     (qty (assq-ref d 'qty))
                     (matched (fold (lambda (m acc)
                                      (if (and (equal? (assq-ref m 'to-scope) scope-id)
                                               (equal? (assq-ref m 'spec-id) spec))
                                          (+ acc (assq-ref m 'quantity))
                                          acc))
                                    0 lateral-matches))
                     (left (- qty matched)))
                (when (> left *epsilon-pu*)
                  (set! remaining
                    (cons `((scope-id . ,scope-id) (spec-id . ,spec) (qty . ,left))
                          remaining)))))
            deficits))
        #f)
      #f by-scope)
    (reverse remaining)))


;; ═════════════════════════════════════════════════════════════════════════
;; Cross-scope retraction — priority-aware reallocation
;; ═════════════════════════════════════════════════════════════════════════

(define* (retract-across-scopes by-scope remaining-deficits priority-fn parent-of
                                 #:key (weight-fn #f))
  "Retract satisfied demands from any scope to free capacity for unmet demands.

   Legacy mode (no weight-fn): Retract lowest priority-number first
   (legacy priority is retraction-sort semantics, lower = more urgent).

   Harmony mode (weight-fn provided): Retract the candidate whose removal
   loses the least weighted harmony — equivalently, the lowest-weight
   candidate — to serve the highest-weight deficit first.

   Returns (values updated-by-scope retractions final-deficits)."
  (let* ((retraction-loss
           (lambda (c)
             (if weight-fn
                 ;; Harmony loss ≈ weight(spec) * 1 (see harmony.scm)
                 (let ((spec (assq-ref c 'spec-id)))
                   (if spec (weight-fn spec) 1))
                 ;; Legacy: use priority number as loss proxy (lower = more urgent)
                 (or (assq-ref c 'priority) 53))))
         (deficit-urgency
           (lambda (d)
             (if weight-fn
                 ;; Higher weight = more urgent to serve → negate for ascending sort
                 (- (let ((spec (assq-ref d 'spec-id)))
                      (if spec (weight-fn spec) 1)))
                 ;; Legacy: lower priority number = more urgent
                 (priority-fn (assq-ref d 'scope-id) (assq-ref d 'spec-id)))))
         (all-candidates
           (hashmap-fold
             (lambda (scope-id result acc)
               (let ((cands (or (assq-ref result 'retraction-candidates) '())))
                 (append acc
                   (map (lambda (c)
                          (if (assq-ref c 'priority) c
                              (cons `(priority . ,(priority-fn scope-id (assq-ref c 'spec-id))) c)))
                        cands))))
             '() by-scope))
         (sorted-cands
           (if weight-fn
               ;; Smallest harmony loss first
               (sort all-candidates
                 (lambda (a b) (< (retraction-loss a) (retraction-loss b))))
               ;; Legacy: highest priority-number first (least urgent → retract first)
               (sort all-candidates
                 (lambda (a b)
                   (> (or (assq-ref a 'priority) 53)
                      (or (assq-ref b 'priority) 53))))))
         (sorted-defs
           (sort remaining-deficits
             (lambda (a b) (< (deficit-urgency a) (deficit-urgency b))))))
    (let loop ((cands sorted-cands) (defs sorted-defs)
               (by-scope by-scope) (retractions '()))
      (if (or (null? defs) (null? cands))
          (values by-scope (reverse retractions) defs)
          (let* ((deficit (car defs))
                 (def-spec (assq-ref deficit 'spec-id))
                 (def-qty (assq-ref deficit 'qty))
                 (def-scope (assq-ref deficit 'scope-id))
                 (eligible?
                   (lambda (c)
                     (and (equal? (assq-ref c 'spec-id) def-spec)
                          (not (equal? (assq-ref c 'scope-id) def-scope))
                          (not (equal? (hashmap-ref parent-of
                                         (assq-ref c 'scope-id) #f)
                                       def-scope))
                          (not (equal? (hashmap-ref parent-of def-scope #f)
                                       (assq-ref c 'scope-id))))))
                 ;; Harmony mode: pick candidate with smallest EXACT loss
                 ;; given the actual transfer amount. Legacy mode: first match.
                 (match
                   (if weight-fn
                       (let ((eligibles (filter eligible? cands)))
                         (if (null? eligibles)
                             #f
                             (car (sort eligibles
                                    (lambda (a b)
                                      (let ((ta (min (assq-ref a 'qty) def-qty))
                                            (tb (min (assq-ref b 'qty) def-qty)))
                                        (< (retraction-loss-exact a ta weight-fn)
                                           (retraction-loss-exact b tb weight-fn))))))))
                       (find eligible? cands))))
            (if (not match)
                (loop cands (cdr defs) by-scope retractions)
                (let* ((cand-scope (assq-ref match 'scope-id))
                       (cand-qty (assq-ref match 'qty))
                       (transfer (min cand-qty def-qty))
                       (cand-ns (assq-ref (hashmap-ref by-scope cand-scope '())
                                          'netter-state))
                       (new-ns (if (and cand-ns (assq-ref match 'plan-id))
                                   (netter-retract cand-ns (assq-ref match 'plan-id))
                                   cand-ns))
                       (old-result (hashmap-ref by-scope cand-scope '()))
                       (new-result
                         (map (lambda (p)
                                (cond
                                  ((eq? (car p) 'netter-state) (cons 'netter-state new-ns))
                                  ((eq? (car p) 'surplus-signals)
                                   (cons 'surplus-signals
                                     (cons `((spec-id . ,(assq-ref match 'spec-id))
                                             (qty . ,transfer))
                                           (cdr p))))
                                  ((eq? (car p) 'retraction-candidates)
                                   (let ((left (- cand-qty transfer)))
                                     (cons 'retraction-candidates
                                       (if (<= left *epsilon-pu*)
                                           (filter (lambda (c)
                                                     (not (equal? (assq-ref c 'plan-id)
                                                                  (assq-ref match 'plan-id))))
                                                   (cdr p))
                                           (map (lambda (c)
                                                  (if (equal? (assq-ref c 'plan-id)
                                                              (assq-ref match 'plan-id))
                                                      (cons (cons 'qty left)
                                                            (filter (lambda (x) (not (eq? (car x) 'qty))) c))
                                                      c))
                                                (cdr p))))))
                                  (else p)))
                              old-result))
                       (new-by-scope (hashmap-set by-scope cand-scope new-result))
                       (retraction `((from-scope . ,cand-scope)
                                     (to-scope . ,(assq-ref deficit 'scope-id))
                                     (spec-id . ,def-spec)
                                     (quantity . ,transfer)
                                     (retracted-plan-id . ,(assq-ref match 'plan-id))
                                     (priority-cost . ,(or (assq-ref match 'priority) 53))))
                       (new-defs
                         (let ((left (- def-qty transfer)))
                           (if (<= left *epsilon-pu*)
                               (cdr defs)
                               (cons `((scope-id . ,(assq-ref deficit 'scope-id))
                                       (spec-id . ,def-spec) (qty . ,left))
                                     (cdr defs)))))
                       (new-cands
                         (let ((left (- cand-qty transfer)))
                           (if (<= left *epsilon-pu*)
                               (delete match cands)
                               (map (lambda (c)
                                      (if (eq? c match)
                                          (cons (cons 'qty left)
                                                (filter (lambda (p) (not (eq? (car p) 'qty))) c))
                                          c))
                                    cands)))))
                  (loop new-cands new-defs new-by-scope
                        (cons retraction retractions)))))))))


;; ═════════════════════════════════════════════════════════════════════════
;; propagate-confirmations — federation endorsement act
;; ═════════════════════════════════════════════════════════════════════════
;;
;; After plan-federation produces a result, the parent's assembly may
;; endorse the federation outcome. Endorsement is modeled as the parent
;; issuing confirm-plan against each child observer with parent-scope-id.
;; This is a deliberate act, not an automatic derivation: the assembly
;; decides when (and whether) to confirm. The helper just propagates the
;; decision once made.

(define (propagate-confirmations federation-result child-scope-roots
                                 parent-scope-id)
  "Walk a federation-result's by-scope alist; for each CHILD scope-root
   whose entry has a plan-id, call confirm-plan on the child observer
   with PARENT-SCOPE-ID. Idempotent (confirm-plan unions). Children
   with no by-scope entry (or no plan-id) are skipped."
  (let ((by-scope (assq-ref federation-result 'by-scope)))
    (for-each
      (lambda (child)
        (let* ((sid     ($ child 'name))
               (result  (and by-scope (hashmap-ref by-scope sid #f)))
               (plan-id (and result (assq-ref result 'plan-id))))
          (when plan-id
            ($ ($ child 'observer) 'confirm-plan plan-id parent-scope-id))))
      child-scope-roots)))

(define (endorse-by-tally tally federation-result child-scope-roots
                          parent-scope-id)
  "Conditional propagation: if the ballot TALLY shows yes-weight
   strictly greater than no-weight, propagate confirmations of every
   child plan in FEDERATION-RESULT up to PARENT-SCOPE-ID. If no wins
   or the vote ties, no-op (confirmation is withheld; voice at the
   parent stays where it was).

   TALLY is a hashmap of position → weight, matching the shape
   returned by ^ballot's `tally` method (e.g. (hashmap-set (hashmap)
   'yes 30 'no 10)). Unknown positions default to 0.

   This is the bridge from a real governance ballot to the gate's
   federation stratification: an assembly votes; the tally decides
   whether the parent's confirmation of the children's plans is
   issued. Withdrawal (revocation after confirmation) uses
   unconfirm-plan on the child observer directly."
  (let ((yes-w (hashmap-ref tally 'yes 0))
        (no-w  (hashmap-ref tally 'no  0)))
    (when (> yes-w no-w)
      (propagate-confirmations federation-result child-scope-roots
                               parent-scope-id))))


;; ═════════════════════════════════════════════════════════════════════════
;; plan-federation — main entry point
;; ═════════════════════════════════════════════════════════════════════════

;; ═════════════════════════════════════════════════════════════════════════
;; Labour matching phase (plans rise, labour descends)
;; ═════════════════════════════════════════════════════════════════════════

(define (run-labour-phase by-scope plan-order pool plan-store observer
                          voice-weight-fn)
  "Collect rising Proposals from scope results, run UC matching,
   emit descending commitments. Returns the matching result or #f."
  (let ((proposals (filter-map
                    (lambda (sid)
                      (let ((r (hashmap-ref by-scope sid #f)))
                        (and r (assq-ref r 'rising-proposal))))
                    plan-order)))
    (and (pair? proposals) pool plan-store
         (let ((result (labour-matching-iterate
                        proposals plan-store pool
                        #:voice-weight-fn voice-weight-fn)))
           (let ((deployment (assq-ref result 'deployment)))
             (when (and deployment (pair? deployment) observer)
               (for-each
                (lambda (cmt)
                  ($ plan-store 'add-commitment cmt)
                  ($ observer 'register-commitment cmt))
                deployment)))
           result))))


;; ═════════════════════════════════════════════════════════════════════════
;; Main entry point
;; ═════════════════════════════════════════════════════════════════════════

(define* (plan-federation scope-ids horizon
                          recipe-store observer
                          plan-scope-fn
                          #:key (parent-of (hashmap)) (registry #f)
                                (priority-fn #f) (weight-fn #f)
                                (labour-matching? #f)
                                (labour-pool #f)
                                (plan-store #f)
                                (voice-weight-fn #f))
  "Plan a federation of scopes hierarchically, then match laterally.
   When priority-fn is provided and deficits remain after lateral matching,
   performs cross-scope retraction to free capacity from lowest-priority
   demands for highest-priority unmet needs.

   WEIGHT-FN: (spec-id) → weight. When provided, the result carries a
   total-harmony score aggregated across all scopes.

   LABOUR-MATCHING?: when #t, collects rising Proposals from all scope
   results and runs the UC-level labour matching after material federation.
   Requires LABOUR-POOL (a <labour-pool>) and PLAN-STORE."
  (let-values (((children-of plan-order)
                (build-scope-hierarchy scope-ids parent-of)))
    (let* ((by-scope (fold-scopes plan-order children-of plan-scope-fn registry))
           (lateral (match-laterally by-scope parent-of))
           (remaining-defs (collect-remaining-deficits by-scope lateral))
           (finalize
             (lambda (final-by-scope retractions final-defs)
               (let* ((harmony (and weight-fn
                                    (aggregate-federation-harmony
                                      final-by-scope weight-fn)))
                      (labour  (and labour-matching?
                                    (run-labour-phase
                                     final-by-scope plan-order
                                     labour-pool plan-store observer
                                     voice-weight-fn))))
                 `((by-scope . ,final-by-scope)
                   (plan-order . ,plan-order)
                   (lateral-matches . ,lateral)
                   (retractions . ,retractions)
                   (remaining-deficits . ,final-defs)
                   ,@(if harmony `((harmony . ,harmony)) '())
                   ,@(if labour `((labour-matching . ,labour)) '()))))))
      (if (and priority-fn (pair? remaining-defs))
          (let-values (((new-by-scope retractions final-defs)
                        (retract-across-scopes by-scope remaining-defs
                                               priority-fn parent-of
                                               #:weight-fn weight-fn)))
            (finalize new-by-scope retractions final-defs))
          (finalize by-scope '() remaining-defs)))))


;; ═════════════════════════════════════════════════════════════════════════
;; Harmony aggregation over federation results
;; ═════════════════════════════════════════════════════════════════════════

(define (aggregate-federation-harmony by-scope weight-fn)
  "Aggregate weighted harmony across all scopes from imperative results.

   The previous implementation called plan-harmony on a 'plan' field
   that plan-for-unit doesn't emit, producing total=0 for every scope.
   This version works directly on the imperative result structure:
   - retraction-candidates → satisfied demands (harmony = 0 per spec)
   - deficit-signals → unmet demands (negative harmony via compute-harmony)
   - coherence → scope self-sufficiency ratio (if available)

   Uses compute-weighted-harmony from harmony.scm (pure numeric,
   loaded via load-relational.scm before plan-federation.scm)."
  (let ((per-scope '())
        (total 0))
    (hashmap-fold
      (lambda (scope-id result _acc)
        (let* ((deficits (or (assq-ref result 'deficit-signals) '()))
               (candidates (or (assq-ref result 'retraction-candidates) '()))
               ;; Satisfied demands: goal=qty, output=qty → harmony=0 per spec
               ;; (satisfied demands contribute zero, not positive, because
               ;; harmony measures u=(output-goal)/goal which is 0 when met)
               (satisfied-h
                 (map (lambda (c)
                        (let* ((spec (assq-ref c 'spec-id))
                               (qty (or (assq-ref c 'qty) 0))
                               (w (if spec (weight-fn spec) 1)))
                          `((spec-id . ,spec)
                            (goal . ,qty)
                            (output . ,qty)
                            (weighted-harmony . 0))))
                      candidates))
               ;; Deficit demands: goal=qty, output=0 → negative harmony
               (deficit-h
                 (map (lambda (d)
                        (let* ((spec (assq-ref d 'spec-id))
                               (qty (or (assq-ref d 'qty) 0))
                               (w (if spec (weight-fn spec) 1))
                               (wh (compute-weighted-harmony qty 0 w)))
                          `((spec-id . ,spec)
                            (goal . ,qty)
                            (output . 0)
                            (weighted-harmony . ,wh))))
                      deficits))
               (all-h (append satisfied-h deficit-h))
               (scope-total (fold (lambda (h acc)
                                    (+ acc (assq-ref h 'weighted-harmony)))
                                  0 all-h)))
          (set! per-scope
            (cons `((scope-id . ,scope-id)
                    (total . ,scope-total)
                    (coherence . ,(or (assq-ref result 'coherence) 1))
                    (per-spec . ,all-h))
                  per-scope))
          (set! total (+ total scope-total))
          #f))
      #f by-scope)
    `((total . ,total)
      (per-scope . ,(reverse per-scope)))))
