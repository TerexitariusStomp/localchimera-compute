;;; tests/keri/test-keri-credentials-ipex.scm — IPEX flow + multi-sig + schema
;;;
;;; Complements test-keri-credentials.scm (push flow + verification) by
;;; covering the rest of (playnet keri credentials):
;;;
;;;   Pull (request) flow:
;;;     - acdc-apply  (holder requests credential)
;;;     - acdc-offer  (issuer offers in response)
;;;     - acdc-agree  (holder agrees to offer)
;;;
;;;   Multi-sig IPEX wrappers:
;;;     - acdc-multisig-admit
;;;     - acdc-multisig-offer
;;;     - acdc-multisig-grant
;;;
;;;   Schema resolution + cache:
;;;     - acdc-get-schema
;;;     - acdc-resolve-schema
;;;
;;;   Availability + sync:
;;;     - acdc-ensure-available  (success + retry path)
;;;     - acdc-sync-credentials  (paginated)
;;;
;;;   Registry creation:
;;;     - acdc-create-registry
;;;
;;; Run: guile -L module -L tests tests/keri/test-keri-credentials-ipex.scm

(use-modules (playnet test harness)
             (playnet keri bridge)
             (playnet keri credentials)
             (web server)
             (web request)
             (web response)
             (web uri)
             (web http)
             (rnrs bytevectors)
             (ice-9 format)
             (ice-9 regex)
             (json)
             (srfi srfi-1))

(declare-opaque-header! "authorization")

;;; ── Mock state ───────────────────────────────────────────────────────

(define %issuer-aid "EIssuer000000000000000000000000000000000000")
(define %holder-aid "EHolder000000000000000000000000000000000000")
(define %registry   "ERegIPEX0000000000000000000000000000000000")
(define %cred-said  "ECredIPEX000000000000000000000000000000000")
(define %schema-said "ESchemaIPEX0000000000000000000000000000000")

;; Tracking
(define %exchange-bodies '())   ; list of POST /exchanges bodies
(define %schema-fetch-count 0)
(define %schema-available? #t)
(define %cred-available-after-attempt 1)
(define %cred-attempts 0)
(define %total-creds-in-store 50)   ; for paginated sync test

(define (with-json code body)
  (values
   (build-response
    #:code code
    #:headers '((content-type . (application/json))))
   (scm->json-string body)))

(define (parse-body body)
  (let ((s (if (bytevector? body) (utf8->string body) (or body ""))))
    (if (string-null? s) '() (json-string->scm s))))

(define (fake-cred i)
  `(("sad" . (("d" . ,(format #f "ECredSync~a000000000000000000000000000000000" i))))))

(define (handle-request request body)
  (let* ((method (request-method request))
         (path   (uri-path (request-uri request)))
         (query  (or (uri-query (request-uri request)) "")))
    (cond
     ((string=? path "/connect")
      (with-json 200 `(("url" . ,%base) ("agent" . (("i" . ,%issuer-aid))))))

     ;; POST /exchanges
     ((and (eq? method 'POST) (string-contains path "/ipex/"))
      (let ((b (parse-body body)))
        (set! %exchange-bodies (cons b %exchange-bodies)))
      (with-json 200 `(("done" . #t) ("d" . "EExnNew"))))

     ;; GET /schema/{said}
     ((and (eq? method 'GET) (string-prefix? "/schema/" path))
      (set! %schema-fetch-count (+ 1 %schema-fetch-count))
      (if %schema-available?
          (with-json 200 `(("$id" . ,%schema-said)
                           ("title" . "TestSchema")
                           ("type" . "object")))
          (with-json 404 `(("title" . "Not Found")))))

     ;; POST /oobis (Signify-ts OOBI resolve, used by acdc-resolve-schema fallback)
     ((and (eq? method 'POST) (string=? path "/oobis"))
      (with-json 200 `(("done" . #t) ("name" . "op-oobi"))))

     ;; GET /identifiers/{name} — needed by registry-body
     ((and (eq? method 'GET) (string-prefix? "/identifiers/" path))
      (with-json 200 `(("name" . "gov") ("prefix" . ,%issuer-aid)
                       ("d" . ,%issuer-aid)
                       ("k" . ,(vector "Dfake")))))

     ;; GET /operations/{name}
     ((and (eq? method 'GET) (string-prefix? "/operations/" path))
      (with-json 200 `(("done" . #t) ("response" . (("ok" . #t)))
                       ("regk" . ,%registry))))

     ;; POST /identifiers/{name}/registries
     ((and (eq? method 'POST) (string-contains path "/registries"))
      (with-json 200 `(("done" . #t) ("name" . "op-reg") ("regk" . ,%registry))))

     ;; GET /credentials/{said} — for acdc-ensure-available
     ((and (eq? method 'GET) (string-prefix? "/credentials/" path))
      (set! %cred-attempts (+ 1 %cred-attempts))
      (if (>= %cred-attempts %cred-available-after-attempt)
          (with-json 200 `(("d" . ,%cred-said)))
          (with-json 404 `(("title" . "Not Found")))))

     ;; POST /credentials/query — paginated sync (KERIA's list route; the
     ;; bridge moved here from GET /credentials, which real KERIA 401s, and
     ;; carries skip/limit in the body rather than the query string).
     ((and (eq? method 'POST) (string=? path "/credentials/query"))
      (let* ((b     (parse-body body))
             (skip  (or (assoc-ref b "skip") 0))
             (limit (or (assoc-ref b "limit") 24))
             (remaining (max 0 (- %total-creds-in-store skip)))
             (n (min limit remaining)))
        (with-json 200 (list->vector (map fake-cred (iota n skip))))))

     (else (values (build-response #:code 404) "not found")))))

(define-values (%port %thread)
  (spawn-mock-server handle-request))
(define %base (format #f "http://127.0.0.1:~a" %port))

(format #t "=== KERI Credentials IPEX/multisig/schema (mock on ~a) ===~%" %base)
(keri-set-urls! %base %base)
(keri-connect! "testbran21chars00000")

;;; ── IPEX pull flow: apply → offer → agree ───────────────────────────
;;; All IPEX functions now produce {exn, sigs, atc, rec} bodies with
;;; EXN events. We verify: exn.t = "exn", exn has the right route in
;;; exn.r, and the body has sigs.

(format #t "~%=== IPEX pull flow ===~%")

(set! %exchange-bodies '())
(acdc-apply "holder" %issuer-aid %schema-said
            #:attributes '(("name" . "Alice")))
(check "apply emitted one exchange" (= 1 (length %exchange-bodies)))
(let* ((b (car %exchange-bodies))
       (exn (assoc-ref b "exn")))
  (check "apply has exn event" (and exn (equal? "exn" (assoc-ref exn "t"))))
  (check "apply exn route is /ipex/apply"
         (equal? "/ipex/apply" (assoc-ref exn "r")))
  (check "apply body has sigs" (vector? (assoc-ref b "sigs"))))

(set! %exchange-bodies '())
(acdc-offer "gov" %holder-aid "EApplySaid" %cred-said)
(let* ((b (car %exchange-bodies))
       (exn (assoc-ref b "exn")))
  (check "offer has exn event" (and exn (equal? "exn" (assoc-ref exn "t"))))
  (check "offer exn route is /ipex/offer"
         (equal? "/ipex/offer" (assoc-ref exn "r")))
  ;; IPEX answer shape: the message being answered rides exn.p.
  (check "offer anchors the apply in exn.p"
         (equal? "EApplySaid" (assoc-ref exn "p"))))

(set! %exchange-bodies '())
(acdc-agree "holder" %issuer-aid "EOfferSaid")
(let* ((b (car %exchange-bodies))
       (exn (assoc-ref b "exn")))
  (check "agree has exn event" (and exn (equal? "exn" (assoc-ref exn "t"))))
  (check "agree exn route is /ipex/agree"
         (equal? "/ipex/agree" (assoc-ref exn "r")))
  (check "agree anchors the offer in exn.p"
         (equal? "EOfferSaid" (assoc-ref exn "p"))))

;;; ── Multi-sig IPEX wrappers ─────────────────────────────────────────
;;; Multi-sig functions produce the same {exn, sigs, atc, rec} shape,
;;; routed through the group AID's IPEX endpoints.

(format #t "~%=== Multi-sig IPEX wrappers ===~%")

(set! %exchange-bodies '())
(acdc-multisig-admit "group-aid" "EGrantSaid")
(let* ((b (car %exchange-bodies))
       (exn (assoc-ref b "exn")))
  (check "multisig-admit has exn event"
         (and exn (equal? "exn" (assoc-ref exn "t"))))
  (check "multisig-admit exn route is /ipex/admit"
         (equal? "/ipex/admit" (assoc-ref exn "r")))
  (check "multisig-admit anchors the grant in exn.p"
         (equal? "EGrantSaid" (assoc-ref exn "p"))))

(set! %exchange-bodies '())
(acdc-multisig-offer "group-aid" %holder-aid "EApplySaid" %cred-said)
(let* ((b (car %exchange-bodies))
       (exn (assoc-ref b "exn")))
  (check "multisig-offer has exn event"
         (and exn (equal? "exn" (assoc-ref exn "t"))))
  (check "multisig-offer exn route is /ipex/offer"
         (equal? "/ipex/offer" (assoc-ref exn "r"))))

(set! %exchange-bodies '())
(acdc-multisig-grant "group-aid" %holder-aid %cred-said)
(let* ((b (car %exchange-bodies))
       (exn (assoc-ref b "exn")))
  (check "multisig-grant has exn event"
         (and exn (equal? "exn" (assoc-ref exn "t"))))
  (check "multisig-grant exn route is /ipex/grant"
         (equal? "/ipex/grant" (assoc-ref exn "r"))))

;;; ── Schema resolution + cache ───────────────────────────────────────

(format #t "~%=== Schema resolution + cache ===~%")

(set! %schema-fetch-count 0)
(set! %schema-available? #t)

(let ((s1 (acdc-get-schema %schema-said)))
  (check "first fetch returns schema alist"
         (equal? %schema-said (assoc-ref s1 "$id")))
  (check "first fetch hit /schema/" (= 1 %schema-fetch-count)))

;; Second fetch — should be served from cache, no extra HTTP call
(let ((s2 (acdc-get-schema %schema-said)))
  (check "second fetch served from cache (no extra HTTP)"
         (= 1 %schema-fetch-count))
  (check "cached value matches"
         (equal? %schema-said (assoc-ref s2 "$id"))))

;; resolve-schema with cached value — no need to hit network
(let ((s3 (acdc-resolve-schema %schema-said)))
  (check "resolve-schema returns from cache"
         (equal? %schema-said (assoc-ref s3 "$id"))))

;; Schema not in cache and not resolvable → error
(let ((unknown "EUnknownSchema00000000000000000000000000"))
  (set! %schema-available? #f)
  (check-error "resolve-schema with no OOBI raises when missing"
               (lambda () (acdc-resolve-schema unknown))))

(set! %schema-available? #t)

;;; ── Availability retry ──────────────────────────────────────────────

(format #t "~%=== acdc-ensure-available ===~%")

(set! %cred-attempts 0)
(set! %cred-available-after-attempt 1)
(check "available immediately"
       (eq? #t (acdc-ensure-available %cred-said #:retries 1 #:delay-s 0)))

(set! %cred-attempts 0)
(set! %cred-available-after-attempt 3)
(check "becomes available after 3 attempts"
       (eq? #t (acdc-ensure-available %cred-said #:retries 5 #:delay-s 0)))
(check "took at least 3 attempts"
       (>= %cred-attempts 3))

(set! %cred-attempts 0)
(set! %cred-available-after-attempt 99)
(check-error "raises after retries exhausted"
             (lambda ()
               (acdc-ensure-available "ENeverArrives000000000000000000"
                                      #:retries 2 #:delay-s 0)))

;;; ── Paginated sync ──────────────────────────────────────────────────

(format #t "~%=== acdc-sync-credentials (pagination) ===~%")

(set! %total-creds-in-store 50)
(let ((all (acdc-sync-credentials #:limit 24)))
  (check "sync returns 50 creds (across pages)"
         (= 50 (length all))))

(set! %total-creds-in-store 0)
(let ((all (acdc-sync-credentials #:limit 24)))
  (check "sync on empty store returns empty list"
         (null? all)))

;;; ── Registry creation ───────────────────────────────────────────────

(format #t "~%=== acdc-create-registry ===~%")

(let ((rid (acdc-create-registry "gov" "playnet-credentials")))
  (check "create-registry returns the registry id"
         (equal? %registry rid))
  (check "acdc-registry-id reflects created id"
         (equal? %registry (acdc-registry-id))))

;;; ── Summary ─────────────────────────────────────────────────────────

(test-summary!)
