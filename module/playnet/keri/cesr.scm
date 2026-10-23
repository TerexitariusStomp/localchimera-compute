;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/keri/cesr.scm — CESR qb64 codec helpers
;;;
;;; CESR (Composable Event Streaming Representation) encodes crypto
;;; materials as qb64 — base64url with a type-code prefix.
;;;
;;; Common codes used in playnet's KERI bridge:
;;;   "D"  (1 char)  → ed25519 transferable public key   (32 bytes raw)
;;;   "B"  (1 char)  → ed25519 non-transferable pubkey   (32 bytes raw)
;;;   "E"  (1 char)  → SAID / blake3-256 digest          (32 bytes raw)
;;;   "0B" (2 chars) → ed25519 signature                 (64 bytes raw)
;;;   "0A" (2 chars) → random salt / 128-bit number      (16 bytes raw)
;;;   "AA" (2 chars) → indexed signature, index 0        (64 bytes raw)
;;;
;;; Encoding: code + base64url(raw-bytes).  Padding is dropped on
;;; encode and re-added on decode.
;;;
;;; Parity: mirrors signify-ts 0.3.0 (commit ebc0f0f) src/keri/core/coring.ts.
;;; The CESR derivation codes (D, B, E, 0A, 0B, AA) MUST match the
;;; MtrDex / CtrDex constants there; drift here is silently fatal —
;;; signatures don't verify, AIDs don't parse. See docs/keri/SIGNIFY-PARITY.md.
;;;
;;; This module was extracted from bridge.scm so signify.scm can
;;; reuse the codec without depending on the HTTP layer.

(define-module (playnet keri cesr)
  #:use-module (rnrs bytevectors)
  #:export (b64url-encode
            b64url-decode
            b64url-char->val
            cesr-bytes->qb64
            cesr-qb64->bytes
            bytevector-append
            ;; The single canonical RFC 4648 §5 base64url alphabet.
            ;; Other KERI modules (signify-portable's CESR counter and
            ;; indexed-signature codes) re-export from here rather than
            ;; redefining their own copy.
            %b64url-alphabet))

;; srfi-13 isn't available in Hoot, and we only need two operations from
;; it. Inline them so cesr.scm compiles for both server and browser.

(define (string-index s c)
  "Return the index of the first occurrence of CHAR C in S, or #f."
  (let ((n (string-length s)))
    (let loop ((i 0))
      (cond ((>= i n) #f)
            ((char=? (string-ref s i) c) i)
            (else (loop (+ i 1)))))))

(define (string-prefix? prefix s)
  "True if S starts with PREFIX."
  (let ((pn (string-length prefix))
        (sn (string-length s)))
    (and (>= sn pn)
         (string=? prefix (substring s 0 pn)))))

;;; ── bytevector-append (Guile's rnrs doesn't export one) ─────────────────────
;;; Lives here because cesr.scm is the common low-level utility module
;;; imported by every KERI-layer file. signify.scm and bridge.scm both
;;; use it; keeping the definition here avoids duplicating it.

(define (bytevector-append . bvs)
  "Concatenate bytevectors."
  (let* ((total (apply + (map bytevector-length bvs)))
         (out   (make-bytevector total 0)))
    (let loop ((bvs bvs) (off 0))
      (cond ((null? bvs) out)
            (else
             (let ((n (bytevector-length (car bvs))))
               (bytevector-copy! (car bvs) 0 out off n)
               (loop (cdr bvs) (+ off n))))))))

(define %b64url-alphabet
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

;; Backwards-compatible alias. *b64-chars* was the original name and
;; is still referenced inside this module's b64url-encode below.
(define *b64-chars* %b64url-alphabet)

(define (b64url-char->val c)
  (or (string-index *b64-chars* c)
      (error "invalid base64url char" c)))

(define (b64url-decode str)
  "Decode a base64url string (no padding required) to a bytevector."
  (let* ((n    (string-length str))
         (pad  (modulo (- 4 (modulo n 4)) 4))
         (padded (string-append str (make-string pad #\=)))
         (out-len (- (quotient (* 3 (string-length padded)) 4) pad))
         (bv  (make-bytevector out-len 0)))
    (let loop ((i 0) (di 0))
      (when (< i (string-length padded))
        (let* ((c0 (string-ref padded i))
               (c1 (string-ref padded (+ i 1)))
               (c2 (string-ref padded (+ i 2)))
               (c3 (string-ref padded (+ i 3)))
               (v0 (b64url-char->val c0))
               (v1 (b64url-char->val c1))
               (v2 (if (char=? c2 #\=) 0 (b64url-char->val c2)))
               (v3 (if (char=? c3 #\=) 0 (b64url-char->val c3)))
               (bits (logior (ash v0 18) (ash v1 12) (ash v2 6) v3)))
          (bytevector-u8-set! bv di (logand (ash bits -16) #xff))
          (when (not (char=? c2 #\=))
            (bytevector-u8-set! bv (+ di 1) (logand (ash bits -8) #xff)))
          (when (not (char=? c3 #\=))
            (bytevector-u8-set! bv (+ di 2) (logand bits #xff)))
          (loop (+ i 4) (+ di 3)))))
    bv))

(define (b64url-encode bv)
  "Encode a bytevector as base64url (no padding)."
  (let ((n (bytevector-length bv)))
    (let loop ((i 0) (acc '()))
      (if (>= i n)
          (list->string (reverse acc))
          (let* ((b0 (bytevector-u8-ref bv i))
                 (b1 (if (< (+ i 1) n) (bytevector-u8-ref bv (+ i 1)) 0))
                 (b2 (if (< (+ i 2) n) (bytevector-u8-ref bv (+ i 2)) 0))
                 (bits (logior (ash b0 16) (ash b1 8) b2))
                 (c0 (string-ref *b64-chars* (logand (ash bits -18) #x3f)))
                 (c1 (string-ref *b64-chars* (logand (ash bits -12) #x3f)))
                 (c2 (if (< (+ i 1) n)
                         (string-ref *b64-chars* (logand (ash bits -6) #x3f))
                         #f))
                 (c3 (if (< (+ i 2) n)
                         (string-ref *b64-chars* (logand bits #x3f))
                         #f)))
            (loop (+ i 3)
                  (append (filter identity (list c3 c2 c1 c0)) acc)))))))

;;; ── CESR encoding/decoding (canonical, keripy-compatible) ───────────────────
;;;
;;; CESR encoding of a typed primitive (code, raw-bytes):
;;;
;;;   1. Compute ps = (3 - rs mod 3) mod 3  (pre-pad bytes to prepend).
;;;   2. padded = ps zero bytes ++ raw-bytes  (length divisible by 3).
;;;   3. Base64url-encode padded  → fs chars, no '=' padding.
;;;   4. Replace the first hs = (string-length code) chars of the output
;;;      with the code string itself.
;;;
;;; Because the leading ps*8 bits of `padded' are all zero, the first
;;; `hs` base64 chars of step 3 are guaranteed to be 'A' (value 0) —
;;; replacing them with the code string is information-preserving.
;;;
;;; Decoding reverses: substitute 'A's back for the code chars, base64
;;; decode, drop ps leading bytes, return the remaining rs bytes.
;;;
;;; For this to round-trip across implementations, ps must match the
;;; one keripy/signify-ts uses. Our choice follows that spec.

(define (%cesr-pad-size raw-len)
  (modulo (- 3 (modulo raw-len 3)) 3))

(define (cesr-bytes->qb64 code bytes)
  "Encode raw BYTES as a canonical CESR qb64 string under CODE.
   code = string prefix (hs chars), e.g. \"D\" / \"E\" / \"0B\" / \"AA\"."
  (let* ((hs      (string-length code))
         (rs      (bytevector-length bytes))
         (ps      (%cesr-pad-size rs))
         (padded  (let ((bv (make-bytevector (+ ps rs) 0)))
                    (bytevector-copy! bytes 0 bv ps rs)
                    bv))
         (b64     (b64url-encode padded)))
    (string-append code (substring b64 hs))))

(define (cesr-qb64->bytes qb64)
  "Decode a canonical CESR qb64 string to raw bytes, dropping the code
   prefix and the CESR pre-pad.

   Heuristic for code size: 2-char codes (hs=2) begin with a digit
   ('0'-'9') or a 2-byte capitalized prefix ('AA'..'AH' at time of
   writing). Everything else is a 1-char code. This covers all codes
   playnet uses (D, E, B, 0B, 0A, AA) and matches keripy's MtrDex
   lookup for those ranges."
  (let* ((hs (cond
              ((string-prefix? "0" qb64) 2)
              ((and (>= (string-length qb64) 2)
                    (char=? #\A (string-ref qb64 0))
                    (let ((c1 (string-ref qb64 1)))
                      (and (char>=? c1 #\A) (char<=? c1 #\H))))
               2)
              (else 1)))
         (total-len (string-length qb64))
         ;; Substitute 'A's back for the code so base64 decode works.
         (qb64r     (string-append (make-string hs #\A)
                                   (substring qb64 hs)))
         (full-bv   (b64url-decode qb64r))
         ;; Derived lengths: we decoded a padded buffer; strip the
         ;; leading ps zero bytes.
         (full-len  (bytevector-length full-bv))
         ;; rs is fixed by the code, but we recover it as "everything
         ;; after the pre-pad". ps = full-len mod 3 isn't right in
         ;; general; ps = ((3 - ((4*full-len - total-len) mod 3)) …)
         ;; is overkill. Instead reuse the pad-size formula from the
         ;; raw length: if rs = (full-len - ps) and ps = pad(rs), then
         ;; ps = (total-len*3/4) - rs = full-len - rs. For our codes
         ;; ps is determined by hs (1→1, 2→2) because both common raw
         ;; sizes (32 and 64) produce the same ps as hs.
         (ps        hs)
         (rs        (- full-len ps))
         (out       (make-bytevector rs 0)))
    (bytevector-copy! full-bv ps out 0 rs)
    out))
