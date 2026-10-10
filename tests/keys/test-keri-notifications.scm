;;; tests/keys/test-keri-notifications.scm — notification dispatch + handler tests
;;;
;;; Exercises (playnet federation keria-notifications):
;;;   - Route constants (just strings, cheap sanity check)
;;;   - register-notification-handler!  (single + multiple handlers per route)
;;;   - Private dispatch-notification / process-notification via @@ access
;;;   - Outbound filter (skip notifications we originated)
;;;   - install-default-handlers! (registers multisig-rpy + remote-sign)
;;;
;;; The fibers-based poll loop + exponential retry are NOT exercised here —
;;; those are timing-sensitive and belong in the real-KERIA integration suite.
;;; Everything testable via the pure dispatch path is covered.
;;;
;;; Run: guile -L module -L tests tests/keys/test-keri-notifications.scm

(use-modules (playnet test harness)
             (playnet keri bridge)
             (playnet federation keria-notifications)
             (web server)
             (web request)
             (web response)
             (web uri)
             (web http)
             (rnrs bytevectors)
             (ice-9 format)
             (json))

(declare-opaque-header! "authorization")

;; Reach into the module for the private dispatch + process procedures.
(define dispatch-notification
  (@@ (playnet federation keria-notifications) dispatch-notification))
(define process-notification
  (@@ (playnet federation keria-notifications) process-notification))
(define reset-handlers!
  (lambda ()
    (module-define! (resolve-module '(playnet federation keria-notifications))
                    '*handlers* '())))

;; Read *local-aid-prefixes* so we can reset between tests.
(define reset-local-aids!
  (lambda ()
    (module-define! (resolve-module '(playnet federation keria-notifications))
                    '*local-aid-prefixes* #f)))

;;; ── Mock state ────────────────────────────────────────────────────────

(define %our-aid    "EOurAID0000000000000000000000000000000000000")
(define %peer-aid   "EPeerAID000000000000000000000000000000000000")
(define %mark-read-calls '())

(define (with-json code body)
  (values
   (build-response
    #:code code
    #:headers '((content-type . (application/json))))
   (scm->json-string body)))

(define (parse-body body)
  (let ((s (if (bytevector? body) (utf8->string body) (or body ""))))
    (if (string-null? s) '() (json-string->scm s))))

(define (extract-mark-id path)
  ;; /notifications/{id}/mark
  (let* ((prefix "/notifications/")
         (suffix "/mark"))
    (and (string-prefix? prefix path)
         (string-suffix? suffix path)
         (uri-decode
          (substring path (string-length prefix)
                     (- (string-length path) (string-length suffix)))))))

(define (handle-request request body)
  (let* ((method (request-method request))
         (path   (uri-path (request-uri request))))
    (cond
     ((string=? path "/connect")
      (with-json 200 `(("url" . ,%base) ("agent" . (("i" . ,%our-aid))))))

     ;; GET /identifiers — keri-list-aids, used by outbound filter
     ((and (eq? method 'GET) (string=? path "/identifiers"))
      (with-json 200 (vector `(("prefix" . ,%our-aid)))))

     ;; POST /notifications/{nid}/mark
     ((and (eq? method 'POST) (string-suffix? "/mark" path))
      (let ((nid (extract-mark-id path)))
        (set! %mark-read-calls (cons nid %mark-read-calls)))
      (with-json 200 '()))

     (else
      (values (build-response #:code 404) "not found")))))

(define-values (%port %thread)
  (spawn-mock-server handle-request))

(define %base (format #f "http://127.0.0.1:~a" %port))

(format #t "=== KERI Notifications Tests (mock on ~a) ===~%" %base)

(keri-set-urls! %base %base)
(keri-connect! "testbran21chars00000")

;;; ── Route constants ──────────────────────────────────────────────────

(format #t "~%=== Route constants ===~%")

(check "multisig-icp route"   (equal? "/multisig/icp" notification-route/multisig-icp))
(check "multisig-exn route"   (equal? "/multisig/exn" notification-route/multisig-exn))
(check "multisig-rpy route"   (equal? "/multisig/rpy" notification-route/multisig-rpy))
(check "ipex-apply route"     (equal? "/exn/ipex/apply" notification-route/ipex-apply))
(check "ipex-offer route"     (equal? "/exn/ipex/offer" notification-route/ipex-offer))
(check "ipex-agree route"     (equal? "/exn/ipex/agree" notification-route/ipex-agree))
(check "ipex-grant route"     (equal? "/exn/ipex/grant" notification-route/ipex-grant))
(check "remote-sign route"    (equal? "/exn/remotesign/ixn/req" notification-route/remote-sign))

;;; ── register-notification-handler! + dispatch ────────────────────────

(format #t "~%=== register-notification-handler! ===~%")

(reset-handlers!)

(define %calls '())   ; list of (route said note)

(register-notification-handler! notification-route/ipex-grant
  (lambda (route said note)
    (set! %calls (cons (list route said note) %calls))))

;; Call the private dispatcher directly with a synthetic notification
(dispatch-notification notification-route/ipex-grant
                       "ESAID000000000000000000000000000000000000"
                       '(("i" . "nid-1")))

(check "single handler: called exactly once"
       (= 1 (length %calls)))
(check "handler got the route"
       (equal? notification-route/ipex-grant (car (car %calls))))
(check "handler got the said"
       (equal? "ESAID000000000000000000000000000000000000" (cadr (car %calls))))

;;; Multiple handlers per route — both should fire, in registration order
(set! %calls '())

(register-notification-handler! notification-route/ipex-grant
  (lambda (route said note)
    (set! %calls (cons 'second %calls))))

(dispatch-notification notification-route/ipex-grant "ESAID2" '())

(check "two handlers: both called" (= 2 (length %calls)))
(check "registration order preserved (second runs second, ends up at head)"
       (eq? 'second (car %calls)))

;;; Handler for unregistered route is a no-op
(set! %calls '())
(dispatch-notification "/unknown/route" "ESAID3" '())
(check "unregistered route: no handlers called" (null? %calls))

;;; Handler that throws doesn't break the dispatch chain
(reset-handlers!)
(set! %calls '())
(register-notification-handler! "/risky"
  (lambda (route said note)
    (error "boom")))
(register-notification-handler! "/risky"
  (lambda (route said note)
    (set! %calls (cons 'survived %calls))))
(dispatch-notification "/risky" "ESAID4" '())
(check "handler error doesn't prevent subsequent handlers"
       (equal? '(survived) %calls))

;;; ── process-notification ─────────────────────────────────────────────

(format #t "~%=== process-notification ===~%")

(reset-handlers!)
(reset-local-aids!)
(set! %mark-read-calls '())
(set! %calls '())

(register-notification-handler! notification-route/ipex-grant
  (lambda (route said note)
    (set! %calls (cons said %calls))))

;; Inbound notification (from peer) — should dispatch + mark read
(define %note-inbound
  `(("i" . "nid-inbound")
    ("a" . (("r" . ,notification-route/ipex-grant)
            ("d" . "ESAID-inbound0000000000000000000000000000")
            ("exn" . (("i" . ,%peer-aid)))))))

(let ((ok? (process-notification %note-inbound)))
  (check "process-notification returns #t on success" (eq? #t ok?))
  (check "handler was invoked"
         (equal? '("ESAID-inbound0000000000000000000000000000") %calls))
  (check "mark-read was called with the notification id"
         (member "nid-inbound" %mark-read-calls)))

;; Outbound notification — we are the sender (exn.i == our AID) — should be
;; silently skipped: mark-read still fires, but handler does NOT
(reset-local-aids!)
(set! %mark-read-calls '())
(set! %calls '())

(define %note-outbound
  `(("i" . "nid-outbound")
    ("a" . (("r" . ,notification-route/ipex-grant)
            ("d" . "ESAID-outbound000000000000000000000000000")
            ("exn" . (("i" . ,%our-aid)))))))

(let ((ok? (process-notification %note-outbound)))
  (check "outbound: process returns #t" (eq? #t ok?))
  (check "outbound: handler NOT invoked (filtered)" (null? %calls))
  (check "outbound: mark-read still fires"
         (member "nid-outbound" %mark-read-calls)))

;; Notification with no route — should be silently skipped
(reset-local-aids!)
(set! %mark-read-calls '())
(set! %calls '())

(let ((ok? (process-notification `(("i" . "nid-noroute")
                                   ("a" . (("d" . "ESAID"))))))) ; no "r"
  (check "no-route notification: returns #t (skipped)" (eq? #t ok?))
  (check "no-route: handler NOT invoked" (null? %calls)))

;;; ── install-default-handlers! ────────────────────────────────────────

(format #t "~%=== install-default-handlers! ===~%")

(reset-handlers!)
(install-default-handlers!)

;; Peek at the handler registry
(define %handlers-after-install
  (@@ (playnet federation keria-notifications) *handlers*))

(check "multisig-rpy has a handler registered"
       (let ((h (assoc notification-route/multisig-rpy %handlers-after-install)))
         (and h (not (null? (cdr h))))))
(check "remote-sign has a handler registered"
       (let ((h (assoc notification-route/remote-sign %handlers-after-install)))
         (and h (not (null? (cdr h))))))

;;; ── Summary ─────────────────────────────────────────────────────────

(test-summary!)
