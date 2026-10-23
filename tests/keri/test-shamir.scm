;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-shamir.scm — Shamir secret sharing over GF(256)
;;;
;;; Verifies: GF(256) arithmetic, split/combine round-trip, threshold
;;; enforcement, all k-subsets, share serialization.

(use-modules (playnet test harness))
(use-modules (playnet keri signify))    ; installs the server keri-crypto backend (random-bytes ← /dev/urandom)
(use-modules (playnet crypto shamir))
(use-modules (rnrs bytevectors)
             (srfi srfi-1))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. GF(256) arithmetic
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. GF(256) arithmetic ──\n")

(check-pred "gf256-add is XOR"
            (= (gf256-add #xab #xcd) (logxor #xab #xcd)))

(check-pred "gf256-add self = 0"
            (= (gf256-add 42 42) 0))

(check-pred "gf256-mul identity"
            (= (gf256-mul 42 1) 42))

(check-pred "gf256-mul by zero"
            (= (gf256-mul 42 0) 0))

(check-pred "gf256-inv round-trip"
            (= (gf256-mul 42 (gf256-inv 42)) 1))

;; Exhaustive: a * inv(a) = 1 for all a in [1..255]
(let ((all-ok
       (let loop ((a 1) (ok #t))
         (if (> a 255) ok
             (loop (+ a 1)
                   (and ok (= 1 (gf256-mul a (gf256-inv a)))))))))
  (check-pred "gf256 a*inv(a)=1 for all a in [1..255]" all-ok))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Split / combine round-trip
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Split/combine round-trip ──\n")

(define test-bran (string->utf8 "0ABCDEFGHIJKLMNOPQRSTu"))

(let* ((shares (shamir-split test-bran 3 5))
       (reconstructed (shamir-combine (take shares 3))))
  (check-pred "3-of-5 round-trip"
              (bytevector=? test-bran reconstructed)))

(let* ((shares (shamir-split test-bran 2 3))
       (reconstructed (shamir-combine (take shares 2))))
  (check-pred "2-of-3 round-trip"
              (bytevector=? test-bran reconstructed)))

(let* ((shares (shamir-split test-bran 1 5))
       (reconstructed (shamir-combine (take shares 1))))
  (check-pred "1-of-5 (trivial) round-trip"
              (bytevector=? test-bran reconstructed)))

(let* ((shares (shamir-split test-bran 5 5))
       (reconstructed (shamir-combine shares)))
  (check-pred "5-of-5 (all required) round-trip"
              (bytevector=? test-bran reconstructed)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. All k-subsets of 3-of-5
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. All k-subsets ──\n")

(define (combinations lst k)
  "All k-element subsets of LST."
  (cond
    ((= k 0) '(()))
    ((null? lst) '())
    (else
     (append (map (lambda (c) (cons (car lst) c))
                  (combinations (cdr lst) (- k 1)))
             (combinations (cdr lst) k)))))

(let* ((shares (shamir-split test-bran 3 5))
       (subsets (combinations shares 3))
       (all-ok (every (lambda (subset)
                        (bytevector=? test-bran (shamir-combine subset)))
                      subsets)))
  (check-pred (string-append "all " (number->string (length subsets))
                             " 3-of-5 subsets reconstruct")
              all-ok))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Threshold enforcement — k-1 shares produce wrong output
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Threshold enforcement ──\n")

(let* ((shares (shamir-split test-bran 3 5))
       (too-few (take shares 2)))
  (check-pred "2 shares can't reconstruct 3-of-5"
              (catch #t
                (lambda ()
                  (shamir-combine too-few)
                  #f)
                (lambda _ #t))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Share serialization round-trip
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. Serialization ──\n")

(let* ((shares (shamir-split test-bran 2 3))
       (s1 (car shares))
       (alist (share->alist s1))
       (recovered (alist->share alist)))
  (check "share index round-trip"
         (share-index recovered) (share-index s1))
  (check "share threshold round-trip"
         (share-threshold recovered) (share-threshold s1))
  (check-pred "share data round-trip"
              (bytevector=? (share-data recovered) (share-data s1))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Single-byte secret
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 6. Edge: single byte ──\n")

(let* ((secret (make-bytevector 1 42))
       (shares (shamir-split secret 2 3))
       (reconstructed (shamir-combine (list (list-ref shares 0)
                                            (list-ref shares 2)))))
  (check-pred "single-byte 2-of-3"
              (bytevector=? secret reconstructed)))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
