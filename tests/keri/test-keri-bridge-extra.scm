;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/keri/test-keri-bridge-extra.scm — extended bridge coverage
;;;
;;; Complements test-keri-bridge.scm (which covers boot/connect/create-aid/
;;; OOBI/signature) by exercising the rest of (localchimera keri bridge):
;;;
;;;   - keri-rotate-keys, keri-list-aids, keri-get-aid, keri-get-keystate,
;;;     keri-add-end-role, keri-get-aid-members
;;;   - keri-create-group, keri-get-group-aid
;;;   - keri-get-contact, keri-list-contacts, keri-delete-contact
;;;   - keri-list-credentials, keri-get-credential, keri-delete-credential
;;;   - keri-list-notifications, keri-mark-notification-read
;;;   - keri-get-operation, keri-wait-operation
;;;   - keri-get-exchange, keri-submit-exchange, keri-list-exchanges
;;;   - keri-get-group-requests, keri-submit-reply
;;;   - keri-get-config, keri-interact, keri-get-tel-state
;;;
;;; Run: guile -L module -L tests tests/keri/test-keri-bridge-extra.scm

(use-modules (localchimera test harness)
             (localchimera keri bridge)
             (web server)
             (web request)
             (web response)
             (web uri)
             (web http)
             (rnrs bytevectors)
             (ice-9 format)
             (ice-9 match)
             (ice-9 regex)
             (json))

(declare-opaque-header! "authorization")

;;; ── Mock state ───────────────────────────────────────────────────────

(define %aid       "EAlice000000000000000000000000000000000000000")
(define %group-aid "EGroup000000000000000000000000000000000000000")
(define %contact   "EBob00000000000000000000000000000000000000000")
(define %cred-said "ECred1000000000000000000000000000000000000000")
(define %registry  "ERegBE0000000000000000000000000000000000000")
(define %nid       "Nid00000000000000000000")

;; per-test counters / capture
(define %last-method #f)
(define %last-path #f)
(define %last-body #f)
(define %request-count 0)

;; Operation-progress cursor: 0 = pending, 1+ = done
(define %op-progress 0)

(define (with-json code body)
  (values
   (build-response
    #:code code
    #:headers '((content-type . (application/json))))
   (scm->json-string body)))

(define (parse-body body)
  (let ((s (if (bytevector? body) (utf8->string body) (or body ""))))
    (if (string-null? s) '() (json-string->scm s))))

(define (capture! request body)
  (set! %request-count (+ 1 %request-count))
  (set! %last-method (request-method request))
  (set! %last-path (uri-path (request-uri request)))
  (set! %last-body (parse-body body)))

(define (handle-request request body)
  (capture! request body)
  (let* ((method (request-method request))
         (path   (uri-path (request-uri request)))
         (query  (or (uri-query (request-uri request)) "")))
    (cond
     ;; Connect plumbing
     ((string=? path "/connect")
      (with-json 200 `(("url" . ,%base) ("agent" . (("i" . ,%aid))))))

     ;; GET /config
     ((and (eq? method 'GET) (string=? path "/config"))
      (with-json 200 `(("iurls" . ,(vector "http://w/oobi/x/controller?role=witness")))))

     ;; GET /identifiers — list AIDs
     ((and (eq? method 'GET) (string=? path "/identifiers"))
      (with-json 200 (vector `(("name" . "alice") ("prefix" . ,%aid)))))

     ;; GET /identifiers/{name}/members
     ((and (eq? method 'GET) (string-suffix? "/members" path))
      (with-json 200 `(("signing" . ,(vector `(("aid" . ,%aid))
                                             `(("aid" . ,%contact)))))))

     ;; POST /identifiers/{name}/events — rotation (Signify). KERIA dispatches
     ;; rot/ixn/submit on this route; PUT /identifiers/{name} is the *rename*
     ;; endpoint, not rotation.
     ((and (eq? method 'POST) (string-suffix? "/events" path))
      (with-json 200 `(("done" . #t) ("name" . "op-rot"))))

     ;; POST /identifiers/{name}/endroles — end-role (Signify)
     ((and (eq? method 'POST) (string-suffix? "/endroles" path))
      (with-json 200 `(("done" . #t) ("name" . "op-end-role"))))

     ;; POST /identifiers/{name}/ipex/* — IPEX exchanges (Signify)
     ((and (eq? method 'POST) (string-contains path "/ipex/"))
      (with-json 200 `(("done" . #t) ("name" . "op-ipex"))))

     ;; POST /identifiers/{name}/ixn — interaction event
     ((and (eq? method 'POST) (string-suffix? "/ixn" path))
      (with-json 200 `(("done" . #t) ("name" . "op-ixn") ("sn" . 7))))

     ;; POST /identifiers (group create)
     ((and (eq? method 'POST) (string=? path "/identifiers"))
      (with-json 200 `(("done" . #t) ("name" . "op-grp")
                       ("response" . (("i" . ,%group-aid))))))

     ;; GET /identifiers/{name} — single AID state
     ((and (eq? method 'GET) (string-prefix? "/identifiers/" path))
      (with-json 200 `(("name" . "alice")
                       ("prefix" . ,%aid)
                       ("d" . ,%aid)
                       ("state" . (("i" . ,%aid) ("d" . ,%aid) ("s" . "0")
                                   ("k" . ,(vector "Dpub00000")))))))

     ;; GET /keystate/{aid}
     ((and (eq? method 'GET) (string-prefix? "/keystate/" path))
      (with-json 200 `(("k" . ,(vector "Dpub00000")) ("i" . ,%aid))))

     ;; Contacts
     ((and (eq? method 'GET) (string=? path "/contacts"))
      (with-json 200 (vector `(("id" . ,%contact)))))
     ((and (eq? method 'GET) (string-prefix? "/contacts/" path))
      (with-json 200 `(("id" . ,%contact) ("alias" . "bob"))))
     ((and (eq? method 'DELETE) (string-prefix? "/contacts/" path))
      (with-json 200 '()))

     ;; Credentials. List is POST /credentials/query (KERIA's route; a bare
     ;; GET /credentials 401s on real KERIA).
     ((and (eq? method 'POST) (string=? path "/credentials/query"))
      (with-json 200 (vector `(("sad" . (("d" . ,%cred-said)))))))
     ((and (eq? method 'GET) (string-prefix? "/credentials/" path))
      (with-json 200 `(("d" . ,%cred-said) ("ri" . ,%registry))))
     ((and (eq? method 'DELETE) (string-prefix? "/credentials/" path))
      (with-json 200 '()))

     ;; Notifications
     ((and (eq? method 'GET) (string=? path "/notifications"))
      (with-json 200 (vector `(("i" . ,%nid)
                               ("a" . (("r" . "/exn/ipex/grant")))))))
     ((and (eq? method 'POST) (string-suffix? "/mark" path))
      (with-json 200 '()))

     ;; Operations: pending → done after 1 poll
     ((and (eq? method 'GET) (string-prefix? "/operations/" path))
      (set! %op-progress (+ 1 %op-progress))
      (if (>= %op-progress 2)
          (with-json 200 `(("done" . #t) ("name" . "op-x") ("response" . (("ok" . #t)))))
          (with-json 200 `(("done" . #f) ("name" . "op-x")))))

     ;; Exchanges
     ((and (eq? method 'GET) (string=? path "/exchanges"))
      (with-json 200 (vector `(("d" . "EExn1")))))
     ((and (eq? method 'GET) (string-prefix? "/exchanges/" path))
      (with-json 200 `(("d" . "EExn1") ("exn" . (("i" . ,%aid))))))
     ((and (eq? method 'POST) (string=? path "/exchanges"))
      (with-json 200 `(("done" . #t) ("d" . "EExnNew"))))

     ;; Group requests
     ((and (eq? method 'GET) (string-prefix? "/groups/" path)
           (string-suffix? "/request" path))
      (with-json 200 (vector `(("exn" . (("a" . (("gid" . ,%group-aid)))))))))

     ;; Replies
     ((and (eq? method 'POST) (string-prefix? "/replies/" path))
      (with-json 200 '(("done" . #t))))

     ;; TEL state
     ((and (eq? method 'GET)
           (string-contains path "/registries/")
           (string-suffix? "/state" path))
      (with-json 200 `(("et" . "iss") ("said" . ,%cred-said))))

     (else (values (build-response #:code 404) "not found")))))

(define-values (%port %thread)
  (spawn-mock-server handle-request))
(define %base (format #f "http://127.0.0.1:~a" %port))

(format #t "=== KERI Bridge Extra Tests (mock on ~a) ===~%" %base)
(keri-set-urls! %base %base)
(keri-connect! "testbran21chars00000")

;;; ── Helpers ──────────────────────────────────────────────────────────

(define (reset-capture!)
  (set! %last-method #f)
  (set! %last-path #f)
  (set! %last-body #f))

;;; ── AID management ──────────────────────────────────────────────────

(format #t "~%=== AID management ===~%")

(reset-capture!)
(let ((result (keri-list-aids)))
  (check "list-aids returns a vector"
         (vector? result))
  (check "list-aids hit GET /identifiers"
         (and (eq? 'GET %last-method) (string=? "/identifiers" %last-path))))

(reset-capture!)
(let ((aid (keri-get-aid "alice")))
  (check "get-aid returns an alist" (pair? aid))
  (check "get-aid returns the prefix"
         (equal? %aid (assoc-ref aid "prefix")))
  (check "get-aid hits /identifiers/alice"
         (string=? "/identifiers/alice" %last-path)))

(reset-capture!)
(keri-rotate-keys "alice" #:adds '("EAdd1") #:cuts '())
(check "rotate-keys uses POST method (to /events)"
       (eq? 'POST %last-method))
(check "rotate-keys posts to /events"
       (string-suffix? "/events" %last-path))
(check "rotate-keys body has rot event"
       (let ((rot (assoc-ref %last-body "rot")))
         (and rot (equal? "rot" (assoc-ref rot "t")))))
(check "rotate-keys body has sigs"
       (vector? (assoc-ref %last-body "sigs")))

(reset-capture!)
(keri-add-end-role "alice" "agent" "EAgentEID")
(check "add-end-role POSTs to /endroles"
       (and (eq? 'POST %last-method)
            (string-suffix? "/endroles" %last-path)))
(check "add-end-role body has rpy event"
       (let ((rpy (assoc-ref %last-body "rpy")))
         (and rpy (equal? "rpy" (assoc-ref rpy "t")))))
(check "add-end-role body has sigs"
       (vector? (assoc-ref %last-body "sigs")))

(reset-capture!)
(let ((ks (keri-get-keystate %aid)))
  (check "get-keystate returns alist with k vector"
         (vector? (assoc-ref ks "k"))))

(reset-capture!)
(let ((members (keri-get-aid-members "the-group")))
  (check "get-aid-members hits /members"
         (string-suffix? "/members" %last-path))
  (check "members has signing vector"
         (vector? (assoc-ref members "signing"))))

;;; ── Multi-sig group ─────────────────────────────────────────────────

(format #t "~%=== Multi-sig group ===~%")

(reset-capture!)
;; The signify-ts body needs: caller name + member prefixes + per-member
;; signing keys + per-member next-key digests.
(keri-create-group "localchimera-gov"
                   "alice"                                  ; caller AID name
                   (list %aid "EMem2" "EMem3")              ; member prefixes (caller first)
                   '("DKey1" "DKey2" "DKey3")               ; member signing keys
                   '("ENdig1" "ENdig2" "ENdig3")            ; next-key digests
                   #:signing-threshold 2
                   #:rotation-threshold 2
                   #:toad 4
                   #:witnesses '("EWit1" "EWit2"))

(check "create-group POSTs to /identifiers"
       (and (eq? 'POST %last-method) (string=? "/identifiers" %last-path)))
(check "create-group body has signed icp"
       (let ((icp (assoc-ref %last-body "icp")))
         (and icp (equal? "icp" (assoc-ref icp "t")))))
(check "create-group body has sigs"
       (vector? (assoc-ref %last-body "sigs")))
(check "create-group body has group.mhab.prefix"
       (let ((g (assoc-ref %last-body "group")))
         (and g (assoc-ref (assoc-ref g "mhab") "prefix"))))
(check "create-group body has smids vector (3 members)"
       (= 3 (vector-length (assoc-ref %last-body "smids"))))
(check "create-group body has rmids vector (3 members)"
       (= 3 (vector-length (assoc-ref %last-body "rmids"))))

(reset-capture!)
(let ((g (keri-get-group-aid "localchimera-gov")))
  (check "get-group-aid is an alias for get-aid"
         (string=? "/identifiers/localchimera-gov" %last-path))
  (check "returns alist with prefix" (assoc-ref g "prefix")))

;;; ── Contacts ────────────────────────────────────────────────────────

(format #t "~%=== Contacts ===~%")

(reset-capture!)
(let ((cs (keri-list-contacts)))
  (check "list-contacts returns vector" (vector? cs))
  (check "list-contacts hits /contacts" (string=? "/contacts" %last-path)))

(reset-capture!)
(let ((c (keri-get-contact %contact)))
  (check "get-contact returns an alist with alias"
         (equal? "bob" (assoc-ref c "alias"))))

(reset-capture!)
(keri-delete-contact %contact)
(check "delete-contact uses DELETE method"
       (eq? 'DELETE %last-method))
(check "delete-contact hits /contacts/{aid}"
       (string-prefix? "/contacts/" %last-path))

;;; ── Credentials ─────────────────────────────────────────────────────

(format #t "~%=== Credentials (raw bridge) ===~%")

(reset-capture!)
(let ((cs (keri-list-credentials)))
  (check "list-credentials returns vector" (vector? cs))
  (check "list-credentials POSTs to /credentials/query"
         (and (eq? 'POST %last-method)
              (string=? "/credentials/query" %last-path))))

(reset-capture!)
(keri-list-credentials #:filter '(("schema" . "ESchema")))
(check "list-credentials with filter POSTs to /credentials/query"
       (and (eq? 'POST %last-method)
            (string=? "/credentials/query" %last-path)))
(check "list-credentials sends filter in body"
       (equal? "ESchema" (assoc-path %last-body "filter" "schema")))

(reset-capture!)
(let ((c (keri-get-credential %cred-said)))
  (check "get-credential returns alist"
         (equal? %cred-said (assoc-ref c "d"))))

(reset-capture!)
(keri-delete-credential %cred-said)
(check "delete-credential uses DELETE"
       (eq? 'DELETE %last-method))

;;; ── Notifications ───────────────────────────────────────────────────

(format #t "~%=== Notifications (raw bridge) ===~%")

(reset-capture!)
(let ((notes (keri-list-notifications #:start 0 #:end 24)))
  (check "list-notifications returns vector" (vector? notes))
  (check "list-notifications hits /notifications"
         (string=? "/notifications" %last-path)))

(reset-capture!)
(keri-mark-notification-read %nid)
(check "mark-notification-read POSTs to /mark"
       (and (eq? 'POST %last-method)
            (string-suffix? "/mark" %last-path)))

;;; ── Operations ──────────────────────────────────────────────────────

(format #t "~%=== Operations + wait ===~%")

(reset-capture!)
(set! %op-progress 0)
(let ((op (keri-get-operation "op-test")))
  (check "get-operation returns alist with done field"
         (assoc "done" op)))

(set! %op-progress 0)
(let ((done (keri-wait-operation `(("name" . "op-test")) #:timeout 5 #:interval 0.05)))
  (check "wait-operation polls until done = #t"
         (eq? #t (assoc-ref done "done"))))

;;; Timeout path
(set! %op-progress -1000) ; never reaches 2
(check-error "wait-operation raises on timeout"
             (lambda ()
               (keri-wait-operation `(("name" . "op-stuck"))
                                    #:timeout 0
                                    #:interval 0.01)))

;;; ── Exchanges + replies ─────────────────────────────────────────────

(format #t "~%=== Exchanges + replies ===~%")

(reset-capture!)
(keri-submit-exchange "alice" "grant"
                      #:recipient %contact #:payload '() #:rec (list %contact))
(check "submit-exchange POSTs to IPEX route"
       (and (eq? 'POST %last-method)
            (string-contains %last-path "/ipex/grant")))
(check "submit-exchange body has exn event"
       (let ((exn (assoc-ref %last-body "exn")))
         (and exn (equal? "exn" (assoc-ref exn "t")))))

(reset-capture!)
(keri-get-exchange "EExn1")
(check "get-exchange GETs /exchanges/{said}"
       (string-prefix? "/exchanges/" %last-path))

(reset-capture!)
(keri-list-exchanges #:route "/multisig/icp" #:group-aid %group-aid)
(check "list-exchanges hits /exchanges with query"
       (string=? "/exchanges" %last-path))

(reset-capture!)
(keri-get-group-requests "ESaidGroup")
(check "get-group-requests hits /groups/{said}/request"
       (and (string-prefix? "/groups/" %last-path)
            (string-suffix? "/request" %last-path)))

;; keri-submit-reply was removed — /replies is not a real KERIA endpoint.
;; OOBI sharing now uses real keri-resolve-oobi on each agent locally.

;;; ── Config ──────────────────────────────────────────────────────────

(format #t "~%=== Config ===~%")

(reset-capture!)
(let ((c (keri-get-config)))
  (check "get-config returns alist with iurls"
         (vector? (assoc-ref c "iurls"))))

;;; ── Interact (ixn) ──────────────────────────────────────────────────

(format #t "~%=== Interact (ixn) ===~%")

(reset-capture!)
(keri-interact "alice" '(("d" . "EAnchorSAID")))
(check "interact POSTs to /ixn"
       (string-suffix? "/ixn" %last-path))
(check "interact body has signed ixn event"
       (let ((ixn (assoc-ref %last-body "ixn")))
         (and ixn (equal? "ixn" (assoc-ref ixn "t")))))
(check "interact body has sigs"
       (vector? (assoc-ref %last-body "sigs")))

;;; ── TEL state ───────────────────────────────────────────────────────

(format #t "~%=== TEL state ===~%")

(reset-capture!)
(let ((s (keri-get-tel-state %registry %cred-said)))
  (check "get-tel-state returns alist with et field"
         (equal? "iss" (assoc-ref s "et"))))

;;; ── Summary ─────────────────────────────────────────────────────────

(test-summary!)
