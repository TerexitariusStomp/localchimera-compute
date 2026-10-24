;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/doors/test-lobby-seat-gate.scm — a key proven is not a seat held.
;;;
;;; ^oobi-host witnesses any verifiable KEL, so an AID can have a current
;;; key at a gateway without ever having joined its universal commune.
;;; keri-authenticate verifies the challenge under that key AND asks
;;; signup-agent for the seat; witnessed-only is refused, seated is
;;; admitted. The lobby's witness-kel / join / has-seat doors are driven
;;; the way the browser's take-seat! drives them. signup-agent sits in
;;; its own vat, as in the gateway, so the gated answer is a promise.

(use-modules (localchimera test harness)
             (localchimera test identity)
             (localchimera keri signify-portable)
             ((localchimera keri cesr) #:select (cesr-bytes->qb64))
             (localchimera identity seat)
             (localchimera identity oobi-host)
             (localchimera doors lobby)
             (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (rnrs bytevectors)
             (ice-9 format))

(define-values (kp0 kp1 icp-json icp-said icp-alist aid icp-sigs)
  (test-identity "seat-gate-passcode-21ch"))
(define-values (gateway-vat signup-vat signup-agent oobi-host lobby settle)
  (lobby-fixture))

(define (challenge-and-answer kp)
  (let* ((nonce (with-vat gateway-vat ($ lobby 'keri-challenge aid)))
         (sig   (cesr-bytes->qb64 "0B" (sign-bytes (string->utf8 nonce) kp))))
    (settle (with-vat gateway-vat ($ lobby 'keri-authenticate aid sig nonce)))))

(format #t "~%=== witnessed, not seated ===~%")

(check "witness-kel → 'ok"
       (eq? 'ok (settle (with-vat gateway-vat
                          ($ lobby 'witness-kel aid icp-alist icp-sigs (vector))))))
(check "has-seat → #f"
       (not (settle (with-vat gateway-vat ($ lobby 'has-seat aid)))))
(let ((r (challenge-and-answer kp0)))
  (check "keri-authenticate under the right key, no seat → error"
         (and (pair? r) (eq? 'error (car r))))
  (check "…and the reason names the seat"
         (and (pair? r) (string? (cadr r)) (string-contains (cadr r) "seat"))))

(format #t "~%=== seated ===~%")

(check "join → 'ok"
       (eq? 'ok (settle (with-vat gateway-vat ($ lobby 'join "" "" aid)))))
(check "has-seat → #t"
       (eq? #t (settle (with-vat gateway-vat ($ lobby 'has-seat aid)))))
(let ((r (challenge-and-answer kp0)))
  (check "keri-authenticate, seated → ok + session"
         (and (pair? r) (eq? 'ok (car r))))
  (when (and (pair? r) (eq? 'ok (car r)))
    (check "the session reports the AID"
           (equal? aid (with-vat gateway-vat ($ (cadr r) 'whoami))))))
(let ((r (challenge-and-answer (bran->signing-keypair "someone-else-entirely-21"))))
  (check "seated, wrong key → error"
         (and (pair? r) (eq? 'error (car r)))))

(test-summary!)
