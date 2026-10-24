;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/utils/hex.scm — bytevector ↔ hex string codec
;;;
;;; Single home for the hex encoding shared by KERI, bran custody, and
;;; recovery paths. Lowercase output; accepts either case on input.

(define-module (localchimera utils hex)
  #:use-module (rnrs bytevectors)
  #:export (bv->hex hex->bv))

(define %digits "0123456789abcdef")

(define (bv->hex bv)
  "Lowercase-hex encode a bytevector."
  (let* ((n (bytevector-length bv))
         (out (make-string (* 2 n) #\0)))
    (let loop ((i 0))
      (when (< i n)
        (let ((b (bytevector-u8-ref bv i)))
          (string-set! out (* 2 i)
                       (string-ref %digits (quotient b 16)))
          (string-set! out (+ 1 (* 2 i))
                       (string-ref %digits (modulo b 16))))
        (loop (+ i 1))))
    out))

(define (hex->bv hex)
  "Decode a hex string (any case) into a bytevector. Errors on
   odd-length input or non-hex characters."
  (let* ((n (string-length hex)))
    (when (odd? n)
      (error "hex->bv: odd-length hex string" hex))
    (let* ((out (make-bytevector (quotient n 2) 0)))
      (let loop ((i 0))
        (when (< i (quotient n 2))
          (let ((b (string->number (substring hex (* 2 i) (+ 2 (* 2 i))) 16)))
            (unless b (error "hex->bv: non-hex character" hex))
            (bytevector-u8-set! out i b))
          (loop (+ i 1))))
      out)))
