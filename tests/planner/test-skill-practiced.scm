;;; test-skill-practiced.scm — observer earned-skills + practiced-hours (Stage 3)
;;;
;;; Skills are a DERIVED view over the work-event log: earned-skills = distinct
;;; resource-conforms-to of an agent's work events; practiced-hours = the SAME
;;; validated-effort fold the credit ledger (validated-gross) uses, restricted
;;; to one skill — so the two can never diverge.
;;;
;;; Run: guile -L module tests/planner/test-skill-practiced.scm

(use-modules (playnet test harness))
(use-modules (playnet planner scope root) (playnet planner vf schemas))
(use-modules (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1))

;; Register a recipient-side work intent for HOURS of SKILL and record a work
;; event (provider AID) that fully satisfies it (Validation Gate → fraction 1.0).
(define (work! obs aid skill hours event-id intent-id)
  ($ obs 'register-intent
     (make-intent #:id intent-id #:action 'work #:resource-conforms-to skill
                  #:effort-quantity (make-measure hours "hour") #:provider aid))
  ($ obs 'record-event
     (make-economic-event
       #:id event-id #:action 'work #:resource-conforms-to skill
       #:provider aid #:effort-quantity (make-measure hours "hour") #:has-point-in-time "2026-03-01T08:00:00Z" #:satisfies intent-id)))

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env
    (lambda () (spawn-scope-root "Skill Practiced Test")) store))

(display "\n── earned-skills: distinct skills from the work log ──\n")
(with-vat vat
  (let ((obs ($ scope 'observer)))
    (work! obs "ada" "spec:surgeon" 10 "ev-a1" "in-a1")
    (work! obs "ada" "spec:surgeon" 15 "ev-a2" "in-a2")   ; 2nd surgeon ⇒ deduped
    (work! obs "ada" "spec:baker"    5 "ev-a3" "in-a3")
    (work! obs "bob" "spec:surgeon"  8 "ev-b1" "in-b1")
    (let ((ada-skills ($ obs 'earned-skills "ada")))
      (check "ada has 2 distinct skills" (length ada-skills) 2)
      (check-pred "ada holds surgeon" (member "spec:surgeon" ada-skills))
      (check-pred "ada holds baker"   (member "spec:baker"   ada-skills)))
    (check "bob has 1 skill" (length ($ obs 'earned-skills "bob")) 1)
    (check-pred "carol has none" (null? ($ obs 'earned-skills "carol")))

    (display "\n── practiced-hours: validated sum per skill ──\n")
    (check "ada surgeon = 25" ($ obs 'practiced-hours "ada" "spec:surgeon") 25)
    (check "ada baker = 5"    ($ obs 'practiced-hours "ada" "spec:baker") 5)
    (check "bob surgeon = 8"  ($ obs 'practiced-hours "bob" "spec:surgeon") 8)
    (check "ada welder = 0 (none)" ($ obs 'practiced-hours "ada" "spec:welder") 0)

    (display "\n── no divergence from the credit ledger ──\n")
    ;; practiced-hours summed over a worker's skills == validated-gross for that
    ;; worker (both fold the same validated-effort over the same work events).
    (check "ada per-skill sum == validated-gross"
           (+ ($ obs 'practiced-hours "ada" "spec:surgeon")
              ($ obs 'practiced-hours "ada" "spec:baker"))
           ($ obs 'validated-gross "ada"))))

(display "\n")
(test-summary!)
