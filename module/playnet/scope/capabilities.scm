;;; module/playnet/scope/capabilities.scm — the capability methods of a scope: the four sealers minted and recognised.
;;;
;;; A fragment of the scope actor (playnet scope actor): a procedure from the
;;; actor's context to the doors it serves, composed into every scope by
;;; (playnet boot scope). `with-scope-ctx` binds the actor's fields and helpers
;;; under their own names, so each clause reads as it did inside the actor
;;; (docs/planning/codebase-layout.md §5).

(define-module (playnet scope capabilities)
  #:use-module (goblins)
  #:use-module (playnet scope actor)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:export (scope-capabilities-doors))

(define (scope-capabilities-doors ctx)
  (with-scope-ctx ctx
    (declared-doors scope

    ;; --- Authority issuance ---
    ((mint-gov-cap holder-aid)
     (unless (may-govern? kind scope-aid acdc-store holder-aid members)
       (error "mint-gov-cap: not recognised by this scope" name holder-aid))
     ($ gov-seal holder-aid))

    ((mint-planning-cap holder-aid) ($ planning-seal holder-aid))

    ((mint-delegate-cap holder-aid) ($ delegate-seal holder-aid))

    ((mint-member-cap holder-aid)
     (unless member-seal
       (error "scope has no member-seal (federation kind)" name))
     ($ member-seal holder-aid))

    ((close-authority) gov-sealed?)

    ((gov-cap? cap)      ($ gov-sealed? cap))

    ((planning-cap? cap) ($ planning-sealed? cap))

    ((delegate-cap? cap) ($ delegate-sealed? cap))

    ((member-cap? cap)
     (and member-sealed? ($ member-sealed? cap))))))
