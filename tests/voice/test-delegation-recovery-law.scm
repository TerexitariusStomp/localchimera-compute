;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-delegation-recovery-law.scm — the recovery law, held for delegation.
;;;
;;; recovery.scm's docstring states it: the live actor graph is a PROJECTION
;;; of the credential store; recovery is the inverse of mutation. For the
;;; delegation map that means
;;;
;;;     recover(store)  ≡  the live map, whatever the mutation history
;;;
;;; What holds it: re-delegating SUPERSEDES (set-entry revokes the prior
;;; credential for the same (delegate, franchise) before issuing), so the
;;; store's LIVE set carries at most one credential per key — replay cannot
;;; resurrect a superseded fraction, and no ordering of the replay matters.
;;;
;;; Run:  guile -L module -L tests tests/voice/test-delegation-recovery-law.scm

(use-modules (playnet voice delegation-map) (playnet federation rebuild) (playnet keri acdc) (playnet keri acdc-store) (playnet test harness)
             (goblins) (goblins utils hashmap) (srfi srfi-1))

(define (fed-fractions dm)
  (sort (hashmap-fold (lambda (k e acc) (cons (cons k (car e)) acc))
                      '() ($ dm 'federation-default))
        (lambda (a b) (string<? (car a) (car b)))))

(display "\n── the delegation recovery law ──\n")
(with-vat (spawn-vat)
  (let* ((store (spawn-acdc-store))
         (dm (spawn-delegation-map "citizen:ana" #:acdc-store store)))

    ;; a mutation history with a superseded fraction and a scope override
    ($ dm 'delegate "citizen:bo" 1/2)
    ($ dm 'delegate "citizen:cy" 1/4)
    ($ dm 'delegate "citizen:bo" 1/5)               ; supersedes the 1/2
    ($ dm 'delegate "citizen:cy" 1/8 'scope "berlin")

    (check "re-delegation leaves ONE live credential for (bo, federation)"
           (length (filter (lambda (c)
                             (and (not (cred-revoked? c))
                                  (equal? "citizen:bo" (cred-holder c))
                                  (eq? 'federation
                                       (assq-ref (cred-claims c) 'franchise))))
                           ($ store 'by-issuer "citizen:ana")))
           1)

    (let ((live (fed-fractions dm))
          (rec  (fed-fractions
                 (recover-delegation-map "citizen:ana" store))))
      (check "the live map holds the superseding fractions"
             live '(("citizen:bo" . 1/5) ("citizen:cy" . 1/4)))
      (check "recover(store) = the live map — the projection law"
             rec live))

    ;; the scope override recovers too
    (let* ((rdm (recover-delegation-map "citizen:ana" store))
           (ov  (hashmap-ref ($ rdm 'scope-overrides) "berlin" #f)))
      (check "the scope override survives the round trip"
             (and ov (car (hashmap-ref ov "citizen:cy" '(#f)))) 1/8))

    ;; revocation projects: revoke live, recover, the entry is gone
    ($ dm 'revoke "citizen:cy")
    (let ((rec (fed-fractions (recover-delegation-map "citizen:ana" store))))
      (check "a revocation is recovered as absence"
             rec '(("citizen:bo" . 1/5))))))

(test-summary!)
