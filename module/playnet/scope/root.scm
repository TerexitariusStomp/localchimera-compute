;;; scope-root.scm — Goblins actor that wires all VF stores into a single scope
;;;
;;; A scope (organization, commune, or ecological agent) is a single Goblins vat
;;; containing all store actors. The ^scope-root holds references to each store
;;; and provides a unified facade for the scope's operations.
;;;
;;; All stores are near (same vat), so operations within a scope are synchronous
;;; and transactional (single turn = all-or-nothing).

(define-module (playnet scope root)
  #:use-module (playnet observation live-resource)
  #:use-module (playnet vf schemas)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (playnet utils store-utils)
  ;; the stores a scope root holds serialize their records by type: every type they
  ;; hold is registered by this module, so whoever holds a scope root has them
  #:use-module ((playnet plan horizon-gate) #:select (make-horizon-gate))
  #:use-module (playnet observation live-registry)
  #:use-module (playnet observation observer)
  #:use-module (playnet observation account)
  #:use-module (playnet scope agents)
  #:use-module (playnet execution alerts)
  #:use-module (playnet ddmrp buffer-zones)
  #:use-module (playnet ddmrp capacity-buffers)
  #:use-module (playnet ddmrp buffer-snapshots)
  #:use-module (playnet scope spatial-things)
  #:use-module (playnet knowledge recipes store)
  #:use-module (playnet plan store)
  #:use-module (playnet scope process-registry)
  #:use-module (playnet legal registry-actor)
  #:use-module ((playnet knowledge law context-pack) #:select (load-legal-registry))
  #:export (^scope-root spawn-scope-root scope-root-env)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet voice ballot-store)
  #:use-module (playnet voice demand-registry))


;; Assumes all store modules and schemas.scm are loaded.


;; =========================================================================
;; ^scope-root — persistent actor holding references to all stores
;; =========================================================================

(define-actor (^scope-root bcom name
                           recipe-store-ref agent-store-ref observer-ref
                           plan-store-ref buffer-zone-store-ref
                           account-store-ref capacity-buffer-store-ref
                           spatial-thing-store-ref snapshot-store-ref
                           alert-store-ref process-registry-ref
                           live-registry-ref ballot-store-ref
                           demand-registry-ref legal-registry-ref)
  ;; All *-ref arguments are near actor references (same vat).
  ;; Goblins persistence serializes actor references natively.
  #:portrait
  (lambda ()
    (list name recipe-store-ref agent-store-ref observer-ref
          plan-store-ref buffer-zone-store-ref
          account-store-ref capacity-buffer-store-ref
          spatial-thing-store-ref snapshot-store-ref
          alert-store-ref process-registry-ref
          live-registry-ref ballot-store-ref
          demand-registry-ref legal-registry-ref))
  ;; 4: the legal registry joins the root (the scope's law persists with its
  ;; other governance registries). A version-3 root restores under an EMPTY
  ;; registry — the law it stood under was the packs folder, which
  ;; spawn-scope-root re-reads at the next fresh spawn; nothing it registered
  ;; at runtime existed to persist before this slot did.
  #:version 4
  #:restore
  (lambda (version . args)
    (case version
      ((4) (apply spawn ^scope-root args))
      ((3) (apply spawn ^scope-root (append args (list (load-legal-registry #f)))))
      (else (error "^scope-root: unknown portrait version" version))))

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
    ((process-registry)     process-registry-ref)
    ((live-registry)        live-registry-ref)
    ((ballot-store)         ballot-store-ref)
    ((demand-registry)      demand-registry-ref)
    ((legal-registry)       legal-registry-ref)

    ;; --- Pipeline wiring ---
    ;;
    ;; Plan-store → observer auto-forwarding. The leaf is the natural
    ;; bridge: when planner adds an intent, the observer's gate needs
    ;; to know about it; when planner finalizes a plan, the leaf
    ;; implicitly endorses it (federation §III.1). Callbacks aren't
    ;; serializable, so spawn-scope-root calls this, and any caller
    ;; that has restored a scope from persistence should call it
    ;; again — it's idempotent (later set-on-* shadows earlier).
    ;;
    ;; Optional ISSUER is a procedure (target-type target-id) → unit
    ;; called alongside the observer's own confirm-plan / recognize-
    ;; intent — a sink for anyone who wants to hear a recognition land.
    ;; The observer's validation maps are recognition's one home.
    ((rewire-callbacks . maybe-issuer)
     (let ((issuer (and (pair? maybe-issuer) (car maybe-issuer))))
       ($ plan-store-ref 'set-on-intent
          (lambda (intent)
            ($ observer-ref 'register-intent intent)))
       ($ plan-store-ref 'set-on-plan
          (lambda (plan)
            (let ((pid (plan-id plan)))
              ($ observer-ref 'confirm-plan pid name)
              (when issuer (issuer 'plan pid)))))
       ;; the commitment-horizon gate at the accept doors — a wire like the
       ;; two above, so a persistence reload re-installs it here too; the
       ;; observer supplies the booking reads for the augmented ceiling
       ($ plan-store-ref 'set-gate
          (make-horizon-gate recipe-store-ref #:observer observer-ref
                             #:plan-store plan-store-ref
                             #:agent-store agent-store-ref))
       #t))

    ;; Imperative recognition entry-points. Governance code (or a
    ;; scope ratifying loose work) calls these instead of poking the
    ;; observer directly, so credential issuance and observer state
    ;; stay aligned. ISSUER is the same shape as for rewire-callbacks
    ;; — pass #f to skip credential issuance.
    ((recognize-plan plan-id . maybe-issuer)
     (let ((issuer (and (pair? maybe-issuer) (car maybe-issuer))))
       ($ observer-ref 'confirm-plan plan-id name)
       (when issuer (issuer 'plan plan-id))
       #t))

    ((recognize-intent iid . maybe-issuer)
     (let ((issuer (and (pair? maybe-issuer) (car maybe-issuer))))
       ($ observer-ref 'recognize-intent iid name)
       (when issuer (issuer 'intent iid))
       #t))))


;; =========================================================================
;; spawn-scope-root — convenience constructor for a complete scope vat
;; =========================================================================

(define* (spawn-scope-root scope-name #:key (law-packs #f))
  "Spawn a complete scope with all store actors. Call within a vat context.
   Returns the ^scope-root actor reference. LAW-PACKS is the rule-pack folder
   (or path list) the scope's law starts from; #f ⇒ no law. The folder is
   configuration, so the spawning service names it (the gateway reads
   PLAYNET_LAW_PACKS) — this module reads no environment."
  (let* ((rs  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap)
                      (hashmap) (hashmap) (hashmap)
                      (hashmap) (hashmap) (hashmap)))
         (as  (spawn ^agent-store (hashmap) (hashmap) (hashmap)))
         (obs (spawn ^observer (empty-observer-state) '()))
         (ps  (spawn ^plan-store (empty-plan-store-state) '()))
         (bzs (spawn ^buffer-zone-store (hashmap)))
         (acs (spawn ^account-store obs rs (hashmap) #f))
         (cbs (spawn ^capacity-buffer-store (hashmap)))
         (sts (spawn ^spatial-thing-store (hashmap)))
         (sns (spawn ^snapshot-store '()))
         (als (spawn ^alert-store '()))
         (preg (spawn ^process-registry (hashmap)))
         (lr   (spawn ^live-registry (hashmap)))
         (bls  (spawn-ballot-store))
         (drs  (spawn-demand-registry))
         ;; a context pack's PLACES belong in this scope's own tree: the gate
         ;; walks `sts`, so a rule guarded on a jurisdiction the pack names can
         ;; only fire if that jurisdiction is here. Bare rule packs carry none.
         (lrg  (load-legal-registry law-packs #:store sts))
         (sr   (spawn ^scope-root scope-name rs as obs ps bzs acs cbs sts sns
                      als preg lr bls drs lrg)))
    ;; Wire plan-store → observer auto-forwarding so live planner output
    ;; flows into the Validation Gate without a manual register-intent.
    ;; The leaf self-confirms its own plans (§III.1). For scopes loaded
    ;; from persistence, callers should re-call ($ scope-root
    ;; 'rewire-callbacks) — the wires aren't serializable.
    ($ sr 'rewire-callbacks)
    sr))


;; =========================================================================
;; Persistence environment (composed from all store envs)
;; =========================================================================

(define scope-root-env
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
                    process-registry-env
                    live-registry-env
                    live-resource-env
                    ballot-store-env
                    demand-registry-env
                    legal-registry-env)))
