;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; guile-websocket --- WebSocket client/server
;;; Copyright © 2015 David Thompson <davet@gnu.org>
;;; Copyright © 2023 Andrew Whatson <whatson@tailcall.au>
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
;; WebSocket frame abstraction.
;;
;; PLAYNET PATCH — guile-websocket 0.3.0's (web socket frame), verbatim except
;; one line in `read-data-frame`: the final-fragment branch joins
;; `(reverse (cons frame fragments))`, so a fragmented message arrives with
;; every fragment, the last one included.  Upstream 0.3.0 joins
;; `(reverse fragments)`, which omits the last fragment's bytes; the truncated
;; message fails to decode and the sender never gets a reply.
;;
;; A browser splits a large send into frames (Chromium: a first frame of 64-80
;; KB, then a continuation), so a ~100 KB request to the gateway needs this
;; line (deploy/UPSTREAM-ISSUES.md #14).
;;
;; This copy sits first on the load path (-L module) of every process that
;; reads websocket frames: the gateway, its tests and the dev loop.  Upstream
;; HEAD (2026-04-17) carries the 0.3.0 line; drop this file when a release
;; carries the fix.  tests/gateway/test-websocket-fragments.scm pins the
;; behaviour.
;;
;;; Code:

(define-module (web socket frame)
  #:use-module (rnrs bytevectors)
  #:use-module (rnrs io ports)
  #:use-module (ice-9 exceptions)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (ice-9 ports internal)
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (srfi srfi-26)
  #:export (&websocket-error
            websocket-error?

            make-frame
            frame?
            frame-final?
            frame-type
            frame-masking-key
            frame-data

            make-ping-frame
            make-pong-frame
            make-close-frame
            make-text-frame
            make-binary-frame

            continuation-frame?
            text-frame?
            binary-frame?
            close-frame?
            ping-frame?
            pong-frame?
            fragment-frame?
            first-fragment-frame?
            final-fragment-frame?
            control-frame?
            data-frame?

            frame-length
            frame-concatenate
            text-frame->string
            text-frames->string

            read-frame
            read-data-frame
            write-frame
            close-frame->status))


;;;
;;; Errors
;;;

(define-exception-type &websocket-error &error
  make-websocket-error
  websocket-error?)

(define-syntax-rule (websocket-error message args ...)
  (raise-exception
   (make-exception (make-websocket-error)
                   (make-exception-with-message message)
                   (make-exception-with-irritants (list args ...)))))

;;;
;;; WebSocket frames
;;;

(define-record-type <frame>
  (make-frame final? type masking-key data)
  frame?
  (final? frame-final?)
  (type frame-type)
  (masking-key frame-masking-key)
  (data frame-data))

(define (display-frame frame port)
  (format port "#<frame final?: ~a type: ~a masking-key: ~a length: ~d>"
          (frame-final? frame)
          (frame-type frame)
          (frame-masking-key frame)
          (frame-length frame)))

(set-record-type-printer! <frame> display-frame)

(define* (make-ping-frame bv #:optional masking-key)
  "Return a \"ping\" control frame containing the contents of the
bytevector BV, masked with MASKING-KEY.  By default, the data is
unmasked."
  (make-frame #t 'ping masking-key bv))

(define* (make-pong-frame bv #:optional masking-key)
  "Return a \"pong\" control frame containing the contents of the
bytevector BV, masked with MASKING-KEY.  By default, the data is
unmasked."
  (make-frame #t 'pong masking-key bv))

(define* (make-close-frame bv #:optional masking-key)
  "Return a \"close\" control frame containing the contents of the
bytevector BV, masked with MASKING-KEY.  By default, the data is
unmasked."
  (make-frame #t 'close masking-key bv))

(define* (make-text-frame text #:optional masking-key)
  "Return a text data frame containing the string TEXT, masked with MASKING-KEY.
By default, the text is unmasked."
  (make-frame #t 'text masking-key (string->utf8 text)))

(define* (make-binary-frame bv #:optional masking-key)
  "Return a binary data frame containing the contents of the
bytevector BV, masked with MASKING-KEY.  By default, the data is
unmasked."
  (make-frame #t 'binary masking-key bv))

(define (continuation-frame? frame)
  "Return #t if FRAME is a continuation frame."
  (eq? (frame-type frame) 'continuation))

(define (text-frame? frame)
  "Return #t if FRAME is a text frame."
  (eq? (frame-type frame) 'text))

(define (binary-frame? frame)
  "Return #t if FRAME is a binary frame."
  (eq? (frame-type frame) 'binary))

(define (close-frame? frame)
  "Return #t if FRAME is a close frame."
  (eq? (frame-type frame) 'close))

(define (ping-frame? frame)
  "Return #t if FRAME is a ping frame."
  (eq? (frame-type frame) 'ping))

(define (pong-frame? frame)
  "Return #t if FRAME is a pong frame."
  (eq? (frame-type frame) 'pong))

;; See section 5.4 - Fragmentation
(define (fragment-frame? frame)
  "Return #t if FRAME is an incomplete message."
  (or (continuation-frame? frame)
      (not (frame-final? frame))))

(define (first-fragment-frame? frame)
  "Return #t if FRAME is the first piece of a fragmented message."
  (and (not (frame-final? frame))
       (data-frame? frame)))

(define (final-fragment-frame? frame)
  "Return #t if FRAME is the final piece of a fragmented message."
  (and (frame-final? frame)
       (continuation-frame? frame)))

;; See section 5.5 - Control Frames
(define (control-frame? frame)
  "Return #t if FRAME is a control frame."
  (or (close-frame? frame)
      (ping-frame? frame)
      (pong-frame? frame)))

;; See section 5.6 - Data Frames
(define (data-frame? frame)
  "Return #t if FRAME is a data frame."
  (or (text-frame? frame)
      (binary-frame? frame)))

(define (frame-length frame)
  "Return the length of the data bytevector in FRAME."
  (bytevector-length (frame-data frame)))

(define (text-frame->string frame)
  "Convert FRAME, an unfragmented text frame, into a string."
  (utf8->string (frame-data frame)))

(define (frame-concatenate frames)
  "Concatenate the data in FRAMES, a list of fragmented frames, into a
single bytevector."
  (let ((bv (make-bytevector (reduce + 0 (map frame-length frames)))))
    (let loop ((frames frames)
               (offset 0))
      (match frames
        (() bv)
        ((frame . rest)
         (let ((length (frame-length frame)))
           (bytevector-copy! (frame-data frame) 0 bv offset length)
           (loop rest (+ offset length))))))))

(define (text-frames->string frames)
  "Convert FRAMES, a list of fragmented text frames, into a single
concatenated string."
  (utf8->string (frame-concatenate frames)))

(define (call-with-input-bytevector bv proc)
  "Call PROC with one argument: an open input port that reads from the
bytevector BV."
  (let ((port (open-bytevector-input-port bv)))
    (dynamic-wind
      (const #t)
      (lambda ()
        (proc port))
      (lambda ()
        (close-port port)))))

(define (close-frame->status frame)
  "Convert FRAME, a close frame, into a pair.  The \"car\" of the pair
is a positive integer status code, and the \"cdr\" is a string
containing the explanation, if present."
  (define (read-status-code)
    (match (bytevector-sint-ref (frame-data frame) 0 (endianness big) 2)
      ;; See section 7.4
      ((and (or 1005 1006 1015) status)
       (websocket-error "invalid use of reserved status code: " status))
      (status status)))

  (let ((length (frame-length frame)))
    (cond
     ((zero? length) ; unspecified closing status
      '(1005 . ""))
     ((= length 2) ; status code only
      (cons (read-status-code) ""))
     (else ; status + reason
      (cons (read-status-code)
            (call-with-input-bytevector (frame-data frame)
              (lambda (port)
                ;; Throw away the status code.
                (get-u8 port)
                (get-u8 port)
                ;; Now read the reason.
                (read-string port))))))))


;;;
;;; Frame reader
;;;

;; See section 5.3 - Client-to-Server Masking
(define (mask-bytevector! bv masking-key)
  "Apply the WebSocket masking algorithm to the bytevector BV using
MASKING-KEY."
  (let loop ((i 0))
    (when (< i (bytevector-length bv))
      (let ((masked (logxor (u8vector-ref bv i)
                            (u8vector-ref masking-key (modulo i 4)))))
        (u8vector-set! bv i masked)
        (loop (1+ i))))))

;; See section 5.2 - Base Framing Protocol
(define (read-frame port)
  (define (opcode->frame-type opcode)
    (match opcode
      (#x0 'continuation)
      (#x1 'text)
      (#x2 'binary)
      (#x8 'close)
      (#x9 'ping)
      (#xA 'pong)
      (else (websocket-error "invalid opcode" opcode))))
  (define (control-frame? type)
    (memq type '(close ping pong)))
  (define (parse-fin-bit octet)
    ;; Test the first bit of the octet.
    (not (zero? (logand #x80 octet))))
  (define (parse-opcode octet final?)
    ;; The opcode is stored in the least significant nibble of the
    ;; octet.
    (let ((type (opcode->frame-type (logand #x0f octet))))
      ;; Section 5.5 specifies that control frames must not be
      ;; fragmented.
      (when (and (not final?) (control-frame? type))
        (websocket-error "fragmented control frame" type))
      type))
  (define (parse-mask-bit octet)
    (not (zero? (logand #x80 octet))))
  (define (read-length octet)
    ;; For lengths <= 125, the frame length is encoded in the last 7
    ;; bits of the octet.  If this number is 126, then the true length
    ;; is encoded in the following 16 bits.  If the number is 127,
    ;; then the true length is encoded in the following 64 bits.
    (match (logand #x7f octet)
      (126
       (match (get-bytevector-n port 2)
         ((? eof-object? eof) eof)
         (bv (bytevector-u16-ref bv 0 (endianness big)))))
      (127
       (match (get-bytevector-n port 8)
         ((? eof-object? eof) eof)
         (bv (bytevector-u64-ref bv 0 (endianness big)))))
      (length length)))
  (define (read-masking-key)
    ;; Masking keys are always 32 bits.
    (get-bytevector-n port 4))
  (define (read-data type length)
    ;; Section 5.5 specifies that control frame bodies may not exceed
    ;; 125 bytes.
    (when (and (> length 125) (control-frame? type))
      (websocket-error "control frame too large" type length))
    (get-bytevector-n port length))
  (match (get-u8 port)
    ((? eof-object? eof) eof)
    (type-byte
     (let* ((final? (parse-fin-bit type-byte))
            (type (parse-opcode type-byte final?)))
       (match (get-u8 port)
         ((? eof-object? eof) eof)
         (length-byte
          (let ((mask? (parse-mask-bit length-byte)))
            (match (read-length length-byte)
              ((? eof-object? eof) eof)
              (length
               (match (and mask? (read-masking-key))
                 ((? eof-object? eof) eof)
                 (masking-key
                  (match (read-data type length)
                    ((? eof-object? eof) eof)
                    (data
                     (when masking-key (mask-bytevector! data masking-key))
                     (make-frame final? type masking-key data))))))))))))))

;; TODO: Remove echo-close? arg.  Just return the close frame and let
;; the client/server implementation DTRT from there.
(define* (read-data-frame port #:key
                          (wait-for-port (lambda (port) 'ready))
                          (max-attempts 1)
                          echo-close?)
  "Read frames from @var{port}, an input and output port such as a
socket, until a complete data frame is received, handling any control
frames transparently.  Return either a text frame, a binary frame, a
close frame, EOF if @var{port} is empty, or #f upon timeout.

By default, timeouts are unhandled and this procedure will wait
indefinitely for data from @var{port}.  When @var{port} is
suspendable, a @var{wait-for-port} procedure should be passed.  This
procedure takes one argument, a port, and should return either
@code{ready} when the port has data to read, or @code{timeout} if the
wait exceeded some maximum time limit.

Here's an example of how to handle timeouts when using Fibers for
async I/O:

@example
(lambda (port)
  (perform-operation
   (choice-operation
    (wrap-operation (wait-until-port-readable-operation port)
                    (lambda () 'ready))
    (wrap-operation (sleep-operation 30)
                    (lambda () 'timeout)))))
@end example

When a timeout occurs, a ping frame will be written to @var{port} in
an attempt to keep the connection alive, up to @var{max-attempts}
time.  By default, @var{max-attempts} is 1, meaning that the read will
fail after a single timeout.  @var{max-attempts} may be @code{#f} in
which case reads are retried indefinitely.

When @var{echo-close?} is @code{#t}, a close frame will be written to
@var{port} when a close frame is read from it.  @var{echo-close?}
should be @code{#t} if @var{port} represents the server end of a
WebSocket connection."
  (let loop ((fragments '()) (type #f) (timeouts 0))
    (cond
     ((or (not max-attempts) (< timeouts max-attempts))
      (match (wait-for-port port)
        ('ready
         (match (read-frame port)
           ((? eof-object? eof)
            (close-port port)
            eof)
           ;; Per section 5.4, control frames may appear interspersed
           ;; along with a fragmented message.
           ((? close-frame? frame)
            ;; Per section 5.5.1, echo the close frame back to
            ;; the client before closing the socket.  The
            ;; client may no longer be listening.
            (when echo-close?
              (with-exception-handler (lambda (exn) #f)
                (lambda ()
                  (write-frame (make-close-frame (frame-data frame)) port))
                #:unwind? #t))
            (close-port port)
            frame)
           ((? ping-frame? frame)
            ;; Per section 5.5.3, a pong frame must include the exact
            ;; same data as the ping frame.
            (write-frame (make-pong-frame (frame-data frame)) port)
            (loop fragments type 0))
           ((? pong-frame?) ; silently ignore pongs
            (loop fragments type 0))
           ((? first-fragment-frame? frame) ; begin accumulating fragments
            (loop (list frame) (frame-type frame) 0))
           ((? final-fragment-frame? frame) ; concatenate all fragments
            (make-frame #t type #f
                        (frame-concatenate (reverse (cons frame fragments)))))
           ((? fragment-frame? frame) ; add a fragment
            (loop (cons frame fragments) type 0))
           ((? data-frame? frame) ; unfragmented data frame
            frame)
           (frame (websocket-error "unexpected WebSocket frame" frame))))
        ;; Ping client in an attempt to keep the connection alive.
        ('timeout
         (write-frame (make-ping-frame #vu8(42 61)) port)
         (loop fragments type (1+ timeouts)))))
     (else
      (close-port port)
      #f))))


;;;
;;; Frame writer
;;;

(define* (write-frame frame #:optional (port (current-output-port)))
  ;; Packs an unsigned integer into a bytevector in network byte
  ;; order.
  (define (uint->bytevector n size)
    (uint-list->bytevector (list n) (endianness big) size))

  (define (masked-data mask data)
    (let ((bv (bytevector-copy data)))
      (mask-bytevector! bv mask)
      bv))

  (let ((length (frame-length frame))
        (mask   (frame-masking-key frame))
        (data   (frame-data frame)))
    ;; Write FIN bit and opcode.
    (put-u8 port
            (logior (if (frame-final? frame) #x80 #x00)
                    (match (frame-type frame)
                      ('continuation #x00)
                      ('text         #x01)
                      ('binary       #x02)
                      ('close        #x08)
                      ('ping         #x09)
                      ('pong         #x0A))))

    ;; Write mask bit and length.
    (put-u8 port
            (logior (if mask #x80 #x00)
                    (cond
                     ((< length 126) length)
                     ((< length (expt 2 16)) 126)
                     (else 127))))

    ;; Write true size when size is greater than 125.
    (cond
     ((< length 126) #f)
     ((< length (expt 2 16))
      (put-bytevector port (uint->bytevector length 2)))
     (else
      (put-bytevector port (uint->bytevector length 8))))

    ;; Write masking key, if present.
    (when mask (put-bytevector port mask))

    ;; Write data, potentially masked.
    (put-bytevector port (if mask (masked-data mask data) data))
    (force-output port)))
