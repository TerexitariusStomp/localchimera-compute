;;; credentials/keys.scm — what a scope's keys rest on: the bran share and the witness assignment, with the witness-quorum audit.
;;;
;;; One family of the playnet credential catalogue (docs/planning/codebase-layout.md
;;; §6); the bundle a constructor returns is described once, in credentials/registry.scm.

(define-module (playnet credentials keys)
  #:use-module (playnet keri acdc)
  #:use-module (srfi srfi-1)
  #:export (*schema-playnet-bran-share*
            *schema-playnet-witness-assignment*
            audit-witness-quorum-independence
            count-witness-attestors
            make-bran-share-credential
            make-witness-assignment-credential
            witness-assignments-for-federation))
(define *schema-playnet-bran-share*             "playnet-bran-share/v1")

;; Witness assignment: a federation issues this credential to a member
;; AID to attest that the member operates a specific KERIA witness on
;; the federation's behalf. The auditor uses the set of these to verify
;; that toad-many witnesses are run by ≥toad-many distinct members
;; (no single operator controls quorum). See
;; docs/governance/FEDERATION-WITNESSES.md for the design and the
;; bootstrap/recovery flows that read these credentials.
(define *schema-playnet-witness-assignment*
  "playnet-witness-assignment/v1")

(define-credential (make-bran-share-credential issuer-group-aid holder-aid share-index threshold total-shares share-data-hex)
  "Shamir bran share: issuer = governance group, holder = member.
   share-data-hex is the hex-encoded share bytevector.

   SUBJECT-AID identifies which scope's bran this share is for. When
   #f (legacy bootstrap shares for the maintainer-governance bran),
   the claim is omitted. For autonomous-signer scope keys, it MUST be
   supplied so multiple scopes' shares don't collide in one store
   (see keys/bran-custody.scm).

   SIGNING-KEYPAIR/MULTISIG-SIGNERS: the issuing governance group's own
   signature over this share — the same key material a share, once
   reconstituted, would let someone impersonate, so an unsigned share
   ACDC is a strictly weaker integrity guarantee than the credentials
   issued right alongside it in a bootstrap ceremony. #f leaves it
   unsigned (synthetic/test mode)."
  *schema-playnet-bran-share*
  #:key ((subject-aid #f))
  #:signed (keypair multisig)
  #:claims (share-index threshold total-shares (share-data share-data-hex) (? subject-aid)))

;; =========================================================================
;; Witness assignment — federation-member operation of KERI witnesses
;; =========================================================================
;;
;; Issued by a federation's governance group AID to a member AID,
;; attesting that the member runs a specific KERIA witness identified
;; by its AID + OOBI. The bootstrap helper in (playnet keri witnesses-
;; federation) reads these credentials to resolve OOBIs into the
;; local KERIA agent. The auditor walks them to check that the toad-
;; many witnesses are operated by distinct members.
;;
;; Sharing a witness across federations is per-federation issuance:
;; each federation that wants the witness in its quorum issues its
;; own assignment. KERI witnesses aren't federation-aware — the
;; cleanest model is the truthful one. See
;; docs/governance/FEDERATION-WITNESSES.md.
;;
;; Claims:
;;   witness-aid   string  — the witness's KERIA AID
;;   witness-oobi  string  — resolvable OOBI URL
;;   group-aid     string  — federation's group AID this witness serves
;;   assigned-at   integer — epoch seconds (timestamp claim)

(define-credential (make-witness-assignment-credential federation-aid member-aid witness-aid witness-oobi group-aid assigned-at)
  "Federation-issued attestation that MEMBER-AID runs the KERIA witness
   identified by WITNESS-AID + WITNESS-OOBI on behalf of GROUP-AID.
   FEDERATION-AID is the issuer; MEMBER-AID is the holder."
  *schema-playnet-witness-assignment*
  #:signed (keypair)
  #:claims (witness-aid witness-oobi group-aid assigned-at)
  #:index (witness-aid)
  #:time assigned-at)

(define (witness-assignments-for-federation federation-aid all-creds)
  "Filter ALL-CREDS down to the non-revoked witness-assignment
   credentials issued by FEDERATION-AID. Each federation maintains
   its own assignment set; cross-federation reuse is achieved by each
   federation issuing its own assignment to the same operator for
   the same witness AID — the operator runs one witness, multiple
   federations independently attest to it. See
   docs/governance/FEDERATION-WITNESSES.md § *Sharing witnesses
   across federations*."
  (filter (lambda (c)
            (and (equal? (cred-schema c) *schema-playnet-witness-assignment*)
                 (equal? (cred-issuer c) federation-aid)
                 (not (cred-revoked? c))))
          all-creds))

(define (count-witness-attestors federation-aid all-creds)
  "Number of distinct members holding non-revoked witness-assignment
   credentials from FEDERATION-AID. Use as a governance dashboard
   pre-check — \"have we issued enough assignments to even attempt
   quorum?\" — separate from the cryptographic
   audit-witness-quorum-independence below."
  (length (delete-duplicates
           (map cred-holder
                (witness-assignments-for-federation federation-aid all-creds)))))

(define (audit-witness-quorum-independence federation-aid toad all-creds
                                           kel-witness-aids)
  "Return #t iff the witnesses ACTUALLY in FEDERATION-AID's group KEL
   `b` list (per KERI spec Table 4) map — via the federation's own
   witness-assignment ACDCs — to ≥TOAD distinct operating members.

   The truthful security predicate. Only KEL backers receipt; off-KEL
   assignments don't count (they're metadata without a receipt slot),
   so we intersect the assignments with the live backer set before
   counting distinct operators.

   Set-on-holder semantics: a member running multiple witnesses still
   counts as one operator — we care about operator coercion, not
   witness count.

   KEL-WITNESS-AIDS is required and not optional: the caller must
   query KERIA for the federation's group AID state and pass its
   `b` field. This forces every audit call to consult the live KEL
   rather than silently degrading into a credential-only check.
   For the cheap dashboard 'have we issued enough?' question, use
   `count-witness-attestors` instead.

   TOAD is typically `(keri-toad-for-count N)` where N is the
   federation's KEL backer count (Table 4 field `bt`)."
  (let* ((assignments
          (witness-assignments-for-federation federation-aid all-creds))
         (active
          (filter (lambda (c)
                    (member (cred-claim c 'witness-aid) kel-witness-aids))
                  assignments))
         (distinct-operators
          (delete-duplicates (map cred-holder active))))
    (>= (length distinct-operators) toad)))

;; What the store knows of this family's schemas: the claims it indexes for
;; O(1) lookup, and the claim the observation time stands under. Registered
;; here at load, so a module that imports one family finds its credentials.

