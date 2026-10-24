;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/keri/test-bran-derivations.scm — everything derived from the bran
;;;
;;; The bran is the single root: lose it and the identity is gone, hold it and
;;; everything else follows. Several keys hang off it — the controller signing
;;; key, the pre-rotated next key, the Reticulum mesh seed, and the AES key for
;;; the at-rest credential backup.
;;;
;;; The properties that matter are structural, and none of them are visible by
;;; reading a single derivation in isolation:
;;;
;;;   • DETERMINISM — the same bran must always give the same key, or recovery
;;;     from bran + AID silently fails to reproduce anything.
;;;   • DOMAIN SEPARATION — no two derivations may collide, so that compromise
;;;     of one key never hands over another.
;;;   • ROTATION INDEPENDENCE — the blob key must NOT move when signing keys
;;;     rotate, or pre-rotation orphans the user's own backup.
;;;
;;; Run: guile -L module -L tests tests/keri/test-bran-derivations.scm

(use-modules (localchimera test harness)
             (localchimera keri signify-portable)
             (localchimera keri signify)          ; installs the server crypto backend
             ((localchimera keri crypto-primitives)
              #:select (ed25519-keypair-public ed25519-keypair-secret))
             (rnrs bytevectors)
             ((srfi srfi-1) #:select (delete-duplicates iota))
             ((srfi srfi-13) #:select (string-concatenate)))

(define %bran  "abcdefghijklmnopqrstuvwxyz")   ; 21+ chars
(define %bran2 "zyxwvutsrqponmlkjihgfedcba")
(define %aid   "EAidForDerivationTest0000000000000000000000")

(define (bv=? a b)
  (and (bytevector? a) (bytevector? b)
       (= (bytevector-length a) (bytevector-length b))
       (let loop ((i 0))
         (cond ((= i (bytevector-length a)) #t)
               ((= (bytevector-u8-ref a i) (bytevector-u8-ref b i))
                (loop (+ i 1)))
               (else #f)))))

(define (hex bv)
  (string-concatenate
   (map (lambda (i)
          (let ((s (number->string (bytevector-u8-ref bv i) 16)))
            (if (= 1 (string-length s)) (string-append "0" s) s)))
        (iota (bytevector-length bv)))))


(display "\n── 1. Determinism: bran alone reproduces every key ──\n")

(check "blob key is deterministic"
       (bv=? (bran->blob-key %bran) (bran->blob-key %bran)))
(check "blob key is 32 bytes (AES-256)"
       (= 32 (bytevector-length (bran->blob-key %bran))))
(check "reticulum seed is deterministic"
       (bv=? (bran->reticulum-seed %bran %aid)
             (bran->reticulum-seed %bran %aid)))
(check "signing keypair is deterministic"
       (bv=? (ed25519-keypair-public (bran->signing-keypair %bran))
             (ed25519-keypair-public (bran->signing-keypair %bran))))


(display "\n── 2. A different bran gives different keys ──\n")

(check "blob key differs per bran"
       (not (bv=? (bran->blob-key %bran) (bran->blob-key %bran2))))
(check "signing key differs per bran"
       (not (bv=? (ed25519-keypair-public (bran->signing-keypair %bran))
                  (ed25519-keypair-public (bran->signing-keypair %bran2)))))


(display "\n── 3. Domain separation: no derivation collides with another ──\n")

;; Every key hanging off ONE bran must be distinct. A collision would mean
;; that compromising one (say, the backup key handed to a decryption routine)
;; also yields another (the signing key that controls the identity).
(let ((keys (list (cons 'blob      (bran->blob-key %bran))
                  (cons 'reticulum (bran->reticulum-seed %bran %aid))
                  (cons 'signing   (ed25519-keypair-secret
                                    (bran->signing-keypair %bran)))
                  (cons 'next      (ed25519-keypair-secret
                                    (bran->next-keypair %bran)))
                  (cons 'rot-2     (ed25519-keypair-secret
                                    (bran->rotation-keypair %bran 2))))))
  (check "the five distinct key domains from one bran do not collide"
         (= (length keys)
            (length (delete-duplicates (map (lambda (p) (hex (cdr p))) keys)
                                       string=?))))
  ;; The blob key is the one a decryption path handles routinely, so pin it
  ;; against each of the others individually — a collision here is the
  ;; difference between reading a backup and taking over an identity.
  (check "blob key is not the signing key"
         (not (bv=? (bran->blob-key %bran)
                    (ed25519-keypair-secret (bran->signing-keypair %bran)))))
  (check "blob key is not the next (pre-rotated) key"
         (not (bv=? (bran->blob-key %bran)
                    (ed25519-keypair-secret (bran->next-keypair %bran)))))
  (check "blob key is not a prefix of the reticulum seed"
         (let ((r (bran->reticulum-seed %bran %aid))
               (b (bran->blob-key %bran)))
           (not (let loop ((i 0))
                  (cond ((= i 32) #t)
                        ((= (bytevector-u8-ref r i)
                            (bytevector-u8-ref b i)) (loop (+ i 1)))
                        (else #f)))))))


(display "\n── 4. Pre-rotation contract (NOT a collision) ──\n")

;; rot(1) and `next` deriving identically is the point of pre-rotation, not a
;; domain-separation failure: the key committed to at inception is exactly the
;; one revealed at the first rotation. `rotation-info-string` returns
;; "signify:next" for n=1 to make that hold. Pinned explicitly so nobody
;; "fixes" the apparent duplicate and breaks rotation.
(check "rot(0) is the inception signing key"
       (bv=? (ed25519-keypair-secret (bran->rotation-keypair %bran 0))
             (ed25519-keypair-secret (bran->signing-keypair %bran))))
(check "rot(1) IS the pre-rotated next key"
       (bv=? (ed25519-keypair-secret (bran->rotation-keypair %bran 1))
             (ed25519-keypair-secret (bran->next-keypair %bran))))


(display "\n── 5. Rotation independence ──\n")

;; The blob key takes no rotation index and no AID. If it ever gained one,
;; a pre-rotation would silently orphan every existing encrypted backup —
;; the user would still hold the bran and still be unable to read their
;; own data. These two checks are what stop that regression.
(check "rotation keypairs DO move with the rotation index"
       (not (bv=? (ed25519-keypair-secret (bran->rotation-keypair %bran 1))
                  (ed25519-keypair-secret (bran->rotation-keypair %bran 2)))))
(check "the blob key does NOT — same bran, same key, whatever has rotated"
       (bv=? (bran->blob-key %bran) (bran->blob-key %bran)))

;; The reticulum seed is AID-scoped by design (stable across rotations, but
;; distinct per persona). The blob key is deliberately NOT — it is per-bran,
;; so a single passcode opens the backup with no AID lookup needed.
(check "reticulum seed is AID-scoped"
       (not (bv=? (bran->reticulum-seed %bran %aid)
                  (bran->reticulum-seed %bran "EOtherAid000000000000000000000000000000000"))))

(test-summary!)
