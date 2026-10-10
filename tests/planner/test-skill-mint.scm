;;; test-skill-mint.scm — mint-on-first-work hook (Stage 4)
;;;
;;; The observer on-event callback (make-credentialing-on-event) issues a
;;; work-event ACDC per work event and mints a skill membership ACDC ONCE per
;;; (worker, skill), edged to the founding work event.
;;;
;;; Constructs ACDCs ⇒ needs blake3. Run:
;;;   GUIX_ENVIRONMENT=<profile-with-libblake3> guile -L module \
;;;     tests/planner/test-skill-mint.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet planner observation observer) (playnet planner vf schemas))
(use-modules (playnet governance acdc-bridge) (playnet credentials work) (playnet keri acdc) (playnet keri acdc) (playnet keri acdc-store))
(use-modules (goblins) (goblins vat) (srfi srfi-1))

(define (rec-work! obs aid skill hours eid)
  ($ obs 'record-event
     (make-economic-event
       #:id eid #:action 'work #:resource-conforms-to skill #:provider aid #:effort-quantity (make-measure hours %effort-unit) #:has-point-in-time "2026-03-01T08:00:00Z")))

(define (skills-for acdc skill)
  (filter (lambda (c) (equal? (cred-claim c 'skill) skill))
          ($ acdc 'by-schema *schema-playnet-skill*)))

(define vat (spawn-vat))
(with-vat vat
  (let ((acdc (spawn-acdc-store))
        (obs  (spawn ^observer (empty-observer-state) '())))
    ($ obs 'set-on-event (make-credentialing-on-event acdc "EScope"))

    (display "\n── First work mints the skill ──\n")
    (rec-work! obs "EAda" "spec:surgeon" 10 "ev1")
    (let ((s (skills-for acdc "spec:surgeon")))
      (check "one surgeon skill minted" (length s) 1)
      (check "issuer is the scope"      (cred-issuer (car s)) "EScope")
      (check "holder is the worker"     (cred-holder (car s)) "EAda")
      (let ((e (cred-edge (car s) 'founding-event)))
        (check-pred "skill edges to a founding work event" (pair? e))))
    (check "one work-event ACDC issued"
           (length ($ acdc 'by-schema *schema-playnet-work-event*)) 1)

    (display "\n── Repeat work does NOT re-mint (mint-once) ──\n")
    (rec-work! obs "EAda" "spec:surgeon" 5 "ev2")
    (check "still exactly one surgeon skill" (length (skills-for acdc "spec:surgeon")) 1)
    (check "but two work-event ACDCs (one per event)"
           (length ($ acdc 'by-schema *schema-playnet-work-event*)) 2)

    (display "\n── A different skill mints its own token ──\n")
    (rec-work! obs "EAda" "spec:baker" 3 "ev3")
    (check "ada now holds baker too" (length (skills-for acdc "spec:baker")) 1)
    (check "two distinct skills total for ada"
           (length (filter (lambda (c) (equal? (cred-holder c) "EAda"))
                           ($ acdc 'by-schema *schema-playnet-skill*))) 2)

    (display "\n── Another worker, same skill: separate token ──\n")
    (rec-work! obs "EBob" "spec:surgeon" 8 "ev4")
    (check "two surgeon skill tokens (ada + bob)"
           (length (skills-for acdc "spec:surgeon")) 2)
    (check-pred "skill-held? sees ada's surgeon"
                (skill-held? acdc "EAda" "spec:surgeon"))
    (check-pred "skill-held? false for carol" (not (skill-held? acdc "ECarol" "spec:surgeon")))))

(display "\n")
(test-summary!)
