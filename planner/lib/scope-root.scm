;;; scope-root.scm — Goblins actor that wires all VF stores into a single scope
;;;
;;; A scope (organization, commune, or ecological agent) is a single Goblins vat
;;; containing all store actors. The ^scope-root holds references to each store
;;; and provides a unified facade for the scope's operations.
;;;
;;; All stores are near (same vat), so operations within a scope are synchronous
;;; and transactional (single turn = all-or-nothing).

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap))

;; Assumes all store modules and schemas.scm are loaded.


;; =========================================================================
;; ^scope-root — persistent actor holding references to all stores
;; =========================================================================

(define-actor (^scope-root bcom name
                           recipe-store-ref agent-store-ref observer-ref
                           plan-store-ref buffer-zone-store-ref
                           account-store-ref capacity-buffer-store-ref
                           spatial-thing-store-ref snapshot-store-ref
                           alert-store-ref process-registry-ref)
  ;; All *-ref arguments are near actor references (same vat).
  ;; Goblins persistence serializes actor references natively.

  (methods

    ;; --- Identity ---
    ((name) name)

    ;; --- Store accessors (return the actor reference) ---
    ((recipe-store)         recipe-store-ref)
    ((agent-store)          agent-store-ref)
    ((observer)             observer-ref)
    ((plan-store)           plan-store-ref)
    ((buffer-zone-store)    buffer-zone-store-ref)
    ((account-store)        account-store-ref)
    ((capacity-buffer-store) capacity-buffer-store-ref)
    ((spatial-thing-store)  spatial-thing-store-ref)
    ((snapshot-store)       snapshot-store-ref)
    ((alert-store)          alert-store-ref)
    ((process-registry)     process-registry-ref)))


;; =========================================================================
;; spawn-scope — convenience constructor for a complete scope vat
;; =========================================================================

(define (spawn-scope scope-name)
  "Spawn a complete scope with all store actors. Call within a vat context.
   Returns the ^scope-root actor reference."
  (let ((rs  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap)
                     (hashmap) (hashmap) (hashmap)
                     (hashmap) (hashmap) (hashmap)))
        (as  (spawn ^agent-store (hashmap) (hashmap) (hashmap)))
        (obs (spawn ^observer (empty-observer-state)))
        (ps  (spawn ^plan-store (empty-plan-store-state)))
        (bzs (spawn ^buffer-zone-store (hashmap)))
        (acs (spawn ^account-store (hashmap) (hashmap)))
        (cbs (spawn ^capacity-buffer-store (hashmap)))
        (sts (spawn ^spatial-thing-store (hashmap)))
        (sns (spawn ^snapshot-store '()))
        (als (spawn ^alert-store '()))
        (preg (spawn ^process-registry (hashmap))))
    (spawn ^scope-root scope-name rs as obs ps bzs acs cbs sts sns als preg)))


;; =========================================================================
;; Persistence environment (composed from all store envs)
;; =========================================================================

(define scope-env
  (make-persistence-env
    `((((vf) ^scope-root) ,^scope-root))
    #:extends (list recipe-store-env
                    agent-store-env
                    observer-env
                    plan-store-env
                    buffer-zone-store-env
                    account-store-env
                    capacity-buffer-store-env
                    spatial-thing-store-env
                    snapshot-store-env
                    alert-store-env
                    process-registry-env)))
