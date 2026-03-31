;;; federation.scm — Complete hierarchical federation (port of plan-federation.scm)
;;;
;;; Hierarchy construction (topological sort), bottom-up scope planning fold,
;;; lateral surplus↔deficit matching with parent-child enforcement.

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Hierarchy facts and relations
;;; ══════════════════════════════════════════════════════════════════════════════

(define (scope-parent-o facts child parent)
  (in-list-o `(scope-parent ,child ,parent) facts))

(define (peer-scopes-o facts scope-a scope-b)
  (fresh (parent)
    (scope-parent-o facts scope-a parent)
    (scope-parent-o facts scope-b parent)
    (=/= scope-a scope-b)))

(define (ancestor-o facts descendant ancestor)
  (transitive-o (lambda (c p) (scope-parent-o facts c p))
                descendant ancestor))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Hierarchy construction (children-of map + post-order topological sort)
;;; ══════════════════════════════════════════════════════════════════════════════

(define (build-hierarchy-o facts scope-ids parent-map children-of plan-order)
  (project (facts scope-ids parent-map)
    (let ((result (build-hierarchy-impl scope-ids parent-map)))
      (fresh ()
        (== children-of (car result))
        (== plan-order (cdr result))))))

(define (build-hierarchy-impl scope-ids parent-map)
  "Pure Scheme: build children-of + post-order sort. Returns (children-of . plan-order)."
  (let ((ch (make-hash-table))
        (visited (make-hash-table))
        (order '()))
    (for-each (lambda (id) (hash-set! ch id '())) scope-ids)
    (for-each (lambda (id)
                (let ((parent (assoc-ref parent-map id)))
                  (when (and parent (member parent scope-ids))
                    (hash-set! ch parent (cons id (hash-ref ch parent '()))))))
              scope-ids)
    (let dfs ((ids scope-ids))
      (for-each (lambda (id)
                  (unless (hash-ref visited id #f)
                    (hash-set! visited id #t)
                    (dfs (hash-ref ch id '()))
                    (set! order (cons id order))))
                ids))
    (cons (hash-map->list cons ch) (reverse order))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Bottom-up scope planning fold
;;; ══════════════════════════════════════════════════════════════════════════════

(define (fold-scopes-o plan-order scope-plan-fn results)
  (if (null? plan-order)
      (== results '())
      (fresh (plan rest)
        (scope-plan-fn (car plan-order) plan)
        (fold-scopes-o (cdr plan-order) scope-plan-fn rest)
        (== results (cons (cons (car plan-order) plan) rest)))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Signal collection
;;; ══════════════════════════════════════════════════════════════════════════════

(define (collect-deficits-o scope-plans deficits)
  (project (scope-plans)
    (== deficits
         (append-map
           (lambda (sp)
             (let ((sid (car sp)) (plan (cdr sp)))
               (filter-map
                 (lambda (entry)
                   (and (pair? entry) (pair? (cadr entry))
                        (eq? (caadr entry) 'purchase)
                        `((scope . ,sid) (spec . ,(cadadr entry))
                          (qty . ,(caddr (cadr entry))))))
                 (if (list? plan) plan '()))))
           scope-plans))))

(define (collect-surpluses-o scope-plans surpluses)
  (project (scope-plans)
    (== surpluses
         (append-map
           (lambda (sp)
             (let ((sid (car sp)) (plan (cdr sp)))
               (filter-map
                 (lambda (entry)
                   (and (pair? entry) (pair? (cadr entry))
                        (eq? (caadr entry) 'satisfied)
                        (let* ((pt (cadr entry))
                               (alloc (cadddr pt))
                               (needed (caddr pt))
                               (total (fold (lambda (a acc) (+ acc (cadr a)))
                                            0 (if (list? alloc) alloc '())))
                               (surplus (- total needed)))
                          (and (> surplus 0)
                               `((scope . ,sid) (spec . ,(cadr pt)) (qty . ,surplus))))))
                 (if (list? plan) plan '()))))
           scope-plans))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Lateral matching (greedy with parent-child enforcement)
;;; ══════════════════════════════════════════════════════════════════════════════

(define (lateral-match-o facts deficits surpluses matches)
  (project (facts deficits surpluses)
    (let* ((parent-facts (filter (lambda (f) (eq? (car f) 'scope-parent)) facts))
           (parent-of (lambda (id) (let ((p (find (lambda (f) (equal? (cadr f) id)) parent-facts)))
                                     (and p (caddr p))))))
      (let loop ((defs deficits) (sups surpluses) (acc '()))
        (if (null? defs) (== matches (reverse acc))
            (let* ((d (car defs))
                   (ds (assq-ref d 'scope)) (dsp (assq-ref d 'spec)) (dq (assq-ref d 'qty))
                   (m (find (lambda (s)
                              (and (equal? (assq-ref s 'spec) dsp)
                                   (not (equal? (assq-ref s 'scope) ds))
                                   (> (assq-ref s 'qty) 0)
                                   ;; Peer enforcement: shared parent
                                   (let ((dp (parent-of ds)) (sp (parent-of (assq-ref s 'scope))))
                                     (and dp sp (equal? dp sp)))))
                            sups)))
              (if (not m) (loop (cdr defs) sups acc)
                  (let* ((sq (assq-ref m 'qty)) (q (min dq sq))
                         (match `((from . ,(assq-ref m 'scope)) (to . ,ds) (spec . ,dsp) (qty . ,q)))
                         (new-sups (map (lambda (s)
                                          (if (eq? s m)
                                              (cons (cons 'qty (- sq q))
                                                    (filter (lambda (p) (not (eq? (car p) 'qty))) s))
                                              s))
                                        sups)))
                    (loop (cdr defs) new-sups (cons match acc))))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Full federation
;;; ══════════════════════════════════════════════════════════════════════════════

(define (plan-federation-o facts scope-ids parent-map scope-plan-fn result)
  (fresh (children-of plan-order scope-plans deficits surpluses matches)
    (build-hierarchy-o facts scope-ids parent-map children-of plan-order)
    (fold-scopes-o plan-order scope-plan-fn scope-plans)
    (collect-deficits-o scope-plans deficits)
    (collect-surpluses-o scope-plans surpluses)
    (lateral-match-o facts deficits surpluses matches)
    (== result `((scope-plans . ,scope-plans)
                 (plan-order . ,plan-order)
                 (lateral-matches . ,matches)))))
