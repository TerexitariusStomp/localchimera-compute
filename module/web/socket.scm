;;; guile-websocket --- WebSocket client/server
;;; Copyright © 2026 David Thompson <dave@spritely.institute>
;;;
;;; This file is part of guile-websocket.
;;;
;;; Guile-websocket is free software; you can redistribute it and/or modify
;;; it under the terms of the GNU Lesser General Public License as
;;; published by the Free Software Foundation; either version 3 of the
;;; License, or (at your option) any later version.
;;;
;;; Guile-websocket is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; Lesser General Public License for more details.
;;;
;;; You should have received a copy of the GNU Lesser General Public
;;; License along with guile-websocket.  If not, see
;;; <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; WebSockets as ports.
;;
;; PLAYNET PATCH — guile-websocket 0.3.0's (web socket) with upstream commit
;; 58c8708 ("Default to only masking client sockets", 2026-04-11, after the
;; 0.3.0 release) applied: `wrap-websocket` masks the frames it sends only when
;; it wraps the client end, as RFC 6455 requires.  0.3.0 masks every frame, and
;; a browser closes a connection whose server masks ("A server must not mask
;; any frames that it sends to the client"); (hoot web-server) wraps its relay
;; socket with #:server-side? #t and relies on that default, so `make
;; serve-dev`'s live REPL could not connect.  Drop this file when a
;; guile-websocket release carries the commit.
;; tests/gateway/test-websocket-masking.scm pins the behaviour.
;;
;;; Code:

(define-module (web socket)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 match)
  #:use-module (rnrs bytevectors)
  #:use-module (web socket client)
  #:export (wrap-websocket
            websocket))

(define* (wrap-websocket ws #:key
                         (entropy-port (default-entropy-port))
                         (wait-for-port (lambda (port) 'ready))
                         (max-attempts 1)
                         (server-side? #f)
                         (mask? (not server-side?)))
  "Wrap a WebSocket in a standard input/output port.

The WebSocket protocol requires a source of random bytes:
@var{entropy-port}.  By default, entropy is sourced from
@file{/dev/urandom}.

@var{wait-for-port} is a procedure that receives one argument: a
socket.  When the socket is ready for reading, the procedure should
return @code{ready}.  If waiting has exceeded some maximum duration,
the procedure should return @code{timeout} which instructs the
WebSocket client to retry reading.  If too many consecutive timeouts
occur then the read will fail.  By default, no timeout logic is
implemented and @var{wait-for-port} always returns @code{ready}.

@var{max-attempts} specifies how many times a read operation will be
attempted before failing.  By default, only one attempt will be made
(i.e., there will be zero retries).

If @var{ws} is a server-side client socket, then @var{server-side?}
should be set to @code{#t}.

@var{mask?} is an optional flag that specifies whether sent messages
will be bitmasked or not.  By default, messages sent by clients are
masked and messages sent by servers are not.  This default is
sufficient for communicating with other specification compliant
WebSocket implementations.
"
  (define done? #f)
  (define pos 0)
  (define chunk #f)
  (define chunk-len 0)
  (define should-mask (if (nil? mask?) (not server-side?) mask?))
  (define (read dst start count)
    (if (eq? pos chunk-len)
        (if done?
            0
            (match (websocket-receive
                    ws
                    #:wait-for-port wait-for-port
                    #:max-attempts max-attempts
                    #:echo-close? server-side?)
              ((? bytevector? next)
               (set! chunk next)
               (set! chunk-len (bytevector-length next))
               (set! pos 0)
               (read dst start count))
              ((? string? next)
               (set! chunk (string->utf8 next))
               (set! chunk-len (bytevector-length chunk))
               (set! pos 0)
               (read dst start count))
              (_
               (set! done? #t)
               (set! pos 0)
               (set! chunk 0)
               (set! chunk-len 0)
               0)))
        (let ((len (min count (- chunk-len pos))))
          (bytevector-copy! chunk pos dst start len)
          (set! pos (+ pos len))
          len)))
  (define (write src start count)
    (unless (zero? count)
      (let ((chunk (make-bytevector count)))
        (bytevector-copy! src start chunk 0 count)
        (websocket-send ws chunk
                        #:mask? mask?
                        #:entropy-port entropy-port)
        count)))
  (define (close)
    (close-websocket ws
                     #:wait-for-port wait-for-port
                     #:server-side? server-side?))
  (make-custom-binary-input/output-port "WebSocket" read write #f #f close))

(define* (websocket url #:key
                    (mask? #t)
                    (flags SOCK_CLOEXEC)
                    (entropy-port (default-entropy-port))
                    (verify-certificate? #t)
                    (wait-for-port (lambda (port) 'ready))
                    (max-attempts 1))
  "Open a WebSocket connection to @var{url}, either a URI object or a
string, and return an open input/output port.

All of the remaining arguments are optional and generally don't need
to be changed from their defaults.  If you'd like to do asynchronous
I/O, though, then keep reading.

@var{mask?} is a boolean flag that specifies whether sent messages will
be bitmasked or not.  By default, masking is enabled.

@var{flags} specifies the socket flags to be set.  By default, only
@code{SOCK_CLOEXEC} is set.

The WebSocket protocol requires a source of random bytes:
@var{entropy-port}.  By default, entropy is sourced from
@file{/dev/urandom}.

When @var{verify-certificate?} is @code{#t} (the default),
@code{wss://} connections will have their TLS certificates verified.

@var{wait-for-port} is a procedure that receives one argument: a
socket.  When the socket is ready for reading, the procedure should
return @code{ready}.  If waiting has exceeded some maximum duration,
the procedure should return @code{timeout} which instructs the
WebSocket client to retry reading.  If too many consecutive timeouts
occur then the read will fail.  By default, no timeout logic is
implemented and @var{wait-for-port} always returns @code{ready}.

@var{max-attempts} specifies how many times a read operation will be
attempted before failing.  By default, only one attempt will be made
(i.e., there will be zero retries).

By default, read and write are blocking operations.  For asynchronous
I/O with fibers, @var{flags} and @var{wait-for-port} must be changed
from their defaults.  For @var{flags}, include the
@code{SOCK_NONBLOCK} flag, e.g., @code{(logior SOCK_CLOEXEC
SOCK_NONBLOCK)}.  For @var{wait-for-port}, use something like this:

@example
(use-modules (fibers operations) (fibers io-wakeup) (fibers timers))

(define (wait-for-port port)
  (perform-operation
   (choice-operation
    (wrap-operation (wait-until-port-readable-operation port)
                    (lambda () 'ready))
    (wrap-operation (sleep-operation 30)
                    (lambda () 'timeout)))))
@end example
"
  (define ws
    (open-websocket-for-uri
     url
     #:flags flags
     #:entropy-port entropy-port
     #:verify-certificate? verify-certificate?))
  (wrap-websocket ws
                  #:mask? mask?
                  #:entropy-port entropy-port
                  #:wait-for-port wait-for-port
                  #:max-attempts max-attempts))
