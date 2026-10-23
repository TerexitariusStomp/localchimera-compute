;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-websocket-masking.scm — a server never masks the frames it sends
;;;
;;; RFC 6455 §5.1: a client masks every frame it sends, a server masks none, and
;;; a browser closes the connection of a server that does ("A server must not
;;; mask any frames that it sends to the client").  guile-websocket 0.3.0's
;;; `wrap-websocket` masked both ends; (hoot web-server) wraps its REPL relay
;;; socket with #:server-side? #t and relies on the default, so the live REPL of
;;; `make serve-dev` was refused by the browser.  module/web/socket.scm carries
;;; upstream's fix (commit 58c8708); this file pins it over a real socket pair.
;;;
;;; Run: guile -L module -L tests tests/gateway/test-websocket-masking.scm

(use-modules (playnet test harness)
             (web socket)
             (web socket frame)
             (rnrs bytevectors)
             (ice-9 binary-ports)
             (srfi srfi-13))

(define (wrapped-send server-side? message)
  "Send MESSAGE through a wrapped websocket port; return the frame the peer
   reads off the wire."
  (define pair (socketpair PF_UNIX SOCK_STREAM 0))
  (define port (wrap-websocket (car pair) #:server-side? server-side?))
  (put-bytevector port message)
  (force-output port)
  (read-frame (cdr pair)))

(display "\n── the patched copy is the first on the load path ──\n")
(check "web/socket.scm is found under module/ before any installed guile-websocket"
       (let ((f (search-path %load-path "web/socket.scm")))
         (and f (string-contains f "module/web/socket.scm"))))

(define hello (string->utf8 "hello"))

(display "\n── the server end sends unmasked frames ──\n")
(let ((frame (wrapped-send #t hello)))
  (check "a server-side frame carries no masking key" (frame-masking-key frame) #f)
  (check "...and its payload arrives intact" (frame-data frame) hello))

(display "\n── the client end sends masked frames ──\n")
(let ((frame (wrapped-send #f hello)))
  (check "a client-side frame carries a masking key" (bytevector? (frame-masking-key frame)) #t)
  (check "...and its payload arrives intact (read-frame unmasks)" (frame-data frame) hello))

(test-summary!)
