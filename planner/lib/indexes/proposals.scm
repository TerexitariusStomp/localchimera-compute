;;; proposals.scm — Proposal query index

(use-modules (srfi srfi-1) (goblins utils hashmap))

(define (build-proposal-index proposals)
  (let ((items (hashmap)) (by-purpose (hashmap)) (by-scope (hashmap)))
    (for-each
      (lambda (p)
        (let ((id (proposal-id p)))
          (set! items (hashmap-set items id p))
          (when (proposal-purpose p)
            (set! by-purpose (hashmap-set by-purpose (proposal-purpose p)
                              (cons id (hashmap-ref by-purpose (proposal-purpose p) '())))))
          (when (proposal-in-scope-of p)
            (for-each (lambda (scope)
                        (set! by-scope (hashmap-set by-scope scope
                                         (cons id (hashmap-ref by-scope scope '())))))
                      (proposal-in-scope-of p)))))
      proposals)
    `((items . ,items) (by-purpose . ,by-purpose) (by-scope . ,by-scope))))

(define (query-proposals-by-purpose idx purpose)
  (filter-map (lambda (i) (hashmap-ref (assq-ref idx 'items) i #f))
              (hashmap-ref (assq-ref idx 'by-purpose) purpose '())))
(define (query-proposals-by-scope idx scope-id)
  (filter-map (lambda (i) (hashmap-ref (assq-ref idx 'items) i #f))
              (hashmap-ref (assq-ref idx 'by-scope) scope-id '())))
