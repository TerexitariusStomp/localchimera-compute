;;; strategy.scm — Strategy synthesis: relate planning strategies to outcomes
;;;
;;; The planner plans production. This module lets the planner plan
;;; its own planning — relating situations to strategies to outcomes.
;;;
;;; Follows the control.scm pattern: wraps existing systems as explicit
;;; relational structure, making strategy decisions queryable and
;;; composable via the relational combinator library.
;;;
;;; Key relations:
;;;   demand-class-o      — relational spec classification (bidirectional)
;;;   situation-o         — extract planning situation from facts
;;;   strategy-o          — relate named strategies to their components
;;;   strategy-outcome-o  — run planner with strategy, relate to outcome
;;;   plan-quality-o      — classify plan quality from plan terms

(define-module (playnet deprecated planner relational strategy)
  #:use-module (playnet deprecated planner relational plan-walk)
  #:use-module (playnet deprecated planner relational plan-relation)
  #:use-module (playnet deprecated planner relational instrumentation)
  #:use-module (srfi srfi-11)
  #:export (demand-class-o situation-o strategy-o plan-quality-o strategy-outcome-o
            best-strategy-o))

(use-modules (playnet deprecated kanren-constraints)
             (srfi srfi-1))


;;; ── demand-class-o (bidirectional) ──────────────────────────────────────────
;;; Replaces the ground demand-class in plan-relation.scm.
;;; "What class is bread?" AND "What specs are class 0?"

(define (demand-class-o facts spec-id class)
  "Relational demand classification — truly bidirectional.
   Forward (ground spec-id): returns the unique class for this spec.
   Inverse (ground class): enumerates specs in that class.
   0 = has positive inventory, 2 = has recipe, 3 = external.

   Implementation: the relation is reified as a concrete list of
   (spec-id . class) pairs at solve time, then turned into a conde
   over those pairs. Works regardless of which argument is ground
   because it treats both as ordinary logic variables once the
   enumeration is built."
  (project (facts)
    (let* ((has-inv (lambda (sid)
                      (any (lambda (f)
                             (and (eq? (car f) 'inventory)
                                  (equal? (caddr f) sid)
                                  (> (cadddr f) 0)))
                           facts)))
           (has-rec (lambda (sid)
                      (any (lambda (f)
                             (and (eq? (car f) 'recipe)
                                  (equal? (cadddr f) sid)))
                           facts)))
           ;; Collect every spec-id referenced anywhere in the facts
           ;; so the inverse query can enumerate candidates.
           (known-specs
             (delete-duplicates
               (append
                 (filter-map (lambda (f)
                               (and (eq? (car f) 'inventory) (caddr f)))
                             facts)
                 (filter-map (lambda (f)
                               (and (eq? (car f) 'recipe) (cadddr f)))
                             facts)
                 (filter-map (lambda (f)
                               (and (eq? (car f) 'flow) (list-ref f 3)))
                             facts))))
           (classify (lambda (sid)
                       (cond ((has-inv sid) 0)
                             ((has-rec sid) 2)
                             (else          3))))
           (pairs (map (lambda (sid) (cons sid (classify sid))) known-specs)))
      ;; Build a conde over the reified pairs. This works in both
      ;; directions because == can unify either side.
      (let loop ((ps pairs))
        (cond
          ((null? ps) fail)
          ((null? (cdr ps))
           (fresh ()
             (== spec-id (caar ps))
             (== class   (cdar ps))))
          (else
           (conde
             ((fresh ()
                (== spec-id (caar ps))
                (== class   (cdar ps))))
             ((loop (cdr ps))))))))))


;;; ── situation-o (forward: facts must be ground) ─────────────────────────────
;;; Extract a planning situation descriptor from lifted facts.

(define (situation-o facts situation)
  "Relate facts to a planning situation: inventory/recipe coverage counts.
   Forward only — facts must be ground."
  (project (facts)
    (let* ((inv-specs (delete-duplicates
                        (filter-map (lambda (f)
                          (and (eq? (car f) 'inventory)
                               (> (cadddr f) 0)
                               (caddr f)))
                          facts)))
           (rec-specs (delete-duplicates
                        (filter-map (lambda (f)
                          (and (eq? (car f) 'recipe)
                               (cadddr f)))
                          facts)))
           (inv-count (length inv-specs))
           (rec-count (length rec-specs)))
      (== situation `((inventory-coverage . ,inv-count)
                      (recipe-coverage . ,rec-count)
                      (inventoried-specs . ,inv-specs)
                      (recipe-specs . ,rec-specs))))))


;;; ── strategy-o (bidirectional, pure conde table) ────────────────────────────
;;; Same pattern as signal-action-o in signals.scm.

(define (strategy-o strategy ordering)
  "Relate a named strategy to its demand ordering.
   'What ordering does local-first use?' AND 'What strategies use by-due-date?'"
  (conde
    ((== strategy 'earliest-due)  (== ordering 'by-due-date))
    ((== strategy 'local-first)   (== ordering 'by-local-first))
    ((== strategy 'unordered)     (== ordering #f))))


;;; ── plan-quality-o (forward: plan must be ground) ───────────────────────────

(define (plan-quality-o plan quality)
  "Classify plan quality from plan terms.
   all-satisfied:  coherence = 1 (every demand sourced internally)
   high-coherence: coherence ≥ 0.8
   partial:        coherence ≥ 0.4
   many-unmet:     coherence < 0.4

   Coherence is the principled metric: it measures the internal-vs-
   external sourcing ratio across the whole plan tree, including
   sub-allocations inside produce terms. Sat/unmet term *counts*
   ignore quantities, so a single big unmet would be misclassified."
  (project (plan)
    (let ((coh (plan-coherence plan)))
      (cond
        ((>= coh 1)   (== quality 'all-satisfied))
        ((>= coh 8/10) (== quality 'high-coherence))
        ((>= coh 4/10) (== quality 'partial))
        (else          (== quality 'many-unmet))))))


;;; ── strategy-outcome-o (forward: strategy must be ground) ───────────────────
;;; The key relation. Runs the planner with a strategy and relates to outcome.

(define (strategy-outcome-o ctx strategy outcome)
  "Relate a planning strategy to its outcome.
   Forward: given strategy, what outcome? (strategy must be ground)
   Compose with strategy-o via conde to enumerate all strategies.

   Enumerates *default-leaf-result-count* alternatives and picks the
   one with highest plan-coherence. The relational solver always
   succeeds (unmet branch is unconditional), so the first conde
   solution is biased toward the trivial all-unmet plan. Sorting by
   coherence is what gives this relation meaningful comparative
   power across strategies."
  (fresh (ordering)
    (strategy-o strategy ordering)
    (project (ctx ordering)
      (let* ((facts (ctx-facts ctx))
             (order-fn (case ordering
                         ((by-due-date)    by-due-date)
                         ((by-local-first) (by-local-first facts))
                         (else #f)))
             (raw (run-plan *default-leaf-result-count* #f (plan)
                    (plan-o ctx plan #:max-depth 10
                                     #:demand-order order-fn)))
             (sorted (sort raw
                       (lambda (a b)
                         (> (plan-coherence a) (plan-coherence b)))))
             (plan (if (null? sorted) '() (car sorted)))
             (coherence (if (null? sorted) 1 (plan-coherence plan))))
        (let-values (((sat unm prod resid) (count-plan-terms plan)))
          (fresh (quality)
            (plan-quality-o plan quality)
            (== outcome `((strategy . ,strategy)
                          (ordering . ,ordering)
                          (quality . ,quality)
                          (coherence . ,coherence)
                          (satisfied . ,sat)
                          (unmet . ,unm)
                          (produced . ,prod)
                          (residual . ,resid)
                          (plan . ,plan)))))))))


;;; ── best-strategy-o (composition of the above) ─────────────────────────────

(define (best-strategy-o ctx best-strategy best-outcome)
  "Find the strategy with the highest plan coherence for a given context.
   Enumerates all strategies via strategy-o, runs each, picks best.

   Coherence (descending) is the right ranking — not residual ascending.
   Two strategies can produce plans with identical residual but very
   different internal/external sourcing splits, and coherence captures
   that. Residual-only ranking is also blind to *how much* internal
   sourcing was achieved when residual is non-zero. Tie-breaks fall
   back to lower residual."
  (project (ctx)
    (let* ((all-strategies (run-plan 10 #f (s) (fresh (o) (strategy-o s o))))
           (outcomes (filter-map
                       (lambda (s)
                         (let ((results (run-plan 1 #f (out)
                                          (strategy-outcome-o ctx s out))))
                           (and (pair? results) (car results))))
                       all-strategies))
           (sorted (sort outcomes
                     (lambda (a b)
                       (let ((ca (or (assq-ref a 'coherence) 0))
                             (cb (or (assq-ref b 'coherence) 0)))
                         (cond
                           ((> ca cb) #t)
                           ((< ca cb) #f)
                           (else
                            (< (or (assq-ref a 'residual) 999999)
                               (or (assq-ref b 'residual) 999999))))))))
           (best (if (null? sorted) #f (car sorted))))
      (if best
          (fresh ()
            (== best-strategy (assq-ref best 'strategy))
            (== best-outcome best))
          fail))))
