;;; credentials.scm — the First Person / OpenVTC credentials as KERI ACDCs
;;;
;;; OpenVTC (github.com/OpenVTC/openvtc, Rust, DID/VC-based) defines the
;;; First Person credential set: personhood (PHC), verifiable relationship
;;; (VRC), contact points (R-card channels), authorized issuers and device
;;; authorization. This module is that set rendered as ACDCs over KERI —
;;; the schema identifiers and the pure-data constructors. Verification
;;; (liveness, root chaining, the trust triangle) is (playnet keri first-person
;;; predicates); the parity pin against upstream is
;;; docs/planning/identity/openvtc-parity.md.
;;;
;;; Every constructor lives under the two SAID disciplines stated in
;;; (playnet credentials …): emission is frozen (new fields are
;;; append-only and emitted only when set), and a re-mint of an existing fact
;;; passes the fact's own timestamp.

(define-module (playnet keri first-person credentials)
  #:use-module (playnet keri acdc)
  #:use-module (playnet keri citizen-sig)
  #:export (*schema-playnet-personhood* *schema-playnet-relationship*
            *schema-playnet-contact-point* *schema-playnet-authorized-issuer*
            *schema-playnet-device-authorization*
            make-device-authorization-credential make-authorized-issuer-credential
            make-personhood-credential make-relationship-credential
            *contact-point-kinds* contact-point-kind? contact-point-identifying?
            make-contact-point-credential contact-point-binding-fields
            contact-point-acceptable?
            *schema-playnet-body-role* *body-roles*
            make-body-role-credential body-role-credential-with-block
            body-role-credential-valid?))

(define *schema-playnet-personhood*              "playnet-personhood/v1")
(define *schema-playnet-relationship*            "playnet-relationship/v1")
(define *schema-playnet-contact-point*           "playnet-contact-point/v1")
(define *schema-playnet-authorized-issuer*       "playnet-authorized-issuer/v1")
(define *schema-playnet-device-authorization*    "playnet-device-authorization/v1")
(define *schema-playnet-body-role*               "playnet-body-role/v1")

;; =========================================================================
;; First-Person layer: Personhood Credential (PHC) + Relationship (VRC)
;; =========================================================================
;;
;; PHC: targeted ACDC anchoring the vertical link ecosystem → unique person.
;; Issuer = ecosystem-AID (federation / governance group). Holder = citizen
;; AID. Uniqueness-per-person is an off-protocol enrollment discipline — the
;; TEL logs issuance but does not attest physical-subject uniqueness
;; (see docs/first-person/first-person-intent-mapping.md, I1/I2).
;;
;; VRC: mutual peer attestation. Issued in *pairs* (one each direction) over
;; an authenticated pairwise channel. The `issuer-phc-said` claim is the
;; I2I-style edge pointing at the issuer's own PHC in the same ecosystem;
;; trust-triangle verification walks from VRC → PHC on both sides.

;; ── Device authorization: the root authorizes one device's key ──────────
;; PERSON-AID is the citizen's KEL-backed AID (the cold root); DEVICE-AID is
;; the `B`-prefixed (non-transferable) encoding of the device's own Ed25519
;; public key — self-certifying, no KEL. The credential is the ONE fact a
;; gateway needs to accept the device key as the person's for everyday acts:
;; challenge-response auth and the SAID signatures on commitments, claims,
;; stances and witness statements. TIER names how the device holds its key
;; ("hardware" = WebAuthn PRF, "software" = non-extractable WebCrypto).
;; `expires-at` (epoch seconds or #f) and `active` follow cred-live? so a
;; device is retired by revocation or by its own horizon. The signature is the
;; root's current KEL key over the SAID (client-signed: the browser derives the
;; SAID with compute-said and signs; the gateway rebuilds and verifies).
(define* (make-device-authorization-credential person-aid device-aid label tier
                                               enrolled-at
                                               #:key (expires-at #f)
                                                     (active #t)
                                                     (doors #f)
                                                     (signing-keypair #f))
  "DOORS, when a list of door names (strings), is the allowlist this device
   may call — an outside interface holds only the doors it needs. Absent, the
   device reaches every device-level door. The claim is present only when
   set, so credentials issued before it keep their SAIDs."
  (make-credential *schema-playnet-device-authorization*
                   person-aid
                   device-aid
                   (append
                    (list (cons 'person-aid  person-aid)
                          (cons 'device-aid  device-aid)
                          (cons 'label       label)
                          (cons 'tier        tier)
                          (cons 'enrolled-at enrolled-at)
                          (cons 'expires-at  expires-at)
                          (cons 'active      active))
                    (if doors (list (cons 'doors doors)) '()))
                   '()
                   #:signing-keypair signing-keypair))

(define* (make-authorized-issuer-credential root-aid ecosystem-aid blessed-at
                                            #:key (active #t)
                                                  (expires-at #f)
                                                  (signing-keypair #f)
                                                  (multisig-signers #f))
  "Authorized-Issuer Credential (AIC) — the trust-registry root's blessing
   that ECOSYSTEM-AID may issue Personhood Credentials. This is the FPP
   'trust registry = registry AID + TEL of authorized-issuer ACDCs'
   primitive (fpp-on-keri.md §2): the root does NOT vouch for people, it
   authorizes the ecosystems that do — so every PHC provably chains to one
   root while portable multi-ecosystem personhood is preserved.

   ROOT-AID is both issuer and (per the design) the Universal Commune's
   group AID — the singleton at the top of the scope tree. HOLDER is the
   ECOSYSTEM-AID being authorized. `active`/`expires-at` follow the same
   liveness semantics as a PHC so a root can retire an ecosystem's
   authority (cred-live-at?). SIGNING-KEYPAIR attaches the root's Ed25519
   signature over the SAID so a foreign verifier can confirm the blessing
   without trusting the store."
  (make-credential *schema-playnet-authorized-issuer*
                   root-aid
                   ecosystem-aid
                   (list (cons 'root-aid      root-aid)
                         (cons 'ecosystem-aid ecosystem-aid)
                         (cons 'blessed-at    blessed-at)
                         (cons 'active        active)
                         (cons 'expires-at    expires-at))
                   '()
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))

(define* (make-personhood-credential ecosystem-aid holder-aid enrolled-at
                                     #:key (enrollment-evidence-digest #f)
                                           (active #t)
                                           (sponsor-aid #f)
                                           (expires-at #f)
                                           (witness-edges '())
                                           (issuer-authz-said #f)
                                           (signing-keypair #f))
  "Personhood Credential (PHC). ISSUER and ECOSYSTEM-AID are the same AID —
   the ecosystem's governance group asserts that HOLDER-AID is a unique
   real person within this ecosystem.
   ENROLLMENT-EVIDENCE-DIGEST: opaque hash of the off-protocol evidence
   bundle (ID checks, in-person vouch, etc.); never the evidence itself.
   SPONSOR-AID: when set via `^scope invite`, names the existing PHC-holder
   who introduced this person — used for fan-out-cap and graph analytics.
   EXPIRES-AT: optional epoch/time after which the PHC is no longer live;
   #f = perpetual (founder default). Re-enrollment refreshes by issuing
   a new PHC and revoking the old.
   WITNESS-EDGES: alist of (witness-name . edge) entries that an
   `^enrollment-ceremony` attaches as cryptographic evidence of k-of-n
   in-person attestation (each edge NI2I to a witness's own PHC).
   ISSUER-AUTHZ-SAID: SAID of the ecosystem's Authorized-Issuer Credential
   (the root's blessing), attached as an **ACDC edge** named `issuer-authz`
   with the I2I operator. I2I here binds THIS PHC's issuer (the ecosystem)
   to be the HOLDER of the referenced AIC — so a foreign verifier can walk
   PHC → AIC → root end-verifiably, without trusting a store index. This is
   the structural half of `issuer-chains-to-root?`.
   SIGNING-KEYPAIR: when provided, attaches an Ed25519 signature over
   the SAID (CESR qb64 under code \"0B\") so verifiers can check the
   ecosystem actually issued this PHC without trusting the store."
  (make-credential *schema-playnet-personhood*
                   ecosystem-aid
                   holder-aid
                   (list (cons 'ecosystem-aid               ecosystem-aid)
                         (cons 'enrolled-at                 enrolled-at)
                         (cons 'enrollment-evidence-digest  enrollment-evidence-digest)
                         (cons 'active                      active)
                         (cons 'sponsor-aid                 sponsor-aid)
                         (cons 'expires-at                  expires-at))
                   (append
                     (if issuer-authz-said
                         (list (cons 'issuer-authz
                                     (make-edge issuer-authz-said
                                                #:operator 'I2I
                                                #:schema *schema-playnet-authorized-issuer*)))
                         '())
                     witness-edges)
                   #:signing-keypair signing-keypair))

(define* (make-relationship-credential issuer-aid subject-aid
                                       relationship-type issuer-phc-said
                                       issued-at
                                       #:key (subject-persona #f)
                                             (expires-at #f)
                                             (signing-keypair #f))
  "Verifiable Relationship Credential (VRC). ISSUER-AID vouches for
   SUBJECT-AID under RELATIONSHIP-TYPE (symbol: 'trust, 'colleague,
   'guardian, 'delegate, …). Mutual relationships require two VRCs,
   one each direction.

   ISSUER-PHC-SAID: SAID of the issuer's PHC in the reference
   ecosystem, attached as an **ACDC edge** named `issuer-phc` with the
   I2I operator (ACDC §8.6). The edge constrains this VRC's issuer to
   be the holder of the referenced PHC; combined with the verifier's
   ecosystem check, it implements the FPP I6 trust-triangle
   Sybil-resistance property structurally rather than by naming
   convention."
  (make-credential *schema-playnet-relationship*
                   issuer-aid
                   subject-aid
                   (list (cons 'relationship-type  relationship-type)
                         (cons 'subject-persona    subject-persona)
                         (cons 'issued-at          issued-at)
                         (cons 'expires-at         expires-at))
                   (list (cons 'issuer-phc
                               (make-edge issuer-phc-said
                                          #:operator 'I2I
                                          #:schema *schema-playnet-personhood*)))
                   #:signing-keypair signing-keypair))


;; =========================================================================
;; Contact points — user-held, presented to gateways as custody
;; =========================================================================
;;
;; A contact point is how to REACH a person on some channel. It used to
;; live only in the gateway's member record and recipient-registry, which
;; made it gateway-local: the AID travels to any gateway (witnesses, OOBI)
;; while every way of reaching the person stayed behind. Backwards from the
;; rest of the architecture, and the same defect as the GDPR one — the
;; gateway was acting as SYSTEM OF RECORD for data it should merely hold in
;; custody.
;;
;; As a self-issued ACDC the user is the holder and a gateway receives a
;; revocable DISCLOSURE. That makes portability native (present it anywhere)
;; and erasure native (revoke, or decline to re-present). Same custody/rights
;; split used for socialized resources: the gateway is a custodian-scope,
;; never the primary-accountable holder.
;;
;; Blinded from day one. This schema is greenfield, so unlike the retrofitted
;; governance credentials it carries a `u` nonce from its first issuance —
;; without one, an email address has a small enough claim space that the SAID
;; is invertible by rainbow-table attack (ACDC §4.1), which would leak the
;; address to anyone holding a SAID.
;;
;; See docs/legal/gdpr-analysis.md §"Phase 1b".

;; Channel kinds accepted for a binding. Mirrors (playnet notify recipient)'s
;; taxonomy — duplicated as data rather than imported so the pure-data
;; credential layer keeps no dependency on the actor layer. The ordering
;; encodes the minimisation preference: the opaque-address channels first
;; (an lxmf address or push endpoint is a cryptographic identifier, not PII),
;; the inherently-identifying ones last.
(define *contact-point-kinds* '(lxmf push browser matrix telegram email))

(define (contact-point-kind? k)
  (and (memq k *contact-point-kinds*) #t))

;; Whether a kind's ctx is inherently identifying (an address that names a
;; person off-network) as opposed to an opaque routing key. Drives the
;; minimisation preference in the UI and the retention policy on the
;; gateway side; NOT a security boundary.
(define (contact-point-identifying? k)
  (and (memq k '(email telegram matrix)) #t))

(define* (make-contact-point-credential subject-aid kind ctx
                                        #:key (style 'terse)
                                              (issued-at #f)
                                              (expires-at #f)
                                              (u 'auto)
                                              (signing-keypair #f))
  "Self-issued contact-point ACDC: SUBJECT-AID declares that it can be
   reached on KIND at CTX. Issuer = holder = SUBJECT-AID — nobody else
   asserts how to reach you.

   KIND is one of *contact-point-kinds*. CTX is the transport destination
   (lxmf address, push device-id, matrix room, email address, …). STYLE is
   the render the channel wants ('terse | 'rich | 'markdown), matching
   (playnet notify recipient)'s <binding>.

   EXPIRES-AT: optional; a lapsed contact point is treated as unbindable by
   the same live/expiry convention as custody attestations and skills, so
   `*-cred-live?` transfers unchanged.

   U: blinding nonce, minted by default — see the note above on why this
   schema is private from its first issuance rather than retrofitted.

   SIGNING-KEYPAIR: the subject's own keypair. A gateway MUST verify this
   before binding, or anyone could redirect another AID's notifications."
  (make-credential *schema-playnet-contact-point*
                   subject-aid subject-aid
                   (append
                    (u-claim u)
                    (list (cons 'kind       kind)
                          (cons 'ctx        ctx)
                          (cons 'style      style)
                          (cons 'issued-at  (or issued-at (iso-utc-now)))
                          (cons 'expires-at expires-at)))
                   '()
                   #:signing-keypair signing-keypair))

(define (contact-point-binding-fields cred)
  "The (kind ctx style) triple a gateway feeds to ^recipient-registry's
   `bind`, or #f when CRED isn't a usable contact point. Pure: does no
   verification — callers MUST run `contact-point-acceptable?` first."
  (and (equal? (cred-schema cred) *schema-playnet-contact-point*)
       (list (cred-claim cred 'kind)
             (cred-claim cred 'ctx)
             (or (cred-claim cred 'style) 'terse))))

(define* (contact-point-acceptable? cred presenter-aid #:key (now #f))
  "Is CRED a contact point PRESENTER-AID is entitled to bind? Returns #t or
   a string naming the first failure — the same verdict shape the signup
   validators use.

   The security hinge is issuer = holder = presenter: without it, any caller
   could bind a channel under someone else's AID and redirect their
   notifications. Signature is checked when present so a gateway that stores
   the credential can prove later why it bound what it bound.

   NOW (epoch seconds) enables the expiry check; #f skips it."
  (cond
   ((not (equal? (cred-schema cred) *schema-playnet-contact-point*))
    "not a contact-point credential")
   ((not (equal? (cred-issuer cred) presenter-aid))
    "contact point not issued by the presenting AID")
   ((not (equal? (cred-holder cred) presenter-aid))
    "contact point not held by the presenting AID")
   ((not (contact-point-kind? (cred-claim cred 'kind)))
    (string-append "unknown channel kind: "
                   (let ((k (cred-claim cred 'kind)))
                     (if (symbol? k) (symbol->string k) "?"))))
   ((not (let ((c (cred-claim cred 'ctx)))
           (and (string? c) (not (string-null? c)))))
    "contact point has no destination (ctx)")
   ((not (equal? (cred-said cred) (cred-recompute-said cred)))
    "contact point SAID does not match its content")
   ((and (cred-signature cred)
         (not (verify-said-signature (cred-said cred)
                                     (cred-signature cred)
                                     presenter-aid)))
    "contact point signature does not verify under the presenting AID")
   ((and now (cred-claim cred 'expires-at)
         (let ((e (cred-claim cred 'expires-at)))
           (and (number? e) (> now e))))
    "contact point has expired")
   (else #t)))

(register-schema-claims!
 `((,*schema-playnet-personhood*   (ecosystem-aid sponsor-aid) enrolled-at)
   (,*schema-playnet-relationship* ()                          issued-at)))

;; =========================================================================
;; Body role: a body says who holds a role in it
;; =========================================================================
;;
;; A body is a k-of-n group AID of its stewards' dial AIDs (identity/
;; personhood/body-ceremony.scm); its roles, members and stewards are VF agent
;; relationships, and this credential is a PROJECTION of one such record,
;; minted on demand when a holder presents the role outside the fold. The
;; issuer is the body, so the signature is a multisig BLOCK the stewards
;; gather in their browsers — `((steward-aid . sig-qb64) …)` over the SAID —
;; attached after the fact with `body-role-credential-with-block`; the
;; constructor builds the credential unsigned and `make-credential`'s
;; server-keypair `#:multisig-signers` path stays what it is, since no
;; server holds a steward's key. A verifier reads the body's stewards and
;; quorum (its KEL's `k` and `kt`, or the body record) and asks
;; `body-role-credential-valid?`.

(define *body-roles* '(steward member officer))

(define* (make-body-role-credential body-aid holder-aid role since
                                    #:key (until #f) (quorum #f) (u 'auto))
  "The unsigned role credential: BODY-AID says HOLDER-AID holds ROLE (one of
   *body-roles*, a symbol) since SINCE (ISO-8601 or epoch seconds). UNTIL
   and QUORUM (the body's k) are emitted when given. U is the blinding
   nonce, minted by default."
  (make-credential *schema-playnet-body-role*
                   body-aid holder-aid
                   (append
                    (u-claim u)
                    (list (cons 'role role)
                          (cons 'since since))
                    (if until (list (cons 'until until)) '())
                    (if quorum (list (cons 'quorum quorum)) '()))
                   '()))

(define (body-role-credential-with-block cred sig-block)
  "CRED carrying SIG-BLOCK, the stewards' signatures over its SAID."
  (cred-with-signature cred sig-block))

(define (body-role-credential-valid? cred steward-aids k)
  "#t when CRED is a body-role credential whose SAID commits to its content
   and whose block carries K valid signatures from distinct members of
   STEWARD-AIDS."
  (let ((sig (cred-signature cred)))
    (and (equal? (cred-schema cred) *schema-playnet-body-role*)
         (pair? sig)
         (cred-said-consistent? cred)
         (verify-said-multisig (cred-said cred) sig steward-aids k))))
