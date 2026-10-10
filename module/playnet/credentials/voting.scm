;;; credentials/voting.scm — a voice recorded: stance, expression stance, ballot snapshot, tally result, recomposition ratification.
;;;
;;; One family of the playnet credential catalogue (docs/planning/codebase-layout.md
;;; §6); the bundle a constructor returns is described once, in credentials/registry.scm.

(define-module (playnet credentials voting)
  #:use-module (playnet keri acdc)
  #:use-module (playnet vf schemas)
  #:use-module (srfi srfi-1)
  #:export (*schema-playnet-ballot-snapshot*
            *schema-playnet-expression-stance*
            *schema-playnet-recomposition-ratification*
            *schema-playnet-stance*
            *schema-playnet-tally-result*
            make-ballot-snapshot-credential
            make-expression-stance-credential
            make-recomposition-ratification-credential
            make-stance-credential
            make-tally-result-credential))
(define *schema-playnet-stance*                 "playnet-stance/v1")
(define *schema-playnet-expression-stance*      "playnet-expression-stance/v1")
(define *schema-playnet-ballot-snapshot*         "playnet-ballot-snapshot/v1")
(define *schema-playnet-tally-result*            "playnet-tally-result/v1")
(define *schema-playnet-recomposition-ratification*
  "playnet-recomposition-ratification/v1")



(define* (make-stance-credential citizen-aid governance-group-aid
                                 domain proposal-id position timestamp
                                 #:key (ballot-snapshot-said #f)
                                       (u 'auto))
  "Citizen's vote on a ballot proposal — KERI-signed, durable. DOMAIN
   tags the ballot kind ('policy, 'recomposition, …) so
   downstream consumers can filter without re-deriving from proposal-id.

   When BALLOT-SNAPSHOT-SAID is supplied, an `e`-block edge with NI2I
   operator is added pointing to the snapshot ACDC. This is the §4.9
   migration: SAID-claim references become formal ACDC edges so a
   verifier walking the property graph can resolve in either direction.
   The `proposal-id` claim is retained for backwards compatibility."
  (let ((edges (if ballot-snapshot-said
                   (list (cons 'ballot-snapshot
                               (make-edge ballot-snapshot-said
                                          #:operator 'NI2I
                                          #:schema *schema-playnet-ballot-snapshot*)))
                   '())))
    ;; issuer = the CITIZEN (a vote is the citizen's own assertion);
    ;; issuee = the recording governance scope, the counter-party that tallies
    ;; it. A targeted ACDC with a real Target AID (ACDC §7.6).
    ;;
    ;; The citizen's KERI key is client-side, so this is only a *conformant*
    ;; ACDC when the client signs it — see `stance-signing-preimage` and the
    ;; signature-verifying `cast` path in service.scm. An unsigned stance is
    ;; honestly just an unsigned assertion; the orientation stays
    ;; citizen-issued either way so there is ONE shape, and recovery reads the
    ;; caster from the issuer.
    ;; U is the blinding nonce. Generated here when absent, but the
    ;; client-signed path MUST pass the one it signed over: `cast-signed`
    ;; rebuilds this credential to check the signature, and a fresh nonce
    ;; would change the SAID and fail every signature. It rides back from
    ;; the client in the echoed claims, exactly as `timestamp` does.
    (make-credential *schema-playnet-stance*
                     citizen-aid governance-group-aid
                     (append
                      (u-claim u)
                      (list (cons 'domain      domain)
                            (cons 'proposal-id proposal-id)
                            (cons 'position    position)
                            (cons 'timestamp   timestamp)))
                     edges)))

(define* (make-expression-stance-credential citizen-aid governance-group-aid
                                            domain expression-id distribution
                                            timestamp
                                            #:key (u 'auto))
  "Citizen's distribution across targets in an expression. DOMAIN tags what
   the targets are (e.g. 'plan, 'demand, 'resource, 'proposal-relevance).
   Same labor-proportional voice mechanism, any per-scope per-domain
   question. Issuer = the citizen (their own assertion); issuee = the
   recording scope (see make-stance-credential's note on signing).

   U: blinding nonce — see make-stance-credential. A distribution has a
   larger claim space than a position, but it is still enumerable for
   small target sets, so it gets the same treatment."
  (make-credential *schema-playnet-expression-stance*
                   citizen-aid governance-group-aid
                   (append
                    (u-claim u)
                    (list (cons 'domain        domain)
                          (cons 'expression-id expression-id)
                          (cons 'distribution  distribution)
                          (cons 'timestamp     timestamp)))))

(define* (make-ballot-snapshot-credential governance-group-aid
                                           domain proposal-id franchise
                                           snapshot-said opened-at
                                           #:key
                                           (description #f)
                                           (voice-snapshot-entries '())
                                           (citizen-registry-aids '()))
  "Governance group anchors the frozen voice-share weights at ballot open.
   DOMAIN tags the ballot kind ('policy, 'recomposition, …).
   voice-snapshot-entries: list of (citizen-id voice-share resolved-delegation)
                           where resolved-delegation is a list of
                           (delegate-aid fraction mandate-spec-or-#f).
                           Enough to reconstruct the ballot.
   citizen-registry-aids: list of citizen AIDs known to this ballot."
  (make-credential *schema-playnet-ballot-snapshot*
                   governance-group-aid governance-group-aid
                   (list (cons 'domain               domain)
                         (cons 'proposal-id           proposal-id)
                         (cons 'franchise             franchise)
                         (cons 'snapshot-said         snapshot-said)
                         (cons 'opened-at             opened-at)
                         (cons 'description           description)
                         (cons 'voice-snapshot-entries voice-snapshot-entries)
                         (cons 'citizen-registry-aids citizen-registry-aids))))

(define* (make-tally-result-credential governance-group-aid
                                       domain proposal-id franchise
                                       winner tally-data
                                       abstain-weight closed-at
                                       #:key (ballot-snapshot-said #f))
  "Governance group signs the final ballot decision — auditable proof.
   DOMAIN tags the ballot kind ('policy, 'recomposition, …).

   Per §4.9 migration: BALLOT-SNAPSHOT-SAID, when supplied, becomes an
   `e`-block NI2I edge so verifiers can walk tally → snapshot directly.
   The `proposal-id` claim is retained for backwards compatibility."
  (let ((edges (if ballot-snapshot-said
                   (list (cons 'ballot-snapshot
                               (make-edge ballot-snapshot-said
                                          #:operator 'NI2I
                                          #:schema *schema-playnet-ballot-snapshot*)))
                   '())))
    (make-credential *schema-playnet-tally-result*
                     governance-group-aid governance-group-aid
                     (list (cons 'domain         domain)
                           (cons 'proposal-id    proposal-id)
                           (cons 'franchise      franchise)
                           (cons 'winner         winner)
                           (cons 'tally-data     tally-data)
                           (cons 'abstain-weight abstain-weight)
                           (cons 'closed-at      closed-at))
                     edges)))


(define* (make-recomposition-ratification-credential
          scope-aid proposal-type proposal-spec
          ballot-said tally
          #:key (threshold 0.5)
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
                                 #:schema *schema-playnet-ballot-snapshot*)))))
    (make-credential *schema-playnet-recomposition-ratification*
                     effective-issuer effective-issuer
                     claims
                     edges
                     #:signing-keypair signing-keypair)))

;; What the store knows of this family's schemas: the claims it indexes for
;; O(1) lookup, and the claim the observation time stands under. Registered
;; here at load, so a module that imports one family finds its credentials.
(register-schema-claims!
 `((,*schema-playnet-stance*                     (domain proposal-id)          timestamp)
   (,*schema-playnet-expression-stance*          (domain expression-id)        timestamp)
   (,*schema-playnet-ballot-snapshot*            (domain proposal-id)          opened-at)
   (,*schema-playnet-tally-result*               (domain proposal-id)          closed-at)
   (,*schema-playnet-recomposition-ratification* (proposal-type proposal-spec) ratified-at)))
