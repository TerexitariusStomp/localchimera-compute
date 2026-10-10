;;; test-personhood-policy.scm — the ecosystem's word on recognition.
;;;
;;; A governor's gov-cap writes the row on the commune's plan-store and readers
;;; read it fresh; a partial change keeps the other keys. The bare reading —
;;; defaults and effective-k — is tests/openvtc/test-personhood-policy.scm.
;;;
;;; Run:  guile --no-auto-compile -L module -L tests tests/governance/test-personhood-policy.scm

(use-modules (playnet test harness)
             (playnet scope root) (playnet doors service)
             (playnet governance scope) (playnet keri acdc-store) (playnet keri first-person personhood-policy)
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(display "\n── the writer: gov-cap gated, partial, read fresh ──\n")
(with-vat (spawn-vat)
  (let* ((store (spawn-acdc-store))
         (root  (spawn-scope-root "Hearth"))
         (scope (spawn-scope "Hearth" #:kind 'commune #:scope-root-ref root
                             #:scope-aid "EHearth" #:acdc-store store))
         (gov   ($ scope 'mint-gov-cap "op"))
         (ps    ($ root 'plan-store)))
    (check "before any word, the default reads" (personhood-policy ps 'enrollment-k) 2)
    ($ scope 'set-personhood-policy! gov '((enrollment-k . 3)))
    (check "the row binds the next read" (personhood-policy ps 'enrollment-k) 3)
    (check "keys it did not name keep their default" (personhood-policy ps 'witness-cap) 10)
    ($ scope 'set-personhood-policy! gov '((witness-cap . 4)))
    (check "a later partial word keeps the earlier key" (personhood-policy ps 'enrollment-k) 3)
    (check "…and sets its own" (personhood-policy ps 'witness-cap) 4)
    (check "a bogus cap is refused"
           (catch #t (lambda () ($ scope 'set-personhood-policy! "not-a-cap" '((enrollment-k . 1))) 'wrote)
             (lambda _ 'refused))
           'refused)
    (check "a non-positive value is refused"
           (catch #t (lambda () ($ scope 'set-personhood-policy! gov '((enrollment-k . 0))) 'wrote)
             (lambda _ 'refused))
           'refused)))

(test-summary!)
