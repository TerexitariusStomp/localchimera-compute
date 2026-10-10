;;; test-edge-chain.scm — full per-work-event edge-chaining (follow-on #2)
;;;
;;; Every work event after the founding one edges to its skill ACDC, so a skill's
;;; whole history is one offline-walkable graph. We record work through the
;;; observer (which mints + edge-chains via the callback), then RECONSTRUCT
;;; earned-skills / practiced-hours from the ACDC set ALONE and show they equal
;;; the observer's own (server-side) views — the fold made distributable.
;;; Constructs ACDCs ⇒ needs blake3:
;;;   GUIX_ENVIRONMENT=<profile-with-libblake3> guile -L module \
;;;     tests/planner/test-edge-chain.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet observation observer) (playnet vf schemas) (srfi srfi-1))
(use-modules (playnet observation credentials) (playnet credentials work) (playnet keri acdc) (playnet keri acdc) (playnet keri acdc-store))
(use-modules (goblins) (goblins vat) (srfi srfi-1))

;; recipient-side intent + a fully-satisfying work event (Validation Gate ⇒ 1.0)
(define (work! obs aid skill hours eid iid)
  ($ obs 'register-intent
     (make-intent #:id iid #:action 'work #:resource-conforms-to skill
                  #:effort-quantity (make-measure hours %effort-unit) #:provider aid))
  ($ obs 'record-event
     (make-economic-event #:id eid #:action 'work #:resource-conforms-to skill #:provider aid
                          #:effort-quantity (make-measure hours %effort-unit)
                          #:has-point-in-time "2026-03-01T08:00:00Z" #:satisfies iid)))

(define vat (spawn-vat))
(with-vat vat
  (let ((acdc (spawn-acdc-store))
        (obs  (spawn ^observer (empty-observer-state) '())))
    ($ obs 'set-on-event (make-credentialing-on-event acdc "EScope"))

    ;; ada does surgery three times (10+15+20) and bakes once (5)
    (work! obs "ada" "spec:surgeon" 10 "ev1" "in1")
    (work! obs "ada" "spec:surgeon" 15 "ev2" "in2")
    (work! obs "ada" "spec:surgeon" 20 "ev3" "in3")
    (work! obs "ada" "spec:baker"    5 "ev4" "in4")

    (define work-creds  ($ acdc 'by-schema *schema-playnet-work-event*))
    (define skill-creds ($ acdc 'by-schema *schema-playnet-skill*))
    (define surgeon (find (lambda (c) (and (equal? (cred-holder c) "ada")
                                           (equal? (cred-claim c 'skill) "spec:surgeon")))
                          skill-creds))

    (display "\n── The skill's work history is walkable from edges alone ──\n")
    (check "all three surgeries reachable from the skill cred"
           (length (work-events-for-skill surgeon work-creds)) 3)
    (check-pred "later events carry a skill edge (not the founding one)"
                (= 2 (length (filter (lambda (we) (cred-edge we 'skill)) work-creds))))

    (display "\n── Reconstruct the observer's views offline (no server state) ──\n")
    (check "reconstructed earned-skills = {surgeon, baker}"
           (sort (reconstruct-earned-skills "ada" skill-creds) string<?)
           '("spec:baker" "spec:surgeon"))
    (check "reconstructed surgeon hours = 45" (reconstruct-practiced-hours surgeon work-creds) 45)

    (display "\n── Offline reconstruction EQUALS the server's own fold ──\n")
    (check "earned-skills matches observer"
           (sort (reconstruct-earned-skills "ada" skill-creds) string<?)
           (sort ($ obs 'earned-skills "ada") string<?))
    (check "practiced-hours matches observer"
           (reconstruct-practiced-hours surgeon work-creds)
           ($ obs 'practiced-hours "ada" "spec:surgeon"))))

(display "\n")
(test-summary!)
