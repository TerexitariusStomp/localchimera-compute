;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/keri/test-signify-portable.scm — verify the portable subset
;;; produces output byte-identical to the original.
;;;
;;; signify-portable was extracted from signify.scm and ships its own
;;; pure-Scheme JSON emitter (no guile-json dependency) so it can
;;; compile under Hoot. Even small differences in serialization would
;;; cascade into different SAIDs and break every existing KERI test.
;;; This test pins the equivalence on the alist shapes that flow
;;; through saidify.

(use-modules (playnet test harness)
             (playnet keri signify-portable)
             (playnet keri signify)
             ((playnet keri crypto-primitives)
              #:select (keri-crypto-random-bytes))
             ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity?
                        keri-identity-aid))
             (rnrs bytevectors)
             (json)
             (ice-9 format))

(define (check-json shape label)
  (let ((mine   (scm->json-canonical shape))
        (theirs (scm->json-string shape)))
    (check label (string=? mine theirs))
    (unless (string=? mine theirs)
      (format #t "    expected: ~s~%    got:      ~s~%" theirs mine))))

(format #t "~%=== JSON canonical emitter — byte parity with guile-json ===~%")

(check-json '() "empty alist → {}")
(check-json (list (cons "k" "v")) "single string entry")
(check-json (list (cons "v" "KERI10JSON000000_") (cons "t" "icp")
                  (cons "s" "0") (cons "k" (vector "Dabc"))
                  (cons "c" #()) (cons "a" #()))
            "icp-shaped alist with vectors and #()")
(check-json (list (cons "n" 42) (cons "b" #t) (cons "f" #f))
            "integer + booleans")
(check-json (list (cons "s" "with \"quote\" \\back \n new \t tab"))
            "control-char escapes")
(check-json (list (cons "outer" (list (cons "inner" "v"))))
            "nested alist")
(check-json (list (cons "kv" (vector (list (cons "i" "v"))
                                      (list (cons "i" "w")))))
            "vector of alists")

(format #t "~%=== build-icp output stable for fixed bran ===~%")

(let* ((bran "abcdefghijklmnopqrstu")
       (kp   (bran->signing-keypair bran))
       (nkp  (bran->next-keypair bran))
       (kq   (public-key->aid-prefix (ed25519-keypair-public kp)))
       (nq   (next-key-digest (ed25519-keypair-public nkp))))
  (call-with-values
   (lambda () (build-icp #:keys (list kq) #:nkeys (list nq)))
   (lambda (json said _alist)
     (check "icp JSON starts with v field"
            (string-prefix? "{\"v\":\"KERI10JSON" json))
     (check "icp JSON contains the signing key qb64"
            (string-contains json kq))
     (check "icp JSON contains the next-key digest qb64"
            (string-contains json nq))
     (check "SAID is 44 chars" (= 44 (string-length said)))
     (check "SAID starts with E (blake3 code)"
            (char=? #\E (string-ref said 0)))
     ;; The SAID we get from build-icp must match what
     ;; make-signify-context computes on the same bran.
     (check "SAID equals make-signify-context's controller AID"
            (string=? said (signify-context-aid (make-signify-context bran)))))))

(format #t "~%=== Determinism ===~%")

(let* ((b "the-quick-brown-fox-jumps")
       (a1 (signify-context-aid (make-signify-context b)))
       (a2 (signify-context-aid (make-signify-context b))))
  (check "same bran → same controller AID" (string=? a1 a2)))

(format #t "~%=== JSON canonical emitter — sweep-4 edge cases ===~%")

;; Negative integer.
(check-json -42 "negative integer")
;; Vector of alists (ACDC edges shape).
(check-json #(((d . "EXX") (n . "EYY")))
            "vector of alists with symbol keys")
;; Top-level vector.
(check-json #(1 2 3) "top-level vector")
;; Nested alist + vector.
(check-json (list (cons "a" #(1 2 3))
                  (cons "b" (list (cons "x" "y"))))
            "nested vector + alist")

;; Symbol value (matches guile-json's stringify-as-string).
(let ((mine   (scm->json-canonical (list (cons "k" 'sym))))
      (theirs (scm->json-string    (list (cons "k" 'sym)))))
  (check "symbol value: stringified to match guile-json"
         (string=? mine theirs)))

;; ── Backend: random-bytes ──────────────────────────────────────────
(format #t "~%=== keri-crypto random-bytes backend ===~%")
(let ((b1 (keri-crypto-random-bytes 32))
      (b2 (keri-crypto-random-bytes 32)))
  (check "random-bytes returns a bytevector of the requested length"
         (and (bytevector? b1) (= 32 (bytevector-length b1))))
  (check "two random-bytes calls return different bytes"
         (not (equal? b1 b2))))

;; ── citizen-sig.make-keri-identity uses backend random ────────────
(let ((id1 (make-keri-identity))
      (id2 (make-keri-identity)))
  (check "make-keri-identity (no seed) produces an identity record"
         (keri-identity? id1))
  (check "two random make-keri-identity calls produce distinct AIDs"
         (not (string=? (keri-identity-aid id1)
                        (keri-identity-aid id2)))))

;; ── Sweep-4 cont: ACDC SAID rederivation via protocol-aware stripper ──
;;
;; event-stripped-for-rederivation must reset v to ACDC10JSON when
;; given an ACDC, not KERI10JSON. Earlier the function hard-coded the
;; KERI placeholder, so this is a regression guard.

(format #t "~%=== ACDC stripper / SAID rederivation ===~%")

;; Build a tiny ACDC-shaped alist by hand. The d field will be filled
;; in by saidify; verify recompute-event-said matches.
(let* ((stripped `(("v" . ,%acdc-version-placeholder)
                   ("d" . ,%saidplaceholder)
                   ("i" . "DXX")
                   ("ri" . "ELL")
                   ("s" . "ESchemaSAID")
                   ("a" . (("d" . "EXX") ("dt" . "2026-01-01")
                            ("name" . "alice"))))))
  (call-with-values
    (lambda () (saidify stripped))
    (lambda (_json said acdc)
      (check "ACDC SAID is 44 chars" (= 44 (string-length said)))
      (check "ACDC v field rewritten with ACDC10JSON prefix"
             (string=? "ACDC10JSON" (substring (assoc-ref acdc "v") 0 10)))
      ;; Now feed the concrete ACDC back through the stripper and
      ;; recompute-event-said — should match the original SAID.
      (let ((stripped-back (event-stripped-for-rederivation acdc)))
        (check "stripper preserves ACDC10JSON when re-stripping"
               (string=? %acdc-version-placeholder
                         (assoc-ref stripped-back "v"))))
      (check "recompute-event-said on ACDC matches original SAID"
             (string=? said (recompute-event-said acdc))))))

(test-summary!)
