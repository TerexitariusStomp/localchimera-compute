;;; federation-a/leaf.scm — ^planning-leaf actor
;;;
;;; Co-locates with a ^scope-root (same vat). On each (plan-for cfg)
;;; request it builds a <plan-ctx> locally from the scope-root's stores,
;;; runs the relational planner via `relational-plan`, and emits K
;;; ranked ref-mode federation-result alists that are safe to cross
;;; vats (the plans themselves stay behind plan-actor refs).
;;;
;;; Nearly all logic is reuse of existing helpers from the planner
;;; umbrella: `relational-plan` (plan-relation.scm:121), `plan-coherence`
;;; (plan-walk.scm), `by-harmony-priority` (plan-relation.scm:53),
;;; `relational-plan->plan-actor-result` (plan-actor.scm:124),
;;; `spawn-plan-facet` (plan-actor.scm:114).
;;;
;;; Included fragment — imports come from (playnet deprecated federation-a).

(define-module (playnet deprecated federation-a leaf)
  #:use-module (playnet deprecated planner)
  #:use-module (playnet deprecated federation-a config)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (plan-for-leaf attenuate-plan-ref-in-result ^planning-leaf
            spawn-planning-leaf))

(define (plan-for-leaf scope-root scope-id cfg)
  "Core of ^planning-leaf's plan-for method — pulled out as a plain
   procedure so tests and direct callers can exercise it without
   spawning an actor."
  (let* ((rs    ($ scope-root 'recipe-store))
         (ps    ($ scope-root 'plan-store))
         (obs   ($ scope-root 'observer))
         (wfn   (federation-a-config-weight-fn cfg))
         (k     (federation-a-config-max-leaf-results cfg))
         (order (and wfn (by-harmony-priority wfn)))
         (raw   (relational-plan k rs ps obs
                                 #:max-depth 5
                                 #:demand-order order))
         (sorted (sort raw
                       (lambda (a b) (> (plan-coherence a) (plan-coherence b)))))
         (results (map (lambda (p)
                         (relational-plan->plan-actor-result p scope-id wfn))
                       sorted)))
    (if (federation-a-config-attenuate? cfg)
        (map attenuate-plan-ref-in-result results)
        results)))


(define (attenuate-plan-ref-in-result result)
  "Replace the 'plan-ref' entry with a summary-only facet. Leaves the
   rest of the alist intact."
  (let ((pr (assq-ref result 'plan-ref)))
    (if pr
        (map (lambda (entry)
               (if (eq? (car entry) 'plan-ref)
                   (cons 'plan-ref (spawn-plan-facet pr))
                   entry))
             result)
        result)))


(define (^planning-leaf bcom scope-root scope-id)
  "Actor wrapping a ^scope-root; on (plan-for cfg) runs the relational
   planner against that scope-root's stores and returns K ranked
   ref-mode federation-results."
  (methods
    ((describe)     scope-id)
    ((planner-kind) 'planning)
    ((scope-root)   scope-root)
    ((plan-for cfg) (plan-for-leaf scope-root scope-id cfg))))


(define (spawn-planning-leaf scope-root scope-id)
  "Spawn a ^planning-leaf bound to SCOPE-ROOT (near ref in the same
   vat). SCOPE-ID is the identifier propagated through federation-result
   alists; it does not need to match the scope-root's internal name."
  (spawn ^planning-leaf scope-root scope-id))
