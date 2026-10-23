;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/gateway/http-door-server.scm — the HTTP door's listener
;;;
;;; Runs (playnet doors http)'s handler on a loopback port inside the
;;; gateway process, where the lobby lives; nginx proxies /api/lobby/,
;;; /api/session/ and /api/planner/ to it (deploy/os.scm). The handler runs
;;; on the listener's own thread; every touch of a Goblins object goes
;;; through the gateway vat, and a promise reply is settled here before the
;;; response is written, bounded by %reply-wait.
;;;
;;; Targets:
;;;   lobby    the lobby itself
;;;   planner  what the lobby's (planner) door hands out — the facet
;;;   session  the person's session at tier device, spawned once per person
;;;            by the constructor the gateway supplies and kept for
;;;            %session-ttl seconds of quiet; the same object a CapTP device
;;;            login would receive.

;;; Everything here runs as fibers on the vat scheduler: the accept loop, each
;;; connection, and the wait for a door's reply. A send from a fiber to a vat
;;; on the same scheduler is the path the OCapN netlayer takes for the dial;
;;; a send from a plain thread reaches an idle scheduler only when its poll
;;; wakes, measured at 0.4–1.7 s per call (2026-09-13). So no thread and no
;;; polling: a reply is a message on a channel, waited for with a timeout.

(define-module (playnet gateway http-door-server)
  #:use-module (playnet doors http)
  #:use-module ((playnet doors mcp) #:select (%mcp-path handle-mcp-request))
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))
  #:use-module (goblins)
  #:use-module (goblins vat)
  #:use-module ((goblins default-vat-scheduler) #:select (default-vat-scheduler))
  #:use-module (fibers)
  #:use-module (fibers channels)
  #:use-module (fibers operations)
  #:use-module (fibers timers)
  #:use-module (web request)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (ice-9 exceptions)
  #:use-module (srfi srfi-1)
  #:export (start-http-door! %reply-wait %session-ttl))

(define %reply-wait 15)        ; seconds a door reply may take
(define %session-ttl 600)      ; seconds a person's HTTP session stays warm

(define (error-text e)
  "One line for a rejection: the message and irritants when it is an
exception, its printed form otherwise."
  (catch #t
    (lambda ()
      (if (exception? e)
          (format #f "~a~a" (or (exception-message e) "error")
                  (let ((irr (exception-irritants e)))
                    (if (null? irr) "" (format #f ": ~s" irr))))
          (format #f "~a" e)))
    (lambda _ (format #f "~a" e))))

(define (settle vat send)
  "From a fiber: run SEND inside VAT — it returns a promise — hook it in the
same turn, and receive its outcome on a channel; (error …) on rejection or
after %reply-wait."
  (let ((ch (make-channel)))
    (with-vat vat
      ;; a handler's value is a turn's value: put-message yields none, so
      ;; each returns #t after the put
      (on (send)
          (lambda (v) (put-message ch (list 'value v)) #t)
          #:catch (lambda (e) (put-message ch (list 'error (error-text e))) #t)))
    (match (perform-operation
            (choice-operation (get-operation ch)
                              (wrap-operation (sleep-operation %reply-wait)
                                              (lambda () '(timeout)))))
      (('value v) v)
      (('error e) (list 'error e))
      (_ (list 'error "the door did not answer in time")))))

;; ── the listener, as fibers ──────────────────────────────────────────────

(define (nonblocking! port)
  (fcntl port F_SETFL (logior O_NONBLOCK (fcntl port F_GETFL)))
  port)

(define (serve-client client handler log)
  "One connection: read the request, answer it, close. Errors close it."
  (catch #t
    (lambda ()
      (let* ((request (read-request client))
             (body (read-request-body request)))
        (call-with-values (lambda () (handler request body))
          (lambda (response body-string)
            (let ((response (write-response response client)))
              (write-response-body response (string->utf8 body-string))
              (force-output client))))))
    (lambda (k . args)
      (log "  [http-door] connection dropped: ~a ~s~%" k args)))
  (false-if-exception (close-port client)))

(define (serve port handler log)
  "Accept forever on loopback PORT; each connection is its own fiber."
  (let ((sock (nonblocking! (socket PF_INET SOCK_STREAM 0))))
    (setsockopt sock SOL_SOCKET SO_REUSEADDR 1)
    (bind sock AF_INET INADDR_LOOPBACK port)
    (listen sock 128)
    (let loop ()
      ;; Guile's accept suspends this fiber until a connection is pending
      ;; (the read waiter fibers installs), the way fibers' own web server
      ;; loops; the flags make the client port non-blocking from birth
      (match (accept sock (logior SOCK_NONBLOCK SOCK_CLOEXEC))
        ((client . _)
         (spawn-fiber (lambda () (serve-client client handler log))))
        (_ #f))
      (loop))))

(define* (start-http-door! #:key port lobby vat spawn-session (log (lambda args #t)))
  "Serve the door on loopback PORT as fibers on the vat scheduler. VAT is the
gateway vat, where a person's session is spawned (SPAWN-SESSION:
(person-aid) → a device-tier session)."
  (define door-vat (spawn-vat #:name "http-door"))
  (define sessions '())          ; ((person-aid session . last-used) …)
  (define planner-facet #f)
  (define (session-for person)
    (let ((now (instant->unix (clock-now))))
      (set! sessions (filter (lambda (e) (< (- now (cddr e)) %session-ttl)) sessions))
      (let ((hit (assoc person sessions)))
        (if hit
            (begin (set-cdr! (cdr hit) now) (cadr hit))
            (let ((s (with-vat vat (spawn-session person))))
              (set! sessions (cons (cons person (cons s now)) sessions))
              s)))))
  (define (target object person)
    (case object
      ((lobby) lobby)
      ((planner)
       (or planner-facet
           (let ((f (settle door-vat (lambda () (<- lobby 'planner)))))
             (and (not (and (pair? f) (eq? (car f) 'error)))
                  (begin (set! planner-facet f) f)))))
      ((session) (and person (session-for person)))
      (else #f)))
  (define (call ref name args)
    (settle door-vat (lambda () (apply <- ref name args))))
  (define (handler request body)
    (log "  [http-door] ~a ~a~%" (request-method request) (uri-path (request-uri request)))
    (catch #t
      (lambda ()
        (if (string=? (uri-path (request-uri request)) %mcp-path)
            (handle-mcp-request request body #:target target #:call call)
            (handle-door-request request body #:target target #:call call)))
      (lambda (k . a)
        (log "  [http-door] handler error: ~a ~s~%" k a)
        (values (build-response #:code 500 #:headers '((content-type . (application/json))))
                "{\"error\":\"door failed\"}\n"))))
  (spawn-fiber
   (lambda ()
     (catch #t
       (lambda () (serve port handler log))
       (lambda (k . a) (log "  [http-door] listener stopped: ~a ~s~%" k a))))
   (default-vat-scheduler))
  (log "  [gateway] HTTP door on http://127.0.0.1:~a/api/<object>/<name>, MCP at ~a~%" port %mcp-path))
