;;; module/weave/auth.scm — LiveKit JWT generation
;;;
;;; Generates LiveKit access tokens (HS256 JWTs) for participants and admin
;;; operations. Server-side only — not compiled to WASM.
;;;
;;; Requires: guile-gcrypt (for HMAC-SHA256), guile-json
;;;
;;; Environment variables read by make-livekit-token:
;;;   LIVEKIT_API_KEY    — the LiveKit API key
;;;   LIVEKIT_API_SECRET — the LiveKit API secret

(define-module (weave auth)
  #:use-module (gcrypt mac)
  #:use-module (rnrs bytevectors)
  #:use-module (json)
  #:use-module (ice-9 iconv)
  #:export (base64url-encode-bv
            base64url-encode-string
            make-livekit-token
            make-livekit-admin-token
            livekit-api-key
            livekit-api-secret))

;;; ── Environment ──────────────────────────────────────────────────────────────

(define (livekit-api-key)
  (or (getenv "LIVEKIT_API_KEY")
      (error "LIVEKIT_API_KEY not set")))

(define (livekit-api-secret)
  (or (getenv "LIVEKIT_API_SECRET")
      (error "LIVEKIT_API_SECRET not set")))

;;; ── Base64URL encoding ───────────────────────────────────────────────────────
;;; Implemented from scratch for portability (works in Guile and Hoot).
;;; Uses the URL-safe alphabet (- and _ instead of + and /); no = padding.

(define *b64url-chars*
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

(define (base64url-encode-bv bv)
  "Encode bytevector BV to a base64url string (no padding)."
  (let ((len (bytevector-length bv)))
    (let loop ((i 0) (acc '()))
      (if (>= i len)
          (list->string (reverse acc))
          (let* ((b0 (bytevector-u8-ref bv i))
                 (b1 (if (< (+ i 1) len) (bytevector-u8-ref bv (+ i 1)) 0))
                 (b2 (if (< (+ i 2) len) (bytevector-u8-ref bv (+ i 2)) 0))
                 (n  (+ (ash b0 16) (ash b1 8) b2))
                 (c0 (string-ref *b64url-chars* (ash n -18)))
                 (c1 (string-ref *b64url-chars* (logand (ash n -12) #x3f)))
                 (acc (cons c1 (cons c0 acc)))
                 (acc (if (< (+ i 1) len)
                          (cons (string-ref *b64url-chars* (logand (ash n -6) #x3f)) acc)
                          acc))
                 (acc (if (< (+ i 2) len)
                          (cons (string-ref *b64url-chars* (logand n #x3f)) acc)
                          acc)))
            (loop (+ i 3) acc))))))

(define (base64url-encode-string s)
  "Encode UTF-8 string S as base64url."
  (base64url-encode-bv (string->bytevector s "UTF-8")))

;;; ── HMAC-SHA256 ──────────────────────────────────────────────────────────────

(define (hmac-sha256-bv key-bv data-bv)
  "Compute HMAC-SHA256 of DATA-BV using KEY-BV. Returns a bytevector."
  (let ((m (make-mac 'hmac-sha256 key-bv)))
    (mac-write! m data-bv)
    (mac-hash m)))

;;; ── JWT construction ─────────────────────────────────────────────────────────

(define *jwt-header* "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")
;; Pre-encoded: base64url({"alg":"HS256","typ":"JWT"})
;; Verified: echo -n '{"alg":"HS256","typ":"JWT"}' | base64url → eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9

(define (unix-now)
  "Current time as Unix epoch integer."
  (let ((t (gettimeofday)))
    (car t)))

(define (make-livekit-token api-key api-secret room-name identity role)
  "Generate a LiveKit participant access token (HS256 JWT).
   ROLE is one of the symbols: convener participant observer
   Token is valid for 24 hours."
  (let* ((now  (unix-now))
         (payload-json
          (scm->json-string
           `((iss . ,api-key)
             (sub . ,identity)
             (nbf . ,now)
             (exp . ,(+ now 86400))
             (video
              . ((roomJoin      . #t)
                 (room          . ,room-name)
                 (canPublish    . ,(not (eq? role 'observer)))
                 (canSubscribe  . #t)
                 (canPublishData . #t)
                 (roomAdmin     . ,(eq? role 'convener)))))))
         (payload       (base64url-encode-string payload-json))
         (signing-input (string-append *jwt-header* "." payload))
         (sig-bv        (hmac-sha256-bv
                         (string->bytevector api-secret "UTF-8")
                         (string->bytevector signing-input "UTF-8")))
         (sig           (base64url-encode-bv sig-bv)))
    (string-append *jwt-header* "." payload "." sig)))

(define (make-livekit-admin-token api-key api-secret)
  "Generate a short-lived LiveKit admin token for server-to-server API calls.
   Valid for 60 seconds."
  (let* ((now (unix-now))
         (payload-json
          (scm->json-string
           `((iss . ,api-key)
             (sub . ,api-key)
             (nbf . ,now)
             (exp . ,(+ now 60))
             (video . ((roomCreate . #t)
                       (roomList   . #t)
                       (roomAdmin  . #t))))))
         (payload       (base64url-encode-string payload-json))
         (signing-input (string-append *jwt-header* "." payload))
         (sig-bv        (hmac-sha256-bv
                         (string->bytevector api-secret "UTF-8")
                         (string->bytevector signing-input "UTF-8")))
         (sig           (base64url-encode-bv sig-bv)))
    (string-append *jwt-header* "." payload "." sig)))
