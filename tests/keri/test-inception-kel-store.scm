;;; test-inception-kel-store.scm — a minted AID's inception lands in its KEL store
;;;
;;; governance-create-scope-aid! takes an optional #:kel-store — an actor — and
;;; appends the signed inception body to it, so the AID's KEL starts with its
;;; icp on disk. The keri-backend's live `create-scope-aid` and scope recovery
;;; both pass one. This holds the whole path: mint with a store, and the store
;;; holds exactly the body the inception record carries.

(use-modules (playnet test harness))
(use-modules (playnet keri inception))
(use-modules (goblins) (goblins actor-lib methods))

(define vat (spawn-vat))
(define appended '())
(define (^recording-kel bcom)
  (methods ((append body) (set! appended (cons body appended)) 'ok)))

(display "\n── mint with a kel-store ──\n")
(define inc
  (with-vat vat
    (governance-create-scope-aid! #:kel-store (spawn ^recording-kel))))

(check "the mint returns an inception record" (scope-inception? inc) #t)
(check "the AID is a CESR prefix" (string? (scope-inception-aid inc)) #t)
(check "the kel-store received one append" (length appended) 1)
(check "what it received is the signed icp the record carries"
       (equal? (car appended) (scope-inception-signed-icp inc)) #t)

(display "\n── mint without one ──\n")
(set! appended '())
(define bare (with-vat vat (governance-create-scope-aid!)))
(check "a store-less mint still returns a record" (scope-inception? bare) #t)
(check "and appends nowhere" (length appended) 0)

(test-summary!)
