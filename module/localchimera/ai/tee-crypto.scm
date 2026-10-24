;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/ai/tee-crypto.scm — pure-Guile Ethereum-style signature
;;; verification for nano-gpt TEE responses. No external libraries, no native
;;; deps (none are installed), no network — the whole check runs offline inside
;;; our own vat (and, in production, inside the SEV-SNP guest).
;;;
;;; "Ethereum-style" is ONLY a signature/address convention — there is no
;;; blockchain here. A nano-gpt TEE enclave signs each response with a secp256k1
;;; key and names itself by an Ethereum address (= last 20 bytes of the keccak256
;;; of its public key). Verifying a signature means: recover the signer's public
;;; key from (message, signature) and check its address equals the one the
;;; attestation vouches for. That needs exactly two primitives, both here:
;;;
;;;   • keccak256          — the ORIGINAL Keccak (pad byte 0x01), not SHA3-256.
;;;   • secp256k1 ecrecover — recover the pubkey from an ECDSA sig + recovery id.
;;;
;;; The public entry `tee-verify-ecdsa` matches llm.scm's #:verify-ecdsa seam
;;; (text hex-sig expected-address -> bool), so turning on client-side TEE
;;; enforcement is just: default that seam to this procedure.
;;;
;;; Correctness is pinned by tests/ai/test-tee-crypto.scm against canonical
;;; vectors (keccak256 of ""/"abc", a real web3.js personal_sign signature).

(define-module (localchimera ai tee-crypto)
  #:use-module (rnrs bytevectors)
  #:export (keccak256
            personal-hash
            ecrecover
            secp256k1-verify
            pubkey->address
            parse-signature
            tee-verify-ecdsa))

;;; ─── little byte/int helpers ───────────────────────────────────────────────
(define mask64 (- (expt 2 64) 1))

(define (bytes->uint bv)                 ; big-endian bytevector → integer
  (let loop ((i 0) (acc 0))
    (if (= i (bytevector-length bv)) acc
        (loop (+ i 1) (+ (* acc 256) (bytevector-u8-ref bv i))))))

(define (uint->32be n)                   ; integer → 32-byte big-endian
  (let ((bv (make-bytevector 32 0)))
    (let loop ((i 31) (v n))
      (if (< i 0) bv
          (begin (bytevector-u8-set! bv i (logand v #xff))
                 (loop (- i 1) (ash v -8)))))))

(define (bv-sub bv start end)
  (let ((out (make-bytevector (- end start) 0)))
    (do ((i start (+ i 1)) (j 0 (+ j 1))) ((= i end) out)
      (bytevector-u8-set! out j (bytevector-u8-ref bv i)))))

(define (bv-append a b)
  (let* ((la (bytevector-length a)) (lb (bytevector-length b))
         (out (make-bytevector (+ la lb) 0)))
    (do ((i 0 (+ i 1))) ((= i la)) (bytevector-u8-set! out i (bytevector-u8-ref a i)))
    (do ((i 0 (+ i 1))) ((= i lb)) (bytevector-u8-set! out (+ la i) (bytevector-u8-ref b i)))
    out))

(define (hex->bytes s)
  (let* ((s (if (and (>= (string-length s) 2) (string=? (substring s 0 2) "0x"))
                (substring s 2) s))
         (n (quotient (string-length s) 2))
         (out (make-bytevector n 0)))
    (do ((i 0 (+ i 1))) ((= i n) out)
      (bytevector-u8-set! out i (string->number (substring s (* i 2) (+ (* i 2) 2)) 16)))))

(define (bytes->hex bv)
  (call-with-output-string
   (lambda (p)
     (do ((i 0 (+ i 1))) ((= i (bytevector-length bv)))
       (let ((h (number->string (bytevector-u8-ref bv i) 16)))
         (when (= (string-length h) 1) (write-char #\0 p))
         (display h p))))))

;;; ─── keccak256 (Keccak-f[1600] sponge, rate 1088, pad 0x01…0x80) ───────────
(define RC
  (vector #x0000000000000001 #x0000000000008082 #x800000000000808A #x8000000080008000
          #x000000000000808B #x0000000080000001 #x8000000080008081 #x8000000000008009
          #x000000000000008A #x0000000000000088 #x0000000080008009 #x000000008000000A
          #x000000008000808B #x800000000000008B #x8000000000008089 #x8000000000008003
          #x8000000000008002 #x8000000000000080 #x000000000000800A #x800000008000000A
          #x8000000080008081 #x8000000000008080 #x0000000080000001 #x8000000080008008))
;; rotation offsets, indexed ROT[x*5 + y]  (lane index = x + 5y)
(define ROT
  (vector 0 36 3 41 18   1 44 10 45 2   62 6 43 15 61   28 55 25 21 56   27 20 39 8 14))

(define (rotl64 x n)
  (if (= n 0) x
      (logand mask64 (logior (ash x n) (ash x (- n 64))))))

(define (load64le bv off)
  (let loop ((j 7) (acc 0))
    (if (< j 0) acc
        (loop (- j 1) (+ (* acc 256) (bytevector-u8-ref bv (+ off j)))))))

(define (store64le! bv off val)
  (do ((j 0 (+ j 1)) (v val (ash v -8))) ((= j 8))
    (bytevector-u8-set! bv (+ off j) (logand v #xff))))

(define (keccak-f! A)                    ; A : mutable vector of 25 lanes
  (do ((round 0 (+ round 1))) ((= round 24))
    ;; θ
    (let ((C (make-vector 5 0)))
      (do ((x 0 (+ x 1))) ((= x 5))
        (vector-set! C x (logxor (vector-ref A x) (vector-ref A (+ x 5))
                                 (vector-ref A (+ x 10)) (vector-ref A (+ x 15))
                                 (vector-ref A (+ x 20)))))
      (do ((x 0 (+ x 1))) ((= x 5))
        (let ((D (logxor (vector-ref C (modulo (+ x 4) 5))
                         (rotl64 (vector-ref C (modulo (+ x 1) 5)) 1))))
          (do ((y 0 (+ y 1))) ((= y 5))
            (vector-set! A (+ x (* 5 y)) (logxor (vector-ref A (+ x (* 5 y))) D))))))
    ;; ρ + π
    (let ((B (make-vector 25 0)))
      (do ((x 0 (+ x 1))) ((= x 5))
        (do ((y 0 (+ y 1))) ((= y 5))
          (vector-set! B (+ y (* 5 (modulo (+ (* 2 x) (* 3 y)) 5)))
                       (rotl64 (vector-ref A (+ x (* 5 y))) (vector-ref ROT (+ (* x 5) y))))))
      ;; χ
      (do ((y 0 (+ y 1))) ((= y 5))
        (do ((x 0 (+ x 1))) ((= x 5))
          (vector-set! A (+ x (* 5 y))
                       (logxor (vector-ref B (+ x (* 5 y)))
                               (logand (logxor (vector-ref B (+ (modulo (+ x 1) 5) (* 5 y))) mask64)
                                       (vector-ref B (+ (modulo (+ x 2) 5) (* 5 y)))))))))
    ;; ι
    (vector-set! A 0 (logxor (vector-ref A 0) (vector-ref RC round)))))

(define (keccak256 msg-bv)               ; bytevector → 32-byte bytevector
  (let* ((rate 136)
         (len (bytevector-length msg-bv))
         (nblocks (+ 1 (quotient len rate)))
         (plen (* nblocks rate))
         (padded (make-bytevector plen 0))
         (A (make-vector 25 0)))
    (do ((i 0 (+ i 1))) ((= i len)) (bytevector-u8-set! padded i (bytevector-u8-ref msg-bv i)))
    (bytevector-u8-set! padded len (logior (bytevector-u8-ref padded len) #x01))
    (bytevector-u8-set! padded (- plen 1) (logior (bytevector-u8-ref padded (- plen 1)) #x80))
    (do ((blk 0 (+ blk 1))) ((= blk nblocks))
      (do ((i 0 (+ i 1))) ((= i 17))     ; 17 lanes = 136 bytes absorbed per block
        (vector-set! A i (logxor (vector-ref A i)
                                 (load64le padded (+ (* blk rate) (* i 8))))))
      (keccak-f! A))
    (let ((out (make-bytevector 32 0)))
      (do ((i 0 (+ i 1))) ((= i 4) out)  ; squeeze first 256 bits = lanes 0..3
        (store64le! out (* i 8) (vector-ref A i))))))

;;; ─── secp256k1 (affine, arbitrary-precision — Guile bignums) ───────────────
(define secp-p #xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F)
(define secp-n #xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141)
(define secp-Gx #x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798)
(define secp-Gy #x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)
(define secp-G (cons secp-Gx secp-Gy))

;; modular inverse by extended Euclid (much cheaper than Fermat here)
(define (mod-inv a m)
  (let loop ((old-r (modulo a m)) (r m) (old-s 1) (s 0))
    (if (= r 0) (modulo old-s m)
        (let ((q (quotient old-r r)))
          (loop r (- old-r (* q r)) s (- old-s (* q s)))))))

(define (mod-expt base ex m)             ; needed only for the modular sqrt
  (let loop ((b (modulo base m)) (e ex) (acc 1))
    (if (= e 0) acc
        (loop (modulo (* b b) m) (ash e -1)
              (if (odd? e) (modulo (* acc b) m) acc)))))

;; points are (x . y); the identity is #f
(define (pt-double P)
  (if (not P) #f
      (let ((x (car P)) (y (cdr P)))
        (if (= y 0) #f
            (let* ((lam (modulo (* (* 3 x x) (mod-inv (* 2 y) secp-p)) secp-p))
                   (x3 (modulo (- (* lam lam) (* 2 x)) secp-p))
                   (y3 (modulo (- (* lam (- x x3)) y) secp-p)))
              (cons x3 y3))))))

(define (pt-add P Q)
  (cond ((not P) Q) ((not Q) P)
        (else
         (let ((x1 (car P)) (y1 (cdr P)) (x2 (car Q)) (y2 (cdr Q)))
           (cond ((and (= x1 x2) (= (modulo (+ y1 y2) secp-p) 0)) #f)  ; P + (−P)
                 ((and (= x1 x2) (= y1 y2)) (pt-double P))
                 (else
                  (let* ((lam (modulo (* (- y2 y1) (mod-inv (- x2 x1) secp-p)) secp-p))
                         (x3 (modulo (- (* lam lam) x1 x2) secp-p))
                         (y3 (modulo (- (* lam (- x1 x3)) y1) secp-p)))
                    (cons x3 y3))))))))

(define (pt-mul k P)
  (let loop ((k (modulo k secp-n)) (acc #f) (base P))
    (cond ((= k 0) acc)
          (else (loop (ash k -1)
                      (if (odd? k) (pt-add acc base) acc)
                      (pt-double base))))))

;; ecrecover: message-hash int z, signature (r, s), recovery id 0..3 → pubkey or #f
(define (ecrecover z r s recid)
  (and (< 0 r secp-n) (< 0 s secp-n)
       (let ((x (+ r (if (>= recid 2) secp-n 0))))
         (and (< x secp-p)
              (let* ((y2 (modulo (+ (mod-expt x 3 secp-p) 7) secp-p))
                     (y  (mod-expt y2 (quotient (+ secp-p 1) 4) secp-p)))
                (and (= (modulo (* y y) secp-p) y2)      ; x must lie on the curve
                     (let* ((y  (if (= (logand y 1) (logand recid 1)) y (- secp-p y)))
                            (R  (cons x y))
                            (ri (mod-inv r secp-n))
                            (u1 (modulo (* (- secp-n (modulo z secp-n)) ri) secp-n))
                            (u2 (modulo (* s ri) secp-n)))
                       (pt-add (pt-mul u1 secp-G) (pt-mul u2 R)))))))))

;; standard ECDSA verify (used by the tests to cross-check a recovered key)
(define (secp256k1-verify Q z r s)
  (and Q (< 0 r secp-n) (< 0 s secp-n)
       (let* ((w  (mod-inv s secp-n))
              (u1 (modulo (* (modulo z secp-n) w) secp-n))
              (u2 (modulo (* r w) secp-n))
              (P  (pt-add (pt-mul u1 secp-G) (pt-mul u2 Q))))
         (and P (= (modulo (car P) secp-n) (modulo r secp-n))))))

;;; ─── Ethereum wrappers ─────────────────────────────────────────────────────
(define (pubkey->address Q)              ; pubkey (x . y) → "0x…" (lowercase)
  (let* ((concat (bv-append (uint->32be (car Q)) (uint->32be (cdr Q))))
         (h (keccak256 concat)))
    (string-append "0x" (bytes->hex (bv-sub h 12 32)))))

;; EIP-191 prefix: byte 0x19, then "Ethereum Signed Message:\n", then the
;; message's BYTE length as decimal. (byte 0x19 via integer->char — the literal
;; \x19; string escape mis-parses under Guile's reader.)
(define (personal-hash text)             ; personal_sign / encode_defunct → int z
  (let* ((mb (string->utf8 text))
         (prefix (string->utf8
                  (string-append (string (integer->char #x19))
                                 "Ethereum Signed Message:\n"
                                 (number->string (bytevector-length mb))))))
    (bytes->uint (keccak256 (bv-append prefix mb)))))

(define (parse-signature hex)            ; 65-byte r‖s‖v hex → (r s recid) | #f
  (let ((b (hex->bytes hex)))
    (and (= (bytevector-length b) 65)
         (let ((v (bytevector-u8-ref b 64)))
           (list (bytes->uint (bv-sub b 0 32))
                 (bytes->uint (bv-sub b 32 64))
                 (if (>= v 27) (- v 27) v))))))

(define (norm-addr a)
  (string-downcase (if (and (>= (string-length a) 2) (string=? (substring a 0 2) "0x"))
                       (substring a 2) a)))

;; the #:verify-ecdsa seam: does (text, signature) recover to expected-address?
(define (tee-verify-ecdsa text hex-sig expected-addr)
  (let ((ps (parse-signature hex-sig)))
    (and ps (string? expected-addr)
         (let ((Q (ecrecover (personal-hash text) (car ps) (cadr ps) (caddr ps))))
           (and Q (string=? (norm-addr (pubkey->address Q)) (norm-addr expected-addr)))))))
