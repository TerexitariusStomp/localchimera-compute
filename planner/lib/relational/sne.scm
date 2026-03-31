;;; sne.scm — Socially Necessary Effort (complete port)
;;;
;;; SNE = (direct labor + embodied labor + depreciation) / output qty.
;;; Recursive through consuming inputs with cycle guard.
;;; build-sne-index-o computes all specs at once (memoization equivalent).

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))

(define *work-actions* '(work deliver-service))
(define *durable-actions* '(use cite))
(define *consuming-actions* '(consume combine pickup accept))


;;; ── SNE relation ──────────────────────────────────────────────────────────────

(define (sne-o facts spec-id sne)
  "Relate spec to its best (min) SNE across all recipes."
  (fresh (rid rname)
    (recipe-o facts rid rname spec-id)
    (project (facts rid spec-id)
      (== sne (compute-recipe-sne facts rid spec-id '())))))

(define (compute-recipe-sne facts rid spec-id visited)
  (if (member spec-id visited) 0
      (let* ((cf (find (lambda (f) (and (eq? (car f) 'chain) (equal? (cadr f) rid))) facts))
             (pids (if cf (caddr cf) '()))
             (nv (cons spec-id visited))
             (direct
               (fold (lambda (pid a)
                       (+ a (fold (lambda (f a2)
                                    (if (and (eq? (car f) 'flow) (equal? (cadr f) pid)
                                             (eq? (caddr f) 'input)
                                             (memq (list-ref f 6) *work-actions*)
                                             (list-ref f 4))
                                        (+ a2 (list-ref f 4)) a2))
                                  0 facts)))
                     0 pids))
             (embodied
               (fold (lambda (pid a)
                       (+ a (fold (lambda (f a2)
                                    (let ((isp (and (eq? (car f) 'flow) (equal? (cadr f) pid)
                                                     (eq? (caddr f) 'input)
                                                     (memq (list-ref f 6) *consuming-actions*)
                                                     (cadddr f)))
                                          (iq (and (eq? (car f) 'flow) (equal? (cadr f) pid)
                                                    (eq? (caddr f) 'input) (list-ref f 4))))
                                      (if (and isp iq)
                                          (+ a2 (* iq (input-sne facts isp nv)))
                                          a2)))
                                  0 facts)))
                     0 pids))
             (deprec
               (fold (lambda (pid a)
                       (+ a (fold (lambda (f a2)
                                    (if (and (eq? (car f) 'flow) (equal? (cadr f) pid)
                                             (eq? (caddr f) 'input)
                                             (memq (list-ref f 6) *durable-actions*)
                                             (list-ref f 4))
                                        (let ((ls (spec-lifespan facts (cadddr f))))
                                          (+ a2 (/ (list-ref f 4) (max 1 ls))))
                                        a2))
                                  0 facts)))
                     0 pids))
             (lp (and (pair? pids) (last pids)))
             (of (and lp (find (lambda (f) (and (eq? (car f) 'flow) (equal? (cadr f) lp)
                                                 (eq? (caddr f) 'output)
                                                 (equal? (cadddr f) spec-id))) facts)))
             (oq (if (and of (list-ref of 4)) (list-ref of 4) 1))
             (total (+ direct embodied deprec)))
        (if (> oq 0) (/ total oq) total))))

(define (input-sne facts spec-id visited)
  (if (member spec-id visited) 0
      (let ((rs (filter (lambda (f) (and (eq? (car f) 'recipe) (equal? (cadddr f) spec-id))) facts)))
        (if (null? rs) 0
            (apply min (map (lambda (rf) (compute-recipe-sne facts (cadr rf) spec-id visited)) rs))))))

(define (spec-lifespan facts spec-id)
  (let ((sf (find (lambda (f) (and (eq? (car f) 'resource-spec-lifespan)
                                    (equal? (cadr f) spec-id))) facts)))
    (if sf (caddr sf) 100)))

(define (build-sne-index-o facts index)
  "Build SNE index for all specs at once."
  (project (facts)
    (let* ((specs (delete-duplicates
                    (filter-map (lambda (f) (and (eq? (car f) 'recipe) (cadddr f))) facts)))
           (idx (map (lambda (sp)
                       (let ((rs (filter (lambda (f) (and (eq? (car f) 'recipe)
                                                          (equal? (cadddr f) sp))) facts)))
                         (cons sp (if (null? rs) 0
                                      (apply min (map (lambda (rf)
                                        (compute-recipe-sne facts (cadr rf) sp '())) rs))))))
                     specs)))
      (== index idx))))
