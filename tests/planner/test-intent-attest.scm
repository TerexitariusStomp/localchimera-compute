;;; test-intent-attest.scm — intent/commitment attestation + lift (follow-on #1)
;;;
;;; The plan-store on-intent/on-commitment callbacks issue intent + commitment
;;; ACDCs; lifting them recovers the DESIRED quantities the credit Validation Gate
;;; needs for its satisfied-fraction, and the plan membership that makes the
;;; open-intent side reconstructable from portable creds alone (caveat 1).
;;; Constructs ACDCs ⇒ needs blake3:
;;;   GUIX_ENVIRONMENT=<profile-with-libblake3> guile -L module \
;;;     tests/planner/test-intent-attest.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet plan store) (playnet vf schemas))   ; slim records (Intent/Measure) — same identity governance uses
;; the relational fact-lifting layer is retired; pull only the lift fns (they read
;; credential alists, not records, so record identity is irrelevant here)
(use-modules ((playnet deprecated planner)
              #:select (lift-intent-facts lift-commitment-facts)))
(use-modules (playnet observation credentials) (playnet credentials commitments) (playnet keri acdc-store))
(use-modules (goblins) (goblins vat) (srfi srfi-1))

(define vat (spawn-vat))
(with-vat vat
  (let* ((acdc (spawn-acdc-store))
         (cbs  (make-plan-credentialing-callbacks acdc "EScope"))
         (ps   (spawn ^plan-store (empty-plan-store-state) cbs)))

    (display "\n── Intent attested with its desired quantity ──\n")
    ;; receiver-side work need: 10h of surgeon at the clinic, in plan-x
    ($ ps 'add-intent (make-intent #:id "i1" #:action 'work #:input-of "proc-1"
                                   #:resource-conforms-to "spec:surgeon"
                                   #:effort-quantity (make-measure 10 %effort-unit) #:receiver "clinic"
                                   #:at-location "clinic" #:planned-within "plan-x"))
    (let* ((icreds ($ acdc 'by-schema *schema-playnet-intent*))
           (facts  (lift-intent-facts icreds)))
      (check "one intent ACDC issued" (length icreds) 1)
      (check-pred "lifts to attested-intent" (eq? 'attested-intent (caar facts)))
      (let ((f (car facts)))   ; (attested-intent id action conforms-to res-qty eff-qty plan-id)
        (check "intent id"         (list-ref f 1) "i1")
        (check "conforms-to skill" (list-ref f 3) "spec:surgeon")
        (check "DESIRED effort = 10 (the credit-fraction input)" (list-ref f 5) 10)
        (check "plan membership"   (list-ref f 6) "plan-x")))

    (display "\n── Commitment attested + satisfies link ──\n")
    ($ ps 'add-commitment (make-commitment #:id "c1" #:action 'work #:input-of "proc-1"
                                           #:resource-conforms-to "spec:surgeon"
                                           #:effort-quantity (make-measure 10 %effort-unit)
                                           #:provider "doc" #:receiver "clinic" #:satisfies "i1"
                                           #:planned-within "plan-x"))
    (let* ((ccreds ($ acdc 'by-schema *schema-playnet-commitment*))
           (f (car (lift-commitment-facts ccreds))))
      (check "one commitment ACDC issued" (length ccreds) 1)
      ;; (attested-commitment id action conforms-to eff-qty plan-id satisfies)
      (check "commitment id"    (list-ref f 1) "c1")
      (check "effort = 10"      (list-ref f 4) 10)
      (check "satisfies intent" (list-ref f 6) "i1"))

    (display "\n── The open-intent side of the plan is reconstructable ──\n")
    ;; intent + its desired qty recoverable from the portable creds alone — no
    ;; server state — which is the caveat-1 gap the work-event chain couldn't close.
    (check "plan-x work-intent recovered from creds"
           (length (filter (lambda (f) (equal? "plan-x" (list-ref f 6)))
                           (lift-intent-facts ($ acdc 'by-schema *schema-playnet-intent*))))
           1)))

(display "\n")
(test-summary!)
