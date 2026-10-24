;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-branch-and-bound.scm — the discrete layer SEARCHES, and its pruning is
;;; licensed by the convex certificate.
;;;
;;; Spec: docs/localchimera.typ §7 (the thin non-convex wrapper) + docs/social-category.typ
;;;       §8 Obligation 8 (a plan carries its proof).
;;;
;;; A minimum-batch process runs at ≥ L or not at all, so the on/off choice is
;;; genuinely combinatorial and no convex program decides it. What replaced the
;;; old enumerate-or-anneal split is branch-and-bound, and the reason it is worth
;;; a test of its own is that its SOUNDNESS rests on the certificate rather than
;;; on the solver behaving well:
;;;
;;;   A node's bound is the value of a relaxation. We do not have that value — we
;;;   have `solution-cost` at the point the solver stopped, which lies ABOVE it,
;;;   and pruning on a bound that is too high silently discards the optimum. The
;;;   certificate supplies the correction: f(x) − f(x*) ≤ gap-bound over the same
;;;   objective (kkt-report builds ∇f at barrier weight 0, so its f is
;;;   desire + κ·labour — exactly what `solution-cost` evaluates), so
;;;
;;;       node lower bound = solution-cost(x) − gap-bound
;;;
;;;   is valid, and where the certificate is +inf the node declines to prune.
;;;
;;; A PERSPECTIVE reformulation was the other candidate and does not apply here:
;;; it is tight when a semi-continuous variable carries a setup charge or a
;;; strictly convex on-cost, and this one has a LINEAR cost (κ·c·x) with no fixed
;;; charge — so conv({0} ∪ [L,U]) = [0,U], which is what dropping the floor
;;; already gives. The relaxation was already as tight as a convex relaxation
;;; gets; only branching improves it. That is asserted below, not just asserted
;;; in prose: the perspective bound and the drop-the-floor bound coincide.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/solve/test-branch-and-bound.scm

(use-modules (localchimera solve discrete))
(use-modules (localchimera test planner prelude)
             (localchimera solve engine) (localchimera test planner worked-example) (localchimera solve world)
             (localchimera solve solver)
             (srfi srfi-1)
             (ice-9 format))

;; ── brute force: the ground truth the search must reproduce ─────────────────
(define (all-subsets lst)
  (if (null? lst) '(())
      (let ((r (all-subsets (cdr lst))))
        (append r (map (lambda (s) (cons (car lst) s)) r)))))

(define (brute-force keys)                 ; → (cost . config), by exhaustion
  (fold (lambda (cfg best)
          (let ((c (cost-of-config cfg)))
            (if (< c (car best)) (cons c cfg) best)))
        (cons +inf.0 'none) (all-subsets keys)))

(define (bnb-on demand)                    ; → (cost cfg certified? root-lb nodes keys)
  (setup-batch demand)
  (let ((keys (batch-keys)))
    (call-with-values solve-discrete
      (lambda (cfg cert lb cost k nodes) (list cost cfg cert lb nodes keys)))))

;; ════════════════════════════════════════════════════════════════════════════
;; (1) the search finds what exhaustion finds
;; ════════════════════════════════════════════════════════════════════════════
;; The demands are chosen to straddle the floor (L = 80) in both directions and,
;; crucially, to include cases where the RELAXATION IS FRACTIONAL — at demand 40
;; it runs the mill at ~38.7 and at demand 79 at ~77.6, neither of which any
;; config can realise. Those are the cases where branching is doing work; a rig
;; of only easy demands would pass with the branching removed.
(display "\n── branch-and-bound agrees with exhaustion ──\n")

(for-each
 (lambda (demand)
   (let* ((r (bnb-on demand))
          (cost (car r)) (cfg (cadr r)) (cert (caddr r))
          (lb (cadddr r)) (nodes (list-ref r 4)) (keys (list-ref r 5))
          (bf (begin (setup-batch demand) (brute-force keys))))
     (format #t "  demand ~5,1f: B&B ~,4f via ~a node(s)~a   exhaustive ~,4f\n"
             demand cost nodes (if cert " [certified]" " [budget hit]") (car bf))
     ;; both sides solve each configuration's continuous program to the solver's own
     ;; tolerance (stationarity ~1e-3), the search warm and the enumeration cold, so the
     ;; two costs agree to that tolerance and not to the digit
     (check (format #f "demand ~a: the search reaches the exhaustive optimum" demand)
            (< (abs (- cost (car bf))) 2e-3))
     ;; The BOUND is the part that could be wrong without the answer being wrong.
     ;; A lower bound above the optimum is what unsound pruning looks like, and it
     ;; would not show up in the cost comparison above on a rig this small.
     (check (format #f "demand ~a: the root bound lies BELOW the optimum" demand)
            (<= lb (+ cost 1e-9)))
     (check (format #f "demand ~a: an exhausted tree certifies" demand) cert)))
 '(100.0 85.0 79.0 40.0 20.0))

;; ════════════════════════════════════════════════════════════════════════════
;; (2) the certificate is what licenses the pruning
;; ════════════════════════════════════════════════════════════════════════════
;; Stated as a property of the numbers rather than of the source: the node bound
;; must be the solved cost less the certified gap, and the gap must be finite for
;; the node to prune at all. If `certificate-of-last-solve` stopped reporting, the
;; bound would fall to −inf and the search would degrade to exhaustion — slower,
;; never wrong. That is the failure mode we want, and it is asserted here.
(display "\n── the node bound is the certificate, not the raw solve ──\n")

(setup-batch 40.0)
(let* ((keys (batch-keys))
       (node (node-solve '() keys))         ; the root: every floor dropped
       (lb (car node)) (cost (cadr node))
       (cert (certificate-of-last-solve))
       (gap (assq-ref cert 'gap-bound)))
  (format #t "  root: solved cost ~,6f   certified gap ~,3e   bound ~,6f\n" cost gap lb)
  (check "the root bound is cost − certified gap"
         (or (= gap +inf.0) (< (abs (- lb (- cost gap))) 1e-9)))
  (check "…and it is strictly below the solved cost, since the gap is positive"
         (or (= gap +inf.0) (< lb cost)))
  (check "a finite certificate is what makes the node prunable"
         (if (= gap +inf.0) (= lb -inf.0) (> lb -inf.0))))

;; ════════════════════════════════════════════════════════════════════════════
;; (3) the perspective relaxation would add nothing — measured, not argued
;; ════════════════════════════════════════════════════════════════════════════
;; conv({0} ∪ [L,U]) = [0,U] when the on-cost is linear and unfixed. So the
;; perspective bound and the drop-the-floor bound are the same number, and the
;; cheapest honest way to say so is to compute the relaxation two ways: with the
;; floor deleted (`relaxed-bound`) and with every column free in the search's own
;; sense (`node-solve` at the root). They must coincide.
(display "\n── perspective adds nothing on a linear on-cost ──\n")

(setup-batch 40.0)
(let* ((keys (batch-keys))
       (dropped (relaxed-bound keys))          ; MBQ deleted outright
       (freed   (cadr (node-solve '() keys)))) ; every column relaxed in-place
  (format #t "  floor deleted ~,6f   vs   columns freed ~,6f\n" dropped freed)
  (check "the two relaxations are the same program, so the same bound"
         (< (abs (- dropped freed)) 1e-6)))

;; ════════════════════════════════════════════════════════════════════════════
;; (4) branching is cheaper than enumeration where that matters
;; ════════════════════════════════════════════════════════════════════════════
;; On one batch column there is nothing to prune — two configs, and the seeding
;; alone costs two solves. The claim is about GROWTH: with k columns the search
;; must not visit 2^k nodes. Stated against 2^k rather than a tuned node count,
;; so the assertion survives the fixture changing size.
(display "\n── the tree is not the enumeration ──\n")

(define (multi-period-keys T)
  (declare-world! #:places '(("town" 40.0 -74.0)) #:periods (iota T)
                  #:templates (append *base-templates* (list *millb-template*)))
  (hash-set! *mbq-procs* "millb" 80.0)
  (for-each (lambda (t)
              (hash-set! *demand* (lg "bread" (cell "town" t)) 100.0)
              (hash-set! *cap* (lg "soil" (cell "town" t)) 400.0)
              (hash-set! *A* (cell "town" t) 400.0))
            (iota T))
  (batch-keys))

(let* ((T 8)
       (keys (multi-period-keys T))
       (k (length keys)))
  (call-with-values solve-discrete
    (lambda (cfg cert lb cost kk nodes)
      (format #t "  ~a batch columns: 2^~a = ~a configs, visited ~a node(s)\n"
              k k (expt 2 k) nodes)
      (check "every column is found, so the search is over the real problem"
             (= k T))
      (check "the search visits far fewer nodes than there are configurations"
             (< nodes (expt 2 k)))
      (check "…and still certifies" cert))))

;; ════════════════════════════════════════════════════════════════════════════
;; (5) UNDER STRESS: every column fractional at once
;; ════════════════════════════════════════════════════════════════════════════
;; Sections 1–4 all had relaxations that landed integral or nearly so, which
;; tests the FIXTURE's luck more than the search: a tree that never opens proves
;; nothing about branching. Here every period demands ~half the floor, so the
;; relaxation wants to run every mill strictly inside (0, L) and cannot — each
;; column must be branched. Checked against exhaustion, which is affordable only
;; because the fixture is deliberately small; that is the point of doing it here
;; and not at T = 10.
(display "\n── under stress: every column fractional ──\n")

(define (fractional-fixture T demand)
  (declare-world! #:places '(("town" 40.0 -74.0)) #:periods (iota T)
                  #:templates (append *base-templates* (list *millb-template*)))
  (hash-set! *mbq-procs* "millb" 80.0)
  (for-each (lambda (t)
              ;; alternating demands straddling the floor: some periods want a
              ;; batch, some want half of one, so the answer is a genuine MIX and
              ;; not "all on" or "all off" — either of which the seeding finds for
              ;; free without the search doing any work at all.
              (hash-set! *demand* (lg "bread" (cell "town" t))
                         (if (even? t) demand (* 2.2 demand)))
              (hash-set! *cap* (lg "soil" (cell "town" t)) 400.0)
              (hash-set! *A* (cell "town" t) 400.0))
            (iota T))
  (batch-keys))

(for-each
 (lambda (T)
   (let* ((keys (fractional-fixture T 40.0))
          (root (node-solve '() keys))
          (x (caddr root)) (idx (cadddr root))
          (frac (node-fractional keys x idx)))
     (format #t "  T=~a: ~a column(s), ~a fractional at the root\n"
             T (length keys) (length frac))
     (check (format #f "T=~a: the root relaxation really is fractional" T)
            (> (length frac) 0))
     ;; re-solve from a clean state, then exhaust for ground truth
     (let* ((keys (fractional-fixture T 40.0))
            (r (call-with-values solve-discrete
                 (lambda (cfg cert lb cost k nodes) (list cost cfg cert lb nodes))))
            (cost (car r)) (cfg (cadr r)) (cert (caddr r)) (nodes (list-ref r 4))
            (bf (begin (fractional-fixture T 40.0) (brute-force keys))))
       (format #t "        B&B ~,4f in ~a node(s)~a   exhaustive ~,4f over ~a configs\n"
               cost nodes (if cert " [certified]" " [budget hit]") (car bf) (expt 2 (length keys)))
       (check (format #f "T=~a: the search still reaches the exhaustive optimum" T)
              (< (abs (- cost (car bf))) 2e-3))
       (check (format #f "T=~a: the chosen config is a genuine mix, not all-on or all-off" T)
              (and (not (null? cfg)) (< (length cfg) (length keys))))
       (check (format #f "T=~a: it certifies" T) cert)
       ;; The SHAPE of the growth, gated cheaply here and measured out to B = 12
       ;; in bench-discrete.scm (45 nodes of 4096 configurations, 98.9% pruned).
       ;; Stated as a linear ceiling rather than a node count, so it fails if
       ;; branching ever degrades toward enumeration instead of merely printing a
       ;; bigger number.
       (check (format #f "T=~a: the tree stays near-linear in k, not exponential" T)
              (<= nodes (+ 8 (* 4 (length keys))))))))
 '(3 4))

(check-done "  The discrete layer searches, and the certificate is its licence.~%")
