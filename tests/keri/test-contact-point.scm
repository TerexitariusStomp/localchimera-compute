;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-contact-point.scm — user-held contact points (GDPR plan §Phase 1b)
;;;
;;; A contact point is how to REACH a person on some channel. It used to live
;;; only in the gateway's member record and recipient-registry, which made it
;;; gateway-local: the AID travels to any gateway while every way of reaching
;;; the person stayed behind. As a self-issued ACDC the user is the holder and
;;; a gateway receives a revocable disclosure.
;;;
;;; The security-critical properties this pins:
;;;   • issuer = holder = the presenting AID — otherwise anyone could bind a
;;;     channel under someone else's AID and REDIRECT THEIR NOTIFICATIONS;
;;;   • the credential is blinded (`u`) from its first issuance, so a SAID
;;;     does not leak the address by rainbow-table attack (ACDC §4.1);
;;;   • a tampered body, a forged signature, an unknown channel kind and an
;;;     expired credential are each rejected;
;;;   • the derived binding matches what ^recipient-registry's `bind` wants.

;; the host crypto backend: loading (localchimera keri signify) installs it
(use-modules ((localchimera keri signify) #:select ()))
(use-modules (localchimera keri acdc) (localchimera keri citizen-sig) (localchimera keri first-person credentials) (localchimera test harness)
             ((localchimera keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair
                        keri-identity-aid))
             (srfi srfi-1))

(define alice   (make-keri-identity))
(define alice-a (keri-identity-aid alice))
(define alice-k (keri-identity-keypair alice))
(define mallory   (make-keri-identity))
(define mallory-a (keri-identity-aid mallory))
(define mallory-k (keri-identity-keypair mallory))

(define (cp . args)
  (apply make-contact-point-credential #:subject-aid alice-a args))


(display "\n── 1. Shape: self-issued, blinded, bindable ──\n")

(let ((c (cp #:kind 'email #:ctx "alice@example.org" #:signing-keypair alice-k)))
  (check "issuer = holder = the subject (nobody else asserts how to reach you)"
         (and (equal? (cred-issuer c) alice-a)
              (equal? (cred-holder c) alice-a)))
  (check "schema is contact-point" (equal? (cred-schema c)
                                           *schema-localchimera-contact-point*))
  (check "carries a blinding nonce from first issuance"
         (let ((u (cred-claim c 'u)))
           (and (string? u) (= 24 (string-length u)))))
  (check "SAID is self-consistent" (cred-said-consistent? c))
  (check "binding fields are (kind ctx style) for recipient-registry"
         (equal? (contact-point-binding-fields c)
                 (list 'email "alice@example.org" 'terse)))
  (check "acceptable when presented by its own subject"
         (eq? #t (contact-point-acceptable? c alice-a))))


(display "\n── 2. Blinding: the SAID must not leak the address ──\n")

;; The attack: an address has a small enough claim space to enumerate. Without
;; a nonce, a holder of the SAID could confirm a guessed address by rebuilding
;; the credential. With one, rebuilding cannot reproduce the SAID.
(let* ((real  (cp #:kind 'email #:ctx "alice@example.org"))
       (guess (make-contact-point-credential
               #:subject-aid alice-a
               #:kind 'email
               #:ctx "alice@example.org"
               #:issued-at (cred-claim real 'issued-at))))
  (check "same content, different SAID — the guess cannot be confirmed"
         (not (equal? (cred-said real) (cred-said guess))))
  (check "supplying the exact nonce DOES reproduce it (rebuild path works)"
         (equal? (cred-said real)
                 (cred-said (make-contact-point-credential
                             #:subject-aid alice-a
                             #:kind 'email
                             #:ctx "alice@example.org"
                             #:u         (cred-claim real 'u)
                             #:issued-at (cred-claim real 'issued-at))))))


(display "\n── 3. The security hinge: you may only bind your OWN channel ──\n")

(let ((stolen (cp #:kind 'email #:ctx "alice@example.org" #:signing-keypair alice-k)))
  (check "Mallory cannot present Alice's contact point"
         (string? (contact-point-acceptable? stolen mallory-a))))

;; The redirect attack: Mallory issues a contact point naming HIS address but
;; claiming Alice as subject, hoping the gateway binds it under her AID.
(let ((forged (make-contact-point-credential
               #:subject-aid alice-a
               #:kind 'email
               #:ctx "mallory@evil.example"
               #:signing-keypair mallory-k)))
  (check "a credential naming Alice as subject is not presentable by Mallory"
         (string? (contact-point-acceptable? forged mallory-a)))
  (check "and Alice cannot present it either — Mallory's signature fails"
         (string? (contact-point-acceptable? forged alice-a))))


(display "\n── 4. Integrity and validation ──\n")

(let* ((c (cp #:kind 'lxmf #:ctx "abc123def456" #:signing-keypair alice-k))
       (tampered (map (lambda (p)
                        (if (eq? (car p) 'claims)
                            (cons 'claims
                                  (map (lambda (q)
                                         (if (eq? (car q) 'ctx)
                                             (cons 'ctx "999999deadbeef") q))
                                       (cdr p)))
                            p))
                      c)))
  (check "a tampered destination breaks the SAID"
         (string? (contact-point-acceptable? tampered alice-a))))

(check "unknown channel kind is rejected"
       (string? (contact-point-acceptable? (cp #:kind 'carrier-pigeon #:ctx "loft-3") alice-a)))
(check "empty destination is rejected"
       (string? (contact-point-acceptable? (cp #:kind 'email #:ctx "") alice-a)))
(check "expired contact point is rejected"
       (string? (contact-point-acceptable? (cp #:kind 'email #:ctx "a@b.c" #:expires-at 1000)
                                           alice-a #:now 2000)))
(check "unexpired contact point is accepted"
       (eq? #t (contact-point-acceptable? (cp #:kind 'email #:ctx "a@b.c" #:expires-at 9999)
                                          alice-a #:now 2000)))
(check "expiry is only checked when NOW is supplied"
       (eq? #t (contact-point-acceptable? (cp #:kind 'email #:ctx "a@b.c" #:expires-at 1000)
                                          alice-a)))


(display "\n── 5. Minimisation taxonomy ──\n")

;; The ordering encodes the preference: bind an opaque routing key where you
;; can, an identifying address only where you must.
(check "lxmf / push / browser are opaque routing keys, not PII"
       (not (or (contact-point-identifying? 'lxmf)
                (contact-point-identifying? 'push)
                (contact-point-identifying? 'browser))))
(check "email / telegram / matrix are inherently identifying"
       (and (contact-point-identifying? 'email)
            (contact-point-identifying? 'telegram)
            (contact-point-identifying? 'matrix)))
(check "every kind in the taxonomy is a valid kind"
       (every contact-point-kind? *contact-point-kinds*))


(display "\n── 6. Portability: the same credential binds at any gateway ──\n")

;; Nothing in the credential names a gateway. That IS the portability
;; property — presenting it elsewhere needs no migration, no export, and no
;; cooperation from the gateway that holds it today.
(let ((c (cp #:kind 'lxmf #:ctx "abc123def456" #:signing-keypair alice-k)))
  (check "acceptable at a second gateway with no prior knowledge of Alice"
         (eq? #t (contact-point-acceptable? c alice-a)))
  (check "and yields the identical binding there"
         (equal? (contact-point-binding-fields c)
                 (list 'lxmf "abc123def456" 'terse))))

(test-summary!)
