;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; vf/aggregation/scope-tree.scm — the shared skeleton of a scope-tree aggregator.
;;;
;;; ^labour-pool and ^folksonomy are the SAME actor pattern: each holds an
;;; immutable indexed aggregate, refolds one member at a time, and pushes that
;;; per-member event UP the federation tree so a parent scope's aggregate is
;;; the sum of every member reachable through its subtree. What differs between
;;; them is only the STATE type, the refold, and the read methods — all of
;;; which stay in each actor. The mechanics they share live here, so the two
;;; are one pattern by construction rather than by resemblance.
;;;
;;; This is the small skeleton the twin actors converge on once BOTH forward
;;; their per-member event upward (rather than one pushing the event and the
;;; other pull-rebuilding from a shared store). The convergence is the point:
;;; no base class is imposed — the common plumbing simply factors out.
;;;
;;; The write tail of every aggregator method is:
;;;   (let ((next (refold state member…)))
;;;     (fire-update! callbacks next)                 ; UI / monitor sink
;;;     (forward-up! callbacks 'member-changed member…) ; parent scope
;;;     (bcom (^self bcom next callbacks) reply))
;;; The bcom self-reference is the only part that cannot factor out (it names
;;; the actor's own constructor), so each actor keeps its one-line rebuild.

(define-module (playnet vf aggregation scope-tree)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (playnet utils hashmap)     ; hashmap-values — the tree walk's members
  #:export (agg-ref fire-update! forward-up! set-callback
            scope-subtree-values scope-subtree-collect))

(define (agg-ref callbacks key)
  "Look up a callback (on-update, parent) in the actor's CALLBACKS alist."
  (let ((p (assq key callbacks))) (and p (cdr p))))

(define (fire-update! callbacks new-state)
  "Push the new aggregate to the on-update sink (the UI / a monitor), if bound."
  (let ((f (agg-ref callbacks 'on-update)))
    (when f (f new-state))))

(define (forward-up! callbacks method . args)
  "Forward a per-member write event to the parent scope's aggregator, if any.
   Same-vat near-call: the federation's scope actors share the gateway vat, so
   the whole tree is consistent within the turn. Correct because refolds are
   idempotent per member — re-folding the same member at every level is exact."
  (let ((parent (agg-ref callbacks 'parent)))
    (when parent (apply $ parent method args))))

(define (set-callback callbacks key val)
  "Return CALLBACKS with KEY bound to VAL, dropping any prior binding so the
   alist does not accumulate stale duplicates as sinks/parents are re-bound."
  (cons (cons key val) (alist-delete key callbacks eq?)))


;;; ── the walk ────────────────────────────────────────────────────────────────
;;; The other half of the same subject: where the push forwards a value UP one
;;; link at a time, this reads the WHOLE subtree in one pass. It is the fold's
;;; definition (see fold-node.scm) — what a node's standing total means, how a
;;; node is seeded, and the only thing a rebuild has to agree with. One walk, so
;;; the tree's awkward cases are handled once: a member with no economic root, a
;;; branch that is down or remote, a DAG, a cycle.

;; A resilient near-call: #f on ANY error — an absent method on a partial mock,
;; or a remote/down member — so a broken branch drops out instead of sinking the
;; walk.
(define (%send actor msg) (false-if-exception ($ actor msg)))

(define (scope-subtree-values scope own-of)
  "OWN-OF read at every scope in SCOPE's subtree — its own economic root, then
   its members' recursively, arbitrarily deep — as ONE VALUE PER SCOPE, in
   visit order. OWN-OF is (scope-root → value).

   Every ^scope is a uniform node — an economic root (`scope-root`, maybe #f)
   plus sub-scopes (`members`, maybe empty) — so one walk serves every reading
   taken off the tree. A visited-set (eq? identity) folds a CYCLE or a DAG (a
   commune shared by two federations) to ONE visit per node, so a loop
   terminates and shared membership never double-counts. A scope with no
   economic root, or one whose root cannot be reached, contributes no value
   rather than sinking the walk.

   Read FRESH: exact under REFEDERATION with nothing to rewire — the tree is
   whatever it is at the moment of the walk."
  (define seen (make-hash-table))
  ;; a node is a ^scope (its economic root behind `scope-root`) or the
  ;; economic root ITSELF, handed in directly — the service's roster holds
  ;; roots — which answers no `scope-root` and IS the root the reading is
  ;; taken off (found live: a root handed to the fold read as an empty
  ;; subtree, and every citizen's need resolved to a placeholder)
  (define (own s)
    (let ((root (or (%send s 'scope-root)
                    (and (%send s 'observer) s))))
      (and root (false-if-exception (own-of root)))))
  (define (members s)
    (let ((m (%send s 'members))) (if m (hashmap-values m) '())))
  (let walk ((s scope))
    (if (or (not s) (hashq-ref seen s #f))
        '()
        (begin (hashq-set! seen s #t)
               (let ((v (own s)))
                 (append (if v (list v) '()) (append-map walk (members s))))))))

(define (scope-subtree-collect scope own-of)
  "The same walk, with every scope's LIST concatenated into one — for readings
   whose values are lists of records (the resources a means may be socialized
   from; the needs a demand folds up) rather than something combined by a
   monoid. `scope-subtree-values` is the general shape; this is the common one."
  (concatenate (scope-subtree-values scope own-of)))
