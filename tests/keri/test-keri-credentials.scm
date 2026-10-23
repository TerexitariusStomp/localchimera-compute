;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/keri/test-keri-credentials.scm — ACDC credential tests
;;;
;;; Exercises credential issuance, IPEX push flow, verification,
;;; and revocation checking against a mock KERIA server.
;;;
;;; Run: guile -L module -L tests tests/keri/test-keri-credentials.scm

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
             (json))

(declare-opaque-header! "authorization")

;;; ── Mock state ───────────────────────────────────────────────────────

(define %test-cred-said "ECredTest0000000000000000000000000000000000")
(define %test-grant-said "EGrantTest000000000000000000000000000000000")
(define %test-registry "ERegTest00000000000000000000000000000000000")
(define %test-issuer-aid "EIssuer0000000000000000000000000000000000000")
(define %test-holder-aid "EHolder0000000000000000000000000000000000000")

(define %issue-calls 0)
(define %exchange-calls '())
(define %last-issue-body #f)
(define %credential-revoked? #f)
(define %credential-exists? #t)
;; acdc-create-registry's "already in use" path: KERIA's error carries no
;; regk, so it has to GET /identifiers/{name}/registries and find the
;; entry by name. #t makes POST /registries 400 like a real re-create.
(define %registry-already-exists? #f)
(define %test-registry-name "playnet-credentials")

(define (with-json code body-alist)
  (values
   (build-response
    #:code code
    #:headers '((content-type . (application/json))))
   (scm->json-string body-alist)))

(define (parse-body body)
  (let ((s (if (bytevector? body) (utf8->string body) (or body ""))))
    (if (string-null? s) '() (json-string->scm s))))

(define (handle-request request body)
  (let* ((method (request-method request))
         (path   (uri-path (request-uri request)))
         (query  (or (uri-query (request-uri request)) "")))
    (cond
     ;; POST /identifiers/{name}/credentials (issue) — note the /identifiers
     ;; guard so this does NOT also match POST /credentials/query (the list
     ;; route, handled below).
     ((and (eq? method 'POST) (string-contains path "/identifiers")
           (string-contains path "/credentials"))
      (set! %issue-calls (+ 1 %issue-calls))
      (set! %last-issue-body (parse-body body))
      (with-json 200
        `(("done" . #t)
          ("name" . "op-issue")
          ("said" . ,%test-cred-said))))

     ;; POST /credentials/query (list by filter) — KERIA's list route. The
     ;; bridge moved here from a bare GET /credentials (which real KERIA 401s).
     ((and (eq? method 'POST) (string=? path "/credentials/query"))
      (let ((b (parse-body body)))
        (if %credential-exists?
            (with-json 200
              (vector
               `(("sad" . (("d" . ,%test-cred-said)
                           ("i" . ,%test-issuer-aid)
                           ("s" . ,(or (assoc-path b "filter" "schema")
                                       %schema-member))
                           ("a" . (("i" . ,%test-holder-aid)
                                   ("dt" . "2026-04-12T00:00:00Z")))))
                 ("status" . (("et" . ,(if %credential-revoked? "rev" "iss")))))))
            (with-json 200 (vector)))))

     ;; POST /identifiers/{name}/ipex/* (Signify IPEX exchanges)
     ((and (eq? method 'POST) (string-contains path "/ipex/"))
      (let ((b (parse-body body)))
        (set! %exchange-calls (cons b %exchange-calls)))
      (with-json 200
        `(("done" . #t)
          ("name" . "op-exchange")
          ("response" . (("d" . ,%test-grant-said))))))

     ;; GET /credentials (list by filter)
     ((and (eq? method 'GET) (string=? path "/credentials"))
      (if %credential-exists?
          (with-json 200
            (vector
             `(("sad" . (("d" . ,%test-cred-said)
                         ("i" . ,%test-issuer-aid)
                         ("s" . ,(or (and (string-contains query "schema=")
                                         (let ((idx (string-contains query "schema=")))
                                           (substring query (+ idx 7))))
                                     %schema-member))
                         ("a" . (("i" . ,%test-holder-aid)
                                 ("dt" . "2026-04-12T00:00:00Z")))))
               ("status" . (("et" . ,(if %credential-revoked? "rev" "iss")))))))
          (with-json 200 (vector))))

     ;; GET /credentials/{said} (single credential) — KERIA 0.4.0 export
     ;; shape (ClonedCredential): SAD under "sad", per-event CESR
     ;; attachments, and the TEL status as a state dict.
     ((and (eq? method 'GET) (string-prefix? "/credentials/" path))
      (if %credential-exists?
          (with-json 200
            `(("sad" . (("d"  . ,%test-cred-said)
                        ("i"  . ,%test-issuer-aid)
                        ("ri" . ,%test-registry)
                        ("s"  . ,%schema-member)
                        ("a"  . (("i"  . ,%test-holder-aid)
                                 ("dt" . "2026-04-12T00:00:00Z")))))
              ("atc"    . "-IABEAAA")
              ("iss"    . (("t" . "iss")
                           ("d" . "EIssEvent0000000000000000000000000000000000")
                           ("i" . ,%test-cred-said)
                           ("s" . "0")))
              ("issatc" . "-GABAAAA")
              ("anc"    . (("t" . "ixn")
                           ("d" . "EAncEvent0000000000000000000000000000000000")))
              ("ancatc" . "-VANAAAA")
              ("status" . (("et" . ,(if %credential-revoked? "rev" "iss"))))))
          (with-json 404 `(("title" . "Not Found")))))

     ;; GET /registries/{rid}/credentials/{said}/state (TEL state)
     ((and (eq? method 'GET) (string-contains path "/state"))
      (with-json 200
        `(("et" . ,(if %credential-revoked? "rev" "iss")))))

     ;; GET /operations/{name}
     ((and (eq? method 'GET) (string-prefix? "/operations/" path))
      (with-json 200
        `(("done" . #t)
          ("said" . ,%test-cred-said)
          ("regk" . ,%test-registry))))

     ;; POST /identifiers/{name}/registries
     ((and (eq? method 'POST) (string-contains path "/registries"))
      (if %registry-already-exists?
          (with-json 400
            `(("title" . "400 Bad Request")
              ("description" . ,(string-append "registry name " %test-registry-name
                                                " already in use"))))
          (with-json 200
            `(("done" . #t)
              ("name" . "op-registry")
              ("response" . (("regk" . ,%test-registry)))))))

     ;; GET /identifiers/{name}/registries (list) — the real regk lookup
     ;; acdc-create-registry falls back to when POST above 400s.
     ((and (eq? method 'GET) (string-contains path "/registries"))
      (with-json 200
        (vector `(("regk" . ,%test-registry)
                  ("name" . ,%test-registry-name)
                  ("pre"  . ,%test-issuer-aid)))))

     ;; GET /identifiers/{name} — needed by credential-body + registry-body
     ((and (eq? method 'GET) (string-prefix? "/identifiers/" path))
      (with-json 200
        `(("name" . "gov-aid") ("prefix" . ,%test-issuer-aid)
          ("d" . ,%test-issuer-aid)
          ("state" . (("d" . ,%test-issuer-aid) ("s" . "0")
                      ("i" . ,%test-issuer-aid)
                      ("k" . ,(vector "Dfake")))))))

     ;; GET /connect + POST /connect (for keri-connect!)
     ((string=? path "/connect")
      (with-json 200
        `(("url" . ,(string-append "http://127.0.0.1:"
                                    (number->string %port)))
          ("agent" . (("i" . ,%test-issuer-aid))))))

     (else
      (values (build-response #:code 404) "not found")))))

;;; ── Start mock + connect ─────────────────────────────────────────────

(define-values (%port %thread)
  (spawn-mock-server handle-request))

(format #t "=== KERI Credentials Tests (mock on port ~a) ===~%" %port)

(keri-set-urls!
 (format #f "http://127.0.0.1:~a" %port)
 (format #f "http://127.0.0.1:~a" %port))
(keri-connect! "testbran21chars00000")

;;; ── Test: Registry creation ──────────────────────────────────────────
;;;
;;; acdc-create-registry must return the registry's regk (SAID) — the
;;; value acdc-issue posts against — never the human-readable name, on
;;; EITHER the fresh-create path or the already-exists path. The already-
;;; exists case is the one that broke live in production: KERIA's 400
;;; body carries no regk, so the fallback used to just reuse the NAME as
;;; the id, and every subsequent acdc-issue 404'd ("issue against invalid
;;; registry SAID <name>").

(format #t "~%=== Registry ===~%")

(let ((rid (acdc-create-registry "gov-aid" %test-registry-name)))
  (check "fresh registry: returns the regk, not the name"
         (equal? rid %test-registry))
  (check "fresh registry: acdc-registry-id matches"
         (equal? (acdc-registry-id) %test-registry)))

(set! %registry-already-exists? #t)
(let ((mod (resolve-module '(playnet keri credentials))))
  (module-define! mod '*playnet-registry-id* #f))
(let ((rid (acdc-create-registry "gov-aid" %test-registry-name)))
  (check "already-exists registry: still returns the regk, not the name"
         (equal? rid %test-registry))
  (check "already-exists registry: NOT the human-readable name"
         (not (equal? rid %test-registry-name)))
  (check "already-exists registry: acdc-registry-id matches"
         (equal? (acdc-registry-id) %test-registry)))
(set! %registry-already-exists? #f)

;; Set registry ID so acdc-issue doesn't error
(let ((mod (resolve-module '(playnet keri credentials))))
  (module-define! mod '*playnet-registry-id* %test-registry))

;;; ── Test: Credential Issuance ───────────────────────────────────────

(format #t "~%=== Issuance ===~%")

(let ((said (acdc-issue "gov-aid" %test-holder-aid %schema-member
                        '(("name" . "Alice")))))
  (check "acdc-issue returns a SAID" (string? said))
  (check "mock saw the issue request" (= 1 %issue-calls))
  ;; New Signify body shape: {acdc, iss, ixn, sigs}
  (let ((acdc (assoc-ref %last-issue-body "acdc")))
    (check "issue body has acdc with correct schema"
           (and acdc (equal? %schema-member (assoc-ref acdc "s"))))
    (check "issue body has acdc.a.i = holder AID"
           (and acdc (equal? %test-holder-aid
                             (assoc-ref (assoc-ref acdc "a") "i"))))))

;;; ── Test: IPEX Grant ────────────────────────────────────────────────

(format #t "~%=== IPEX Grant ===~%")

(set! %exchange-calls '())
(acdc-grant "gov-aid" %test-cred-said %test-holder-aid)

(check "acdc-grant called IPEX endpoint"
       (= 1 (length %exchange-calls)))
(check "grant body has exn event"
       (let ((exn (assoc-ref (car %exchange-calls) "exn")))
         (and exn (equal? "exn" (assoc-ref exn "t")))))

;; Spec-complete grant: the full acdc + iss + anc SADs ride in the exn's
;; `e` block (saidified), and atc carries one -L pathed-material group
;; per embed — what KERIA's postman + the holder's Admitter consume.
(check "grant e block embeds the full acdc SAD"
       (let* ((exn (assoc-ref (car %exchange-calls) "exn"))
              (e   (assoc-ref exn "e")))
         (equal? %test-cred-said
                 (and=> (assoc-ref e "acdc")
                        (lambda (sad) (assoc-ref sad "d"))))))
(check "grant e block embeds iss + anc and is saidified"
       (let* ((exn (assoc-ref (car %exchange-calls) "exn"))
              (e   (assoc-ref exn "e")))
         (and (pair? (assoc-ref e "iss"))
              (pair? (assoc-ref e "anc"))
              (let ((d (assoc-ref e "d")))
                (and (string? d) (string-prefix? "E" d))))))
(check "grant atc carries 3 -L pathed-material groups"
       (let ((atc (assoc-ref (car %exchange-calls) "atc")))
         (and (string? atc)
              (string-prefix? "-L" atc)
              (= 3 (let loop ((i 0) (n 0))
                     (let ((hit (string-contains atc "-L" i)))
                       (if hit (loop (+ hit 2) (+ n 1)) n)))))))
(check "grant atc pathed groups name the embed paths"
       (let ((atc (assoc-ref (car %exchange-calls) "atc")))
         (and (string-contains atc "-acdc")
              (string-contains atc "-iss")
              (string-contains atc "-anc"))))

;;; ── Test: IPEX Admit ────────────────────────────────────────────────

(format #t "~%=== IPEX Admit ===~%")

(set! %exchange-calls '())
(acdc-admit "holder-aid" %test-grant-said)

(check "acdc-admit called IPEX endpoint"
       (= 1 (length %exchange-calls)))
(check "admit body has exn event"
       (let ((exn (assoc-ref (car %exchange-calls) "exn")))
         (and exn (equal? "exn" (assoc-ref exn "t")))))
;; Spec shape: the grant being admitted rides exn.p (KERIA's Admitter
;; reads admit.ked.p — "no grant listed" without it).
(check "admit anchors the grant in exn.p"
       (let ((exn (assoc-ref (car %exchange-calls) "exn")))
         (equal? %test-grant-said (assoc-ref exn "p"))))

;;; ── Test: verify-role-credential ────────────────────────────────────

(format #t "~%=== Verify Role Credential ===~%")

(set! %credential-revoked? #f)
(set! %credential-exists? #t)

(let ((result (verify-role-credential %test-holder-aid %schema-member)))
  (check "valid credential: returns an alist" (pair? result))
  (check "valid credential: has sad with correct SAID"
         (equal? %test-cred-said (assoc-ref (assoc-ref result "sad") "d"))))

;; No credential
(set! %credential-exists? #f)
(check "no credential: returns #f"
       (not (verify-role-credential %test-holder-aid %schema-member)))

;; Revoked credential
(set! %credential-exists? #t)
(set! %credential-revoked? #t)
(check "revoked credential: returns #f"
       (not (verify-role-credential %test-holder-aid %schema-member)))

;;; ── Test: acdc-revoked? ─────────────────────────────────────────────

(format #t "~%=== Revocation Check ===~%")

(set! %credential-revoked? #f)
(check "acdc-revoked? on valid cred: #f"
       (not (acdc-revoked? %test-cred-said)))

(set! %credential-revoked? #t)
(check "acdc-revoked? on revoked cred: #t"
       (acdc-revoked? %test-cred-said))

;;; ── Test: acdc-valid? ──────────────────────────────────────────────

(format #t "~%=== Validity Check ===~%")

(set! %credential-revoked? #f)
(set! %credential-exists? #t)
(check "acdc-valid? on valid cred: #t"
       (acdc-valid? %test-cred-said))

(set! %credential-revoked? #t)
(check "acdc-valid? on revoked cred: #f"
       (not (acdc-valid? %test-cred-said)))

;;; ── Test: Role-specific issuance helpers ───────────────────────────

(format #t "~%=== Role Helpers ===~%")

(set! %issue-calls 0)
(issue-member-credential "gov-aid" %test-holder-aid "Bob")
(check "issue-member-credential uses member schema"
       (equal? %schema-member (assoc-ref (assoc-ref %last-issue-body "acdc") "s")))

(issue-supplier-credential "gov-aid" %test-holder-aid "FoodCo" '("produce" "dairy"))
(check "issue-supplier-credential uses supplier schema"
       (equal? %schema-supplier (assoc-ref (assoc-ref %last-issue-body "acdc") "s")))

(issue-governor-credential "gov-aid" %test-holder-aid)
(check "issue-governor-credential uses governor schema"
       (equal? %schema-governor (assoc-ref (assoc-ref %last-issue-body "acdc") "s")))

;;; ── Summary ─────────────────────────────────────────────────────────

(test-summary!)
