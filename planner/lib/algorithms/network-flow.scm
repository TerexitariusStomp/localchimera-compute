;;; network-flow.scm — Max-flow / min-cut (Edmonds-Karp / Ford-Fulkerson)
;;;
;;; Pure graph algorithms. Nodes are strings, edges have capacity/flow.

(use-modules (srfi srfi-1))

(define (max-flow nodes edges source sink)
  "Edmonds-Karp max-flow. O(V * E^2).
   edges: list of (from to capacity) lists.
   Returns alist: ((max-flow . number) (flow-edges . list) (residual . hash-table))."
  ;; Build adjacency + residual capacity
  (let ((residual (make-hash-table))  ;; key: \"u->v\" -> remaining capacity
        (adj (make-hash-table)))       ;; node -> list of neighbors
    ;; Initialize residual graph (forward + backward edges)
    (for-each
      (lambda (e)
        (let ((u (car e)) (v (cadr e)) (cap (caddr e)))
          (hash-set! residual (string-append u "->" v)
            (+ (hash-ref residual (string-append u "->" v) 0) cap))
          (hash-set! residual (string-append v "->" u)
            (hash-ref residual (string-append v "->" u) 0))
          (hash-set! adj u (cons v (hash-ref adj u '())))
          (hash-set! adj v (cons u (hash-ref adj v '())))))
      edges)
    ;; BFS to find augmenting path
    (define (bfs-augment)
      (let ((visited (make-hash-table))
            (parent (make-hash-table))
            (queue (list source)))
        (hash-set! visited source #t)
        (let loop ((q queue))
          (cond
            ((null? q) #f)  ;; no path found
            ((equal? (car q) sink)
             ;; Reconstruct path and find bottleneck
             (let path-loop ((node sink) (path '()) (bottleneck +inf.0))
               (if (equal? node source)
                   (cons bottleneck (cons source path))
                   (let* ((prev (hash-ref parent node))
                          (key (string-append prev "->" node))
                          (cap (hash-ref residual key 0)))
                     (path-loop prev (cons node path) (min bottleneck cap))))))
            (else
             (let ((u (car q)) (new-q (cdr q)))
               (for-each
                 (lambda (v)
                   (let ((key (string-append u "->" v)))
                     (when (and (not (hash-ref visited v #f))
                                (> (hash-ref residual key 0) 0))
                       (hash-set! visited v #t)
                       (hash-set! parent v u)
                       (set! new-q (append new-q (list v))))))
                 (delete-duplicates (hash-ref adj u '())))
               (loop new-q)))))))
    ;; Main loop: find augmenting paths until none exist
    (let flow-loop ((total-flow 0))
      (let ((path-result (bfs-augment)))
        (if (not path-result)
            `((max-flow . ,total-flow) (residual . ,residual))
            (let ((bottleneck (car path-result))
                  (path (cdr path-result)))
              ;; Update residual graph
              (let edge-loop ((nodes path))
                (when (>= (length nodes) 2)
                  (let* ((u (car nodes)) (v (cadr nodes))
                         (fwd (string-append u "->" v))
                         (bwd (string-append v "->" u)))
                    (hash-set! residual fwd (- (hash-ref residual fwd 0) bottleneck))
                    (hash-set! residual bwd (+ (hash-ref residual bwd 0) bottleneck))
                    (edge-loop (cdr nodes)))))
              (flow-loop (+ total-flow bottleneck))))))))

(define (min-cut max-flow-result source nodes)
  "Compute S-T cut from max-flow residual graph.
   Returns alist: ((source-side . list) (sink-side . list) (cut-capacity . number))."
  (let ((residual (assq-ref max-flow-result 'residual))
        (visited (make-hash-table))
        (queue (list source)))
    ;; BFS on residual graph from source
    (hash-set! visited source #t)
    (let loop ((q queue))
      (unless (null? q)
        (let ((u (car q)) (new-q (cdr q)))
          (for-each
            (lambda (v)
              (let ((key (string-append u "->" v)))
                (when (and (not (hash-ref visited v #f))
                           (> (hash-ref residual key 0) 0))
                  (hash-set! visited v #t)
                  (set! new-q (append new-q (list v))))))
            nodes)
          (loop new-q))))
    (let* ((source-side (filter (lambda (n) (hash-ref visited n #f)) nodes))
           (sink-side (filter (lambda (n) (not (hash-ref visited n #f))) nodes)))
      `((source-side . ,source-side)
        (sink-side . ,sink-side)
        (cut-capacity . ,(assq-ref max-flow-result 'max-flow))))))
