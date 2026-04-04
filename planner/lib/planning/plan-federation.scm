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

(use-modules (srfi srfi-1)
             (goblins utils hashmap))

(define *epsilon-pu* 1e-9)


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

(define (retract-across-scopes by-scope remaining-deficits priority-fn parent-of)
  "Retract lowest-priority satisfied demands from any scope to free capacity
   for highest-priority unmet demands. Minimizes priority cost to the whole.
   Returns (values updated-by-scope retractions final-deficits)."
  (let* ((all-candidates
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
           (sort all-candidates
             (lambda (a b)
               (> (or (assq-ref a 'priority) 53)
                  (or (assq-ref b 'priority) 53)))))
         (sorted-defs
           (sort remaining-deficits
             (lambda (a b)
               (< (priority-fn (assq-ref a 'scope-id) (assq-ref a 'spec-id))
                  (priority-fn (assq-ref b 'scope-id) (assq-ref b 'spec-id)))))))
    (let loop ((cands sorted-cands) (defs sorted-defs)
               (by-scope by-scope) (retractions '()))
      (if (or (null? defs) (null? cands))
          (values by-scope (reverse retractions) defs)
          (let* ((deficit (car defs))
                 (def-spec (assq-ref deficit 'spec-id))
                 (def-qty (assq-ref deficit 'qty))
                 (match (find (lambda (c)
                                (and (equal? (assq-ref c 'spec-id) def-spec)
                                     (not (equal? (assq-ref c 'scope-id)
                                                  (assq-ref deficit 'scope-id)))
                                     (not (equal? (hashmap-ref parent-of
                                                    (assq-ref c 'scope-id) #f)
                                                  (assq-ref deficit 'scope-id)))
                                     (not (equal? (hashmap-ref parent-of
                                                    (assq-ref deficit 'scope-id) #f)
                                                  (assq-ref c 'scope-id)))))
                              cands)))
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
;; plan-federation — main entry point
;; ═════════════════════════════════════════════════════════════════════════

(define* (plan-federation scope-ids horizon
                          recipe-store observer
                          plan-scope-fn
                          #:key (parent-of (hashmap)) (registry #f)
                                (priority-fn #f))
  "Plan a federation of scopes hierarchically, then match laterally.
   When priority-fn is provided and deficits remain after lateral matching,
   performs cross-scope retraction to free capacity from lowest-priority
   demands for highest-priority unmet needs."
  (let-values (((children-of plan-order)
                (build-scope-hierarchy scope-ids parent-of)))
    (let* ((by-scope (fold-scopes plan-order children-of plan-scope-fn registry))
           (lateral (match-laterally by-scope parent-of))
           (remaining-defs (collect-remaining-deficits by-scope lateral)))
      (if (and priority-fn (pair? remaining-defs))
          (let-values (((new-by-scope retractions final-defs)
                        (retract-across-scopes by-scope remaining-defs
                                               priority-fn parent-of)))
            `((by-scope . ,new-by-scope)
              (plan-order . ,plan-order)
              (lateral-matches . ,lateral)
              (retractions . ,retractions)
              (remaining-deficits . ,final-defs)))
          `((by-scope . ,by-scope)
            (plan-order . ,plan-order)
            (lateral-matches . ,lateral)
            (retractions . ())
            (remaining-deficits . ,remaining-defs))))))
