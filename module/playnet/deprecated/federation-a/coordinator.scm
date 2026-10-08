;;; federation-a/coordinator.scm — federate-planning + evaluate-state-a
;;;
;;; Public entry for the real-planning tier. `federate-planning`
;;; targets ^planning-leaf refs (which run plan-o locally against a
;;; scope-root); `federate-ranked` (defined elsewhere) stays the
;;; inventory/transport-demo entry point with its own greedy combiner.
;;;
;;; `evaluate-state-a` is the harmony-aware combiner. When weight-fn
;;; is set it enumerates combinations across leaves and picks the one
;;; maximizing weighted harmony with a tiebreak on coherence. When
;;; weight-fn is #f it falls back to rank-1-from-each (coherence is
;;; already the leaf's primary sort key, so rank-1 = highest coherence
;;; alt per leaf).
;;;
;;; Combination enumeration is brute force — K alternatives × N leaves
;;; = K^N combinations. With defaults (K=5, N~3-5) this is fine; a
;;; more scalable port of advance-worst-by-harmony (federation.scm:422)
;;; lives in the follow-up plan.
;;;
;;; Included fragment — imports come from (playnet deprecated federation-a).

(define-module (playnet deprecated federation-a coordinator)
  #:use-module (playnet deprecated federation-a config)
  #:use-module (playnet deprecated planner)
  #:use-module (playnet deprecated vat-federation)
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:export (federate-planning federate-planning-resilient evaluate-state-a
            pick-best-combination score-combination pair-gt? aggregate-chosen))

(define (federate-planning leaf-refs cfg)
  "Fan out to ^planning-leaf refs in parallel. Each leaf runs its own
   relational planner against its local scope-root, returning K ranked
   ref-mode federation-results. Coordinator aggregates via
   evaluate-state-a. Returns a vow of a federation-result alist.

   Strict: any leaf's (plan-for cfg) vow breaking fails the whole
   federation. Use federate-planning-resilient otherwise."
  (let ((proposals (map (lambda (ref) (<- ref 'plan-for cfg)) leaf-refs)))
    (on (vow-all proposals)
        (lambda (per-leaf-lists)
          (evaluate-state-a per-leaf-lists cfg))
        #:promise? #t)))


(define (federate-planning-resilient leaf-refs cfg)
  "Resilient variant. Broken leaf vows contribute an empty ranked list
   (the combiner sees 'leaf has no alternatives' and skips them), and
   the federation still resolves."
  (with-sever-handling
    leaf-refs
    (lambda (ref reason)
      (format (current-error-port)
              "[federation-a] peer severed: ~a (reason: ~a)~%" ref reason))
    (lambda ()
      (let ((proposals (map (lambda (ref) (<- ref 'plan-for cfg)) leaf-refs)))
        (on (vow-allsettled proposals)
            (lambda (outcomes)
              (let ((per-leaf-lists
                      (map (lambda (outcome)
                             (if (eq? (car outcome) 'fulfilled)
                                 (cdr outcome)
                                 '()))
                           outcomes)))
                (evaluate-state-a per-leaf-lists cfg)))
            #:promise? #t)))))


;;; ── evaluate-state-a ────────────────────────────────────────────────

(define (evaluate-state-a per-leaf-lists cfg)
  "Combine PER-LEAF-LISTS (list of per-leaf lists of ref-mode
   federation-results) into one aggregate federation-result. If
   cfg.weight-fn is set, scores combinations by weighted harmony;
   otherwise picks each leaf's rank-1 alternative."
  (let* ((weight-fn (federation-a-config-weight-fn cfg))
         (non-empty (filter pair? per-leaf-lists))
         (chosen (if weight-fn
                     (pick-best-combination non-empty weight-fn)
                     (map car non-empty))))
    (aggregate-chosen chosen weight-fn)))


(define (pick-best-combination per-leaf-lists weight-fn)
  "Brute-force combination search: K^N combinations, score each by
   total weighted harmony with coherence as tiebreak, return the
   best. K=max-leaf-results (default 5), N=leaf count. For K=5/N=4
   that's 625 combinations — fine."
  (define (cartesian lists)
    (cond
      ((null? lists) '(()))
      (else
       (let ((rest (cartesian (cdr lists))))
         (append-map
           (lambda (head) (map (lambda (tail) (cons head tail)) rest))
           (car lists))))))
  (let* ((combos (cartesian per-leaf-lists))
         (scored (map (lambda (c) (cons (score-combination c weight-fn) c))
                      combos))
         (best (fold (lambda (entry best)
                       (if (pair-gt? entry best) entry best))
                     (car scored) (cdr scored))))
    (cdr best)))


(define (score-combination combo weight-fn)
  "Score a combination (one chosen result per leaf) as
   (total-harmony . total-coherence). Higher is better on both axes;
   comparison is lexicographic via pair-gt?."
  (cons (fold + 0 (map (lambda (r)
                         (let ((h (assq-ref r 'harmony)))
                           (if (and h (pair? h)) (or (assq-ref h 'total) 0) 0)))
                       combo))
        (fold + 0 (map (lambda (r) (or (assq-ref r 'coherence) 0)) combo))))


(define (pair-gt? a b)
  "Lexicographic > on pairs (car . cdr). A wins if car>b.car, or
   cars equal and cdr>b.cdr."
  (or (> (car a) (car b))
      (and (= (car a) (car b)) (> (cdr a) (cdr b)))))


(define (aggregate-chosen chosen weight-fn)
  "Roll the per-leaf chosen results into a single federation-result
   alist. Preserves plan-refs, sums deficits/surpluses, averages
   coherence weighted by participation, sums harmony totals."
  (let* ((deficits  (append-map (lambda (r) (or (assq-ref r 'deficits)  '())) chosen))
         (surpluses (append-map (lambda (r) (or (assq-ref r 'surpluses) '())) chosen))
         (residual  (fold + 0 (map (lambda (r) (or (assq-ref r 'residual) 0)) chosen)))
         (coh-sum   (fold + 0 (map (lambda (r) (or (assq-ref r 'coherence) 0)) chosen)))
         (coh-avg   (if (null? chosen) 0 (/ coh-sum (length chosen))))
         (harm-sum  (and weight-fn
                         (fold + 0
                               (map (lambda (r)
                                      (let ((h (assq-ref r 'harmony)))
                                        (if (and h (pair? h))
                                            (or (assq-ref h 'total) 0)
                                            0)))
                                    chosen))))
         (allocs    (map (lambda (r)
                           `((scope    . ,(assq-ref r 'scope))
                             (plan-ref . ,(assq-ref r 'plan-ref))
                             (residual . ,(assq-ref r 'residual))
                             (coherence . ,(assq-ref r 'coherence))))
                         chosen))
         (base `((scope . federation-a)
                 (chosen-alternatives . ,chosen)
                 (allocations . ,allocs)
                 (deficits . ,deficits)
                 (surpluses . ,surpluses)
                 (residual . ,residual)
                 (coherence . ,coh-avg))))
    (if weight-fn
        (cons `(harmony . ((total . ,harm-sum))) base)
        base)))
