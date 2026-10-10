;;; test-bodies.scm — a legal body is its ValueFlows records, and the law reads
;;; it as the holder.
;;;
;;; Properties over legal/bodies.scm: who stands behind a body is a fold over
;;; <agent-relationship>s with the roles of knowledge/body-roles.scm; a closed
;;; register yields nobody; admission is the eight tests of
;;; docs/legal/structure.md §2 read as crossings, with the one refusal (two
;;; bodies selling the same good in the same place); and the solve's decorate
;;; asks the BODY for the policy a rule demands — under fr/rc-auto a body with
;;; a vehicle and no policy loses the ride column, the policy in its custody
;;; restores it, the same policy in another agent's custody does not.
;;;
;;; Run: guile -L module tests/scope/test-bodies.scm

(use-modules (playnet test harness)
             ((playnet utils units) #:select (%effort-unit))
             (playnet vf schemas)
             (playnet scope agents)
             (playnet scope spatial-things)
             (playnet observation observer)
             (playnet knowledge recipes store)
             (playnet legal registry) (playnet legal registry-actor)
             (playnet legal gate) (playnet legal compliance)
             (playnet legal bodies) (playnet knowledge body-roles)
             (playnet knowledge dsl findings)
             (playnet knowledge law context-pack)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (ice-9 format))

(define vat (spawn-vat))
(define scope "scope:kiez")
(define (facts . kv) kv)

(define (kinds-of findings kind)
  (filter (lambda (f) (eq? kind (finding-kind f))) findings))
(define (errors findings) (filter (lambda (f) (eq? 'error (finding-severity f))) findings))

;;; ─── who stands behind a body ────────────────────────────────────────────
(display "\n── roles and the register ──\n")
(define-values (stewards members reg-open reg-closed mine scope-list)
  (with-vat vat
    (let ((as (spawn ^agent-store (hashmap) (hashmap) (hashmap) '())))
      (declare-body! as scope "body:kitchen" "Kiez Kitchen e.V."
                     '((kind . association) (role . provider) (jurisdiction . "berlin")
                       (register . inspectable) (quorum . 2)))
      (declare-body! as scope "body:land" "Boden Trust"
                     '((kind . foundation) (role . title-holder) (jurisdiction . "berlin")
                       (asset-lock . "yes")))
      ;; stewards in a different order than members, and one person in both roles
      (body-add-steward! as scope "body:kitchen" "aid:bo")
      (body-add-steward! as scope "body:kitchen" "aid:ada")
      (body-add-member!  as scope "body:kitchen" "aid:ada")
      (body-add-member!  as scope "body:kitchen" "aid:cy")
      (body-add-steward! as scope "body:land" "aid:bo")
      (values (body-stewards as "body:kitchen")
              (body-members as "body:kitchen")
              (call-with-values (lambda () (body-register as ($ as 'get-agent "body:kitchen"))) list)
              (call-with-values (lambda () (body-register as ($ as 'get-agent "body:land"))) list)
              (map agent-id (bodies-of as "aid:bo"))
              (map agent-id (scope-bodies as scope))))))

(check-pred "the stewards are exactly those related by role:steward"
            (lset= equal? stewards '("aid:bo" "aid:ada")))
(check-pred "the members are exactly those related by role:member"
            (lset= equal? members '("aid:ada" "aid:cy")))
(check "an inspectable register names everyone in any role, once"
       (and (car reg-open) (sort (cadr reg-open) string<?)) '("aid:ada" "aid:bo" "aid:cy"))
(check "a closed register names nobody — the privacy read is the fold" reg-closed '(#f ()))
(check-pred "bodies-of lists every body a person holds a role in"
            (lset= equal? mine '("body:kitchen" "body:land")))
(check-pred "a declared body is a member of its scope"
            (lset= equal? scope-list '("body:kitchen" "body:land")))

;;; ─── the provisional id becomes the AID ──────────────────────────────────
(display "\n── close-body! rebinds the provisional id ──\n")
(define-values (after-old after-new rel-count)
  (with-vat vat
    (let ((as (spawn ^agent-store (hashmap) (hashmap) (hashmap) '())))
      (declare-body! as scope "body:prov" "Provisional" '((role . host)))
      (body-add-steward! as scope "body:prov" "aid:bo")
      (close-body! as scope "body:prov" "EBODYAID")
      (values ($ as 'get-agent "body:prov")
              (body-stewards as "EBODYAID")
              (length (filter (lambda (r) (or (equal? "body:prov" (agent-relationship-subject r))
                                               (equal? "body:prov" (agent-relationship-object r))))
                              ($ as 'all-relationships)))))))
(check "the provisional agent is gone" after-old #f)
(check "the steward relationship now names the AID" after-new '("aid:bo"))
(check "no relationship names the provisional id any more" rel-count 0)

;;; ─── admission as crossings ──────────────────────────────────────────────
(display "\n── admission: the eight tests as findings ──\n")
(define (admission declare!)
  (with-vat vat
    (let ((as (spawn ^agent-store (hashmap) (hashmap) (hashmap) '()))
          (obs (spawn ^observer (empty-observer-state) '())))
      (declare! as obs)
      (admission-findings as obs scope))))

(define provider-with-credit
  (admission (lambda (as obs)
               (declare-body! as scope "b:p" "Kitchen" '((role . provider) (jurisdiction . "berlin")
                                                        (crossings . (credit-contribution)))))))
(check "a provider that takes credited work has no error" (errors provider-with-credit) '())
(check-pred "…and the shield is noted on it"
            (pair? (kinds-of provider-with-credit 'shield)))

(define seller-with-credit
  (admission (lambda (as obs)
               (declare-body! as scope "b:s" "Shop" '((role . provider) (jurisdiction . "berlin")
                                                     (sells . ("bread"))
                                                     (crossings . (credit-contribution)))))))
(check-pred "a selling body that takes credited work is refused: unpaid wages"
            (pair? (kinds-of (errors seller-with-credit) 'unpaid-work)))
(check-pred "…and its selling itself is an error for a provider"
            (pair? (kinds-of (errors seller-with-credit) 'selling)))

(define two-sellers
  (admission (lambda (as obs)
               (declare-body! as scope "b:1" "Bakery A" '((role . seller) (jurisdiction . "berlin") (sells . ("bread"))))
               (declare-body! as scope "b:2" "Bakery B" '((role . seller) (jurisdiction . "berlin") (sells . ("bread" "cake"))))
               (declare-body! as scope "b:3" "Bakery C" '((role . seller) (jurisdiction . "hamburg") (sells . ("bread")))))))
(check "two sellers of one good in one place under one plan: exactly one refusal, naming both"
       (map finding-subject (kinds-of (errors two-sellers) 'selling)) '(("b:1" "b:2")))
(check-pred "a seller's own selling is only noted"
            (= 3 (length (filter (lambda (f) (eq? 'info (finding-severity f))) (kinds-of two-sellers 'selling)))))

(define unlocked-title
  (admission (lambda (as obs)
               (declare-body! as scope "b:t" "Land Co" '((role . title-holder) (jurisdiction . "berlin"))))))
(check-pred "a title holder with no asset lock is refused"
            (pair? (kinds-of (errors unlocked-title) 'lock)))
(define locked-title
  (admission (lambda (as obs)
               (declare-body! as scope "b:t" "Land Trust" '((role . title-holder) (jurisdiction . "berlin") (asset-lock . "yes"))))))
(check "the same body with an asset lock passes" (errors locked-title) '())

(define unincorporated
  (admission (lambda (as obs)
               (declare-body! as scope "b:u" "Neighbours" '((kind . unincorporated) (role . membership)))
               (body-present-holding! obs "b:u" "Lease" #:issuer "landlord"))))
(check-pred "an unincorporated group that holds something answers personally: refused"
            (pair? (kinds-of (errors unincorporated) 'person)))

(define voice-charity
  (admission (lambda (as obs)
               (declare-body! as scope "b:v" "Kitchen" '((role . provider) (crossings . (organise)))))))
(check-pred "a charity pressing a program is warned, not refused"
            (and (null? (errors voice-charity))
                 (any (lambda (f) (and (eq? 'voice (finding-kind f)) (eq? 'warning (finding-severity f))))
                      voice-charity)))

;;; ─── the registry identifier ─────────────────────────────────────────────
(display "\n── legal ids: the body carries its registry codes ──\n")
(define with-lei
  (with-vat vat
    (let ((as (spawn ^agent-store (hashmap) (hashmap) (hashmap) '())))
      (declare-body! as scope "body:lei" "GLEIF-like" '((role . provider) (jurisdiction . "berlin")
                                                        (legal-ids . ((lei . "506700GE1G29325QX363") (hrb . "12345")))))
      ($ as 'get-agent "body:lei"))))
(check "the codes read back as (scheme . code)" (body-legal-ids with-lei) '((lei . "506700GE1G29325QX363") (hrb . "12345")))
(check "the LEI reads by name" (body-lei with-lei) "506700GE1G29325QX363")
(check-pred "a valid LEI passes admission without a legal-id error"
            (null? (kinds-of (errors (admission (lambda (as obs)
                                                  (declare-body! as scope "b:l" "L" '((role . provider) (legal-ids . ((lei . "506700GE1G29325QX363"))))))))
                             'legal-id)))
(check-pred "a malformed LEI is an admission error"
            (pair? (kinds-of (errors (admission (lambda (as obs)
                                                  (declare-body! as scope "b:l" "L" '((role . provider) (legal-ids . ((lei . "506700GE1G29325QX364"))))))))
                             'legal-id)))
(check-pred "no registry id at all is a note, not an error"
            (let ((fs (admission (lambda (as obs) (declare-body! as scope "b:n" "N" '((role . provider)))))))
              (and (null? (kinds-of (errors fs) 'legal-id))
                   (any (lambda (f) (and (eq? 'legal-id (finding-kind f)) (eq? 'info (finding-severity f)))) fs))))
(check-pred "fewer than three stewards is a note"
            (any (lambda (f) (and (eq? 'stewards (finding-kind f)) (eq? 'info (finding-severity f))))
                 (admission (lambda (as obs) (declare-body! as scope "b:s" "S" '((role . provider)))))))

;;; ─── the law reads the body as the holder ────────────────────────────────
(display "\n── the decorate asks the body for the policy fr/rc-auto demands ──\n")
;; a ride recipe: `use` of a vehicle trips public-vehicle (legal/crossings.scm)
(define (seed-ride! rs)
  ($ rs 'add-resource-spec
     (make-resource-specification #:id "spec-van" #:name "Van"
                                  #:resource-classified-as '("vf:vehicle") #:default-unit-of-resource "unit"))
  ($ rs 'add-resource-spec
     (make-resource-specification #:id "spec-ride" #:name "Ride" #:default-unit-of-resource "trip"))
  ($ rs 'add-recipe-process (make-recipe-process #:id "rp-ride" #:name "Drive the van"
                                                #:has-duration (make-duration 1 %effort-unit)))
  ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-ride-van" #:action 'use
                                           #:resource-conforms-to "spec-van"
                                           #:resource-quantity (make-measure 1 "unit")
                                           #:recipe-input-of "rp-ride"))
  ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-ride-out" #:action 'produce
                                           #:resource-conforms-to "spec-ride"
                                           #:resource-quantity (make-measure 1 "trip")
                                           #:recipe-output-of "rp-ride" #:is-primary #t)))

(define %policy "Assurance de responsabilité civile automobile")   ; fr/rc-auto's demand name
(define fr-rules (load-context-pack "docs/legal/contexts/fr-national.sexp"))

(define (prunes? holder)
  "Does the ride column prune at a French cell, with the policy held by HOLDER (#f: nobody)?"
  (with-vat vat
    (let* ((rs  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))
           (sts (spawn ^spatial-thing-store (hashmap)))
           (reg (spawn ^legal-registry fr-rules))
           (obs (spawn ^observer (empty-observer-state) '()))
           (as  (spawn ^agent-store (hashmap) (hashmap) (hashmap) '())))
      (seed-ride! rs)
      ($ sts 'add-location (make-spatial-thing #:id "world"))
      ($ sts 'add-location (make-spatial-thing #:id "eu" #:contained-in "world"))
      ($ sts 'add-location (make-spatial-thing #:id "france" #:contained-in "eu"))
      ($ sts 'add-location (make-spatial-thing #:id "lyon" #:lat 45.7 #:long 4.8 #:contained-in "france"))
      (declare-body! as scope "body:rides" "Vélo-Van Asso" '((role . provider) (jurisdiction . "france")))
      (when holder (body-present-holding! obs holder %policy #:issuer "assureur"))
      (let ((dec (make-legal-decorate/observer
                  #:recipe-store rs #:spatial-thing-store sts #:registry reg #:observer obs
                  #:agent-store as #:act 'transport #:as-of "2026-10-10"
                  #:subject-for (scope-body-subject as obs (all-bodies as)
                                                    #:path-of (spatial-path-reader sts)))))
        (call-with-values (lambda () (dec "rp-ride" "lyon@0")) (lambda (prune? . _) prune?))))))

(check "no policy anywhere: the ride column prunes" (prunes? #f) #t)
(check "the policy in the body's custody restores it" (prunes? "body:rides") #f)
(check "the same policy in another agent's custody does not" (prunes? "aid:someone") #t)

(test-summary!)
