;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/keys/bran-custody.scm — bran persistence
;;;
;;; A scope's "bran" is the 32-byte seed from which all of its KERI keys
;;; derive (signing keypair, next keypair, every rotation key — see
;;; `bran->signing-keypair`, `bran->next-keypair`,
;;; `bran->rotation-keypair` in `(playnet keri signify-portable)`).
;;; Persisting the bran is therefore necessary and sufficient for full
;;; recovery of a scope's identity.
;;;
;;; Two custody modes (per docs/governance/democracy-on-keri.md §4.1):
;;;
;;;   1. Shamir-distributed.
;;;      `split-and-issue-bran-shares!` splits the bran k-of-n via
;;;      `(playnet crypto shamir)` and issues each share as a
;;;      `playnet-bran-share/v1` ACDC into a shared store, holder = the
;;;      designated share-holder AID. Recovery via
;;;      `reconstitute-bran-from-store` requires gathering at least k
;;;      shares from the store.
;;;
;;;   2. Vault-on-disk fallback.
;;;      `write-vault-bran!` encrypts the bran under PLAYNET_VAULT_KEY
;;;      using HKDF-derived keystream + HMAC-SHA256 tag (both already
;;;      wired via `(playnet keri crypto-primitives)`). Single-host
;;;      recovery reads `<scope-state-dir>/vault` with `read-vault-bran`.
;;;
;;; Either mode is selected at scope spawn time; the actor itself never
;;; holds the bran in bcom.

;;; Hex codec lives in (playnet utils hex), imported by the umbrella.

;;; ── Shamir share ↔ ACDC plumbing ───────────────────────────────────────────

(define-module (playnet keys bran-custody)
  #:use-module (srfi srfi-1)
  #:use-module (playnet credentials keys)
  #:use-module (playnet keri acdc)
  #:use-module (playnet utils hex)
  #:use-module (rnrs bytevectors)
  #:use-module (playnet utils paths)
  #:use-module (playnet keri signify-portable)
  #:use-module (playnet keri crypto-primitives)
  #:use-module (playnet crypto shamir)
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (split-and-issue-bran-shares! reconstitute-bran-from-store ^bran-custodian
            custodian-meta-path spawn-bran-custodian split-and-spawn-custodians!
            restore-bran-custodian reconstitute-bran-from-custodians %vault-version
            %vault-info-stream %vault-info-mac bran-custody/xor-bv!
            bran-custody/copy-bv bran-custody/ct-eq? bran-custody/concat
            bran-custody/encrypt bran-custody/decrypt write-vault-secret!
            read-vault-secret write-vault-bran! read-vault-bran *vault-key-cache*
            ;; a define-syntax-rule, which the lift's name-scanner did not see:
            ;; the umbrella #:export'd it and had nothing to publish, leaving a
            ;; hollow slot that resolved fine right up to the first expansion.
            host-vault-key with-host-vault-key))

(define* (split-and-issue-bran-shares! bran share-holder-aids threshold
                                       scope-aid issuer-aid acdc-store
                                       #:key (signing-keypair #f))
  "Split BRAN (a 32-byte bytevector) into (length share-holder-aids)
   shares with the given THRESHOLD, then issue each share as a
   playnet-bran-share/v1 ACDC into ACDC-STORE: issuer = ISSUER-AID,
   holder = the corresponding share-holder AID, claims include
   `subject-aid SCOPE-AID` so multiple scopes' shares don't collide.

   SIGNING-KEYPAIR: the issuing scope's own keypair, if available —
   see make-bran-share-credential's note on why an unsigned share is a
   real integrity gap, not a cosmetic one.

   Returns the list of share SAIDs in holder order."
  (let* ((n      (length share-holder-aids))
         (shares (shamir-split bran threshold n)))
    (map (lambda (holder share)
           (let* ((idx       (car share))
                  (k         (cadr share))
                  (share-bv  (caddr share))
                  (share-hex (bv->hex share-bv))
                  (cred (make-bran-share-credential
                         #:issuer-group-aid issuer-aid
                         #:holder-aid holder
                         #:share-index idx
                         #:threshold k
                         #:total-shares n
                         #:share-data-hex share-hex
                         #:subject-aid scope-aid
                         #:signing-keypair signing-keypair)))
             ($ acdc-store 'issue cred)
             (cred-said cred)))
         share-holder-aids
         shares)))

(define (reconstitute-bran-from-store store scope-aid threshold)
  "Walk STORE for non-revoked playnet-bran-share/v1 ACDCs whose
   subject-aid claim matches SCOPE-AID. If at least THRESHOLD distinct
   shares are present, returns the reconstituted 32-byte bran. Errors
   with how many shares are missing otherwise."
  (let* ((all-shares
          ($ store 'by-schema *schema-playnet-bran-share*))
         (matching
          (filter (lambda (c)
                    (and (not (cred-revoked? c))
                         (equal? scope-aid (cred-claim c 'subject-aid))))
                  all-shares))
         (by-idx (make-hash-table)))
    (for-each (lambda (c)
                (let ((idx (cred-claim c 'share-index)))
                  (hash-set! by-idx idx c)))
              matching)
    (let* ((unique-creds (hash-map->list (lambda (_k v) v) by-idx))
           (have (length unique-creds)))
      (when (< have threshold)
        (error "reconstitute-bran-from-store: not enough shares"
               scope-aid have threshold))
      (let ((shares
             (map (lambda (c)
                    (list (cred-claim c 'share-index)
                          (cred-claim c 'threshold)
                          (hex->bv (cred-claim c 'share-data))))
                  (take unique-creds threshold))))
        (shamir-combine shares)))))

;;; ── ^bran-custodian: active share-holder actor ─────────────────────────────
;;;
;;; In production, a Shamir share is held by a *party* (a federation
;;; peer, a trusted member, a backup service), not just sitting in a
;;; shared store. A custodian is an actor that:
;;;
;;;   - holds exactly one share for a given (subject-aid, holder-aid)
;;;   - exposes 'release-share which returns (index threshold share-bv)
;;;   - exposes 'identify which returns the holder AID it represents
;;;
;;; Reconstitution becomes a multi-actor query: collect ≥k shares from
;;; ≥k custodians, call `shamir-combine`. Custodians may be local
;;; actors (in-vat tests) or remote OCapN refs (production federation
;;; peers); the protocol is the same.

;; No #:portrait/#:restore here — deliberately. Goblins-native checkpoint
;; requires a composed master persistence-env, which per the actor audit
;; (docs/planning/audits/goblins-actor-audit-2026-07-20.md) is essentially never
;; exercised in this codebase; the mechanism that's actually load-bearing
;; in production is disk write-through + replay-on-spawn, the same shape
;; as ^acdc-store/^kel-store. So a custodian's share is written
;; encrypted-at-rest the moment it's created and reloaded straight off
;; disk on the next spawn — no dependency on any Goblins checkpoint ever
;; running.
(define-actor (^bran-custodian bcom holder-aid subject-aid index threshold share-bv)
  (methods
   ((identify) holder-aid)
   ((subject)  subject-aid)
   ((release-share)
    (list index threshold share-bv))))

(define (custodian-meta-path subject-aid holder-aid)
  ;; index/threshold aren't secret — a small plaintext sidecar next to the
  ;; encrypted share, mirroring kel-store's index.log-next-to-content
  ;; convention, so a custodian can restore itself from disk alone.
  (string-append (custodian-share-path subject-aid holder-aid) ".meta"))

(define* (spawn-bran-custodian holder-aid subject-aid
                               #:key (index #f) (threshold #f) (share-bv #f) (durable? #f))
  "Spawn an active custodian actor wrapping one Shamir share of
   SUBJECT-AID's bran, held on behalf of HOLDER-AID.

   When DURABLE? is #t, the share is encrypted (write-vault-secret!,
   keyed by THIS PROCESS's own PLAYNET_VAULT_KEY — see custodian-share-path's
   note on why that matters for the k-of-n trust property) and written to
   disk immediately, alongside a small plaintext INDEX/THRESHOLD sidecar.
   A fresh custodian takes its SHARE-BV, INDEX and THRESHOLD; a restore
   (DURABLE? #t and no share) reads INDEX and THRESHOLD back from the
   sidecar."
  (cond
   (share-bv
    (when durable?
      (write-vault-secret! share-bv (custodian-share-path subject-aid holder-aid))
      (call-with-output-file (custodian-meta-path subject-aid holder-aid)
        (lambda (port) (write (list index threshold) port) (newline port))))
    (spawn ^bran-custodian holder-aid subject-aid index threshold share-bv))
   (durable?
    (let* ((meta (call-with-input-file (custodian-meta-path subject-aid holder-aid) read))
           (idx  (car meta)) (thr (cadr meta))
           (loaded (read-vault-secret (custodian-share-path subject-aid holder-aid))))
      (spawn ^bran-custodian holder-aid subject-aid idx thr loaded)))
   (else
    (error "spawn-bran-custodian: need share-bv (fresh) or #:durable? #t (restore)"))))

(define* (split-and-spawn-custodians! bran share-holder-aids threshold subject-aid
                                      #:key (durable? #f))
  "Split BRAN k-of-n and spawn one ^bran-custodian per share. Returns
   the list of custodian refs, ordered to match SHARE-HOLDER-AIDS.
   Unlike `split-and-issue-bran-shares!`, no ACDC is created.
   DURABLE?: see spawn-bran-custodian — when #t, each share is written
   encrypted-at-rest as it's created, not just held in actor state."
  (let* ((n      (length share-holder-aids))
         (shares (shamir-split bran threshold n)))
    (map (lambda (holder share)
           (let ((idx      (car share))
                 (k        (cadr share))
                 (share-bv (caddr share)))
             (spawn-bran-custodian holder subject-aid #:index idx #:threshold k
                                   #:share-bv share-bv #:durable? durable?)))
         share-holder-aids
         shares)))

(define (restore-bran-custodian subject-aid holder-aid)
  "Restore a previously-durable ^bran-custodian from
   (custodian-share-path SUBJECT-AID HOLDER-AID) on this host. Errors if
   nothing was ever persisted there (custodian-meta-path missing)."
  (spawn-bran-custodian holder-aid subject-aid #:durable? #t))

(define (reconstitute-bran-from-custodians custodian-refs threshold)
  "Query each custodian for its share and Shamir-combine ≥THRESHOLD.
   Errors when fewer custodians can release shares than threshold."
  (let* ((shares
          (filter-map
           (lambda (ref)
             (catch #t
               (lambda () ($ ref 'release-share))
               (lambda _ #f)))
           custodian-refs))
         (have (length shares)))
    (when (< have threshold)
      (error "reconstitute-bran-from-custodians: not enough shares"
             have threshold))
    (shamir-combine (list-head shares threshold))))

;;; ── Vault: encrypt-on-disk fallback ────────────────────────────────────────
;;;
;;; Construction: HKDF-derived keystream XOR plaintext, HMAC-SHA256 tag
;;; over (nonce || ciphertext). Both primitives ride the keri-crypto
;;; backend wired at module load, so this section imposes no new native
;;; deps. Threat model: protects the bran at rest from anyone who doesn't
;;; hold PLAYNET_VAULT_KEY. Does not protect against runtime introspection
;;; by a malicious host — see democracy-on-keri.md §4.1 honesty caveat.

(define %vault-version 1)
(define %vault-info-stream (string->utf8 "playnet:vault:stream"))
(define %vault-info-mac    (string->utf8 "playnet:vault:mac"))

(define (bran-custody/xor-bv! a b)
  (let ((n (bytevector-length a)))
    (let loop ((i 0))
      (when (< i n)
        (bytevector-u8-set! a i
                            (logxor (bytevector-u8-ref a i)
                                    (bytevector-u8-ref b i)))
        (loop (+ i 1))))))

(define (bran-custody/copy-bv bv)
  (let* ((n (bytevector-length bv))
         (out (make-bytevector n 0)))
    (bytevector-copy! bv 0 out 0 n)
    out))

(define (bran-custody/ct-eq? a b)
  (and (= (bytevector-length a) (bytevector-length b))
       (let loop ((i 0) (acc 0))
         (cond
          ((>= i (bytevector-length a)) (zero? acc))
          (else
           (loop (+ i 1)
                 (logior acc
                         (logxor (bytevector-u8-ref a i)
                                 (bytevector-u8-ref b i)))))))))

(define (bran-custody/concat a b)
  (let* ((na (bytevector-length a))
         (nb (bytevector-length b))
         (out (make-bytevector (+ na nb) 0)))
    (bytevector-copy! a 0 out 0 na)
    (bytevector-copy! b 0 out na nb)
    out))

(define (bran-custody/encrypt bran key-bv)
  (let* ((nonce      (keri-crypto-random-bytes 24))
         (stream-key (hkdf #:ikm key-bv
                           #:salt nonce
                           #:info %vault-info-stream
                           #:length (bytevector-length bran)))
         (mac-key    (hkdf #:ikm key-bv
                           #:salt nonce
                           #:info %vault-info-mac
                           #:length 32))
         (ciphertext (bran-custody/copy-bv bran))
         (_ (bran-custody/xor-bv! ciphertext stream-key))
         (tag        (keri-crypto-hmac-sha256
                      mac-key
                      (bran-custody/concat nonce ciphertext))))
    (cons nonce (cons ciphertext tag))))

(define (bran-custody/decrypt nonce ciphertext tag key-bv)
  (let* ((mac-key (hkdf #:ikm key-bv
                        #:salt nonce
                        #:info %vault-info-mac
                        #:length 32))
         (expect  (keri-crypto-hmac-sha256
                   mac-key
                   (bran-custody/concat nonce ciphertext))))
    (unless (bran-custody/ct-eq? expect tag)
      (error "vault: MAC verification failed (wrong key, or tampering)"))
    (let* ((stream-key (hkdf #:ikm key-bv
                             #:salt nonce
                             #:info %vault-info-stream
                             #:length (bytevector-length ciphertext)))
           (plaintext  (bran-custody/copy-bv ciphertext)))
      (bran-custody/xor-bv! plaintext stream-key)
      plaintext)))

;; Generic encrypted-secret-bytevector-on-disk pair. `bran` was the first
;; and so far only caller when this was named write-vault-bran!/
;; read-vault-bran, but the envelope format has nothing bran-specific
;; about it — it's HKDF+HMAC over any secret bytevector. ^bran-custodian's
;; Shamir shares (below) are the second caller; anything else that ever
;; needs a secret bytevector on disk should reuse this rather than
;; growing its own encrypt-at-rest scheme.

(define* (write-vault-secret! secret path #:key (key-bv #f))
  "Encrypt SECRET (any bytevector) under KEY-BV (defaults to
   host-vault-key) and write the sealed envelope to PATH."
  (let* ((k       (or key-bv (host-vault-key)))
         (sealed  (bran-custody/encrypt secret k))
         (nonce   (car sealed))
         (ct      (cadr sealed))
         (tag     (cddr sealed))
         (envelope `(playnet-vault ,%vault-version
                                   (nonce ,(bv->hex nonce))
                                   (ct    ,(bv->hex ct))
                                   (tag   ,(bv->hex tag)))))
    (ensure-directory! (dirname path))
    (call-with-output-file path
      (lambda (port) (write envelope port) (newline port)))
    path))

(define* (read-vault-secret path #:key (key-bv #f))
  "Read PATH and decrypt the secret bytevector under KEY-BV. Errors on
   tamper, wrong key, or version mismatch."
  (let* ((envelope (call-with-input-file path read))
         (k        (or key-bv (host-vault-key))))
    (unless (and (pair? envelope)
                 (eq? 'playnet-vault (car envelope))
                 (= (cadr envelope) %vault-version))
      (error "read-vault-secret: bad envelope" path envelope))
    (let* ((parts  (cddr envelope))
           (nonce  (hex->bv (cadr (assq 'nonce parts))))
           (ct     (hex->bv (cadr (assq 'ct    parts))))
           (tag    (hex->bv (cadr (assq 'tag   parts)))))
      (bran-custody/decrypt nonce ct tag k))))

;; bran-named aliases — kept for the existing scope.scm/scope-recovery.scm
;; call sites, which read more clearly with "bran" in the name than the
;; now-generic underlying functions.
(define write-vault-bran! write-vault-secret!)
(define read-vault-bran   read-vault-secret)

;;; ── Host vault key ─────────────────────────────────────────────────────────

(define *vault-key-cache* #f)

(define (host-vault-key)
  "Return the host vault key bytevector. Reads PLAYNET_VAULT_KEY env
   (64-char hex) on first call and caches. Errors when env is missing."
  (or *vault-key-cache*
      (let ((hex (getenv "PLAYNET_VAULT_KEY")))
        (cond
         ((and hex (= 64 (string-length hex)))
          (let ((bv (hex->bv hex)))
            (set! *vault-key-cache* bv)
            bv))
         (else
          (error "PLAYNET_VAULT_KEY not set or wrong length"
                 "expected 32-byte hex (64 chars)"))))))

(define-syntax-rule (with-host-vault-key hex body ...)
  (let ((prev *vault-key-cache*))
    (dynamic-wind
      (lambda () (set! *vault-key-cache* (hex->bv hex)))
      (lambda () body ...)
      (lambda () (set! *vault-key-cache* prev)))))
