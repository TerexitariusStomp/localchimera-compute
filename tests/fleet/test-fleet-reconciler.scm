;;; tests/fleet/test-fleet-reconciler.scm — end-to-end reconciler test
;;;
;;; This test stitches together all four layers:
;;;
;;;   1. A mock SporeStack API server (subset: add, info, servers,
;;;      /servers/{id}).
;;;   2. A mock SporeStack provider (wraps the mock server).
;;;   3. A stub ^monero-wallet that records transfer calls.
;;;   4. A real ^wallet-policy wired to the stub wallet.
;;;   5. A real ^fleet-reconciler wired to the real policy + provider.
;;;
;;; Run:
;;;   guile -L module -L tests tests/fleet/test-fleet-reconciler.scm

(use-modules (goblins)
             (goblins vat)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (playnet test harness)
             (web server)
             (web request)
             (web response)
             (web uri)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-1)
             (srfi srfi-9)
             (ice-9 threads)
             (ice-9 format)
             (ice-9 match)
             (json)
             (playnet monero wallet)
             (playnet monero policy)
             (playnet fleet sporestack)
             (playnet fleet sporestack-provider)
             (playnet fleet provider)
             (playnet fleet records)
             (playnet fleet reconciler))

;;; ── Stub wallet ──────────────────────────────────────────────────────────

(define (make-log) (list 'log))
(define (log-append! log v) (set-cdr! log (cons v (cdr log))))
(define (log-entries log) (reverse (cdr log)))

(define (^stub-wallet _bcom call-log)
  (methods
    [(transfer destinations)
     (log-append! call-log `(transfer ,destinations))
     (list (cons "tx_hash" "cafef00d00000000000000000000000000000000000000000000000000000000")
           (cons "amount" (fold + 0 (map (lambda (d) (assoc-ref d "amount")) destinations)))
           (cons "fee" 10000000))]
    [(get-balance) (make-balance-info 10000000000000 10000000000000 0)]
    [(get-address)
     "44Stub000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"]
    [(calls) (log-entries call-log)]))

;;; ── Mock SporeStack ──────────────────────────────────────────────────────

(define %token "ss_t_reconciler_test_000000000000000000000_zzzz")
(define %machine-id "ss_m_reconciler_test_000000000000000000000_yyyy")
(define %xmr-address
  "4ReconcilerTestAddress00000000000000000000000000000000000000000000000000000000000000000000000000AA")

(define %state-balance 0)
(define %state-invoice-paid? #f)
(define %state-server-launched? #f)
(define %state-server-running? #f)
(define %state-poll-count 0)
(define %state-launch-calls 0)

(define (with-json-body code body-scm)
  ;; a BYTEVECTOR body, not a string: (web server)'s respond auto-appends a
  ;; charset param to Content-Type for a string body by destructuring it as
  ;; (type . params) — incompatible with the bare-string form Content-Type is
  ;; declared as everywhere in this codebase (playnet utils http-auth). A
  ;; bytevector body skips that whole path.
  (values
   (build-response
    #:code code
    #:headers '((content-type . "application/json")))
   (string->utf8 (scm->json-string body-scm))))

(define (parse-body body)
  (let ((s (if (bytevector? body) (utf8->string body) (or body ""))))
    (if (string-null? s) '() (json-string->scm s))))

(define (path-for-token suffix)
  (string-append "/token/" %token suffix))

(define (handle-request request body)
  (let* ((method (request-method request))
         (path   (uri-path (request-uri request))))
    (cond
     ;; POST /token/.../add — create top-up invoice.
     ((and (eq? method 'POST) (equal? path (path-for-token "/add")))
      (parse-body body)
      (with-json-body 200
        `(("id" . "inv_reconciler_001")
          ("cryptocurrency" . "xmr")
          ("amount" . 500)
          ("fiat_per_coin" . "150.00")
          ("payment_uri" . ,(string-append "monero:" %xmr-address
                                           "?tx_amount=0.0333"))
          ("created" . 1712000000)
          ("expires" . 1712003600)
          ("paid" . 0)
          ("txid" . ""))))

     ;; GET /token/.../info — return current balance state.
     ((and (eq? method 'GET) (equal? path (path-for-token "/info")))
      (with-json-body 200
        `(("balance_cents" . ,%state-balance)
          ("balance_usd" . "$x.xx")
          ("burn_rate_cents" . 20)
          ("burn_rate_usd" . "$0.20")
          ("days_remaining" . ,(if (> %state-balance 0) 25 0))
          ("servers" . ,(if %state-server-launched? 1 0))
          ("autorenew_servers" . 0)
          ("suspended_servers" . 0)
          ("messages" . 0)
          ("invoices" . 1))))

     ;; POST /token/.../servers — launch.
     ((and (eq? method 'POST) (equal? path (path-for-token "/servers")))
      (parse-body body)
      (set! %state-launch-calls (+ 1 %state-launch-calls))
      (set! %state-server-launched? #t)
      (with-json-body 200 `(("machine_id" . ,%machine-id))))

     ;; GET /token/.../servers/{id} — poll status.
     ((and (eq? method 'GET)
           (equal? path (path-for-token (string-append "/servers/" %machine-id))))
      (set! %state-poll-count (+ 1 %state-poll-count))
      (when (>= %state-poll-count 2)
        (set! %state-server-running? #t))
      (with-json-body 200
        `(("machine_id" . ,%machine-id)
          ("region" . "nyc1")
          ("ipv4" . ,(if %state-server-running? "203.0.113.77" ""))
          ("ipv6" . "")
          ("created_at" . 1712000000)
          ("expiration" . 1712086400)
          ("running" . ,%state-server-running?)
          ("flavor_slug" . "vps-1vcpu-1gb")
          ("operating_system" . "debian-12")
          ("hostname" . "playnet-test-recon")
          ("autorenew" . #f)
          ("billing_cycle" . "daily")
          ("deleted_at" . 0)
          ("deleted_by" . "")
          ("suspended_at" . 0)
          ("forgotten_at" . 0)
          ("provider" . "digitalocean"))))

     (else (values (build-response #:code 404) "not found")))))

;; The harness owns this: `pick-free-port` cannot RESERVE the port it reports
;; (the socket must close before the real server binds), so a parallel run can
;; hand two tests the same number. spawn-mock-server retries the lost race and
;; polls until the port actually accepts, instead of sleeping a flat 200ms and
;; hoping. This file used to carry its own copy of the broken version.
(define-values (%port %server-thread) (spawn-mock-server handle-request))
(define %base (format #f "http://127.0.0.1:~a" %port))

(format #t "=== Starting mock sporestack on ~a ===~%" %base)


;;; ── Build provider registry ─────────────────────────────────────────────

(define %creds (make-sporestack-creds %base %token))
(define %sporestack-provider (make-sporestack-provider %creds))
(define %providers
  (make-provider-registry
   `(("sporestack" . ,%sporestack-provider))))

;;; ── Temp files ───────────────────────────────────────────────────────────

(define %tmpdir (string-append "/tmp/playnet-test-reconciler-"
                               (number->string (getpid))))
(system* "mkdir" "-p" %tmpdir)

(define %desired-path (string-append %tmpdir "/desired-fleet.scm"))
(define %hosts-path   (string-append %tmpdir "/hosts.scm"))

;; Write the desired-fleet file with one host.
;; Uses sporestack-host (backward-compat constructor).
(call-with-output-file %desired-path
  (lambda (port)
    (display "(use-modules (playnet fleet records))" port) (newline port)
    (newline port)
    (display "(list" port) (newline port)
    (display "  (sporestack-host" port) (newline port)
    (display "    #:name \"playnet-test-recon\"" port) (newline port)
    (display "    #:flavor \"vps-1vcpu-1gb\"" port) (newline port)
    (display "    #:operating-system \"debian-12\"" port) (newline port)
    (display "    #:provider \"digitalocean\"" port) (newline port)
    (display "    #:region \"nyc1\"" port) (newline port)
    (display "    #:days 30" port) (newline port)
    (display "    #:hostname \"playnet-test-recon\"" port) (newline port)
    (display "    #:estimated-monthly-usd 5))" port) (newline port)))

;;; ── Build the actor stack ───────────────────────────────────────────────

(define vat (spawn-vat))

(define log1 (make-log))
(define wallet (with-vat vat (spawn ^stub-wallet log1)))

(define %policy
  (make-monero-spend-policy
   10                   ; monthly-budget
   2                    ; default per-tx cap
   (list (make-allowed-payee "sporestack-topup" %xmr-address 2 "XMR->VPS"))
   "test reconciler policy"))

(define policy (with-vat vat (spawn ^wallet-policy wallet %policy 0 0 (lambda (_) #f) (lambda (_) #t))))

(define %fake-ssh-key
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI0Testingkey test-reconciler")

;; Reconciler: takes providers registry + swapper (nil for XMR-only tests)
(define reconciler
  (with-vat vat
    (spawn ^fleet-reconciler
           policy
           %providers
           #f          ; swapper (not needed for SporeStack/XMR path)
           %fake-ssh-key
           %desired-path
           %hosts-path
           (hashmap)
           0       ; last-reconcile
           0       ; min-reconcile-interval (0 = no cooldown for tests)
           #f)))   ; token-rotation (idle)

;;; ── Tick 1: invoice placed + XMR transferred ────────────────────────────

(format #t "~%=== Tick 1: expect invoice + paid-state → paying ===~%")

(let ((result (with-vat vat ($ reconciler 'reconcile))))
  (check "tick 1 returned a result alist" (pair? result))
  (check "tick 1 desired count = 1"
         (= 1 (assq-ref result 'desired)))
  (check "tick 1 in-flight count = 1"
         (= 1 (assq-ref result 'in-flight)))
  (check "tick 1 newly-provisioned = 0"
         (= 0 (assq-ref result 'newly-provisioned))))

(let ((status (with-vat vat ($ reconciler 'status))))
  (check "tick 1: reconciler sees exactly one in-flight entry"
         (= 1 (assq-ref status 'in-flight-count)))
  (check "tick 1: in-flight entry state is 'paying"
         (eq? 'paying
              (cdr (assoc "playnet-test-recon"
                          (assq-ref status 'in-flight-states)))))
  (check "tick 1: providers list includes sporestack"
         (member "sporestack" (assq-ref status 'providers))))

(check "tick 1: stub wallet saw exactly one transfer"
       (= 1 (length (with-vat vat ($ wallet 'calls)))))

(let* ((calls (with-vat vat ($ wallet 'calls)))
       (transfer (car calls))
       (destinations (cadr transfer))
       (dest (car destinations)))
  (check "tick 1: transfer destination matches invoice address"
         (equal? %xmr-address (assoc-ref dest "address")))
  (check "tick 1: transfer amount = 0.0333 XMR in atomic units"
         (= (xmr->atomic 0.0333) (assoc-ref dest "amount"))))

(let ((stats (with-vat vat ($ policy 'stats))))
  (check "tick 1: policy spent-atomic = 0.0333 XMR (atomic)"
         (= (xmr->atomic 0.0333) (assq-ref stats 'spent-atomic))))

;;; ── Simulate SporeStack seeing the payment ──────────────────────────────

(set! %state-balance 500)

;;; ── Tick 2: balance confirmed → funded → launching ──────────────────────

(format #t "~%=== Tick 2: funded → launching ===~%")

(let ((_ (with-vat vat ($ reconciler 'reconcile))))
  (let ((status (with-vat vat ($ reconciler 'status))))
    (check "tick 2: in-flight count still 1"
           (= 1 (assq-ref status 'in-flight-count)))
    (check "tick 2: state advanced past 'paying"
           (not (eq? 'paying
                     (cdr (assoc "playnet-test-recon"
                                 (assq-ref status 'in-flight-states))))))))

;;; ── Keep ticking until provisioned ──────────────────────────────────────

(format #t "~%=== Tick through to 'provisioned ===~%")

(let loop ((n 0))
  (cond
   ((> n 10) (check "reached provisioned state within tick budget" #f))
   (else
    (with-vat vat ($ reconciler 'reconcile))
    (let ((status (with-vat vat ($ reconciler 'status))))
      (cond
       ((zero? (assq-ref status 'in-flight-count))
        (format #t "  in-flight drained after tick ~a~%" (+ n 2)))
       (else (loop (+ n 1))))))))

(check "terminal: no more in-flight entries"
       (zero? (assq-ref (with-vat vat ($ reconciler 'status)) 'in-flight-count)))

(check "terminal: hosts.scm was written"
       (file-exists? %hosts-path))

;;; ── Verify hosts.scm content ────────────────────────────────────────────

(format #t "~%=== Verify hosts.scm ===~%")

(define written-hosts (primitive-load %hosts-path))

(check "hosts.scm returned a list of length 1"
       (and (list? written-hosts) (= 1 (length written-hosts))))

(when (pair? written-hosts)
  (let ((m (car written-hosts)))
    (check "hosts.scm entry is a materialized-host"
           (materialized-host? m))
    (check "hosts.scm entry name matches"
           (equal? "playnet-test-recon" (materialized-host-name m)))
    (check "hosts.scm entry machine-id matches"
           (equal? %machine-id (materialized-host-machine-id m)))
    (check "hosts.scm entry ipv4 matches what SporeStack returned"
           (equal? "203.0.113.77" (materialized-host-ipv4 m)))
    ;; Provider field now stores "sporestack" (the registry name),
    ;; not "digitalocean" (the backend).
    (check "hosts.scm entry provider is sporestack"
           (equal? "sporestack" (materialized-host-provider m)))
    (check "hosts.scm entry flavor matches"
           (equal? "vps-1vcpu-1gb" (materialized-host-flavor m)))
    (check "hosts.scm entry estimated-monthly-atomic matches budget"
           (= (xmr->atomic 0.0333)
              (materialized-host-estimated-monthly-atomic m)))))

;;; ── Tick N+1: idempotent, no new activity ───────────────────────────────

(format #t "~%=== Tick (idempotent): no new activity ===~%")

(let ((launches-before %state-launch-calls))
  (with-vat vat ($ reconciler 'reconcile))
  (check "idempotent tick: no new launches"
         (= launches-before %state-launch-calls))
  (check "idempotent tick: wallet call count unchanged"
         (= 1 (length (with-vat vat ($ wallet 'calls))))))

;;; ── Cleanup ──────────────────────────────────────────────────────────────

(system* "rm" "-rf" %tmpdir)

;;; ── Summary ──────────────────────────────────────────────────────────────

(test-summary!)
