;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/fleet/test-sporestack-client.scm — SporeStack client unit tests
;;;
;;; Mocks the subset of the SporeStack API that the fleet reconciler
;;; uses via a small in-process (web server). Exercises:
;;;
;;;   - POST /token/{token}/add → InvoiceRead with monero: payment_uri
;;;   - GET  /token/{token}/balance
;;;   - GET  /token/{token}/info
;;;   - POST /token/{token}/servers (launch)
;;;   - GET  /token/{token}/servers/{id} (first returns running=false,
;;;     then running=true on a subsequent poll)
;;;   - GET  /token/{token}/servers
;;;   - DELETE /token/{token}/servers/{id}
;;;   - GET  /slugs/flavors
;;;
;;; Also verifies that:
;;;   - The token is passed through the URL path, not an Authorization header
;;;   - Monero payment_uri is correctly parsed into (address, amount-xmr)
;;;   - Poll-until-running pattern works (client tolerates intermediate
;;;     running=false responses)
;;;
;;; Run:
;;;   guile -L module -L tests tests/fleet/test-sporestack-client.scm

(use-modules (localchimera test harness)
             (web server)
             (web request)
             (web response)
             (web uri)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-1)
             (ice-9 threads)
             (ice-9 format)
             (ice-9 match)
             (json)
             (localchimera fleet sporestack))

;;; ── Mock SporeStack server ───────────────────────────────────────────────
;;;
;;; Tracks: request count per path+method, current launch state machine
;;; for a single fake server.

(define %token "ss_t_test_000000000000000000000000000000000000_aaaa")
(define %machine-id "ss_m_test_000000000000000000000000000000000000_bbbb")
(define %xmr-address
  "4AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz112233445566778899aabbccddeeff00112233445566778899")

;; Mutable mock state.
(define %server-launched? #f)
(define %server-running? #f)
(define %server-poll-count 0)
(define %delete-called? #f)
(define %last-launch-body #f)
(define %last-add-body #f)

(define (with-json-body response body-scm)
  ;; a BYTEVECTOR body, not a string: (web server)'s respond auto-appends a
  ;; charset param to Content-Type for a string body by destructuring it as
  ;; (type . params) — incompatible with the bare-string form Content-Type is
  ;; declared as everywhere in this codebase (localchimera utils http-auth). A
  ;; bytevector body skips that whole path.
  (values
   (build-response
    #:code 200
    #:headers '((content-type . "application/json")))
   (string->utf8 (scm->json-string body-scm))))

(define (not-found)
  (values (build-response #:code 404) "not found"))

(define (parse-body body)
  (let ((s (if (bytevector? body) (utf8->string body) (or body ""))))
    (if (string-null? s) '() (json-string->scm s))))

(define (path-for-token suffix)
  (string-append "/token/" %token suffix))

(define (handle-request request body)
  (let* ((method (request-method request))
         (path   (uri-path (request-uri request))))

    (cond
     ;; ── POST /token/{token}/add ──────────────────────────────────
     ((and (eq? method 'POST)
           (equal? path (path-for-token "/add")))
      (set! %last-add-body (parse-body body))
      (with-json-body
       (build-response
        #:code 200
        #:headers '((content-type . "application/json")))
       `(("id"            . "inv_test_001")
         ("cryptocurrency" . "xmr")
         ("amount"        . 500)                 ; 5.00 USD in cents
         ("fiat_per_coin" . "150.00")
         ("payment_uri"   . ,(string-append "monero:" %xmr-address
                                            "?tx_amount=0.0333&tx_description=topup"))
         ("created"       . 1712000000)
         ("expires"       . 1712003600)
         ("paid"          . 0)
         ("txid"          . ""))))

     ;; ── GET /token/{token}/balance ───────────────────────────────
     ((and (eq? method 'GET)
           (equal? path (path-for-token "/balance")))
      (with-json-body (build-response #:code 200)
                      '(("cents" . 500) ("usd" . "$5.00"))))

     ;; ── GET /token/{token}/info ──────────────────────────────────
     ((and (eq? method 'GET)
           (equal? path (path-for-token "/info")))
      (with-json-body (build-response #:code 200)
                      '(("balance_cents" . 500)
                        ("balance_usd" . "$5.00")
                        ("burn_rate_cents" . 20)
                        ("burn_rate_usd" . "$0.20")
                        ("days_remaining" . 25)
                        ("servers" . 1)
                        ("autorenew_servers" . 0)
                        ("suspended_servers" . 0)
                        ("messages" . 0)
                        ("invoices" . 1))))

     ;; ── POST /token/{token}/servers (launch) ─────────────────────
     ((and (eq? method 'POST)
           (equal? path (path-for-token "/servers")))
      (set! %last-launch-body (parse-body body))
      (set! %server-launched? #t)
      (with-json-body (build-response #:code 200)
                      `(("machine_id" . ,%machine-id))))

     ;; ── GET /token/{token}/servers/{id} ──────────────────────────
     ((and (eq? method 'GET)
           (equal? path (path-for-token
                         (string-append "/servers/" %machine-id))))
      (set! %server-poll-count (+ 1 %server-poll-count))
      ;; Flip to running on the 2nd poll.
      (when (= %server-poll-count 2) (set! %server-running? #t))
      (with-json-body
       (build-response #:code 200)
       `(("machine_id" . ,%machine-id)
         ("region" . "nyc1")
         ("ipv4"   . ,(if %server-running? "198.51.100.23" ""))
         ("ipv6"   . "")
         ("created_at" . 1712000000)
         ("expiration" . 1712086400)
         ("running" . ,%server-running?)
         ("flavor_slug" . "vps-1vcpu-1gb")
         ("operating_system" . "debian-12")
         ("hostname" . "localchimera-test-1")
         ("autorenew" . #f)
         ("billing_cycle" . "daily")
         ("deleted_at" . 0)
         ("deleted_by" . "")
         ("suspended_at" . 0)
         ("forgotten_at" . 0)
         ("provider" . "digitalocean"))))

     ;; ── GET /token/{token}/servers (list) ────────────────────────
     ((and (eq? method 'GET)
           (equal? path (path-for-token "/servers")))
      (with-json-body
       (build-response #:code 200)
       `(("servers" . ,(if %server-launched?
                           (vector
                            `(("machine_id" . ,%machine-id)
                              ("running" . ,%server-running?)
                              ("ipv4" . ,(if %server-running? "198.51.100.23" ""))
                              ("hostname" . "localchimera-test-1")
                              ("flavor_slug" . "vps-1vcpu-1gb")
                              ("operating_system" . "debian-12")
                              ("provider" . "digitalocean")))
                           (vector))))))

     ;; ── DELETE /token/{token}/servers/{id} ───────────────────────
     ((and (eq? method 'DELETE)
           (equal? path (path-for-token
                         (string-append "/servers/" %machine-id))))
      (set! %delete-called? #t)
      (values (build-response #:code 204) ""))

     ;; ── GET /slugs/flavors ──────────────────────────────────────
     ((and (eq? method 'GET) (equal? path "/slugs/flavors"))
      (with-json-body
       (build-response #:code 200)
       (vector
        `(("slug" . "vps-1vcpu-1gb")
          ("cores" . 1)
          ("memory" . 1024)
          ("disk" . 25)
          ("price" . 17)          ; cents per day
          ("monthly_price" . 500)
          ("annual_price" . 6000)
          ("ipv4" . #t)
          ("ipv6" . #t)
          ("bandwidth_per_month" . 1000)
          ("provider" . "digitalocean")
          ("features" . ,(vector))
          ("type" . "vps")
          ("architecture" . "amd64")))))

     (else (not-found)))))

;;; ── Pick free port + spawn server ────────────────────────────────────────

;; The harness owns this: `pick-free-port` cannot RESERVE the port it reports
;; (the socket must close before the real server binds), so a parallel run can
;; hand two tests the same number. spawn-mock-server retries the lost race and
;; polls until the port actually accepts, instead of sleeping a flat 200ms and
;; hoping. This file used to carry its own copy of the broken version.
(define-values (%port %server-thread) (spawn-mock-server handle-request))
(define %base (format #f "http://127.0.0.1:~a" %port))

(format #t "=== Starting mock sporestack on ~a ===~%" %base)


;;; ── Exercise the client ─────────────────────────────────────────────────

(define creds (make-sporestack-creds %base %token))

(format #t "~%=== Top-up (POST /add) ===~%")
(let ((invoice (sporestack-add-funds creds #:currency "xmr" #:dollars 5)))
  (check "add-funds returned an invoice alist" (pair? invoice))
  (check "invoice id is set"
         (string? (invoice-id invoice)))
  (check "invoice amount matches request (500 cents)"
         (= 500 (invoice-amount-usd-cents invoice)))
  (check "invoice not yet paid" (not (invoice-paid? invoice)))

  (let ((uri (parse-monero-uri (invoice-payment-uri invoice))))
    (check "payment_uri parses as monero:" (monero-uri? uri))
    (check "address matches mock"
           (equal? (monero-uri-address uri) %xmr-address))
    (check "amount-xmr is 0.0333"
           (and (number? (monero-uri-amount-xmr uri))
                (< (abs (- (monero-uri-amount-xmr uri) 0.0333)) 1e-9))))

  (check "server saw add request with currency=xmr"
         (equal? "xmr" (assoc-ref %last-add-body "currency")))
  (check "server saw add request with dollars=5"
         (= 5 (assoc-ref %last-add-body "dollars"))))

(format #t "~%=== Balance + info ===~%")
(let ((b (sporestack-balance creds)))
  (check "balance returns cents field"
         (= 500 (assoc-ref b "cents")))
  (check "balance returns usd field"
         (string? (assoc-ref b "usd"))))

(let ((info (sporestack-info creds)))
  (check "info has days_remaining"
         (= 25 (assoc-ref info "days_remaining")))
  (check "info has burn_rate_cents"
         (= 20 (assoc-ref info "burn_rate_cents"))))

(format #t "~%=== Launch server ===~%")
(let ((resp (sporestack-launch-server
             creds
             #:flavor "vps-1vcpu-1gb"
             #:ssh-key "ssh-ed25519 AAAAC3Nza... test"
             #:operating-system "debian-12"
             #:provider "digitalocean"
             #:region "nyc1"
             #:hostname "localchimera-test-1"
             #:days 1
             #:user-data "#!/bin/bash\necho hello\n")))
  (check "launch returned a machine_id"
         (equal? %machine-id (assoc-ref resp "machine_id")))
  (check "launch body had flavor"
         (equal? "vps-1vcpu-1gb" (assoc-ref %last-launch-body "flavor")))
  (check "launch body had operating_system"
         (equal? "debian-12" (assoc-ref %last-launch-body "operating_system")))
  (check "launch body had ssh_key"
         (string-contains (or (assoc-ref %last-launch-body "ssh_key") "")
                          "ssh-ed25519"))
  (check "launch body had user_data"
         (string-contains (or (assoc-ref %last-launch-body "user_data") "")
                          "hello")))

(format #t "~%=== Poll until running ===~%")
(let loop ((n 0))
  (cond
   ((> n 5)
    (check "server became running within poll budget" #f))
   (else
    (let ((srv (sporestack-get-server creds %machine-id)))
      (if (server-running? srv)
          (begin
            (check "server-running? reports true"
                   (server-running? srv))
            (check "server-ipv4 is now populated"
                   (and (string? (server-ipv4 srv))
                        (> (string-length (server-ipv4 srv)) 0))))
          (loop (+ n 1)))))))

(check "poll count is exactly 2 (flipped to running on 2nd poll)"
       (= 2 %server-poll-count))

(format #t "~%=== List servers ===~%")
(let* ((resp (sporestack-list-servers creds))
       (servers (assoc-ref resp "servers")))
  (check "list returned a vector of servers"
         (vector? servers))
  (check "list contains exactly one server"
         (= 1 (vector-length servers))))

(format #t "~%=== Slugs/flavors ===~%")
(let ((fl (sporestack-list-flavors creds #:provider "digitalocean")))
  (check "flavors list is non-empty vector"
         (and (vector? fl) (> (vector-length fl) 0)))
  (let ((f0 (vector-ref fl 0)))
    (check "first flavor has slug"
           (string? (assoc-ref f0 "slug")))))

(format #t "~%=== Delete ===~%")
(check "delete returns #t (204 normalized)"
       (eq? #t (sporestack-delete-server creds %machine-id)))
(check "server saw delete"
       %delete-called?)

;;; ── Error path ──────────────────────────────────────────────────────────

(format #t "~%=== Error on unknown machine id ===~%")
(check "GET on unknown machine raises a descriptive error"
       (catch #t
         (lambda ()
           (sporestack-get-server creds "ss_m_does_not_exist")
           #f)
         (lambda _ #t)))

;;; ── Summary ──────────────────────────────────────────────────────────────

(test-summary!)
