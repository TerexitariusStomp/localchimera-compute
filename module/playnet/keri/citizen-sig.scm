;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; citizen-sig.scm — per-AID Ed25519 signing for governance credentials
;;;
;;; Phase-B of the First-Person implementation. Lets a citizen sign
;;; their own speech acts (VRCs in particular) so verifiers don't have
;;; to trust the issuing-scope's claim about who issued what.
;;;
;;; The identity model here is KERI non-transferable ("B") or
;;; transferable ("D") AIDs: the AID prefix IS the 32-byte Ed25519
;;; public key, CESR-encoded. Decoding the AID yields the pubkey
;;; directly. For E-prefix or rotated transferable AIDs whose current
;;; key has changed, KEL-aware verification lives in
;;; `(playnet keri bridge)` `keri-verify-signature` — which dispatches
;;; here for D/B and to a KERIA keystate lookup for the rest, then
;;; loops back through `verify-said-signature`.
;;;
;;; Signatures are CESR qb64 strings under code "0B" (64-byte Ed25519
;;; signature, matching KERI's `SigDex.Ed25519_Sig`). A signature is
;;; produced over the bytes of a credential's SAID — since SAIDs are
;;; deterministic content hashes, signing the SAID is equivalent to
;;; signing the full content without needing a canonical re-serialize.

(define-module (playnet keri citizen-sig)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-9)
  #:use-module ((playnet keri signify-portable)
                #:select (seed->ed25519-keypair
                          ed25519-keypair-public
                          ed25519-keypair-secret
                          ed25519-keypair?
                          sign-bytes
                          public-key->aid-prefix))
  #:use-module ((playnet keri cesr)
                #:select (cesr-bytes->qb64 cesr-qb64->bytes))
  #:use-module ((playnet keri crypto-primitives)
                #:select (keri-crypto-ed25519-verify
                          keri-crypto-random-bytes))
  #:use-module ((srfi srfi-1) #:select (filter-map delete-duplicates any))
  #:export (make-keri-identity
            keri-identity?
            keri-identity-aid
            keri-identity-keypair
            keri-identity-public-key
            keri-identity-from-seed

            aid-prefix->pubkey
            sign-said
            sign-bytes-under-aid
            verify-said-signature
            verify-bytes-under-aid
            aid-signer-keys-resolver
            verify-said-signature-under-key
            sign-said-multisig
            verify-said-multisig))

;; =========================================================================
;; Identity record — an AID + its keypair, derived together
;; =========================================================================

(define-record-type <keri-identity>
  (%make-keri-identity aid keypair)
  keri-identity?
  (aid      keri-identity-aid)
  (keypair  keri-identity-keypair))

(define (keri-identity-public-key id)
  (ed25519-keypair-public (keri-identity-keypair id)))

(define (keri-identity-from-seed seed-bv)
  "Deterministically derive a KERI identity from a 32-byte seed.
   The AID is the CESR qb64 encoding of the Ed25519 public key under
   code \"D\" (transferable) — matching `public-key->aid-prefix`."
  (unless (and (bytevector? seed-bv) (= 32 (bytevector-length seed-bv)))
    (error "keri-identity-from-seed: need a 32-byte bytevector"))
  (let* ((kp  (seed->ed25519-keypair seed-bv))
         (aid (public-key->aid-prefix (ed25519-keypair-public kp))))
    (%make-keri-identity aid kp)))

(define* (make-keri-identity #:optional seed-bv)
  "Create a fresh KERI identity. If SEED-BV is supplied, derives
   deterministically (useful for tests). Otherwise pulls 32 random
   bytes via the keri-crypto backend — server reads /dev/urandom,
   browser uses crypto.getRandomValues."
  (keri-identity-from-seed
    (or seed-bv (keri-crypto-random-bytes 32))))


;; =========================================================================
;; AID ↔ public key — "D" and "B" codes both carry a 32-byte Ed25519 key
;; =========================================================================

(define (aid-prefix->pubkey aid-prefix)
  "Decode an Ed25519-backed AID prefix to its 32-byte public-key
   bytevector. Supports codes \"D\" (transferable) and \"B\"
   (non-transferable). Errors on any other code — in particular,
   synthetic / SAID-based AIDs (code \"E\") do not carry an
   embedded key and require a KEL lookup this module does not do."
  (unless (and (string? aid-prefix) (>= (string-length aid-prefix) 1))
    (error "aid-prefix->pubkey: expected non-empty string" aid-prefix))
  (let ((code (string-ref aid-prefix 0)))
    (case code
      ((#\D #\B) (cesr-qb64->bytes aid-prefix))
      (else (error "aid-prefix->pubkey: non-key AID prefix (need D or B)"
                   aid-prefix)))))


;; =========================================================================
;; Sign / verify a credential SAID
;; =========================================================================

(define (sign-bytes-under-aid data-bv keypair)
  "Ed25519-sign the bytevector DATA-BV with KEYPAIR. Returns a CESR
   qb64 string under code \"0B\" (64-byte Ed25519 signature, KERI's
   `SigDex.Ed25519_Sig`). This is the byte-level primitive; sign-said
   is a thin string wrapper."
  (unless (bytevector? data-bv)
    (error "sign-bytes-under-aid: expected bytevector" data-bv))
  (unless (ed25519-keypair? keypair)
    (error "sign-bytes-under-aid: expected an Ed25519 keypair"))
  (cesr-bytes->qb64 "0B" (sign-bytes data-bv keypair)))

(define (sign-said said-string keypair)
  "Ed25519-sign the UTF-8 bytes of SAID-STRING with KEYPAIR. Returns
   a CESR qb64 0B-prefixed signature."
  (unless (string? said-string)
    (error "sign-said: expected a string SAID" said-string))
  (sign-bytes-under-aid (string->utf8 said-string) keypair))

;; The keys that sign AS an AID, beyond the one its prefix encodes: the
;; gateway binds this cell to (aid at → list of qb64 D/B keys) — the AID's
;; current KEL key after rotations, and every device key the root had
;; authorized AT instant `at` (playnet identity devices
;; device-keys-at); `at` is #f for "now". A statement is verified at its
;; own time, so a device's vouch stays the person's after the device is
;; revoked or its person forgotten, as a rotated-away root key keeps what it
;; signed. Unbound, or an AID it knows nothing about → the prefix alone, the
;; pre-existing D/B behaviour. Reads are vat-free (a file read), so
;; verification stays synchronous anywhere.
(define aid-signer-keys-resolver
  (let ((v #f)) (case-lambda (() v) ((new) (set! v new) new))))

(define (%verify-under-key pub-bv data-bv sig-bv)
  (and (bytevector? sig-bv)
       (= 64 (bytevector-length sig-bv))
       (bytevector? pub-bv)
       (= 32 (bytevector-length pub-bv))
       (keri-crypto-ed25519-verify pub-bv data-bv sig-bv)))

(define* (verify-bytes-under-aid data-bv sig-qb64 signer-aid #:optional (at #f))
  "Verify that SIG-QB64 (CESR qb64) is a valid Ed25519 signature over
   the bytevector DATA-BV by SIGNER-AID: the key its D/B prefix encodes,
   or any key `aid-signer-keys-resolver` names for it as of AT (current KEL
   key, the device keys authorized at AT; AT #f = now). Returns #t/#f
   without raising on malformed input.

   The verifier delegates to keri-crypto-ed25519-verify so it works
   identically on server (goblins crypto) and browser (noble libs)."
  (let* ((sig-bv (catch #t (lambda () (cesr-qb64->bytes sig-qb64)) (lambda _ #f)))
         (try (lambda (key)
               (catch #t
                  (lambda () (%verify-under-key (aid-prefix->pubkey key) data-bv sig-bv))
                  (lambda _ #f)))))
    (and sig-bv
         (or (try signer-aid)
             (let ((resolve (aid-signer-keys-resolver)))
               (and resolve
                    (let ((keys (catch #t (lambda () (resolve signer-aid at)) (lambda _ '()))))
                      (and (list? keys)
                           (any (lambda (k) (and (string? k) (try k))) keys)))))))))

(define (verify-said-signature-under-key said-string sig-qb64 key-qb64)
  "Verify SIG-QB64 over SAID-STRING under exactly KEY-QB64 (a D/B qb64
   key) — the resolver is not consulted. The gate for acts only the ROOT
   key may perform (authorizing a device), where accepting a device's own
   signature would let one device mint another."
  (catch #t
    (lambda ()
      (and (string? said-string)
           (%verify-under-key (aid-prefix->pubkey key-qb64)
                              (string->utf8 said-string)
                              (cesr-qb64->bytes sig-qb64))))
    (lambda _ #f)))

(define* (verify-said-signature said-string sig-qb64 signer-aid #:optional (at #f))
  "Verify that SIG-QB64 is a valid Ed25519 signature over SAID-STRING's
   UTF-8 bytes by a keyholder of SIGNER-AID as of AT (#f = now). Thin
   wrapper over verify-bytes-under-aid for the common SAID-string case."
  (and (string? said-string)
       (verify-bytes-under-aid (string->utf8 said-string)
                               sig-qb64 signer-aid at)))

;; =========================================================================
;; Multisig over a SAID — k-of-n group signing of a credential
;;
;; A single-controller AID signs with one 0B signature (`sign-said`). A
;; k-of-n governance GROUP AID has no single key; each member signs the
;; SAID with their own key and the block carries a threshold of them. This
;; is the credential-layer multisig: the cryptographic core, independent of
;; the KERIA IPEX-multisig exchange that COLLECTS remote member signatures
;; and the keystate lookup that resolves a group's member set. Given the
;; member keypairs locally (single-operator multisig) or the collected
;; signatures + the group's published member AIDs, sign/verify work with no
;; KERIA. Sigs are the same 0B Ed25519 form, one per member.
;; =========================================================================

(define (sign-said-multisig said-string signers)
  "Produce a k-of-n multisig over SAID-STRING. SIGNERS is a list of
   (member-aid . keypair). Returns an alist (member-aid . sig-qb64) — each
   member's Ed25519 0B signature over the SAID. A group-AID-issued
   credential carries this block in place of a single signature."
  (map (lambda (s) (cons (car s) (sign-said said-string (cdr s)))) signers))

(define (verify-said-multisig said-string sig-block member-aids threshold)
  "#t iff SIG-BLOCK (alist member-aid → sig-qb64) carries at least THRESHOLD
   valid signatures over SAID-STRING by DISTINCT members of MEMBER-AIDS.
   k-of-n verification without KERIA: the verifier supplies the group's
   member AIDs (from its published keystate) and its signing threshold. A
   signature from a non-member, a duplicate member, or a bad sig does not
   count toward the threshold."
  (and (list? sig-block)
       (>= (length
            (delete-duplicates
             (filter-map
              (lambda (entry)
                (and (pair? entry)
                     (member (car entry) member-aids)
                     (verify-said-signature said-string (cdr entry) (car entry))
                     (car entry)))
              sig-block)))
           threshold)))
