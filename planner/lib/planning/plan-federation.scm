;;; plan-federation.scm — Hierarchical federation planning
;;;
;;; Translated from src/lib/planning/plan-federation.ts
;;; Orchestrates bottom-up planning across a scope hierarchy,
;;; then performs lateral matching of surpluses against deficits.
;;;
;;; Architecture: The federation planner is a monoidal fold.
;;; Each scope is planned independently (the monoid element).
;;; foldScopes combines them bottom-up (the fold).
;;; Lateral matching is a monoid homomorphism (surplus -> agreement).

;; Assumes plan-for-scope.scm, store-registry.scm, signals.scm,
;; and all dependencies are loaded.

(use-modules (srfi srfi-1)
             (goblins utils hashmap))


;; ═════════════════════════════════════════════════════════════════════════
;; Hierarchy construction
;; ═════════════════════════════════════════════════════════════════════════

(define (build-hierarchy scope-ids parent-of)
  "Build children-of map and topological sort (post-order: children first).
   parent-of: hashmap of child-id -> parent-id.
   Returns (values children-of plan-order)."
  ;; Build children-of from parent-of
  (let ((children-of (make-hash-table)))
    ;; Initialize all scopes
    (for-each (lambda (id) (hash-set! children-of id '())) scope-ids)
    ;; Populate children
    (for-each
      (lambda (id)
        (let ((parent (hashmap-ref parent-of id #f)))
          (when (and parent (member parent scope-ids))
            (hash-set! children-of parent
              (cons id (hash-ref children-of parent '()))))))
      scope-ids)
    ;; Post-order DFS topological sort
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
               ;; Collect child plan-stores (already planned since post-order)
               (child-results
                 (filter-map (lambda (cid)
                               (hashmap-ref acc cid #f))
                             child-ids))
               ;; Plan this scope
               (result (plan-scope-fn scope-id child-results)))
          ;; Register in store-registry (store the plan-store actor ref, NOT the result)
          ;; The caller is responsible for passing plan-store refs via the plan-scope-fn result.
          ;; Registry stores ONLY actor references (serializable by Goblins).
          (hashmap-set acc scope-id result)))
      results
      plan-order)))


;; ═════════════════════════════════════════════════════════════════════════
;; Lateral matching — surplus/deficit across sibling scopes
;; ═════════════════════════════════════════════════════════════════════════

(define (match-laterally by-scope-results parent-of)
  "Match surpluses against deficits across unrelated scopes.
   Returns list of match alists: ((from-scope . id) (to-scope . id)
                                   (spec-id . id) (quantity . n))."
  (let ((offers '())
        (requests '())
        (matches '()))

    ;; Collect surpluses (offers)
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

    ;; Collect deficits (requests)
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

    ;; Greedy matching: match offers to requests by spec
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
                ;; Match: same spec, different scopes, both have remaining
                (when (and (equal? offer-spec req-spec)
                           (not (equal? offer-scope req-scope))
                           ;; Don't match parent-child (only peers)
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
                    ;; Deduct from remaining
                    (set-cdr! (assq 'remaining offer)
                              (- offer-rem transfer-qty))
                    (set-cdr! (assq 'remaining request)
                              (- req-rem transfer-qty))))))
            requests)))
      offers)

    (reverse matches)))


;; ═════════════════════════════════════════════════════════════════════════
;; plan-federation — main entry point
;; ═════════════════════════════════════════════════════════════════════════

(define* (plan-federation scope-ids horizon
                          recipe-store observer
                          plan-scope-fn
                          #:key (parent-of (hashmap)) (registry #f))
  "Plan a federation of scopes hierarchically, then match laterally.
   scope-ids: list of scope ID strings.
   plan-scope-fn: (scope-id child-results) -> plan-result alist.
   parent-of: hashmap of child-id -> parent-id.
   registry: optional ^store-registry actor.
   Returns alist: ((by-scope . hashmap) (plan-order . list)
                    (lateral-matches . list))."
  (let-values (((children-of plan-order)
                (build-hierarchy scope-ids parent-of)))
    (let* ((by-scope (fold-scopes plan-order children-of plan-scope-fn registry))
           (lateral (match-laterally by-scope parent-of)))
      `((by-scope . ,by-scope)
        (plan-order . ,plan-order)
        (lateral-matches . ,lateral)))))
