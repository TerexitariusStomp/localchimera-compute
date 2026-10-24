;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-demand-to-proposal.scm — end-to-end:
;;;   demand → weighted voice tally → VF proposal + intent in plan-store
;;;
;;; Scenario: three citizens in the same scope express free-form
;;; demands ("jacuzzi", "couch", "plants") into the scope's
;;; demand-registry, distribute their labor-share-weighted voice over
;;; those demands via an ^expression, and close. The threshold
;;; then decides which demands auto-materialize as <proposal> +
;;; <intent> records in the scope's plan-store via promote-demands.

(use-modules (localchimera test harness)
             (localchimera pools credit-fold) (localchimera scope root) (localchimera vf schemas) (srfi srfi-1)
             (localchimera utils endorsement)
             (localchimera voice delegation-map) (localchimera voice expression) (localchimera voice voice-signer)
             (localchimera scope demand-registry)
             (localchimera voice demand-bridge)
             (goblins)
             (goblins utils hashmap)
             (srfi srfi-1))


(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.001)))
    (< (abs (- a b)) tol)))

(define (synthetic-aid id) (string-append "E_" id))

(define (make-citizen id voice-share)
  (call-with-values
    (lambda () (spawn-voice-signer id (synthetic-aid id)))
    (lambda (voice sealed?)
      (list id voice sealed? (spawn-delegation-map id) voice-share))))

(define (cid c) (list-ref c 0))
(define (voice c) (list-ref c 1))
(define (sealed c) (list-ref c 2))
(define (deleg c) (list-ref c 3))
(define (share c) (list-ref c 4))

(define (registry-of citizens)
  (fold (lambda (c acc) (hashmap-set acc (cid c) (sealed c)))
        (hashmap) citizens))

(define (vdata-of citizens)
  (fold (lambda (c acc) (hashmap-set acc (cid c) (cons (share c) (deleg c))))
        (hashmap) citizens))


;;; ════════════════════════════════════════════════════════════════════════════
;;; End-to-end: demand → tally → promote
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Demand → proposal pipeline ──\n")

(define vat (spawn-vat))

(with-vat vat

  ;; Scope: "floor-3". Three citizens with labor-hour voice-shares:
  ;;   Alice 20h, Bob 5h, Charlie 5h.  (Total: 30h — used as units.)
  (define scope (spawn-scope-root "floor-3"))
  (define alice   (make-citizen "alice"   20))
  (define bob     (make-citizen "bob"      5))
  (define charlie (make-citizen "charlie"  5))
  (define citizens (list alice bob charlie))

  ;; Each citizen proposes a demand into the scope's demand-registry.
  (define dreg ($ scope 'demand-registry))
  (define jacuzzi-id ($ dreg 'propose "alice"   "jacuzzi" '()))
  (define couch-id   ($ dreg 'propose "bob"     "couch"   '()))
  (define plants-id  ($ dreg 'propose "charlie" "plants"  '()))

  (check-pred "demand-registry lists all three demands"
              (= 3 (length ($ dreg 'all))))

  ;; Open an expression with domain='demand whose targets ARE the demand-ids.
  (define demand-ids ($ dreg 'ids))
  (define expr
    (open-expression
      'demand "floor-3-spring-cycle" 'federation
      "What should floor-3 focus on?" demand-ids
      (registry-of citizens) (vdata-of citizens)))

  ;; Citizens distribute their voice over demands.
  ;;   Alice   (20h): 1.0 jacuzzi
  ;;   Bob      (5h): 0.3 jacuzzi, 0.7 couch
  ;;   Charlie  (5h): 0.4 couch,   0.6 plants
  (let ((d (hashmap-set (hashmap) jacuzzi-id 1.0)))
    ($ expr 'cast "alice" (express (voice alice)
                                    'demand "floor-3-spring-cycle" d)))
  (let ((d (hashmap-set (hashmap-set (hashmap)
                                      jacuzzi-id 0.3)
                         couch-id 0.7)))
    ($ expr 'cast "bob" (express (voice bob)
                                  'demand "floor-3-spring-cycle" d)))
  (let ((d (hashmap-set (hashmap-set (hashmap)
                                      couch-id 0.4)
                         plants-id 0.6)))
    ($ expr 'cast "charlie" (express (voice charlie)
                                      'demand "floor-3-spring-cycle" d)))

  ;; Close the expression.
  ($ expr 'close)

  ;; Verify the raw tally before promotion:
  ;;   jacuzzi = 1.0·20 + 0.3·5 = 21.5
  ;;   couch   = 0.7·5  + 0.4·5 =  5.5
  ;;   plants  = 0.6·5          =  3
  (let* ((result ($ expr 'result))
         (tally  (assoc-ref result 'tally)))
    (check-pred "jacuzzi tally ≈ 21.5"
                (approx= 21.5 (hashmap-ref tally jacuzzi-id 0)))
    (check-pred "couch tally ≈ 5.5"
                (approx= 5.5  (hashmap-ref tally couch-id   0)))
    (check-pred "plants tally ≈ 3"
                (approx= 3    (hashmap-ref tally plants-id  0))))

  ;; Promote with threshold 6 hours — only jacuzzi clears.
  (define promoted (promote-demands scope expr 6))

  (check-pred "exactly one demand promoted under threshold=6"
              (= 1 (length promoted)))
  (check-pred "jacuzzi is the one promoted"
              (equal? jacuzzi-id (caar promoted)))

  ;; plan-store should now contain a <proposal> + <intent> for jacuzzi.
  (let* ((ps ($ scope 'plan-store))
         (props ($ ps 'all-proposals))
         (intents ($ ps 'all-intents)))
    (check-pred "plan-store has exactly one proposal"
                (= 1 (length props)))
    (let ((p (car props)))
      (check-pred "proposal name = 'jacuzzi'"
                  (equal? "jacuzzi" (proposal-name p)))
      (check-pred "proposal is a request (demand-side)"
                  (eq? 'request (proposal-purpose p)))
      (check-pred "proposal in-scope-of floor-3"
                  (equal? '("floor-3") (proposal-in-scope-of p)))
      (check-pred "proposal publishes one intent"
                  (= 1 (length (proposal-publishes p))))
      (let* ((iid (car (proposal-publishes p)))
             (i ($ ps 'get-intent iid)))
        (check-pred "referenced intent exists in plan-store"
                    (and i #t))
        (check-pred "intent receiver = scope (open demand)"
                    (equal? "floor-3" (intent-receiver i)))
        (check-pred "intent provider is open (#f)"
                    (not (intent-provider i)))
        (check-pred "intent name carries the description"
                    (equal? "jacuzzi" (intent-name i))))))

  ;; demand-registry should record the promotion link.
  (let ((e ($ dreg 'get jacuzzi-id)))
    (check-pred "jacuzzi demand is marked promoted"
                (string? (demand-entry-promoted-proposal e))))
  (let ((e ($ dreg 'get couch-id)))
    (check-pred "couch demand is NOT promoted"
                (not (demand-entry-promoted-proposal e))))
  (let ((e ($ dreg 'get plants-id)))
    (check-pred "plants demand is NOT promoted"
                (not (demand-entry-promoted-proposal e)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; Lower threshold: all three demands promoted
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Inclusive threshold (threshold=1): all three promoted ──\n")

(define vat2 (spawn-vat))

(with-vat vat2
  (define scope (spawn-scope-root "floor-7"))
  (define alice   (make-citizen "alice"   10))
  (define bob     (make-citizen "bob"     10))
  (define citizens (list alice bob))

  (define dreg ($ scope 'demand-registry))
  (define bench-id  ($ dreg 'propose "alice" "bench" '()))
  (define lamp-id   ($ dreg 'propose "bob"   "lamp"  '()))

  (define expr
    (open-expression
      'demand "floor-7-q1" 'federation "focus" ($ dreg 'ids)
      (registry-of citizens) (vdata-of citizens)))

  (let ((d (hashmap-set (hashmap-set (hashmap) bench-id 0.5) lamp-id 0.5)))
    ($ expr 'cast "alice" (express (voice alice) 'demand "floor-7-q1" d)))
  (let ((d (hashmap-set (hashmap-set (hashmap) bench-id 0.5) lamp-id 0.5)))
    ($ expr 'cast "bob"   (express (voice bob)   'demand "floor-7-q1" d)))

  ($ expr 'close)

  (define promoted (promote-demands scope expr 1))

  (check-pred "both demands clear threshold=1"
              (= 2 (length promoted)))
  (check-pred "plan-store holds two proposals"
              (= 2 (length ($ ($ scope 'plan-store) 'all-proposals))))
  (check-pred "plan-store holds two intents"
              (= 2 (length ($ ($ scope 'plan-store) 'all-intents)))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
