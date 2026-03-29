;;; module/playnet/host.scm — Host org for multi-org topology
;;;
;;; The host org is privileged: it holds service capabilities and grants
;;; attenuated sub-capabilities to tenant orgs via OCapN over Unix domain sockets.
;;;
;;; Public API:
;;;   make-host-org        — create a governed org that manages services and tenants
;;;   host-grant-service!  — install a service capability under infra-<service-name>
;;;   host-grant-deploy!   — install a deploy capability for a config path
;;;   deploy-via-org!      — execute a deploy with full org provenance
;;;
;;; Tenant orgs get only what the host grants. The grant is an org action — in the
;;; host's history, attributed to whoever authorized it.
;;;
;;; Design note: infra-* bindings store RAW capability actor refs (not endorsed
;;; wrappers). The endorsement is validated at grant time to prove the caller
;;; holds infra-seal, then the raw cap is stored so it can be called directly
;;; via ($ cap 'method). The endorsed marker is kept in the history expression
;;; for auditability.
;;;
;;; Possession IS authorization. No ACL patterns.

(define-module (playnet host)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins actor-lib sealers)
  #:use-module (playnet gplay)
  #:use-module (playnet org)
  #:use-module (playnet services)
  #:use-module (playnet endorsement)
  #:export (make-host-org
            host-grant-service!
            host-grant-deploy!
            deploy-via-org!
            host-spawn-tenant!))

;;; ── Host org creation ────────────────────────────────────────────────────────

(define* (make-host-org name #:key (store #f))
  "Create a host org that manages services and tenants on this machine.
   Returns (values host-org gov-seal infra-seal member-seal)

   The host org is a governed org whose infra-* bindings hold service and
   deploy capabilities.  Tenants receive attenuated capabilities passed
   explicitly.

   When STORE is provided, the org will use persistent storage.
   (Persistent governed orgs are a future feature — for now, store is
   accepted but only the non-persistent path is implemented.)"
  ;; TODO: when make-governed-org-persistent exists, wire store here
  (make-governed-org name))

;;; ── Privileged grant helper ──────────────────────────────────────────────────

(define (host-grant! host-org binding-name cap infra-seal history-expr)
  "Internal: validate endorsement, then store raw cap under binding-name.
   The validator sees the endorsed value (proving infra-seal possession).
   The binding stores the raw cap (so it's callable via $).
   History records the grant with history-expr."
  (let* ((ref (org-ref host-org))
         ;; Create endorsed value for validator check
         (endorsed-val (endorse cap infra-seal))
         ;; Validate: prove we hold infra-seal
         (validator ($ ref 'validator-proc))
         (expressor ($ ref 'current-expressor))
         (pre-bindings ($ ref 'bindings))
         (post-bindings (cons (cons binding-name cap) pre-bindings)))
    (unless (call-validator validator expressor binding-name endorsed-val
                            pre-bindings post-bindings)
      (error "Validation failed: infra-seal required for" binding-name))
    ;; Store the raw cap (not endorsed) so it's usable via ($ cap 'method)
    (let* ((version (next-version))
           (entry (list version expressor history-expr ($ ref 'head-version))))
      ($ ref 'modify! binding-name cap entry))))

;;; ── Service capability grants ────────────────────────────────────────────────

(define (host-grant-service! host-org service-name service-cap infra-seal)
  "Install a service capability in the host org under infra-<service-name>.
   Requires infra-seal endorsement.

   service-name: string, e.g. \"nginx\"
   service-cap: a ^service-cap actor ref
   infra-seal: the infra-seal returned by make-host-org

   The raw cap is stored (callable via $). The endorsement is validated
   at grant time and recorded in history for auditability."
  (with-vat (org-vat host-org)
    (let ((binding-name (string->symbol
                         (string-append "infra-" service-name))))
      (host-grant! host-org binding-name service-cap infra-seal
                   `(host-grant-service! ,service-name)))))

;;; ── Deploy capability grants ─────────────────────────────────────────────────

(define (host-grant-deploy! host-org config-path infra-seal)
  "Install a deployment capability for config-path.
   Binding name: infra-deploy-<basename>

   config-path: path to a Guix deploy config (.scm file)
   infra-seal: the infra-seal returned by make-host-org

   The deploy cap is content-hashed at creation time and verified at
   deploy time — if the config changes, the cap refuses to deploy."
  (with-vat (org-vat host-org)
    (let* ((base (basename config-path ".scm"))
           (name (string->symbol (string-append "infra-deploy-" base)))
           (deploy-cap (make-deploy-cap (org-vat host-org) config-path)))
      (host-grant! host-org name deploy-cap infra-seal
                   `(host-grant-deploy! ,config-path)))))

;;; ── Deploy as an org action (Layer 7) ────────────────────────────────────────

(define (deploy-via-org! host-org deploy-binding-name actor-seal)
  "Execute a deploy capability stored in the host org, acting as actor-seal.
   The deploy action is recorded in org history with full provenance.

   deploy-binding-name: symbol like 'infra-deploy-machines
   actor-seal: the infra-seal (proves authorization to deploy)

   This is a convenience wrapper — the real action recorded in history:
     (deploy-via-org! <binding-name>)
   with an endorsed marker proving who authorized it.

   Flow:
   1. Look up the raw deploy cap from org bindings
   2. Execute the deploy (guix deploy)
   3. Record the action in org history with endorsed authorization marker"
  (with-vat (org-vat host-org)
    (let* ((ref (org-ref host-org))
           ;; Look up the raw deploy capability from org bindings
           (deploy-cap ($ ref 'lookup deploy-binding-name))
           ;; Execute the actual deployment
           (result ($ deploy-cap 'deploy))
           ;; Create endorsed marker proving authorization
           (endorsed-marker (endorse deploy-binding-name actor-seal))
           ;; Record in history under ungoverned name
           (version (next-version))
           (expressor ($ ref 'current-expressor))
           (entry (list version expressor
                       `(deploy-via-org! ,deploy-binding-name)
                       ($ ref 'head-version))))
      ;; Store deploy record: binding name + endorsed proof of authorization
      ($ ref 'modify! 'last-deploy
         (list 'deployed deploy-binding-name endorsed-marker)
         entry)
      result)))

;;; ── OCapN tenant communication ───────────────────────────────────────────────

;; TODO OCapN/UDS: when Goblins Unix socket netlayer is wired:
;; (define (host-spawn-tenant! host-org tenant-name caps-alist)
;;   "Spawn a tenant org process and pass it attenuated capabilities via OCapN."
;;   (let ((socket-path (string-append "/var/run/playnet-" tenant-name ".sock")))
;;     ;; spawn the Shepherd service
;;     ;; pass caps via OCapN Unix socket
;;     ...))
;;
;; For now: tenant orgs are spawned by Shepherd, capabilities are passed
;; at construction time via make-governed-org or as bindings by the host admin.
;; Goblins 0.16.0 has Unix Domain Socket netlayer — wire it up here when ready.

(define (host-spawn-tenant! host-org tenant-name caps-alist)
  "Placeholder for OCapN/UDS tenant spawning.
   Currently raises an error — tenant orgs must be spawned by Shepherd
   and capabilities passed at construction time.

   When Goblins Unix socket netlayer is wired, this will:
   1. Spawn a tenant org Shepherd service
   2. Pass attenuated capabilities via OCapN over Unix domain sockets"
  (error "OCapN/UDS tenant spawning not yet implemented"
         tenant-name
         "Use Shepherd service + manual capability grants for now"))
