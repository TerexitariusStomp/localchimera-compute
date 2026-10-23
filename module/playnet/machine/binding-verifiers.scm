;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/machine/binding-verifiers.scm — the real signature
;;; checks the AccountLink ceremony needs.
;;;
;;; binding.scm's verify-binding is the seam; THIS file is what fills it
;;; with in-repo crypto instead of a shrug. Three forms:
;;;
;;;   signer (did:key)   — the did:key decodes to its Ed25519 pubkey
;;;                        (z6Mk… = base58btc multibase of the 0xed01
;;;                        multicodec-prefixed key); the sig is a CESR
;;;                        qb64 Ed25519 signature over the statement.
;;;   account (keri:)    — the AID's signature verifies through
;;;                        verify-said-signature, the same path the
;;;                        session signature gates use.
;;;   account (CAIP-10)  — an eip155 account is an EOA: the sig is an
;;;                        EIP-191 personal-sign and tee-verify-ecdsa
;;;                        recovers the signer to the account's address.
;;;
;;; Fail-closed holds: an account form this module doesn't know answers
;;; 'unverifiable through verify-binding's catch — a binding the crypto
;;; can't read is a binding that doesn't settle, not one that pretends.

(define-module (playnet machine binding-verifiers)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 format)
  #:use-module ((playnet keri citizen-sig) #:select (verify-said-signature))
  #:use-module ((playnet keri cesr) #:select (cesr-qb64->bytes))
  #:use-module ((playnet keri crypto-primitives)
                #:select (keri-crypto-ed25519-verify))
  #:use-module ((playnet ai tee-crypto) #:select (tee-verify-ecdsa))
  #:export (base58-decode base58-encode did-key->ed25519-pubkey
            ed25519-pubkey->did-key
            verify-did-key-sig verify-caip10-sig verify-keri-account-sig
            account-verifier-for))


;;; ── base58btc ────────────────────────────────────────────────────────────
;;; did:key's "z" marks base58btc. The alphabet is Bitcoin's.

(define *base58-alphabet*
  "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

(define (base58-decode s)
  "base58btc → bytevector. Leading '1's are leading zero bytes. Works on
   a digit list, big-endian accumulate: out = out*58 + digit."
  (let ((digits (map (lambda (c)
                       (or (string-index *base58-alphabet* c)
                           (error "base58: bad character" c)))
                     (string->list s))))
    (let lp ((ds digits) (acc '()))
      (if (null? ds)
          ;; acc is least-significant-first; reverse to bytes, restore the
          ;; leading zeros the '1's stood for.
          (let* ((lead (length (take-while (lambda (d) (= d 0)) digits)))
                 (payload (reverse acc))
                 (trimmed (drop-while zero? payload))
                 (out (u8-list->bytevector
                       (append (make-list lead 0) trimmed))))
            (if (zero? (bytevector-length out)) (make-bytevector 1 0) out))
          ;; multiply the running base-256 digit list by 58, add the digit.
          ;; the walk builds res MSB-first — flip it back (the final carry
          ;; is the new most-significant byte).
          (let mul ((xs acc) (carry (car ds)) (res '()))
            (if (null? xs)
                (lp (cdr ds) (reverse (if (> carry 0) (cons carry res) res)))
                (let* ((v (+ (* (car xs) 58) carry)))
                  (mul (cdr xs) (quotient v 256)
                       (cons (remainder v 256) res)))))))))


(define (base58-encode bv)
  "bytevector → base58btc. The inverse of base58-decode: leading zero
   bytes are '1's; digits accumulate LSB-first, each byte a
   multiply-by-256 carry pass."
  (let* ((n (bytevector-length bv))
         (lead (let lp ((i 0)) (if (and (< i n) (zero? (bytevector-u8-ref bv i)))
                                   (lp (+ i 1)) i))))
    (if (= n 0) ""
        (let lp ((i lead) (digits '()))
          (if (= i n)
              ;; digits is LSB-first — reverse for print order
              (list->string
               (append (make-list lead #\1)
                       (map (lambda (d) (string-ref *base58-alphabet* d))
                            (reverse digits))))
              ;; multiply the digit list by 256, add the byte: walk LSB
              ;; first, each remainder cons'd on — res ends MSB-first
              (let mul ((ds digits) (carry (bytevector-u8-ref bv i)) (res '()))
                (if (null? ds)
                    ;; carry overflow is MORE significant — cons its
                    ;; base-58 digits onto res's head
                    (let flush ((c carry) (res res))
                      (if (zero? c)
                          (lp (+ i 1) (reverse res))
                          (flush (quotient c 58)
                                 (cons (remainder c 58) res))))
                    (let ((v (+ (* (car ds) 256) carry)))
                      (mul (cdr ds) (quotient v 58)
                           (cons (remainder v 58) res))))))))))

(define (ed25519-pubkey->did-key pub-bv)
  "did:key:z… for a 32-byte Ed25519 pubkey — the multicodec tag 0xed01
   then base58btc. Inverse of did-key->ed25519-pubkey."
  (unless (and (bytevector? pub-bv) (= 32 (bytevector-length pub-bv)))
    (error "ed25519-pubkey->did-key: need a 32-byte key"))
  (string-append "did:key:z"
                 (base58-encode (u8-list->bytevector
                                 (cons #xed (cons #x01 (bytevector->u8-list pub-bv)))))))

;;; ── did:key → the Ed25519 pubkey ─────────────────────────────────────────
;;; "did:key:z" + base58btc(0xed 0x01 ∥ 32-byte pubkey). ed25519-pub's
;;; multicodec is 0xed — the two-byte prefix is the codec tag, the rest is
;;; the key.

(define (did-key->ed25519-pubkey did)
  "The 32-byte Ed25519 pubkey a did:key encodes, or #f if the did isn't
   a z6Mk-prefixed ed25519-pub multicodec."
  (and (string? did) (string-prefix? "did:key:z" did)
       (let ((bv (catch #t
                   (lambda () (base58-decode (substring did 9)))
                   (lambda _ #f))))
         (and bv (= (bytevector-length bv) 34)
              (= (bytevector-u8-ref bv 0) #xed)
              (= (bytevector-u8-ref bv 1) #x01)
              (u8-list->bytevector
               (map (lambda (i) (bytevector-u8-ref bv (+ 2 i)))
                    (iota 32)))))))


;;; ── the three verifiers ──────────────────────────────────────────────────
;;; Each answers #t / #f — verify-binding's cond turns them into verdicts.

(define* (verify-did-key-sig did-key statement sig-qb64 #:optional _at)
  "The signer's side: Ed25519 over the statement's UTF-8 bytes under the
   pubkey the did:key itself encodes — no resolver, no trust needed."
  (catch #t
    (lambda ()
      (let ((pub (did-key->ed25519-pubkey did-key))
            (sig (cesr-qb64->bytes sig-qb64)))
        (and pub sig (= (bytevector-length sig) 64)
             (keri-crypto-ed25519-verify pub (string->utf8 statement) sig))))
    (lambda _ #f)))

(define* (verify-keri-account-sig account statement sig-qb64 #:optional _at)
  "keri:<aid> accounts: the AID's signature via the codebase's own path —
   D/B prefixes verify locally; E-prefix resolves the key through KERIA."
  (and (string-prefix? "keri:" account)
       (verify-said-signature statement sig-qb64 (substring account 5))))

(define* (verify-caip10-sig account statement hex-sig #:optional _at)
  "eip155:CAIP-10 accounts are EOAs: EIP-191 personal-sign recovery must
   land on the account's own address."
  (and (string-prefix? "eip155:" account)
       (let ((addr (car (reverse (string-split account #\:)))))
         (tee-verify-ecdsa statement hex-sig addr))))

(define (account-verifier-for account)
  "Dispatch on the account form: keri: → the KERI path; eip155: → ECDSA
   recovery; anything else → #f (verify-binding's 'unverifiable verdict
   rides that — the form we can't read is the binding we can't settle)."
  (cond
   ((string-prefix? "keri:" account) verify-keri-account-sig)
   ((string-prefix? "eip155:" account) verify-caip10-sig)
   (else #f)))
