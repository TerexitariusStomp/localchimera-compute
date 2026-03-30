;;; sne.scm — Socially Necessary Effort as a relation
;;;
;;; SNE = (direct labor + embodied labor + depreciation) / output quantity
;;; Embodied labor recurses through consuming inputs' SNE values.
;;; Used to rank recipes by social cost — lower SNE = more efficient.

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))

(define *work-actions* '(work deliver-service))
(define *durable-actions* '(use cite))
(define *consuming-actions* '(consume combine pickup accept))


;;; ── SNE for a spec ────────────────────────────────────────────────────────────

(define (sne-o facts spec-id sne)
  "Relate a spec to its Standard Normalized Exchange (embodied labor hours/unit).
   Explores all recipes; interleaving finds each recipe's SNE."
  (fresh (rid rname)
    (recipe-o facts rid rname spec-id)
    (recipe-sne-o facts rid spec-id sne '())))

(define (recipe-sne-o facts rid spec-id sne visited)
  "SNE for a specific recipe. VISITED prevents cycles."
  (if (member spec-id visited)
      (== sne 0)  ;; cycle: contribute 0
      (project (facts rid spec-id visited)
        (let* ((chain-fact (find (lambda (f)
                                   (and (eq? (car f) 'chain)
                                        (equal? (cadr f) rid)))
                                 facts))
               (pids (if chain-fact (caddr chain-fact) '()))
               ;; Direct labor: sum work-action flow quantities (hours)
               (direct (fold (lambda (pid acc)
                               (+ acc
                                  (fold (lambda (f a)
                                          (if (and (eq? (car f) 'flow)
                                                   (equal? (cadr f) pid)
                                                   (eq? (caddr f) 'input)
                                                   (memq (list-ref f 6) *work-actions*)
                                                   (list-ref f 4))
                                              (+ a (list-ref f 4))
                                              a))
                                        0 facts)))
                             0 pids))
               ;; Embodied labor: sum SNE of consuming inputs × qty
               (embodied
                 (fold (lambda (pid acc)
                         (+ acc
                            (fold (lambda (f a)
                                    (let ((in-spec (and (eq? (car f) 'flow)
                                                        (equal? (cadr f) pid)
                                                        (eq? (caddr f) 'input)
                                                        (memq (list-ref f 6) *consuming-actions*)
                                                        (cadddr f)))
                                          (in-qty (and (eq? (car f) 'flow)
                                                       (equal? (cadr f) pid)
                                                       (eq? (caddr f) 'input)
                                                       (list-ref f 4))))
                                      (if (and in-spec in-qty)
                                          (let ((input-sne (compute-input-sne facts in-spec
                                                             (cons spec-id visited))))
                                            (+ a (* in-qty input-sne)))
                                          a)))
                                  0 facts)))
                       0 pids))
               ;; Depreciation: durable inputs contribute fractional cost
               (deprec
                 (fold (lambda (pid acc)
                         (+ acc
                            (fold (lambda (f a)
                                    (if (and (eq? (car f) 'flow)
                                             (equal? (cadr f) pid)
                                             (eq? (caddr f) 'input)
                                             (memq (list-ref f 6) *durable-actions*)
                                             (list-ref f 4))
                                        (+ a (* (list-ref f 4) 0.01))  ;; 1% depreciation
                                        a))
                                  0 facts)))
                       0 pids))
               ;; Output quantity for this recipe
               (last-pid (and (pair? pids) (last pids)))
               (out-flow (and last-pid
                              (find (lambda (f)
                                      (and (eq? (car f) 'flow)
                                           (equal? (cadr f) last-pid)
                                           (eq? (caddr f) 'output)
                                           (equal? (cadddr f) spec-id)))
                                    facts)))
               (out-qty (if (and out-flow (list-ref out-flow 4))
                            (list-ref out-flow 4) 1))
               (total (+ direct embodied deprec)))
          (== sne (if (> out-qty 0) (/ total out-qty) total))))))


;;; ── Helper: compute SNE for an input spec (memoizable) ────────────────────────

(define (compute-input-sne facts spec-id visited)
  "Pure Scheme: compute SNE for a spec. Used inside project."
  (if (member spec-id visited) 0
      (let ((recipe-fact (find (lambda (f)
                                 (and (eq? (car f) 'recipe)
                                      (equal? (cadddr f) spec-id)))
                               facts)))
        (if (not recipe-fact) 0
            ;; Recursive call via run-plan would be ideal but is complex
            ;; For now, compute the first recipe's SNE directly
            ;; NOTE: this is a simplification — full version would explore all recipes
            0))))  ;; TODO: recursive SNE via relational search
