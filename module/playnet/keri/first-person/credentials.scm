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
            *schema-playnet-body* %usage-disclaimer %issuance-disclaimer
            make-body-credential
            *schema-playnet-body-role* *body-roles*
            make-body-role-credential body-role-credential-with-block))

(define *schema-playnet-personhood*              "playnet-personhood/v1")
(define *schema-playnet-relationship*            "playnet-relationship/v1")
(define *schema-playnet-contact-point*           "playnet-contact-point/v1")
(define *schema-playnet-authorized-issuer*       "playnet-authorized-issuer/v1")
(define *schema-playnet-device-authorization*    "playnet-device-authorization/v1")
(define *schema-playnet-body*                    "playnet-body/v1")
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
(define-credential (make-device-authorization-credential person-aid device-aid label tier enrolled-at)
  "DOORS, when a list of door names (strings), is the allowlist this device
   may call — an outside interface holds only the doors it needs. Absent, the
   device reaches every device-level door. The claim is present only when
   set, so credentials issued before it keep their SAIDs."
  *schema-playnet-device-authorization*
  #:key ((expires-at #f) (active #t) (doors #f))
  #:signed (keypair)
  #:claims (person-aid device-aid label tier enrolled-at expires-at active (? doors)))

(define-credential (make-authorized-issuer-credential root-aid ecosystem-aid blessed-at)
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
  *schema-playnet-authorized-issuer*
  #:key ((active #t) (expires-at #f))
  #:signed (keypair multisig)
  #:claims (root-aid ecosystem-aid blessed-at active expires-at))

(define-credential (make-personhood-credential ecosystem-aid holder-aid enrolled-at)
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
  *schema-playnet-personhood*
  #:key ((enrollment-evidence-digest #f) (active #t) (sponsor-aid #f) (expires-at #f) (witness-edges '()) (issuer-authz-said #f))
  #:signed (keypair)
  #:claims (ecosystem-aid enrolled-at enrollment-evidence-digest active sponsor-aid expires-at)
  #:edges ((? issuer-authz issuer-authz-said I2I *schema-playnet-authorized-issuer*) (@ witness-edges))
  #:index (ecosystem-aid sponsor-aid)
  #:time enrolled-at)

(define-credential (make-relationship-credential issuer-aid subject-aid relationship-type issuer-phc-said issued-at)
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
  *schema-playnet-relationship*
  #:key ((subject-persona #f) (expires-at #f))
  #:signed (keypair)
  #:claims (relationship-type subject-persona issued-at expires-at)
  #:edges ((issuer-phc issuer-phc-said I2I *schema-playnet-personhood*))
  #:index ()
  #:time issued-at)

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

(define-credential (make-contact-point-credential subject-aid kind ctx)
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
  *schema-playnet-contact-point*
  #:key ((style 'terse) (issued-at #f) (expires-at #f) (u 'auto))
  #:signed (keypair)
  #:holder subject-aid
  #:nonce u
  #:claims (kind ctx style (issued-at (or issued-at (iso-utc-now))) expires-at))

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

;; =========================================================================
;; Body: a scope admits a body — the Legal Entity credential's shape
;; =========================================================================
;;
;; The chain is the vLEI's (EGF v4.0): root AID → authorized issuer → the
;; entity's own credential, issued to its self-managed multisig AID → the
;; roles the entity issues to people. Here: root → AIC → BODY credential →
;; body-role credential. The body credential is issued by the scope that
;; admitted the body (its AID, signed with its keypair) to the body's k-of-n
;; group AID (identity/personhood/body-ceremony.scm), and chains to the
;; scope's AIC by the same `issuer-authz` I2I edge a personhood credential
;; carries, so a verifier anywhere walks body → AIC → root with SAID
;; resolution alone. `legal-ids` carries the body's registry identifiers
;; (`((lei . "…") (siren . "…"))`), the join key to a real LE vLEI the body
;; may present beside this one.
;;
;; The two rule texts a vLEI reader expects ride as claims; ACDC's `r`
;; section is their home once the compact-form migration happens.

(define %usage-disclaimer
  "This credential states that the named body was admitted by the issuing scope. It does not assert that the body is trustworthy, honest, reputable, solvent or compliant with any law, and reliance on it is at the relier's own judgement.")

(define %issuance-disclaimer
  "The issuing scope issued this credential to the named holder with reasonable care, following its own admission ceremony, and the facts it carries were accurate at the time of issuance. A later change in the body's standing is read from revocation, not from this text.")

(define-credential (make-body-credential ecosystem-aid body-aid admitted-at)
  "The body credential: ECOSYSTEM-AID (the admitting scope, the issuer) says
   BODY-AID (the body's group AID, the holder) is a body it admitted at
   ADMITTED-AT (ISO-8601 or epoch seconds). KIND (a symbol, the body class),
   JURISDICTION (a string), LEGAL-IDS (an alist scheme → id), QUORUM (the
   body's k) and EXPIRES-AT are emitted when given. ISSUER-AUTHZ-SAID, when
   given, is the SAID of the scope's Authorized-Issuer Credential, attached
   as the I2I edge `issuer-authz` — this credential's issuer must be that
   AIC's holder. U is the blinding nonce, minted by default. The usage and
   issuance disclaimers ride as claims on every body credential."
  *schema-playnet-body*
  #:key ((kind #f) (jurisdiction #f) (legal-ids #f) (quorum #f) (expires-at #f) (issuer-authz-said #f) (u 'auto))
  #:signed (keypair multisig)
  #:nonce u
  #:claims ((? kind) (? jurisdiction) (? legal-ids) (? quorum) admitted-at (? expires-at) (usage-disclaimer %usage-disclaimer) (issuance-disclaimer %issuance-disclaimer))
  #:edges ((? issuer-authz issuer-authz-said I2I *schema-playnet-authorized-issuer*))
  #:index ()
  #:time admitted-at)

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
;; server holds a steward's key. The role chains to the body credential by
;; the I2I edge `body` — the ECR's `le` edge: the role's issuer is the body
;; credential's holder. A verifier reads the body's stewards and quorum (its
;; KEL's `k` and `kt`, or the body record) and asks
;; `body-role-credential-valid?` (playnet keri first-person predicates),
;; which also walks the chain. `officer` is the official role the law names
;; (the OOR analogue); `steward` and `member` are the ECR analogue.

(define *body-roles* '(steward member officer))

(define-credential (make-body-role-credential body-aid holder-aid role since)
  "The unsigned role credential: BODY-AID says HOLDER-AID holds ROLE (one of
   *body-roles*, a symbol) since SINCE (ISO-8601 or epoch seconds). UNTIL
   and QUORUM (the body's k) are emitted when given. U is the blinding
   nonce, minted by default. BODY-CRED-SAID, when given, is the SAID of the
   body's own credential, attached as the I2I edge `body`."
  *schema-playnet-body-role*
  #:key ((until #f) (quorum #f) (u 'auto) (body-cred-said #f))
  #:signed ()
  #:nonce u
  #:claims (role since (? until) (? quorum))
  #:edges ((? body body-cred-said I2I *schema-playnet-body*))
  #:index ()
  #:time since)

(define (body-role-credential-with-block cred sig-block)
  "CRED carrying SIG-BLOCK, the stewards' signatures over its SAID."
  (cred-with-signature cred sig-block))

