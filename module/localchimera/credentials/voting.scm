;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; credentials/voting.scm — a voice recorded: stance, expression stance, ballot snapshot, tally result, recomposition ratification.
;;;
;;; One family of the localchimera credential catalogue (docs/planning/codebase-layout.md
;;; §6); the bundle a constructor returns is described once, in credentials/registry.scm.

(define-module (localchimera credentials voting)
  #:use-module (localchimera keri acdc)
  #:use-module (localchimera vf schemas)
  #:use-module (srfi srfi-1)
  #:export (*schema-localchimera-ballot-snapshot*
            *schema-localchimera-expression-stance*
            *schema-localchimera-recomposition-ratification*
            *schema-localchimera-stance*
            *schema-localchimera-tally-result*
            make-ballot-snapshot-credential
            make-expression-stance-credential
            make-recomposition-ratification-credential
            make-stance-credential
            make-tally-result-credential))
(define *schema-localchimera-stance*                 "localchimera-stance/v1")
(define *schema-localchimera-expression-stance*      "localchimera-expression-stance/v1")
(define *schema-localchimera-ballot-snapshot*         "localchimera-ballot-snapshot/v1")
(define *schema-localchimera-tally-result*            "localchimera-tally-result/v1")
(define *schema-localchimera-recomposition-ratification*
  "localchimera-recomposition-ratification/v1")

(define-credential (make-stance-credential citizen-aid governance-group-aid domain proposal-id position timestamp)
  "Citizen's vote on a ballot proposal — KERI-signed, durable. DOMAIN
   tags the ballot kind ('policy, 'recomposition, …) so
   downstream consumers can filter without re-deriving from proposal-id.

   When BALLOT-SNAPSHOT-SAID is supplied, an `e`-block edge with NI2I
   operator is added pointing to the snapshot ACDC. This is the §4.9
   migration: SAID-claim references become formal ACDC edges so a
   verifier walking the property graph can resolve in either direction.
   The `proposal-id` claim is retained for backwards compatibility."
  *schema-localchimera-stance*
  #:key ((ballot-snapshot-said #f) (u 'auto))
  #:signed ()
  #:nonce u
  #:claims (domain proposal-id position timestamp)
  #:edges ((? ballot-snapshot ballot-snapshot-said NI2I *schema-localchimera-ballot-snapshot*))
  #:index (domain proposal-id)
  #:time timestamp)

(define-credential (make-expression-stance-credential citizen-aid governance-group-aid domain expression-id distribution timestamp)
  "Citizen's distribution across targets in an expression. DOMAIN tags what
   the targets are (e.g. 'plan, 'demand, 'resource, 'proposal-relevance).
   Same labor-proportional voice mechanism, any per-scope per-domain
   question. Issuer = the citizen (their own assertion); issuee = the
   recording scope (see make-stance-credential's note on signing).

   U: blinding nonce — see make-stance-credential. A distribution has a
   larger claim space than a position, but it is still enumerable for
   small target sets, so it gets the same treatment."
  *schema-localchimera-expression-stance*
  #:key ((u 'auto))
  #:signed ()
  #:nonce u
  #:claims (domain expression-id distribution timestamp)
  #:index (domain expression-id)
  #:time timestamp)

(define-credential (make-ballot-snapshot-credential governance-group-aid domain proposal-id franchise snapshot-said opened-at)
  "Governance group anchors the frozen voice-share weights at ballot open.
   DOMAIN tags the ballot kind ('policy, 'recomposition, …).
   voice-snapshot-entries: list of (citizen-id voice-share resolved-delegation)
                           where resolved-delegation is a list of
                           (delegate-aid fraction mandate-spec-or-#f).
                           Enough to reconstruct the ballot.
   citizen-registry-aids: list of citizen AIDs known to this ballot."
  *schema-localchimera-ballot-snapshot*
  #:key ((description #f) (voice-snapshot-entries '()) (citizen-registry-aids '()))
  #:signed ()
  #:holder governance-group-aid
  #:claims (domain proposal-id franchise snapshot-said opened-at description voice-snapshot-entries citizen-registry-aids)
  #:index (domain proposal-id)
  #:time opened-at)

(define-credential (make-tally-result-credential governance-group-aid domain proposal-id franchise winner tally-data abstain-weight closed-at)
  "Governance group signs the final ballot decision — auditable proof.
   DOMAIN tags the ballot kind ('policy, 'recomposition, …).

   Per §4.9 migration: BALLOT-SNAPSHOT-SAID, when supplied, becomes an
   `e`-block NI2I edge so verifiers can walk tally → snapshot directly.
   The `proposal-id` claim is retained for backwards compatibility."
  *schema-localchimera-tally-result*
  #:key ((ballot-snapshot-said #f))
  #:signed ()
  #:holder governance-group-aid
  #:claims (domain proposal-id franchise winner tally-data abstain-weight closed-at)
  #:edges ((? ballot-snapshot ballot-snapshot-said NI2I *schema-localchimera-ballot-snapshot*))
  #:index (domain proposal-id)
  #:time closed-at)

(define-credential-procedure (make-recomposition-ratification-credential scope-aid proposal-type proposal-spec ballot-said tally)
  #:key ((threshold 0.5)
         (threshold-met? #t)
         (ratified-at #f)
         (signing-keypair #f)
         (issuer-aid #f)
         (predecessors #f)
         (successor-spec #f))
  "Recomposition-ratification ACDC. Records that a labor-proportional
   ballot passed for a structural proposal.

   PROPOSAL-TYPE: 'admit-commune | 'merge-with | 'split |
                  'rejoin-federation
   PROPOSAL-SPEC: canonical equal?-comparable form (see scope.scm)
   BALLOT-SAID:   SAID of the closed ballot-snapshot ACDC anchoring
                  the labor-proportional voice computation.
   TALLY:         alist (yes . w) (no . w) (abstain . w) at close.
   THRESHOLD:     voice fraction needed (default 0.5 = simple majority).
   THRESHOLD-MET?: pre-checked at issuance; consumed by validators.

   Two issuance shapes (per democracy-on-keri.md §4.3):

   1. **Self-issued** (legacy): omit ISSUER-AID. Issuer = holder =
      SCOPE-AID. Used by tests and the pre-bottom-up flow. The
      ratification post-records the ballot's outcome on the affected
      scope's TEL.

   2. **Parent-issued** (bottom-up): supply ISSUER-AID = parent
      federation AID (or Universal Commune for federation-root
      recompositions), PREDECESSORS = list of pre-existing scope AIDs
      involved (e.g. (A B) for a merge), and SUCCESSOR-SPEC = alist
      describing the new scope to-be-incepted (e.g. ((kind . commune)
      (name . \"AB\") (members . (...)))). The ratification SAID is
      then sealed as an anchor in the new scope's inception event.
      Predates the successor's existence.

   Either shape carries an NI2I edge to the ballot-snapshot."
  (let* ((effective-issuer (or issuer-aid scope-aid))
         (claims-base (list (cons 'scope-aid       scope-aid)
                            (cons 'proposal-type   proposal-type)
                            (cons 'proposal-spec   proposal-spec)
                            (cons 'ballot-said     ballot-said)
                            (cons 'tally           tally)
                            (cons 'threshold       threshold)
                            (cons 'threshold-met?  threshold-met?)
                            (cons 'ratified-at     (or ratified-at
                                                        (iso-utc-now)))))
         (claims (cond
                  ((and predecessors successor-spec)
                   (append claims-base
                           (list (cons 'predecessors   predecessors)
                                 (cons 'successor-spec successor-spec))))
                  (predecessors
                   (append claims-base
                           (list (cons 'predecessors predecessors))))
                  (successor-spec
                   (append claims-base
                           (list (cons 'successor-spec successor-spec))))
                  (else claims-base)))
         (edges
          (list (cons 'ballot-snapshot
                      (make-edge ballot-said
                                 #:operator 'NI2I
                                 #:schema *schema-localchimera-ballot-snapshot*)))))
    (make-credential *schema-localchimera-recomposition-ratification*
                     effective-issuer effective-issuer
                     claims
                     edges
                     #:signing-keypair signing-keypair)))

;; What the store knows of this family's schemas: the claims it indexes for
;; O(1) lookup, and the claim the observation time stands under. Registered
;; here at load, so a module that imports one family finds its credentials.
(register-schema-claims!
 `((,*schema-localchimera-recomposition-ratification* (proposal-type proposal-spec) ratified-at)))
