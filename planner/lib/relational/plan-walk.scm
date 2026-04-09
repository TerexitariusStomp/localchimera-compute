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

(use-modules (srfi srfi-1))


;;; ── Predicates ─────────────────────────────────────────────────────────────

(define (plan-term? x)
  "#t if X is a plan term (satisfied | unmet | produce)."
  (and (pair? x)
       (memq (car x) '(satisfied unmet produce))
       #t))

(define (satisfied-term? x)
  (and (pair? x) (eq? (car x) 'satisfied)))

(define (unmet-term? x)
  (and (pair? x) (eq? (car x) 'unmet)))

(define (produce-term? x)
  (and (pair? x) (eq? (car x) 'produce)))

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
