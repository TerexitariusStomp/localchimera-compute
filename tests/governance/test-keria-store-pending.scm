;;; tests/governance/test-keria-store-pending.scm — umbrella-grant
;;; resilience via the unified ^pending-grants queue.
;;;
;;; When KERIA's /ipex/grant rejects (KERIA down, recipient OOBI not
;;; resolved, etc.), ^keria-acdc-store's `issue` no longer carries an
;;; embedded queue — it enqueues to the unified ^pending-grants actor
;;; under kind = 'umbrella-grant. Gateway's drain pass calls
;;; (^pending-grants 'drain!) which dispatches via the replay-fn
;;; registered in keys/keria-store.scm.
;;;
;;; What we assert:
;;;   - happy path: issue succeeds, central queue stays empty
;;;   - KERIA-down: issue still returns the said (local issue succeeded),
;;;     central queue grows with kind='umbrella-grant entries
;;;   - drain while still down: 0 drained, entries stay
;;;   - drain after recovery: all entries drain, queue empties
;;;
;;; Mock HTTP server: /credentials POST always succeeds (issue is local
;;; to KERIA), /ipex/grant toggles between 200 and 500 via %grant-up?.

(use-modules (playnet test harness)
             (playnet keri bridge)
             (playnet keri credentials)
             (playnet keys keria-store)
             (playnet keys pending-grants)
             (playnet credentials membership) (playnet keri acdc) (playnet keri acdc)
             (goblins)
             (web server)
             (web request)
             (web response)
             (web uri)
             (rnrs bytevectors)
             (ice-9 format)
             (json))

;; ── Mock state ──────────────────────────────────────────────────────

(define %grant-up?     #t)          ; flip to simulate KERIA-down
(define %grant-attempts 0)          ; total POSTs to /ipex/grant
(define %grant-successes 0)
(define %issued-said "ECred0000000000000000000000000000000000000A")
(define %issuer-aid  "EIssuer0000000000000000000000000000000000000")
(define %holder-aid  "EHolder0000000000000000000000000000000000000")

(define (with-json code body)
  (values (build-response #:code code
                          #:headers '((content-type . (application/json))))
          (scm->json-string body)))

(define (handle-request request _body)
  (let* ((method (request-method request))
         (path   (uri-path (request-uri request))))
    (cond
     ((string=? path "/connect")     (with-json 200 '(("ok" . #t))))
     ((string=? path "/")            (with-json 200 '(("ok" . #t))))
     ((string=? path "/identifiers") (with-json 200 (vector)))

     ;; POST registry creation
     ((and (eq? method 'POST) (string-contains path "/registries"))
      (with-json 200 `(("done" . #t)
                       ("name" . "op-reg")
                       ("response" . (("regk" . "ERegTest00000000000000000000000000000000000"))))))

     ;; POST issue: always succeeds, returns the canned said
     ((and (eq? method 'POST) (string-contains path "/credentials"))
      (with-json 200 `(("done" . #t)
                       ("name" . "op-issue")
                       ("said" . ,%issued-said))))

     ;; GET credential export — the spec-complete grant (acdc-grant) embeds
     ;; the FULL acdc + iss + anc SADs read back from KERIA's own export
     ;; (ClonedCredential: SAD under "sad", TEL status a state dict), so the
     ;; mock serves that shape. Without this route every issue deferred at the
     ;; export fetch and the grant POST below was never reached at all.
     ((and (eq? method 'GET) (string-contains path "/credentials/"))
      (with-json 200
        `(("sad" . (("v" . "ACDC10JSON000000_") ("d" . ,%issued-said)
                    ("i" . ,%issuer-aid)
                    ("s" . "ESchema0000000000000000000000000000000000000")
                    ("a" . (("i" . ,%holder-aid)))))
          ("iss" . (("v" . "KERI10JSON000000_") ("t" . "iss")
                    ("d" . "EIss0000000000000000000000000000000000000000")
                    ("i" . ,%issued-said) ("s" . "0")))
          ("anc" . (("v" . "KERI10JSON000000_") ("t" . "ixn")
                    ("d" . "EAnc0000000000000000000000000000000000000000")
                    ("i" . ,%issuer-aid) ("s" . "1")))
          ("status" . (("et" . "iss"))))))

     ;; POST IPEX grant: gated by %grant-up?
     ((and (eq? method 'POST) (string-contains path "/ipex/grant"))
      (set! %grant-attempts (+ 1 %grant-attempts))
      (cond
       (%grant-up?
        (set! %grant-successes (+ 1 %grant-successes))
        (with-json 200 `(("done" . #t) ("name" . "op-grant"))))
       (else
        (with-json 500 `(("title" . "KERIA temporarily unavailable"))))))

     ;; All other IPEX (admit, spurn, etc.): ok
     ((string-contains path "/ipex/")
      (with-json 200 `(("done" . #t) ("name" . "op-ipex"))))

     ;; Operation polling — return regk too so acdc-create-registry
     ;; can pick it up after polling.
     ((string-prefix? "/operations/" path)
      (with-json 200 `(("done" . #t)
                       ("said" . ,%issued-said)
                       ("regk" . "ERegTest00000000000000000000000000000000000"))))

     ;; Identifier metadata
     ((string-prefix? "/identifiers/" path)
      (with-json 200 `(("name" . "test-issuer")
                       ("prefix" . ,%issuer-aid)
                       ("state" . (("d" . ,%issuer-aid) ("s" . "0")
                                   ("i" . ,%issuer-aid)
                                   ("k" . #("Dfake000000000000000000000000000000000000000")))))))

     (else (values (build-response #:code 404) "not found")))))

(define-values (%port _thread) (spawn-mock-server handle-request))
(define %base (format #f "http://127.0.0.1:~a" %port))
(format #t "=== keria-store pending-grants (mock on ~a) ===~%" %base)
(keri-set-urls! %base %base)
(keri-connect! "testbran21chars00000")
(acdc-create-registry "test-issuer" "test-reg")

;; ── Spawn the central queue + the store, wire the parameter ────────
;;
;; Order matters: set the parameter BEFORE spawn-vat for the store so
;; the vat's internal fiber inherits the queue ref. Without that,
;; `<-` enqueues scheduled inside actor methods would land with
;; (current-pending-grants) = #f because the vat fiber forked off
;; before the parameter was set in main thread.

(define %q-vat (spawn-vat #:name "pending-grants"))
(define %q     (with-vat %q-vat (spawn-pending-grants)))
(current-pending-grants %q)
(define %vat   (spawn-vat #:name "store"))
(define %store (with-vat %vat (spawn-keria-acdc-store "test-issuer")))

;; Polling helper for async `<-` enqueues that the vat scheduler
;; needs a tick to deliver. with-vat does the ticking for us.
(define (q-count-eq? n)
  (let loop ((tries 0))
    (cond
     ((>= tries 50) #f)
     ((= n (with-vat %q-vat ($ %q 'count))) #t)
     (else (loop (1+ tries))))))

;; Helper: make a synthetic credential (the keria-store re-issues anyway).
(define (mk-cred i)
  (make-credential *schema-playnet-membership* %issuer-aid %holder-aid
                   `((seq . ,i)) '()))
(define (mk-cred-to i holder)
  (make-credential *schema-playnet-membership* %issuer-aid holder
                   `((seq . ,i)) '()))

;; ── Case 1: happy path, KERIA up ───────────────────────────────────

(set! %grant-up? #t)
(set! %grant-attempts 0)
(define %said-1
  (with-vat %vat ($ %store 'issue (mk-cred 1))))

(check "happy: issue returned the keria-said"
       (equal? %said-1 %issued-said))

(check "happy: exactly one grant attempt"
       (= 1 %grant-attempts))

(check "happy: central queue is empty"
       (= 0 (with-vat %q-vat ($ %q 'count))))

;; ── Case 2: KERIA-down during issue ────────────────────────────────

(set! %grant-up? #f)
(set! %grant-attempts 0)
(define %said-2
  (with-vat %vat ($ %store 'issue (mk-cred 2))))

(check "down: issue still returned a said (local issue succeeded)"
       (equal? %said-2 %issued-said))

(check "down: grant was attempted"
       (= 1 %grant-attempts))

(check "down: central queue now has the failed entry"
       (q-count-eq? 1))

(check "down: entry is kind = 'umbrella-grant"
       (eq? 'umbrella-grant
            (pending-grant-kind
             (car (with-vat %q-vat ($ %q 'all))))))

;; Issue another one while KERIA stays down
(with-vat %vat ($ %store 'issue (mk-cred 3)))

(check "down: second failed issue → central queue count = 2"
       (q-count-eq? 2))

;; ── Case 3: drain while KERIA still down → no progress ─────────────

(set! %grant-attempts 0)
(define %drain-while-down (with-vat %q-vat ($ %q 'drain!)))

(check "drain (still down): 0 drained, 2 still pending"
       (and (= 0 (car %drain-while-down))
            (= 2 (cdr %drain-while-down))))

(check "drain (still down): made 2 retry attempts"
       (= 2 %grant-attempts))

;; ── Case 4: KERIA recovers, drain succeeds ─────────────────────────
;;
;; Reset to a clean state: clear the queue, enqueue 2 fresh failed
;; grants under down-KERIA, then flip up and drain. Avoids depending
;; on case-3's "drain re-enqueued the entries" behaviour.

(with-vat %q-vat ($ %q 'clear!))
(set! %grant-up? #f)
(with-vat %vat ($ %store 'issue (mk-cred 4)))
(with-vat %vat ($ %store 'issue (mk-cred 5)))
(check "case-4 setup: 2 entries queued under down KERIA"
       (q-count-eq? 2))

(set! %grant-up? #t)
(set! %grant-attempts 0)
(define %drain-after-up (with-vat %q-vat ($ %q 'drain!)))

(check "drain (recovered): both grants drained"
       (and (= 2 (car %drain-after-up))
            (= 0 (cdr %drain-after-up))))

(check "drain (recovered): central queue is empty"
       (= 0 (with-vat %q-vat ($ %q 'count))))

(check "drain (recovered): 2 successful retries"
       (= 2 %grant-attempts))

;; ── Case 5: a holder that is a scope of this gateway is home at issue ──
;;
;; The founding commune and the universal commune hold their credentials
;; in their own acdc-store; no scope of ours reads a KERIA mailbox. Such
;; a holder takes no grant attempt and leaves nothing in the queue — and
;; an entry already queued for it (from before this rule) drains as
;; delivered.

(define %home-state-dir
  (string-append "/tmp/playnet-keria-store-home-" (number->string (current-time))))
(setenv "PLAYNET_STATE_DIR" %home-state-dir)
(define %home-holder "DHome000000000000000000000000000000000000000")
(let ((dir (string-append %home-state-dir "/scopes/" %home-holder)))
  (system* "mkdir" "-p" dir))

(with-vat %q-vat ($ %q 'clear!))
(set! %grant-up? #t)
(set! %grant-attempts 0)
(with-vat %vat ($ %store 'issue (mk-cred-to 6 %home-holder)))

(check "home holder: issue makes no grant attempt"
       (= 0 %grant-attempts))
(check "home holder: nothing queued"
       (q-count-eq? 0))

(with-vat %q-vat
  ($ %q 'enqueue (make-pending-grant
                  'umbrella-grant
                  `((issuer-aid-name . "test-issuer")
                    (said . ,%issued-said)
                    (holder . ,%home-holder)))))
(define %drain-home (with-vat %q-vat ($ %q 'drain!)))
(check "home holder: a queued entry drains as delivered"
       (and (= 1 (car %drain-home)) (= 0 (cdr %drain-home))))
(check "home holder: the drain made no grant attempt"
       (= 0 %grant-attempts))

(test-summary!)
