;;; federation.scm — Hierarchical federation planning as relations
;;;
;;; Multi-scope planning: each scope plans independently, then
;;; lateral matching connects surplus to deficit across peers.
;;; The hierarchy is facts. The fold is relational. The matching
;;; is interleaved search over valid pairings.

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))


;;; ── Hierarchy fact relations ──────────────────────────────────────────────────

(define (scope-parent-o facts child parent)
  "Relate a child scope to its parent scope."
  (in-list-o `(scope-parent ,child ,parent) facts))

(define (peer-scopes-o facts scope-a scope-b)
  "Two scopes are peers if they share a parent."
  (fresh (parent)
    (scope-parent-o facts scope-a parent)
    (scope-parent-o facts scope-b parent)
    (=/= scope-a scope-b)))

(define (ancestor-o facts descendant ancestor)
  "Ancestor relation via transitive closure over scope-parent."
  (transitive-o (lambda (child parent) (scope-parent-o facts child parent))
                descendant ancestor))


;;; ── Scope planning fold ───────────────────────────────────────────────────────
;;; Each scope is planned independently. Results are accumulated.
;;; Children are planned before parents (topological order).

(define (plan-scopes-o scope-ctxs scope-plans)
  "Plan each scope in order. SCOPE-CTXS = list of (scope-id . ctx) pairs.
   SCOPE-PLANS = list of (scope-id . plan-result) pairs."
  (if (null? scope-ctxs)
      (== scope-plans '())
      (let ((entry (car scope-ctxs))
            (scope-id (caar scope-ctxs))
            (ctx (cdar scope-ctxs)))
        (fresh (plan rest-plans)
          (plan-o ctx plan #:max-depth 5)
          (plan-scopes-o (cdr scope-ctxs) rest-plans)
          (== scope-plans (cons (cons scope-id plan) rest-plans))))))


;;; ── Signal collection from plan results ───────────────────────────────────────

(define (collect-signals-o scope-plans kind signals)
  "Collect all signals of KIND from scope plan results."
  (project (scope-plans kind)
    (== signals
         (append-map
           (lambda (sp)
             (let ((scope-id (car sp))
                   (plan (cdr sp)))
               ;; Extract signals from plan terms
               (filter-map
                 (lambda (entry)
                   (let ((plan-term (cadr entry)))
                     (and (pair? plan-term)
                          (eq? (car plan-term) 'purchase)
                          (eq? kind 'deficit)
                          `((scope . ,scope-id)
                            (spec . ,(cadr plan-term))
                            (qty . ,(caddr plan-term))))))
                 (if (list? plan) plan '()))))
           scope-plans))))

(define (collect-surpluses-o scope-plans surpluses)
  "Extract surplus signals from plan results."
  (project (scope-plans)
    (== surpluses
         (append-map
           (lambda (sp)
             (let ((scope-id (car sp))
                   (plan (cdr sp)))
               (filter-map
                 (lambda (entry)
                   (let ((plan-term (cadr entry)))
                     (and (pair? plan-term)
                          (eq? (car plan-term) 'satisfied)
                          ;; Surplus = allocated more than needed
                          ;; (simplified — real surplus comes from plan analysis)
                          #f)))
                 (if (list? plan) plan '()))))
           scope-plans))))


;;; ── Lateral matching ──────────────────────────────────────────────────────────
;;; Match deficits from one scope against surpluses from a peer scope.
;;; Each match is explored as a conde branch — interleaving finds all pairings.

(define (lateral-match-o facts deficits surpluses matches)
  "Match deficit-surplus pairs across peer scopes."
  (if (or (null? deficits) (null? surpluses))
      (== matches '())
      (let ((deficit (car deficits)))
        (fresh (match rest-matches)
          (conde
            ;; Try to match this deficit with a surplus
            ((find-matching-surplus-o facts deficit surpluses match)
             (lateral-match-o facts (cdr deficits) surpluses rest-matches)
             (== matches (cons match rest-matches)))
            ;; No match — skip this deficit
            ((== match #f)
             (lateral-match-o facts (cdr deficits) surpluses rest-matches)
             (== matches rest-matches)))))))

(define (find-matching-surplus-o facts deficit surpluses match)
  "Find a surplus that matches a deficit (same spec, peer scopes)."
  (if (null? surpluses)
      fail
      (let ((surplus (car surpluses)))
        (conde
          ;; This surplus matches
          ((fresh (def-scope def-spec def-qty sur-scope sur-spec sur-qty qty)
             (== def-scope (assq-ref deficit 'scope))
             (== def-spec (assq-ref deficit 'spec))
             (== def-qty (assq-ref deficit 'qty))
             (== sur-scope (assq-ref surplus 'scope))
             (== sur-spec (assq-ref surplus 'spec))
             (== sur-qty (assq-ref surplus 'qty))
             ;; Same spec
             (== def-spec sur-spec)
             ;; Peer scopes (share parent)
             (peer-scopes-o facts def-scope sur-scope)
             ;; Match quantity = min(deficit, surplus)
             (project (def-qty sur-qty)
               (let ((q (min def-qty sur-qty)))
                 (== match `((from . ,sur-scope) (to . ,def-scope)
                             (spec . ,def-spec) (qty . ,q)))))))
          ;; Try next surplus
          ((find-matching-surplus-o facts deficit (cdr surpluses) match))))))


;;; ── Full federation planning ──────────────────────────────────────────────────

(define (plan-federation-o facts scope-ctxs result)
  "Plan all scopes, then match surpluses to deficits laterally."
  (fresh (scope-plans deficits surpluses matches)
    (plan-scopes-o scope-ctxs scope-plans)
    (collect-signals-o scope-plans 'deficit deficits)
    (collect-surpluses-o scope-plans surpluses)
    (lateral-match-o facts deficits surpluses matches)
    (== result `((scope-plans . ,scope-plans)
                 (lateral-matches . ,matches)))))
