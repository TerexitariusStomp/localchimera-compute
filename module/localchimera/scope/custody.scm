;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/scope/custody.scm — the custody methods of a scope: attestations, transfer, the outstanding commitments of a spec.
;;;
;;; A fragment of the scope actor (localchimera scope actor): a procedure from the
;;; actor's context to the doors it serves, composed into every scope by
;;; (localchimera boot scope). `with-scope-ctx` binds the actor's fields and helpers
;;; under their own names, so each clause reads as it did inside the actor
;;; (docs/planning/codebase-layout.md §5).

(define-module (localchimera scope custody)
  #:use-module (srfi srfi-1)
  #:use-module (localchimera keri first-person predicates)
  #:use-module (localchimera credentials custody)
  #:use-module (localchimera keri acdc)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (localchimera scope actor)
  #:use-module ((localchimera protocol dispatch) #:select (declared-doors))
  #:export (scope-custody-doors))

(define (scope-custody-doors ctx)
  (with-scope-ctx ctx
    (declared-doors scope

    ;; ====================================================================
    ;; Voice and weight rules (Phase 3 hardening)
    ;; ====================================================================
    ;;
    ;; A leaf's voice rule and a federation's weight rule are stored
    ;; as credentials, not implicit in code paths. Changes are
    ;; governance acts: they require gov-cap, emit a credential, and
    ;; supersede the prior rule (revoking it).

    ;; Voice rule and weight rule are both universal labor-proportional.
    ;; Voice = gross/total at every level; federation aggregation is
    ;; commune-weight-async (labor-share, hardcoded). Neither is
    ;; configurable; the protocol commits.


    ;; ====================================================================
    ;; Custody: attestation + transfer-commitment
    ;; ====================================================================
    ;;
    ;; Custody is a credential. A scope acts as the issuing authority for
    ;; its own inventory: `attest-custody` issues a self-held attestation;
    ;; `transfer-custody` co-issues (a) a new attestation crediting the
    ;; receiving scope and (b) a transfer-commitment that enumerates the
    ;; outstanding commitments traveling with the inventory. The prior
    ;; attestation is revoked atomically.
    ;;
    ;; The validator: outstanding commitments are commitments where this
    ;; scope is provider, resource-conforms-to matches, and the credential
    ;; is neither finished nor revoked. The `#:carries` policy chooses:
    ;;   'all       (default) — auto-enumerate all outstanding
    ;;   '()                  — must be no outstanding (else error)
    ;;   (list …)             — caller-supplied SAIDs (partial / curated)

    ((live-custody-attestations)         (live-custody-attestations))

    ((custody-attestation-for spec)      (custody-attestation-for spec))

    ((outstanding-commitments-of-spec s) (outstanding-commitments-of-spec s))

    ((attest-custody gov-cap resource-spec qty . opts)
     (require-gov-cap! gov-sealed? gov-cap "attest-custody" name)
     (let ((cred (make-custody-attestation-credential
                  #:issuing-authority-aid scope-aid
                  #:custodian-aid scope-aid
                  #:resource-spec resource-spec
                  #:qty qty
                  #:valid-from  (kw-ref opts 'valid-from (iso-utc-now))
                  #:valid-until (kw-ref opts 'valid-until)
                  #:supersedes  (kw-ref opts 'supersedes)
                  #:signing-keypair keypair)))
       (when acdc-store ($ acdc-store 'issue cred))
       (cred-said cred)))

    ((transfer-custody gov-cap resource-spec qty to-scope-aid . opts)
     (require-gov-cap! gov-sealed? gov-cap "transfer-custody" name)
     (require-store!   acdc-store    "transfer-custody" name)
     (let* ((carries-policy (kw-ref opts 'carries 'all))
            (effective-at   (kw-ref opts 'effective-at (iso-utc-now)))
            (prior          (custody-attestation-for resource-spec))
            (outstanding    (outstanding-commitments-of-spec resource-spec))
            (outstanding-saids (map cred-said outstanding))
            (resolve-carries
             (lambda ()
               (cond
                ((eq? carries-policy 'all) outstanding-saids)
                ((null? carries-policy)
                 (unless (null? outstanding-saids)
                   (error "transfer-custody: outstanding commitments would be orphaned"
                          name resource-spec outstanding-saids))
                 '())
                ((list? carries-policy)
                 (let ((missing (lset-difference equal?
                                                 outstanding-saids
                                                 carries-policy)))
                   (unless (null? missing)
                     (error "transfer-custody: explicit carries omits outstanding"
                            name missing)))
                 carries-policy)
                (else (error "transfer-custody: invalid carries policy"
                             carries-policy))))))
       (unless prior
         (error "transfer-custody: no prior attestation"
                name resource-spec scope-aid))
       (let* ((carries (resolve-carries))
              ;; the prior grant's TERMS travel with custody: movability, care
              ;; terms, the exact-resource binding, the unit, the kind, and the
              ;; owner's steward rule all bind the next custodian the way they
              ;; bound this one. `ref` stays per-issuance — it is the
              ;; anti-replay nonce, not a term.
              (new-att (make-custody-attestation-credential
                        #:issuing-authority-aid scope-aid
                        #:custodian-aid to-scope-aid
                        #:resource-spec resource-spec
                        #:qty qty
                        #:valid-from effective-at
                        #:supersedes (cred-said prior)
                        #:valid-until    (cred-claim prior 'valid-until)
                        #:movable        (cred-claim prior 'movable)
                        #:return-to      (cred-claim prior 'return-to)
                        #:condition-floor (cred-claim prior 'condition-floor)
                        #:resource       (cred-claim prior 'resource-id)
                        #:qty-unit       (cred-claim prior 'qty-unit)
                        #:kind           (cred-claim prior 'kind)
                        #:eligible       (cred-claim prior 'eligible)
                        #:signing-keypair keypair))
              (xfer    (make-custody-transfer-commitment-credential
                        #:from-scope-aid scope-aid
                        #:to-scope-aid to-scope-aid
                        #:resource-spec resource-spec
                        #:qty qty
                        #:new-attestation-said (cred-said new-att)
                        #:revoked-attestation-said (cred-said prior)
                        #:carries-commitments carries
                        #:effective-at effective-at
                        #:signing-keypair keypair)))
         ($ acdc-store 'issue new-att)
         ($ acdc-store 'issue xfer)
         ($ acdc-store 'revoke (cred-said prior))
         (cred-said xfer)))))))
