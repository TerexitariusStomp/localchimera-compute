;;; plan-for-scope.scm — Scope-level planning wrapper
;;;
;;; Translated from src/lib/planning/plan-for-scope.ts
;;; Thin wrapper over plan-for-unit with scope-specific policies.

;; Assumes plan-for-unit.scm and all dependencies are loaded.

(use-modules (srfi srfi-1))


;; ═════════════════════════════════════════════════════════════════════════
;; Scope spatial model
;; ═════════════════════════════════════════════════════════════════════════

(define (normalize-scopes scope-ids parent-of)
  "Deduplicate scope IDs and remove dominated scopes (children whose
   parents are also in the set)."
  (let ((id-set (delete-duplicates scope-ids)))
    (filter (lambda (id)
              (let ((parent (and parent-of (hashmap-ref parent-of id #f))))
                (or (not parent) (not (member parent id-set)))))
            id-set)))


;; ═════════════════════════════════════════════════════════════════════════
;; plan-for-scope — main entry point
;; ═════════════════════════════════════════════════════════════════════════

(define* (plan-for-scope scope-ids horizon
                         recipe-store plan-store observer
                         #:key (agents #f) (parent-of #f))
  "Plan for a set of scopes. Normalizes scope IDs, then delegates to
   plan-for-unit with scope-specific normalization."
  (plan-for-unit scope-ids horizon
                 recipe-store plan-store observer
                 #:agents agents
                 #:normalize-fn (lambda (ids) (normalize-scopes ids parent-of))
                 #:plan-name "Scope Plan"))
