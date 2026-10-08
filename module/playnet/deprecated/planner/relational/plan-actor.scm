;;; plan-actor.scm — Plan-as-actor: lazy traversal across scope boundaries
;;;
;;; A plan-actor wraps a reified plan and exposes its derivatives as
;;; methods. Consumers that only need scalars (coherence, harmony,
;;; residual) or scope-attributed lists (deficits, surpluses) never
;;; touch the plan structure itself. Consumers that need the plan
;;; walk it via demand-pairs + subplan-of, which can preserve remote
;;; semantics: cross-vat consumers pull sub-trees on demand rather
;;; than receiving the whole nested structure up-front.
;;;
;;; Single-vat callers use $ (synchronous) and pay no overhead over
;;; the current inline-plan path. Cross-vat callers use <- and get
;;; a vow; the same API works for both.
;;;
;;; Why: the eager-reification path materializes deep recipe chains
;;; × multiple alternatives × N scopes, most of which the parent
;;; federation never traverses (evaluate-state only reads deficits,
;;; surpluses, coherence, harmony). Plan-as-actor makes "most consumers
;;; never walk the plan" a load-bearing property.
;;;
;;; This file is include-from-path'd into the (playnet planner) umbrella,
;;; so it shares the umbrella's imports (goblins, methods, srfi-*).

;;; ── ^plan-actor ────────────────────────────────────────────────────────────
;;;
;;; Wraps a reified plan + scope-id + optional weight-fn. Coherence is
;;; computed eagerly (leaf ranking needs it regardless); everything
;;; else is delayed and memoized via promises.
;;;
;;; Methods:
;;;   (scope)                  → scope-id
;;;   (full)                   → the inline reified plan (escape hatch)
;;;   (demand-pairs)           → top-level list of demand-pairs
;;;   (coherence)              → scalar
;;;   (harmony)                → alist or #f (if no weight-fn)
;;;   (deficits)               → list of deficit-records
;;;   (surpluses)              → list of surplus-records
;;;   (retraction-candidates)  → list (lazily extracted)
;;;   (residual)               → scalar
;;;   (subplan-of term)        → fresh ^plan-actor ref for a produce
;;;                              term's sub-plan, or #f for other kinds

(define-module (playnet deprecated planner relational plan-actor)
  #:use-module (goblins)
  #:use-module (playnet deprecated planner algorithms flow-graph)
  #:use-module (srfi srfi-1)
  #:use-module (goblins actor-lib methods)
  #:use-module (playnet deprecated planner relational plan-walk)
  #:use-module (goblins actor-lib facet)
  #:use-module (playnet deprecated planner relational harmony)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:export (^plan-actor *plan-methods-summary* *plan-methods-readable*
            spawn-plan-facet relational-plan->plan-actor-result
            federation-result-plan-ref federation-result-plan))

(define (^plan-actor bcom plan scope-id weight-fn)
  (let* ((coh   (plan-coherence plan))
         (harm  (and weight-fn (plan-harmony plan #:priority-fn weight-fn)))
         (defs  (delay (extract-deficits plan scope-id)))
         (surps (delay (extract-surpluses plan scope-id)))
         (cands (delay (extract-retraction-candidates plan scope-id)))
         (resid (delay
                  (fold (lambda (d a) (+ a (or (assq-ref d 'qty) 0)))
                        0 (force defs)))))
    (methods
     ((scope)                 scope-id)
     ((full)                  plan)
     ((demand-pairs)          plan)
     ((coherence)             coh)
     ((harmony)               harm)
     ((deficits)              (force defs))
     ((surpluses)             (force surps))
     ((retraction-candidates) (force cands))
     ((residual)              (force resid))
     ((subplan-of term)
      ;; Destructure a (produce spec rid scale sub-plans [at-location])
      ;; term; anything else → #f. `match` reads the shape declaratively;
      ;; `spawn-named` threads a derived label so nested traversal
      ;; leaves a breadcrumb (`commune-A/subplan:pie`).
      (match term
        (('produce spec _rid _scale sub-plans . _)
         (spawn-named (and scope-id
                           (format #f "~a/subplan:~a" scope-id spec))
                      ^plan-actor sub-plans scope-id weight-fn))
        (_ #f))))))


;;; ── Constructor for federation-result in plan-ref mode ────────────────────
;;;
;;; Produces the alist shape that the coherence-ranking and federation-
;;; substrate code expects, with one key change: the 'plan' field is
;;; replaced by 'plan-ref' carrying an actor ref. Parents and the
;;; user-facing caller access plan structure through $ / <- on the ref.
;;;
;;; Scalars and list-shaped derivatives (deficits/surpluses/coherence/
;;; harmony/residual) are INLINE because they're small and always-walked
;;; by the parent (lateral matching, harmony aggregation). Keeping them
;;; inline saves a round-trip per access.

;;; ── Facets (capability attenuation) ──────────────────────────────────────
;;;
;;; Ocap principle: when you hand a plan-ref across a trust boundary,
;;; give the holder only the observations they're authorized to make.
;;; Three named presets cover most needs; the generic helper accepts
;;; any method list.
;;;
;;;   *plan-methods-summary*   — scalars/lists usable by a federation
;;;                              coordinator for aggregation. No access
;;;                              to plan structure. The default.
;;;   *plan-methods-readable*  — summary + demand-pairs + subplan-of +
;;;                              full. Consumer can fully inspect the
;;;                              plan but cannot mutate.
;;;
;;; Mutation methods don't exist on ^plan-actor today, so "read-only"
;;; is already the underlying property; these facets document intent
;;; and provide room to grow (e.g. adding mutate methods later that
;;; would be denied by default).

(define *plan-methods-summary*
  '(scope coherence harmony deficits surpluses residual retraction-candidates))

(define *plan-methods-readable*
  '(scope coherence harmony deficits surpluses residual retraction-candidates
    plan full demand-pairs subplan-of))

(define* (spawn-plan-facet plan-ref
                           #:optional (methods *plan-methods-summary*))
  "Create an attenuated view of PLAN-REF exposing only METHODS.
   Default exposes the summary set (no plan-structure access).
   Useful before handing a plan-ref to a federation coordinator or
   external peer. The facet forwards sync-or-async appropriately;
   it's transparent to the holder except for the restricted surface."
  (apply facet plan-ref methods))


(define (relational-plan->plan-actor-result plan scope-id weight-fn)
  "Ref-mode variant of relational-plan->federation-result. Wraps PLAN
   in a ^plan-actor, emits a federation-result carrying the ref plus
   inline scalars/lists. Retraction-candidates stays a promise (same
   laziness as the inline path — forced only when retraction fires)."
  (let ((plan-actor (spawn-named (scope->debug-name scope-id)
                                  ^plan-actor plan scope-id weight-fn)))
    (let ((coh  ($ plan-actor 'coherence))
          (harm ($ plan-actor 'harmony))
          (defs ($ plan-actor 'deficits))
          (surps ($ plan-actor 'surpluses))
          (resid ($ plan-actor 'residual)))
      (let ((base `((scope . ,scope-id)
                    (plan-ref . ,plan-actor)
                    (deficits . ,defs)
                    (surpluses . ,surps)
                    (retraction-candidates
                     . ,(delay ($ plan-actor 'retraction-candidates)))
                    (residual . ,resid)
                    (coherence . ,coh))))
        (if harm
            (cons `(harmony . ,harm) base)
            base)))))


;;; ── Federation-result accessors that handle both modes ───────────────────
;;;
;;; Old-mode federation-results have a (plan . <inline list>) pair.
;;; New-mode results have a (plan-ref . <actor ref>) pair. These
;;; accessors give consumers a single API regardless of mode.

(define (federation-result-plan-ref result)
  "Return the plan-ref actor if RESULT is a ref-mode federation-result,
   else #f."
  (assq-ref result 'plan-ref))

(define (federation-result-plan result)
  "Return an inline plan structure from RESULT, whether it's inline
   mode (reads 'plan) or ref mode (synchronously forces via $ from
   'plan-ref). Cross-vat callers should prefer the ref-aware traversal
   methods (subplan-of, demand-pairs via <-) rather than forcing the
   whole plan through this accessor."
  (or (assq-ref result 'plan)
      (let ((ref (assq-ref result 'plan-ref)))
        (and ref ($ ref 'full)))))
