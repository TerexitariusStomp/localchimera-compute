;;; test-scope-brand.scm — scope brand rejects non-^scope refs
;;;
;;; merge-with and admit-commune accept a counterparty ref. Without a brand
;;; check, any actor that responds to 'scope-aid / 'name / 'commune-aid
;;; passes the duck-type — letting an attacker forge a counterparty AID.
;;;
;;; verify-scope! checks a sealed brand-token that only real ^scope
;;; instances (in the same vat) can produce.

(use-modules (playnet test harness))
(use-modules (playnet org endorsement))
(use-modules (playnet planner scope root))
(use-modules (playnet governance scope))
(use-modules (goblins) (goblins vat) (goblins actor-lib methods)
             (fibers) (fibers conditions) (ice-9 atomic))

(define (run-in-vat thunk)
  (let ((box  (make-atomic-box 'pending))
        (done (make-condition)))
    (run-fibers
     (lambda ()
       (with-vat (spawn-vat)
         (atomic-box-set! box (thunk))
         (signal-condition! done))
       (wait done)))
    (atomic-box-ref box)))

(display "\n── 1. merge-with rejects fake counterparty ──\n")
(let ((result
       (run-in-vat
        (lambda ()
          (let* ((root-a  (spawn-scope-root "A"))
                 (root-b  (spawn-scope-root "B"))
                 (scope-a (spawn-scope "A" #:kind 'commune #:scope-aid "E_a"
                                          #:scope-root-ref root-a))
                 (scope-b (spawn-scope "B" #:kind 'commune #:scope-aid "E_b"
                                          #:scope-root-ref root-b))
                 (gov-a   ($ scope-a 'mint-gov-cap "owner-a"))
                 (fake    (spawn (lambda (bcom)
                                   (methods
                                     [(scope-aid)   "E_attacker"]
                                     [(name)        "attacker"]
                                     [(commune-aid) "E_attacker"])))))
            (list 'legit  ($ scope-a 'merge-with scope-b gov-a)
                  'fake-rejected?
                  (catch #t
                    (lambda () ($ scope-a 'merge-with fake gov-a) #f)
                    (lambda _ #t))))))))
  (check-pred "legit merge produced combined-aid (string)" (string? (cadr result)))
  (check-pred "fake counterparty rejected" (cadddr result)))

(display "\n── 2. admit-commune rejects fake commune ──\n")
(let ((result
       (run-in-vat
        (lambda ()
          (let* ((root-c   (spawn-scope-root "C"))
                 (commune  (spawn-scope "C" #:kind 'commune #:scope-aid "E_c"
                                           #:scope-root-ref root-c))
                 (fed      (spawn-scope "F" #:kind 'federation
                                            #:scope-aid "E_f"))
                 (gov-fed  ($ fed 'mint-gov-cap "fed-owner"))
                 (fake     (spawn (lambda (bcom)
                                    (methods
                                      [(scope-aid)   "E_evil"]
                                      [(name)        "evil"]
                                      [(commune-aid) "E_evil"])))))
            (list 'legit
                  (begin ($ fed 'admit-commune gov-fed "good" commune) 'ok)
                  'fake-rejected?
                  (catch #t
                    (lambda ()
                      ($ fed 'admit-commune gov-fed "evil" fake) #f)
                    (lambda _ #t))))))))
  (check-pred "legit admit-commune ok" (eq? 'ok (cadr result)))
  (check-pred "fake commune rejected" (cadddr result)))

(display "\n── Results: brand checks complete ──\n")
