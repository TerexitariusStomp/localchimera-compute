;;; plan-walk.scm — Canonical plan tree walker
;;;
;;; Plans produced by the relational planner are nested lists with an
;;; implicit algebraic structure:
;;;
;;;   Plan := List of DemandPair
;;;   DemandPair := (demand-alist plan-term)
;;;   PlanTerm := (satisfied spec-id qty allocated [at-location])
;;;             | (unmet spec-id qty [at-location])
;;;             | (produce spec-id rid scale sub-plans)
;;;
;;; This file provides predicates, accessors, and walkers so consumers
;;; don't need to re-implement the pattern-matching. Several existing
;;; functions (count-plan-terms, extract-deficits, extract-surpluses,
;;; extract-demand-outcomes) are variations of "walk this tree and
;;; classify nodes"; they should all use these helpers.

(define-module (playnet deprecated planner relational plan-walk)
  #:use-module (playnet deprecated kanren-constraints)
  #:use-module (ice-9 format)
  #:export (plan-term? satisfied-term? unmet-term? produce-term? transport-term?
            demand-pair? plan-term-kind plan-term-spec plan-term-qty
            plan-term-subplans plan-term-alloc allocation-total reify-from-state
            reify-s demand-pair-demand demand-pair-term demand-pair-spec
            demand-pair-goal fold-demand-pairs fold-plan-terms plan-internal-qty
            plan-external-qty plan-coherence-counts *default-leaf-result-count*
            force-or-self force-cands scope->debug-name inexact-unless-int
            plan-coherence extract-deficits extract-surpluses
            extract-retraction-candidates))

(use-modules (srfi srfi-1))


;;; ── Predicates ─────────────────────────────────────────────────────────────

(define (plan-term? x)
  "#t if X is a plan term (satisfied | unmet | produce | transport)."
  (and (pair? x)
       (memq (car x) '(satisfied unmet produce transport))
       #t))

(define (satisfied-term? x)
  (and (pair? x) (eq? (car x) 'satisfied)))

(define (unmet-term? x)
  (and (pair? x) (eq? (car x) 'unmet)))

(define (produce-term? x)
  (and (pair? x) (eq? (car x) 'produce)))

(define (transport-term? x)
  (and (pair? x) (eq? (car x) 'transport)))

(define (demand-pair? x)
  "#t if X is a (demand-alist plan-term) pair from all-demands-o.
   The first element is treated as opaque metadata (production code
   uses an alist with spec-id/quantity, but tests use simpler stubs).
   We only require that the second element is a plan term."
  (and (pair? x)
       (pair? (cdr x))
       (plan-term? (cadr x))))


;;; ── Plan term accessors ────────────────────────────────────────────────────

(define (plan-term-kind term)
  "Return 'satisfied | 'unmet | 'produce | #f."
  (and (plan-term? term) (car term)))

(define (plan-term-spec term)
  "Spec-id from any plan term. #f if TERM is not a plan term."
  (and (plan-term? term) (cadr term)))

(define (plan-term-qty term)
  "For satisfied: the fulfilled qty.
   For unmet: the remaining (unfulfilled) qty.
   For produce: the scale. #f otherwise."
  (cond
    ((satisfied-term? term) (caddr term))
    ((unmet-term? term) (caddr term))
    ((produce-term? term)
     (and (pair? (cdddr term)) (list-ref term 3)))
    (else #f)))

(define (plan-term-subplans term)
  "For produce terms, return the list of sub-plans. '() otherwise."
  (if (and (produce-term? term) (>= (length term) 5))
      (list-ref term 4)
      '()))

(define (plan-term-alloc term)
  "For satisfied terms, return the allocation list — a list of
   (resource-id qty) pairs showing where the demand was sourced.
   '() for non-satisfied or malformed terms."
  (if (and (satisfied-term? term) (>= (length term) 4))
      (list-ref term 3)
      '()))

(define (allocation-total alloc)
  "Sum the qty of an allocation list (list of (rid qty) pairs)."
  (if (list? alloc)
      (fold (lambda (a acc) (+ acc (cadr a))) 0 alloc)
      0))


;;; ── Reification: cstate → ground plan ──────────────────────────────────────
;;; A miniKanren cstate carries a substitution that maps logic variables
;;; to their bindings. To get a ground plan structure for traversal, we
;;; walk the substitution and replace any unground variables with
;;; placeholder symbols (_._.0, _._.1, etc.).

(define (reify-from-state state)
  "Reify a plan from a miniKanren cstate. The first logic variable
   (var 0) is the conventional plan-result slot — walk the substitution
   to ground it, then walk again with the placeholder substitution to
   resolve any remaining unground vars."
  (let* ((S (cstate-S state))
         (v (walk* (var 0) S))
         (R (reify-s v '())))
    (walk* v R)))

(define (reify-s v subst)
  "Build a substitution that maps unground vars to placeholder symbols.
   Used by reify-from-state."
  (let ((v (walk v subst)))
    (cond
     ((var? v) (cons (cons v (string->symbol
                    (string-append "_." (number->string (length subst))))) subst))
     ((pair? v) (reify-s (cdr v) (reify-s (car v) subst)))
     (else subst))))


;;; ── Demand-pair accessors ──────────────────────────────────────────────────

(define (demand-pair-demand pair) (car pair))
(define (demand-pair-term pair)   (cadr pair))

(define (demand-pair-spec pair)
  (or (assq-ref (demand-pair-demand pair) 'spec-id)
      (plan-term-spec (demand-pair-term pair))))

(define (demand-pair-goal pair)
  "Target quantity from the demand alist. This is the harmony 'goal'."
  (assq-ref (demand-pair-demand pair) 'quantity))


;;; ── Walkers / folds ────────────────────────────────────────────────────────

(define (fold-demand-pairs proc init plan)
  "Fold PROC over each top-level demand pair in PLAN.
   PROC signature: (demand-alist plan-term acc) → new-acc.
   Does NOT recurse into produce sub-plans (independent demands only)."
  (cond
    ((null? plan) init)
    ((not (pair? plan)) init)
    ((demand-pair? (car plan))
     (fold-demand-pairs proc
                        (proc (demand-pair-demand (car plan))
                              (demand-pair-term (car plan))
                              init)
                        (cdr plan)))
    (else
     ;; Unexpected shape — skip this element, keep scanning
     (fold-demand-pairs proc init (cdr plan)))))

(define (fold-plan-terms proc init plan)
  "Fold PROC over every plan term in the tree, recursing into produce
   sub-plans. PROC signature: (term acc) → new-acc.
   Handles the full tree including nested productions."
  (let loop ((tree plan) (acc init))
    (cond
      ((null? tree) acc)
      ((not (pair? tree)) acc)
      ((plan-term? tree)
       (let ((acc* (proc tree acc)))
         (if (produce-term? tree)
             (loop (plan-term-subplans tree) acc*)
             acc*)))
      ;; Demand pair: unwrap to the term
      ((demand-pair? tree)
       (loop (demand-pair-term tree) acc))
      ;; Generic list: recurse into each element
      (else
       (loop (cdr tree) (loop (car tree) acc))))))


;;; ── Plan coherence ─────────────────────────────────────────────────────────
;;;
;;; Coherence is a per-scope ranking metric: how much of a plan is
;;; sourced INTERNALLY (from this scope's inventory or production)
;;; vs EXTERNALLY (from other locations or marked unmet for the
;;; federation to handle).
;;;
;;;   internal: satisfied (from local inventory) + produce (made here)
;;;   external: transport (from elsewhere) + unmet (deferred)
;;;
;;;   coherence(plan) = sum(internal-qty) / sum(total-demand-qty)
;;;
;;; A plan with coherence=1 is fully self-sufficient at this scope.
;;; A plan with coherence=0 has every demand sourced externally.
;;;
;;; This is the natural ranking metric for relational planners that
;;; can never "fail" — the unmet branch is always available, so the
;;; search always succeeds. Without explicit ranking, "best plan" is
;;; an artifact of conde branch order. Coherence makes it principled.
;;;
;;; Note: this is plan-level coherence (forward-looking, computed from
;;; a plan structure). It is distinct from the historical-flow
;;; coherence in algorithms/flow-graph.scm:72 (which computes internal-
;;; vs-external ratios from event facts after the fact). Both concepts
;;; measure "self-sufficiency" but at different layers.

(define (plan-internal-qty term)
  "Quantity that the plan TERM sources internally.
   For satisfied: the qty that was allocated.
   For produce: the qty produced (sub-plan handles the consumption).
   For transport/unmet: 0 (sourced externally)."
  (cond
    ((satisfied-term? term)
     (or (plan-term-qty term) 0))
    ((produce-term? term)
     ;; The produce term itself represents internal sourcing
     ;; (we made it here), even if its sub-inputs are mixed.
     ;; The sub-inputs are walked separately by fold-plan-terms.
     0)  ;; Counted via the satisfied/produce sub-terms instead
    (else 0)))

(define (plan-external-qty term)
  "Quantity that the plan TERM sources externally.
   For unmet/transport: the qty.
   For satisfied/produce: 0 (sourced internally)."
  (cond
    ((unmet-term? term)
     (or (plan-term-qty term) 0))
    ((transport-term? term)
     ;; Transport allocations are quantity-bearing; the actual qty
     ;; is in the allocation list (5th element if present).
     (let ((alloc (and (>= (length term) 3) (caddr term))))
       (if (list? alloc) (allocation-total alloc) 0)))
    (else 0)))

(define (plan-coherence-counts plan)
  "Walk PLAN and return (internal-qty . external-qty) totals.
   Used by plan-coherence and for debugging/diagnostics."
  (let ((int 0) (ext 0))
    (fold-plan-terms
      (lambda (term _acc)
        (set! int (+ int (plan-internal-qty term)))
        (set! ext (+ ext (plan-external-qty term)))
        #f)
      #f plan)
    (cons int ext)))

;; Default number of plan alternatives to enumerate before sorting by
;; coherence. The relational solver always succeeds (the unmet branch
;; is unconditional), so a 1-result run is biased toward trivial
;; all-unmet plans. Both the federation leaf-planner and the strategy
;; comparison module enumerate this many candidates and pick the most
;; self-sufficient one. Defined here (not in federation.scm) so it
;; loads before strategy.scm in load-relational.scm.
(define *default-leaf-result-count* 5)


;;; ── Laziness bridge: any field may be a promise, a value, or #f ──────────
;;; The generalised pattern: boundary-crossing data structures often
;;; have mixed eagerness — a field might hold a computed value, a
;;; (delay ...) promise, or #f (missing). `force-or-self` normalises
;;; all three into a uniform value, coercing #f to '() for list-shaped
;;; fields. This is the coinductive-bridge helper: consumers observe
;;; the field; the helper handles how it was actually represented.
;;;
;;; Originally added for retraction-candidates (leaf planners wrap in
;;; delay so unused alternatives skip the walk). Same shape applies
;;; to any lazy field added later — no need to reinvent the helper.
;;;
;;; `force-cands` is kept as an alias for back-compat with the L0
;;; code that introduced the pattern. New code should prefer the
;;; general name.

(define (force-or-self x)
  "Normalise a field that may be a promise, a value, or #f.
   Returns: '() if x is #f; (force x) if x is a promise; else x."
  (cond
    ((not x) '())
    ((promise? x) (force x))
    (else x)))

(define force-cands force-or-self)  ; back-compat alias


;;; ── scope->debug-name — symbol/string/any → spawn-named label ───────────
;;;
;;; Shared helper for actor spawns that want `refr-name` to return a
;;; meaningful label derived from their scope identifier. Handles the
;;; common shapes (symbol, string, number, #f) without each caller
;;; reinventing the coercion. Loading order places this in plan-walk
;;; (early) so all later-included actors can use it.

(define (scope->debug-name scope)
  (cond
   ((not scope) #f)
   ((symbol? scope) (symbol->string scope))
   ((string? scope) scope)
   (else (format #f "~a" scope))))


;;; ── inexact-unless-int — Syrup/OCapN wire safety ────────────────────────
;;;
;;; Goblins' Syrup serializer doesn't support exact rationals like 3/4.
;;; Any actor method that might return a rational (coherence ratios,
;;; harmony weights, etc.) across an OCapN boundary must coerce first.
;;; We preserve integers untouched — `(equal? 1 (inexact-unless-int 1))`
;;; stays true — so in-process tests that assert on integer coherences
;;; keep passing. Only non-integer rationals get promoted to inexact.

(define (inexact-unless-int x)
  (if (and (rational? x) (not (integer? x))) (exact->inexact x) x))

(define (plan-coherence plan)
  "Compute plan-level coherence: ratio of internally-sourced demand
   to total demand. Returns a number in [0,1]. Returns 1 for an empty
   plan (vacuously self-sufficient).

   internal:  satisfied terms (allocated from local inventory)
              + sub-allocations inside produce terms
   external:  unmet terms (deferred to federation)
              + transport terms (from another location)

   This is the natural ranking metric when the relational solver can
   always succeed (because unmet is always available as a fallback).
   Sort plans by coherence descending to prefer self-sufficient ones."
  (let* ((counts (plan-coherence-counts plan))
         (int (car counts))
         (ext (cdr counts))
         (total (+ int ext)))
    (if (<= total 0)
        1  ;; vacuous: empty plan or no demand → fully coherent
        (/ int total))))

;;; ── plan extraction: deficits, surpluses, retraction candidates ──────────
;;; These read a plan through the walkers just above and lived in
;;; federation.scm, which made four files depend on federation for what is
;;; plain plan inspection — and federation on plan-actor for one function,
;;; while plan-actor needed these three back. That was the cycle. Every helper
;;; they call is defined in this file, so this is where they belong.

(define (extract-deficits plan scope-id)
  "Extract unmet demands as deficit records.
   Each deficit: ((scope-id . id) (spec-id . s) (qty . q))."
  (reverse
    (fold-demand-pairs
      (lambda (_demand term acc)
        (if (unmet-term? term)
            (cons `((scope-id . ,scope-id)
                    (spec-id  . ,(plan-term-spec term))
                    (qty      . ,(plan-term-qty term)))
                  acc)
            acc))
      '() plan)))

(define (extract-surpluses plan scope-id)
  "Extract over-produced output as surplus records.
   A surplus exists when allocated > needed for a satisfied term.
   Each surplus: ((scope-id . id) (spec-id . s) (qty . q))."
  (reverse
    (fold-demand-pairs
      (lambda (_demand term acc)
        (if (satisfied-term? term)
            (let ((surplus (- (allocation-total (plan-term-alloc term))
                              (plan-term-qty term))))
              (if (> surplus 0)
                  (cons `((scope-id . ,scope-id)
                          (spec-id  . ,(plan-term-spec term))
                          (qty      . ,surplus))
                        acc)
                  acc))
            acc))
      '() plan)))

(define (extract-retraction-candidates plan scope-id)
  "Extract satisfied demands as retraction candidates from a relational plan.
   Each candidate: ((scope-id . id) (spec-id . s) (qty . q))."
  (reverse
    (fold-demand-pairs
      (lambda (_demand term acc)
        (if (and (satisfied-term? term) (> (plan-term-qty term) 0))
            (cons `((scope-id . ,scope-id)
                    (spec-id  . ,(plan-term-spec term))
                    (qty      . ,(plan-term-qty term)))
                  acc)
            acc))
      '() plan)))
