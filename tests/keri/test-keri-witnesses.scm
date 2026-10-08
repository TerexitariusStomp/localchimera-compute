;;; tests/keri/test-keri-witnesses.scm — witness selection + OOBI sharing tests
;;;
;;; Exercises (playnet keri witnesses):
;;;   - keri-toad-for-count  (pure — all threshold bands + error path)
;;;   - keri-get-available-witnesses  (parses /config iurls, dedupes by EID)
;;;   - keri-get-member-oobi  (GET /identifiers/{aid}/oobi)
;;;   - keri-share-witness-oobis!  (POST /replies/{aid} per witness per contact)
;;;   - keri-share-member-oobi!  (POST /replies/{aid} per recipient)
;;;
;;; Run: guile -L module -L tests tests/keri/test-keri-witnesses.scm

(use-modules (playnet test harness)
             (playnet keri bridge)
             (playnet keri witnesses)
             (web server)
             (web request)
             (web response)
             (web uri)
             (web http)
             (rnrs bytevectors)
             (ice-9 format)
             (json)
             (srfi srfi-1))

(declare-opaque-header! "authorization")

;;; ── Toad table (pure, no mock needed) ────────────────────────────────

(format #t "=== keri-toad-for-count ===~%")

(define (toad-of n)
  (call-with-values (lambda () (keri-toad-for-count n))
    (lambda (toad sel) toad)))
(define (sel-of n)
  (call-with-values (lambda () (keri-toad-for-count n))
    (lambda (toad sel) sel)))

(check "n=6: toad=4, select=6" (and (= 4 (toad-of 6)) (= 6 (sel-of 6))))
(check "n=7: toad=5, select=7" (and (= 5 (toad-of 7)) (= 7 (sel-of 7))))
(check "n=8: still toad=5 (no 8-band)" (and (= 5 (toad-of 8)) (= 7 (sel-of 8))))
(check "n=9: toad=6, select=9" (and (= 6 (toad-of 9)) (= 9 (sel-of 9))))
(check "n=10: toad=7, select=10" (and (= 7 (toad-of 10)) (= 10 (sel-of 10))))
(check "n=11: still toad=7 (no 11-band)" (and (= 7 (toad-of 11)) (= 10 (sel-of 11))))
(check "n=12: toad=8, select=12" (and (= 8 (toad-of 12)) (= 12 (sel-of 12))))
(check "n=50: saturates at toad=8, select=12"
       (and (= 8 (toad-of 50)) (= 12 (sel-of 50))))
(check-error "n=5: error (insufficient witnesses)"
             (lambda () (keri-toad-for-count 5)))
(check-error "n=0: error (insufficient witnesses)"
             (lambda () (keri-toad-for-count 0)))

;;; ── Mock state ────────────────────────────────────────────────────────

(define %wit-oobis
  (vector
   ;; 6 unique witnesses
   "http://wit1.test:5642/oobi/BWitEID1example000000000000000000000000000/controller?role=witness"
   "http://wit2.test:5642/oobi/BWitEID2example000000000000000000000000000/controller?role=witness"
   "http://wit3.test:5642/oobi/BWitEID3example000000000000000000000000000/controller?role=witness"
   "http://wit4.test:5642/oobi/BWitEID4example000000000000000000000000000/controller?role=witness"
   "http://wit5.test:5642/oobi/BWitEID5example000000000000000000000000000/controller?role=witness"
   "http://wit6.test:5642/oobi/BWitEID6example000000000000000000000000000/controller?role=witness"
   ;; Duplicate of witness 1 (same EID) — should be deduped
   "http://wit1b.test:5642/oobi/BWitEID1example000000000000000000000000000/controller?role=witness"
   ;; Non-witness role — should be filtered out
   "http://agent.test:5642/oobi/BAgentEID0000000000000000000000000000000000/controller?role=agent"))

(define %member-oobi "http://mem.test:5642/oobi/EMemberAID00000000000000000000000000000000/agent/BAgent00000000000000000000000000000000000")

(define %reply-calls '())     ; list of (recipient . body-alist)
(define %oobi-get-count 0)

(define (with-json code body-alist-or-vec)
  (values
   (build-response
    #:code code
    #:headers '((content-type . (application/json))))
   (scm->json-string body-alist-or-vec)))

(define (parse-body body)
  (let ((s (if (bytevector? body) (utf8->string body) (or body ""))))
    (if (string-null? s) '() (json-string->scm s))))

(define (extract-reply-recipient path)
  ;; path = "/replies/{recipient}"
  (let ((prefix "/replies/"))
    (and (string-prefix? prefix path)
         (uri-decode (substring path (string-length prefix))))))

(define (handle-request request body)
  (let* ((method (request-method request))
         (path   (uri-path (request-uri request))))
    (cond
     ;; GET/POST /connect — for keri-connect!
     ((string=? path "/connect")
      (with-json 200 `(("url" . ,%base) ("agent" . (("i" . "EAgent"))))))

     ;; GET /config — witness iurls
     ((and (eq? method 'GET) (string=? path "/config"))
      (with-json 200 `(("iurls" . ,%wit-oobis))))

     ;; GET /identifiers/{name}/oobi — member OOBI
     ((and (eq? method 'GET)
           (string-suffix? "/oobi" path)
           (string-prefix? "/identifiers/" path))
      (set! %oobi-get-count (+ 1 %oobi-get-count))
      (with-json 200 `(("oobis" . ,(vector %member-oobi)))))

     ;; POST /oobis (Signify OOBI resolve on our agent)
     ((and (eq? method 'POST) (string=? path "/oobis"))
      (let ((b (parse-body body)))
        (set! %reply-calls (cons (cons "oobi-resolve" b) %reply-calls)))
      (with-json 200 `(("done" . #t) ("name" . "op-oobi"))))

     (else
      (values (build-response #:code 404) "not found")))))

(define-values (%port %thread)
  (spawn-mock-server handle-request))

(define %base (format #f "http://127.0.0.1:~a" %port))

(format #t "~%=== Witness mock on ~a ===~%" %base)

(keri-set-urls! %base %base)
(keri-connect! "testbran21chars00000")

;;; ── keri-get-available-witnesses ────────────────────────────────────

(format #t "~%=== keri-get-available-witnesses ===~%")

(call-with-values
    (lambda () (keri-get-available-witnesses))
  (lambda (witnesses toad)
    (check "returned 6 witnesses (dedupe + role filter)"
           (= 6 (length witnesses)))
    (check "each result is (eid . oobi) pair"
           (every (lambda (w) (and (pair? w)
                                   (string? (car w))
                                   (string? (cdr w))))
                  witnesses))
    (check "EIDs are unique"
           (= 6 (length (delete-duplicates (map car witnesses)))))
    (check "no agent-role OOBIs present"
           (not (any (lambda (w)
                       (string-contains (cdr w) "role=agent"))
                     witnesses)))
    (check "toad=4 for 6 witnesses" (= 4 toad))))

;;; ── keri-get-member-oobi ────────────────────────────────────────────

(format #t "~%=== keri-get-member-oobi ===~%")

(let ((oobi (keri-get-member-oobi "EMemberAID00000000000000000000000000000000")))
  (check "returns the OOBI string" (string? oobi))
  (check "matches the mock's oobi" (equal? %member-oobi oobi))
  (check "GET /oobi was called" (>= %oobi-get-count 1)))

;;; ── keri-share-witness-oobis! ───────────────────────────────────────

(format #t "~%=== keri-share-witness-oobis! ===~%")

(set! %reply-calls '())

(define %contacts '("EContact1AID00000000000000000000000000000000"
                    "EContact2AID00000000000000000000000000000000"))

(keri-share-witness-oobis! "EMyAID00000000000000000000000000000000000000"
                           %contacts)

;; New behavior: resolve 6 witnesses on OUR agent, no per-contact fan-out.
(check "resolved 6 witness OOBIs locally"
       (= 6 (length %reply-calls)))
(check "every call carries a url field"
       (every (lambda (call) (string? (assoc-ref (cdr call) "url")))
              %reply-calls))

;;; ── keri-share-member-oobi! ─────────────────────────────────────────

(format #t "~%=== keri-share-member-oobi! ===~%")

(set! %reply-calls '())

(define %recipients '("ERecip1AID00000000000000000000000000000000"
                      "ERecip2AID00000000000000000000000000000000"
                      "ERecip3AID00000000000000000000000000000000"))

(keri-share-member-oobi! "EMemberAID00000000000000000000000000000000"
                         %recipients)

;; New behavior: no POSTs, just logs. Mock captures zero reply calls.
(check "member-oobi share is a local-only log (no remote POSTs)"
       (null? %reply-calls))

;;; ── Summary ─────────────────────────────────────────────────────────

(test-summary!)
