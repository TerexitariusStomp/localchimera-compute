;;; test-settlement-chain.scm — consumption side on the distributable substrate
;;;
;;; The bridge attests individually-claimable `transfer` events (credit draws) just
;;; as it attests work events (contribution). So credit-balance = gross (work-event
;;; ACDCs) − claimed (claim ACDCs) reconstructs from the ACDC set ALONE — BOTH
;;; halves of the ledger, contribution and consumption symmetric. Proven == the
;;; observer's own credit-balance.
;;; Constructs ACDCs ⇒ run under the canonical runner:
;;;   guix shell -L deploy/guix -m deploy/manifests/dev-test-manifest.scm -- \
;;;     guile --no-auto-compile -L module tests/observation/test-settlement-chain.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet observation observer) (playnet vf schemas))
(use-modules (playnet observation credentials) (playnet credentials work) (playnet keri acdc) (playnet keri acdc) (playnet keri acdc-store))
(use-modules (goblins) (goblins vat) (srfi srfi-1))

;; CONTRIBUTION: recipient-side intent + a fully-satisfying work event (gross).
(define (work! obs aid skill hours eid iid)
  ($ obs 'register-intent
     (make-intent #:id iid #:action 'work #:resource-conforms-to skill
                  #:effort-quantity (make-measure hours %effort-unit) #:provider aid))
  ($ obs 'record-event
     (make-economic-event #:id eid #:action 'work #:resource-conforms-to skill #:provider aid
                          #:effort-quantity (make-measure hours %effort-unit)
                          #:has-point-in-time "2026-03-01T08:00:00Z" #:satisfies iid)))

;; CONSUMPTION: an individually-claimable transfer RECEIVED by AID (credit draw).
(define (claim! obs aid spec cost eid)
  ($ obs 'record-event
     (make-economic-event #:id eid #:action 'transfer #:resource-conforms-to spec #:resource-classified-as '("individually-claimable") #:receiver aid                                    ; provider #f, receiver = claimant
 #:effort-quantity (make-measure cost %effort-unit)             ; effort-quantity = credit drawn
 #:has-point-in-time "2026-03-02T08:00:00Z" #:in-scope-of '())))

(define vat (spawn-vat))
(with-vat vat
  (let ((acdc (spawn-acdc-store))
        (obs  (spawn ^observer (empty-observer-state) '())))
    ($ obs 'set-on-event (make-credentialing-on-event acdc "EScope"))

    (work!  obs "ada" "spec:surgeon" 10 "ev1" "in1")
    (work!  obs "ada" "spec:surgeon" 20 "ev2" "in2")   ; gross = 30
    (claim! obs "ada" "spec:bread"   10 "cl1")          ; claimed = 10 ⇒ balance 20

    (define work-creds  ($ acdc 'by-schema *schema-playnet-work-event*))
    (define claim-creds ($ acdc 'by-schema *schema-playnet-claim*))

    (display "\n── The consumption side is attested too ──\n")
    (check "one claim ACDC minted" (length claim-creds) 1)
    (check "claim holder is the claimant" (cred-holder (car claim-creds)) "ada")
    (check "claim records the credit drawn" (cred-claim (car claim-creds) 'labor-cost) 10)

    (display "\n── Both halves reconstruct offline ──\n")
    (check "reconstructed claimed = 10" (reconstruct-claimed-hours "ada" claim-creds) 10)
    (check "reconstructed credit-balance = 30 − 10 = 20"
           (reconstruct-credit-balance "ada" work-creds claim-creds) 20)

    (display "\n── Offline reconstruction EQUALS the observer's ledger ──\n")
    (check "credit-balance matches observer"
           (reconstruct-credit-balance "ada" work-creds claim-creds)
           ($ obs 'credit-balance "ada"))))

(display "\n")
(test-summary!)
