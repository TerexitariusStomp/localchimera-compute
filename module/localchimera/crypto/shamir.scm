;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/crypto/shamir.scm — Shamir's Secret Sharing over GF(256)
;;;
;;; k-of-n threshold secret sharing. Each byte of the secret is split
;;; independently using a random polynomial of degree k-1 evaluated at
;;; points x=1..n in GF(2^8). Reconstruction uses Lagrange interpolation
;;; at x=0. Any k shares suffice; fewer than k reveal nothing.
;;;
;;; GF(256) uses the AES irreducible polynomial x^8+x^4+x^3+x+1 (0x11B).
;;; Multiplication via precomputed log/exp tables (256 entries each).

(define-module (localchimera crypto shamir)
  #:use-module (srfi srfi-1)
  #:use-module (rnrs bytevectors)
  #:use-module ((localchimera keri crypto-primitives)
                #:select (keri-crypto-random-bytes))
  #:export (;; GF(256) primitives (exported for testing)
            gf256-add gf256-mul gf256-inv

            ;; Core operations
            shamir-split
            shamir-combine

            ;; Share serialization
            share-index share-data share-threshold
            share->alist alist->share))


;; =========================================================================
;; GF(256) arithmetic — AES polynomial 0x11B
;; =========================================================================

;; The tables are built INSIDE one procedure each, every write completing
;; before the value escapes. That is what makes them safe under every
;; compiler this module meets:
;;
;;   - Guile's optimizer constant-folds a bare (make-bytevector n 0) into an
;;     IMMUTABLE literal, so top-level bytevector-u8-set!s against it die
;;     with "expecting mutable bytevector" — but only once a .go exists, so
;;     it presents as a stale-cache ghost. It took the gateway down at load
;;     time. An earlier (bytevector-copy (make-bytevector …)) guard beat
;;     Guile's folder;
;;   - Hoot's folder is stronger and folded the COPY too, which took the
;;     day dial down at boot (2026-08-25) the moment the browser vat
;;     imported this module.
;;
;; With the fills inside the builder, folding is HARMLESS: a compiler that
;; evaluates the whole builder at compile time embeds the finished table,
;; and nothing mutates a table after it escapes. u8-list->bytevector is
;; avoided for Hoot's sake (its rnrs shim leaves it unbound).
(define (build-gf256-tables)
  "Return (values exp-table log-table) for GF(256), AES polynomial 0x11B.
   Generator g=3 is primitive (order 255); x*3 = (x*2) XOR x. Loop
   i=0..254 to avoid overwriting log[1]. exp[255..509] mirrors
   exp[0..254] for mod-free multiplication."
  (let ((exp-t (make-bytevector 512 0))
        (log-t (make-bytevector 256 0)))
    (let loop ((i 0) (x 1))
      (when (< i 255)
        (bytevector-u8-set! exp-t i x)
        (bytevector-u8-set! log-t x i)
        (let* ((x2 (logxor (ash x 1) (if (>= x 128) #x1b 0)))
               (x3 (logxor (logand x2 #xff) x)))
          (loop (+ i 1) (logand x3 #xff)))))
    (let loop ((i 255))
      (when (< i 510)
        (bytevector-u8-set! exp-t i (bytevector-u8-ref exp-t (- i 255)))
        (loop (+ i 1))))
    (values exp-t log-t)))

(define-values (*gf256-exp* *gf256-log*) (build-gf256-tables))

(define (gf256-add a b) (logxor a b))

(define (gf256-mul a b)
  (if (or (= a 0) (= b 0)) 0
      (bytevector-u8-ref *gf256-exp*
                         (+ (bytevector-u8-ref *gf256-log* a)
                            (bytevector-u8-ref *gf256-log* b)))))

(define (gf256-inv a)
  (if (= a 0) (error "gf256-inv: division by zero")
      (bytevector-u8-ref *gf256-exp*
                         (- 255 (bytevector-u8-ref *gf256-log* a)))))

(define (gf256-div a b) (gf256-mul a (gf256-inv b)))


;; =========================================================================
;; Polynomial evaluation in GF(256)
;; =========================================================================

(define (eval-poly coeffs x)
  "Evaluate polynomial with COEFFS (constant term first) at point X in GF(256)."
  (let loop ((cs (reverse coeffs)) (acc 0))
    (if (null? cs) acc
        (loop (cdr cs) (gf256-add (gf256-mul acc x) (car cs))))))


;; =========================================================================
;; Random bytes — delegates to the keri-crypto backend (server: /dev/urandom,
;; browser: crypto.getRandomValues) so this module works in both Guile and Hoot.
;; =========================================================================

(define random-bytes keri-crypto-random-bytes)


;; =========================================================================
;; Shamir split / combine
;; =========================================================================

(define (shamir-split secret-bv k n)
  "Split SECRET-BV into N shares with threshold K.
   Returns a list of (index threshold . share-bytevector) triples,
   where index is in [1..N]."
  (when (< k 1)   (error "shamir-split: k must be >= 1" k))
  (when (< n k)   (error "shamir-split: n must be >= k" n k))
  (when (> n 255) (error "shamir-split: n must be <= 255" n))
  (let* ((len (bytevector-length secret-bv))
         (shares (map (lambda (i) (make-bytevector len 0)) (iota n))))
    (let byte-loop ((pos 0))
      (when (< pos len)
        (let* ((secret-byte (bytevector-u8-ref secret-bv pos))
               (rand (random-bytes (- k 1)))
               (coeffs (cons secret-byte
                             (map (lambda (j) (bytevector-u8-ref rand j))
                                  (iota (- k 1))))))
          (let share-loop ((i 0))
            (when (< i n)
              (let ((x (+ i 1)))
                (bytevector-u8-set! (list-ref shares i) pos
                                    (eval-poly coeffs x)))
              (share-loop (+ i 1)))))
        (byte-loop (+ pos 1))))
    (map (lambda (i bv) (list (+ i 1) k bv))
         (iota n) shares)))

(define (shamir-combine shares)
  "Reconstruct a secret from SHARES (list of (index threshold . share-bv)).
   The number of shares provided must be >= threshold."
  (when (null? shares) (error "shamir-combine: no shares"))
  (let* ((k (cadr (car shares)))
         (len (bytevector-length (caddr (car shares))))
         (result (make-bytevector len 0))
         (xs (map car shares))
         (bvs (map caddr shares)))
    (when (< (length shares) k)
      (error "shamir-combine: need at least k shares" k (length shares)))
    (let byte-loop ((pos 0))
      (when (< pos len)
        (let ((val
               (fold
                 (lambda (i acc)
                   (let* ((xi (list-ref xs i))
                          (yi (bytevector-u8-ref (list-ref bvs i) pos))
                          (num (fold (lambda (j n)
                                       (if (= j i) n
                                           (gf256-mul n (list-ref xs j))))
                                     1 (iota (length xs))))
                          (den (fold (lambda (j d)
                                       (if (= j i) d
                                           (gf256-mul d (gf256-add xi (list-ref xs j)))))
                                     1 (iota (length xs))))
                          (lagrange (gf256-mul yi (gf256-div num den))))
                     (gf256-add acc lagrange)))
                 0 (iota (length xs)))))
          (bytevector-u8-set! result pos val))
        (byte-loop (+ pos 1))))
    result))


;; =========================================================================
;; Share accessors + serialization
;; =========================================================================

(define (share-index s) (car s))
(define (share-threshold s) (cadr s))
(define (share-data s) (caddr s))

(define (bytevector->hex bv)
  (let loop ((i 0) (acc '()))
    (if (>= i (bytevector-length bv))
        (string-concatenate (reverse acc))
        (loop (+ i 1)
              (cons (let ((b (bytevector-u8-ref bv i)))
                      (string-append
                        (if (< b 16) "0" "")
                        (number->string b 16)))
                    acc)))))

(define (hex->bytevector s)
  (let* ((len (quotient (string-length s) 2))
         (bv (make-bytevector len)))
    (let loop ((i 0))
      (when (< i len)
        (bytevector-u8-set! bv i
                            (string->number (substring s (* i 2) (+ (* i 2) 2)) 16))
        (loop (+ i 1))))
    bv))

(define (share->alist share)
  "Convert a share to an alist suitable for ACDC credential claims."
  `((share-index . ,(share-index share))
    (threshold   . ,(share-threshold share))
    (share-data  . ,(bytevector->hex (share-data share)))))

(define (alist->share alist)
  "Reconstruct a share from an alist."
  (list (assoc-ref alist 'share-index)
        (assoc-ref alist 'threshold)
        (hex->bytevector (assoc-ref alist 'share-data))))
