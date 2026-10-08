;;; Patched server.scm — gnutls removed (TLS handled by reverse proxy).
;;; Original: Copyright © 2015, 2025 David Thompson <dthompson2@worcester.edu>
;;; License: LGPL-3.0+

(define-module (web socket server)
  #:use-module (ice-9 match)
  #:use-module (rnrs bytevectors)
  #:use-module (rnrs io ports)
  #:use-module (web request)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (web socket frame)
  #:use-module (web socket utils)
  #:export (websocket-upgrade-request?
            websocket-upgrade-response?
            make-websocket-upgrade-response
            make-server-socket
            run-websocket-server))

(define* (make-server-socket #:key
                             (host #f)
                             (family AF_INET)
                             (addr (if host (inet-pton family host) INADDR_LOOPBACK))
                             (port 8080))
  (let ((sock (socket PF_INET SOCK_STREAM 0)))
    (setsockopt sock SOL_SOCKET SO_REUSEADDR 1)
    (fcntl sock F_SETFD FD_CLOEXEC)
    (bind sock AF_INET addr port)
    sock))

(define (accept-client server-sock)
  (match (accept server-sock O_CLOEXEC)
    ((client-sock . _)
     client-sock)))

(define (websocket-upgrade-request? request)
  (let ((headers (request-headers request)))
    (and (eq? (request-method request) 'GET)
         (assq-ref headers 'host)
         (match (assq-ref headers 'upgrade)
           ((upgrade)
            (string-ci=? upgrade "websocket"))
           (_ #f))
         (memq 'upgrade (assq-ref headers 'connection))
         (assq-ref headers 'sec-websocket-key)
         (string=? (assq-ref headers 'sec-websocket-version) "13"))))

(define (make-websocket-upgrade-response request)
  (let* ((client-key (assoc-ref (request-headers request) 'sec-websocket-key))
         (accept-key (make-accept-key (string-trim-both client-key))))
    (build-response #:code 101
                    #:headers `((upgrade . ("websocket"))
                                (connection . (upgrade))
                                (sec-websocket-accept . ,accept-key)))))

(define (websocket-upgrade-response? response)
  (and (= (response-code response) 101)
       (let ((headers (response-headers response)))
         (and (equal? (assq-ref headers 'upgrade) '("websocket"))
              (equal? (assq-ref headers 'connection) '(upgrade))))))

(define* (run-websocket-server handle-client #:key
                               (server-socket (make-server-socket))
                               (max-clients 1)
                               (accept-client accept-client)
                               (spawn-client (lambda (thunk) (thunk)))
                               tls-private-key tls-certificate)
  ;; tls-private-key / tls-certificate are accepted for ABI compatibility
  ;; with upstream guile-websocket, but ignored — TLS terminates at nginx.
  (define (serve-client client)
    ;; Guard the handshake: port scanners, health probes, and clients
    ;; that hang up mid-headers make read-request raise ("Bad
    ;; Read-Header-Line header: #<eof>"), which otherwise escapes as a
    ;; full backtrace in the gateway log on every deploy/probe. Drop
    ;; the connection quietly; real upgrade requests are unaffected.
    (define request
      (catch #t
        (lambda () (read-request client))
        (lambda _ #f)))
    (cond
     ((not request)
      (catch #t (lambda () (close-port client)) (lambda _ #f)))
     ((websocket-upgrade-request? request)
      (let ((response (make-websocket-upgrade-response request)))
        (write-response response client)
        (force-output client)
        (handle-client client)))
     (else
      (let ((response (build-response #:code 400)))
        (write-response response client)
        (close-port client)))))
  (listen server-socket max-clients)
  (sigaction SIGPIPE SIG_IGN)
  (let loop ()
    (match (accept-client server-socket)
      (#f (values))
      (#t (loop))
      (client
       (setsockopt client IPPROTO_TCP TCP_NODELAY 1)
       (setvbuf client 'block 1024)
       (spawn-client (lambda () (serve-client client)))
       (loop)))))
