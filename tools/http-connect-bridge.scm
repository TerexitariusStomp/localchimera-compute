#!/usr/bin/env -S guile --no-auto-compile
!#
;;; tools/http-connect-bridge.scm
;;;
;;; HTTP CONNECT → SOCKS5 bridge. Lets guix-daemon's substitute
;;; fetcher (HTTP CONNECT only) reach the network through Tor's SOCKS5
;;; port while we bootstrap the proper torrc HTTPTunnelPort via
;;; reconfigure. After the persistent config lands, kill this and
;;; guix-daemon talks straight to Tor's native HTTP tunnel.
;;;
;;; Env:
;;;   LISTEN_PORT  default 9080
;;;   SOCKS_HOST   default 127.0.0.1
;;;   SOCKS_PORT   default 9050
;;;
;;; Run:
;;;   guile --no-auto-compile tools/http-connect-bridge.scm &
;;;   herd set-http-proxy guix-daemon http://127.0.0.1:9080
;;;
;;; Leans on what Guile already ships: (web request) reads + parses the
;;; CONNECT line; dump-port pipes bytes; (ice-9 match) destructures
;;; SOCKS5 replies; call-with-new-thread fans out per connection.

(use-modules ((ice-9 threads)      #:select (call-with-new-thread join-thread))
             ((web request)        #:select (read-request request-method
                                             request-uri))
             ((web uri)            #:select (uri->string))
             ((ice-9 binary-ports) #:select (put-bytevector get-bytevector-n
                                             get-bytevector-some))
             ((ice-9 match)        #:select (match))
             ((ice-9 format)       #:select (format))
             ((srfi srfi-11)       #:select (let*-values))
             ((rnrs bytevectors)   #:select (u8-list->bytevector
                                             bytevector-length
                                             bytevector-u8-ref
                                             bytevector-copy!
                                             make-bytevector
                                             string->utf8)))

(define (bv-append . bvs)
  "(rnrs bytevectors) ships `bytevector-append` in R6RS but Guile
   doesn't re-export it; small inline replacement."
  (let* ((total (apply + (map bytevector-length bvs)))
         (out   (make-bytevector total)))
    (let loop ((bvs bvs) (off 0))
      (if (null? bvs) out
          (let ((b (car bvs)))
            (bytevector-copy! b 0 out off (bytevector-length b))
            (loop (cdr bvs) (+ off (bytevector-length b))))))))

(define %listen-port (string->number (or (getenv "LISTEN_PORT") "9080")))
(define %socks-host  (or (getenv "SOCKS_HOST") "127.0.0.1"))
(define %socks-port  (string->number (or (getenv "SOCKS_PORT") "9050")))

(define (log-msg fmt . args)
  (apply format (current-error-port)
         (string-append "[bridge ~a] " fmt "~%")
         (strftime "%H:%M:%S" (localtime (current-time)))
         args)
  (force-output (current-error-port)))

;;; ── SOCKS5 client (RFC 1928 §3, §4) ───────────────────────────────────────

(define (port->u8x2 port)
  (u8-list->bytevector
   (list (logand (ash port -8) #xff) (logand port #xff))))

(define (socks5-connect host port)
  "Open a TCP tunnel to HOST:PORT through Tor SOCKS5. Returns a socket
   port with both halves piped to the destination."
  (let ((sock (socket AF_INET SOCK_STREAM 0)))
    (connect sock (make-socket-address AF_INET
                                       (inet-pton AF_INET %socks-host)
                                       %socks-port))
    ;; Method negotiation: ver=5, 1 method, NO_AUTH(0).
    (put-bytevector sock #vu8(5 1 0))
    (force-output sock)
    (match (bytevector->u8-list (get-bytevector-n sock 2))
      ((5 0) #t)
      (other (close-port sock)
             (error "SOCKS5 method negotiation rejected" other)))
    ;; CONNECT with domain ATYP — let Tor resolve.
    (let ((host-bv (string->utf8 host)))
      (put-bytevector sock
        (bv-append
          (u8-list->bytevector
           (list 5 1 0 3 (bytevector-length host-bv)))
          host-bv
          (port->u8x2 port))))
    (force-output sock)
    ;; Reply: ver, rep, rsv, atyp, then bnd-addr (variable) + bnd-port.
    (match (bytevector->u8-list (get-bytevector-n sock 4))
      ((5 0 _ atyp)
       (get-bytevector-n sock                ; drain bind-addr + port
                         (case atyp
                           ((1) 6)                                  ; IPv4 + port
                           ((4) 18)                                 ; IPv6 + port
                           ((3) (let* ((b (get-bytevector-n sock 1))
                                       (l (bytevector-u8-ref b 0)))
                                  (+ l 2))))) ; domain + port
       sock)
      ((5 rep . _) (close-port sock)
                   (error "SOCKS5 CONNECT rejected, REP" rep))
      (other       (close-port sock)
                   (error "SOCKS5 short reply" other)))))

(define (bytevector->u8-list bv)
  (let loop ((i 0) (acc '()))
    (if (= i (bytevector-length bv))
        (reverse acc)
        (loop (+ i 1) (cons (bytevector-u8-ref bv i) acc)))))

;;; ── HTTP CONNECT handling ────────────────────────────────────────────────
;;; `read-request` parses the request line, version, and all headers and
;;; leaves the port positioned right after the blank line — exactly what
;;; we want before flipping into raw tunnel mode.

(define (parse-authority target)
  "Split `host:port` (CONNECT's request-target form, not a full URI).
   Returns (values host port-int)."
  (let ((col (string-rindex target #\:)))
    (unless col (error "CONNECT target missing port" target))
    (values (substring target 0 col)
            (or (string->number (substring target (+ col 1)))
                (error "CONNECT target port not numeric" target)))))

(define (handle-connect req client)
  ;; (request-uri req) on a CONNECT request returns a URI record whose
  ;; printed form is the original `host:port` authority — uri-host /
  ;; uri-port are #f because the parser treats it as a relative ref.
  ;; Round-tripping through uri->string + manual split is the cleanest.
  (let*-values (((host port) (parse-authority (uri->string (request-uri req)))))
    (log-msg "CONNECT ~a:~a" host port)
    (let ((upstream (socks5-connect host port)))
      (dynamic-wind
        (const #t)
        (lambda ()
          (put-bytevector client
            (string->utf8 "HTTP/1.1 200 Connection Established\r\n\r\n"))
          (force-output client)
          (pipe-bidirectional client upstream))
        (lambda ()
          (close-quiet upstream)
          (close-quiet client)
          (log-msg "closed ~a:~a" host port))))))

;;; ── Bidirectional byte pump ──────────────────────────────────────────────
;;; dump-port copies until EOF using an internal buffer. One thread per
;;; direction; whichever side closes first cascades the close via
;;; dynamic-wind.

(define (relay src dst)
  (catch #t
    (lambda ()
      (let loop ()
        (let ((chunk (get-bytevector-some src)))
          (unless (eof-object? chunk)
            (put-bytevector dst chunk)
            (force-output dst)
            (loop)))))
    (lambda _ #f)))

(define (pipe-bidirectional a b)
  (let ((t (call-with-new-thread (lambda () (relay a b) (close-quiet b)))))
    (relay b a)
    (close-quiet a)
    (join-thread t)))

(define (close-quiet port)
  (false-if-exception (close-port port)))

;;; ── Listener loop ────────────────────────────────────────────────────────

(define (handle-client client)
  (catch #t
    (lambda ()
      (let ((req (read-request client)))
        (case (request-method req)
          ((CONNECT) (handle-connect req client))
          (else
           (put-bytevector client
             (string->utf8 "HTTP/1.1 405 Method Not Allowed\r\n\r\n"))
           (close-quiet client)))))
    (lambda args
      (log-msg "client error: ~s" args)
      (close-quiet client))))

(define (main)
  (let ((sock (socket AF_INET SOCK_STREAM 0)))
    (setsockopt sock SOL_SOCKET SO_REUSEADDR 1)
    (bind sock (make-socket-address AF_INET INADDR_LOOPBACK %listen-port))
    (listen sock 32)
    (log-msg "listening on 127.0.0.1:~a → socks5://~a:~a"
             %listen-port %socks-host %socks-port)
    (let loop ()
      (let ((client (car (accept sock))))
        (call-with-new-thread (lambda () (handle-client client)))
        (loop)))))

(main)
