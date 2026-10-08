;;; test-external-asset-claim.scm — buying external liquidity with credits
;;;
;;; playnet.typ §Credits and external liquidity: an external asset (XMR,
;;; fiat) enters the commons as a resource spec priced by its ACQUISITION
;;; recipe — crystallized SNLT = the labour of acquisition — and citizens
;;; claim it against earned credit exactly like bread, one-directionally.
;;; Validates: bootstrap wires spec + recipe + claimable resource; a
;;; donation ('raise) fills the pool; a claim at server-derived cost
;;; (qty × acquisition-SNLT) draws the citizen's balance; over-draw fails.
;;; Run: guile -L module tests/planner/test-external-asset-claim.scm

(use-modules (playnet test harness))
(use-modules (playnet planner scope root) (playnet planner vf schemas))
(use-modules (playnet planner doors service))
(use-modules (playnet monero specs))
(use-modules ((playnet planner facts rail) #:select (declare-rail!)))
(use-modules ((playnet test scope) #:select (plan-claim!)))   ; the plan's row, stood by the fixture
(use-modules (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(define (work! obs aid skill hours eid iid)
  ($ obs 'register-intent
     (make-intent #:id iid #:action 'work #:resource-conforms-to skill
                  #:effort-quantity (make-measure hours "hour") #:provider aid))
  ($ obs 'record-event
     (make-economic-event #:id eid #:action 'work #:resource-conforms-to skill #:provider aid
                          #:effort-quantity (make-measure hours "hour")
                          #:has-point-in-time "2026-03-01T08:00:00Z" #:satisfies iid
                          #:in-scope-of '())))

(define (raise-xmr! obs xmr)
  ;; the poller's donation event, in miniature: XMR arriving on-chain
  ($ obs 'record-event
     (make-economic-event #:id "ev-donation" #:action 'raise
       #:resource-inventoried-as %xmr-resource-id #:resource-conforms-to "spec-xmr" #:resource-classified-as '("donation") #:receiver "agent-playnet"
       #:resource-quantity (make-measure xmr "XMR") #:in-scope-of '())))

(define vat (spawn-vat))
(define SR #f)
(define svc-ref
  (with-vat vat
    (let* ((sr  (begin (set! SR (spawn-scope-root "External Scope")) SR))
           (obs ($ sr 'observer))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "s1" sr))))
      ;; XMR on the claimable rail: spec + acquisition recipe (20 h/XMR) + pool
      (bootstrap-monero-resource! sr)
      (declare-rail! %xmr-spec-id 'individual)   ; stands in for the plan: made by the acquisition recipe, nobody's input
      (plan-claim! obs %xmr-spec-id "alice" 1)   ; …and the plan's rows: 1 XMR for alice, 2 for bob
      (plan-claim! obs %xmr-spec-id "bob" 2)
      ;; alice earns 40 validated hours; 1 XMR arrives by donation
      (work! obs "alice" "spec-labor" 40 "ev1" "in1")
      (raise-xmr! obs 1)
      svc)))

(with-vat vat
  (let ((svc svc-ref))
    (display "\n── the acquisition recipe prices the asset ──\n")
    (let ((r ($ svc 'credit-balance "s1" "alice")))
      (check "alice gross = 40" (assq-ref (cdr r) 'balance) 40))

    (display "\n── claim 1 XMR at the derived acquisition cost (20 h) ──\n")
    (let ((r ($ svc 'claim "s1" %xmr-resource-id 1 "alice" #f)))
      (check "claim ok"          (car r) 'ok)
      (check "cost = 20 h/XMR"   (= 20 (assq-ref (cdr r) 'claimed)) #t)
      (check "balance 40 − 20"   (= 20 (assq-ref (cdr r) 'balance)) #t)
      (check "credit block rides" (number? (assq-ref (assq-ref (cdr r) 'credit) 'drawable)) #t))

    (display "\n── the boundary is one-directional: over-draw fails ──\n")
    (let ((r ($ svc 'claim "s1" %xmr-resource-id 5 "alice" #f)))
      (check "5 XMR = 100 h > balance → error" (car r) 'error))

    (display "\n── solvency: a claim draws on what the pool holds ──\n")
    ;; bob earns plenty; the pool holds 0 XMR now (alice took the 1)
    (let ((obs ($ SR 'observer)))
      (work! obs "bob" "spec-labor" 400 "ev2" "in2"))
    (let ((r ($ svc 'claim "s1" %xmr-resource-id 1 "bob" #f)))
      (check "credit enough, pool empty → refused at the door" (car r) 'error)
      (check "…and it says so" (and (string-contains (cdr r) "pool holds") #t)))
    ;; the wallet's live reading caps it too: 3 XMR raised, but the wallet can pay 2
    (let ((obs ($ SR 'observer))
          (lr  ($ SR 'live-registry)))
      ($ obs 'record-event
         (make-economic-event #:id "ev-donation-2" #:action 'raise
                              #:resource-inventoried-as %xmr-resource-id
                              #:resource-conforms-to "spec-xmr"
                              #:resource-classified-as '("donation") #:receiver "agent-playnet"
                              #:resource-quantity (make-measure 3 "XMR") #:in-scope-of '()))
      ($ ($ lr 'get %xmr-resource-id) 'resize 2))
    (check "3 on the books, 2 in the wallet: 3 refused"
           (car ($ svc 'claim "s1" %xmr-resource-id 3 "bob" #f)) 'error)
    (check "…2 goes through"
           (car ($ svc 'claim "s1" %xmr-resource-id 2 "bob" #f)) 'ok)))

(display "\n")
(test-summary!)
