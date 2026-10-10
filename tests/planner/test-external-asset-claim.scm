;;; test-external-asset-claim.scm — buying external liquidity with credits
;;;
;;; playnet.typ §Credits and external liquidity: an external asset (XMR,
;;; fiat) enters the commons as a resource spec priced by its ACQUISITION
;;; recipe — crystallized SNLT = the labour of acquisition — and citizens
;;; claim it against earned credit exactly like bread, one-directionally.
;;; Validates: bootstrap wires spec + recipe + claimable resource; a
;;; donation ('raise) fills the pool; a claim at server-derived cost
;;; (qty × acquisition-SNLT) draws the citizen's balance; over-draw fails.
;;;
;;; The mechanics above are generic to ANY external asset, not Monero
;;; specifically, so they run here against a synthetic spec
;;; ("spec-test-liquidity") bootstrapped the same generic way
;;; `bootstrap-external-asset!` always has. XMR itself — along with every
;;; fiat currency and precious metal — is on the bar list now
;;; (facts/barred-specs.scm): no citizen may claim a financial instrument
;;; against credit, whatever the acquisition recipe prices it at. The last
;;; section proves that directly, against the real spec-xmr/res-xmr-main.
;;;
;;; Run: guile -L module tests/planner/test-external-asset-claim.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet planner scope root) (playnet planner vf schemas))
(use-modules (playnet planner doors service))
(use-modules (playnet monero specs))
(use-modules ((playnet planner observation live-resource) #:select (^live-resource)))
(use-modules ((playnet planner facts rail) #:select (declare-rail!)))
(use-modules ((playnet test scope) #:select (plan-claim!)))   ; the plan's row, stood by the fixture
(use-modules (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(define SPEC "spec-test-liquidity")
(define RID  "res-spec-test-liquidity-pool")   ; bootstrap-external-asset!'s own naming: "res-" + spec-id + "-pool"
(define UNIT "TLQ")

(define (work! obs aid skill hours eid iid)
  ($ obs 'register-intent
     (make-intent #:id iid #:action 'work #:resource-conforms-to skill
                  #:effort-quantity (make-measure hours %effort-unit) #:provider aid))
  ($ obs 'record-event
     (make-economic-event #:id eid #:action 'work #:resource-conforms-to skill #:provider aid
                          #:effort-quantity (make-measure hours %effort-unit)
                          #:has-point-in-time "2026-03-01T08:00:00Z" #:satisfies iid
                          #:in-scope-of '())))

(define (raise! obs qty)
  ;; a donation arriving, in miniature — the same shape the real poller writes
  ($ obs 'record-event
     (make-economic-event #:id "ev-donation" #:action 'raise
       #:resource-inventoried-as RID #:resource-conforms-to SPEC #:resource-classified-as '("donation") #:receiver "agent-playnet"
       #:resource-quantity (make-measure qty UNIT) #:in-scope-of '())))

(define vat (spawn-vat))
(define SR #f)
(define svc-ref
  (with-vat vat
    (let* ((sr  (begin (set! SR (spawn-scope-root "External Scope")) SR))
           (obs ($ sr 'observer))
           (lr  ($ sr 'live-registry))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "s1" sr))))
      ;; the synthetic asset on the claimable rail: spec + acquisition recipe
      ;; (20 h/unit, same figure the real XMR fixture used) + pool, generic
      ;; to any external asset — the same call production makes for a real one
      (bootstrap-external-asset! sr #:spec-id SPEC #:name "Test liquidity" #:unit UNIT
                                 #:note "A synthetic external asset, for exercising the
                                         acquisition-recipe/solvency mechanics without
                                         touching a specific, barred financial instrument."
                                 #:categories '("external/test") #:acquisition-hours 20)
      ;; the live-resource wiring bootstrap-monero-resource! also does, generic here too
      ($ lr 'register RID (spawn ^live-resource RID SPEC 0 0 UNIT "loc-playnet-server" '()))
      (declare-rail! SPEC 'individual)   ; stands in for the plan: made by the acquisition recipe, nobody's input
      (plan-claim! obs SPEC "alice" 1)   ; the plan's rows: 1 unit for alice, 2 for bob
      (plan-claim! obs SPEC "bob" 2)
      ;; alice earns 40 validated hours; 1 unit arrives by donation
      (work! obs "alice" "spec-labor" 40 "ev1" "in1")
      (raise! obs 1)
      svc)))

(with-vat vat
  (let ((svc svc-ref))
    (display "\n── the acquisition recipe prices the asset ──\n")
    (let ((r ($ svc 'credit-balance "s1" "alice")))
      (check "alice gross = 40" (= 40 (assq-ref (cdr r) 'balance)) #t))

    (display "\n── claim 1 unit at the derived acquisition cost (20 h) ──\n")
    (let ((r ($ svc 'claim "s1" RID 1 "alice" #f)))
      (check "claim ok"          (car r) 'ok)
      (check "cost = 20 h/unit"  (= 20 (assq-ref (cdr r) 'claimed)) #t)
      (check "balance 40 − 20"   (= 20 (assq-ref (cdr r) 'balance)) #t)
      (check "credit block rides" (number? (assq-ref (assq-ref (cdr r) 'credit) 'drawable)) #t))

    (display "\n── the boundary is one-directional: over-draw fails ──\n")
    (let ((r ($ svc 'claim "s1" RID 5 "alice" #f)))
      (check "5 units = 100 h > balance → error" (car r) 'error))

    (display "\n── solvency: a claim draws on what the pool holds ──\n")
    ;; bob earns plenty; the pool holds 0 units now (alice took the 1)
    (let ((obs ($ SR 'observer)))
      (work! obs "bob" "spec-labor" 400 "ev2" "in2"))
    (let ((r ($ svc 'claim "s1" RID 1 "bob" #f)))
      (check "credit enough, pool empty → refused at the door" (car r) 'error)
      (check "…and it says so" (and (string-contains (cdr r) "pool holds") #t)))
    ;; the live reading caps it too: 3 on the books, but the wallet can pay 2
    (let ((obs ($ SR 'observer))
          (lr  ($ SR 'live-registry)))
      ($ obs 'record-event
         (make-economic-event #:id "ev-donation-2" #:action 'raise
                              #:resource-inventoried-as RID
                              #:resource-conforms-to SPEC
                              #:resource-classified-as '("donation") #:receiver "agent-playnet"
                              #:resource-quantity (make-measure 3 UNIT) #:in-scope-of '()))
      ($ ($ lr 'get RID) 'resize 2))
    (check "3 on the books, 2 in the wallet: 3 refused"
           (car ($ svc 'claim "s1" RID 3 "bob" #f)) 'error)
    (check "…2 goes through"
           (car ($ svc 'claim "s1" RID 2 "bob" #f)) 'ok)

    (display "\n── the bar list: a financial instrument is refused regardless of price or pool ──\n")
    ;; same mechanics, the real spec — bootstrapped, priced, and donated into
    ;; exactly as above, and still refused: the bar list is read before any
    ;; of the pricing or solvency checks above ever get a chance to pass it.
    (let* ((obs ($ SR 'observer)))
      (bootstrap-monero-resource! SR)
      ($ obs 'record-event
         (make-economic-event #:id "ev-xmr-donation" #:action 'raise
                              #:resource-inventoried-as %xmr-resource-id #:resource-conforms-to %xmr-spec-id
                              #:resource-classified-as '("donation") #:receiver "agent-playnet"
                              #:resource-quantity (make-measure 1 "XMR") #:in-scope-of '()))
      (plan-claim! obs %xmr-spec-id "alice" 1))
    (check "a fully-priced, fully-funded, plan-claimed XMR is refused all the same"
           (car ($ svc 'claim "s1" %xmr-resource-id 1 "alice" #f)) 'error)))

(display "\n")
(test-summary!)
