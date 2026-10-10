;;; tests/push/test-push-crypto.scm — Automated tests for Web Push crypto
;;;
;;; Run: guix shell guile-next guile-gcrypt guile-json libgcrypt guile-goblins -- \
;;;        env LTDL_LIBRARY_PATH=<libgcrypt-lib-dir> \
;;;        guile -L module tests/push/test-push-crypto.scm

(use-modules (rnrs bytevectors))
(use-modules (playnet push crypto))
(use-modules (playnet push adapter))
(use-modules (playnet push vapid))
(use-modules (playnet keri cesr))
(use-modules (gcrypt pk-crypto))
(use-modules (ice-9 textual-ports))
(use-modules (srfi srfi-11))

(define *pass* 0)
(define *fail* 0)

(define (test name thunk)
  (catch #t
    (lambda ()
      (thunk)
      (set! *pass* (+ *pass* 1))
      (format #t "PASS: ~a~%" name))
    (lambda (key . args)
      (set! *fail* (+ *fail* 1))
      (format #t "FAIL: ~a — ~a ~a~%" name key args))))

;;; ── Module loading ──────────────────────────────────────────────────

(test "push/crypto module loads"
  (lambda () (and generate-vapid-keypair web-push-encrypt vapid-sign-jwt)))

(test "push/adapter module loads"
  (lambda () (and ^push-adapter ^push-subscription-store)))

(test "push/vapid module loads"
  (lambda () (and load-or-generate-vapid-key!)))

;;; ── VAPID key generation ───────────────────────────────────────────

(define vk (generate-vapid-keypair))

(test "VAPID keypair generation"
  (lambda () (unless vk (error "nil key"))))

(test "VAPID public key is 65 bytes (uncompressed P-256)"
  (lambda ()
    (let ((pub (vapid-public-key-bytes vk)))
      (unless (= (bytevector-length pub) 65)
        (error "wrong length" (bytevector-length pub)))
      (unless (= (bytevector-u8-ref pub 0) 4)
        (error "not uncompressed point")))))

;;; ── VAPID JWT signing ──────────────────────────────────────────────

(define jwt-header (vapid-sign-jwt vk "https://fcm.googleapis.com" 3600))

(test "VAPID JWT starts with 'vapid t='"
  (lambda ()
    (unless (string-prefix? "vapid t=" jwt-header)
      (error "bad prefix"))))

(test "VAPID JWT token has 3 dot-separated parts"
  (lambda ()
    (let* ((t-start (+ (string-index jwt-header #\=) 1))
           (comma (string-index jwt-header #\,))
           (token (substring jwt-header t-start comma))
           (parts (string-split token #\.)))
      (unless (= (length parts) 3)
        (error "expected 3 parts" (length parts))))))

(test "VAPID JWT k= decodes to 65-byte public key"
  (lambda ()
    (let* ((k-pos (string-contains jwt-header ",k="))
           (k-str (substring jwt-header (+ k-pos 3)))
           (decoded (b64url-decode k-str)))
      (unless (= (bytevector-length decoded) 65)
        (error "wrong key length" (bytevector-length decoded))))))

;;; ── Crypto internals (tested via web-push-encrypt integration) ─────
;;;
;;; ECDH, AES-128-GCM, and HKDF are internal to push/crypto and
;;; exercised through web-push-encrypt. These tests verify the
;;; integration produces structurally correct output.

;;; ── Web Push encryption ─────────────────────────────────────────────

(test "web-push-encrypt: valid payload structure"
  (lambda ()
    (let* ((sub-key (generate-vapid-keypair))
           (sub-pub (vapid-public-key-bytes sub-key))
           (sub-auth (make-bytevector 16 77))
           (plaintext (string->utf8 "{\"title\":\"test\"}")))
      (call-with-values
        (lambda () (web-push-encrypt plaintext sub-pub sub-auth))
        (lambda (body server-pub)
          ;; header: 16 salt + 4 rs + 1 idlen + 65 keyid = 86
          (unless (> (bytevector-length body) 86)
            (error "too short" (bytevector-length body)))
          (let ((rs (bytevector-u32-ref body 16 (endianness big)))
                (idlen (bytevector-u8-ref body 20)))
            (unless (= rs 4096) (error "rs" rs))
            (unless (= idlen 65) (error "idlen" idlen)))
          (unless (= (bytevector-length server-pub) 65)
            (error "server pub" (bytevector-length server-pub))))))))

(test "web-push-encrypt: different output each call (random salt + ephemeral key)"
  (lambda ()
    (let* ((sub-key (generate-vapid-keypair))
           (sub-pub (vapid-public-key-bytes sub-key))
           (sub-auth (make-bytevector 16 77))
           (plaintext (string->utf8 "same input"))
           (body1 (call-with-values
                    (lambda () (web-push-encrypt plaintext sub-pub sub-auth))
                    (lambda (b _s) b)))
           (body2 (call-with-values
                    (lambda () (web-push-encrypt plaintext sub-pub sub-auth))
                    (lambda (b _s) b))))
      (unless (not (equal? body1 body2))
        (error "identical outputs")))))

;;; ── VAPID key persistence ──────────────────────────────────────────

(test "VAPID key round-trips through file"
  (lambda ()
    (let ((dir "/tmp/playnet-vapid-test"))
      (catch #t (lambda () (mkdir dir)) (lambda _ #f))
      (let* ((key1 (load-or-generate-vapid-key! dir))
             (pub1 (vapid-public-key-bytes key1))
             (key2 (load-or-generate-vapid-key! dir))
             (pub2 (vapid-public-key-bytes key2)))
        (unless (equal? pub1 pub2)
          (error "keys differ after reload"))
        (delete-file (string-append dir "/vapid-key.scm"))
        (rmdir dir)))))

;;; ── Base64url ───────────────────────────────────────────────────────

(test "base64url round-trip on VAPID public key"
  (lambda ()
    (let* ((pub (vapid-public-key-bytes vk))
           (encoded (b64url-encode pub))
           (decoded (b64url-decode encoded)))
      (unless (equal? pub decoded)
        (error "round-trip failed")))))

;;; ── Summary ─────────────────────────────────────────────────────────

(newline)
(format #t "~a passed, ~a failed~%" *pass* *fail*)
(when (> *fail* 0)
  (exit 1))
