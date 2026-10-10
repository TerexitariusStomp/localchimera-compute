;;; test-compliance.scm — the SUPPLY side, over a REAL ^observer + a REAL bill.
;;;
;;; A permit/licence is an ordinary <economic-resource> conforming to a spec,
;;; held by an <agent>, expiring via its lot. holding-status folds the observer;
;;; reconcile joins a legal-demands bill to those holdings; obligations derives
;;; the renewal calendar. No new store — just queries over the observer.
;;;
;;; Pure data path (seed-resource, no ACDC) ⇒ no blake3.
;;; Run: guile -L module tests/observation/test-compliance.scm

(use-modules (playnet test harness) (playnet observation observer) (playnet vf schemas) (playnet vf beyond lot) (srfi srfi-1)
             (goblins) (goblins vat) (srfi srfi-1) (ice-9 format))

(use-modules (playnet legal crossings))
(use-modules (playnet legal registry))
(use-modules (playnet legal registry-actor))
(use-modules (playnet legal compliance))
(load (string-append (dirname (current-filename)) "/legal-example-rules.scm"))

;; a held credential = a resource conforming to the demand-name spec, held by an
;; agent, expiring via its lot. (Positional make-economic-resource: id name note
;; image tracking conforms-to classified accounting onhand loc vloc
;; primary-accountable custodian stage state contained-in unit lot prev avail.)
(define (held-credential id spec holder expiration)
  (make-economic-resource
    #:id id #:name spec #:conforms-to spec #:classified-as '("credential")
    #:onhand-quantity (make-measure 1 "cert")
    #:primary-accountable holder #:state "active"
    #:lot (and expiration (make-batch-lot-record (string-append id ":lot") #f expiration))))

(define vat (spawn-vat))
(define out
  (with-vat vat
    (let ((obs (spawn ^observer (empty-observer-state) '())))
      ;; the adapter holds a food-establishment permit valid to 2027-03-01;
      ;; one cook holds a valid handler card, another an EXPIRED one; nobody
      ;; holds the phytosanitary cert.
      ($ obs 'seed-resource (held-credential "res:permit" "Retail Food Permit" "adapter:foodco" "2027-03-01"))
      ($ obs 'seed-resource (held-credential "res:card-ada" "Food Handler Card" "person:ada" "2027-01-01"))
      ($ obs 'seed-resource (held-credential "res:card-bob" "Food Handler Card" "person:bob" "2025-01-01"))
      (list
       ;; ── holding-status, folded as-of 2026-07-14 ──
       (holding-status obs "adapter:foodco" "Retail Food Permit" "2026-07-14")   ; satisfied
       (holding-status obs "person:ada"     "Food Handler Card"  "2026-07-14")   ; satisfied
       (holding-status obs "person:bob"     "Food Handler Card"  "2026-07-14")   ; expired
       (holding-status obs "adapter:foodco" "Phytosanitary Cert" "2026-07-14")   ; missing
       (holding-status obs "adapter:foodco" "Retail Food Permit" "2027-06-01")   ; expired (future)
       ;; ── reconcile a real bill (food retail @ alameda) ──
       (let* ((ctx (activity-context '(public-sale) 'us-ca-alameda #:act 'food)))
         (call-with-values (lambda () (legal-demands ctx #:rules *example-rules*))
           (lambda (bill hits)
             (reconcile bill hits obs "2026-07-14"
                        #:subject-of (lambda (d kind)
                                       (if (eq? kind 'obtain-person) "person:ada" "adapter:foodco"))))))
       ;; ── obligations: renew the permit 60 days before its 2027-03-01 expiry ──
       (obligations obs "adapter:foodco"
                    '(("Retail Food Permit" renew-before . 60))
                    "auth:acdeh" "2026-07-14" "2027-12-31")))))

(define st-permit  (list-ref out 0))
(define st-ada     (list-ref out 1))
(define st-bob     (list-ref out 2))
(define st-phyto   (list-ref out 3))
(define st-future  (list-ref out 4))
(define recon      (list-ref out 5))
(define obs-list   (list-ref out 6))

(display "\n── holding-status: a fold over the observer, as-of a date ──\n")
(check "adapter holds a valid food permit"      st-permit 'satisfied)
(check "ada holds a valid handler card"         st-ada    'satisfied)
(check "bob's handler card has expired"         st-bob    'expired)
(check "nobody holds the phytosanitary cert"    st-phyto  'missing)
(check "the permit is expired as-of a future date past its lot" st-future 'expired)

(display "\n── reconcile: the demand bill ⋈ holdings ──\n")
(format #t "  reconciliation: ~s\n" recon)
(let ((perm (find (lambda (e) (equal? (caddr e) "Retail Food Permit")) recon))
      (card (find (lambda (e) (equal? (caddr e) "Food Handler Card")) recon)))
  (check-pred "the bill required a Retail Food Permit" (and perm #t))
  (check "…and it is satisfied (adapter holds it)"  (entry-status perm) 'satisfied)
  (check-pred "the bill required a Food Handler Card" (and card #t))
  (check "…and it is satisfied (ada holds it)"      (entry-status card) 'satisfied))
(check-pred "no gaps in this reconciliation" (null? (reconcile-gaps recon)))

(display "\n── obligations: the renewal calendar, derived ──\n")
(format #t "  obligations: ~s\n"
        (map (lambda (c) (list (commitment-id c) (commitment-due c))) obs-list))
(check "one renewal obligation for the permit" (length obs-list) 1)
(check "…due 60 days before the 2027-03-01 expiry" (commitment-due (car obs-list)) "2026-12-31")
(check-pred "…its receiver is the authority agent"
            (equal? (commitment-receiver (car obs-list)) "auth:acdeh"))

(display "\n")
(test-summary!)
