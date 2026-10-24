;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-scope-credentialing.scm — the substrate, wired into a LIVE scope
;;;
;;; Drives a real spawn-scope-root with install-credentialing!: planner events
;;; (intent added, work recorded, credit drawn) flow through the actual observer
;;; + plan-store, and the on-event / on-intent / on-commitment hooks mint the
;;; whole credential family. Then the full credit-balance reconstructs from the
;;; ACDC store and EQUALS the live observer's. This is the integration proof that
;;; the substrate is turned on, not just unit-tested.
;;; Constructs ACDCs ⇒ run under the canonical runner:
;;;   guix shell -L deploy/guix -m deploy/manifests/dev-test-manifest.scm -- \
;;;     guile --no-auto-compile -L module tests/scope/test-scope-credentialing.scm

(use-modules ((localchimera utils units) #:select (%effort-unit)))
(use-modules (localchimera test harness))
(use-modules (localchimera scope root) (localchimera vf schemas))
(use-modules (localchimera observation credentials) (localchimera boot scope) (localchimera credentials commitments) (localchimera credentials work) (localchimera keri acdc-store))
(use-modules (goblins) (goblins vat) (srfi srfi-1))

(define vat (spawn-vat))
(with-vat vat
  (let* ((sr   (spawn-scope-root "Wired Scope"))
         (acdc (spawn-acdc-store)))
    ;; turn the substrate ON for this scope
    (install-credentialing! sr acdc "EScope")
    (let ((obs ($ sr 'observer))
          (ps  ($ sr 'plan-store)))

      ;; CONTRIBUTION: a work intent (→ on-intent: register-intent + intent ACDC),
      ;; satisfied by a work event (→ on-event: work-event + skill ACDCs). gross=30.
      ($ ps 'add-intent
         (make-intent #:id "in1" #:action 'work #:resource-conforms-to "spec:surgeon"
                      #:effort-quantity (make-measure 30 %effort-unit) #:provider "ada"))
      ($ obs 'record-event
         (make-economic-event #:id "ev1" #:action 'work #:resource-conforms-to "spec:surgeon"
                              #:provider "ada" #:effort-quantity (make-measure 30 %effort-unit)
                              #:has-point-in-time "2026-03-01T08:00:00Z" #:satisfies "in1"
                              #:in-scope-of '()))

      ;; CONSUMPTION: an individually-claimable transfer received by ada. claimed=10.
      ($ obs 'record-event
         (make-economic-event #:id "cl1" #:action 'transfer #:resource-conforms-to "spec:bread"
           #:resource-classified-as '("individually-claimable") #:receiver "ada" #:effort-quantity (make-measure 10 %effort-unit) #:has-point-in-time "2026-03-02T08:00:00Z" #:in-scope-of '()))

      (define (creds schema) ($ acdc 'by-schema schema))

      (display "\n── A live scope mints the whole credential family ──\n")
      (check "work-event ACDC issued"  (length (creds *schema-localchimera-work-event*)) 1)
      (check "skill ACDC minted"       (length (creds *schema-localchimera-skill*)) 1)
      (check "intent ACDC issued"      (length (creds *schema-localchimera-intent*)) 1)
      (check "claim ACDC issued"       (length (creds *schema-localchimera-claim*)) 1)

      (display "\n── on-intent still forwards to the Validation Gate ──\n")
      ;; the composed hook ran register-intent, so the work validated (gross 30)
      (check "validated gross = 30" ($ obs 'validated-gross "ada") 30)

      (display "\n── Full credit-balance reconstructs from the store == observer ──\n")
      (check "observer credit-balance = 30 − 10 = 20" ($ obs 'credit-balance "ada") 20)
      (check "reconstructed credit-balance matches the live observer"
             (reconstruct-credit-balance "ada"
                                         (creds *schema-localchimera-work-event*)
                                         (creds *schema-localchimera-claim*))
             ($ obs 'credit-balance "ada")))))

;; ── a duration is counted in hours wherever it is read ──────────────────────
;; Ninety minutes of work is an hour and a half to the observer and, rebuilt from the
;; credentials the event minted, to the store: the credential states the hours.
(with-vat (spawn-vat)
  (let* ((sr   (spawn-scope-root "Minutes Scope"))
         (acdc (spawn-acdc-store)))
    (install-credentialing! sr acdc "EScope")
    (let ((obs ($ sr 'observer)) (ps ($ sr 'plan-store)))
      ($ ps 'add-intent
         (make-intent #:id "in2" #:action 'work #:resource-conforms-to "spec:weld"
                      #:effort-quantity (make-measure 1.5 %effort-unit) #:provider "cy"))
      ($ obs 'record-event
         (make-economic-event #:id "ev2" #:action 'work #:resource-conforms-to "spec:weld"
                              #:provider "cy" #:effort-quantity (make-measure 90 "minute")
                              #:has-point-in-time "2026-03-01T08:00:00Z" #:satisfies "in2"
                              #:in-scope-of '()))
      (display "\n── a duration is counted in hours wherever it is read ──\n")
      (define (near-1.5? x) (< (abs (- x 1.5)) 1e-9))
      (check-pred "the observer counts ninety minutes as 1.5 hours" (near-1.5? ($ obs 'validated-gross "cy")))
      (check-pred "the credentials rebuild to the same 1.5"
                  (near-1.5? (reconstruct-credit-balance "cy" ($ acdc 'by-schema *schema-localchimera-work-event*)
                                                         ($ acdc 'by-schema *schema-localchimera-claim*)))))))

;; ── spawn-commune turns the substrate on by itself (no manual install) ───────
(with-vat (spawn-vat)
  (let* ((sr   (spawn-scope-root "Commune Scope"))
         (acdc (spawn-acdc-store))
         (_    (spawn-commune "C1" sr #:commune-aid "ECommune" #:acdc-store acdc)))
    (display "\n── spawn-commune auto-wires the substrate ──\n")
    ($ ($ sr 'observer) 'record-event
       (make-economic-event #:id "wev" #:action 'work #:resource-conforms-to "spec:weld"
                            #:provider "bob" #:effort-quantity (make-measure 5 %effort-unit)
                            #:has-point-in-time "2026-03-03T08:00:00Z" #:in-scope-of '()))
    (check "commune auto-minted a work-event ACDC"
           (length ($ acdc 'by-schema *schema-localchimera-work-event*)) 1)
    (check "commune auto-minted bob's skill ACDC"
           (length ($ acdc 'by-schema *schema-localchimera-skill*)) 1)))

(display "\n")
(test-summary!)
