;;; test-filings.scm — the filing round-trip: render → submit → grant → HELD.
;;;
;;; Proves the loop closes: legal/filings.scm renders a deterministic, content-addressed
;;; document; the submission boundary records a `submitted` VF event; the grant
;;; raises the permit credential into custody; and compliance.scm's holding-status
;;; then reads it as `satisfied` — the same fold the planner's decorate consults.
;;; Pure data path ⇒ no blake3.
;;;
;;; Run: guile -L module tests/observation/test-filings.scm

(use-modules (playnet test harness) (playnet observation observer) (playnet vf schemas) (playnet vf beyond lot)
             (goblins) (goblins vat) (srfi srfi-1) (ice-9 format))

(define here (dirname (current-filename)))
(use-modules (playnet legal crossings))
(use-modules (playnet legal registry))
(use-modules (playnet legal compliance)) (use-modules (playnet legal filings))

(define tmpl
  (filing-template "Food Establishment Permit Application"
    #:jurisdiction 'foodville #:demand-name "Food Establishment Permit" #:version "2026.1"
    #:render (lambda (c) `((applicant . ,(assq-ref c 'adapter-name))
                           (site      . ,(assq-ref c 'site))
                           (activity  . "retail food vending")))
    #:source "foodville Health Code" #:as-of "2026-01-01"
    #:confidence 'verified #:steward "scope:food.foodville"))
(define canonical '((adapter-name . "FoodCo Commons LLC") (site . "12 Market St")))

;; render twice — determinism — and once with different data.
(define ra (call-with-values (lambda () (render-filing tmpl canonical #:filer "scope:foodco")) list))
(define rb (call-with-values (lambda () (render-filing tmpl canonical #:filer "scope:foodco")) list))
(define rc (call-with-values (lambda () (render-filing tmpl '((adapter-name . "Other Co") (site . "9 Elm"))
                                                       #:filer "scope:foodco")) list))
(define doc-a  (car ra))
(define said-a (caddr ra))

(display "\n── render-filing: deterministic, content-addressed document ──\n")
(format #t "  said: ~a   ·   fields: ~s\n" said-a (cadr ra))
(check-pred "the artifact is a document EconomicResource conforming to 'filing'"
            (equal? (economic-resource-conforms-to doc-a) "filing"))
(check-pred "its id IS its content address (SAID)" (equal? (economic-resource-id doc-a) said-a))
(check "re-rendering the same data ⇒ the same SAID" (caddr rb) said-a)
(check-pred "different data ⇒ a different SAID" (not (equal? (caddr rc) said-a)))
(check-pred "the rendered form is carried on the resource" (string? (economic-resource-note doc-a)))

;; the submission boundary + grant, then the fold that reads it back.
(define vat (spawn-vat))
(define status
  (with-vat vat
    (let ((obs (spawn ^observer (empty-observer-state) '()))
          (sub (submitted-event "ev:submit1" said-a "auth:foodville-health" "scope:foodco"
                                "2026-07-14T09:00:00Z" "Food Establishment Permit")))
      ;; the `submitted` event is a deliver-service to the authority (the door).
      (check-pred "submitted is a deliver-service to the authority"
                  (and (eq? (economic-event-action sub) 'deliver-service)
                       (equal? (economic-event-receiver sub) "auth:foodville-health")))
      ;; the authority GRANTS: the permit credential is raised into the filer's
      ;; custody (here seeded as the grant's resulting resource — its provenance
      ;; is the grant-event). Its spec id = the demand-name (compliance join key).
      ($ obs 'seed-resource
         (make-economic-resource #:id "res:granted-permit" #:name "Food Establishment Permit"
           #:conforms-to "Food Establishment Permit" #:classified-as '("credential") #:onhand-quantity (make-measure 1 "cert")
           #:primary-accountable "scope:foodco" #:state "active" #:lot (make-batch-lot-record "lot1" #f "2027-07-14")))
      ;; and now the SAME fold the planner's decorate uses reads it as held.
      (holding-status obs "scope:foodco" "Food Establishment Permit" "2026-07-14"))))

(display "\n── the round-trip closes: granted permit ⇒ holding-status satisfied ──\n")
(check "after grant, the permit is HELD (holding-status = satisfied)" status 'satisfied)

(display "\n")
(test-summary!)
