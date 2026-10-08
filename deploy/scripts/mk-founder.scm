;;; mk-founder.scm — mint a fresh founder identity for First-Person bootstrap.
;;;
;;; This is the FALLBACK path. PREFER having the person sign up on the dial:
;;; their key is minted in their browser and never leaves it, and they hand
;;; you only their AID. This script mints a key SERVER-SIDE — fine for a
;;; throwaway / test founder, but for a real founder prefer the dial path so
;;; the key never transits a shared machine.
;;;
;;; Run:
;;;     make founder
;;;   or, directly:
;;;     guix shell -L deploy/guix -m deploy/manifests/dev-test-manifest.scm -- \
;;;       guile --no-auto-compile -q -L module deploy/scripts/mk-founder.scm
;;;
;;; It prints a passcode (the ONLY key — there is NO recovery) and its AID,
;;; derived with the native (playnet keri signify) — parity with the dial's
;;; signify-portable, so the passcode logs in to the same AID. Then activate:
;;;     deploy/scripts/add-founder.sh <AID>

(use-modules (playnet keri signify)
             (ice-9 binary-ports)
             (ice-9 format)
             (rnrs bytevectors))

;; 32 chars, no ambiguous 0/o/1/l — same alphabet the dial's genPasscode uses.
(define %alphabet "abcdefghijkmnpqrstuvwxyz23456789")

(define (gen-bran)
  "A strong passcode: 120 bits from /dev/urandom, hyphen-grouped, ≥21 chars."
  (let* ((port  (open-file "/dev/urandom" "rb"))
         (bytes (get-bytevector-n port 24)))
    (close-port port)
    (let loop ((i 0) (acc ""))
      (if (= i 24)
          acc
          (loop (+ i 1)
                (string-append
                 acc
                 (string (string-ref %alphabet (modulo (bytevector-u8-ref bytes i) 32)))
                 (if (and (= (modulo i 6) 5) (< i 23)) "-" "")))))))

(define (bran->aid bran)
  "Derive the transferable AID for BRAN exactly as the dial does:
   inception over the signing key + next-key digest; the AID is icp.i."
  (let* ((kp  (bran->signing-keypair bran))
         (nkp (bran->next-keypair bran))
         (kq  (public-key->aid-prefix (ed25519-keypair-public kp)))
         (nq  (next-key-digest (ed25519-keypair-public nkp))))
    (call-with-values
        (lambda () (build-icp #:keys (list kq) #:nkeys (list nq) #:anchors '()))
      (lambda (_icp-json _said icp-alist) (cdr (assoc "i" icp-alist))))))

(let* ((bran (gen-bran))
       (aid  (bran->aid bran)))
  (format #t "~%  ┌─ FOUNDER IDENTITY ───────────────────────────────────────────~%")
  (format #t "  │  passcode : ~a~%" bran)
  (format #t "  │  AID      : ~a~%" aid)
  (format #t "  └──────────────────────────────────────────────────────────────~%")
  (format #t "~%  SAVE THE PASSCODE NOW. It is the founder/governor key and there~%")
  (format #t "  is NO recovery. Then activate the gate with:~%~%")
  (format #t "      bash deploy/scripts/add-founder.sh ~a~%~%" aid))
