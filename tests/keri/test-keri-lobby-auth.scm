;;; tests/keri/test-keri-lobby-auth.scm — end-to-end lobby challenge-response
;;;
;;; Exercises the full KERI authentication flow through the ^lobby actor:
;;;   1. keri-challenge → get nonce
;;;   2. Sign nonce with a test Ed25519 keypair
;;;   3. CESR-encode the signature
;;;   4. keri-authenticate → verify signature → return user identity
;;;
;;; Uses a mock KERIA server for keystate and a stub signup-agent for
;;; user lookup. All other lobby sub-actors are no-op stubs.
;;;
;;; Run: guile -L module -L tests tests/keri/test-keri-lobby-auth.scm

(use-modules (playnet test harness)
             (playnet keri bridge)
             (playnet doors lobby)
             (goblins)
             (goblins vat)
             (goblins actor-lib methods)
             (goblins utils crypto)
             (web server)
             (web request)
             (web response)
             (web uri)
             (web http)
             (rnrs bytevectors)
             (ice-9 format)
             ((srfi srfi-1) #:select (every))
             (json))

(declare-opaque-header! "authorization")

;;; ── Test keypair ─────────────────────────────────────────────────────

(define %test-keypair (generate-key-pair))
(define %test-priv (key-pair->private-key %test-keypair))
(define %test-pub-bv (captp-public-key->bytevector
                      (key-pair->public-key %test-keypair)))
(define %test-pub-qb64 (cesr-bytes->qb64 "D" %test-pub-bv))
(define %test-aid "ELobbyTestAID0000000000000000000000000000000")

;;; ── Mock KERIA (keystate only) ───────────────────────────────────────

(define (with-json code body-alist)
  (values
   (build-response
    #:code code
    #:headers '((content-type . (application/json))))
   (scm->json-string body-alist)))

(define (handle-request request body)
  (let* ((method (request-method request))
         (path   (uri-path (request-uri request))))
    (cond
     ((and (eq? method 'GET) (string=? path "/connect"))
      (with-json 200 `(("url" . ,%base) ("agent" . (("i" . ,%test-aid))))))
     ((and (eq? method 'POST) (string=? path "/connect"))
      (with-json 200 `(("agent" . (("i" . ,%test-aid))))))
     ((and (eq? method 'GET) (string-prefix? "/keystate/" path))
      (with-json 200 `(("k" . ,(vector %test-pub-qb64)))))
     (else (values (build-response #:code 404) "not found")))))

(define-values (%port %thread)
  (spawn-mock-server handle-request))

(define %base (format #f "http://127.0.0.1:~a" %port))

(keri-set-urls! %base %base)
(keri-connect! "testbran21chars00000")

;;; ── Stub actors ──────────────────────────────────────────────────────

(define vat (spawn-vat))

(define stub-signup
  (with-vat vat
    (spawn (lambda (_bcom)
             (methods
              ((lookup-aid aid-prefix) "test-user")
              ((register! username email aid oobi) #t))))))

(define stub-noop
  (with-vat vat
    (spawn (lambda (_bcom) (methods)))))

;; ^lobby required positionals: signup-agent ai-svc presence
;; terminal-svc mailbox-mgr planner-service wallet-policy governance-svc
;; (oobi-host and acdc-store are optional; left #f so the auth path
;; falls through to keri-verify-signature against the mock KERIA above.)
(define lobby
  (with-vat vat
    (spawn ^lobby stub-signup
           stub-noop stub-noop stub-noop stub-noop
           stub-noop stub-noop stub-noop)))

;;; ── Test: Challenge-Response Auth ───────────────────────────────────

(format #t "=== KERI Lobby Auth Tests ===~%")

;; Step 1: get a challenge nonce
(define nonce
  (with-vat vat ($ lobby 'keri-challenge %test-aid)))

(check "keri-challenge returns a nonce string"
       (and (string? nonce) (> (string-length nonce) 0)))
(format #t "  nonce: ~a...~%" (substring nonce 0 (min 20 (string-length nonce))))

;; Step 2: sign the nonce with our test keypair
(define sig-sexp (sign (string->utf8 nonce) %test-priv))
(define sig-bv (captp-signature->crypto-signature sig-sexp))
(define sig-qb64 (cesr-bytes->qb64 "0B" sig-bv))

(format #t "  sig:   ~a...~%" (substring sig-qb64 0 (min 20 (string-length sig-qb64))))

;; Step 3: authenticate with valid signature
(define auth-result
  (with-vat vat ($ lobby 'keri-authenticate %test-aid sig-qb64 nonce)))

(check "valid auth: returns a list starting with 'ok"
       (and (pair? auth-result)
            (eq? (car auth-result) 'ok)))

(when (and (pair? auth-result) (eq? (car auth-result) 'ok))
  (check "valid auth: session capability reports the AID"
         (equal? %test-aid
                 (with-vat vat ($ (cadr auth-result) 'whoami)))))

;; Step 4: nonce is consumed — re-auth with same nonce should fail
(define reauth-result
  (with-vat vat ($ lobby 'keri-authenticate %test-aid sig-qb64 nonce)))

(check "replayed nonce: returns error"
       (and (pair? reauth-result)
            (eq? (car reauth-result) 'error)))

;; Step 5: wrong signature → error
(define nonce2
  (with-vat vat ($ lobby 'keri-challenge %test-aid)))

(define wrong-sig-qb64
  (cesr-bytes->qb64 "0B" (make-bytevector 64 42)))  ; garbage sig

(define wrong-result
  (with-vat vat ($ lobby 'keri-authenticate %test-aid wrong-sig-qb64 nonce2)))

(check "wrong signature: returns error"
       (and (pair? wrong-result)
            (eq? (car wrong-result) 'error)))

;; Step 6: AID mismatch → error
(define nonce3
  (with-vat vat ($ lobby 'keri-challenge %test-aid)))

(define mismatch-result
  (with-vat vat
    ($ lobby 'keri-authenticate "EDifferentAID0000000000000000000000000000000"
       sig-qb64 nonce3)))

(check "AID mismatch: returns error"
       (and (pair? mismatch-result)
            (eq? (car mismatch-result) 'error)))

;;; ── Step 7: mesh send budget (rate limit) ───────────────────────────
;;; A session may relay at most %mesh-budget packets per window; the
;;; 31st DATA packet in one window is declined. Fake announcer so the
;;; pipeline reaches the budget check (no reticulum netlayer here).

(define fake-announcer
  (with-vat vat
    (spawn (lambda (_bcom)
             (methods ((send-raw! _hex) 'ok)
                      ((announce-raw! _hex) 'ok)
                      ((register-dest! _hex) 'ok))))))

(define session
  (with-vat vat
    ;; ^lobby-session takes aid-prefix + terminal-svc mailbox-mgr
    ;; governance-svc signup-agent; this suite exercises only the auth/mesh
    ;; methods, so every service is #f.
    (spawn ^lobby-session %test-aid #f #f #f #f)))

;; 24 bytes of zeros: flags 0x00 = HEADER_1 single DATA, long enough.
(define %data-pkt-hex (make-string 48 #\0))

(current-mesh-announcer fake-announcer) ; boot cell — visible everywhere

(define budget-results
  (with-vat vat
    (let loop ((n 0) (acc '()))
      (if (= n 31)
          (reverse acc)
          (loop (+ n 1)
                (cons ($ session 'send-mesh-packet! %data-pkt-hex)
                      acc))))))

(check "mesh budget: first 30 sends pass"
       (every (lambda (r) (eq? r 'ok)) (list-head budget-results 30)))

(check "mesh budget: 31st send is declined"
       (let ((r (list-ref budget-results 30)))
         (and (pair? r) (eq? (car r) 'error))))

;;; ── Summary ─────────────────────────────────────────────────────────

(test-summary!)
