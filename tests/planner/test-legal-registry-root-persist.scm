;;; test-legal-registry-root-persist.scm — the scope's law persists WITH the root.
;;;
;;; `^legal-registry` is a slot on `^scope-root` (version 4) beside the ballot
;;; store and demand registry. A rule registered at runtime — a production-
;;; governance act — is in the root's portrait, so a cold restart of the vat
;;; brings the law back: the same label, the same possibility-tension at the
;;; solve door, with no packs folder involved.
;;;
;;; Run: guile -L module tests/planner/test-legal-registry-root-persist.scm

(use-modules (playnet test scope))
(use-modules (playnet test harness) (playnet planner scope root) (playnet planner vf schemas) (playnet planner legal compliance)
             (playnet planner legal registry) (playnet planner legal registry-actor)
             (playnet planner knowledge recipes compliance-food)
             (goblins) (goblins vat) (goblins persistence-store memory)
             (srfi srfi-1) (ice-9 format) (ice-9 receive))

(define operator-rule
  (rule (all-of (on-crossing 'food-vending) (agent-has 'classified-as "food-business"))
        (list (forbid #:reason "operator is a Lebensmittelunternehmer"))
        #:label "lmu/operator" #:confidence 'verified #:steward "scope:test"))
(define (prune? root)
  (let ((dec (scope-legal-decorate root)))
    (and dec (call-with-values (lambda () (dec "rp-cf-vend" "foodville@0")) (lambda (p c s . _) p)))))

(define store (make-memory-store))

;; run 1: a lawless root; register the operator rule at runtime
(receive (vat root)
    (spawn-persistent-vat scope-root-env
      (lambda () (spawn-scope-root "Law Scope" #:law-packs #f))
      store #:name "law-root" #:version 1)
  (with-vat vat
    (let ((rs ($ root 'recipe-store)) (obs ($ root 'observer))
          (as ($ root 'agent-store))  (sts ($ root 'spatial-thing-store)))
      (seed-compliance-food-recipe rs)
      ($ sts 'add-location (make-spatial-thing #:id "foodville" #:lat 40.0 #:long -74.0))
      ($ obs 'seed-resource (er "pr" "spec-cf-produce" "agent:kantine" #:place "foodville" #:qty 100.0 #:custodian "agent:kantine"))
      ($ as 'add-agent (make-agent #:id "agent:kantine" #:type 'organization #:name "Kantine"
                                   #:primary-location "foodville" #:classified-as '("food-business")))
      (check-pred "a fresh root under no packs has no law (decorate is #f)"
                  (not (scope-legal-decorate root)))
      (check "register! on the root's own registry" ($ ($ root 'legal-registry) 'register! operator-rule) 'ok)
      (check-pred "…and the vend column is pruned in this run" (prune? root)))))

;; run 2: a cold restore from the same store — no spawn thunk runs
(receive (vat2 root2)
    (spawn-persistent-vat scope-root-env
      (lambda () (error "should not be called on restore"))
      store #:name "law-root" #:version 1)
  (with-vat vat2
    (check "the registered law survives the restart"
           ($ ($ root2 'legal-registry) 'labels) '("lmu/operator"))
    (check-pred "…and still prunes the vend column at the solve door" (prune? root2))
    (check "repeal after restore is the same governance act"
           ($ ($ root2 'legal-registry) 'repeal "lmu/operator") 'ok)
    (check-pred "…after which the root is lawless again" (not (scope-legal-decorate root2)))))

(test-summary!)
