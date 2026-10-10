;;; tests/keri/test-keri-recovery.scm — server recovery tests
;;;
;;; Exercises (playnet keri keria-reconnect):
;;;   - recovery-reconnect!   (set URLs + connect)
;;;   - recovery-sync!        (count AIDs / credentials / contacts)
;;;   - recovery-check-witnesses  (resolve each + classify reachable/unreachable)
;;;   - recovery-check-governance (load AID + registry)
;;;   - recovery-status       (aggregate)
;;;   - recovery-full!        (reconnect + governance-load + sync + status)
;;;
;;; All against a mock KERIA that can simulate:
;;;   - Fresh-start KERIA (empty lists, no governance AID yet)
;;;   - Healthy populated KERIA (AIDs, creds, contacts, governance AID present)
;;;   - Partial witness outage (some OOBI resolves fail)
;;;
;;; Run: guile -L module -L tests tests/keri/test-keri-recovery.scm

(use-modules (playnet test harness)
             (playnet keri bridge)
             (playnet keri credentials)
             (playnet keri inception)
             (playnet keri keria-reconnect)
             (web server)
             (web request)
             (web response)
             (web uri)
             (web http)
             (rnrs bytevectors)
             (ice-9 format)
             (ice-9 regex)
             (json))

(declare-opaque-header! "authorization")

;;; ── Mock state ───────────────────────────────────────────────────────

(define %gov-aid "EGovAID00000000000000000000000000000000000000")
(define %registry "ERegRec00000000000000000000000000000000000")

;; Switchable state — tests tweak these, mock reacts.
(define %aids-exist? #t)
(define %creds-count 3)
(define %contacts-count 2)
(define %gov-exists? #t)

;; Witness resolution: list of witness OOBI -> boolean (reachable?)
(define %witness-reachability
  '(("http://wit1.test/oobi/EWit1" . #t)
    ("http://wit2.test/oobi/EWit2" . #t)
    ("http://wit3.test/oobi/EWit3" . #f)))   ; one unreachable

(define %connect-calls 0)
(define %agent-url #f)

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
  `(("sad" . (("d" . ,(format #f "ECred~a00000000000000000000000000000000000" i))
              ("i" . ,%gov-aid)
              ("s" . ,%schema-member)
              ("a" . (("i" . "EHolder0000000000000000000000000000000000000")))))
    ("status" . (("et" . "iss")))))

(define (handle-request request body)
  (let* ((method (request-method request))
         (path   (uri-path (request-uri request))))
    (cond
     ;; GET /agent/<controller-aid> — Signify keri-connect! probe
     ((and (eq? method 'GET) (string-prefix? "/agent/" path))
      (set! %connect-calls (+ 1 %connect-calls))
      (with-json 200 `(("i" . ,%gov-aid)
                       ("agent" . (("i" . ,%gov-aid))))))

     ;; GET /identifiers — list AIDs
     ((and (eq? method 'GET) (string=? path "/identifiers"))
      (if %aids-exist?
          (with-json 200 (vector `(("prefix" . ,%gov-aid))
                                 `(("prefix" . "EOther0000000000000000000000000000000000"))))
          (with-json 200 (vector))))

     ;; GET /identifiers/{name} — get AID (for gateway-controller-init!)
     ((and (eq? method 'GET) (string-prefix? "/identifiers/" path))
      (if %gov-exists?
          (with-json 200 `(("name" . "playnet-governance")
                           ("prefix" . ,%gov-aid)))
          (with-json 404 `(("title" . "Not Found")))))

     ;; POST /identifiers — keri-create-aid, the register-or-fetch
     ;; gateway-controller-init! calls before the GET above. Its return
     ;; value is unused by the caller (an unresolved operation shape),
     ;; so any 200 is fine here.
     ((and (eq? method 'POST) (string=? path "/identifiers"))
      (with-json 200
        `(("done" . #t)
          ("name" . "playnet-gateway")
          ("response" . (("i" . ,%gov-aid))))))

     ;; POST /credentials/query — honor skip so acdc-sync-credentials
     ;; terminates. KERIA's list route (the bridge moved here from a bare
     ;; GET /credentials, which 401s) carries skip/limit in the body.
     ((and (eq? method 'POST) (string=? path "/credentials/query"))
      (let* ((b    (parse-body body))
             (skip (or (assoc-ref b "skip") 0)))
        (if (zero? skip)
            (with-json 200
              (list->vector (map fake-cred (iota %creds-count))))
            (with-json 200 (vector)))))

     ;; GET /contacts
     ((and (eq? method 'GET) (string=? path "/contacts"))
      (with-json 200
        (list->vector
         (map (lambda (i)
                `(("id" . ,(format #f "EContact~a" i))))
              (iota %contacts-count)))))

     ;; POST /oobis — Signify-ts OOBI resolution (used by recovery-check-witnesses)
     ((and (eq? method 'POST) (string=? path "/oobis"))
      (let* ((b    (parse-body body))
             (oobi (assoc-ref b "url"))
             (reach (assoc-ref %witness-reachability oobi)))
        (if reach
            (with-json 200 `(("done" . #t) ("name" . "op-oobi")))
            (with-json 500 `(("error" . "unreachable"))))))

     ;; POST /identifiers/{name}/registries
     ((and (eq? method 'POST) (string-contains path "/registries"))
      (with-json 200 `(("done" . #t) ("name" . "op-reg") ("regk" . ,%registry))))

     ;; GET /operations/{name}
     ((and (eq? method 'GET) (string-prefix? "/operations/" path))
      (with-json 200 `(("done" . #t) ("regk" . ,%registry))))

     (else
      (values (build-response #:code 404) "not found")))))

(define-values (%port %thread)
  (spawn-mock-server handle-request))

(define %base (format #f "http://127.0.0.1:~a" %port))
(set! %agent-url %base)

(format #t "=== KERI Recovery Tests (mock on ~a) ===~%" %base)

;; Seed witnesses env so recovery-check-witnesses has something to check
(setenv "KERI_WITNESS_OOBIS"
        (string-join (map car %witness-reachability) ","))

;;; ── recovery-reconnect! ─────────────────────────────────────────────

(format #t "~%=== recovery-reconnect! ===~%")

(set! %connect-calls 0)

(recovery-reconnect! "testbran21chars00000"
                     #:agent-url %base
                     #:boot-url %base)

(check "connect was called"
       (>= %connect-calls 1))
(check "agent URL updated to mock"
       (string=? %base (keri-agent-url)))

;;; ── recovery-sync! (healthy populated KERIA) ────────────────────────

(format #t "~%=== recovery-sync! (populated) ===~%")

(set! %aids-exist? #t)
(set! %creds-count 3)
(set! %contacts-count 2)

(let ((report (recovery-sync!)))
  (check "sync returns alist" (pair? report))
  (check "sync: aids count" (= 2 (assoc-ref report 'aids)))
  (check "sync: credentials count" (= 3 (assoc-ref report 'credentials)))
  (check "sync: contacts count" (= 2 (assoc-ref report 'contacts))))

;;; ── recovery-sync! (fresh KERIA) ────────────────────────────────────

(format #t "~%=== recovery-sync! (fresh/empty) ===~%")

(set! %aids-exist? #f)
(set! %creds-count 0)
(set! %contacts-count 0)

(let ((report (recovery-sync!)))
  (check "fresh sync: 0 aids" (= 0 (assoc-ref report 'aids)))
  (check "fresh sync: 0 credentials" (= 0 (assoc-ref report 'credentials)))
  (check "fresh sync: 0 contacts" (= 0 (assoc-ref report 'contacts))))

;;; ── recovery-check-witnesses ────────────────────────────────────────

(format #t "~%=== recovery-check-witnesses ===~%")

(let ((report (recovery-check-witnesses)))
  (check "total witnesses = 3" (= 3 (assoc-ref report 'total)))
  (check "reachable = 2" (= 2 (assoc-ref report 'reachable)))
  (check "unreachable = 1" (= 1 (assoc-ref report 'unreachable)))
  (check "details is a list of (oobi . status) pairs"
         (and (list? (assoc-ref report 'details))
              (= 3 (length (assoc-ref report 'details))))))

;;; ── recovery-check-governance ───────────────────────────────────────

(format #t "~%=== recovery-check-governance ===~%")

;; Initialize the controller AID so the prefix is set
(set! %gov-exists? #t)
(gateway-controller-init!)

(let ((report (recovery-check-governance)))
  (check "governance ok = #t" (eq? #t (assoc-ref report 'ok)))
  (check "governance prefix matches" (equal? %gov-aid (assoc-ref report 'prefix))))

;; Simulate governance AID missing
(set! %gov-exists? #f)
;; governance-check reads keri-get-aid which hits /identifiers/{name}
(let ((report (recovery-check-governance)))
  (check "missing governance: ok = #f" (eq? #f (assoc-ref report 'ok)))
  (check "missing governance: reports error" (assoc-ref report 'error)))

;;; ── recovery-status ─────────────────────────────────────────────────

(format #t "~%=== recovery-status ===~%")

(set! %gov-exists? #t)

(let ((status (recovery-status)))
  (check "status has witnesses section"
         (pair? (assoc-ref status 'witnesses)))
  (check "status has governance section"
         (pair? (assoc-ref status 'governance))))

;;; ── recovery-full! ──────────────────────────────────────────────────

(format #t "~%=== recovery-full! ===~%")

(set! %aids-exist? #t)
(set! %gov-exists? #t)
(set! %creds-count 1)
(set! %contacts-count 1)
(set! %connect-calls 0)

(let ((status (recovery-full! "testbran21chars00000"
                              #:agent-url %base
                              #:boot-url %base)))
  (check "full recovery invokes connect" (>= %connect-calls 1))
  (check "full recovery returns status alist"
         (and (pair? status) (assoc-ref status 'witnesses))))

;;; ── Summary ─────────────────────────────────────────────────────────

(test-summary!)
