;;; federation/auditor.scm — ^federation-auditor + ^custody-half-life-watcher
;;;
;;; Phase 1 of HARDENING.md: turning runtime-checkable invariants from
;;; theory into actively-detected properties. Validators in
;;; structural-invariants.scm are functions; without an actor calling
;;; them on a schedule, capture is detectable but not detected.
;;;
;;; Two actors with the same shape:
;;;
;;;   ^federation-auditor      — periodic federation-tree-coherent?
;;;                              emits audit-pass on success,
;;;                              incoherence-alert on failure.
;;;
;;;   ^custody-half-life-watcher — periodic scan for expired
;;;                                attestations; issues reversion
;;;                                attestation crediting a configured
;;;                                default custodian; revokes the
;;;                                expired one.
;;;
;;; Both actors are *synchronous* — driven by an external clock
;;; (a real deployment uses a fibers timer; tests call `audit!` /
;;; `tick!` directly). This keeps them testable without timing
;;; flakiness.
;;;


;; ── ^federation-auditor ─────────────────────────────────────────────────────

(define-module (playnet federation auditor)
  #:use-module (playnet credentials audit)
  #:use-module (playnet credentials custody)
  #:use-module (playnet credentials registry)
  #:use-module (playnet keri acdc)
  #:use-module (playnet vf facts validity)
  #:use-module (srfi srfi-1)
  #:use-module (goblins actor-lib facet)
  #:use-module (playnet federation structural-invariants)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (^federation-auditor spawn-federation-auditor *auditor-methods-readonly*
            spawn-auditor-facet ^custody-half-life-watcher
            spawn-custody-half-life-watcher))

(define-actor (^federation-auditor bcom auditor-aid federation-ref
                                    sink-store cycle keypair)
  ;; AUDITOR-AID:    AID this auditor signs credentials under
  ;; FEDERATION-REF: the federation being audited (any ^scope ref)
  ;; SINK-STORE:     ACDC store where audit-pass / incoherence-alert
  ;;                 credentials are emitted (typically the federation's)
  ;; CYCLE:          monotonic cycle counter; bumped each `audit!`
  ;; KEYPAIR:        optional Ed25519 keypair for signing emitted
  ;;                 credentials (KERI portability); #f = unsigned

  ;; All plain data / actor refs, no closures — safe to persist directly.
  ;; Without this, `cycle` silently reset to 0 on every restart.
  #:portrait
  (lambda () (list auditor-aid federation-ref sink-store cycle keypair))

  #:version 1

  #:restore
  (lambda (version . args)
    (case version
      ((1) (apply spawn ^federation-auditor args))
      (else (error "Unknown ^federation-auditor version" version))))

  (methods
   ((auditor-aid)    auditor-aid)
   ((federation)     federation-ref)
   ((cycle)          cycle)

   ((audit!)
    ;; Run all runtime-checkable invariants; emit credential.
    ;; Returns the SAID of the emitted credential.
    (let* ((unique?   (federation-membership-paths-unique? federation-ref))
           (labor?    (leaf-only-labor-coherent? federation-ref))
           (members?  (federation-members-attested? federation-ref))
           (lineage?  (verify-kind-from-lineage federation-ref))
           (redist?   (redistribution-coherent? federation-ref))
           (ratified? (recomposition-ratified? federation-ref))
           (owned?    (ownership-coherent? federation-ref))
           (once?     (records-held-once? federation-ref))
           (coherent? (and unique? labor? members? lineage? redist? ratified?
                           owned? once?))
           (fed-aid   ($ federation-ref 'scope-aid))
           ;; The auditor is the federation's OWN runtime invariant checker,
           ;; so the federation issues + signs its audit records — issuer =
           ;; fed-aid, signed via the federation's sign-said (keypair stays in
           ;; the actor). Forgery-resistant provenance ("this federation's
           ;; auditor produced this pass/alert"), not independent third-party
           ;; audit. cred-signed-by-scope no-ops for a keyless synthetic
           ;; federation. AUDITOR-AID stays as the actor's nominal label.
           (cred
            (cred-signed-by-scope
            (if coherent?
                (make-audit-pass-credential #:auditor-aid fed-aid
                                            #:federation-aid fed-aid
                                            #:cycle cycle)
                (let ((violations
                       (filter (lambda (entry) (cdr entry))
                               (list
                                (cons 'double-counted-members
                                      (and (not unique?)
                                           (federation-double-counted-members
                                            federation-ref)))
                                (cons 'leaf-only-labor-violations
                                      (and (not labor?)
                                           (map cred-said
                                                (leaf-only-labor-violations
                                                 federation-ref))))
                                (cons 'unattested-members
                                      (and (not members?)
                                           (federation-unattested-members
                                            federation-ref)))
                                (cons 'kind-lineage-failure
                                      (and (not lineage?)
                                           ($ federation-ref 'kind)))
                                (cons 'redistribution-breaches
                                      (and (not redist?)
                                           (append-map
                                            (lambda (s)
                                              (map (lambda (b)
                                                     (list ($ s 'scope-aid)
                                                           (cred-said (car b))
                                                           (cdr b)))
                                                   (redistribution-mandate-breaches s)))
                                            (cons federation-ref
                                                  (federation-leaves federation-ref)))))
                                (cons 'unratified-recompositions
                                      (and (not ratified?)
                                           (map cred-said
                                                (unratified-recomposition-acdcs
                                                 federation-ref))))
                                ;; the ownership backstop: fields contradicting
                                ;; standing titles (declare-means's promised audit)
                                (cons 'ownership-violations
                                      (and (not owned?)
                                           (ownership-violations
                                            federation-ref)))
                                ;; one record, one scope: the condition every
                                ;; fold's sum is sound on
                                (cons 'records-held-twice
                                      (and (not once?)
                                           (records-held-twice
                                            federation-ref)))))))
                  (make-incoherence-alert-credential
                   #:auditor-aid fed-aid
                   #:federation-aid fed-aid
                   #:violations violations
                   #:cycle cycle)))
            federation-ref)))
      (when sink-store ($ sink-store 'issue cred))
      (bcom (^federation-auditor bcom auditor-aid federation-ref
                                  sink-store (+ cycle 1) keypair)
            (cred-said cred))))))

(define* (spawn-federation-auditor federation-ref
                                    #:key (auditor-aid #f) (sink-store #f)
                                          (keypair #f))
  "Spawn a new auditor for FEDERATION-REF.
   AUDITOR-AID  defaults to a synthetic AID from the federation's name;
   SINK-STORE   defaults to the federation's own acdc-store;
   KEYPAIR      optional Ed25519 keypair for signing emitted credentials
                (KERI portability) — its public half should match
                AUDITOR-AID's prefix."
  (let* ((fed-name (catch #t
                     (lambda () ($ federation-ref 'name))
                     (lambda _ "federation")))
         (effective-aid
          (or auditor-aid
              (string-append "E_auditor_" fed-name)))
         (effective-sink
          (or sink-store ($ federation-ref 'acdc-store))))
    (spawn ^federation-auditor effective-aid federation-ref
           effective-sink 0 keypair)))


;; Read-only facet for monitor-only consumers — UI dashboards,
;; archivists, peer auditors that should see audit state without
;; the capability to trigger an audit cycle.
(define *auditor-methods-readonly*
  '(auditor-aid federation cycle))

(define* (spawn-auditor-facet auditor-ref
                              #:optional (methods *auditor-methods-readonly*))
  "Attenuated view of AUDITOR-REF: read methods only by default, no
   audit! exposed. Use when handing an auditor reference across a
   trust boundary."
  (apply facet auditor-ref methods))


;; ── ^custody-half-life-watcher ──────────────────────────────────────────────

(define-actor (^custody-half-life-watcher bcom watcher-aid scope-ref
                                           default-custodian-fn
                                           cycle keypair)
  ;; WATCHER-AID:           AID for the reversion attestations issued
  ;; SCOPE-REF:             the scope whose custody attestations are
  ;;                        watched (issuer or holder, configurable)
  ;; DEFAULT-CUSTODIAN-FN:  (resource-spec → aid) — chooses the default
  ;;                        custodian for a given resource on expiry.
  ;;                        Typical implementations: federation pool,
  ;;                        commons AID, original source AID.

  ;; default-custodian-fn is a closure and can't survive a portrait —
  ;; excluded here; restore leaves it as an erroring stub until
  ;; 'rewire-default-custodian-fn! is called, so a restart can't silently
  ;; misdirect a reversion to whatever the stub happens to return.
  #:portrait
  (lambda () (list watcher-aid scope-ref cycle keypair))

  #:version 1

  #:restore
  (lambda (version aid scope cyc kp)
    (case version
      ((1)
       (spawn ^custody-half-life-watcher aid scope
              (lambda (_spec)
                (error "^custody-half-life-watcher: default-custodian-fn not yet rewired after restore — call 'rewire-default-custodian-fn! first"))
              cyc kp))
      (else (error "Unknown ^custody-half-life-watcher version" version))))

  (methods
   ((watcher-aid) watcher-aid)
   ((cycle)       cycle)

   ((rewire-default-custodian-fn! new-fn)
    "Re-supply the default-custodian-fn closure lost on restore (see #:portrait)."
    (bcom (^custody-half-life-watcher bcom watcher-aid scope-ref
                                       new-fn cycle keypair)))

   ((tick!)
    ;; Scan live attestations held by SCOPE-REF; for each whose
    ;; valid-until is in the past, issue a reversion + revoke.
    ;; Returns list of (expired-said . reversion-said) pairs.
    (let* ((store ($ scope-ref 'acdc-store))
           (live  (if store
                      (filter
                       (lambda (c) (not (cred-revoked? c)))
                       ($ store 'by-schema
                          *schema-playnet-custody-attestation*))
                      '()))
           (expired (filter (lambda (c)
                              (not (custody-cred-live? c)))
                            live))
           (results '()))
      (when store
        (for-each
         (lambda (c)
           (let* ((spec (cred-claim c 'resource-spec))
                  (qty  (cred-claim c 'qty))
                  (default-cust (default-custodian-fn spec))
                  ;; The scope that holds the custody attestations is the
                  ;; authority for reverting them — issuer = scope-aid, signed
                  ;; via the scope's own sign-said. WATCHER-AID stays as the
                  ;; actor's nominal label. (issued-by claim preserves it.)
                  (rev (cred-signed-by-scope
                        (make-reversion-attestation-credential
                         #:authority-aid ($ scope-ref 'scope-aid)
                         #:default-custodian-aid default-cust
                         #:resource-spec spec
                         #:qty qty
                         #:expired-attestation-said (cred-said c))
                        scope-ref)))
             ($ store 'issue rev)
             ($ store 'revoke (cred-said c))
             (set! results
                   (cons (cons (cred-said c) (cred-said rev))
                         results))))
         expired))
      (bcom (^custody-half-life-watcher bcom watcher-aid scope-ref
                                         default-custodian-fn
                                         (+ cycle 1) keypair)
            (reverse results))))))

(define* (spawn-custody-half-life-watcher scope-ref default-custodian-fn
                                           #:key (watcher-aid #f)
                                                 (keypair #f))
  "Spawn a watcher actor for SCOPE-REF.
   DEFAULT-CUSTODIAN-FN: (resource-spec → aid). Typical impls:
                        federation pool, commons AID, original source.
   WATCHER-AID:         defaults to E_halflife_<scope-name>.
   KEYPAIR:             optional Ed25519 for KERI-signed reversions."
  (let* ((scope-name (catch #t
                       (lambda () ($ scope-ref 'name))
                       (lambda _ "scope")))
         (effective-aid
          (or watcher-aid
              (string-append "E_halflife_" scope-name))))
    (spawn ^custody-half-life-watcher effective-aid scope-ref
           default-custodian-fn 0 keypair)))
