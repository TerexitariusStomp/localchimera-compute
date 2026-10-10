;;; test-filings-boundary.scm — template provenance + dry-run + submission drivers.
;;;
;;; (1) render-filing stamps the template's PROVENANCE onto the artifact.
;;; (2) filing-preview is a DRY-RUN: it renders what WOULD be filed and flags
;;;     whether it is submittable (verified) or needs review — no side effect.
;;; (3) submit-filing rides the `submitted` boundary: pending-human by default,
;;;     or driven where an authority exposes a clean API. Pure data ⇒ no blake3.
;;;
;;; Run: guile -L module tests/legal/test-filings-boundary.scm

(use-modules (playnet test harness) (playnet vf schemas) (srfi srfi-1) (ice-9 format))

(use-modules (playnet legal crossings))
(use-modules (playnet legal registry))
(use-modules (playnet legal compliance)) (use-modules (playnet legal filings))

(define verified-tmpl
  (filing-template "Food Establishment Permit Application"
    #:jurisdiction 'foodville #:demand-name "Food Establishment Permit" #:version "2026.1"
    #:render (lambda (c) `((applicant . ,(assq-ref c 'adapter-name)) (site . ,(assq-ref c 'site))))
    #:source "foodville Health Code §4" #:as-of "2026-01-01"
    #:confidence 'verified #:steward "scope:food.foodville"))
(define reported-tmpl                         ; not yet steward-verified
  (filing-template "Draft Vendor Registration" #:jurisdiction 'newtown
    #:demand-name "Vendor Registration"
    #:render (lambda (c) `((applicant . ,(assq-ref c 'adapter-name))))
    #:source "(scraped, unconfirmed)" #:confidence 'reported #:steward "scope:legal"))
(define canonical '((adapter-name . "FoodCo Commons LLC") (site . "12 Market St")))

;;; ─── (1) provenance stamped on the artifact ──────────────────────────────
(define doc (call-with-values (lambda () (render-filing verified-tmpl canonical #:filer "scope:foodco"))
              (lambda (r f s) r)))
(define cls (economic-resource-classified-as doc))
(display "\n── (1) the rendered artifact carries its template's provenance ──\n")
(format #t "  classified-as: ~s\n" cls)
(check-pred "the filing is tagged with its confidence grade" (member "confidence:verified" cls))
(check-pred "…its source"  (member "source:foodville Health Code §4" cls))
(check-pred "…its steward" (member "steward:scope:food.foodville" cls))

;;; ─── (2) dry-run preview ─────────────────────────────────────────────────
(define pv-ok  (filing-preview verified-tmpl canonical #:filer "scope:foodco"))
(define pv-warn(filing-preview reported-tmpl canonical #:filer "scope:foodco"))
(display "\n── (2) dry-run: preview what WOULD be filed, no side effect ──\n")
(format #t "  verified: submittable=~s caveat=~s\n" (assq-ref pv-ok 'submittable) (assq-ref pv-ok 'caveat))
(format #t "  reported: submittable=~s caveat=~s\n" (assq-ref pv-warn 'submittable) (assq-ref pv-warn 'caveat))
(check-pred "the preview carries the rendered fields + SAID + provenance"
            (and (assq-ref pv-ok 'fields) (assq-ref pv-ok 'said) (assq-ref pv-ok 'provenance)))
(check-pred "a VERIFIED template is submittable, no caveat"
            (and (assq-ref pv-ok 'submittable) (not (assq-ref pv-ok 'caveat))))
(check-pred "a REPORTED template is NOT submittable — a caveat flags review"
            (and (not (assq-ref pv-warn 'submittable)) (string? (assq-ref pv-warn 'caveat))))
(check "the preview's provenance grade matches the template"
       (assq-ref (assq-ref pv-ok 'provenance) 'confidence) 'verified)

;;; ─── (3) submission boundary: manual by default, driver where an API exists ─
(define said (assq-ref pv-ok 'said))
(clear-submission-drivers!)
(define manual (submit-filing #:filing-said said #:authority "auth:foodville-health"
                              #:filer "scope:foodco" #:stamp "2026-07-16T09:00:00Z"
                              #:demand-name "Food Establishment Permit"))
;; an authority WITH a clean API: register a driver that grants a credential.
(register-submission-driver! "auth:efile-state"
  (lambda (fsaid authority filer stamp demand-name)
    `((status . granted)
      (credential . ,(make-economic-resource #:id (string-append "cred:" fsaid) #:name demand-name
                       #:conforms-to demand-name #:classified-as '("credential") #:onhand-quantity (make-measure 1 "cert")
                       #:primary-accountable filer #:state "active")))))
(define driven (submit-filing #:filing-said said #:authority "auth:efile-state"
                              #:filer "scope:foodco" #:stamp "2026-07-16T09:00:00Z"
                              #:demand-name "Food Establishment Permit"))

(display "\n── (3) submit-filing: manual boundary vs. API driver ──\n")
(format #t "  no driver → via=~s status=~s\n" (assq-ref manual 'via) (assq-ref manual 'status))
(format #t "  driver    → via=~s status=~s credential=~a\n" (assq-ref driven 'via) (assq-ref driven 'status)
        (and (assq-ref driven 'credential) (economic-resource-id (assq-ref driven 'credential))))
(check-pred "both paths emit the `submitted` boundary event (deliver-service to the authority)"
            (and (eq? (economic-event-action (assq-ref manual 'submitted)) 'deliver-service)
                 (eq? (economic-event-action (assq-ref driven 'submitted)) 'deliver-service)))
(check "no driver ⇒ pending-human (a front lodges it)" (assq-ref manual 'status) 'pending-human)
(check "no driver ⇒ via manual" (assq-ref manual 'via) 'manual)
(check "an API driver ⇒ granted, via driver" (list (assq-ref driven 'status) (assq-ref driven 'via))
       '(granted driver))
(check-pred "…and the driver returned the credential resource"
            (equal? (economic-resource-conforms-to (assq-ref driven 'credential)) "Food Establishment Permit"))

(display "\n")
(test-summary!)
