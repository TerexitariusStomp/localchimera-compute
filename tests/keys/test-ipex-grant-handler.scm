;;; tests/keys/test-ipex-grant-handler.scm — handle-ipex-grant unit tests
;;;
;;; Exercises the IPEX grant handler against a mock KERIA. We record
;;; every HTTP request and assert the handler made the spec-conformant
;;; decisions:
;;;
;;;   - known schema + accepted issuer → POST /ipex/admit
;;;   - unknown schema                  → POST /ipex/spurn
;;;   - issuer rejected by policy        → POST /ipex/spurn
;;;   - credential already admitted     → no admit, no spurn
;;;   - apply/offer/agree stubs         → always spurn
;;;
;;; The handler itself lives in (playnet federation keria-notifications) but is
;;; not exported; we re-resolve it via `module-ref` for testing.
;;;
;;; Run: guile -L module -L tests tests/keys/test-ipex-grant-handler.scm

(use-modules (playnet test harness)
             (playnet keri bridge)
             (playnet keri credentials)
             (playnet federation ipex-policy)
             (playnet credentials membership)
             (web server)
             (web request)
             (web response)
             (web uri)
             (rnrs bytevectors)
             (ice-9 format)
             (json))

;; Pull the (non-exported) handler symbols out of the notifications module.
(define notif-mod (resolve-module '(playnet federation keria-notifications)))
(define handle-ipex-grant (module-ref notif-mod 'handle-ipex-grant))
(define handle-ipex-apply (module-ref notif-mod 'handle-ipex-apply))

;; Install the default policy table so federation-membership etc. resolve.
(install-default-grant-policies!)

;; ── Mock state ────────────────────────────────────────────────────────

(define %issuer-aid    "EIssuer000000000000000000000000000000000000")
(define %issuee-aid    "EIssuee000000000000000000000000000000000000")
(define %grant-said    "EGrant000000000000000000000000000000000000A")
(define %cred-said     "ECred0000000000000000000000000000000000000A")
(define %unknown-schema "playnet-not-a-real-schema/v999")

(define %posts '())   ; list of (path . body-alist) in reverse order
(define %credential-exists? #f)
(define %fixed-schema *schema-playnet-membership*)  ; default informational

(define (with-json code body-alist)
  (values (build-response
           #:code code
           #:headers '((content-type . (application/json))))
          (scm->json-string body-alist)))

(define (parse-body body)
  (let ((s (if (bytevector? body) (utf8->string body) (or body ""))))
    (if (string-null? s) '() (json-string->scm s))))

(define (handle-request request body)
  (let* ((method (request-method request))
         (path   (uri-path (request-uri request))))
    (when (eq? method 'POST)
      (set! %posts (cons (cons path (parse-body body)) %posts)))
    (cond
     ;; keri-connect handshake — minimal stub
     ((string=? path "/connect")    (with-json 200 '(("ok" . #t))))
     ;; the bridge probes / on connect
     ((string=? path "/")           (with-json 200 '(("ok" . #t))))
     ;; keri-list-aids — needed by outbound-exchange? cache refresh
     ((string=? path "/identifiers") (with-json 200 (vector)))
     ;; keri-get-exchange — returns synthetic IPEX grant exn
     ((string-prefix? "/exchanges/" path)
      (with-json 200
        `(("exn" . (("t" . "exn")
                    ("i" . ,%issuer-aid)
                    ("rp" . ,%issuee-aid)
                    ("r" . "/ipex/grant")
                    ("a" . (("acdc" . (("d" . ,%cred-said)
                                       ("i" . ,%issuer-aid)
                                       ("s" . ,%fixed-schema)
                                       ("a" . (("i"  . ,%issuee-aid)
                                               ("dt" . "2026-05-20T00:00:00Z")))))))))
          ("sigs" . #()))))
     ;; keri-get-credential — flips on idempotency-test
     ((string-prefix? "/credentials/" path)
      (if %credential-exists?
          (with-json 200
            `(("sad" . (("d" . ,%cred-said) ("i" . ,%issuer-aid)
                        ("s" . ,%fixed-schema)
                        ("a" . (("i" . ,%issuee-aid)))))
              ("status" . "issued")))
          (with-json 404 `(("title" . "Not Found")))))
     ;; All IPEX submits (admit/spurn) — record and ack
     ((string-contains path "/ipex/")
      (with-json 200 `(("done" . #t) ("name" . "op-ipex"))))
     ;; All operations — done
     ((string-prefix? "/operations/" path)
      (with-json 200 `(("done" . #t))))
     ;; Identifier name → AID (needed by exchange-body builder)
     ((string-prefix? "/identifiers/" path)
      (with-json 200
        `(("name" . "playnet-governance")
          ("prefix" . ,%issuee-aid)
          ("state" . (("d" . ,%issuee-aid) ("s" . "0")
                      ("i" . ,%issuee-aid)
                      ("k" . #("Dfake000000000000000000000000000000000000000"))))
          ("d" . ,%issuee-aid))))
     (else (values (build-response #:code 404) "not found")))))

(define-values (%port %thread) (spawn-mock-server handle-request))
(define %base (format #f "http://127.0.0.1:~a" %port))
(format #t "=== IPEX grant-handler (mock on ~a) ===~%" %base)
(keri-set-urls! %base %base)
(keri-connect! "testbran21chars00000")

;; Helpers
(define (posts-to-path-prefix prefix)
  (filter (lambda (p) (string-contains (car p) prefix)) %posts))

(define (reset-posts!) (set! %posts '()))

(define (synthetic-note said)
  `(("i" . "noteid-1")
    ("a" . (("r" . "/exn/ipex/grant") ("d" . ,said)))))

;; ── Happy path: known schema, informational policy accepts ──────────

(reset-posts!)
(set! %credential-exists? #f)
(set! %fixed-schema *schema-playnet-membership*)
(catch #t
  (lambda ()
    (handle-ipex-grant "/exn/ipex/grant" %grant-said
                       (synthetic-note %grant-said)))
  (lambda (key . args)
    (format #t "  handler error (ignored): ~a ~a~%" key args)))

(check "happy: at least one admit POSTed"
       (>= (length (posts-to-path-prefix "/ipex/admit")) 1))

(check "happy: no spurn on accept"
       (length (posts-to-path-prefix "/ipex/spurn"))
       0)

;; ── Unknown schema → spurn ──────────────────────────────────────────

(reset-posts!)
(set! %credential-exists? #f)
(set! %fixed-schema %unknown-schema)
(catch #t
  (lambda ()
    (handle-ipex-grant "/exn/ipex/grant" %grant-said
                       (synthetic-note %grant-said)))
  (lambda _ #f))

(check "unknown schema: spurn POSTed"
       (>= (length (posts-to-path-prefix "/ipex/spurn")) 1))

(check "unknown schema: no admit"
       (length (posts-to-path-prefix "/ipex/admit"))
       0)

;; ── Issuer rejected by policy (federation-membership w/ no graph) ──

(reset-posts!)
(set! %credential-exists? #f)
(set! %fixed-schema *schema-playnet-federation-membership*)
(catch #t
  (lambda ()
    (handle-ipex-grant "/exn/ipex/grant" %grant-said
                       (synthetic-note %grant-said)))
  (lambda _ #f))

(check "issuer rejected: spurn POSTed"
       (>= (length (posts-to-path-prefix "/ipex/spurn")) 1))

(check "issuer rejected: no admit"
       (length (posts-to-path-prefix "/ipex/admit"))
       0)

;; ── Idempotency: credential already exists → no admit, no spurn ────

(reset-posts!)
(set! %credential-exists? #t)
(set! %fixed-schema *schema-playnet-membership*)
(catch #t
  (lambda ()
    (handle-ipex-grant "/exn/ipex/grant" %grant-said
                       (synthetic-note %grant-said)))
  (lambda _ #f))

(check "idempotency: no admit when already present"
       (length (posts-to-path-prefix "/ipex/admit"))
       0)

(check "idempotency: no spurn either"
       (length (posts-to-path-prefix "/ipex/spurn"))
       0)

;; ── Stub handler: apply always spurns ──────────────────────────────

(reset-posts!)
(set! %credential-exists? #f)
(set! %fixed-schema *schema-playnet-membership*)
(catch #t
  (lambda ()
    (handle-ipex-apply "/exn/ipex/apply" %grant-said
                       (synthetic-note %grant-said)))
  (lambda _ #f))

(check "apply stub: spurn POSTed"
       (>= (length (posts-to-path-prefix "/ipex/spurn")) 1))

(test-summary!)
