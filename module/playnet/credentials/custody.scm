;;; credentials/custody.scm — who holds and who owns: custody attestation, custody transfer commitment, reversion, ownership.
;;;
;;; One family of the playnet credential catalogue (docs/planning/codebase-layout.md
;;; §6); the bundle a constructor returns is described once, in credentials/registry.scm.

(define-module (playnet credentials custody)
  #:use-module (playnet keri acdc)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module ((playnet credentials commitments) #:select (*schema-playnet-commitment*))
  #:export (*schema-playnet-custody-attestation*
            *schema-playnet-custody-transfer-commitment*
            *schema-playnet-ownership-attestation*
            *schema-playnet-reversion-attestation*
            make-custody-attestation-credential
            make-custody-transfer-commitment-credential
            make-ownership-attestation-credential
            make-reversion-attestation-credential))
(define *schema-playnet-custody-attestation*     "playnet-custody-attestation/v1")
(define *schema-playnet-ownership-attestation*   "playnet-ownership-attestation/v1")
(define *schema-playnet-custody-transfer-commitment*
  "playnet-custody-transfer-commitment/v1")
(define *schema-playnet-reversion-attestation*   "playnet-reversion-attestation/v1")


(define* (make-custody-attestation-credential
          issuing-authority-aid custodian-aid resource-spec qty
          #:key (valid-from #f) (valid-until #f) (supersedes #f)
          (movable #f) (return-to #f) (condition-floor #f) (resource #f)
          (qty-unit #f) (kind #f) (ref #f) (eligible #f)
          (signing-keypair #f) (multisig-signers #f))
  "Custody-attestation ACDC: ISSUING-AUTHORITY-AID attests that
   CUSTODIAN-AID is the current steward of QTY of RESOURCE-SPEC.

   KIND: what the custodian may DO with the thing. Absent (every grant so
   far) it is a USE grant — the custodian engages the thing and returns it
   whole. \"consume\" is a CONSUME grant: the custodian may SPEND up to QTY of
   the holding (money, fuel, seed) within the window; what is unspent at
   the window's close is the owner's again. Emitted as a claim only when
   given, so every use-grant keeps the SAID it always had.

   Issuer = issuing authority (federation, commons body, or scope itself
   for genesis self-attestation). Holder = custodian.

   valid-from / valid-until: optional timestamps (epoch seconds or ISO);
   #f means open-ended. An attestation whose valid-until is in the past
   is treated as revoked by observers.

   MOVABLE: whether this custody grant permits the custodian to RELOCATE
   the thing (default #f = keep in place — used where it sits).

   RETURN-TO / CONDITION-FLOOR: reciprocal CARE terms the custodian owes on
   return — a place the thing must come back to (for a movable grant) and a
   minimum condition it must come back in. (Return-BY is `valid-until`;
   the per-period capacity ceiling is `qty`; both are structural.)

   QTY-UNIT: what QTY is measured in. A capacity ceiling is a RATE — `8 hours a
   day` of a workshop — and a rate means nothing until it says per what, so the
   unit carries the denominator as one quotient — hours/day — see utils/units.scm.
   Absent, the solve reads the unit off the granted resource's own measure, which
   is the right default for a grant of everything a thing can render. Optional and
   therefore SAID-stable: a grant that omits it keeps the SAID it always had.

   RESOURCE: optional id of the exact EconomicResource this grant is over
   (resourceInventoriedAs) — names WHICH one when the owner holds several of a
   spec; when absent the subject is the owner's resource of RESOURCE-SPEC.

   ELIGIBLE: optional steward rule — a filter-rule expression (see
   matching/filter-rule.scm) carried verbatim as the JSON string the grantor
   signed. Bounds who may be ASSIGNED to work drawing on this grant; the
   commune's capacity is otherwise anonymous. Evaluated fail-closed at the
   assignment doors, never inside the LP.

   Every optional field is emitted as a claim only when set, so an
   attestation that uses none of them keeps the exact SAID it had before.

   SUPERSEDES: optional SAID of a prior custody-attestation this one
   replaces. Adds an I2I edge so the chain is attestable. Note the actual
   ACDC §8.6 I2I rule: issuee(target) == issuer(this) — i.e. the party
   issuing the superseding attestation must be the one the PRIOR
   attestation named as custodian (its issuee), not merely the prior's
   issuer. That is the meaningful constraint here: only the current
   custodian can hand custody on. It holds for both flows, since a
   scope's custody chain is self-attested (issuer == issuee == scope)
   before any transfer."
  (let ((edges (if supersedes
                   (list (cons 'supersedes
                               (make-edge supersedes
                                          #:operator 'I2I
                                          #:schema *schema-playnet-custody-attestation*)))
                   '())))
    (make-credential *schema-playnet-custody-attestation*
                     issuing-authority-aid custodian-aid
                     (let* ((base (list (cons 'custodian-aid  custodian-aid)
                                        (cons 'resource-spec resource-spec)
                                        (cons 'qty           qty)
                                        (cons 'valid-from    valid-from)
                                        (cons 'valid-until   valid-until)
                                        (cons 'issued-by     issuing-authority-aid)))
                            ;; optional grant metadata — each emitted only when set, so
                            ;; a grant that uses none keeps the exact SAID it had before
                            (cl base)
                            (cl (if movable         (cons (cons 'movable movable) cl) cl))
                            (cl (if return-to       (cons (cons 'return-to return-to) cl) cl))
                            (cl (if condition-floor (cons (cons 'condition-floor condition-floor) cl) cl))
                            (cl (if resource        (cons (cons 'resource-id resource) cl) cl))
                            (cl (if qty-unit        (cons (cons 'qty-unit qty-unit) cl) cl))
                            (cl (if kind            (cons (cons 'kind kind) cl) cl))
                            ;; REF (append-only, emit-when-set — SAID-stable
                            ;; for every grant minted before it existed): a
                            ;; caller nonce distinguishing two same-termed
                            ;; grants. Without it, recall-then-relend with
                            ;; identical terms rebuilt the identical SAID,
                            ;; and the revoked copy swallowed the re-issue —
                            ;; the wire answered 'ok while the grant stayed
                            ;; dead. Revocation stays append-only on purpose
                            ;; (the old signature verifies forever, so
                            ;; un-revoke-on-reissue would let anyone replay a
                            ;; recalled grant back to life); a fresh ref is
                            ;; the correct way to lend again.
                            (cl (if ref             (cons (cons 'ref ref) cl) cl))
                            ;; ELIGIBLE (append-only, emit-when-set — SAID-stable
                            ;; for every grant minted before it existed): the
                            ;; owner's steward rule, a filter-rule expression
                            ;; (matching/filter-rule.scm) carried as the verbatim
                            ;; JSON string the grantor signed. It bounds WHO may
                            ;; be assigned to work drawing on this grant, the way
                            ;; mandate-spec bounds a delegate's ballot — and like
                            ;; every filter-rule it fails CLOSED: a clause the
                            ;; evaluator does not know denies.
                            (cl (if eligible        (cons (cons 'eligible eligible) cl) cl)))
                       cl)
                     edges
                     #:signing-keypair signing-keypair
                     #:multisig-signers multisig-signers)))

(define* (make-ownership-attestation-credential
          owner-aid resource-id resource-spec
          #:key (kind "declared") (holder #f) (valid-from #f) (valid-until #f)
          (qty #f) (qty-unit #f) (ref #f) (supersedes #f) (stake #f)
          (signing-keypair #f) (multisig-signers #f))
  "Ownership-attestation ACDC: the TITLE claim behind a declared means,
   as a first-class credential. Custody's sibling on the other side of
   the rights/custody split: custody says who stewards a thing now,
   this says whose claim on its congealed labour stands
   (docs/common-property.typ).

   KIND \"declared\" is a self-assertion: issuer = holder = the owner.
   Self-issuance is the honest form of what declare-means already does —
   the signature makes the claim non-repudiable, revocable, and a
   subject others can attest or contest; it does not make it TRUE, which
   is what the auditor's ownership-coherence check and, later, the
   governed passage exist for. A future passage lands as KIND
   \"passage\": a superseding attestation whose issuer is the old owner
   and whose holder is the receiving scope — title moving as a chain,
   exactly custody-transfer's shape.

   QTY/QTY-UNIT: optional — the resource's own measure is the default
   truth, and a standing title stores no derived quantities (the skill
   credential's discipline). EMISSION, precisely (it is SAID-load-bearing):
   `valid-from` and `kind` are emitted UNCONDITIONALLY — #f and the
   \"declared\" default included — exactly as this constructor always has;
   only `valid-until`/`qty`/`qty-unit` are emitted when set. Do not
   \"align\" valid-from with valid-until: making it conditional would
   silently re-SAID every existing bare title (a #f entry in the claims
   alist IS SAID material — said-portable.scm).

   SUPERSEDES: SAID of the prior ownership attestation this replaces
   (I2I — only the titled owner passes title on). STAKE: SAID of an
   auditor's SNLT stake attestation (NI2I) — the ℓ_own⁰ edge the
   governed-passage design names; reserved, unused today."
  (let* ((edges '())
         (edges (if stake
                    (cons (cons 'stake (make-edge stake #:operator 'NI2I))
                          edges)
                    edges))
         (edges (if supersedes
                    (cons (cons 'supersedes
                                (make-edge supersedes
                                           #:operator 'I2I
                                           #:schema *schema-playnet-ownership-attestation*))
                          edges)
                    edges)))
    (make-credential *schema-playnet-ownership-attestation*
                     owner-aid (or holder owner-aid)   ; passage names the scope
                     ;; base emits valid-from/kind unconditionally (#f and
                     ;; default included) — historical, and therefore frozen:
                     ;; see the docstring's EMISSION note before touching this
                     (let* ((base (list (cons 'resource-id   resource-id)
                                        (cons 'resource-spec resource-spec)
                                        (cons 'kind          kind)
                                        (cons 'valid-from    valid-from)
                                        (cons 'issued-by     owner-aid)))
                            (cl base)
                            (cl (if valid-until (cons (cons 'valid-until valid-until) cl) cl))
                            (cl (if qty         (cons (cons 'qty qty) cl) cl))
                            (cl (if qty-unit    (cons (cons 'qty-unit qty-unit) cl) cl))
                            ;; REF (append-only, emit-when-set): the caller
                            ;; nonce that lets a disowned title be asserted
                            ;; anew — identical terms rebuilt the identical
                            ;; SAID, the revoked copy swallowed the re-issue,
                            ;; and title-permits? then locked the owner out
                            ;; of their own resource forever
                            (cl (if ref         (cons (cons 'ref ref) cl) cl)))
                       cl)
                     edges
                     #:signing-keypair signing-keypair
                     #:multisig-signers multisig-signers)))

(define* (make-custody-transfer-commitment-credential
          from-scope-aid to-scope-aid resource-spec qty
          new-attestation-said revoked-attestation-said
          #:key (carries-commitments '()) (effective-at #f)
          (signing-keypair #f) (multisig-signers #f))
  "Custody-transfer commitment ACDC: FROM-SCOPE-AID commits to transfer
   custody of QTY RESOURCE-SPEC to TO-SCOPE-AID.

   Issuer = from-scope (relinquishing custody). Holder = to-scope
   (inheriting). SIGNING-KEYPAIR signs the from-scope's own side (the
   relinquishing commitment). A full bilateral co-signature (to-scope
   counter-signs its acceptance) is the eventual model — pass
   MULTISIG-SIGNERS or add a receiver-fulfillment ACDC then; for now the
   from-scope's single issuer signature is what's attached, not the
   \"both sign\" the earlier docstring wrongly claimed.

   NEW-ATTESTATION-SAID: SAID of the freshly-issued custody-attestation
   for the receiving scope.
   REVOKED-ATTESTATION-SAID: SAID of the predecessor attestation being
   superseded.

   CARRIES-COMMITMENTS: list of prior commitment SAIDs that travel with
   the inventory. The protocol layer rejects a transfer that orphans
   outstanding commitments against the resource — an empty list is the
   explicit \"no obligations follow\" assertion, not a default."
  (let* ((carry-edges
          (map (lambda (i said)
                 (cons (string->symbol (format #f "carries-commitment-~a" i))
                       (make-edge said
                                  #:operator 'NI2I
                                  #:schema *schema-playnet-commitment*)))
               (iota (length carries-commitments))
               carries-commitments))
         (attestation-edges
          ;; NI2I, not I2I. I2I (ACDC §8.6) requires issuee(target) ==
          ;; issuer(this). Here issuer(this) is FROM-SCOPE while the new
          ;; attestation's issuee is TO-SCOPE — different by construction, since
          ;; the whole point is a transfer. The I2I constraint could therefore
          ;; never hold; NI2I ("no issuer/issuee constraint") is the correct
          ;; operator, matching the sibling revoked-attestation edge.
          (list (cons 'new-attestation
                      (make-edge new-attestation-said
                                 #:operator 'NI2I
                                 #:schema *schema-playnet-custody-attestation*))
                (cons 'revoked-attestation
                      (make-edge revoked-attestation-said
                                 #:operator 'NI2I
                                 #:schema *schema-playnet-custody-attestation*))))
         (edges (append attestation-edges carry-edges)))
    (make-credential *schema-playnet-custody-transfer-commitment*
                     from-scope-aid to-scope-aid
                     (list (cons 'from-scope-aid       from-scope-aid)
                           (cons 'to-scope-aid         to-scope-aid)
                           (cons 'resource-spec        resource-spec)
                           (cons 'qty                  qty)
                           (cons 'new-attestation      new-attestation-said)
                           (cons 'revoked-attestation  revoked-attestation-said)
                           (cons 'effective-at         effective-at))
                     edges
                     #:signing-keypair signing-keypair
                     #:multisig-signers multisig-signers)))

(define* (make-reversion-attestation-credential
          authority-aid default-custodian-aid
          resource-spec qty expired-attestation-said
          #:key (effective-at #f) (signing-keypair #f))
  "Issued by the half-life watcher when a custody-attestation expires
   without renewal. Credits a configured DEFAULT-CUSTODIAN; carries a
   `reverted-from` edge to the expired SAID. SIGNING-KEYPAIR optional
   for KERI portability."
  (let ((edges
         (list (cons 'reverted-from
                     (make-edge expired-attestation-said
                                #:operator 'NI2I
                                #:schema
                                *schema-playnet-custody-attestation*)))))
    (make-credential *schema-playnet-reversion-attestation*
                     authority-aid default-custodian-aid
                     (list (cons 'custodian-aid       default-custodian-aid)
                           (cons 'resource-spec      resource-spec)
                           (cons 'qty                qty)
                           (cons 'valid-from         (or effective-at
                                                          (iso-utc-now)))
                           (cons 'valid-until        #f)
                           (cons 'issued-by          authority-aid)
                           (cons 'reverted-from-said expired-attestation-said))
                     edges
                     #:signing-keypair signing-keypair)))

;; What the store knows of this family's schemas: the claims it indexes for
;; O(1) lookup, and the claim the observation time stands under. Registered
;; here at load, so a module that imports one family finds its credentials.
(register-schema-claims!
 `((,*schema-playnet-ownership-attestation* (resource-id))))
