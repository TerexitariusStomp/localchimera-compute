;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-ballot.scm — Liquid democracy ballot mechanism
;;;
;;; Validates the cross-cutting override semantic: a citizen who casts
;;; directly on a ballot must NOT flow their voice to their delegates for
;;; that ballot. Also tests transitive delegation, cycle rejection,
;;; revocation snapshot isolation, scope-specific overrides, and
;;; over-delegation validation.

(use-modules (playnet test harness))
(use-modules (playnet pools credit-fold) (srfi srfi-1))
(use-modules (playnet utils endorsement))
(use-modules (playnet voice ballot) (playnet voice delegation-map) (playnet voice voice-signer))
(use-modules (goblins)
             (goblins utils hashmap))


(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.001)))
    (< (abs (- a b)) tol)))


;;; Helper: spawn a simple voice-registry for n citizens, each with N hours
;;; of labor contribution. Returns a list of citizen records:
;;;   ((id voice-actor sealed?-actor delegation-map voice-share) ...)

(define (synthetic-aid citizen-id)
  ;; Tests use a deterministic fake AID per citizen. Production callers
  ;; pass a real qb64 KERI AID. The default credential-check is
  ;; always-true, so the AID's only job here is to round-trip through the
  ;; cleartext stance.
  (string-append "E_test_aid_" citizen-id))

(define* (make-citizen citizen-id voice-share
                       #:optional (keri-aid (synthetic-aid citizen-id)))
  (call-with-values
    (lambda () (spawn-voice-signer citizen-id keri-aid))
    (lambda (voice sealed?)
      (list citizen-id voice sealed? (spawn-delegation-map citizen-id)
            voice-share))))

(define (citizen-id c)       (list-ref c 0))
(define (citizen-voice c)    (list-ref c 1))
(define (citizen-sealed? c)  (list-ref c 2))
(define (citizen-deleg c)    (list-ref c 3))
(define (citizen-share c)    (list-ref c 4))

(define (registry-of citizens)
  (fold (lambda (c acc) (hashmap-set acc (citizen-id c) (citizen-sealed? c)))
        (hashmap) citizens))

(define (voice-data-of citizens)
  (fold (lambda (c acc)
          (hashmap-set acc (citizen-id c)
                       (cons (citizen-share c) (citizen-deleg c))))
        (hashmap) citizens))

(define (tally-result ballot-ref)
  "Return the 'tally hashmap from a tally call."
  (assoc-ref ($ ballot-ref 'tally) 'tally))

(define (tally-abstain ballot-ref)
  (assoc-ref ($ ballot-ref 'tally) 'abstain))

(define (weight-for position tally-map)
  (hashmap-ref tally-map position 0))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Basic cast — citizen's stance gets their voice-share
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Basic cast ──\n")

(define vat1 (spawn-vat))

(with-vat vat1
  (define alice (make-citizen "alice" 10))
  (define bob   (make-citizen "bob"   20))
  (define citizens (list alice bob))
  (define b (open-ballot 'policy "p-1" 'federation "test"
                         (registry-of citizens)
                         (voice-data-of citizens)))
  ($ b 'cast "alice" ($ (citizen-voice alice) 'stance "p-1" 'yes))
  ;; Actually `cast` returns via bcom — re-spawn not needed with with-vat
  ;; The cast mutation has taken effect through bcom.
  (let ((tally (tally-result b)))
    (check-pred "alice's yes gets her 10" (= 10 (weight-for 'yes tally)))
    (check-pred "no other positions" (= 0 (weight-for 'no tally))))
  (check-pred "bob abstains → 20 unexercised" (= 20 (tally-abstain b))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Pure delegation — Alice 100% to Bob, Bob casts
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Pure delegation ──\n")

(define vat2 (spawn-vat))

(with-vat vat2
  (define alice (make-citizen "alice" 10))
  (define bob   (make-citizen "bob"   20))
  (define citizens (list alice bob))
  ;; Alice delegates 100% to Bob (federation-default)
  ($ (citizen-deleg alice) 'delegate "bob" 1)
  (define b (open-ballot 'policy "p-2" 'federation "test"
                         (registry-of citizens)
                         (voice-data-of citizens)))
  ($ b 'cast "bob" ($ (citizen-voice bob) 'stance "p-2" 'yes))
  (let ((tally (tally-result b)))
    (check-pred "bob's yes gets 30 (alice 10 + bob 20)"
                (= 30 (weight-for 'yes tally)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Direct override — Alice delegates 40% to Bob, Alice casts directly
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Direct override ──\n")

(define vat3 (spawn-vat))

(with-vat vat3
  (define alice (make-citizen "alice" 10))
  (define bob   (make-citizen "bob"   20))
  (define citizens (list alice bob))
  ($ (citizen-deleg alice) 'delegate "bob" 0.4)
  (define b (open-ballot 'policy "p-3" 'federation "test"
                         (registry-of citizens)
                         (voice-data-of citizens)))
  ;; Alice casts directly → override, her full voice goes to yes
  ($ b 'cast "alice" ($ (citizen-voice alice) 'stance "p-3" 'yes))
  ;; Bob casts no
  ($ b 'cast "bob" ($ (citizen-voice bob) 'stance "p-3" 'no))
  (let ((tally (tally-result b)))
    ;; Alice's full 10 goes to yes (override reclaims all)
    ;; Bob's 20 goes to no; Bob does NOT get any of Alice's 4
    (check-pred "alice's yes = 10 (full override)"
                (= 10 (weight-for 'yes tally)))
    (check-pred "bob's no = 20 (no inflow from overriding alice)"
                (= 20 (weight-for 'no tally))))
  (check-pred "no abstention" (= 0 (tally-abstain b))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Partial delegation + abstention
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Partial delegation + abstention ──\n")

(define vat4 (spawn-vat))

(with-vat vat4
  (define alice (make-citizen "alice" 10))
  (define bob   (make-citizen "bob"   20))
  (define citizens (list alice bob))
  ($ (citizen-deleg alice) 'delegate "bob" 0.4)
  (define b (open-ballot 'policy "p-4" 'federation "test"
                         (registry-of citizens)
                         (voice-data-of citizens)))
  ;; Alice does not cast; Bob casts yes.
  ($ b 'cast "bob" ($ (citizen-voice bob) 'stance "p-4" 'yes))
  (let ((tally (tally-result b)))
    ;; Bob gets his 20 + 0.4 × 10 = 24
    (check-pred "bob's yes = 24" (approx= 24 (weight-for 'yes tally))))
  ;; 0.6 × 10 = 6 unexercised
  (check-pred "abstention = 6" (approx= 6 (tally-abstain b))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Transitive delegation — Alice → Bob → Carol
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. Transitive delegation ──\n")

(define vat5 (spawn-vat))

(with-vat vat5
  (define alice (make-citizen "alice" 10))
  (define bob   (make-citizen "bob"   20))
  (define carol (make-citizen "carol" 30))
  (define citizens (list alice bob carol))
  ($ (citizen-deleg alice) 'delegate "bob"   1)
  ($ (citizen-deleg bob)   'delegate "carol" 1)
  (define b (open-ballot 'policy "p-5" 'federation "test"
                         (registry-of citizens)
                         (voice-data-of citizens)))
  ($ b 'cast "carol" ($ (citizen-voice carol) 'stance "p-5" 'yes))
  (let ((tally (tally-result b)))
    (check-pred "carol gets 60 (alice 10 + bob 20 + carol 30)"
                (= 60 (weight-for 'yes tally)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Mid-chain override — Bob casts, short-circuits Alice→Bob→Carol
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 6. Mid-chain override ──\n")

(define vat6 (spawn-vat))

(with-vat vat6
  (define alice (make-citizen "alice" 10))
  (define bob   (make-citizen "bob"   20))
  (define carol (make-citizen "carol" 30))
  (define citizens (list alice bob carol))
  ($ (citizen-deleg alice) 'delegate "bob"   1)
  ($ (citizen-deleg bob)   'delegate "carol" 1)
  (define b (open-ballot 'policy "p-6" 'federation "test"
                         (registry-of citizens)
                         (voice-data-of citizens)))
  ;; Bob casts → takes Alice+Bob; Carol gets 0 from this chain
  ($ b 'cast "bob" ($ (citizen-voice bob) 'stance "p-6" 'yes))
  ($ b 'cast "carol" ($ (citizen-voice carol) 'stance "p-6" 'no))
  (let ((tally (tally-result b)))
    (check-pred "bob's yes = 30 (alice + bob; override)"
                (= 30 (weight-for 'yes tally)))
    (check-pred "carol's no = 30 (just her own)"
                (= 30 (weight-for 'no tally)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Cycle rejection
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 7. Cycle rejection ──\n")
;; Phase-2 simplification: cycle check is deferred. The tally uses a visited
;; set per resolution chain to prevent infinite recursion in case cycles
;; slip through (belt-and-suspenders). For now, test infinite-recursion
;; safety by running a small cycle through the tally; full cycle rejection
;; at delegate-time is tracked in the plan's follow-up.

;; Skip: cycle-rejection test (requires additional per-ballot-open guard)
;; Marked intentionally as deferred.


;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Revocation snapshot isolation
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 8. Revocation snapshot isolation ──\n")

(define vat8 (spawn-vat))

(with-vat vat8
  (define alice (make-citizen "alice" 10))
  (define bob   (make-citizen "bob"   20))
  (define citizens (list alice bob))
  ($ (citizen-deleg alice) 'delegate "bob" 1)
  (define b1 (open-ballot 'policy "p-8a" 'federation "test"
                          (registry-of citizens)
                          (voice-data-of citizens)))
  ;; Revoke AFTER ballot open — current ballot's snapshot unaffected
  ($ (citizen-deleg alice) 'revoke "bob")
  ;; Bob casts — current ballot still flows Alice → Bob (snapshot frozen)
  ($ b1 'cast "bob" ($ (citizen-voice bob) 'stance "p-8a" 'yes))
  (let ((tally (tally-result b1)))
    (check-pred "snapshot frozen: bob still gets alice's voice"
                (= 30 (weight-for 'yes tally))))

  ;; Open a NEW ballot after revocation: alice no longer delegates to bob
  (define b2 (open-ballot 'policy "p-8b" 'federation "test"
                          (registry-of citizens)
                          (voice-data-of citizens)))
  ($ b2 'cast "bob" ($ (citizen-voice bob) 'stance "p-8b" 'yes))
  (let ((tally (tally-result b2)))
    (check-pred "new ballot: bob gets only his own 20"
                (= 20 (weight-for 'yes tally))))
  (check-pred "new ballot: alice's 10 unexercised"
              (= 10 (tally-abstain b2))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 9. Invalid seal rejected
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 9. Invalid seal rejected ──\n")

(define vat9 (spawn-vat))

(with-vat vat9
  (define alice (make-citizen "alice" 10))
  (define mallory (make-citizen "mallory" 5))
  (define citizens (list alice mallory))
  (define b (open-ballot 'policy "p-9" 'federation "test"
                         (registry-of citizens)
                         (voice-data-of citizens)))
  ;; Mallory signs a stance claiming to be Alice.
  ;; Her own voice returns a bundle attributing to "mallory"; even if we
  ;; repack it as "alice", the seal won't match alice's sealed?-actor.
  (let ((mallory-stance ($ (citizen-voice mallory) 'stance "p-9" 'yes)))
    (check-pred "submitting mallory's stance as alice rejected"
                (catch #t
                  (lambda ()
                    ($ b 'cast "alice" mallory-stance)
                    #f)
                  (lambda _ #t)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 10. Federation franchise (multi-scope, same vat)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 10. Federation franchise ──\n")

(define vat10 (spawn-vat))

(with-vat vat10
  ;; Simulate voice-shares as if derived from two scopes.
  ;; Here we just set them manually — the ballot doesn't care where the
  ;; shares came from, only the snapshot.
  (define alice (make-citizen "alice" 15))  ; 10 in watershed + 5 in tech-coop
  (define bob   (make-citizen "bob"   25))  ; 20 + 5
  (define citizens (list alice bob))
  (define b (open-ballot 'policy "p-10" 'federation "federation decision"
                         (registry-of citizens)
                         (voice-data-of citizens)))
  ($ b 'cast "alice" ($ (citizen-voice alice) 'stance "p-10" 'yes))
  ($ b 'cast "bob"   ($ (citizen-voice bob)   'stance "p-10" 'no))
  (let ((tally (tally-result b)))
    (check-pred "alice yes = 15" (= 15 (weight-for 'yes tally)))
    (check-pred "bob no = 25" (= 25 (weight-for 'no tally)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 11. Scope-specific delegation override
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 11. Scope-specific delegation override ──\n")

(define vat11 (spawn-vat))

(with-vat vat11
  (define alice (make-citizen "alice" 10))
  (define bob   (make-citizen "bob"   20))
  (define citizens (list alice bob))
  ;; Federation default: delegate 0.3 to bob
  ($ (citizen-deleg alice) 'delegate "bob" 0.3)
  ;; Watershed scope override: delegate 0.5 to bob
  ($ (citizen-deleg alice) 'delegate "bob" 0.5 'scope "watershed")

  ;; Ballot in watershed — scope override applies
  (define bw (open-ballot 'policy "p-11w" '(scope "watershed") "watershed decision"
                          (registry-of citizens)
                          (voice-data-of citizens)))
  ($ bw 'cast "bob" ($ (citizen-voice bob) 'stance "p-11w" 'yes))
  (let ((tally (tally-result bw)))
    ;; Bob: 20 own + 0.5 × 10 from alice = 25
    (check-pred "watershed: bob gets 25 (0.5 × alice)"
                (approx= 25 (weight-for 'yes tally))))

  ;; Ballot in tech-coop — federation default applies
  (define bt (open-ballot 'policy "p-11t" '(scope "tech-coop") "tech decision"
                          (registry-of citizens)
                          (voice-data-of citizens)))
  ($ bt 'cast "bob" ($ (citizen-voice bob) 'stance "p-11t" 'yes))
  (let ((tally (tally-result bt)))
    ;; Bob: 20 own + 0.3 × 10 from alice = 23
    (check-pred "tech-coop: bob gets 23 (0.3 × alice)"
                (approx= 23 (weight-for 'yes tally)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 12. Scope override adds new delegate
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 12. Scope override adds new delegate ──\n")

(define vat12 (spawn-vat))

(with-vat vat12
  (define alice (make-citizen "alice" 10))
  (define bob   (make-citizen "bob"   20))
  (define dave  (make-citizen "dave"  30))
  (define citizens (list alice bob dave))
  ($ (citizen-deleg alice) 'delegate "bob" 0.3)
  ;; Tech-coop override: also delegate 0.2 to dave (bob still 0.3 from fed default)
  ($ (citizen-deleg alice) 'delegate "dave" 0.2 'scope "tech-coop")

  (define bt (open-ballot 'policy "p-12" '(scope "tech-coop") "test"
                          (registry-of citizens)
                          (voice-data-of citizens)))
  ($ bt 'cast "bob"  ($ (citizen-voice bob)  'stance "p-12" 'yes))
  ($ bt 'cast "dave" ($ (citizen-voice dave) 'stance "p-12" 'no))
  (let ((tally (tally-result bt)))
    ;; Bob: 20 own + 0.3 × 10 = 23
    (check-pred "bob yes = 23" (approx= 23 (weight-for 'yes tally)))
    ;; Dave: 30 own + 0.2 × 10 = 32
    (check-pred "dave no = 32" (approx= 32 (weight-for 'no tally)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 13. Validation rejects over-delegation
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 13. Over-delegation rejected ──\n")

(define vat13 (spawn-vat))

(with-vat vat13
  (define alice (make-citizen "alice" 10))
  (define dm (citizen-deleg alice))
  ($ dm 'delegate "bob" 0.6)
  ;; Attempt to add a scope-override that makes resolved sum > 1
  (check-pred "scope override that over-delegates is rejected"
              (catch #t
                (lambda ()
                  ($ dm 'delegate "carol" 0.5 'scope "watershed")
                  #f)
                (lambda _ #t))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 14. Mandate: delegate complies → voice flows
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 14. Mandate: delegate complies ──\n")

(define vat14 (spawn-vat))

(with-vat vat14
  (define alice (make-citizen "alice" 10))
  (define bob   (make-citizen "bob"   20))
  (define citizens (list alice bob))
  ;; Alice instructs Bob: "on this proposal you must vote yes"
  ($ (citizen-deleg alice) 'delegate-mandated "bob" 1
     (lambda (stance) (eq? (caddr stance) 'yes)))
  (define b (open-ballot 'policy "p-14" 'federation "test"
                         (registry-of citizens)
                         (voice-data-of citizens)))
  ;; Bob complies: votes yes
  ($ b 'cast "bob" ($ (citizen-voice bob) 'stance "p-14" 'yes))
  (let ((tally (tally-result b)))
    (check-pred "mandate satisfied: bob yes = 30"
                (= 30 (weight-for 'yes tally)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 15. Mandate: delegate deviates → voice abstained
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 15. Mandate: delegate deviates ──\n")

(define vat15 (spawn-vat))

(with-vat vat15
  (define alice (make-citizen "alice" 10))
  (define bob   (make-citizen "bob"   20))
  (define citizens (list alice bob))
  ($ (citizen-deleg alice) 'delegate-mandated "bob" 1
     (lambda (stance) (eq? (caddr stance) 'yes)))
  (define b (open-ballot 'policy "p-15" 'federation "test"
                         (registry-of citizens)
                         (voice-data-of citizens)))
  ;; Bob votes 'no — violates Alice's mandate
  ($ b 'cast "bob" ($ (citizen-voice bob) 'stance "p-15" 'no))
  (let ((tally (tally-result b)))
    ;; Bob's own 20 goes to no. Alice's 10 is held (mandate violated).
    (check-pred "bob's own voice (20) counts on no"
                (= 20 (weight-for 'no tally)))
    (check-pred "alice's 10 is abstained, not flowed to bob"
                (= 10 (tally-abstain b)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 16. Mandate must-act: delegate doesn't cast → voice abstained
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 16. Mandate must-act: delegate absent ──\n")

(define vat16 (spawn-vat))

(with-vat vat16
  (define alice (make-citizen "alice" 10))
  (define bob   (make-citizen "bob"   20))
  (define citizens (list alice bob))
  ($ (citizen-deleg alice) 'delegate-mandated "bob" 1
     (lambda (stance) (eq? (caddr stance) 'yes)))
  (define b (open-ballot 'policy "p-16" 'federation "test"
                         (registry-of citizens)
                         (voice-data-of citizens)))
  ;; Bob doesn't cast at all. Under must-act semantics, the mandate fails.
  (let ((tally (tally-result b)))
    (check-pred "no votes cast" (= 0 (weight-for 'yes tally)))
    (check-pred "alice's 10 abstained + bob's 20 abstained = 30"
                (= 30 (tally-abstain b)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 17. Mandate + override: Alice overrides, mandate irrelevant for this ballot
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 17. Mandate + override ──\n")

(define vat17 (spawn-vat))

(with-vat vat17
  (define alice (make-citizen "alice" 10))
  (define bob   (make-citizen "bob"   20))
  (define citizens (list alice bob))
  ;; Alice has mandated Bob to vote yes
  ($ (citizen-deleg alice) 'delegate-mandated "bob" 1
     (lambda (stance) (eq? (caddr stance) 'yes)))
  (define b (open-ballot 'policy "p-17" 'federation "test"
                         (registry-of citizens)
                         (voice-data-of citizens)))
  ;; Alice overrides by voting directly 'no — her full voice goes to no,
  ;; mandate does not apply because Alice's override reclaims her voice.
  ($ b 'cast "alice" ($ (citizen-voice alice) 'stance "p-17" 'no))
  ;; Bob votes 'no (would violate the mandate if flow occurred, but
  ;; Alice's override means her voice never flows to him)
  ($ b 'cast "bob" ($ (citizen-voice bob) 'stance "p-17" 'no))
  (let ((tally (tally-result b)))
    ;; Alice 10 + Bob 20 = 30, all on 'no
    (check-pred "total no = 30 (alice + bob)"
                (= 30 (weight-for 'no tally)))
    (check-pred "no abstention" (= 0 (tally-abstain b)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 18. Mixed: partial liquid + partial mandated
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 18. Mixed liquid + mandated delegations ──\n")

(define vat18 (spawn-vat))

(with-vat vat18
  (define alice (make-citizen "alice" 10))
  (define bob   (make-citizen "bob"   20))
  (define carol (make-citizen "carol" 30))
  (define citizens (list alice bob carol))
  ;; 0.4 liquid to bob; 0.6 mandated-yes to carol
  ($ (citizen-deleg alice) 'delegate "bob" 0.4)
  ($ (citizen-deleg alice) 'delegate-mandated "carol" 0.6
     (lambda (stance) (eq? (caddr stance) 'yes)))
  (define b (open-ballot 'policy "p-18" 'federation "test"
                         (registry-of citizens)
                         (voice-data-of citizens)))
  ($ b 'cast "bob"   ($ (citizen-voice bob)   'stance "p-18" 'no))
  ;; Carol deviates — votes 'no instead of mandated 'yes
  ($ b 'cast "carol" ($ (citizen-voice carol) 'stance "p-18" 'no))
  (let ((tally (tally-result b)))
    ;; Flow:
    ;;   Alice (no cast) → 0.4×10=4 liquid to Bob (flows)
    ;;                   → 0.6×10=6 mandated to Carol (mandate violated, abstained)
    ;;   Bob own 20 + 4 from Alice = 24 on 'no
    ;;   Carol own 30 on 'no
    ;;   Total 'no = 54, abstention 6.
    (check-pred "total no = 54 (bob 24 + carol 30)"
                (approx= 54 (weight-for 'no tally)))
    (check-pred "abstention = 6 (alice's mandated portion to carol)"
                (approx= 6 (tally-abstain b)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 19. Self-cycle delegation rejected
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 19. Self-cycle rejected ──\n")

(define vat19 (spawn-vat))

(with-vat vat19
  (define alice (make-citizen "alice" 10))
  (check-pred "alice → alice rejected"
              (catch #t
                (lambda ()
                  ($ (citizen-deleg alice) 'delegate "alice" 1)
                  #f)
                (lambda _ #t))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 20. Cross-citizen cycle: tally guard breaks it (abstention)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 20. Tally cycle guard ──\n")

(define vat20 (spawn-vat))

(with-vat vat20
  (define alice (make-citizen "alice" 10))
  (define bob   (make-citizen "bob"   20))
  (define citizens (list alice bob))
  ;; Construct A → B and B → A. Each individual delegate-map's self-cycle
  ;; check passes (neither is self-delegating). The tally's cycle guard
  ;; catches the cross-citizen loop.
  ($ (citizen-deleg alice) 'delegate "bob" 1)
  ($ (citizen-deleg bob)   'delegate "alice" 1)
  (define b (open-ballot 'policy "p-20" 'federation "test"
                         (registry-of citizens)
                         (voice-data-of citizens)))
  ;; Neither casts. Both voices flow into the cycle and are abstained.
  (let ((tally (tally-result b)))
    (check-pred "no positions tallied"
                (= 0 (hashmap-fold (lambda (_k _v a) (+ a 1)) 0 tally))))
  (check-pred "all 30 voice abstained (cycle broken safely)"
              (= 30 (tally-abstain b))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 21. Close authorization (when close-authority is set)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 21. Close authorization ──\n")

(define vat21 (spawn-vat))

(with-vat vat21
  (define alice (make-citizen "alice" 10))
  (define citizens (list alice))
  (call-with-values
    (lambda () (make-endorsement-authority))
    (lambda (gov-seal _u gov-sealed?)
      (define b (open-ballot 'policy "p-21" 'federation "test"
                             (registry-of citizens)
                             (voice-data-of citizens)
                             #:close-authority gov-sealed?))
      (check-pred "close without auth rejected"
                  (catch #t
                    (lambda () ($ b 'close) #f)
                    (lambda _ #t)))
      (check-pred "close with valid gov-cap accepted"
                  (catch #t
                    (lambda ()
                      (let ((cap ($ gov-seal "operator")))
                        ($ b 'close cap)
                        #t))
                    (lambda _ #f))))))

;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
