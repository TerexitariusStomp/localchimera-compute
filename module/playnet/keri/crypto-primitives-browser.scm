;;; module/playnet/keri/crypto-primitives-browser.scm — Hoot/WASM backend
;;;
;;; FFI binding from (playnet keri crypto-primitives) into the
;;; `keri.*` JS namespace exposed by browser/lib/keri-crypto.js (which
;;; wraps @noble/hashes and @noble/ed25519). All primitives must be
;;; SYNCHRONOUS — Hoot's FFI cannot await Promises, and the noble
;;; libraries are pure-JS so they meet that bar.
;;;
;;; Marshalling: bytevector ↔ Uint8Array via (hoot typed-arrays).
;;; Every input/output crosses that boundary once per call.
;;;
;;; Loading this module installs the backend at module-init time, so
;;; downstream signify-portable users don't need to call any setter.

(define-module (playnet keri crypto-primitives-browser)
  #:use-module (rnrs bytevectors)
  #:use-module (hoot ffi)
  #:use-module (hoot typed-arrays)
  #:use-module ((playnet keri crypto-primitives)
                #:select (set-keri-crypto-backend!
                          make-ed25519-keypair
                          ed25519-keypair-secret
                          ed25519-keypair-backend-data))
  ;; uint8array->bytevector is exported as the ONE marshalling helper for
  ;; browser code that touches raw FFI byte buffers — repl.scm's blob
  ;; crypto uses it too. Duplicating the copy loop per call site is how
  ;; off-by-one bugs get in.
  #:export (install-browser-keri-backend!
            uint8array->bytevector))

;;; ── FFI: keri.* JS namespace (browser/lib/keri-crypto.js) ───────────────────────

(define-foreign %keri-blake3-256
  "keri" "blake3_256" (ref extern) -> (ref extern))

(define-foreign %keri-sha256
  "keri" "sha256" (ref extern) -> (ref extern))

(define-foreign %keri-hmac-sha256
  "keri" "hmac_sha256" (ref extern) (ref extern) -> (ref extern))

(define-foreign %keri-ed25519-from-seed
  "keri" "ed25519_from_seed" (ref extern) -> (ref extern))

(define-foreign %keri-ed25519-sign
  "keri" "ed25519_sign" (ref extern) (ref extern) -> (ref extern))

(define-foreign %keri-ed25519-verify
  "keri" "ed25519_verify" (ref extern) (ref extern) (ref extern) -> i32)

(define-foreign %keri-random-bytes
  "keri" "random_bytes" i32 -> (ref extern))

(define-foreign %keri-kp-pub
  "keri" "kp_pub" (ref extern) -> (ref extern))

(define-foreign %keri-kp-seed
  "keri" "kp_seed" (ref extern) -> (ref extern))

;;; ── Uint8Array → bytevector conversion ──────────────────────────────────────

(define (uint8array->bytevector arr)
  "Copy ARR's contents into a fresh bytevector."
  (let* ((n  (uint8array-length arr))
         (bv (make-bytevector n 0)))
    (let loop ((i 0))
      (when (< i n)
        (bytevector-u8-set! bv i (uint8array-ref arr i))
        (loop (+ i 1))))
    bv))

;;; ── Backend implementations ─────────────────────────────────────────────────

(define (browser-blake3-256 bv)
  (uint8array->bytevector
   (%keri-blake3-256 (bytevector->uint8array bv))))

(define (browser-sha256 bv)
  (uint8array->bytevector
   (%keri-sha256 (bytevector->uint8array bv))))

(define (browser-hmac-sha256 key data)
  (uint8array->bytevector
   (%keri-hmac-sha256 (bytevector->uint8array key)
                      (bytevector->uint8array data))))

(define (browser-ed25519-from-seed seed)
  ;; JS returns {pub, seed} — both Uint8Arrays. Convert pub to a
  ;; bytevector for AID derivation; keep the seed bytevector as
  ;; backend-data (noble's sign takes the 32-byte seed directly).
  (let* ((kp     (%keri-ed25519-from-seed (bytevector->uint8array seed)))
         (pub-u8 (%keri-kp-pub kp))
         (pub-bv (uint8array->bytevector pub-u8)))
    (make-ed25519-keypair pub-bv seed seed)))

(define (browser-ed25519-sign keypair message)
  ;; backend-data is the 32-byte seed bytevector.
  (let ((seed-u8 (bytevector->uint8array (ed25519-keypair-backend-data keypair)))
        (msg-u8  (bytevector->uint8array message)))
    (uint8array->bytevector
     (%keri-ed25519-sign seed-u8 msg-u8))))

(define (browser-ed25519-verify pubkey-bv message-bv sig-bv)
  ;; JS noble returns 1/0 (we wrap try/catch in the JS shim too).
  (positive?
   (%keri-ed25519-verify (bytevector->uint8array pubkey-bv)
                         (bytevector->uint8array message-bv)
                         (bytevector->uint8array sig-bv))))

(define (browser-random-bytes n)
  (uint8array->bytevector (%keri-random-bytes n)))

;;; ── Install on module load ──────────────────────────────────────────────────

(define (install-browser-keri-backend!)
  "Wire the primitives into (playnet keri crypto-primitives).
   Idempotent — safe to call multiple times."
  (set-keri-crypto-backend!
   #:blake3-256        browser-blake3-256
   #:sha256            browser-sha256
   #:hmac-sha256       browser-hmac-sha256
   #:ed25519-from-seed browser-ed25519-from-seed
   #:ed25519-sign      browser-ed25519-sign
   #:ed25519-verify    browser-ed25519-verify
   #:random-bytes      browser-random-bytes))

;; Auto-install at module-init.
(install-browser-keri-backend!)
