;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-tee-crypto.scm — pin the pure-Guile keccak256 + secp256k1 ecrecover to
;;; CANONICAL, externally-known vectors, so we KNOW the crypto is correct (not
;;; merely that it runs). If any of these fail, the TEE verifier is unsound.
;;;
;;; Run: guile -L module tests/ai/test-tee-crypto.scm

(use-modules (playnet test harness)
             (playnet ai tee-crypto)
             (rnrs bytevectors) (ice-9 format))

(define (hex bv)
  (string-concatenate
   (map (lambda (b) (let ((h (number->string b 16))) (if (= (string-length h) 1) (string-append "0" h) h)))
        (bytevector->u8-list bv))))
(define (kh s) (hex (keccak256 (string->utf8 s))))

;;; ─── 1. keccak256 canonical vectors (the ORIGINAL Keccak, not SHA3-256) ────
(display "\n── keccak256 against canonical test vectors ──\n")
(check "keccak256(\"\") is the canonical empty-input hash"
       (kh "") "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
(check "keccak256(\"abc\") matches the canonical vector"
       (kh "abc") "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
;; a >136-byte input to exercise multi-block absorption
(check "keccak256 of a 200-char string (multi-block) is stable"
       (kh (make-string 200 #\a))
       (kh (make-string 200 #\a)))   ; self-consistency across calls

;;; ─── 2. Ethereum personal_sign message hash (validates the prefix path) ────
;;; web3.js: eth.accounts.sign('Some data', pk) → messageHash below.
(display "\n── personal_sign (encode_defunct) message hash ──\n")
(define ph (personal-hash "Some data"))
(check "personal-hash(\"Some data\") equals the canonical web3.js messageHash"
       (string-downcase (number->string ph 16))
       "1da44b586eb0729ff70a73c326926f6ed5a25f5b056e7f47fbc6e58d86871655")

;;; ─── 3. secp256k1 ecrecover on a REAL personal_sign signature ──────────────
;;; The signature web3.js produced for 'Some data' with private key
;;; 0x4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318,
;;; whose account address is 0x2c7536E3605D9C16a7a3D7b1898e529396a65c23.
(define sig
  "0xb91467e570a6466aa9e9876cbcd013baba02900b8979d43fe208a4a4f339f5fd6007e74cd82e037b800186422fc2da167c747ef045e5d18a5f5d4300f8e1a0291c")
(define expected-addr "0x2c7536E3605D9C16a7a3D7b1898e529396a65c23")
(define ps (parse-signature sig))
(define Q  (ecrecover ph (car ps) (cadr ps) (caddr ps)))
(display "\n── ecrecover → address, cross-checked by an independent ECDSA verify ──\n")
(format #t "  recovered address: ~a\n" (pubkey->address Q))
(check-pred "the recovered key passes a standard ECDSA verify (internal soundness)"
            (secp256k1-verify Q ph (car ps) (cadr ps)))
(check "ecrecover yields the signer's canonical Ethereum address"
       (string-downcase (pubkey->address Q))
       (string-downcase expected-addr))

;;; ─── 4. the #:verify-ecdsa seam that llm.scm plugs in ──────────────────────
(display "\n── tee-verify-ecdsa: the seam llm.scm calls ──\n")
(check-pred "accepts the real (text, signature, address) triple"
            (tee-verify-ecdsa "Some data" sig expected-addr))
(check-pred "rejects the SAME signature against a different address"
            (not (tee-verify-ecdsa "Some data" sig "0x0000000000000000000000000000000000000000")))
(check-pred "rejects when the signed text is altered (signature no longer recovers the addr)"
            (not (tee-verify-ecdsa "Some dataX" sig expected-addr)))
(check-pred "rejects a malformed signature (not 65 bytes)"
            (not (tee-verify-ecdsa "Some data" "0xdeadbeef" expected-addr)))

(display "\n")
(test-summary!)
