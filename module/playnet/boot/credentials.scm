;;; module/playnet/boot/credentials.scm — the gateway's credential store, the founding commune minting into it, the planner reconciled from it.

(define-module (playnet boot credentials)
  #:use-module ((playnet boot restore) #:select (restored-scope))
  #:use-module ((playnet boot site) #:select (data-path log!))
  #:use-module ((playnet federation rebuild) #:select (recover-economic-state))
  #:use-module ((playnet keri acdc-store) #:select (spawn-acdc-store))
  #:use-module ((playnet keri bridge) #:select (keri-connected?))
  #:use-module ((playnet keri inception) #:select (gateway-controller-aid-name))
  #:use-module ((playnet observation credentials) #:select (install-credentialing!))
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:export (spawn-credential-store! wire-credentialing! reconcile-planner!))

;; ── ACDC credential store ──────────────────────────────────────
;; One ^acdc-store, durable on local disk, in both modes. With KERIA
;; connected it stands behind ^keria-acdc-store, which adds the issue in
;; KERIA, the IPEX grant and the delete on revoke.
(define (spawn-credential-store! planner-vat)
  "The store in PLANNER-VAT, where the planner service reads it near."
  (let ((store
         (with-vat planner-vat
           (if (keri-connected?)
               (let ((proc (module-ref
                             (resolve-interface
                               '(playnet keys keria-store))
                             'spawn-keria-acdc-store)))
                 (proc (gateway-controller-aid-name) #:durable-dir (data-path "acdc")))
               ;; No KERIA client → DURABLE local-disk store, NOT pure memory.
               ;; ^acdc-store's #:durable-dir writes every credential through
               ;; to disk and replays them on startup (survives process death)
               ;; — the same mechanism scope-recovery / oobi-host / mesh-mailbox
               ;; already use. Without this, the whole ACDC credential graph
               ;; (personhood, delegations, stances, work/skill attestations)
               ;; was wiped on every gateway restart. The KERIA-backed tier
               ;; above adds witness-pool replication + cross-node verifiability
               ;; on top; this tier stops the restart-wipe with zero new infra.
               (spawn-acdc-store #:durable-dir (data-path "acdc"))))))
    (log! "  [gateway] acdc-store: ~a~%"
          (if (keri-connected?) "KERIA-backed" "durable (local disk)"))
    store))

;; ── Turn ON the credential substrate for the meeting commune ───
;; The gateway builds its scope via spawn-scope-root, which bypasses
;; the governance spawn-scope path that auto-installs credentialing,
;; so wire it explicitly: planner events on this scope now mint the
;; work / skill / intent / commitment / claim ACDCs into store
;; (the in-memory or KERIA-backed store above). Runs in planner-vat,
;; where the scope's observer + plan-store live.
;;
;; On a first boot the founding commune's ^scope is minted further down
;; and its own spawn-scope re-installs these hooks with a signer. On
;; every RESTART that mint is skipped (the AID is already on disk), so
;; this wiring is the one that stands — and without a signer here, each
;; work / claim / intent / commitment ACDC the live gateway records
;; issues with `signature: #f`. The restored ^scope holds the key, so
;; pass it: cred-signed-by-scope routes through its sign-said and the
;; keypair stays in the actor.
;;
;; The issuer travels with the signer. A verifier checks the signature
;; against the issuer AID, so a record signed by the founding commune
;; must name the founding commune as issuer — signing under one AID
;; while issuing under another fails to bind, which is worse than not
;; signing at all.
;;
;; That issuer is the founding commune's AID, the one earth keys the
;; commune by and the same AID the founder PHC below issues under.
;; `gateway-controller-aid-name` is this gateway's OWN local KERIA
;; identity, not an AID anything can verify a commune's authority
;; against, and it stands here only for the boot where no commune
;; AID exists yet.
(define (wire-credentialing! planner-vat meeting-scope store fc-aid-early restored)
  "MEETING-SCOPE's events mint their credentials into STORE, signed by the
founding commune's restored ^scope when FC-AID-EARLY names one."
  (with-vat planner-vat
    (let* ((fc-scope (and fc-aid-early (restored-scope restored fc-aid-early)))
           (issuer   (or fc-aid-early (gateway-controller-aid-name))))
      (install-credentialing! meeting-scope store issuer
                              #:signer fc-scope)
      (log! "  [gateway] credentialing: meeting commune wired to acdc-store \
(issuer ~a, ~a)~%"
            issuer (if fc-scope "signed" "unsigned — no restored scope key")))))

;; ── Reconcile the planner with the durable ACDC record ─────────
;; The economic state is persisted twice, independently, on local
;; disk: the planner scope-root via planner.syrup (native portrait,
;; restored by boot/earth) and the credential store via
;; #:durable-dir. The portrait is the primary and is complete on an
;; ordinary restart, so this reconcile is then an idempotent no-op —
;; recover-economic-state skips every commitment / intent / work-event
;; already present (by id — see federation/rebuild.scm). Its real job
;; is the disaster case: if planner.syrup was lost or corrupted while
;; the durable acdc-store survived, it rebuilds the planner from the
;; credential record. No gate — idempotency makes it correct on every
;; boot. (It no longer depends on a KERIA-backed store; the durable-dir
;; fallback persists the ACDCs just as well, locally.)
(define (reconcile-planner! planner-vat meeting-scope store)
  (catch #t
    (lambda ()
      (with-vat planner-vat
        (recover-economic-state meeting-scope store))
      (log! "  [gateway] planner reconciled with durable ACDC record~%"))
    (lambda (key . args)
      (log! "  [gateway] economic-state reconcile skipped: ~a ~a~%" key args)))
)
