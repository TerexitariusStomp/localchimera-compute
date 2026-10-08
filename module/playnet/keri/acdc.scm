;;; acdc.scm — the ACDC data layer: credentials, edges, SAID binding, liveness
;;;
;;; A credential is an alist:
;;;
;;;   ((said       . string)        ; deterministic blake3 SAID (CESR "E")
;;;    (schema     . string)        ; schema identifier
;;;    (issuer     . string)        ; AID of issuer
;;;    (holder     . string)        ; AID of holder (subject)
;;;    (claims     . alist)         ; schema-specific (ACDC `a` block)
;;;    (edges      . alist)         ; ACDC `e` block — see `make-edge`
;;;    (signature  . string|#f)     ; CESR Ed25519 over the SAID, or a multisig block
;;;    (revoked?   . boolean))
;;;
;;; Edges follow ACDC §8: a chained reference from this credential to
;;; another by SAID, with an optional operator constraining the chain:
;;;   n — SAID of the target credential (required)
;;;   o — operator symbol: 'I2I (Issuer-to-Issuee), 'NI2I, or #f
;;;   s — target schema identifier (optional; informational only)
;;; The SAID folds the edge block in, so any edge change changes the SAID.
;;;
;;; Everything here is pure data over (playnet keri said-portable)'s
;;; compute-said: schema-agnostic, actor-free, and the base every schema
;;; layer builds on — (playnet openvtc credentials) for the First Person /
;;; OpenVTC credentials, (playnet governance credentials) for playnet's own.

(define-module (playnet keri acdc)
  #:use-module (playnet keri cesr)
  #:use-module (playnet keri said)
  #:use-module (playnet keri crypto-primitives)
  #:use-module ((playnet utils clock)
                #:select (now civil->instant instant->civil instant->unix
                          window-close-epoch))
  #:export (make-credential cred-with-signature credential-preimage-fields
            cred-said cred-schema cred-issuer cred-holder cred-claims cred-edges
            cred-signature cred-revoked? cred-claim cred-edge
            cred-with-revoked cred-recompute-said cred-said-consistent?
            make-edge edge-target edge-operator edge-schema edge-i2i-holds?
            blinding-nonce u-claim iso-utc-now
            register-timestamp-claims! timestamp-claim-for
            register-claim-indexes! indexed-claims-for
            parse-time-value cred-timestamp
            cred-live?))

;; =========================================================================
;; Generic credential constructor
;; =========================================================================

(define* (make-credential schema issuer holder claims
                          #:optional (edges '())
                          #:key (signing-keypair #f) (multisig-signers #f))
  "Returns the credential alist. SAID is deterministic from content
   including the edge block (ACDC §8 SAID-covers-edges invariant).

   When SIGNING-KEYPAIR is supplied (an Ed25519 keypair whose public
   half matches ISSUER's \"D\" or \"B\" AID prefix), a CESR-qb64
   Ed25519 signature over the SAID bytes is attached as the
   `signature` field. Verifiers can then check authenticity with
   `verify-said-signature` against the issuer AID.

   When MULTISIG-SIGNERS is supplied (a list of (member-aid . keypair))
   the ISSUER is a k-of-n governance GROUP AID, and the `signature` field
   is instead a multisig block — one member signature each. Verifiers use
   `cred-multisig-valid?` with the group's member set + threshold."
  (let* ((said (compute-said issuer holder schema claims edges))
         ;; the signing module is resolved on a host when a credential is signed; a
         ;; page's build carries no signer here, and signing there says so
         (citizen (cond-expand
                   (guile (lambda (sym) (module-ref (resolve-interface
                                                     '(playnet keri citizen-sig)) sym)))
                   (else (lambda (sym) (lambda _ (error "a credential is signed on a host" sym))))))
         (sig  (cond
                (multisig-signers ((citizen 'sign-said-multisig) said multisig-signers))
                (signing-keypair  ((citizen 'sign-said) said signing-keypair))
                (else #f))))
    (list (cons 'said      said)
          (cons 'schema    schema)
          (cons 'issuer    issuer)
          (cons 'holder    holder)
          (cons 'claims    claims)
          (cons 'edges     edges)
          (cons 'signature sig)
          (cons 'revoked?  #f))))

(define (cred-with-signature c sig)
  "Return a copy of credential C with its `signature` field replaced by SIG.
   For callers that can't hold the raw signing keypair (it's encapsulated
   inside an actor — a `sign-said` method on that actor, which signs a
   SAID without ever exporting the keypair) but can ask that actor to sign
   this credential's SAID after the fact: build the credential unsigned via
   make-*-credential (signature stays #f, the SAID itself doesn't depend on
   the signature), get SIG from ($ scope 'sign-said (cred-said c)), then
   attach it here. Cheaper than threading a keypair through every caller."
  (map (lambda (p) (if (eq? (car p) 'signature) (cons 'signature sig) p)) c))

;; ── Client-side signing protocol (generic over any credential) ──────────────
;;
;; A credential whose ISSUER is a party the server can't sign for — a citizen
;; (stance, delegation) — is only a conformant ACDC when that party's own
;; controller signs it, and the key is client-side. The protocol is one shape
;; for every such credential:
;;
;;   1. server builds the exact credential it would issue (from the client's
;;      intent + the fields the server is authoritative for), and returns its
;;      SAID-relevant fields via `credential-preimage-fields`;
;;   2. the client re-derives the SAID with the SHARED compute-said (so it is
;;      not blind-signing) and signs it;
;;   3. server rebuilds the identical credential from the client's echoed intent,
;;      and issues it iff `client-signature-ok?` holds.
;;
;; The rebuild-from-echoed-intent is the security hinge: the SAID commits to the
;; position/delegate/etc., so a signature can't be retargeted, and the caller
;; AID is session-bound so it can't be forged as another party.

(define (credential-preimage-fields cred)
  "The SAID-relevant fields of CRED — everything a client needs to re-derive the
   SAID (compute-said issuer holder schema claims edges) before signing. Generic:
   the preimage for ANY client-signed credential is exactly this."
  (list (cons 'schema (cred-schema cred))
        (cons 'issuer (cred-issuer cred))
        (cons 'holder (cred-holder cred))
        (cons 'claims (cred-claims cred))
        (cons 'edges  (cred-edges cred))))

(define (cred-said c)      (assq-ref c 'said))
(define (cred-schema c)    (assq-ref c 'schema))
(define (cred-issuer c)    (assq-ref c 'issuer))
(define (cred-holder c)    (assq-ref c 'holder))
(define (cred-claims c)    (assq-ref c 'claims))
(define (cred-edges c)     (or (assq-ref c 'edges) '()))
(define (cred-signature c) (assq-ref c 'signature))
(define (cred-revoked? c)  (assq-ref c 'revoked?))
(define (cred-claim c key) (assq-ref (cred-claims c) key))
(define (cred-edge c name) (assq-ref (cred-edges c) name))

(define (cred-with-revoked c flag)
  "Return a copy of C with its `revoked?` field set to FLAG. Every
   credential the constructors above mint carries the field from birth, so
   replacing it in place is the common case — but issue-credential (the
   gateway door) accepts a caller-built alist, not only a constructor's, so
   a credential missing the field entirely is a real shape to defend: a
   map-replace over an absent key is a silent no-op that reads as success
   while leaving the credential exactly as revocable as before."
  (if (assq 'revoked? c)
      (map (lambda (entry) (if (eq? (car entry) 'revoked?) (cons 'revoked? flag) entry)) c)
      (append c (list (cons 'revoked? flag)))))

(define (cred-recompute-said c)
  "Re-derive C's SAID from its OWN content the same way `compute-said`
   did at construction time. A credential whose stored `said` differs
   from this was tampered after issuance (or never validly SAID'd)."
  (compute-said (cred-issuer c) (cred-holder c) (cred-schema c)
                (cred-claims c) (cred-edges c)))

(define (cred-said-consistent? c)
  "#t iff C's stored SAID actually commits to C's current content.

   This is the precondition for trusting ANY signature over the SAID.
   Per ACDC §2.5 (docs/keri/ACDC.md): a signature on a SAID is a
   commitment to the block *only when the SAID was derived from the
   block*. A verifier that accepts a wire-supplied `d` and checks the
   issuer signed `d`, but never re-derives `d` from the presented
   issuer/holder/claims/edges, has verified nothing about the content —
   an attacker can graft a validly-signed `d`+signature onto swapped
   attributes (e.g. a foreign holder AID) and pass a naive check.
   Re-deriving closes that gap.

   This is the SINGLE seam for SAID-derivation compatibility. Today
   there is one scheme (canonical/order-independent `compute-said`), so
   the check is a plain equality. If the derivation ever changes in a
   breaking way, do NOT accumulate 'try every historical ordering' here
   — carry an explicit derivation-version on the credential and dispatch
   on it in this one function, so acceptance stays deterministic."
  (equal? (cred-said c) (cred-recompute-said c)))

;; ── ACDC edges (ACDC §8) ─────────────────────────────────────────────────

(define* (make-edge target-said #:key (operator #f) (schema #f))
  "Construct an ACDC edge spec: a reference to TARGET-SAID with an
   optional OPERATOR and target SCHEMA.

   OPERATOR ∈ {#f, 'I2I, 'NI2I}:
     I2I  — Issuer-to-Issuee: the issuer of THIS credential must be
            the issuee (holder) of the target credential.
     NI2I — Non-Issuer-to-Issuee: no issuer/issuee constraint.
     #f   — unspecified; verifier applies default (I2I per ACDC §8.6)."
  `((n . ,target-said)
    ,@(if operator (list (cons 'o operator)) '())
    ,@(if schema   (list (cons 's schema))   '())))

(define (edge-target edge)   (assq-ref edge 'n))
(define (edge-operator edge) (assq-ref edge 'o))
(define (edge-schema edge)   (assq-ref edge 's))

(define (edge-i2i-holds? edge cred target-cred)
  "Verify an I2I edge: this CRED's issuer must equal TARGET-CRED's holder.
   For edges without an explicit operator, #f or 'I2I both mean I2I."
  (and target-cred
       (equal? (edge-target edge) (cred-said target-cred))
       (case (edge-operator edge)
         ((#f I2I) (equal? (cred-issuer cred) (cred-holder target-cred)))
         ((NI2I)   #t)
         (else #f))))


;; ── Blinding nonce (ACDC §2.7 `u`, interim placement) ────────────────────
;;
;; `compute-said` folds the whole claims alist into the digest. For a
;; credential whose claim space is small — a stance is (domain,
;; proposal-id, position, timestamp) where position is one of a handful
;; of symbols, the ids are known and the timestamp is bounded by the
;; ballot window — the power set is small enough to enumerate. That makes
;; the SAID invertible by rainbow-table attack (ACDC §4.1), so **holding a
;; stance SAID is equivalent to learning how that citizen voted**, without
;; ever seeing the credential body.
;;
;; A high-entropy nonce in the claims restores the property the spec gets
;; from a `u` field: the SAID becomes a blinded commitment. 128 bits under
;; CESR code "0A", matching the spec's `u` encoding.
;;
;; DIVERGENCE, deliberate: the spec places `u` at block or top level, not
;; inside the attribute set. We have no block structure to place it in —
;; `compute-said` hashes a flat (issuer holder schema claims edges) tuple
;; (keri/said-portable.scm:84). Putting the nonce in `claims` buys the
;; blinding property at ZERO blast radius: the SAID scheme is unchanged
;; and every existing credential keeps its SAID. The conformant fix is
;; Phase 3 (section restructuring) — see docs/planning/legal/gdpr-analysis.md
;; §6.1 and PLAYNET-KERI-CONFORMANCE.md §2.7.
;; The `u` argument on the stance constructors is two-valued:
;;   'auto     — mint a fresh nonce (the default; what a new cast does)
;;   <string>  — use this exact nonce (the client-signed rebuild path,
;;               where the nonce must match what the client signed over)
;;
;; There is deliberately no "omit the nonce" option. `stance-preimage`
;; always mints one, so any client that signed a preimage necessarily
;; signed over a nonce; a nonce-less rebuild could only ever produce a
;; credential no signature matches. `cast-signed` rejects a missing nonce
;; explicitly rather than silently building an unverifiable credential.
(define (blinding-nonce)
  "128 bits of entropy as CESR qb64 under code \"0A\" (24 chars)."
  (cesr-bytes->qb64 "0A" (keri-crypto-random-bytes 16)))

(define (u-claim u)
  "The `u` entry for a claims alist. U is 'auto (mint) or an exact nonce."
  (list (cons 'u (if (eq? u 'auto) (blinding-nonce) u))))


;; ISO-8601 UTC timestamp helper. Use this at credential-issuance
;; boundaries so timestamps are timezone-stable across distributed
;; scopes.
(define (iso-utc-now)
  (instant->civil (now)))


;; =========================================================================
;; Timestamp claims
;; =========================================================================
;;
;; Schemas carry their observation time under different claim keys
;; (`enrolled-at`, `issued-at`, `closed-at`, …). Each schema layer registers
;; its own keys at load; an unregistered schema reads the `timestamp` claim.

(define %timestamp-claims (make-hash-table))

(define (register-timestamp-claims! alist)
  "Register ALIST of (schema-string . claim-key-symbol). Idempotent."
  (for-each (lambda (p) (hash-set! %timestamp-claims (car p) (cdr p))) alist))

(define (timestamp-claim-for schema)
  "The claim-key symbol under which SCHEMA stores its timestamp,
   defaulting to 'timestamp when unregistered."
  (hash-ref %timestamp-claims schema 'timestamp))

(define (parse-time-value raw)
  "Coerce a credential's timestamp claim onto the one clock.
   Accepts: #f (→ #f), numbers, numeric strings, ISO-8601 strings.
   An unparseable string reads as #f, never as 1970-01-01."
  (cond
    ((not raw) #f)
    ((number? raw) raw)
    ((string? raw)
     (or (string->number raw)
         (let ((epoch (or (civil->instant raw) 0)))
           (and (> epoch 0) epoch))))
    (else #f)))

(define (cred-timestamp cred)
  "CRED's schema-appropriate timestamp claim on the one clock, or #f."
  (parse-time-value (cred-claim cred (timestamp-claim-for (cred-schema cred)))))


;; =========================================================================
;; Claim indexes
;; =========================================================================
;;
;; A store indexes the claims a schema declares, for O(1) hot-path lookup
;; ("the PHCs of this ecosystem", "the commitment with this id"). Each schema
;; layer registers its own at load; an unregistered schema indexes nothing and
;; is reached through the by-schema / by-issuer / by-holder scans.

(define %claim-indexes (make-hash-table))

(define (register-claim-indexes! alist)
  "Register ALIST of (schema-string . (claim-key-symbol …)). Idempotent."
  (for-each (lambda (p) (hash-set! %claim-indexes (car p) (cdr p))) alist))

(define (indexed-claims-for schema)
  "The claim-key symbols to index for SCHEMA, or '() when none."
  (hash-ref %claim-indexes schema '()))


;; =========================================================================
;; Liveness
;; =========================================================================

(define* (cred-live? cred #:optional (now-epoch #f))
  "THE credential-liveness law — one reading for every schema. A credential
   is live iff: not revoked; not suspended (an `active` claim present and
   #f); and its window — `valid-until` or `expires-at`, whichever claim
   name the schema speaks — not closed. The window closes on
   window-close-epoch, the one temporal law: a timed boundary at
   its minute, a bare date at the END of its day, an unreadable window
   never closes. Custody attestations, skill recertification, ownership
   titles, PHCs and VRCs all read HERE. NOW-EPOCH: unix seconds, an ISO
   instant string, or #f for now."
  (let* ((claims (or (assq-ref cred 'claims) '()))
         (u      (window-close-epoch
                  (or (assq-ref claims 'valid-until)
                      (assq-ref claims 'expires-at))))
         (nowu   (cond ((number? now-epoch) now-epoch)
                       ((string? now-epoch)
                        (let ((i (civil->instant now-epoch)))
                          (if i (instant->unix i) (instant->unix (now)))))
                       (else (instant->unix (now))))))
    (and (not (assq-ref cred 'revoked?))
         (or (not (assq 'active claims)) (assq-ref claims 'active))
         (or (not u) (> u nowu)))))
