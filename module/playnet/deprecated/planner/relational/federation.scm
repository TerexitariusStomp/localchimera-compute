;;; federation.scm — Generic recursive streamed federation substrate
;;;
;;; This file is the GENERIC SUBSTRATE for hierarchical scope planning.
;;; It is intentionally agnostic about what kind of planner runs at the
;;; leaves — different leaf planners (single-pass relational, multi-pass
;;; DDMRP, custom strategies) plug in via the #:leaf-planner parameter.
;;;
;;; Architecture:
;;;
;;;   ┌──────────────────────────────────────────────────────┐
;;;   │ federation.scm (this file) — generic substrate       │
;;;   │   • protocol: scope → lazy stream of result          │
;;;   │   • recursion: same shape at every level             │
;;;   │   • cross-scope: lateral match + retraction          │
;;;   │   • optimization: harmony (or any objective)         │
;;;   └────────┬─────────────────────────────────────────────┘
;;;            │
;;;            │ #:leaf-planner
;;;            ▼
;;;   ┌────────────────────────────┬─────────────────────────┐
;;;   │ default-relational         │ (future) ddmrp          │
;;;   │ leaf-planner               │ leaf-planner            │
;;;   │ (built-in, uses plan-o)    │ (wraps plan-for-unit)   │
;;;   └────────────────────────────┴─────────────────────────┘
;;;
;;; The federation substrate doesn't know or care which leaf planner
;;; runs at the bottom. It composes whatever the leaves produce, as
;;; long as those leaves emit federation-result alists conforming to
;;; the protocol below.
;;;
;;; This is the relational/lazy counterpart to plan-federation.scm.
;;; See docs/federation-comparison.md for a full side-by-side.
;;;
;;; Protocol — same at every level:
;;;
;;;   scope-stream : scope → lazy stream of federation-result
;;;
;;;   federation-result = ((scope . id)
;;;                        (plan . ...)
;;;                        (deficits . list of deficit-record)
;;;                        (surpluses . list of surplus-record)
;;;                        (retraction-candidates . list)
;;;                        (lateral-matches . list of match-record)
;;;                        (retractions . list of retraction-record)
;;;                        (harmony . (total . n) ...)      ; when weight-fn
;;;                        (residual . number))
;;;
;;;   deficit-record  = ((scope-id . id) (spec-id . s) (qty . q))
;;;   surplus-record  = ((scope-id . id) (spec-id . s) (qty . q))
;;;   match-record    = ((from-scope . s) (to-scope . t) (spec-id . x) (qty . q))
;;;
;;; Key names align with plan-federation.scm for consistency.
;;;
;;; Leaf: miniKanren search over local facts (plan-o from plan-relation.scm).
;;; Parent: interleave children's streams + lateral matching.
;;; When lateral matching exhausts surpluses but deficits remain, the
;;; retraction stream lazily retracts satisfied demands across scopes
;;; to free capacity for higher-priority needs. In harmony mode, the
;;; candidate with smallest expected weighted-harmony loss is retracted
;;; first, and the remaining candidates are re-sorted after each step.
;;; Consumers don't know or care which kind of stream they're pulling from.
;;;
;;; NETTING EQUIVALENCE
;;; -------------------
;;; The imperative plan-federation.scm uses a pure-state-monad netter
;;; (<netter-state> in netting.scm) to track allocated flows and call
;;; netter-retract when reclaiming resources for cross-scope reuse.
;;;
;;; This relational version has NO explicit netter. Its equivalent is
;;; the CLP(FD) global sum constraint system in allocation.scm:
;;;
;;;   - Each allocation posts a claim into the N field of the cstate
;;;     (see claim-from-o in allocation.scm)
;;;   - sum-leq-check enforces sum(claims) ≤ inventory globally
;;;   - Backtracking in miniKanren automatically restores the cstate,
;;;     which automatically unclaims flows — no explicit retract call
;;;     is needed because there was no mutation
;;;
;;; So "retraction" in this file means something narrower than in
;;; plan-federation.scm. Here it's a bookkeeping move on the already-
;;; reified plan: the satisfied demand is removed from
;;; retraction-candidates and its resources become surplus, allowing
;;; lateral matching to give them to another scope. The underlying
;;; CLP(FD) claims from the original search are untouched — we're
;;; editing the OUTPUT, not re-running the search.
;;;
;;; This is why retract-demand-from-state doesn't need to call
;;; anything like netter-retract: there's no stateful allocation to
;;; unwind. The plan was produced by a single relational search; the
;;; federation layer edits that plan's presentation for rebalancing.
;;;
;;; CAPABILITY GAP
;;; --------------
;;; federation.scm currently uses plan-o (plan-relation.scm) directly,
;;; which does single-pass relational BOM explosion. It does NOT run
;;; the multi-pass DDMRP pipeline (plan-for-unit.scm: buffer-zone
;;; evaluation, TOY-gated primary demand, derived replenishment,
;;; retry, supply phase). That pipeline is currently only available
;;; through the imperative plan-federation.scm path. Closing this gap
;;; is a future architectural decision; see docs/federation-comparison.md
;;; for options.

(define-module (playnet deprecated planner relational federation)
  #:use-module (playnet deprecated planner relational plan-walk)
  #:use-module (playnet deprecated planner relational plan-relation)
  #:use-module (playnet deprecated planner relational harmony)
  #:use-module (playnet deprecated planner relational streams)
  #:use-module (playnet deprecated planner relational plan-actor)
  #:export (<federation-config> %make-federation-config federation-config?
            cfg-weight-fn cfg-leaf-planner cfg-max-steps cfg-plan-actor?
            make-federation-config cfg-leaf-planner-or-default state-entry-id
            state-entry-result state-entry-stream make-state-entry scope-parent-o
            peer-scopes-o build-hierarchy default-relational-leaf-planner
            relational-plan->federation-result relational-state->federation-result
            scope-stream leaf-stream parent-stream search-stream evaluate-state
            entry-result collect-child-defs collect-child-surps collect-child-cands
            collect-child-plans collect-child-harmonies collect-child-coherences
            sum-qty sum-harmony-totals subtract-matched match-at-level
            retraction-stream sort-retraction-candidates deficit-spec
            relevant-candidate? expected-retraction-loss retraction-harmony-loss
            retract-one-stream residual-zero? retraction-improved?
            expected-transfer-for-cand enrich-retraction-record
            retract-demand-from-state add-retraction-record advance-worst
            advance-worst-by-harmony advance-worst-by-coherence advance-child
            pull-from-all plan-federation-o))

(use-modules (playnet deprecated kanren-constraints)
             (srfi srfi-1)
             (srfi srfi-9))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Federation config
;;; ══════════════════════════════════════════════════════════════════════════════
;;;
;;; A single record carries all the parameters that flow through the
;;; federation substrate, instead of threading multiple keyword args
;;; through every function. New options become new fields, with no
;;; signature churn across the call graph.
;;;
;;; Fields:
;;;   weight-fn    — (spec-id) → weight (higher = more important)
;;;                  Always exponential. Constructed from a level-fn at
;;;                  the API boundary.
;;;   leaf-planner — (scope-id ctx cfg) → lazy stream of federation-result
;;;   max-steps    — search step bound for parent-stream interleaving
;;;
;;; Priority semantics: there is ONE convention — higher weight means
;;; more important. Governance sets per-spec LEVELS (small integers,
;;; 0-10ish); make-weight-fn from harmony.scm exponentiates levels into
;;; weights at the API boundary. The substrate only ever sees weights.
;;; The legacy "lower priority number = more urgent" convention from
;;; plan-federation.scm is gone from this file.

(define-record-type <federation-config>
  (%make-federation-config weight-fn leaf-planner max-steps plan-actor?)
  federation-config?
  (weight-fn    cfg-weight-fn)
  (leaf-planner cfg-leaf-planner)
  (max-steps    cfg-max-steps)
  (plan-actor?  cfg-plan-actor?))

(define* (make-federation-config
          #:key (level-fn #f)
                (weight-fn #f)
                (leaf-planner #f)  ;; resolved at use-site to avoid forward ref
                (max-steps 50)
                (plan-actor? #f))
  "Build a federation config. All fields default to sensible values.

   LEVEL-FN is the user-facing harmony API: a function (spec-id) →
   small integer level (0-10ish). It's exponentiated via make-weight-fn
   to produce the actual multiplier the substrate uses. If both LEVEL-FN
   and WEIGHT-FN are given, level-fn wins.

   WEIGHT-FN is the advanced API: a function (spec-id) → already-
   computed weight (higher = more important). Use this if you want to
   bypass the exponentiation or use a custom scaling.

   leaf-planner defaults to default-relational-leaf-planner (resolved
   below to avoid a forward reference).

   PLAN-ACTOR? when #t, leaf planners emit federation-results whose
   plan field is an actor ref (^plan-actor) instead of an inline
   nested list. Consumers use $ / <- on the ref for lazy per-subtree
   access. See plan-actor.scm. Default #f for backward compatibility
   with existing consumers that read the inline 'plan field directly."
  (%make-federation-config (cond
                             (level-fn (make-weight-fn level-fn))
                             (else weight-fn))
                           leaf-planner
                           max-steps
                           plan-actor?))

(define (cfg-leaf-planner-or-default cfg)
  "Return cfg's leaf-planner, falling back to the default if unset."
  (or (cfg-leaf-planner cfg) default-relational-leaf-planner))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; State-entry accessors
;;; ══════════════════════════════════════════════════════════════════════════════
;;;
;;; A state entry is a list (child-id federation-result rest-stream).
;;; These accessors give it names so the federation code reads as
;;; structured data instead of car/cadr/caddr.

(define (state-entry-id e)     (car e))
(define (state-entry-result e) (cadr e))
(define (state-entry-stream e) (caddr e))

(define (make-state-entry id result stream) (list id result stream))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Hierarchy
;;; ══════════════════════════════════════════════════════════════════════════════

(define (scope-parent-o facts child parent)
  (in-list-o `(scope-parent ,child ,parent) facts))

(define (peer-scopes-o facts scope-a scope-b)
  (fresh (parent)
    (scope-parent-o facts scope-a parent)
    (scope-parent-o facts scope-b parent)
    (=/= scope-a scope-b)))

(define (build-hierarchy facts scope-ids parent-map)
  "scope-id → list of child-ids."
  (let ((ch (make-hash-table)))
    (for-each (lambda (id) (hash-set! ch id '())) scope-ids)
    (for-each (lambda (id)
                (let ((parent (assoc-ref parent-map id)))
                  (when (and parent (member parent scope-ids))
                    (hash-set! ch parent (cons id (hash-ref ch parent '()))))))
              scope-ids)
    (hash-map->list cons ch)))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Leaf-planner protocol
;;; ══════════════════════════════════════════════════════════════════════════════
;;;
;;; A LEAF PLANNER is a function that produces a federation-result lazy
;;; stream for a single scope, given that scope's planning context and
;;; the active federation config.
;;;
;;;   leaf-planner :: scope-id × ctx × cfg → lazy-stream of federation-result
;;;
;;; The cfg is the same federation-config that flows through the rest
;;; of the substrate. Leaf planners use it to access weight-fn (for
;;; harmony evaluation), and any future per-run options that get
;;; added as cfg fields. They don't need to know about scope-stream,
;;; parent-stream, or any other substrate internals.
;;;
;;; The federation substrate (scope-stream / parent-stream / evaluate-state /
;;; retraction-stream) does NOT care how the planner produces its results.
;;; It only requires that each result conform to the federation-result alist
;;; protocol described at the top of this file.
;;;
;;; Built-in leaf planners:
;;;   default-relational-leaf-planner — wraps plan-o (plan-relation.scm).
;;;     Single-pass relational BOM explosion via miniKanren + CLP(FD).
;;;
;;; Future leaf planners (extension points):
;;;   ddmrp-leaf-planner — wraps plan-for-unit (multi-pass DDMRP pipeline)
;;;   custom-leaf-planner — anything that produces federation-results
;;;
;;; The federation substrate is generic: it composes leaf planners
;;; recursively, performs cross-scope lateral matching, runs harmony-aware
;;; retraction, and aggregates results — all without knowing what kind
;;; of leaf planner sits at the bottom.
;;;
;;; Helper toolkit (for use by leaf-planner authors):
;;;   extract-deficits, extract-surpluses, extract-retraction-candidates
;;;     — pull federation signals out of a relational plan structure
;;;   plan-harmony — compute weighted harmony from a plan
;;;   stream-map-lazy — wrap a state stream as a result stream

;; *default-leaf-result-count* is defined in plan-walk.scm so that
;; strategy.scm (which loads earlier) can also reference it without
;; a forward-declaration warning.

(define (default-relational-leaf-planner scope-id ctx cfg)
  "The built-in leaf planner: runs plan-o on CTX (a plan-relation context)
   and returns a list of federation-results sorted by plan coherence
   (most self-sufficient first). This is the relational single-pass
   planner — see plan-relation.scm.

   IMPORTANT: the relational solver always succeeds because the unmet
   branch in after-allocation is unconditionally available. miniKanren's
   conde interleaving favors the cheap unmet branch over the compound
   produce-branch, so 'first solution' from (run-plan 1 ...) is often
   an unmet result even when a satisfying produce result is reachable.

   The fix is to enumerate multiple alternatives and rank them by
   plan-coherence (the per-scope self-sufficiency metric). The first
   element of the returned list is then the most self-sufficient
   alternative the search found within MAX-RESULTS attempts.

   When CFG carries a weight-fn, harmony is used in two ways:

     1. As a search-ordering signal: by-harmony-priority is passed as
        plan-o's #:demand-order, so high-weight specs are processed first.
        Under greedy allocation, this means essentials (high-weight) get
        served before luxuries (low-weight) under scarcity.

     2. As a post-hoc score: each federation-result carries the
        plan's total weighted harmony for use by federation-level
        rebalancing (advance-worst-by-harmony, retraction sort).

   Returns the empty list if CTX is #f.
   See plan-walk.scm:plan-coherence and docs/planner-known-gaps.md."
  (let ((weight-fn (cfg-weight-fn cfg)))
    (if (not ctx)
        '()
        (let* ((demand-order (and weight-fn (by-harmony-priority weight-fn)))
               (max-results (or (and cfg (cfg-max-steps cfg))
                                *default-leaf-result-count*))
               ;; Enumerate alternatives — the search may produce many
               ;; including all-unmet ones; coherence ranking sorts them.
               (raw-plans (run-plan max-results '() (plan)
                            (plan-o ctx plan
                                    #:max-depth 5
                                    #:demand-order demand-order)))
               ;; Rank by coherence descending (more self-sufficient first)
               (sorted (sort raw-plans
                         (lambda (a b)
                           (> (plan-coherence a) (plan-coherence b)))))
               (to-result (if (cfg-plan-actor? cfg)
                              relational-plan->plan-actor-result
                              relational-plan->federation-result)))
          (map (lambda (plan) (to-result plan scope-id weight-fn))
               sorted)))))

(define (relational-plan->federation-result plan scope-id weight-fn)
  "Convert a reified plan from plan-o into a federation-result alist.
   Used by default-relational-leaf-planner. The plan is already
   reified (run-plan returns ground plans, not cstates)."
  (let* ((defs (extract-deficits plan scope-id))
         (surps (extract-surpluses plan scope-id))
         ;; Lazy: alternatives that are enumerated but never picked
         ;; (4 of 5 in a coherence-ranked run) don't pay the walk cost.
         (cands (delay (extract-retraction-candidates plan scope-id)))
         (resid (fold (lambda (d a) (+ a (assq-ref d 'qty))) 0 defs))
         (coherence (plan-coherence plan))
         (harmony-result (and weight-fn
                              (plan-harmony plan #:priority-fn weight-fn)))
         (base `((scope . ,scope-id) (plan . ,plan)
                 (deficits . ,defs) (surpluses . ,surps)
                 (retraction-candidates . ,cands)
                 (residual . ,resid)
                 (coherence . ,coherence))))
    (if harmony-result
        (cons `(harmony . ,harmony-result) base)
        base)))

;; Backward-compat wrapper for the old state-based API. Some code paths
;; still pass cstates to relational-state->federation-result; they
;; reify and delegate to the plan-based version above.
(define (relational-state->federation-result state scope-id weight-fn)
  "Convert a miniKanren cstate from plan-o into a federation-result alist.
   Reifies the cstate and delegates to relational-plan->federation-result.
   Kept for backward compatibility — new code should use the plan-based
   variant directly via run-plan."
  (relational-plan->federation-result
    (reify-from-state state) scope-id weight-fn))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; scope-stream — the universal protocol
;;; ══════════════════════════════════════════════════════════════════════════════

(define* (scope-stream facts scope-id ctx-map children-of cfg
                       #:optional (visited '()))
  "Produce a lazy stream of federation-results for SCOPE-ID.
   CFG is the federation config carrying priority-fn, weight-fn, and
   leaf-planner. VISITED guards against cycles in the scope-parent graph
   (defaults to empty for the top-level call)."
  (if (member scope-id visited)
      '()  ;; cycle detected — stop
      (let ((children (or (assoc-ref children-of scope-id) '()))
            (visited* (cons scope-id visited)))
        (if (null? children)
            (leaf-stream scope-id ctx-map cfg)
            (parent-stream facts scope-id children ctx-map children-of
                           visited* cfg)))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Leaf stream — thin dispatcher to a leaf planner
;;; ══════════════════════════════════════════════════════════════════════════════

(define (leaf-stream scope-id ctx-map cfg)
  "Lazy stream of federation-results for a leaf scope.
   Looks up the scope's ctx in CTX-MAP and dispatches to the leaf-planner
   in CFG. The leaf-planner is responsible for producing federation-result
   alists.

   This is intentionally a thin dispatcher: federation.scm doesn't know
   what kind of planner runs at the leaves. Different planners (relational
   single-pass, imperative DDMRP multi-pass, etc.) plug in via cfg's
   leaf-planner field, all sharing the same federation-result protocol."
  ((cfg-leaf-planner-or-default cfg)
   scope-id
   (assoc-ref ctx-map scope-id)
   cfg))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Parent stream
;;; ══════════════════════════════════════════════════════════════════════════════

(define (parent-stream facts scope-id children ctx-map children-of visited cfg)
  "Lazy stream: interleave children's streams + lateral matching + retraction.
   CFG is threaded through to descendant scope-streams so the same
   leaf strategy and options apply everywhere in the subtree."
  (let* ((child-streams
           (map (lambda (cid)
                  (cons cid (scope-stream facts cid ctx-map children-of cfg visited)))
                children))
         (initial (pull-from-all child-streams)))
    (if (null? initial)
        '()
        (search-stream facts scope-id initial (cfg-max-steps cfg) cfg))))

(define (search-stream facts scope-id state steps cfg)
  "Lazy stream of improving federation-results.
   When the chosen advance-worst exhausts stream positions, chains
   into retraction. Steering strategy:
     1. weight-fn given → advance-worst-by-harmony (lowest harmony first)
     2. otherwise       → advance-worst-by-coherence (least self-sufficient)
   The coherence-based strategy is the new default — it's always
   available because every leaf-planner result carries a coherence
   field. The legacy advance-worst (largest deficit) is kept as a
   fallback for results that have no coherence (legacy callers)."
  (let* ((weight-fn (cfg-weight-fn cfg))
         (result (evaluate-state facts scope-id state cfg)))
    (if (or (<= steps 0) (= (assq-ref result 'residual) 0))
        (list result)
        (cons result
              (lambda ()
                (let ((advanced
                        (cond
                          (weight-fn
                           (advance-worst-by-harmony state result weight-fn))
                          (else
                           (or (advance-worst-by-coherence state result)
                               (advance-worst state result))))))
                  (if advanced
                      (search-stream facts scope-id advanced (- steps 1) cfg)
                      ;; No more stream positions — try retraction
                      (retraction-stream facts scope-id state result cfg))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Evaluate: match children's results at this level
;;; ══════════════════════════════════════════════════════════════════════════════

(define (evaluate-state facts scope-id state cfg)
  "state = list of state-entries (child-id federation-result rest-stream).
   Returns a federation-result for this scope. CFG carries weight-fn
   for harmony aggregation. Coherence is always aggregated (mean of
   children's coherence scores) so it propagates up the hierarchy."
  (let* ((weight-fn    (cfg-weight-fn cfg))
         (child-defs   (collect-child-defs state))
         (child-surps  (collect-child-surps state))
         (child-cands  (collect-child-cands state))
         (child-plans  (collect-child-plans state))
         (child-h      (and weight-fn (collect-child-harmonies state)))
         (child-cohs   (collect-child-coherences state))
         ;; Lateral match deficits against surpluses
         (match-result (match-at-level child-defs child-surps))
         (matches      (car match-result))
         (unmatched    (cdr match-result))
         (residual     (sum-qty unmatched))
         (coherence    (if (null? child-cohs)
                           1
                           (/ (apply + child-cohs) (length child-cohs)))))
    `((scope . ,scope-id)
      (plan . ,child-plans)
      ,@(if child-h
            `((harmony . ((total . ,(sum-harmony-totals child-h))
                          (per-child . ,child-h))))
            '())
      (coherence . ,coherence)
      (deficits . ,unmatched)
      (surpluses . ,(subtract-matched child-surps matches))
      (retraction-candidates . ,child-cands)
      (lateral-matches . ,matches)
      (residual . ,residual))))


;;; ── evaluate-state helpers ──────────────────────────────────────────────────
;;; Each helper does one walk of the children's state list and pulls out
;;; one kind of information. Splitting them keeps each walk obvious and
;;; lets evaluate-state read like an outline of what it does.

(define (entry-result entry)
  "Extract the federation-result alist from a state-entry, or #f
   if the slot is empty/malformed."
  (let ((r (state-entry-result entry)))
    (and (pair? r) r)))

(define (collect-child-defs state)
  "All children's deficits, each tagged with the child-id (so the
   parent can attribute multi-level deficits back to the right scope)."
  (append-map
    (lambda (e)
      (let ((cid (state-entry-id e)) (r (entry-result e)))
        (if r
            (map (lambda (d) (cons (cons 'child cid) d))
                 (or (assq-ref r 'deficits) '()))
            '())))
    state))

(define (collect-child-surps state)
  "All children's surpluses, untagged."
  (append-map
    (lambda (e)
      (let ((r (entry-result e)))
        (or (and r (assq-ref r 'surpluses)) '())))
    state))

(define (collect-child-cands state)
  "All children's retraction candidates, untouched. Forces any lazy
   producer-side promises so the aggregated list is inline for the
   parent result."
  (append-map
    (lambda (e)
      (let ((r (entry-result e)))
        (if r (force-cands (assq-ref r 'retraction-candidates)) '())))
    state))

(define (collect-child-plans state)
  "Combined plan: alist of (child-id . child-plan-or-ref). In
   plan-actor mode, child-plan-or-ref is the leaf's ^plan-actor ref;
   consumers call $ ref 'demand-pairs / 'subplan-of / 'full as
   needed. In inline mode, it's the nested plan structure as before.
   Either way, the shape aggregated at the parent is an alist keyed
   by child-id."
  (map (lambda (e)
         (let ((r (entry-result e)))
           (cons (state-entry-id e)
                 (if r
                     (or (assq-ref r 'plan)
                         (assq-ref r 'plan-ref)
                         '())
                     '()))))
       state))

(define (collect-child-harmonies state)
  "All children's harmony alists (those that have one)."
  (filter-map
    (lambda (e)
      (let ((r (entry-result e)))
        (and r (assq-ref r 'harmony))))
    state))

(define (collect-child-coherences state)
  "All children's coherence values (those that have one). Used by
   evaluate-state to aggregate coherence at the parent level."
  (filter-map
    (lambda (e)
      (let ((r (entry-result e)))
        (and r (assq-ref r 'coherence))))
    state))

(define (sum-qty deficits)
  "Sum the 'qty field of a list of deficit/surplus records."
  (fold (lambda (d acc) (+ acc (or (assq-ref d 'qty) 0))) 0 deficits))

(define (sum-harmony-totals harmonies)
  "Sum the 'total field of a list of harmony alists."
  (fold (lambda (h acc) (+ acc (or (assq-ref h 'total) 0))) 0 harmonies))

(define (subtract-matched surpluses matches)
  "Reduce surpluses by matched quantities. Fully consumed surpluses are removed."
  (fold (lambda (m sups)
    (filter-map (lambda (s)
      (if (and (equal? (assq-ref s 'scope-id) (assq-ref m 'from-scope))
               (equal? (assq-ref s 'spec-id) (assq-ref m 'spec-id)))
          (let ((new-qty (- (assq-ref s 'qty) (assq-ref m 'qty))))
            (if (<= new-qty 0) #f
                (cons (cons 'qty new-qty)
                      (filter (lambda (p) (not (eq? (car p) 'qty))) s))))
          s))
      sups))
    surpluses matches))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Lateral matching
;;; ══════════════════════════════════════════════════════════════════════════════

(define (match-at-level deficits surpluses)
  "Match deficits with surpluses (same spec-id, different scope).
   Returns (matches . unmatched-deficits).
   Matches: ((from-scope . s) (to-scope . t) (spec-id . x) (qty . q))"
  (let loop ((defs deficits) (sups surpluses) (matches '()) (unmatched '()))
    (if (null? defs)
        (cons (reverse matches) (reverse unmatched))
        (let* ((d (car defs))
               (dsp (assq-ref d 'spec-id)) (dq (assq-ref d 'qty))
               (d-scope (or (assq-ref d 'child) (assq-ref d 'scope-id)))
               (m (find (lambda (s)
                          (and (equal? (assq-ref s 'spec-id) dsp)
                               (not (equal? (assq-ref s 'scope-id) d-scope))
                               (> (assq-ref s 'qty) 0)))
                        sups)))
          (if (not m)
              (loop (cdr defs) sups matches (cons d unmatched))
              (let* ((sq (assq-ref m 'qty)) (q (min dq sq))
                     (match `((from-scope . ,(assq-ref m 'scope-id))
                              (to-scope . ,d-scope)
                              (spec-id . ,dsp) (qty . ,q)))
                     (new-sups (map (lambda (s)
                       (if (eq? s m)
                           (cons (cons 'qty (- sq q))
                                 (filter (lambda (p) (not (eq? (car p) 'qty))) s))
                           s))
                       sups)))
                (if (>= q dq)
                    (loop (cdr defs) new-sups (cons match matches) unmatched)
                    (let ((remaining-d (cons (cons 'qty (- dq q))
                                             (filter (lambda (p) (not (eq? (car p) 'qty))) d))))
                      (loop (cons remaining-d (cdr defs)) new-sups
                            (cons match matches) unmatched)))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Retraction stream — lazy cross-scope priority-aware retraction
;;; ══════════════════════════════════════════════════════════════════════════════

(define (retraction-stream facts scope-id state result cfg)
  "Lazy stream: retract satisfied demands to free capacity for deficits.
   Candidates are filtered to those that could actually serve a deficit,
   then ordered by expected harmony loss (which accounts for the quadratic
   nature of partial retraction). Requires CFG to carry a weight-fn —
   without one, no retraction occurs (returns the unchanged result)."
  (let* ((weight-fn  (cfg-weight-fn cfg))
         (candidates (force-cands (assq-ref result 'retraction-candidates)))
         (deficits   (or (assq-ref result 'deficits) '()))
         (sorted     (and weight-fn
                          (sort-retraction-candidates candidates deficits weight-fn))))
    (if (or (not sorted) (null? sorted) (null? deficits))
        (list result)
        (retract-one-stream facts scope-id state sorted result cfg))))

(define (sort-retraction-candidates candidates deficits weight-fn)
  "Order retraction candidates from least-costly to most-costly to retract.
   Filters to candidates that match some deficit, then sorts by expected
   harmony loss given the current deficits."
  (let ((relevant (filter (lambda (c) (relevant-candidate? c deficits))
                          candidates)))
    (sort relevant
      (lambda (a b)
        (< (expected-retraction-loss a deficits weight-fn)
           (expected-retraction-loss b deficits weight-fn))))))

(define (deficit-spec d)
  "Extract spec-id from a deficit alist."
  (assq-ref d 'spec-id))

(define (relevant-candidate? cand deficits)
  "True if at least one deficit could be served by retracting CAND
   (i.e. some deficit's spec matches the candidate's spec)."
  (let ((spec (assq-ref cand 'spec-id)))
    (any (lambda (d) (equal? (deficit-spec d) spec)) deficits)))

(define (expected-retraction-loss cand deficits weight-fn)
  "Expected weighted-harmony loss from retracting CAND given current
   deficits. Calls retraction-loss-exact with the expected transfer
   amount (the sum of deficits matching this candidate's spec,
   clamped to the candidate's qty). Assumes CAND is relevant — if
   there's no matching deficit, returns 0 (caller should filter)."
  (let* ((spec (assq-ref cand 'spec-id))
         (cand-qty (or (assq-ref cand 'qty) 0))
         (total-matching-deficit
           (fold (lambda (d acc)
                   (if (equal? (deficit-spec d) spec)
                       (+ acc (or (assq-ref d 'qty) 0))
                       acc))
                 0 deficits))
         (expected-transfer (min cand-qty total-matching-deficit)))
    (retraction-loss-exact cand expected-transfer weight-fn)))

(define (retraction-harmony-loss cand weight-fn)
  "Upper-bound weighted-harmony loss for sort ordering.
   Deprecated in favor of expected-retraction-loss (which is
   deficit-aware). Kept for backward compatibility."
  (retraction-loss-upper cand weight-fn))

(define (retract-one-stream facts scope-id state candidates prev-result cfg)
  "Each step: retract one candidate, re-evaluate lateral matching.
   When CFG has a weight-fn, candidates are re-sorted between steps
   so that the sort key reflects the post-retraction deficits."
  (if (null? candidates)
      (list prev-result)
      (let* ((cand          (car candidates))
             (transfer-qty  (expected-transfer-for-cand cand prev-result))
             (new-state     (retract-demand-from-state state cand))
             (new-result    (evaluate-state facts scope-id new-state cfg))
             (enriched      (enrich-retraction-record cand transfer-qty prev-result)))
        (cond
          ((residual-zero? new-result)
           (list (add-retraction-record new-result enriched)))
          ((retraction-improved? new-result prev-result)
           (let* ((result*  (add-retraction-record new-result enriched))
                  (resorted (sort-retraction-candidates
                              (cdr candidates)
                              (or (assq-ref result* 'deficits) '())
                              (cfg-weight-fn cfg))))
             (cons result*
                   (lambda ()
                     (retract-one-stream facts scope-id new-state
                       resorted result* cfg)))))
          (else
           (retract-one-stream facts scope-id new-state
             (cdr candidates) prev-result cfg))))))

(define (residual-zero? result)
  "True if RESULT has no remaining unmet deficits."
  (= (assq-ref result 'residual) 0))

(define (retraction-improved? new-result prev-result)
  "True if NEW-RESULT has strictly less residual than PREV-RESULT."
  (< (assq-ref new-result 'residual)
     (assq-ref prev-result 'residual)))

(define (expected-transfer-for-cand cand result)
  "How much of CAND is expected to be transferred in a retraction,
   given the deficits in RESULT. Used for informational purposes
   when recording retractions."
  (let* ((spec (assq-ref cand 'spec-id))
         (cand-qty (or (assq-ref cand 'qty) 0))
         (deficits (or (assq-ref result 'deficits) '()))
         (total-def
           (fold (lambda (d acc)
                   (if (equal? (deficit-spec d) spec)
                       (+ acc (or (assq-ref d 'qty) 0))
                       acc))
                 0 deficits)))
    (min cand-qty total-def)))

(define (enrich-retraction-record cand transfer-qty prev-result)
  "Wrap a retraction candidate with additional fields for the
   retraction record: transferred quantity and target scope(s).
   Target scopes are inferred from deficits that match this candidate."
  (let* ((spec (assq-ref cand 'spec-id))
         (deficits (or (assq-ref prev-result 'deficits) '()))
         (target-scopes
           (filter-map
             (lambda (d)
               (and (equal? (deficit-spec d) spec)
                    (or (assq-ref d 'child) (assq-ref d 'scope-id))))
             deficits)))
    `((from-scope . ,(assq-ref cand 'scope-id))
      (to-scopes . ,target-scopes)
      (spec-id . ,spec)
      (qty . ,transfer-qty)
      (retracted-plan-id . ,(assq-ref cand 'plan-id))
      ,@cand)))

(define (retract-demand-from-state state candidate)
  "Federation-level retraction: remove a satisfied demand from its child's
   result and convert its resources to surplus."
  (let ((target-scope (assq-ref candidate 'scope-id))
        (target-spec  (assq-ref candidate 'spec-id))
        (target-qty   (assq-ref candidate 'qty)))
    (map (lambda (entry)
           (let ((cid (state-entry-id entry))
                 (r   (entry-result entry)))
             (if (not (equal? cid target-scope))
                 entry
                 (let* ((old-cands (force-cands
                                     (and r (assq-ref r 'retraction-candidates))))
                        (new-cands (filter
                                     (lambda (c)
                                       (not (and (equal? (assq-ref c 'spec-id) target-spec)
                                                 (equal? (assq-ref c 'plan-id)
                                                         (assq-ref candidate 'plan-id)))))
                                     old-cands))
                        (old-surps (or (and r (assq-ref r 'surpluses)) '()))
                        (new-surps (cons `((scope . ,cid) (spec . ,target-spec)
                                          (qty . ,target-qty))
                                        old-surps))
                        (new-result
                          (map (lambda (pair)
                                 (cond
                                   ((eq? (car pair) 'retraction-candidates)
                                    (cons 'retraction-candidates new-cands))
                                   ((eq? (car pair) 'surpluses)
                                    (cons 'surpluses new-surps))
                                   (else pair)))
                               r)))
                   (make-state-entry cid new-result (state-entry-stream entry))))))
         state)))

(define (add-retraction-record result candidate)
  "Add a retraction to the result's retractions list."
  (let ((existing (or (assq-ref result 'retractions) '())))
    (cons (cons 'retractions (cons candidate existing))
          (filter (lambda (p) (not (eq? (car p) 'retractions))) result))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Advance: move the worst child's stream forward one step
;;; ══════════════════════════════════════════════════════════════════════════════

(define (advance-worst state result)
  "Advance the child whose deficit is largest (legacy: deficit-quantity)."
  (let ((unmatched (or (assq-ref result 'deficits) '())))
    (if (null? unmatched) #f
        (let* ((sorted (sort unmatched
                  (lambda (a b) (> (assq-ref a 'qty) (assq-ref b 'qty)))))
               (worst-child (or (assq-ref (car sorted) 'child)
                                (assq-ref (car sorted) 'scope-id))))
          (advance-child state worst-child)))))

(define (advance-worst-by-harmony state result weight-fn)
  "Advance the child whose weighted harmony is lowest.
   Falls back to deficit-based advance if no child has a harmony score."
  (let ((scored
          (filter-map
            (lambda (entry)
              (let* ((r     (entry-result entry))
                     (h     (and r (assq-ref r 'harmony)))
                     (total (and h (assq-ref h 'total))))
                (and total (cons (state-entry-id entry) total))))
            state)))
    (if (null? scored)
        (advance-worst state result)  ;; fallback
        (let ((worst-child (car (car (sort scored
                                       (lambda (a b) (< (cdr a) (cdr b))))))))
          (advance-child state worst-child)))))

(define (advance-worst-by-coherence state result)
  "Advance the child whose plan coherence is lowest (least self-
   sufficient). This is the new default steering strategy because
   coherence is always available — every leaf-planner result carries
   a 'coherence field. Returns #f if no child has coherence (i.e.,
   the legacy planner without coherence ranking is in use), so the
   caller can fall back to deficit-based advance.

   This is the federation-level analog of the leaf-planner's coherence
   ranking: pull more alternatives from the LEAST self-sufficient
   child first, since that's where there's the most room to improve."
  (let ((scored
          (filter-map
            (lambda (entry)
              (let* ((r (entry-result entry))
                     (c (and r (assq-ref r 'coherence))))
                (and c (cons (state-entry-id entry) c))))
            state)))
    (if (null? scored)
        #f  ;; signal: no coherence info available, caller falls back
        (let ((worst-child (car (car (sort scored
                                       (lambda (a b) (< (cdr a) (cdr b))))))))
          (advance-child state worst-child)))))

(define (advance-child state child-id)
  "Pull next result from CHILD-ID's stream. Returns updated state or #f."
  (let loop ((entries state) (acc '()))
    (if (null? entries) #f
        (let ((entry (car entries)))
          (if (not (equal? (state-entry-id entry) child-id))
              (loop (cdr entries) (cons entry acc))
              (let ((next (stream-take-1 (state-entry-stream entry))))
                (if (not next) #f
                    (append (reverse acc)
                            (list (make-state-entry child-id (car next) (cdr next)))
                            (cdr entries)))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Stream → state-entry adapter
;;; ══════════════════════════════════════════════════════════════════════════════
;;; The general lazy-stream utilities live in streams.scm. This adapter
;;; wraps pull-one-each's raw results into federation state-entries.

(define (pull-from-all child-streams)
  "Pull one federation-result from each child's stream.
   CHILD-STREAMS: alist of (child-id . stream).
   Returns: list of state-entries with empty placeholders for exhausted
   children."
  (map (lambda (pair)
         (let ((cid (car pair)) (pulled (cdr pair)))
           (if pulled
               (make-state-entry cid (car pulled) (cdr pulled))
               (make-state-entry cid '() '()))))
       (pull-one-each child-streams)))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Plan extraction (federation-result fields from a relational plan)
;;; ══════════════════════════════════════════════════════════════════════════════
;;;
;;; (reify-from-state lives in plan-walk.scm — it's a generic miniKanren
;;; reification helper, not federation-specific.)
;;;
;;; The three extract functions walk the top-level demand pairs of a
;;; relational plan and classify them. They use plan-walk.scm helpers
;;; (fold-demand-pairs, plan-term predicates, named accessors) so the
;;; pattern-matching of plan terms isn't reinvented here.

;;; ══════════════════════════════════════════════════════════════════════════════
;;; Entry point
;;; ══════════════════════════════════════════════════════════════════════════════

(define* (plan-federation-o facts scope-ids parent-map ctx-map result
                            #:key (level-fn #f) (weight-fn #f)
                                  (leaf-planner #f) (max-steps 50)
                                  (plan-actor? #f))
  "Recursive streamed federation. Same protocol at every level.

   HARMONY (one convention only):
     level-fn:  (spec-id) → small integer level (0-10ish). User-facing
                logarithmic API. Exponentiated via make-weight-fn at
                the boundary to produce the actual weight multiplier.
                THIS IS THE PRIMARY HARMONY API.
     weight-fn: (spec-id) → already-computed weight (higher = more
                important). Advanced API; bypasses exponentiation.
                Use this if you want a custom scaling. If both LEVEL-FN
                and WEIGHT-FN are given, level-fn wins.

   PLANNING:
     leaf-planner: (scope-id ctx cfg) → lazy stream of federation-result.
                   Plug in alternative leaf strategies (e.g.
                   ddmrp-leaf-planner) without changing the substrate.
                   Defaults to the built-in single-pass relational planner.
     max-steps:    Search step bound for parent-stream interleaving.

   These keyword args are bundled into a federation-config and threaded
   through the substrate as a single value. Adding a new option means
   adding a field to <federation-config>; no other signatures change."
  (project (facts scope-ids parent-map ctx-map)
    (let* ((cfg (make-federation-config #:level-fn     level-fn
                                        #:weight-fn    weight-fn
                                        #:leaf-planner leaf-planner
                                        #:max-steps    max-steps
                                        #:plan-actor?  plan-actor?))
           (children-of (build-hierarchy facts scope-ids parent-map))
           (root (or (find (lambda (id) (not (assoc-ref parent-map id))) scope-ids)
                     (and (pair? scope-ids) (car scope-ids))))
           (root-stream (if root
                            (scope-stream facts root ctx-map children-of cfg)
                            '()))
           (best (stream-take-best root-stream)))
      (== result (if best best
                     `((scope . ,(or root "none")) (plan . ()) (residual . 0)))))))
