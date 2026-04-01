;;; test-labor-capacity.scm — Labor-as-resource: capacity/capability separation
;;;
;;; Ported from: old/planner/src/lib/tests/labor-as-resource.test.ts
;;;
;;; Intent: Verify the capacity/capability model where:
;;;   - Capacity = ONE resource per agent (hours available)
;;;   - Capability = separate skill resources
;;;   - Work action is non-consuming (does not deplete capacity)
;;;   - Over-offering is allowed (expressing willingness to multiple scopes)
;;;   - ATP gate prevents overcommitment via promoteToCommitment
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-labor-capacity.scm

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))


;;; ── Harness ───────────────────────────────────────────────────────────────────

(define pass-count 0)
(define fail-count 0)

(define (check label got expected)
  (if (equal? got expected)
      (begin (set! pass-count (+ pass-count 1))
             (display (string-append "  PASS  " label "\n")))
      (begin (set! fail-count (+ fail-count 1))
             (display (string-append "  FAIL  " label "\n"))
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write got)      (newline))))

(define (check-pred label pred)
  (if pred
      (begin (set! pass-count (+ pass-count 1))
             (display (string-append "  PASS  " label "\n")))
      (begin (set! fail-count (+ fail-count 1))
             (display (string-append "  FAIL  " label "\n")))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup: Capacity/Capability scope ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Labor Test Commune"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (as ($ scope 'agent-store)))
    ;; Agents
    ($ as 'add-agent (make-agent "agent-alice" 'person "Alice" #f #f #f #f #f))
    ($ as 'add-agent (make-agent "agent-bob" 'person "Bob" #f #f #f #f #f))
    ($ as 'add-agent (make-agent "agent-commune" 'organization "Labor Commune"
                                 #f #f #f #f #f))
    (check-pred "agents seeded" (= 3 (length ($ as 'all-agents))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Seed capacity resource
;;;
;;; Ported from: "seedCapacityResource creates a capacity resource"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Capacity resource seeding ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Alice: 40 hours capacity
    ($ obs 'seed-resource
       (make-economic-resource "capacity:alice" "Alice Capacity" #f #f #f
         "spec:agent-capacity" #f
         (make-measure 40 "hours") (make-measure 40 "hours")
         #f #f "agent-alice" #f #f #f #f #f #f #f #f))

    ;; Bob: 30 hours capacity
    ($ obs 'seed-resource
       (make-economic-resource "capacity:bob" "Bob Capacity" #f #f #f
         "spec:agent-capacity" #f
         (make-measure 30 "hours") (make-measure 30 "hours")
         #f #f "agent-bob" #f #f #f #f #f #f #f #f))

    ;; Verify
    (let ((alice-cap ($ obs 'get-resource "capacity:alice"))
          (bob-cap ($ obs 'get-resource "capacity:bob")))
      (check "alice capacity: 40h"
             (measure-has-numerical-value (economic-resource-accounting-quantity alice-cap))
             40)
      (check "bob capacity: 30h"
             (measure-has-numerical-value (economic-resource-accounting-quantity bob-cap))
             30)
      (check "alice accountable"
             (economic-resource-primary-accountable alice-cap)
             "agent-alice"))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Capability (skills) separate from capacity
;;;
;;; Ported from: "skillsOf excludes capacity resources"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Capability vs capacity ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed a skill resource for Alice (welding certification)
    ($ obs 'seed-resource
       (make-economic-resource "skill:alice:welding" "Welding Cert" #f #f #f
         "spec:welding-certified" #f
         (make-measure 1 "certification") (make-measure 1 "certification")
         #f #f "agent-alice" #f #f #f #f #f #f #f #f))

    ;; Alice has: capacity resource + skill resource
    ;; Query all resources for alice
    (let ((alice-resources
            (filter (lambda (r)
                      (equal? "agent-alice" (economic-resource-primary-accountable r)))
                    ($ obs 'all-resources))))
      (check-pred "alice has 2 resources" (= 2 (length alice-resources)))

      ;; Capacity query: find the one with spec:agent-capacity
      (let ((cap (find (lambda (r)
                         (equal? "spec:agent-capacity"
                                 (economic-resource-conforms-to r)))
                       alice-resources)))
        (check-pred "capacity resource found" (economic-resource? cap))
        (check "capacity id" (economic-resource-id cap) "capacity:alice"))

      ;; Skill query: find non-capacity resources
      (let ((skills (filter (lambda (r)
                              (not (equal? "spec:agent-capacity"
                                           (economic-resource-conforms-to r))))
                            alice-resources)))
        (check-pred "skills found" (= 1 (length skills)))
        (check "skill id" (economic-resource-id (car skills)) "skill:alice:welding")))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Work events do not change capacity (non-consuming)
;;;
;;; Ported from: "work events do not change onhandQuantity"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Work is non-consuming ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Record work event: Alice works 8 hours
    ($ obs 'record-event
       (make-economic-event
         "ev-work-alice" 'work "proc-welding" #f
         "capacity:alice" #f "spec:agent-capacity" #f
         "agent-alice" "agent-alice"
         #f (make-measure 8 "hours")
         #f #f "2026-03-28T10:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ;; Onhand should remain 40 (work doesn't consume)
    (let ((r ($ obs 'get-resource "capacity:alice")))
      (check "work: alice onhand=40"
             (measure-has-numerical-value (economic-resource-onhand-quantity r))
             40)
      ;; primaryAccountable shouldn't change either
      (check "work: accountable unchanged"
             (economic-resource-primary-accountable r)
             "agent-alice"))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Over-offering is allowed
;;;
;;; Ported from: "over-offering is allowed — total offers can exceed capacity"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Over-offering ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ($ ps 'add-plan (make-plan "plan-labor" "Labor Plan" #f
                               "2026-04-07T00:00:00Z" "2026-03-27T00:00:00Z"
                               #f #f #f))

    ;; Alice has 40h but offers 30 + 20 + 10 = 60h total (over-offer)
    ($ ps 'add-intent
       (make-intent "i-offer-1" 'work "Alice work offer 1" #f #f
                    "proc-a" #f #f #f #f
                    #f (make-measure 30 "hours")
                    #f #f
                    "agent-alice" #f
                    #f #f #f #f
                    #f #f #f "plan-labor" #f #f #f #f))
    ($ ps 'add-intent
       (make-intent "i-offer-2" 'work "Alice work offer 2" #f #f
                    "proc-b" #f #f #f #f
                    #f (make-measure 20 "hours")
                    #f #f
                    "agent-alice" #f
                    #f #f #f #f
                    #f #f #f "plan-labor" #f #f #f #f))
    ($ ps 'add-intent
       (make-intent "i-offer-3" 'work "Alice work offer 3" #f #f
                    "proc-c" #f #f #f #f
                    #f (make-measure 10 "hours")
                    #f #f
                    "agent-alice" #f
                    #f #f #f #f
                    #f #f #f "plan-labor" #f #f #f #f))

    ;; All three intents should be created without error
    (check-pred "offer 1 created" (intent? ($ ps 'get-intent "i-offer-1")))
    (check-pred "offer 2 created" (intent? ($ ps 'get-intent "i-offer-2")))
    (check-pred "offer 3 created" (intent? ($ ps 'get-intent "i-offer-3")))
    (check-pred "total offers (60h) exceeds capacity (40h) — allowed"
                (= 3 (length (filter (lambda (i) (eq? 'work (intent-action i)))
                                     ($ ps 'all-intents)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. ATP gate: commitment within capacity succeeds
;;;
;;; Ported from: "promoteToCommitment succeeds when within capacity"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── ATP gate ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; Promote first offer (30h) to commitment — within 40h capacity
    (let ((cid ($ ps 'promote-to-commitment "i-offer-1"
                  (list (cons 'receiver "agent-commune")))))
      (check-pred "commitment within capacity: created"
                  (commitment? ($ ps 'get-commitment cid)))
      (let ((c ($ ps 'get-commitment cid)))
        (check "commitment: action=work" (commitment-action c) 'work)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. ATP gate: exact boundary
;;;
;;; Ported from: "ATP gate allows commitment up to exact capacity"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── ATP gate exact boundary ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ;; Already committed 30h. 30 + 10 = 40 = capacity → should succeed
    ;; (using offer-3 which is 10h)
    (let ((cid ($ ps 'promote-to-commitment "i-offer-3"
                  (list (cons 'receiver "agent-commune")))))
      (check-pred "exact capacity: commitment created"
                  (commitment? ($ ps 'get-commitment cid))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Intent unilaterality
;;;
;;; Ported from: planning-constraints H4 "Intent unilaterality"
;;; VF spec: An intent should have provider XOR receiver, not both.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Intent unilaterality ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ;; Only provider → ok
    ($ ps 'add-intent
       (make-intent "i-uni-prov" 'transfer "Unilateral provider" #f #f
                    #f #f #f "spec-wheat" #f
                    (make-measure 10 "kg") #f #f #f
                    "agent-alice" #f
                    #f #f #f #f
                    #f #f #f "plan-labor" #f #f #f #f))
    (check-pred "provider only: ok" (intent? ($ ps 'get-intent "i-uni-prov")))

    ;; Only receiver → ok
    ($ ps 'add-intent
       (make-intent "i-uni-recv" 'transfer "Unilateral receiver" #f #f
                    #f #f #f "spec-wheat" #f
                    (make-measure 10 "kg") #f #f #f
                    #f "agent-bob"
                    #f #f #f #f
                    #f #f #f "plan-labor" #f #f #f #f))
    (check-pred "receiver only: ok" (intent? ($ ps 'get-intent "i-uni-recv")))

    ;; Neither → ok (open intent)
    ($ ps 'add-intent
       (make-intent "i-uni-none" 'transfer "Open intent" #f #f
                    #f #f #f "spec-wheat" #f
                    (make-measure 10 "kg") #f #f #f
                    #f #f
                    #f #f #f #f
                    #f #f #f "plan-labor" #f #f #f #f))
    (check-pred "neither: ok" (intent? ($ ps 'get-intent "i-uni-none")))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Persistence round-trip
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Persistence ──\n")

(define-values (vat2 scope2)
  (spawn-persistent-vat
    scope-env
    (lambda () (error "Should restore!"))
    store))

(with-vat vat2
  (let ((obs ($ scope2 'observer))
        (ps ($ scope2 'plan-store)))
    ;; Capacity preserved
    (let ((r ($ obs 'get-resource "capacity:alice")))
      (check "restored: alice capacity=40"
             (measure-has-numerical-value (economic-resource-onhand-quantity r))
             40))

    ;; Commitments preserved
    (check-pred "restored: has commitments"
                (>= (length ($ ps 'all-commitments)) 2))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(when (> fail-count 0) (exit 1))
