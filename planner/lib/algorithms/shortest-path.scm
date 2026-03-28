;;; shortest-path.scm — Dijkstra & Bellman-Ford shortest path algorithms
;;;
;;; Pure graph algorithms. Nodes are strings, edges are (from to weight) lists.

(use-modules (srfi srfi-1))

(define (dijkstra nodes edges source)
  "Single-source shortest paths (non-negative weights). O(V^2).
   nodes: list of strings. edges: list of (from to weight) lists.
   Returns alist: ((distances . hash-table) (predecessors . hash-table))."
  (let ((dist (make-hash-table))
        (pred (make-hash-table))
        (visited (make-hash-table))
        ;; Build adjacency list
        (adj (make-hash-table)))
    (for-each (lambda (e)
                (let ((from (car e)) (to (cadr e)) (w (caddr e)))
                  (hash-set! adj from (cons (cons to w) (hash-ref adj from '())))))
              edges)
    ;; Initialize
    (for-each (lambda (n) (hash-set! dist n +inf.0)) nodes)
    (hash-set! dist source 0)
    ;; Main loop: V iterations
    (let loop ((remaining (length nodes)))
      (when (> remaining 0)
        ;; Find unvisited node with minimum distance
        (let* ((unvisited (filter (lambda (n) (not (hash-ref visited n #f))) nodes))
               (u (fold (lambda (n best)
                          (if (or (not best) (< (hash-ref dist n +inf.0)
                                                (hash-ref dist best +inf.0)))
                              n best))
                        #f unvisited)))
          (when (and u (< (hash-ref dist u +inf.0) +inf.0))
            (hash-set! visited u #t)
            ;; Relax neighbors
            (for-each
              (lambda (neighbor)
                (let* ((v (car neighbor)) (w (cdr neighbor))
                       (alt (+ (hash-ref dist u +inf.0) w)))
                  (when (< alt (hash-ref dist v +inf.0))
                    (hash-set! dist v alt)
                    (hash-set! pred v u))))
              (hash-ref adj u '()))
            (loop (- remaining 1))))))
    `((distances . ,dist) (predecessors . ,pred))))

(define (bellman-ford nodes edges source)
  "Single-source shortest paths (handles negative weights). O(VE).
   Returns alist like dijkstra, or #f if negative cycle detected."
  (let ((dist (make-hash-table))
        (pred (make-hash-table)))
    (for-each (lambda (n) (hash-set! dist n +inf.0)) nodes)
    (hash-set! dist source 0)
    ;; Relax V-1 times
    (let loop ((i (- (length nodes) 1)))
      (when (> i 0)
        (for-each
          (lambda (e)
            (let* ((u (car e)) (v (cadr e)) (w (caddr e))
                   (alt (+ (hash-ref dist u +inf.0) w)))
              (when (< alt (hash-ref dist v +inf.0))
                (hash-set! dist v alt)
                (hash-set! pred v u))))
          edges)
        (loop (- i 1))))
    ;; Check for negative cycles
    (let ((has-neg-cycle
            (any (lambda (e)
                   (let ((u (car e)) (v (cadr e)) (w (caddr e)))
                     (< (+ (hash-ref dist u +inf.0) w)
                        (hash-ref dist v +inf.0))))
                 edges)))
      (if has-neg-cycle #f
          `((distances . ,dist) (predecessors . ,pred))))))

(define (reconstruct-path target result)
  "Reconstruct path from source to target. Returns list or #f if unreachable."
  (let ((pred (assq-ref result 'predecessors))
        (dist (assq-ref result 'distances)))
    (if (= (hash-ref dist target +inf.0) +inf.0) #f
        (let loop ((node target) (path '()))
          (if (not (hash-ref pred node #f))
              (cons node path)
              (loop (hash-ref pred node #f) (cons node path)))))))
