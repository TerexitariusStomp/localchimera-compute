;;; test-pipeline-wiring.scm — Planner pipeline wired through Validation Gate
;;;
;;; Verifies the wiring done in scope-root.scm + planning.scm + plan-federation.scm:
;;;
;;;   1. Plan-store's add-intent fires on-intent → observer.register-intent.
;;;      Result: satisfaction-state appears automatically, with the
;;;      intent's planned-within mirrored as plan-id.
;;;
;;;   2. Plan-store's add-plan fires on-plan → observer.confirm-plan
;;;      with the leaf's own scope-name. Result: leaf self-confirms its
;;;      own plans; voice at level=leaf-name is non-zero without any
;;;      manual confirm-plan call.
;;;
;;;   3. propagate-confirmations walks a federation-result's by-scope
;;;      and calls confirm-plan on each child observer with the parent
;;;      scope-id. Result: voice at level=parent-name lifts.
;;;
;;; This exercises the production path. The §14 test in test-account.scm
;;; exercises the gate with manual setup; this test exercises the
;;; auto-wiring that closes the loop end-to-end.

(use-modules (playnet test harness))
(use-modules (playnet deprecated planner))
(use-modules (playnet governance))   ;; for compute-plan-said
(use-modules (goblins)
             (goblins utils hashmap)
             (srfi srfi-1))


;; =========================================================================
;; Helpers
;; =========================================================================

(define (make-need iid hours plan-id receiver)
  "Construct a recipient-side intent for HOURS of labor in plan PLAN-ID,
   addressed to RECEIVER. The planner would normally produce these via
   signal->intent; we hand-build for test isolation."
  (make-intent #:id iid #:action 'work #:resource-conforms-to "spec-labor"
               #:effort-quantity (make-measure hours "hour") #:receiver receiver
               #:planned-within plan-id))

(define (work-event evid aid hours satisfies-iid)
  (make-economic-event
    #:id evid #:action 'work #:resource-conforms-to "spec-labor"
    #:provider aid #:effort-quantity (make-measure hours "hour") #:has-point-in-time "2026-04-26T08:00:00Z" #:satisfies satisfies-iid))


;; =========================================================================
;; 1. Auto-forwarded intents
;; =========================================================================

(display "\n── Plan-store add-intent → observer.register-intent ──\n")

(define vat-1 (spawn-vat))
(define scope-1
  (with-vat vat-1 (spawn-scope-root "Bakery")))

(with-vat vat-1
  (let* ((ps  ($ scope-1 'plan-store))
         (obs ($ scope-1 'observer)))

    ;; Adding the intent through plan-store should land in observer
    ;; via the on-intent → register-intent wire.
    ($ ps 'add-intent (make-need "I-bread" 10 "P-spring" "commune"))

    (check-pred "satisfaction-state appears in observer"
                ($ obs 'get-satisfaction "I-bread"))
    (check-pred "satisfaction-state carries plan-id from planned-within"
                (equal? "P-spring"
                        (satisfaction-state-plan-id
                          ($ obs 'get-satisfaction "I-bread"))))))


;; =========================================================================
;; 2. Auto-confirmed plans at the leaf
;; =========================================================================

(display "\n── Plan-store add-plan → observer.confirm-plan(leaf) ──\n")

(with-vat vat-1
  (let* ((ps  ($ scope-1 'plan-store))
         (obs ($ scope-1 'observer)))

    ;; Adding the plan through plan-store should auto-confirm at the
    ;; leaf scope-name via on-plan → confirm-plan.
    ($ ps 'add-plan (make-plan #:id "P-spring" #:name "Spring 2026"))

    (check-pred "P-spring validated at Bakery (leaf self-confirm)"
                (member "Bakery" ($ obs 'plan-validated-at "P-spring")))
    (check-pred "P-spring NOT yet validated at Regional"
                (not (member "Regional"
                             ($ obs 'plan-validated-at "P-spring"))))))


;; =========================================================================
;; 3. Credit flows through the gate without manual register-intent
;; =========================================================================

(display "\n── End-to-end credit through the wired pipeline ──\n")

(with-vat vat-1
  (let* ((obs ($ scope-1 'observer))
         (as  ($ scope-1 'account-store)))

    ;; Record alice's work satisfying the planner-emitted intent.
    ($ obs 'record-event (work-event "ev-a" "alice" 10 "I-bread"))
    ($ as  'credit-from-event ($ obs 'get-event "ev-a"))

    (let ((scopes (list scope-1)))
      (check-pred "unfiltered: alice gross = 10 (gate live, no manual setup)"
                  (= 10 (global-citizen-gross "alice" scopes)))
      (check-pred "Bakery: alice gross = 10 (leaf auto-confirmed)"
                  (= 10 (global-citizen-gross "alice" scopes "Bakery")))
      (check-pred "Regional: alice gross = 0 (not yet propagated)"
                  (= 0 (global-citizen-gross "alice" scopes "Regional"))))))


;; =========================================================================
;; 4. propagate-confirmations lifts credit to the parent level
;; =========================================================================

(display "\n── Federation propagate-confirmations ──\n")

(define vat-fed (spawn-vat))
(define-values (parent leaf-A leaf-B)
  (with-vat vat-fed
    (values (spawn-scope-root "Regional")
            (spawn-scope-root "Bakery")
            (spawn-scope-root "Watershed"))))

(with-vat vat-fed
  ;; Each leaf produces its own plan + intent, satisfies it, gets credit.
  (let* ((ps-a  ($ leaf-A 'plan-store))
         (obs-a ($ leaf-A 'observer))
         (as-a  ($ leaf-A 'account-store))
         (ps-b  ($ leaf-B 'plan-store))
         (obs-b ($ leaf-B 'observer))
         (as-b  ($ leaf-B 'account-store)))

    ($ ps-a 'add-plan (make-plan #:id "P-bread" #:name "Bakery Spring"))
    ($ ps-a 'add-intent (make-need "I-bread" 10 "P-bread" "commune-A"))
    ($ obs-a 'record-event (work-event "ev-a" "alice" 10 "I-bread"))
    ($ as-a 'credit-from-event ($ obs-a 'get-event "ev-a"))

    ($ ps-b 'add-plan (make-plan #:id "P-water" #:name "Watershed Spring"))
    ($ ps-b 'add-intent (make-need "I-water" 30 "P-water" "commune-B"))
    ($ obs-b 'record-event (work-event "ev-b" "bob" 30 "I-water"))
    ($ as-b 'credit-from-event ($ obs-b 'get-event "ev-b"))

    (let ((scopes (list parent leaf-A leaf-B)))

      (check-pred "Regional: alice gross = 0 pre-propagation"
                  (= 0 (global-citizen-gross "alice" scopes "Regional")))
      (check-pred "Regional: bob gross = 0 pre-propagation"
                  (= 0 (global-citizen-gross "bob" scopes "Regional")))

      ;; Synthesize a federation-result of the shape plan-federation
      ;; would emit, then propagate. (We don't run the full DDMRP
      ;; planner here — it requires recipes, demand, etc. — the wiring
      ;; this test verifies is between by-scope→confirm-plan.)
      (let* ((by-scope (hashmap-set
                         (hashmap-set (hashmap)
                                      "Bakery"   `((plan-id . "P-bread")))
                         "Watershed" `((plan-id . "P-water"))))
             (fed-result `((by-scope . ,by-scope))))

        (propagate-confirmations fed-result (list leaf-A leaf-B) "Regional")

        (check-pred "P-bread validated at Regional after propagation"
                    (member "Regional"
                            ($ obs-a 'plan-validated-at "P-bread")))
        (check-pred "P-water validated at Regional after propagation"
                    (member "Regional"
                            ($ obs-b 'plan-validated-at "P-water")))

        (check-pred "Regional: alice gross = 10 post-propagation"
                    (= 10 (global-citizen-gross "alice" scopes "Regional")))
        (check-pred "Regional: bob gross = 30 post-propagation"
                    (= 30 (global-citizen-gross "bob" scopes "Regional")))
        (check-pred "Regional: voices sum to 1"
                    (= 1 (+ (voice-share "alice" scopes "Regional")
                            (voice-share "bob"   scopes "Regional"))))

        ;; Withdrawal: Regional revokes its endorsement of P-bread.
        ;; Alice's credit at Regional vanishes on the next query — the
        ;; gate joins through plan-validations every read.
        ($ obs-a 'unconfirm-plan "P-bread" "Regional")
        (check-pred "Regional: alice gross = 0 after Regional revokes P-bread"
                    (= 0 (global-citizen-gross "alice" scopes "Regional")))
        (check-pred "Bakery: alice gross still 10 (leaf-self-confirm survives)"
                    (= 10 (global-citizen-gross "alice" scopes "Bakery")))
        (check-pred "Regional: bob gross still 30 (P-water unchanged)"
                    (= 30 (global-citizen-gross "bob" scopes "Regional")))
        (check-pred "unconfirm-plan is idempotent (re-revoke is no-op)"
                    (begin ($ obs-a 'unconfirm-plan "P-bread" "Regional")
                           (= 0 (global-citizen-gross "alice" scopes "Regional"))))))))


;; =========================================================================
;; 5. Content-addressed plan-ids (SAID) flow end-to-end
;; =========================================================================
;;
;; Plan-ids don't have to be opaque random strings. compute-plan-said
;; produces a content-derived SAID over (scope-aid, sorted intent set);
;; that SAID drops in anywhere a plan-id string is expected. Two scopes
;; that converge on the same intent set get the same plan-id — useful
;; for federation harmonization.

(display "\n── Content-addressed plan-id (SAID) end-to-end ──\n")

(define vat-said (spawn-vat))
(define scope-said
  (with-vat vat-said (spawn-scope-root "E_bakery_said_test")))

(with-vat vat-said
  (let* ((ps  ($ scope-said 'plan-store))
         (obs ($ scope-said 'observer))
         (as  ($ scope-said 'account-store))
         (intent-ids '("I-bread" "I-flour"))
         (plan-said (compute-plan-said "E_bakery_said_test" intent-ids)))

    (check-pred "plan-said is a CESR E-prefixed SAID"
                (and (= 44 (string-length plan-said))
                     (eq? #\E (string-ref plan-said 0))))

    ;; Wire intents + plan via the planner pipeline; auto-forwards
    ;; through on-intent / on-plan to the observer.
    (for-each (lambda (iid)
                ($ ps 'add-intent (make-need iid 5 plan-said "commune")))
              intent-ids)
    ($ ps 'add-plan (make-plan #:id plan-said #:name "Bakery (SAID)"))

    ;; Satisfy one of the intents.
    ($ obs 'record-event (work-event "ev-said" "alice" 5 "I-bread"))
    ($ as  'credit-from-event ($ obs 'get-event "ev-said"))

    (let ((scopes (list scope-said)))
      (check-pred "satisfaction-state plan-id IS the SAID"
                  (equal? plan-said
                          (satisfaction-state-plan-id
                            ($ obs 'get-satisfaction "I-bread"))))
      (check-pred "leaf auto-confirmed against the SAID-derived plan-id"
                  (member "E_bakery_said_test"
                          ($ obs 'plan-validated-at plan-said)))
      (check-pred "voice flows the same way as with random plan-ids"
                  (= 5 (global-citizen-gross "alice" scopes
                                              "E_bakery_said_test"))))))


;; =========================================================================
;; 6. Ballot tally → endorse-by-tally → propagate-confirmations
;; =========================================================================
;;
;; The federation-confirmation act is conditional on an assembly's
;; decision. endorse-by-tally bridges a ballot's tally hashmap (yes/no
;; weights) to propagation: yes wins → propagate; no wins or tie →
;; withhold. The gate's level-stratified voice then reflects whether
;; the assembly endorsed.

(display "\n── Ballot tally gates federation confirmation ──\n")

(define vat-tally (spawn-vat))
(define-values (parent-2 leaf-X)
  (with-vat vat-tally
    (values (spawn-scope-root "Watershed-Council")
            (spawn-scope-root "Spring-Cluster"))))

(with-vat vat-tally
  (let* ((ps  ($ leaf-X 'plan-store))
         (obs ($ leaf-X 'observer))
         (as  ($ leaf-X 'account-store)))
    ($ ps 'add-plan (make-plan #:id "P-flow-X" #:name "Spring Cluster Plan"))
    ($ ps 'add-intent (make-need "I-clean" 8 "P-flow-X" "commune"))
    ($ obs 'record-event (work-event "ev-c" "carol" 8 "I-clean"))
    ($ as  'credit-from-event ($ obs 'get-event "ev-c"))

    (let* ((scopes (list parent-2 leaf-X))
           (fed-result
             `((by-scope . ,(hashmap-set (hashmap)
                              "Spring-Cluster"
                              `((plan-id . "P-flow-X")))))))

      ;; Tally: no wins → no propagation.
      (let ((tally-rejected (hashmap-set (hashmap-set (hashmap) 'yes 5) 'no 12)))
        (endorse-by-tally tally-rejected fed-result (list leaf-X)
                          "Watershed-Council")
        (check-pred "rejected ballot: Watershed-Council voice = 0"
                    (= 0 (global-citizen-gross "carol" scopes
                                                "Watershed-Council")))
        (check-pred "rejected ballot: P-flow-X NOT validated at parent"
                    (not (member "Watershed-Council"
                                 ($ obs 'plan-validated-at "P-flow-X")))))

      ;; Tally: yes wins → propagation fires, voice lifts.
      (let ((tally-passed (hashmap-set (hashmap-set (hashmap) 'yes 12) 'no 3)))
        (endorse-by-tally tally-passed fed-result (list leaf-X)
                          "Watershed-Council")
        (check-pred "passed ballot: P-flow-X validated at Watershed-Council"
                    (member "Watershed-Council"
                            ($ obs 'plan-validated-at "P-flow-X")))
        (check-pred "passed ballot: Watershed-Council voice = 8"
                    (= 8 (global-citizen-gross "carol" scopes
                                                "Watershed-Council"))))

      ;; Tie: also no-op (yes must strictly exceed no).
      ($ obs 'unconfirm-plan "P-flow-X" "Watershed-Council")
      (let ((tally-tied (hashmap-set (hashmap-set (hashmap) 'yes 7) 'no 7)))
        (endorse-by-tally tally-tied fed-result (list leaf-X)
                          "Watershed-Council")
        (check-pred "tied ballot: Watershed-Council voice = 0"
                    (= 0 (global-citizen-gross "carol" scopes
                                                "Watershed-Council")))))))


;; =========================================================================

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
