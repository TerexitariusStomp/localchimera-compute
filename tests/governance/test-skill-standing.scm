;;; test-skill-standing.scm — a declared skill, and what the record shows for it.
;;;
;;; A citizen is free to declare what they can do. What the profile shows
;;; beside each skill comes from other people, in hours: recipients validating
;;; the work (the observer's practiced-hours) and peers co-signing it (the
;;; multisig block on the work-event ACDC). This pins both halves:
;;;   • the fold — reconstruct-skill-attestation counts, per skill, the events,
;;;     the witnessed ones, the DISTINCT co-signers and the witnessed hours;
;;;   • the door — declare-skill / revoke-skill / skill-standing through
;;;     ^planner-service, with the witness door's `standing` read injected the
;;;     way the gateway injects it.

;; the host crypto backend: loading (playnet keri signify) installs it
(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules ((playnet keri signify) #:select ()))
(use-modules (playnet test harness))
(use-modules (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1))
(use-modules (playnet planner doors service))
(use-modules (playnet governance acdc-bridge) (playnet keri acdc-store) (playnet keri citizen-sig))
(use-modules ((playnet governance acdc-bridge)
              #:select (reconstruct-skill-attestation skill-attestation-standing
                        cred-attesters)))
(use-modules ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-aid keri-identity-keypair)))
(use-modules (goblins) (goblins utils hashmap) (rnrs bytevectors))
(use-modules (srfi srfi-1))

(define (fresh n) (make-keri-identity (make-bytevector 32 n)))
(define (signer id) (cons (keri-identity-aid id) (keri-identity-keypair id)))

(define (work-ev eid pid skill hours)
  (make-economic-event #:id eid #:action 'work #:output-of pid #:resource-conforms-to skill
                       #:provider "EAda" #:effort-quantity (make-measure hours %effort-unit)
                       #:has-point-in-time "2026-03-01T08:00:00Z"))

(define vat (spawn-vat))
(define store #f)

(define (row-of rows skill)
  (find (lambda (r) (equal? (assq-ref r 'skill) skill)) rows))

(display "\n── the fold: who co-signed which skill ──\n")

(with-vat vat
  (set! store (spawn-acdc-store))
  (let ((w1 (fresh 81)) (w2 (fresh 82)) (w3 (fresh 83)))
    ;; baking: two witnessed events (w1+w2, then w2+w3) and one unwitnessed
    (attest-contribution! store "EScope" (work-ev "b1" "p1" "skill-bake" 6.0)
                          #:witnesses (list (signer w1) (signer w2)))
    (attest-contribution! store "EScope" (work-ev "b2" "p2" "skill-bake" 4.0)
                          #:witnesses (list (signer w2) (signer w3)))
    (attest-contribution! store "EScope" (work-ev "b3" "p3" "skill-bake" 2.0))
    ;; plumbing: worked, never witnessed
    (attest-contribution! store "EScope" (work-ev "q1" "p4" "skill-plumb" 3.0))
    (let* ((st   (skill-attestation-standing store "EAda"))
           (bake (assoc-ref st "skill-bake"))
           (plmb (assoc-ref st "skill-plumb")))
      (check "three baking events stand"              (assq-ref bake 'events) 3)
      (check "two of them reached their witnesses"    (assq-ref bake 'witnessed) 2)
      (check "a witness counts once per skill: three people, four signatures"
             (assq-ref bake 'attesters) 3)
      (check "witnessed hours are the witnessed events' hours"
             (assq-ref bake 'witnessed-hours) 10.0)
      (check "unwitnessed work has events and no attesters"
             (list (assq-ref plmb 'events) (assq-ref plmb 'attesters)) '(1 0))
      (check "someone else's standing is empty"
             (skill-attestation-standing store "EBob") '()))))

(display "\n── witnessed work is one record across the scopes' stores ──\n")
(with-vat vat
  (let ((a (spawn-acdc-store)) (b (spawn-acdc-store))
        (w1 (fresh 91)) (w2 (fresh 92)))
    ;; ada baked at two scopes: two events at A (one witnessed), one at B (witnessed)
    (attest-contribution! a "EScopeA" (work-ev "c1" "q1" "skill-bake" 6.0) #:witnesses (list (signer w1) (signer w2)))
    (attest-contribution! a "EScopeA" (work-ev "c2" "q2" "skill-bake" 2.0))
    (attest-contribution! b "EScopeB" (work-ev "c3" "q3" "skill-bake" 4.0) #:witnesses (list (signer w1)))
    (let ((alone (assoc-ref (skill-attestation-standing a "EAda") "skill-bake"))
          (both  (assoc-ref (skill-attestation-standing a "EAda" b) "skill-bake")))
      (check "read at A alone: two events" (assq-ref alone 'events) 2)
      (check "read across A and B: three events" (assq-ref both 'events) 3)
      (check "two witnessed" (assq-ref both 'witnessed) 2)
      (check "a witness who co-signed at both counts once" (assq-ref both 'attesters) 2)
      (check "and the same store named twice is one store"
             (assq-ref (assoc-ref (skill-attestation-standing a "EAda" b b a) "skill-bake") 'events) 3))))

(display "\n── the door: a claim beside its evidence ──\n")

(with-vat vat
  (define scope (spawn-scope-root "Granary"))
  (define svc   (spawn ^planner-service (hashmap)))
  ($ ($ scope 'agent-store) 'add-agent
     (make-agent #:id "EAda" #:type 'person #:name "Ada" #:note "" #:image "" #:classified-as '()))
  ($ svc 'add-scope! "Granary" scope)
  ($ svc 'set-witness-door!
     `((standing . ,(lambda (scope-aid worker . scopes) (skill-attestation-standing store worker)))
       (outbox   . ,(lambda (worker)
                      (if (equal? worker "EAda")
                          '(((said . "ESaid") (count . 1) (quorum . 2)
                             (kind . work) (worker . "EAda") (skill . "skill-bake")))
                          '())))))

  (define (ok-rows r) (assq-ref (cdr r) 'standing))

  (check "a skill is free to declare"
         (car ($ svc 'declare-skill "Granary" "EAda" "skill-bake")) 'ok)
  (check "so is one with no work behind it"
         (car ($ svc 'declare-skill "Granary" "EAda" "early mornings")) 'ok)

  (let* ((rows (ok-rows ($ svc 'skill-standing "Granary" "EAda")))
         (bake (row-of rows "skill-bake"))
         (morn (row-of rows "early mornings"))
         (plmb (row-of rows "skill-plumb")))
    (check "a row carries no word of the citizen's own — only the record"
           (map car bake)
           '(skill held hours competence events witnessed attesters witnessed-hours pending))
    (check "three people co-signed the baking" (assq-ref bake 'attesters) 3)
    (check "a ceremony still collecting shows its count"
           (assq-ref bake 'pending) '(((count . 1) (quorum . 2))))
    (check "a skill with no work behind it stands as the citizen's word alone"
           (list (assq-ref morn 'held) (assq-ref morn 'hours) (assq-ref morn 'events) (assq-ref morn 'attesters))
           '(#t 0 0 0))
    (check "practice she never declared still shows, off the roster"
           (list (assq-ref plmb 'held) (assq-ref plmb 'events)) '(#f 1))
    (check "a declared skill is on the roster; practice never declared is not"
           (list (assq-ref bake 'held) (assq-ref morn 'held) (assq-ref plmb 'held)) '(#t #t #f)))

  (display "\n── holding, withdrawing ──\n")
  (check "declaring again is idempotent"
         (car ($ svc 'declare-skill "Granary" "EAda" "skill-bake")) 'ok)
  ($ svc 'revoke-skill "Granary" "EAda" "early mornings")
  (check "a withdrawn skill with no evidence leaves no row"
         (row-of (ok-rows ($ svc 'skill-standing "Granary" "EAda")) "early mornings") #f)
  (check "another citizen's standing carries none of hers"
         (ok-rows ($ svc 'skill-standing "Granary" "EBob")) '()))

(test-summary!)
