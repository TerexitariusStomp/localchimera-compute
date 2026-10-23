;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/keri/crypto-primitives.scm — pluggable KERI crypto seam
;;;
;;; Abstracts the four host primitives that signify.scm needs but that
;;; can't be expressed in pure Scheme:
;;;
;;;   blake3-256       : bytevector → 32-byte bytevector
;;;   sha256           : bytevector → 32-byte bytevector
;;;   hmac-sha256      : key:bv data:bv → 32-byte bytevector
;;;   ed25519-from-seed: 32-byte seed bytevector → <ed25519-keypair>
;;;   ed25519-sign     : <ed25519-keypair> message:bv → 64-byte sig bytevector
;;;
;;; The shared <ed25519-keypair> record has three slots:
;;;   public       — 32-byte raw Ed25519 public key (canonical, both backends)
;;;   secret       — 32-byte seed (canonical)
;;;   backend-data — opaque per-backend material the sign primitive needs
;;;                  (libsodium's 64-byte expanded SK on the server;
;;;                   typically the seed itself for noble-ed25519 in browser)
;;;
;;; A backend is installed by calling `set-keri-crypto-backend!` once at
;;; load time. signify.scm (server) installs the gcrypt + libsodium +
;;; libblake3 backend; the browser bundle installs an FFI-to-noble
;;; backend. signify-portable.scm calls the four `keri-crypto-*`
;;; procedures unconditionally — it doesn't care which backend is live.

(define-module (playnet keri crypto-primitives)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-9)
  #:export (<ed25519-keypair>
            make-ed25519-keypair
            ed25519-keypair?
            ed25519-keypair-public
            ed25519-keypair-secret
            ed25519-keypair-backend-data

            set-keri-crypto-backend!
            keri-crypto-installed?

            keri-crypto-blake3-256
            keri-crypto-sha256
            keri-crypto-hmac-sha256
            keri-crypto-ed25519-from-seed
            keri-crypto-ed25519-sign
            keri-crypto-ed25519-verify
            keri-crypto-random-bytes))

;;; ── Shared keypair record ───────────────────────────────────────────────────

(define-record-type <ed25519-keypair>
  (make-ed25519-keypair public secret backend-data)
  ed25519-keypair?
  (public       ed25519-keypair-public)        ; 32-byte raw pubkey
  (secret       ed25519-keypair-secret)        ; 32-byte seed
  (backend-data ed25519-keypair-backend-data)) ; opaque per-backend

;;; ── Backend slots ───────────────────────────────────────────────────────────

(define %blake3-256-impl        #f)
(define %sha256-impl            #f)
(define %hmac-sha256-impl       #f)
(define %ed25519-from-seed-impl #f)
(define %ed25519-sign-impl      #f)
(define %ed25519-verify-impl    #f)
(define %random-bytes-impl      #f)

(define* (set-keri-crypto-backend!
          #:key blake3-256 sha256 hmac-sha256
                ed25519-from-seed ed25519-sign ed25519-verify
                random-bytes)
  "Install backend primitives. Pass #f for any to leave its slot
   unchanged. Subsequent calls override; the last installer wins, by
   design (the browser bundle installs after signify runs at module
   load)."
  (when blake3-256        (set! %blake3-256-impl       blake3-256))
  (when sha256            (set! %sha256-impl           sha256))
  (when hmac-sha256       (set! %hmac-sha256-impl      hmac-sha256))
  (when ed25519-from-seed (set! %ed25519-from-seed-impl ed25519-from-seed))
  (when ed25519-sign      (set! %ed25519-sign-impl     ed25519-sign))
  (when ed25519-verify    (set! %ed25519-verify-impl   ed25519-verify))
  (when random-bytes      (set! %random-bytes-impl     random-bytes)))

(define (keri-crypto-installed?)
  "True iff every primitive slot is bound. Useful as a sanity check
   before any cryptographic operation."
  (and %blake3-256-impl %hmac-sha256-impl
       %ed25519-from-seed-impl %ed25519-sign-impl
       %ed25519-verify-impl %random-bytes-impl))

;;; ── Public dispatchers ──────────────────────────────────────────────────────

(define (keri-crypto-blake3-256 bv)
  (unless %blake3-256-impl
    (error "keri-crypto: no blake3-256 backend installed"))
  (%blake3-256-impl bv))

(define (keri-crypto-sha256 bv)
  "Plain SHA-256 over BV. Reticulum derives its identity and destination
   hashes from truncated SHA-256, so the AID↔mesh binding verifier needs
   this alongside the KERI-side blake3."
  (unless %sha256-impl
    (error "keri-crypto: no sha256 backend installed"))
  (%sha256-impl bv))

(define (keri-crypto-hmac-sha256 key data)
  (unless %hmac-sha256-impl
    (error "keri-crypto: no hmac-sha256 backend installed"))
  (%hmac-sha256-impl key data))

(define (keri-crypto-ed25519-from-seed seed)
  (unless %ed25519-from-seed-impl
    (error "keri-crypto: no ed25519-from-seed backend installed"))
  (unless (and (bytevector? seed) (= 32 (bytevector-length seed)))
    (error "keri-crypto-ed25519-from-seed: need 32-byte bytevector" seed))
  (%ed25519-from-seed-impl seed))

(define (keri-crypto-ed25519-sign keypair message)
  (unless %ed25519-sign-impl
    (error "keri-crypto: no ed25519-sign backend installed"))
  (unless (ed25519-keypair? keypair)
    (error "keri-crypto-ed25519-sign: expected <ed25519-keypair>" keypair))
  (%ed25519-sign-impl keypair message))

(define (keri-crypto-random-bytes n)
  "Return a fresh bytevector of N cryptographically-strong random
   bytes. Backend-implemented: server uses /dev/urandom, browser uses
   crypto.getRandomValues. Errors on N < 0."
  (unless %random-bytes-impl
    (error "keri-crypto: no random-bytes backend installed"))
  (unless (and (exact-integer? n) (>= n 0))
    (error "keri-crypto-random-bytes: N must be a non-negative integer" n))
  (%random-bytes-impl n))

(define (keri-crypto-ed25519-verify pubkey-bv message-bv sig-bv)
  "Verify the 64-byte SIG-BV is a valid Ed25519 signature over
   MESSAGE-BV under the 32-byte raw public key PUBKEY-BV. Returns
   #t / #f without raising on malformed inputs (the backend is
   expected to swallow library-specific errors)."
  (unless %ed25519-verify-impl
    (error "keri-crypto: no ed25519-verify backend installed"))
  (unless (and (bytevector? pubkey-bv) (= 32 (bytevector-length pubkey-bv)))
    (error "keri-crypto-ed25519-verify: pubkey must be 32-byte bytevector"))
  (unless (and (bytevector? sig-bv) (= 64 (bytevector-length sig-bv)))
    (error "keri-crypto-ed25519-verify: sig must be 64-byte bytevector"))
  (unless (bytevector? message-bv)
    (error "keri-crypto-ed25519-verify: message must be a bytevector"))
  (%ed25519-verify-impl pubkey-bv message-bv sig-bv))
