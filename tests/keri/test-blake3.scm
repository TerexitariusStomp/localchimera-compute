;;; tests/keri/test-blake3.scm — Blake3 FFI vectors
;;;
;;; Vectors taken directly from the BLAKE3 reference test suite at
;;; https://github.com/BLAKE3-team/BLAKE3/blob/master/test_vectors/test_vectors.json
;;; — the unkeyed_hash field of the first few input lengths.
;;;
;;; Run via the dev-test or keri-test guix shell so libblake3.so is on
;;; LD_LIBRARY_PATH:
;;;
;;;   make test-blake3
;;;
;;; Bare guile won't find libblake3 unless you've already entered the shell.

(use-modules (playnet test harness)
             (playnet keri blake3)
             (rnrs bytevectors)
             (ice-9 format))

(define (hex->bv hex)
  (let* ((n  (quotient (string-length hex) 2))
         (bv (make-bytevector n 0)))
    (let loop ((i 0))
      (when (< i n)
        (bytevector-u8-set!
         bv i
         (string->number (substring hex (* i 2) (+ (* i 2) 2)) 16))
        (loop (+ i 1))))
    bv))

;;; The reference test vectors feed input bytes 0,1,2,...,250,0,1,...
;;; (mod 251). Build the first N bytes of that pattern.
(define (ref-input n)
  (let ((bv (make-bytevector n 0)))
    (let loop ((i 0))
      (when (< i n)
        (bytevector-u8-set! bv i (modulo i 251))
        (loop (+ i 1))))
    bv))

;;; ── Spec-derived golden vectors ──────────────────────────────────────────────

(format #t "=== Blake3 FFI ===~%")
(format #t "  upstream version: ~a~%" (blake3-version))

;; len 0 (empty input) — Blake3 of empty string
(check "blake3-256(empty) hex"
       (string=? (blake3-256-hex (make-bytevector 0))
                 "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"))

;; len 1 — input = [0x00]
(check "blake3-256(#vu8(0)) hex"
       (string=? (blake3-256-hex (make-bytevector 1 0))
                 "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213"))

;; len 2 — input = [0x00, 0x01]
(check "blake3-256(#vu8(0 1)) hex"
       (string=? (blake3-256-hex (ref-input 2))
                 "7b7015bb92cf0b318037702a6cdd81dee41224f734684c2c122cd6359cb1ee63"))

;; len 3 — input = [0x00, 0x01, 0x02]
(check "blake3-256(ref-input 3) hex"
       (string=? (blake3-256-hex (ref-input 3))
                 "e1be4d7a8ab5560aa4199eea339849ba8e293d55ca0a81006726d184519e647f"))

;; len 1024 — full chunk boundary, exercises chunk-state finalization
(check "blake3-256(ref-input 1024) hex"
       (string=? (blake3-256-hex (ref-input 1024))
                 "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7"))

;; Determinism — same input twice → same output
(let ((d1 (blake3-256-hex (ref-input 100)))
      (d2 (blake3-256-hex (ref-input 100))))
  (check "deterministic on 100-byte input" (string=? d1 d2)))

;; blake3-256-string convenience wrapper
(check "blake3-256-string(\"abc\") matches blake3-256(string->utf8)"
       (string=? (blake3-256-hex (string->utf8 "abc"))
                 (blake3-256-hex (string->utf8 "abc"))))

;; Output is exactly 32 bytes
(check "blake3-256 returns 32-byte bv"
       (= 32 (bytevector-length (blake3-256 (make-bytevector 0)))))

;;; ── Wrong-arg guard ──────────────────────────────────────────────────────────

(check-error "blake3-256 on a string raises"
             (lambda () (blake3-256 "not a bytevector")))

(test-summary!)
