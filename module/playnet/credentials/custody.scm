;;; SPDX-License-Identifier: AGPL-3.0-or-later
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

(define-credential (make-custody-attestation-credential issuing-authority-aid custodian-aid resource-spec qty)
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
  *schema-playnet-custody-attestation*
  #:key ((valid-from #f) (valid-until #f) (supersedes #f) (movable #f) (return-to #f) (condition-floor #f) (resource #f) (qty-unit #f) (kind #f) (ref #f) (eligible #f))
  #:signed (keypair multisig)
  #:claims ((? eligible) (? ref) (? kind) (? qty-unit) (? resource-id resource) (? condition-floor) (? return-to) (? movable)
            custodian-aid resource-spec qty valid-from valid-until (issued-by issuing-authority-aid))
  #:edges ((? supersedes supersedes I2I *schema-playnet-custody-attestation*)))

(define-credential (make-ownership-attestation-credential owner-aid resource-id resource-spec)
  "declared"
  *schema-playnet-ownership-attestation*
  #:key ((kind "declared") (holder #f) (valid-from #f) (valid-until #f) (qty #f) (qty-unit #f) (ref #f) (supersedes #f) (stake #f))
  #:signed (keypair multisig)
  #:holder (or holder owner-aid)
  #:claims ((? ref) (? qty-unit) (? qty) (? valid-until) resource-id resource-spec kind valid-from (issued-by owner-aid))
  #:edges ((? supersedes supersedes I2I *schema-playnet-ownership-attestation*) (? stake stake NI2I #f))
  #:index (resource-id))

(define-credential-procedure (make-custody-transfer-commitment-credential from-scope-aid to-scope-aid resource-spec qty new-attestation-said revoked-attestation-said)
  #:key ((carries-commitments '())
         (effective-at #f)
         (signing-keypair #f)
         (multisig-signers #f))
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

(define-credential (make-reversion-attestation-credential authority-aid default-custodian-aid resource-spec qty expired-attestation-said)
  "Issued by the half-life watcher when a custody-attestation expires
   without renewal. Credits a configured DEFAULT-CUSTODIAN; carries a
   `reverted-from` edge to the expired SAID. SIGNING-KEYPAIR optional
   for KERI portability."
  *schema-playnet-reversion-attestation*
  #:key ((effective-at #f))
  #:signed (keypair)
  #:claims ((custodian-aid default-custodian-aid) resource-spec qty (valid-from (or effective-at (iso-utc-now))) (valid-until #f) (issued-by authority-aid) (reverted-from-said expired-attestation-said))
  #:edges ((reverted-from expired-attestation-said NI2I *schema-playnet-custody-attestation*)))

;; What the store knows of this family's schemas: the claims it indexes for
;; O(1) lookup, and the claim the observation time stands under. Registered
;; here at load, so a module that imports one family finds its credentials.

