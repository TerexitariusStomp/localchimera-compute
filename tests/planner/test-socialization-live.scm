;;; test-socialization-live.scm — a socialized private means, scheduled in a REAL solve.
;;;
;;; The end-to-end proof that ties the socialization arc together. Alice owns a
;;; cargo-bike (primary-accountable = Alice); the COMMUNE owns nothing of its own.
;;; Alice socializes the bike; a live `plan-scope` solve over the commune's
;;; scope-root then:
;;;   (1) RESOLVES the granted resource (Alice's bike lives in her books) and
;;;       assembles the commune's view = own ∪ live-granted, projected
;;;       custodian-scope = commune, rights untouched  (commune-resource-view, via
;;;       plan-scope's #:resource-view — federation visibility A2), and
;;;   (2) injects the bike's per-window `Svc|bike` capacity  (commune-socialized-caps,
;;;       via #:eco-caps),
;;; so a delivery recipe that `use`s the bike runs — BOUNDED by exactly what the
;;; grant lent. Lend 2 and ~2 parcels move; lend 4 and ~4 move. Nothing is stored:
;;; the whole view (resource + custody + capacity) is derived from the live grant
;;; each solve, so a lapsed grant drops all of it.
;;;
;;; Run:  guile -L module -L tests tests/planner/test-socialization-live.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness)
             (playnet vf schemas)
             (playnet scope live)
             (playnet credentials custody) (playnet governance socialization) (playnet keri acdc-store)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

(define OWNER   "EAlice")
(define COMMUNE "ECommune")
(define FUTURE  "2099-12-31T00:00:00Z")

;; generic mock actor (as in test-live-wiring)
;; a delivery recipe: `use` the bike (1 bike-hour/parcel) → produce a delivered parcel
(define procs (list (make-recipe-process #:id "deliver" #:name "Deliver")))
(define flows
  (list (make-recipe-flow #:id "d-use" #:action 'use #:resource-conforms-to "bike" #:resource-quantity (make-measure 1.0 %count-unit) #:effort-quantity (make-measure 1.0 %effort-unit)
                          #:recipe-input-of "deliver")
        (make-recipe-flow #:id "d-out" #:action 'produce #:resource-conforms-to "delivered" #:resource-quantity (make-measure 1.0 "kg")
                          #:recipe-output-of "deliver" #:is-primary #t)))
(define recipes (list (make-recipe #:id "deliver-recipe" #:name "Deliver"
                                   #:primary-output "delivered" #:recipe-processes '()
                                   #:recipe-exchanges '())))

;; the bike as it sits in the books: Alice owns it, no custodian, at "town".
(define (bike)
  (make-economic-resource #:id "res:bike" #:conforms-to "bike" #:classified-as '()
                          #:onhand-quantity (make-measure 1 %count-unit) #:current-location "town" #:primary-accountable OWNER))
(define spatials (list (make-spatial-thing #:id "town" #:lat 40.0 #:long -74.0)))

(define vat (spawn-vat #:name "socialize-live"))

;; run one live solve for a grant of QTY (or #f = no grant), demand 5 parcels.
;; returns the fraction of demand met.
(define (run qty)
  (with-vat vat
    (let* ((store (spawn-acdc-store))
           (_ (when qty (socialize-private-resource store OWNER COMMUNE "bike" qty #:until FUTURE)))
           ;; the commune owns NOTHING of its own; Alice's bike lives in her books.
           (obs (spawn ^mock `((all-resources . ,(lambda () '()))
                               (record-event  . ,(lambda (e) "ok")))))
           (as  (spawn ^mock `((all-agents    . ,(lambda () '())))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs  (spawn ^mock `((all-recipes       . ,(lambda () recipes))
                               (get-process-chain . ,(lambda (rid) procs))
                               (flows-for-process . ,(lambda (pid)
                                 (cons (filter (lambda (f) (or (equal? (recipe-flow-recipe-input-of f) pid)
                                                               (equal? (recipe-flow-recipe-output-of f) pid)))
                                               flows) '()))))))
           (ps  (spawn ^mock `((all-meta . ,(lambda () '())) (all-commitments . ,(lambda () '())))))
           (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs #:plan-store ps))
           ;; Alice's bike lives in HER commune's books; this commune owns nothing.
           ;; The FEDERATION resolver fetches it cross-scope from the sibling commune's
           ;; observer; `commune-resource-view` then assembles own ∪ resolved-granted
           ;; and projects it commune-custodied — all derived from the live grant, so a
           ;; lapsed grant drops the bike AND its custody, never copied.
           (m-obs   (spawn ^mock `((all-resources . ,(lambda () (list (bike)))))))
           (m-root  (mock-scope-root #:observer m-obs))
           (m-commA (spawn ^mock `((scope-root . ,(lambda () m-root)))))
           (fed     (spawn ^mock `((members . ,(lambda () (hashmap-set (hashmap) "commA" m-commA))))))
           (resolve (federation-resource-resolver fed))
           (view    (lambda (own) (commune-resource-view own store COMMUNE resolve)))
           (caps    (commune-socialized-caps store COMMUNE (view '()) '(0)))
           (result (plan-scope->alist scope
                     #:resource-view view
                     #:eco-caps caps
                     #:demand '(("delivered#town@0" . 5.0))
                     #:backend 'native-c)))
      (assq-ref result 'met))))

(define lent-2 (run 2))
(define lent-4 (run 4))

(display "\n── a socialized bike, scheduled in a live plan-scope solve (demand 5) ──\n")
(format #t "  lent 2 ⇒ demand met ~,2f   (≈ 2/5)~%" lent-2)
(format #t "  lent 4 ⇒ demand met ~,2f   (≈ 4/5)~%" lent-4)

(check "lent 2 ⇒ communal use bounded to ~2/5 of demand"
       (and (> lent-2 0.35) (< lent-2 0.45)))
(check "lent 4 ⇒ more lent, more use, ~4/5 of demand"
       (and (> lent-4 0.75) (< lent-4 0.85)))
(check "lending more raises delivered communal use"
       (> lent-4 lent-2))

;; the resolver itself: searches member communes, skips members without an economic
;; scope-root (sub-federations), and honours a grant that names an exact resource.
(display "\n── the federation resolver: search members, skip scope-root-less ──\n")
(with-vat vat
  (let* ((m-obs   (spawn ^mock `((all-resources . ,(lambda () (list (bike)))))))
         (m-root  (mock-scope-root #:observer m-obs))
         (commA   (spawn ^mock `((scope-root . ,(lambda () m-root)))))
         (sub-fed (spawn ^mock `((scope-root . ,(lambda () #f)))))   ; a member with no economic root
         (fed     (spawn ^mock `((members . ,(lambda ()
                    (hashmap-set (hashmap-set (hashmap) "A" commA) "F" sub-fed))))))
         (resolve (federation-resource-resolver fed))
         (grant   (make-custody-attestation-credential OWNER COMMUNE "bike" 4)))
    (check "fetches the member's resource, skips the scope-root-less member"
           (= 1 (length (resolve grant))))
    (check "a resource-id grant that matches nothing resolves empty"
           (null? (resolve (make-custody-attestation-credential
                            OWNER COMMUNE "bike" 4 #:resource "no-such-id"))))
    ;; STANDING. Lending a thing is an exercise of rights, so a grant reaches
    ;; only what its issuer actually owns. Naming the resource outright does not
    ;; buy past that — which it silently did while the resource-id branch of
    ;; %grant-over? stood on its own, letting anyone lend out a thing that was
    ;; never theirs (and, once the map could leave things in public boxes, a
    ;; thing the commons itself owned).
    (check "a grant from someone with no rights over it reaches nothing"
           (null? (resolve (make-custody-attestation-credential
                            "EMallory" COMMUNE "bike" 4 #:resource "res:bike"))))
    (check "…and the owner's own grant still reaches it"
           (= 1 (length (resolve (make-custody-attestation-credential
                                  OWNER COMMUNE "bike" 4 #:resource "res:bike")))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; The other half of the same wire: the demand comes from a DECLARED NEED
;;; ════════════════════════════════════════════════════════════════════════════
;;;
;;; Above, the demand was handed to the solve as a literal. Here nobody hands it
;;; anything: a citizen declared "I need 5 delivered, at town" on the share face,
;;; and `plan-commune-scope` folds that need up the tree at planning time
;;; (demand-fold.scm) to get the same 5. Same recipe, same socialized bike, same
;;; numbers — so what changes is only WHERE the demand came from.

(define (need-intent aid spec qty loc)
  (make-intent #:id (string-append "need:" aid ":" spec)
               #:action 'consume #:name spec #:resource-conforms-to spec
               #:resource-quantity (make-measure qty %count-unit) #:receiver aid #:at-location loc #:in-scope-of '()))

(define (run-declared qty)
  (with-vat vat
    (let* ((store (spawn-acdc-store))
           (_ (when qty (socialize-private-resource store OWNER COMMUNE "bike" qty #:until FUTURE)))
           (obs (spawn ^mock `((all-resources . ,(lambda () '()))
                               (record-event  . ,(lambda (e) "ok")))))
           (as  (spawn ^mock `((all-agents    . ,(lambda () '())))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs  (spawn ^mock `((all-recipes       . ,(lambda () recipes))
                               (get-process-chain . ,(lambda (rid) procs))
                               (flows-for-process . ,(lambda (pid)
                                 (cons (filter (lambda (f) (or (equal? (recipe-flow-recipe-input-of f) pid)
                                                               (equal? (recipe-flow-recipe-output-of f) pid)))
                                               flows) '()))))))
           (ps  (spawn ^mock `((all-meta . ,(lambda () '())) (all-commitments . ,(lambda () '()))
                               (all-intents . ,(lambda () '())))))
           (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs #:plan-store ps))
           (m-obs   (spawn ^mock `((all-resources . ,(lambda () (list (bike)))))))
           (m-root  (mock-scope-root #:observer m-obs))
           (m-commA (spawn ^mock `((scope-root . ,(lambda () m-root)))))
           (fed     (spawn ^mock `((members . ,(lambda () (hashmap-set (hashmap) "commA" m-commA))))))
           ;; the DEMAND side of the tree: a member scope whose plan-store holds
           ;; one citizen's standing need for 5 delivered at town
           (n-ps    (spawn ^mock `((all-intents . ,(lambda ()
                       (list (need-intent "EAlice" "delivered" 5 "town")))))))
           (n-root  (spawn ^mock `((plan-store . ,(lambda () n-ps)))))
           (n-memb  (spawn ^mock `((scope-root . ,(lambda () n-root))
                                   (members    . ,(lambda () (hashmap))))))
           (dscope  (spawn ^mock `((scope-root . ,(lambda () #f))
                                   (members    . ,(lambda () (hashmap-set (hashmap) "m" n-memb))))))
           (result (plan-commune-scope scope store COMMUNE
                     #:resolve (federation-resource-resolver fed)
                     #:demand-scope dscope
                     #:backend 'native-c)))
      (assq-ref result 'met))))

(define declared-2 (run-declared 2))
(define declared-4 (run-declared 4))

(display "\n── the demand is a citizen's declared need, folded up at planning time ──\n")
(format #t "  need 5 · lent 2 ⇒ demand met ~,2f   (≈ 2/5)~%" declared-2)
(format #t "  need 5 · lent 4 ⇒ demand met ~,2f   (≈ 4/5)~%" declared-4)

(check "a declared need IS the solve's demand (lent 2 ⇒ ~2/5)"
       (and (> declared-2 0.35) (< declared-2 0.45)))
(check "and it responds to the means lent, exactly as a literal demand did"
       (and (> declared-4 0.75) (< declared-4 0.85)))
(check "declared need = handed demand — same wire, same answer"
       ;; same wire; the tolerance is the native solver's own noise floor
       (and (< (abs (- declared-2 lent-2)) 0.005)
            (< (abs (- declared-4 lent-4)) 0.005)))

(test-summary!)
