;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-recovery.scm — federation round-trip rebuild from ACDCs
;;;
;;; Spawn a federation, do meaningful mutations, snapshot the ACDC store,
;;; reconstruct everything from the ACDCs alone, assert behavioral
;;; equivalence on the recovered actor graph.

(use-modules ((localchimera test scope) #:select (account!)))
(use-modules ((localchimera utils units) #:select (%effort-unit)))
(use-modules (localchimera test harness))
(use-modules (localchimera scope root) (localchimera vf schemas) (localchimera observation states))
(use-modules (localchimera utils endorsement))
(use-modules (localchimera voice ballot) (localchimera boot scope) (localchimera credentials commitments) (localchimera credentials membership) (localchimera credentials voting) (localchimera credentials work) (localchimera keri acdc) (localchimera voice delegation-map) (localchimera boot scope) (localchimera federation rebuild) (localchimera voice voice-signer) (localchimera keri acdc) (localchimera keri acdc-store) (localchimera keri said-portable))
(use-modules (goblins) (goblins utils hashmap) (srfi srfi-1))


(define (synthetic-aid id) (string-append "E_" id))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Delegation map round-trip (single citizen)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Delegation map round-trip ──\n")

(define vat (spawn-vat))

(with-vat vat
  (define store (spawn-acdc-store))
  (define dm (spawn-delegation-map "alice" #:acdc-store store))

  ;; Alice delegates: 0.4 federation to bob, 0.3 federation to carol,
  ;; AND in watershed she boosts bob to 0.5 (override per-delegate replaces
  ;; the federation default for bob in watershed).
  ($ dm 'delegate "bob" 0.4)
  ($ dm 'delegate "carol" 0.3)
  ($ dm 'delegate "bob" 0.5 'scope "watershed")

  ;; Check ACDCs were issued
  (let ((creds ($ store 'by-issuer "alice")))
    (check-pred "3 delegation ACDCs issued" (= 3 (length creds))))

  ;; --- TEAR DOWN ---
  ;; In Phase-1 we just abandon the live dm. The store survives.

  ;; --- RECOVER ---
  (define dm2 (recover-delegation-map "alice" store #:write-store store))

  (let ((fed-resolved   ($ dm2 'resolve-for 'federation))
        (water-resolved ($ dm2 'resolve-for '(scope "watershed")))
        (tech-resolved  ($ dm2 'resolve-for '(scope "tech-coop"))))

    ;; Federation: bob 0.4, carol 0.3
    (check-pred "recovered federation: bob 0.4"
                (and (hashmap-ref fed-resolved "bob" #f)
                     (= 0.4 (entry-fraction (hashmap-ref fed-resolved "bob")))))
    (check-pred "recovered federation: carol 0.3"
                (and (hashmap-ref fed-resolved "carol" #f)
                     (= 0.3 (entry-fraction (hashmap-ref fed-resolved "carol")))))

    ;; Watershed: bob 0.5 (override), carol 0.3 (still federation default)
    (check-pred "watershed: bob 0.5 (override)"
                (= 0.5 (entry-fraction (hashmap-ref water-resolved "bob"))))
    (check-pred "watershed: carol 0.3 (federation)"
                (= 0.3 (entry-fraction (hashmap-ref water-resolved "carol"))))

    ;; Tech-coop: federation default only — bob 0.4
    (check-pred "tech-coop: bob 0.4 (federation default applies)"
                (= 0.4 (entry-fraction (hashmap-ref tech-resolved "bob"))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Mandated delegation round-trip (DSL spec)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Mandated delegation round-trip ──\n")

(define vat2 (spawn-vat))

(with-vat vat2
  (define store (spawn-acdc-store))
  (define dm (spawn-delegation-map "alice" #:acdc-store store))

  ;; Alice mandates bob to vote 'yes (using the DSL helper)
  ($ dm 'delegate-mandated "bob" 0.5 (mandate '(equal-position yes)))

  ;; Recover
  (define dm2 (recover-delegation-map "alice" store))
  (let* ((resolved ($ dm2 'resolve-for 'federation))
         (entry (hashmap-ref resolved "bob" #f)))
    (check-pred "fraction recovered" (= 0.5 (entry-fraction entry)))
    (let ((mandate-pred (entry-mandate entry)))
      (check-pred "mandate predicate recovered"
                  (procedure? mandate-pred))
      (check-pred "predicate accepts 'yes"
                  (mandate-pred (list 'stance "p" 'yes "alice" "E_alice")))
      (check-pred "predicate rejects 'no"
                  (not (mandate-pred (list 'stance "p" 'no "alice" "E_alice")))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Revocation respected on recovery
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Revoked credentials skipped ──\n")

(define vat3 (spawn-vat))

(with-vat vat3
  (define store (spawn-acdc-store))
  (define dm (spawn-delegation-map "alice" #:acdc-store store))
  ($ dm 'delegate "bob" 0.4)
  ($ dm 'revoke "bob")

  (let ((dm2 (recover-delegation-map "alice" store)))
    (let ((resolved ($ dm2 'resolve-for 'federation)))
      (check-pred "revoked delegation gone after recovery"
                  (not (hashmap-ref resolved "bob" #f))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Commune state round-trip
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Commune state round-trip ──\n")

(define vat4 (spawn-vat))

(with-vat vat4
  (define store (spawn-acdc-store))
  (define scope (spawn-scope-root "Watershed"))
  (define commune (spawn-commune "Watershed" scope #:acdc-store store))
  (define gov-cap ($ commune 'mint-gov-cap "operator"))

  ;; Set up some members + CCFs + an exclusion.
  ($ commune 'admit-member gov-cap "alice")
  ($ commune 'admit-member gov-cap "bob")
  ($ commune 'admit-member gov-cap "grandma")
  ($ commune 'set-ccf gov-cap "alice" 1)
  ($ commune 'set-ccf gov-cap "grandma" 0)
  ($ commune 'exclude-member gov-cap "outlaw")

  ;; --- TEAR DOWN ---
  ;; Drop commune and scope; keep store.

  ;; --- RECOVER ---
  ;; Spawn commune WITHOUT acdc-store first (so recovery mutations
  ;; don't re-emit), then bind store after recovery completes.
  (define scope2 (spawn-scope-root "Watershed"))
  (define commune2 (spawn-commune "Watershed" scope2))
  (recover-commune-state commune2 store)
  ($ commune2 'set-acdc-store store)

  ;; Verify membership: alice/bob/grandma have accounts in scope2
  (let ((as ($ scope2 'account-store)))
    (check-pred "alice account exists"  ($ as 'holder? "alice"))
    (check-pred "bob account exists"    ($ as 'holder? "bob"))
    (check-pred "grandma account exists" ($ as 'holder? "grandma")))

  ;; CCFs recovered
  (let ((as ($ scope2 'account-store)))
    (check-pred "alice CCF = 1"
                (= 1 ($ as 'ccf-of "alice")))
    (check-pred "grandma CCF = 0"
                (= 0 ($ as 'ccf-of "grandma"))))

  ;; Exclusion recovered
  (check-pred "outlaw is excluded" ($ commune2 'excluded-aid? "outlaw"))
  (check-pred "alice not excluded" (not ($ commune2 'excluded-aid? "alice"))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Federation membership round-trip
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. Federation membership round-trip ──\n")

(define vat5 (spawn-vat))

(with-vat vat5
  (define store (spawn-acdc-store))
  (define scope-a (spawn-scope-root "Watershed"))
  (define scope-b (spawn-scope-root "Bakery"))
  (define commune-a (spawn-commune "Watershed" scope-a
                                    #:commune-aid "watershed-aid"
                                    #:acdc-store store))
  (define commune-b (spawn-commune "Bakery" scope-b
                                    #:commune-aid "bakery-aid"
                                    #:acdc-store store))
  (define fed (spawn-federation "River-Federation"
                                 #:federation-aid "river-fed-aid"
                                 #:acdc-store store))
  (define fed-gov ($ fed 'mint-gov-cap "operator"))

  ($ fed 'admit-commune fed-gov "watershed" commune-a)
  ($ fed 'admit-commune fed-gov "bakery"    commune-b)

  (check-pred "2 fed-membership ACDCs issued"
              (= 2 (length
                    (filter (lambda (c)
                              (equal? (cred-schema c)
                                      *schema-localchimera-federation-membership*))
                            ($ store 'by-issuer "river-fed-aid")))))

  ;; --- RECOVER ---
  ;; Recovery spawns federation WITHOUT acdc-store, replays admit-commune
  ;; from credentials (no re-emission), then binds the store.
  (define fed2 (spawn-federation "River-Federation"
                                  #:federation-aid "river-fed-aid"))
  (let ((lookup (hashmap-set
                  (hashmap-set (hashmap) "watershed" commune-a)
                  "bakery" commune-b)))
    (recover-federation-state fed2 store lookup))
  ($ fed2 'set-acdc-store store)

  (check-pred "recovered fed has 2 communes"
              (= 2 (length ($ fed2 'member-commune-ids))))
  (check-pred "watershed in recovered fed"
              ($ fed2 'member-commune "watershed"))
  (check-pred "bakery in recovered fed"
              ($ fed2 'member-commune "bakery")))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Reinstatement revokes exclusion
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 6. Reinstatement revokes exclusion ──\n")

(define vat6 (spawn-vat))

(with-vat vat6
  (define store (spawn-acdc-store))
  (define scope (spawn-scope-root "Watershed"))
  (define commune (spawn-commune "Watershed" scope
                                  #:commune-aid "watershed-aid"
                                  #:acdc-store store))
  (define gov-cap ($ commune 'mint-gov-cap "op"))

  ($ commune 'exclude-member gov-cap "alice")
  ($ commune 'reinstate-member gov-cap "alice")

  (let ((commune2 (spawn-commune "Watershed" (spawn-scope-root "Watershed")
                                  #:commune-aid "watershed-aid")))
    (recover-commune-state commune2 store)
    (check-pred "alice not excluded after reinstate→recover"
                (not ($ commune2 'excluded-aid? "alice")))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Ballot recovery: snapshot + stances → fresh ^ballot with same tally
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 7. Ballot recovery ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (scope (spawn-scope-root "Watershed"))
         (ballot-store ($ scope 'ballot-store)))

    ;; Setup citizens with voice
    ($ ($ scope 'account-store) 'add-contribution "alice" 30)
    ($ ($ scope 'account-store) 'add-contribution "bob"   70)

    ;; Spawn citizen-voices (sealer mode)
    (define-values (alice-voice alice-sealed?) (spawn-voice-signer "alice" "alice"))
    (define-values (bob-voice   bob-sealed?)   (spawn-voice-signer "bob"   "bob"))
    (define citizen-registry
      (hashmap-set (hashmap-set (hashmap) "alice" alice-sealed?)
                   "bob" bob-sealed?))

    ;; Build voice-data and open ballot directly (mirror service.scm)
    (define citizen-voice-data
      (hashmap-set (hashmap-set (hashmap)
                                "alice" (cons 30/100 #f))
                   "bob" (cons 70/100 #f)))
    (define b (open-ballot 'policy "p-1" 'federation "Test ballot"
                           citizen-registry citizen-voice-data))
    ($ ballot-store 'record "p-1" b)

    ;; Manually emit ballot-snapshot ACDC (would normally come from service)
    (let* ((entries (hashmap-fold
                      (lambda (cid pair acc)
                        (cons (list cid (car pair) '()) acc))
                      '() citizen-voice-data))
           (registry-aids '("alice" "bob"))
           (snap-said (compute-said "gov" "gov" *schema-localchimera-ballot-snapshot*
                                    (list (cons 'proposal-id "p-1")
                                          (cons 'entries entries)))))
      ($ store 'issue
         (make-ballot-snapshot-credential
           #:governance-group-aid "gov"
           #:domain 'policy
           #:proposal-id "p-1"
           #:franchise 'federation
           #:snapshot-said snap-said
           #:opened-at (current-time)
           #:description "Test ballot"
           #:voice-snapshot-entries entries
           #:citizen-registry-aids registry-aids)))

    ;; Cast stances
    ($ b 'cast "alice" ($ alice-voice 'stance "p-1" 'yes))
    ($ b 'cast "bob"   ($ bob-voice   'stance "p-1" 'no))

    ;; Emit stance ACDCs
    ($ store 'issue
       (make-stance-credential #:citizen-aid "alice"
                               #:governance-group-aid "gov"
                               #:domain 'policy
                               #:proposal-id "p-1"
                               #:position 'yes
                               #:timestamp (current-time)))
    ($ store 'issue
       (make-stance-credential #:citizen-aid "bob"
                               #:governance-group-aid "gov"
                               #:domain 'policy
                               #:proposal-id "p-1"
                               #:position 'no
                               #:timestamp (current-time)))

    ;; Original tally
    (let ((orig-tally (assoc-ref ($ b 'tally) 'tally)))
      (check-pred "original yes = 30/100"
                  (= (hashmap-ref orig-tally 'yes 0) 30/100))
      (check-pred "original no = 70/100"
                  (= (hashmap-ref orig-tally 'no 0) 70/100)))

    ;; Tear down: forget the ballot from the ballot-store
    ($ ballot-store 'forget "p-1")
    (check-pred "ballot forgotten"
                (not ($ ballot-store 'get "p-1")))

    ;; Recover from ACDCs
    (let* ((sealed-by-aid (hashmap-set (hashmap-set (hashmap)
                                                     "alice" alice-sealed?)
                                       "bob" bob-sealed?))
           (recovered (recover-ballot-state ballot-store store "p-1"
                                            sealed-by-aid)))
      (check-pred "ballot recovered"
                  (and recovered #t))
      ;; Verify same tally
      (let ((rec-tally (assoc-ref ($ recovered 'tally) 'tally)))
        (check-pred "recovered yes = 30/100"
                    (= (hashmap-ref rec-tally 'yes 0) 30/100))
        (check-pred "recovered no = 70/100"
                    (= (hashmap-ref rec-tally 'no 0) 70/100))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Economic state recovery: commitments + work events from ACDCs
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 8. Economic state recovery ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (scope (spawn-scope-root "Bakery"))
         (plan-store ($ scope 'plan-store))
         (account-store ($ scope 'account-store)))

    ;; Wire emitters
    ($ plan-store 'set-on-commitment
       (lambda (cmt)
         (let ((rq (commitment-resource-quantity cmt))
               (eq (commitment-effort-quantity cmt)))
           ($ store 'issue-idempotent
              (make-commitment-credential
                #:provider-aid (or (commitment-provider cmt) "E_provider")
                #:receiver-aid (or (commitment-receiver cmt) "E_receiver")
                #:commitment-id (commitment-id cmt)
                #:action (commitment-action cmt)
                #:resource-conforms-to (commitment-resource-conforms-to cmt)
                #:resource-quantity
                (and rq (cons (measure-has-numerical-value rq)
                              (measure-has-unit rq)))
                #:effort-quantity
                (and eq (cons (measure-has-numerical-value eq)
                              (measure-has-unit eq))))))))

    ($ account-store 'set-on-work
       (lambda (event)
         (let* ((worker (economic-event-provider event))
                (hours (measure-has-numerical-value
                         (economic-event-effort-quantity event))))
           ($ store 'issue-idempotent
              (make-work-event-credential
                #:scope-aid "E_bakery"
                #:worker-aid worker
                #:event-id (economic-event-id event)
                #:hours hours
                #:unit %effort-unit
                #:fulfills (economic-event-fulfills event)
                #:satisfies (economic-event-satisfies event))))))

    ;; Intent-emitter too: §III.1 gates credit on recipient-side intents.
    ($ plan-store 'set-on-intent
       (lambda (i)
         (let ((rq (intent-resource-quantity i))
               (eq (intent-effort-quantity i)))
           ($ store 'issue-idempotent
              (make-intent-credential
                #:issuer-aid (or (intent-receiver i) (intent-provider i) "E_issuer")
                #:intent-id (intent-id i)
                #:action (intent-action i)
                #:receiver (intent-receiver i)
                #:provider (and (not (intent-receiver i)) (intent-provider i))
                #:resource-conforms-to (intent-resource-conforms-to i)
                #:resource-quantity
                (and rq (cons (measure-has-numerical-value rq)
                              (measure-has-unit rq)))
                #:effort-quantity
                (and eq (cons (measure-has-numerical-value eq)
                              (measure-has-unit eq))))))))

    ;; Add a commitment (producer-side plan) + an intent (recipient-side
    ;; need) + a work event that satisfies the intent. The Validation
    ;; Gate (§III.1) anchors credit on intent-satisfaction, so the
    ;; observer must know about the intent for the event to count.
    (let ((cmt (make-commitment #:id "C-recover" #:action 'work
                                #:resource-conforms-to "spec-bread" #:effort-quantity (make-measure 4 %effort-unit)
                                #:provider "E_alice" #:receiver "E_bakery"
                                #:planned-within "plan-test")))
      ($ plan-store 'add-commitment cmt))

    (let ((int (make-intent #:id "I-recover" #:action 'work #:resource-conforms-to "spec-bread"
                            #:effort-quantity (make-measure 4 %effort-unit) #:receiver "E_bakery"
                            #:in-scope-of "plan-test")))
      ($ plan-store 'add-intent int)
      ($ ($ scope 'observer) 'register-intent int))

    ;; VF constraint: event can fulfill OR satisfy, not both. The gate
    ;; anchors on satisfies, so that's what this event carries.
    (let ((event (make-economic-event
                   #:id "W-recover" #:action 'work
                   #:provider "E_alice" #:receiver "E_bakery"
                   #:effort-quantity (make-measure 4 %effort-unit) #:created "2026-04-20T09:00:00Z" #:satisfies "I-recover")))
      ($ ($ scope 'observer) 'record-event event)
      ($ account-store 'credit-from-event event))

    ;; Original state
    (check "original commitment exists"
           (commitment-id ($ plan-store 'get-commitment "C-recover")) "C-recover")
    (check "original intent exists"
           (intent-id ($ plan-store 'get-intent "I-recover")) "I-recover")
    (check "alice gross-credited = 4"
           ($ account-store 'citizen-gross "E_alice") 4)

    ;; Tear down: spawn fresh scope without the data
    (let* ((fresh-scope (spawn-scope-root "Bakery"))
           (fresh-plan ($ fresh-scope 'plan-store))
           (fresh-account ($ fresh-scope 'account-store)))

      (check-pred "fresh plan-store empty"
                  (not ($ fresh-plan 'get-commitment "C-recover")))
      (check-pred "fresh account-store empty"
                  (not ($ fresh-account 'holder? "E_alice")))

      ;; Recover from ACDCs (reads same store, replays into fresh scope)
      (recover-economic-state fresh-scope store)

      (check "recovered commitment exists"
             (commitment-id ($ fresh-plan 'get-commitment "C-recover")) "C-recover")
      (check "recovered alice gross-credited = 4"
             ($ fresh-account 'citizen-gross "E_alice") 4)

      ;; Idempotency: recover-economic-state is wired at gateway boot as a
      ;; disaster-recovery fallback that runs AFTER the native-portrait
      ;; restore, so replaying a second time (or over an already-populated
      ;; scope) must not double-count. Work events are the sharp case —
      ;; recording one both appends to the observer log and credits the
      ;; account, neither of which dedups on its own.
      (recover-economic-state fresh-scope store)
      (check "2nd replay: alice STILL gross-credited = 4 (idempotent, no double-credit)"
             ($ fresh-account 'citizen-gross "E_alice") 4)
      (check "2nd replay: observer STILL holds exactly 1 event (no double-append)"
             ($ ($ fresh-scope 'observer) 'event-count) 1))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
