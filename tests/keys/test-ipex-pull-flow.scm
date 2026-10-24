;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/keys/test-ipex-pull-flow.scm — apply/offer/agree handlers
;;;
;;; The pull-flow trio: handler-side. Asserts the cooperative behaviour
;;; with a mock KERIA + a mock credential-finder.
;;;
;;;   apply  — we get a credential request; offer if we have one, spurn if not
;;;   offer  — we get an offer from a trusted issuer; agree (or spurn unknown)
;;;   agree  — peer accepted our offer; we ship the grant they agreed to
;;;
;;; Reuses the test pattern from test-ipex-grant-handler.scm. Mock
;;; KERIA records POST paths so we can verify the right verbs went out.

(use-modules (localchimera test harness)
             (localchimera keri bridge)
             (localchimera keri credentials)
             (localchimera federation ipex-policy)
             (localchimera credentials membership) (localchimera keri acdc) (localchimera keri acdc)
             (web server)
             (web request)
             (web response)
             (web uri)
             (rnrs bytevectors)
             (ice-9 format)
             (json))

(define notif-mod (resolve-module '(localchimera federation keria-notifications)))
(define handle-ipex-apply (module-ref notif-mod 'handle-ipex-apply))
(define handle-ipex-offer (module-ref notif-mod 'handle-ipex-offer))
(define handle-ipex-agree (module-ref notif-mod 'handle-ipex-agree))

(install-default-grant-policies!)

;; ── Mock state ────────────────────────────────────────────────────────

(define %posts '())   ; list of (path . body)
(define %grant-said    "EGrant000000000000000000000000000000000000A")
(define %offer-said    "EOffer000000000000000000000000000000000000A")
(define %apply-said    "EApply000000000000000000000000000000000000A")
(define %agree-said    "EAgree000000000000000000000000000000000000A")
(define %cred-said     "ECred0000000000000000000000000000000000000A")
(define %issuer-aid    "EIssuer000000000000000000000000000000000000")
(define %holder-aid    "EHolder000000000000000000000000000000000000")
(define %recipient-aid "ERecipient00000000000000000000000000000000A")
(define %known-schema  *schema-localchimera-membership*)
(define %unknown-schema "localchimera-not-a-real-schema/v999")

;; Toggle: which schema the apply requests
(define %apply-schema %known-schema)

;; The fake credential the finder returns (when found)
(define %fake-cred
  (make-credential %known-schema %issuer-aid %holder-aid '() '()))

(define %finder-result #f)  ; what gateway-credential-finder returns
(define (test-finder _schema _requester) %finder-result)
(current-credential-finder test-finder)

;; whether the mock KERIA can export the credential (the agree path's
;; spec-complete grant); #f = the locally-issued-credential case
(define %cred-exportable? #t)

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
     ((string=? path "/connect")    (with-json 200 '(("ok" . #t))))
     ((string=? path "/")           (with-json 200 '(("ok" . #t))))
     ((string=? path "/identifiers") (with-json 200 (vector)))

     ;; keri-get-exchange — return synthetic exns based on the SAID
     ((string-prefix? "/exchanges/" path)
      (let ((requested-said (substring path (string-length "/exchanges/"))))
        (cond
         ;; Apply: sender = holder, payload schema field
         ((string-contains requested-said "Apply")
          (with-json 200
            `(("exn" . (("t" . "exn")
                        ("i" . ,%holder-aid)
                        ("rp" . ,%recipient-aid)
                        ("r" . "/ipex/apply")
                        ("a" . (("schema" . ,%apply-schema))))))))
         ;; Offer: from issuer, references cred SAID
         ((string-contains requested-said "Offer")
          (with-json 200
            `(("exn" . (("t" . "exn")
                        ("i" . ,%issuer-aid)
                        ("rp" . ,%recipient-aid)
                        ("r" . "/ipex/offer")
                        ("a" . (("apply" . ,%apply-said)
                                ("acdc"  . ,%cred-said))))))))
         ;; Agree: from holder, references offer SAID
         ((string-contains requested-said "Agree")
          (with-json 200
            `(("exn" . (("t" . "exn")
                        ("i" . ,%holder-aid)
                        ("rp" . ,%recipient-aid)
                        ("r" . "/ipex/agree")
                        ("a" . (("offer" . ,%offer-said))))))))
         (else (with-json 404 `(("title" . "Not Found")))))))

     ;; Identifier name → AID
     ((string-prefix? "/identifiers/" path)
      (with-json 200
        `(("name" . "localchimera-governance")
          ("prefix" . ,%recipient-aid)
          ("state" . (("d" . ,%recipient-aid) ("s" . "0")
                      ("i" . ,%recipient-aid)
                      ("k" . #("Dfake000000000000000000000000000000000000000")))))))

     ;; keri-get-credential — the agree path's acdc-grant exports the FULL
     ;; artifact set (sad + iss + anc SADs) to embed in the grant exn.
     ;; %cred-exportable? #f plays the locally-issued case: KERIA's
     ;; registry never held the credential, so the export 404s.
     ((and (string-prefix? "/credentials/" path) (not %cred-exportable?))
      (with-json 404 `(("title" . "Not Found"))))
     ((string-prefix? "/credentials/" path)
      (with-json 200
        `(("sad" . (("d" . ,%cred-said) ("i" . ,%issuer-aid)
                    ("s" . ,%apply-schema)
                    ("a" . (("i" . ,%holder-aid)))))
          ("iss" . (("d" . "EIssEvt00000000000000000000000000000000000A")
                    ("t" . "iss") ("i" . ,%cred-said) ("s" . "0")))
          ("anc" . (("d" . "EAncEvt00000000000000000000000000000000000A")
                    ("t" . "ixn")))
          ("status" . "issued"))))

     ;; All IPEX submits ack
     ((string-contains path "/ipex/")
      (with-json 200 `(("done" . #t) ("name" . "op-ipex"))))

     ;; Operation polling
     ((string-prefix? "/operations/" path)
      (with-json 200 `(("done" . #t))))

     ;; keystate (used by issuer-has-resolvable-kel? in offer handler)
     ((string-prefix? "/keystate/" path)
      (with-json 200 `(("i" . ,%issuer-aid)
                       ("k" . #("Dfake000000000000000000000000000000000000000")))))

     (else (values (build-response #:code 404) "not found")))))

(define-values (%port _thread) (spawn-mock-server handle-request))
(define %base (format #f "http://127.0.0.1:~a" %port))
(format #t "=== IPEX pull-flow handlers (mock on ~a) ===~%" %base)
(keri-set-urls! %base %base)
(keri-connect! "testbran21chars00000")

(define (posts-to-path-prefix prefix)
  (filter (lambda (p) (string-contains (car p) prefix)) %posts))

(define (reset-posts!) (set! %posts '()))

(define (synthetic-note route said)
  `(("i" . "noteid-1")
    ("a" . (("r" . ,route) ("d" . ,said)))))

;; ── apply: known schema + finder hits → offer ────────────────────

(reset-posts!)
(set! %apply-schema %known-schema)
(set! %finder-result %fake-cred)
(catch #t
  (lambda () (handle-ipex-apply "/exn/ipex/apply" %apply-said
                                (synthetic-note "/exn/ipex/apply" %apply-said)))
  (lambda _ #f))

(check "apply (have it): offer was POSTed"
       (>= (length (posts-to-path-prefix "/ipex/offer")) 1))

(check "apply (have it): no spurn"
       (length (posts-to-path-prefix "/ipex/spurn")) 0)

;; ── apply: finder returns #f → spurn ───────────────────────────

(reset-posts!)
(set! %finder-result #f)
(catch #t
  (lambda () (handle-ipex-apply "/exn/ipex/apply" %apply-said
                                (synthetic-note "/exn/ipex/apply" %apply-said)))
  (lambda _ #f))

(check "apply (don't have it): spurn POSTed"
       (>= (length (posts-to-path-prefix "/ipex/spurn")) 1))

(check "apply (don't have it): no offer"
       (length (posts-to-path-prefix "/ipex/offer")) 0)

;; ── apply: unbound finder → spurn ──────────────────────────────

(reset-posts!)
;; the finder is a global (see federation/ipex-policy.scm) — unbind, run, restore
(let ((saved (current-credential-finder)))
  (current-credential-finder #f)
  (catch #t
    (lambda () (handle-ipex-apply "/exn/ipex/apply" %apply-said
                                  (synthetic-note "/exn/ipex/apply" %apply-said)))
    (lambda _ #f))
  (current-credential-finder saved))

(check "apply (no finder): spurn POSTed"
       (>= (length (posts-to-path-prefix "/ipex/spurn")) 1))

;; ── offer: from issuer with resolvable KEL → agree ─────────────

(reset-posts!)
(catch #t
  (lambda () (handle-ipex-offer "/exn/ipex/offer" %offer-said
                                (synthetic-note "/exn/ipex/offer" %offer-said)))
  (lambda _ #f))

(check "offer (trusted issuer): agree POSTed"
       (>= (length (posts-to-path-prefix "/ipex/agree")) 1))

(check "offer (trusted issuer): no spurn"
       (length (posts-to-path-prefix "/ipex/spurn")) 0)

;; ── agree: peer accepted our offer → grant ────────────────────

(reset-posts!)
(catch #t
  (lambda () (handle-ipex-agree "/exn/ipex/agree" %agree-said
                                (synthetic-note "/exn/ipex/agree" %agree-said)))
  (lambda _ #f))

(check "agree: grant POSTed"
       (>= (length (posts-to-path-prefix "/ipex/grant")) 1))

;; ── agree: cred NOT in KERIA (locally issued) → local-store grant ──
;; The by-said finder answers; the grant embeds the governance cred's
;; wire projection (governance-cred->wire) instead of KERIA's export.

(reset-posts!)
(set! %cred-exportable? #f)
(current-credential-finder-by-said
 (lambda (said) (and (equal? said %cred-said) %fake-cred)))
(catch #t
  (lambda () (handle-ipex-agree "/exn/ipex/agree" %agree-said
                                (synthetic-note "/exn/ipex/agree" %agree-said)))
  (lambda _ #f))
(set! %cred-exportable? #t)
(current-credential-finder-by-said #f)

(let ((grants (posts-to-path-prefix "/ipex/grant")))
  (check "agree (local cred): grant POSTed without KERIA export"
         (>= (length grants) 1))
  (check "agree (local cred): the grant embeds the credential's own SAID"
         (and (pair? grants)
              (let* ((body (cdar grants))
                     (exn  (assoc-ref body "exn"))
                     (e    (and exn (assoc-ref exn "e")))
                     (acdc (and e (assoc-ref e "acdc"))))
                (equal? (and acdc (assoc-ref acdc "d"))
                        (cred-said %fake-cred))))))

;; ── agree: cred not in KERIA AND no by-said finder → no grant ──

(reset-posts!)
(set! %cred-exportable? #f)
(catch #t
  (lambda () (handle-ipex-agree "/exn/ipex/agree" %agree-said
                                (synthetic-note "/exn/ipex/agree" %agree-said)))
  (lambda _ #f))
(set! %cred-exportable? #t)

(check "agree (local cred, no finder): no grant went out"
       (length (posts-to-path-prefix "/ipex/grant")) 0)

(test-summary!)
