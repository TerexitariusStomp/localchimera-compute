;;; module/playnet/utils/constant-time.scm — timing-safe comparisons
;;;
;;; Guile's string=? and equal? use early-exit comparison: they return
;;; #f on the first mismatched byte. This leaks the position of the
;;; mismatch via response timing, enabling byte-by-byte reconstruction
;;; of secrets (AID prefixes, tokens, HMAC digests).
;;;
;;; These functions always process every byte. The accumulator collects
;;; XOR differences via logior — if any byte differs, the accumulator
;;; is non-zero. The final zero? check reveals the result only after
;;; all bytes are compared.
;;;
;;; Usage:
;;;   (constant-time-string=? stored-aid client-aid)
;;;   (constant-time-bytevector=? computed-hmac received-hmac)

(define-module (playnet utils constant-time)
  #:use-module (rnrs bytevectors)
  #:export (constant-time-string=?
            constant-time-bytevector=?))

(define (constant-time-string=? a b)
  "Compare two strings in constant time. Returns #t if equal.
Does NOT early-exit — always compares every byte. The length
check is NOT constant-time (lengths are not secret — an attacker
already knows the expected format length)."
  (and (= (string-length a) (string-length b))
       (zero?
        (let loop ((i 0) (acc 0))
          (if (>= i (string-length a))
              acc
              (loop (+ i 1)
                    (logior acc
                            (logxor (char->integer (string-ref a i))
                                    (char->integer (string-ref b i))))))))))

(define (constant-time-bytevector=? a b)
  "Compare two bytevectors in constant time. Returns #t if equal.
Same algorithm as constant-time-string=? but on raw bytes."
  (and (= (bytevector-length a) (bytevector-length b))
       (zero?
        (let loop ((i 0) (acc 0))
          (if (>= i (bytevector-length a))
              acc
              (loop (+ i 1)
                    (logior acc
                            (logxor (bytevector-u8-ref a i)
                                    (bytevector-u8-ref b i)))))))))
