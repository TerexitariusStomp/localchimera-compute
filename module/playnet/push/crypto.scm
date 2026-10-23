;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/push/crypto.scm — Web Push encryption (RFC 8291)
;;;
;;; Implements the content-encoding for Web Push payloads:
;;;   ECDH key agreement on P-256 → HKDF-SHA256 key derivation →
;;;   AES-128-GCM encryption with a single record.
;;;
;;; Also provides VAPID (RFC 8292) JWT signing via ECDSA P-256.
;;;
;;; Depends on libgcrypt for AES-GCM and ECDH; uses guile-gcrypt's
;;; pk-crypto for key generation and ECDSA signing.

(define-module (playnet push crypto)
  #:use-module (system foreign)
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))   ; the one clock: instants inside, civil at the boundary
  #:use-module (system foreign-library)
  #:use-module (gcrypt pk-crypto)
  #:use-module (gcrypt hash)
  #:use-module (gcrypt base16)
  #:use-module (rnrs bytevectors)
  #:use-module ((gcrypt mac) #:select (sign-data lookup-mac-algorithm))
  #:use-module (playnet keri cesr)              ;; b64url-encode, b64url-decode
  #:use-module (ice-9 format)
  #:use-module (ice-9 binary-ports)
  #:use-module (json)
  #:use-module ((playnet utils operator) #:select (operator-ref contact-uri))
  #:use-module ((gcrypt package-config) #:select (%libgcrypt))
  #:export (generate-vapid-keypair
            vapid-public-key-bytes
            vapid-sign-jwt
            web-push-encrypt))

;;; ── libgcrypt FFI ──────────────────────────────────────────────────────

;; the libgcrypt guile-gcrypt was built against (gcrypt package-config), by its
;; path: the bare name resolved only once some (gcrypt …) module had loaded the
;; library first, so whether this module loaded depended on import order
(define gcrypt-lib (load-foreign-library %libgcrypt))

(define gcry-cipher-open
  (foreign-library-function gcrypt-lib "gcry_cipher_open"
    #:return-type int
    #:arg-types (list '* int int unsigned-int)))
(define gcry-cipher-close
  (foreign-library-function gcrypt-lib "gcry_cipher_close"
    #:return-type void #:arg-types (list '*)))
(define gcry-cipher-setkey
  (foreign-library-function gcrypt-lib "gcry_cipher_setkey"
    #:return-type int #:arg-types (list '* '* size_t)))
(define gcry-cipher-setiv
  (foreign-library-function gcrypt-lib "gcry_cipher_setiv"
    #:return-type int #:arg-types (list '* '* size_t)))
(define gcry-cipher-encrypt
  (foreign-library-function gcrypt-lib "gcry_cipher_encrypt"
    #:return-type int #:arg-types (list '* '* size_t '* size_t)))
(define gcry-cipher-gettag
  (foreign-library-function gcrypt-lib "gcry_cipher_gettag"
    #:return-type int #:arg-types (list '* '* size_t)))
(define gcry-pk-encrypt
  (foreign-library-function gcrypt-lib "gcry_pk_encrypt"
    #:return-type int #:arg-types (list '* '* '*)))
(define gcry-sexp-find-token
  (foreign-library-function gcrypt-lib "gcry_sexp_find_token"
    #:return-type '* #:arg-types (list '* '* size_t)))
(define gcry-sexp-nth-data
  (foreign-library-function gcrypt-lib "gcry_sexp_nth_data"
    #:return-type '* #:arg-types (list '* int '*)))
(define gcry-sexp-release
  (foreign-library-function gcrypt-lib "gcry_sexp_release"
    #:return-type void #:arg-types (list '*)))

(define %GCRY_CIPHER_AES128 7)
(define %GCRY_CIPHER_MODE_GCM 11)

(define cs->ptr (@ (gcrypt pk-crypto) canonical-sexp->pointer))

;;; ── Bytevector helpers ─────────────────────────────────────────────────

(define (bv-concat . bvs)
  (let* ((total (apply + (map bytevector-length bvs)))
         (out (make-bytevector total 0)))
    (let loop ((bvs bvs) (off 0))
      (if (null? bvs) out
          (let ((bv (car bvs)))
            (bytevector-copy! bv 0 out off (bytevector-length bv))
            (loop (cdr bvs) (+ off (bytevector-length bv))))))))

;;; ── HMAC-SHA256 + HKDF (self-contained, no pluggable backend) ───────────

(define %hmac-sha256-algo (lookup-mac-algorithm 'hmac-sha256))

(define (%hmac-sha256 key data)
  (sign-data key data #:algorithm %hmac-sha256-algo))

(define (hkdf-extract salt ikm)
  (let ((effective-salt (if (and salt (> (bytevector-length salt) 0))
                            salt
                            (make-bytevector 32 0))))
    (%hmac-sha256 effective-salt ikm)))

(define (hkdf-expand prk info length)
  (when (> length (* 255 32))
    (error "hkdf-expand: requested length exceeds 255 * HashLen"))
  (let loop ((t #vu8()) (i 1) (out #vu8()))
    (if (>= (bytevector-length out) length)
        (let ((result (make-bytevector length)))
          (bytevector-copy! out 0 result 0 length)
          result)
        (let* ((input (bv-concat t info (make-bytevector 1 i)))
               (t-i (%hmac-sha256 prk input)))
          (loop t-i (+ i 1) (bv-concat out t-i))))))

;;; ── AES-128-GCM ───────────────────────────────────────────────────────

(define (aes128-gcm-encrypt key nonce plaintext)
  "Encrypt PLAINTEXT with AES-128-GCM. KEY is 16 bytes, NONCE is 12 bytes.
   Returns (values ciphertext tag) where tag is 16 bytes."
  (let* ((hd-bv (make-bytevector 8 0))
         (err (gcry-cipher-open (bytevector->pointer hd-bv)
                                %GCRY_CIPHER_AES128
                                %GCRY_CIPHER_MODE_GCM 0)))
    (unless (zero? err)
      (error "aes128-gcm-encrypt: cipher open failed" err))
    (let ((hd (make-pointer (bytevector-u64-ref hd-bv 0 (endianness little))))
          (ct (make-bytevector (bytevector-length plaintext) 0))
          (tag (make-bytevector 16 0)))
      (gcry-cipher-setkey hd (bytevector->pointer key) 16)
      (gcry-cipher-setiv hd (bytevector->pointer nonce) 12)
      (gcry-cipher-encrypt hd (bytevector->pointer ct) (bytevector-length ct)
                           (bytevector->pointer plaintext) (bytevector-length plaintext))
      (gcry-cipher-gettag hd (bytevector->pointer tag) 16)
      (gcry-cipher-close hd)
      (values ct tag))))

;;; ── P-256 ECDH ─────────────────────────────────────────────────────────

(define (p256-generate-keypair)
  "Generate a P-256 keypair. Returns the gcrypt canonical-sexp."
  (generate-key (string->canonical-sexp
                  "(genkey (ecc (curve \"NIST P-256\")))")))

(define (p256-public-point key-sexp)
  "Extract the uncompressed public point (65 bytes) from a P-256 key sexp."
  (let* ((pub (find-sexp-token key-sexp 'public-key))
         (q (find-sexp-token pub 'q)))
    (canonical-sexp-nth-data q 1)))

(define (p256-ecdh private-key-sexp remote-public-point)
  "Perform ECDH: compute shared point from our private key and their
   public point (65-byte uncompressed). Returns the 32-byte x-coordinate
   of the shared point (as per RFC 8291 §3.4)."
  (let* ((data (string->canonical-sexp
                 (format #f "(data (flags raw) (value #~a#))"
                         (bytevector->base16-string remote-public-point))))
         (priv (find-sexp-token private-key-sexp 'private-key))
         (result-ptr-bv (make-bytevector 8 0))
         (err (gcry-pk-encrypt (bytevector->pointer result-ptr-bv)
                               (cs->ptr data) (cs->ptr priv))))
    (unless (zero? err)
      (error "p256-ecdh: gcry_pk_encrypt failed" err))
    (let* ((rsexp (make-pointer (bytevector-u64-ref result-ptr-bv 0 (endianness little))))
           (ecdh-node (gcry-sexp-find-token rsexp (string->pointer "ecdh") 0))
           (s-node (gcry-sexp-find-token ecdh-node (string->pointer "s") 0))
           (len-bv (make-bytevector 8 0))
           (data-ptr (gcry-sexp-nth-data s-node 1 (bytevector->pointer len-bv)))
           (len (bytevector-u64-ref len-bv 0 (endianness little)))
           (shared-point (pointer->bytevector data-ptr len))
           ;; x-coordinate is bytes 1..32 of the uncompressed point
           (x-coord (make-bytevector 32)))
      (bytevector-copy! shared-point 1 x-coord 0 32)
      (gcry-sexp-release s-node)
      (gcry-sexp-release ecdh-node)
      (gcry-sexp-release rsexp)
      x-coord)))

;;; ── VAPID (RFC 8292) ───────────────────────────────────────────────────

(define (generate-vapid-keypair)
  "Generate a VAPID keypair (P-256). Returns the gcrypt canonical-sexp."
  (p256-generate-keypair))

(define (vapid-public-key-bytes key-sexp)
  "Return the 65-byte uncompressed public key for passing to pushManager.subscribe()."
  (p256-public-point key-sexp))

(define (vapid-sign-jwt key-sexp audience expiry-seconds)
  "Sign a VAPID JWT (RFC 8292 §2). Returns the Authorization header value
   string: 'vapid t=<jwt>,k=<b64url-pubkey>'."
  (let* ((now (instant->unix (clock-now)))
         (header-json (scm->json-string '(("typ" . "JWT") ("alg" . "ES256"))))
         ;; RFC 8292 §2: `sub` tells the push service who to reach about this
         ;; sender — THIS gateway's operator (PLAYNET_OPERATOR_CONTACT), never
         ;; another deployment's. With none configured the claim is left out.
         (sub (let ((c (operator-ref "contact"))) (and c (contact-uri c))))
         (payload-json (scm->json-string
                         `(("aud" . ,audience)
                           ("exp" . ,(+ now expiry-seconds))
                           ,@(if sub `(("sub" . ,sub)) '()))))
         (header-b64 (b64url-encode (string->utf8 header-json)))
         (payload-b64 (b64url-encode (string->utf8 payload-json)))
         (signing-input (string-append header-b64 "." payload-b64))
         (digest (sha256 (string->utf8 signing-input)))
         (data-sexp (string->canonical-sexp
                      (format #f "(data (flags raw) (value #~a#))"
                              (bytevector->base16-string digest))))
         (sig-sexp (sign data-sexp key-sexp))
         ;; Extract r and s values from the signature
         (sig-node (find-sexp-token sig-sexp 'sig-val))
         (ecdsa-node (find-sexp-token sig-node 'ecdsa))
         (r-data (canonical-sexp-nth-data (find-sexp-token ecdsa-node 'r) 1))
         (s-data (canonical-sexp-nth-data (find-sexp-token ecdsa-node 's) 1))
         ;; ES256 signature is r || s, each zero-padded to 32 bytes
         (sig-bytes (make-bytevector 64 0)))
    ;; r and s may be < 32 bytes (no leading zeros) or 33 bytes (sign bit)
    (let ((r-len (bytevector-length r-data))
          (s-len (bytevector-length s-data)))
      (if (> r-len 32)
          (bytevector-copy! r-data (- r-len 32) sig-bytes 0 32)
          (bytevector-copy! r-data 0 sig-bytes (- 32 r-len) r-len))
      (if (> s-len 32)
          (bytevector-copy! s-data (- s-len 32) sig-bytes 32 32)
          (bytevector-copy! s-data 0 sig-bytes (+ 32 (- 32 s-len)) s-len)))
    (let* ((sig-b64 (b64url-encode sig-bytes))
           (jwt (string-append signing-input "." sig-b64))
           (pub-b64 (b64url-encode (p256-public-point key-sexp))))
      (format #f "vapid t=~a,k=~a" jwt pub-b64))))

;;; ── Web Push Encryption (RFC 8291) ─────────────────────────────────────

(define %web-push-info (string->utf8 "WebPush: info\x00"))
(define %content-encoding-aes128gcm (string->utf8 "Content-Encoding: aes128gcm\x00"))
(define %content-encoding-nonce (string->utf8 "Content-Encoding: nonce\x00"))

(define (web-push-encrypt plaintext
                          subscriber-public-key-bytes
                          subscriber-auth-secret)
  "Encrypt PLAINTEXT for Web Push (RFC 8291, aes128gcm content encoding).
   SUBSCRIBER-PUBLIC-KEY-BYTES: 65-byte uncompressed P-256 public key from
   the PushSubscription's p256dh field.
   SUBSCRIBER-AUTH-SECRET: 16-byte auth secret from the PushSubscription.
   Returns (values encrypted-body server-public-key-bytes) where
   encrypted-body is the complete aes128gcm payload ready for the push POST."
  (let* (;; Generate ephemeral server keypair
         (server-key (p256-generate-keypair))
         (server-pub (p256-public-point server-key))
         ;; ECDH shared secret (x-coordinate)
         (shared-secret (p256-ecdh server-key subscriber-public-key-bytes))
         ;; IKM for HKDF (RFC 8291 §3.4):
         ;; info = "WebPush: info\0" || ua_public || as_public
         (ikm-info (bv-concat %web-push-info
                              subscriber-public-key-bytes
                              server-pub))
         ;; PRK = HKDF-Extract(auth_secret, ecdh_secret)
         ;; IKM = HKDF-Expand(PRK, ikm_info, 32)
         (ikm (hkdf-expand (hkdf-extract subscriber-auth-secret shared-secret)
                           ikm-info 32))
         ;; Content encryption key:
         ;; salt (random 16 bytes)
         (salt (let ((bv (make-bytevector 16)))
                 (let ((port (open-input-file "/dev/urandom")))
                   (get-bytevector-n! port bv 0 16)
                   (close-port port))
                 bv))
         ;; cek_info = "Content-Encoding: aes128gcm\0\1"
         (cek-info (bv-concat %content-encoding-aes128gcm #vu8(1)))
         ;; nonce_info = "Content-Encoding: nonce\0\1"
         (nonce-info (bv-concat %content-encoding-nonce #vu8(1)))
         ;; PRK for content = HKDF-Extract(salt, IKM)
         (prk (hkdf-extract salt ikm))
         ;; CEK = HKDF-Expand(PRK, cek_info, 16)
         (cek (hkdf-expand prk cek-info 16))
         ;; Nonce = HKDF-Expand(PRK, nonce_info, 12)
         (nonce (hkdf-expand prk nonce-info 12))
         ;; Pad plaintext: add delimiter byte 0x02 (final record)
         (padded (bv-concat plaintext #vu8(2)))
         ;; Encrypt
         (ct+tag (call-with-values
                   (lambda () (aes128-gcm-encrypt cek nonce padded))
                   bv-concat))
         ;; Build aes128gcm header:
         ;; salt (16) || rs (4, big-endian uint32) || idlen (1) || keyid (65)
         (rs-bv (make-bytevector 4))
         (_ (bytevector-u32-set! rs-bv 0 4096 (endianness big)))
         (header (bv-concat salt rs-bv #vu8(65) server-pub))
         ;; Final payload = header || ciphertext+tag
         (body (bv-concat header ct+tag)))
    (values body server-pub)))
