;;; tests/keri/test-keri-bridge.scm — KERI bridge tests with mock KERIA
;;;
;;; Exercises the critical paths in (playnet keri bridge):
;;; - Agent boot + connect
;;; - AID creation
;;; - OOBI resolution
;;; - Ed25519 signature verification (keri-verify-signature) using a
;;;   Guile-generated keypair — the most critical test, because the
;;;   original code was broken and has been rewritten to use
;;;   (goblins utils crypto).
;;;
;;; Run: guile -L module -L tests tests/keri/test-keri-bridge.scm

(use-modules (playnet test harness)
             (playnet keri bridge)
             (goblins utils crypto)
             (web server)
             (web request)
             (web response)
             (web uri)
             (web http)
             (rnrs bytevectors)
             (ice-9 format)
             (ice-9 match)
             (json))

;;; ── Test Ed25519 keypair (generated once, used across tests) ─────────

(define %test-keypair (generate-key-pair))
(define %test-priv (key-pair->private-key %test-keypair))
(define %test-pub-sexp (key-pair->public-key %test-keypair))
(define %test-pub-bv (captp-public-key->bytevector %test-pub-sexp))

;; CESR-encode the public key: 'D' prefix + base64url(32 bytes)
(define %test-pub-qb64 (cesr-bytes->qb64 "D" %test-pub-bv))

(define %test-aid "ETestAID000000000000000000000000000000000000")
(define %test-bran "testsecretpasscode21")

;;; ── Mock KERIA server ────────────────────────────────────────────────

(declare-opaque-header! "authorization")

(define %boot-requests 0)
(define %connect-requests 0)
(define %create-aid-requests 0)
(define %oobi-requests 0)
(define %last-create-body #f)

(define (parse-body body)
  (let ((s (if (bytevector? body) (utf8->string body) (or body ""))))
    (if (string-null? s) '() (json-string->scm s))))

(define (with-json code body-alist)
  (values
   (build-response
    #:code code
    #:headers '((content-type . (application/json))))
   (scm->json-string body-alist)))

(define (handle-request request body)
  (let* ((method (request-method request))
         (path   (uri-path (request-uri request)))
         (query  (or (uri-query (request-uri request)) "")))
    (cond
     ;; POST /boot
     ((and (eq? method 'POST) (string=? path "/boot"))
      (set! %boot-requests (+ 1 %boot-requests))
      (with-json 200
        `(("controller" . (("state" . (("i" . ,%test-aid))))))))

     ;; GET /agent/<controller-aid>  (Signify keri-connect! probe)
     ((and (eq? method 'GET) (string-prefix? "/agent/" path))
      (set! %connect-requests (+ 1 %connect-requests))
      (with-json 200
        `(("i" . ,%test-aid)
          ("agent" . (("i" . ,%test-aid))))))

     ;; POST /identifiers (create AID)
     ((and (eq? method 'POST) (string=? path "/identifiers"))
      (set! %create-aid-requests (+ 1 %create-aid-requests))
      (set! %last-create-body (parse-body body))
      (with-json 200
        `(("done" . #t)
          ("name" . "op-create-aid")
          ("response" . (("i" . "ENewAID00000000000000000000000000000000000000"))))))

     ;; GET /identifiers/{name}
     ((and (eq? method 'GET) (string-prefix? "/identifiers/" path))
      (with-json 200
        `(("name" . "test-aid")
          ("state" . (("i" . ,%test-aid)
                      ("k" . ,(vector %test-pub-qb64)))))))

     ;; GET /keystate/{aid}
     ((and (eq? method 'GET) (string-prefix? "/keystate/" path))
      (with-json 200
        `(("k" . ,(vector %test-pub-qb64)))))

     ;; POST /oobis (Signify-ts OOBI resolution)
     ((and (eq? method 'POST) (string=? path "/oobis"))
      (set! %oobi-requests (+ 1 %oobi-requests))
      (with-json 200
        `(("done" . #t) ("name" . "op-oobi"))))

     ;; GET /operations/{name}
     ((and (eq? method 'GET) (string-prefix? "/operations/" path))
      (with-json 200
        `(("done" . #t) ("response" . (("i" . ,%test-aid))))))

     (else
      (values (build-response #:code 404) "not found")))))

;;; ── Start mock ──────────────────────────────────────────────────────

(define-values (%port %thread)
  (spawn-mock-server handle-request))

(define %base (format #f "http://127.0.0.1:~a" %port))

(format #t "=== KERI Bridge Tests (mock KERIA on ~a) ===~%" %base)

;; Point the bridge at the mock server.
(keri-set-urls! %base %base)

;;; ── Test: Boot + Connect ────────────────────────────────────────────

(format #t "~%=== Boot + Connect ===~%")

(keri-boot! "test-agent" %test-bran)
(check "keri-boot! called the mock" (= 1 %boot-requests))

;; The mock's /boot reply carries no agent AID, so keri-boot! follows
;; up with the /agent/<controller> probe — the same endpoint
;; keri-connect! uses. Count connect's own call as a delta.
(define %connects-after-boot %connect-requests)
(keri-connect! %test-bran)
(check "keri-connect! called the mock"
       (= (+ 1 %connects-after-boot) %connect-requests))

;;; ── Test: Create AID ────────────────────────────────────────────────

(format #t "~%=== Create AID ===~%")

(let ((result (keri-create-aid "alice")))
  (check "keri-create-aid returned a result" (pair? result))
  (check "mock saw the create request" (= 1 %create-aid-requests))
  (check "create body has 'name' field"
         (equal? "alice" (assoc-ref %last-create-body "name"))))

;;; ── Test: OOBI Resolution ───────────────────────────────────────────

(format #t "~%=== OOBI Resolution ===~%")

(let ((result (keri-resolve-oobi "http://example.com/oobi/EFoo")))
  (check "keri-resolve-oobi returned a result" (pair? result))
  (check "mock saw the OOBI request" (= 1 %oobi-requests)))

;;; ── Test: Signature Verification (CRITICAL) ─────────────────────────
;;;
;;; This is the test that catches the original broken code. We generate
;;; a real Ed25519 signature using the Goblins crypto module, CESR-encode
;;; it, and verify it through the bridge's keri-verify-signature function
;;; which fetches the pubkey from the mock KERIA keystate endpoint.

(format #t "~%=== Signature Verification ===~%")

(define %test-message "challenge-nonce-abc123")
(define %test-msg-bv (string->utf8 %test-message))

;; Sign the message with our test keypair
(define %test-sig-sexp (sign %test-msg-bv %test-priv))
(define %test-sig-bv (captp-signature->crypto-signature %test-sig-sexp))

;; CESR-encode the signature: '0B' prefix + base64url(64 bytes)
(define %test-sig-qb64 (cesr-bytes->qb64 "0B" %test-sig-bv))

(format #t "  pubkey qb64: ~a...~%" (substring %test-pub-qb64 0 20))
(format #t "  sig qb64:    ~a...~%" (substring %test-sig-qb64 0 20))

;; Verify: correct message → #t
(let ((result (keri-verify-signature %test-aid %test-message %test-sig-qb64)))
  (check "valid signature verifies as #t" (eq? #t result)))

;; Verify: wrong message → #f
(let ((result (keri-verify-signature %test-aid "wrong-message" %test-sig-qb64)))
  (check "wrong message verifies as #f" (eq? #f result)))

;; Verify: CESR round-trip (encode then decode)
(let* ((decoded-pub (cesr-qb64->bytes %test-pub-qb64))
       (decoded-sig (cesr-qb64->bytes %test-sig-qb64)))
  (check "CESR pubkey round-trips to 32 bytes"
         (= 32 (bytevector-length decoded-pub)))
  (check "CESR sig round-trips to 64 bytes"
         (= 64 (bytevector-length decoded-sig)))
  (check "decoded pubkey matches original"
         (equal? %test-pub-bv decoded-pub)))

;;; ── keri-as-list — KERIA reply-shape normalizer ──────────────────────
;;; Locks in the three-shape contract: vector → list, pair → pass-through,
;;; anything else (notably #f for missing keys) → '(). This used to be
;;; nine ad-hoc inlinings across the keri/* layer with drifting fallback
;;; semantics; one canonical helper now, this test pins it.

(check "keri-as-list: vector → list"
       (equal? '(1 2 3) (keri-as-list #(1 2 3))))
(check "keri-as-list: empty vector → '()"
       (null? (keri-as-list #())))
(check "keri-as-list: list passes through"
       (equal? '(a b) (keri-as-list '(a b))))
(check "keri-as-list: #f → '() (missing-key safe)"
       (null? (keri-as-list #f)))
(check "keri-as-list: '() → '()"
       (null? (keri-as-list '())))

;;; ── assoc-path — nested KERIA-payload walker ─────────────────────────
;;; 10 sites of `(assoc-ref (assoc-ref … …) …)` collapsed to one helper.
;;; Three properties matter: walks N levels, returns #f at the first
;;; missing link, and is #f-safe when an intermediate node isn't a pair.

(let ((note '(("a" . (("r" . "/foo") ("d" . "EXX")))
              ("i" . "EZZ"))))
  (check "assoc-path: 1-level == assoc-ref"
         (string=? "EZZ" (assoc-path note "i")))
  (check "assoc-path: 2-level walks down"
         (string=? "/foo" (assoc-path note "a" "r")))
  (check "assoc-path: missing intermediate → #f"
         (eq? #f (assoc-path note "missing" "r")))
  (check "assoc-path: missing leaf → #f"
         (eq? #f (assoc-path note "a" "missing")))
  (check "assoc-path: 0 keys returns OBJ"
         (eq? note (assoc-path note))))
(check "assoc-path: non-pair input safely returns #f"
       (eq? #f (assoc-path #f "a" "b")))

;;; ── Summary ─────────────────────────────────────────────────────────

(test-summary!)
