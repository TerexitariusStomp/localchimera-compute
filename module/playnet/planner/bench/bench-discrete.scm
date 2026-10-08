;;; bench-discrete.scm — the NON-CONVEX core: minimum-batch (indivisible) processes.
;;; The convex solve fixes continuous levels; choosing each batch process ON/OFF is
;;; the genuinely non-convex shell. solve-discrete BRANCHES AND BOUNDS over it: each
;;; node is one cold convex solve of a relaxation, and the node's lower bound is that
;;; solve's cost less its CERTIFIED gap — which is what makes pruning sound rather
;;; than merely plausible. An exhausted tree is a certified global optimum; the
;;; `pruned` column is the fraction of the 2^B configurations never solved at all.
;;;
;;; A "town" over T periods, each period demanding bread with a big-batch mill (millb,
;;; ½ labour but only at ≥80) available — so B = T independent batch decisions.
;;;
;;; Run:  guile --no-auto-compile -q -L module module/playnet/planner/bench-discrete.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine))
(define (msx t0) (/ (* 1000.0 (- (get-internal-real-time) t0)) internal-time-units-per-second))

(define (setup-batch-T T demand)
  (declare-world! #:places '(("town" 40.0 -74.0)) #:periods (iota T)
                  #:templates (append *base-templates* (list *millb-template*)))
  (hash-set! *mbq-procs* "millb" 80.0)
  (for-each (lambda (t)
    (hash-set! *demand* (lg "bread" (cell "town" t)) demand)
    (hash-set! *cap* (lg "soil" (cell "town" t)) 400.0)
    (hash-set! *A* (cell "town" t) 400.0)) *periods*))

(format #t "~%==== non-convex core: minimum-batch discrete layer ====~%")
(format #t "    T  batch-keys   configs   nodes   pruned   convex(1)   discrete(all)   ratio   cert   gap~%")
(for-each (lambda (T)
  (setup-batch-T T 100.0)
  (let* ((nk (length (batch-keys)))
         (t1 (get-internal-real-time)) (_ (cost-of-config 'all)) (cms (msx t1))    ; one convex solve
         (t2 (get-internal-real-time))
         (r (call-with-values solve-discrete list)) (dms (msx t2))
         (cert (cadr r)) (lb (caddr r)) (cost (cadddr r))
         (k (list-ref r 4)) (nodes (list-ref r 5))
         (configs (expt 2 k)))
    ;; `pruned` is the search's whole point: what fraction of the 2^k configs the
    ;; certified bounds let us never solve. Enumeration's figure is 0 by
    ;; definition, so a column that stays near 0 means branching bought nothing.
    (format #t "  ~3a    ~3a     ~7a   ~5a   ~5,1f%   ~7,0f ms   ~8,0f ms   ~5,1f×   ~3a   ~5,2f~%"
            T nk configs nodes
            (* 100.0 (max 0.0 (- 1.0 (/ (exact->inexact nodes) (max 1.0 configs)))))
            cms dms (/ dms (max 1.0 cms)) (if cert "yes" "no") (max 0.0 (- cost lb)))
    (force-output)))
  (list 2 3 4 10))
(newline)

;; ── SCALING: where does certified-global actually stop? ──────────────────────
;; The sweep above uses demands that make the relaxation land integral, so the
;; tree never opens and the answer is "one node" regardless of B. That measures
;; the fixture's luck. This one alternates demands across the batch floor so many
;; columns are fractional at once — the case branching has to work for.
(define (setup-fractional T demand)
  (declare-world! #:places '(("town" 40.0 -74.0)) #:periods (iota T)
                  #:templates (append *base-templates* (list *millb-template*)))
  (hash-set! *mbq-procs* "millb" 80.0)
  (for-each (lambda (t)
    (hash-set! *demand* (lg "bread" (cell "town" t)) (if (even? t) demand (* 2.2 demand)))
    (hash-set! *cap* (lg "soil" (cell "town" t)) 400.0)
    (hash-set! *A* (cell "town" t) 400.0)) *periods*))

(format #t "~%==== branch-and-bound scaling · every column fractional ====~%")
(format #t "    B   configs    nodes   pruned   cert   ms/node      total~%")
(for-each (lambda (T)
  (setup-fractional T 40.0)
  (let* ((t0 (get-internal-real-time)))
    (call-with-values solve-discrete
      (lambda (cfg cert lb cost k nodes)
        (let ((ms (msx t0)))
          (format #t "  ~3a  ~8a   ~5a   ~5,1f%   ~4a  ~7,0f ms  ~7,1f s~%"
                  k (expt 2 k) nodes
                  (* 100.0 (- 1.0 (/ (exact->inexact nodes) (max 1.0 (expt 2 k)))))
                  (if cert "yes" "NO") (/ ms (max 1 nodes)) (/ ms 1000.0))
          (force-output))))))
  (list 4 6 8 10 12))
(newline)
;; MEASURED (12-core laptop, jobs=1), with a node closed on its inherited bound
;; BEFORE it is solved (a child is a restriction of its parent, so the parent's
;; certified bound is the child's until it has one of its own):
;;    B    configs   nodes   pruned   cert   total
;;    4         16       5    68.8%   yes    0.5 s
;;    6         64       7    89.1%   yes    1.3 s
;;    8        256       9    96.5%   yes    2.1 s
;;   10       1024      13    98.7%   yes    3.7 s
;;   12       4096      19    99.5%   yes    6.1 s
;;
;; Nodes grow ~1.5B + 1 — NEAR-LINEAR against an exponential configuration count,
;; and every size certifies global. So `*bnb-nodes*` (400) is not the limit anyone
;; meets: at this growth it corresponds to B in the hundreds. WALL TIME binds
;; first — each node is a full convex solve and the program itself grows with the
;; horizon. The honest ceiling on certified discrete planning is set by the
;; per-node solve, not by the search.
