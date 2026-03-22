;;; Patched utils.scm — replaces gnutls base64-encode with built-in.
;;; Original: Copyright © 2016 David Thompson <davet@gnu.org>
;;; License: LGPL-3.0+

(define-module (web socket utils)
  #:use-module (rnrs bytevectors)
  #:use-module (web socket sha-1)
  #:export (%handshake-guid
            make-accept-key))

(define %handshake-guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

(define *b64* "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(define (base64-encode bv)
  (let ((len (bytevector-length bv))
        (out (open-output-string)))
    (let loop ((i 0))
      (when (< i len)
        (let ((b0 (bytevector-u8-ref bv i))
              (b1 (if (< (+ i 1) len) (bytevector-u8-ref bv (+ i 1)) 0))
              (b2 (if (< (+ i 2) len) (bytevector-u8-ref bv (+ i 2)) 0))
              (remain (- len i)))
          (display (string-ref *b64* (ash b0 -2)) out)
          (display (string-ref *b64* (logior (ash (logand b0 3) 4) (ash b1 -4))) out)
          (if (> remain 1)
              (display (string-ref *b64* (logior (ash (logand b1 15) 2) (ash b2 -6))) out)
              (display "=" out))
          (if (> remain 2)
              (display (string-ref *b64* (logand b2 63)) out)
              (display "=" out))
          (loop (+ i 3)))))
    (get-output-string out)))

(define (make-accept-key client-key)
  (base64-encode
   (sha-1->bytevector
    (sha-1
     (string->utf8
      (string-append client-key %handshake-guid))))))
