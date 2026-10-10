;;; tests/planner/test-claim-leftover.scm — THE CLAIMABLE PORTION IS WHAT THE PLAN LEAVES.
;;;
;;; One portion serves as fresh means of production and stays social; another
;;; portion is consumed by members as means of subsistence. The
;;; deduction is the solve's own material balance: a claim column can only take
;;; what production's floors and the reserve leave, and the plan publishes the
;;; portion it keeps back (rail.scm social-portion). Downstream, a claim event
;;; exists only as the fulfilment of a claim commitment the plan minted: the
;;; ledger refuses a claim with no such commitment, one above what remains on
;;; it, and one the plan withdrew.
;;;
;;; Layer 1 — the plan: ten kilos of wheat stand, six are the calamity reserve,
;;; ada wants five for herself. The plan claims four at most for her, and says
;;; it keeps six back.
;;; Layer 2 — the doors: a real scope, the plan's row stood by plan-claim!.
;;;
;;; Run:  guile -L module tests/planner/test-claim-leftover.scm
(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test scope)) ; mock-scope-root plan-claim!
(use-modules (playnet test harness)
             (playnet algorithms elastic) (playnet scope root) (playnet vf schemas) (srfi srfi-1)
             (playnet scope live)
             (playnet doors service)
             
             ((playnet observation account) #:select (spec-social-portion declare-claimable! declare-social-portion!))
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (ice-9 format))

;; ═══════════════════════════════════════════════════════════════════════════
;; Layer 1 — the plan's deduction
;; ═══════════════════════════════════════════════════════════════════════════
(define COMMUNE "ECommune")
(define PLACE   "town")
(define* (want aid spec qty #:optional (loc PLACE))
  (make-intent #:id (string-append "want:" aid ":" spec) #:action 'consume #:name spec #:resource-conforms-to spec
               #:resource-quantity (make-measure qty "kg") #:receiver aid #:at-location loc #:in-scope-of '()))

(define procs (list (make-recipe-process #:id "grow" #:name "Grow")))
(define flows
  (list (make-recipe-flow #:id "gw" #:action 'work #:resource-conforms-to "skill-grow"
                          #:effort-quantity (make-measure 1.0 %effort-unit) #:recipe-input-of "grow")
        (make-recipe-flow #:id "go" #:action 'produce #:resource-conforms-to "wheat"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-output-of "grow"
                          #:is-primary #t)))
(define recipes (list (make-recipe #:id "grow-recipe" #:name "Grow" #:primary-output "wheat"
                                   #:recipe-processes (list "grow"))))
(define spatials (list (make-spatial-thing #:id PLACE #:lat 40.0 #:long -74.0)))
(define win (all-week-window "00:00" "23:59"))
(define agents (list (make-agent #:id "ada" #:type 'person #:name "Ada" #:primary-location PLACE
                                 #:classified-as '() #:availability-window win)))
(define wheat-stock
  (make-economic-resource #:id "r-wheat" #:name "the granary" #:conforms-to "wheat" #:classified-as '()
    #:accounting-quantity (make-measure 10.0 "kg") #:onhand-quantity (make-measure 10.0 "kg") #:current-location PLACE #:primary-accountable "commune"))

(define vat (spawn-vat #:name "claim-leftover"))

(define (run reserve)
  (with-vat vat
    (let* ((obs (spawn ^mock `((all-resources . ,(lambda () (list wheat-stock))) (record-event . ,(lambda (e) "ok")))))
           (as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs  (spawn ^mock `((all-recipes . ,(lambda () recipes))
                               (get-process-chain . ,(lambda (rid) procs))
                               (flows-for-process . ,(lambda (pid)
                                 (cons (filter (lambda (f) (or (equal? (recipe-flow-recipe-input-of f) pid)
                                                               (equal? (recipe-flow-recipe-output-of f) pid)))
                                               flows) '()))))))
           (ps  (spawn ^mock `((all-intents . ,(lambda () (list (want "ada" "wheat" 5.0))))
                               (all-commitments . ,(lambda () '())))))
           (root  (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs #:plan-store ps)))
      (plan-scope->alist root
        #:demand (list (cons (format #f "wheat~~ada#~a@0" PLACE) 5.0))   ; ada's own wheat: her want, felt on the owned good
        #:periods '(0)
        #:reproduce? #f
        #:insurance (if reserve (list (list (format #f "wheat#~a@0" PLACE) reserve reserve 1.0 1.0)) '())
        #:eco-caps (list (cons (format #f "wheat#~a@0" PLACE) 0.0))   ; nothing grows this period: the ten kilos are all there is
        #:backend 'native-c))))

(define (claimed alist aid spec)
  (fold (lambda (c a) (if (and (equal? (assq-ref c 'claimant) aid) (equal? (assq-ref c 'conforms-to) spec))
                          (+ a (assq-ref c 'quantity)) a))
        0.0 (or (assq-ref alist 'claims) '())))

(format #t "~%── ada wants 5 kg of the 10 that stand ──~%")
(define free (run #f))
(format #t "  no reserve:    claims ~,2f, kept back ~,2f~%" (claimed free "ada" "wheat") (spec-social-portion "wheat"))
(check "no reserve: the plan claims her 5" (>= (claimed free "ada" "wheat") 4.9) #t)

(define kept (run 6.0))
(format #t "  reserve of 6:  claims ~,2f, kept back ~,2f~%" (claimed kept "ada" "wheat") (spec-social-portion "wheat"))
(check "reserve of 6: the plan claims at most the 4 above it" (<= (claimed kept "ada" "wheat") 4.05) #t)
(check "…and still claims something for her"                 (>= (claimed kept "ada" "wheat") 3.9) #t)
(check "the plan publishes the 6 it keeps back"               (>= (spec-social-portion "wheat") 5.9) #t)

;; ═══════════════════════════════════════════════════════════════════════════
;; Layer 2 — the doors honour only the plan's word
;; ═══════════════════════════════════════════════════════════════════════════
(define (work! obs aid skill hours eid iid)
  ($ obs 'register-intent
     (make-intent #:id iid #:action 'work #:resource-conforms-to skill
                  #:effort-quantity (make-measure hours %effort-unit) #:provider aid))
  ($ obs 'record-event
     (make-economic-event #:id eid #:action 'work #:resource-conforms-to skill #:provider aid
                          #:effort-quantity (make-measure hours %effort-unit)
                          #:has-point-in-time "2026-03-01T08:00:00Z" #:satisfies iid
                          #:in-scope-of '())))

(declare-claimable! "spec-wheat")   ; the fixture's stand-in for the plan's rail
((@ (playnet algorithms elastic) set-social-free-time!) 0)   ; layer 1's solve published f; the doors read the base model
(define vat2 (spawn-vat #:name "claim-leftover-doors"))
(define-values (svc obs as rs sr)
  (with-vat vat2
    (let* ((sr  (spawn-scope-root "Leftover Scope"))
           (rs  ($ sr 'recipe-store))
           (obs ($ sr 'observer))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "s1" sr))))
      ($ rs 'add-recipe-process
         (make-recipe-process #:id "rp-grow" #:name "Grow" #:process-conforms-to "pspec-grow"
                              #:has-duration (make-duration 1 %effort-unit)))
      ($ rs 'add-recipe-flow
         (make-recipe-flow #:id "rf-grow-work" #:action 'work #:resource-conforms-to "spec-labor"
                           #:effort-quantity (make-measure 1 %effort-unit) #:recipe-input-of "rp-grow"))
      ($ rs 'add-recipe-flow
         (make-recipe-flow #:id "rf-grow-out" #:action 'produce #:resource-conforms-to "spec-wheat"
                           #:resource-quantity (make-measure 1 "kg") #:recipe-output-of "rp-grow"))
      ($ rs 'add-recipe (make-recipe #:id "recipe-wheat" #:name "Wheat"
                                     #:primary-output "spec-wheat"
                                     #:recipe-processes (list "rp-grow")))
      (work! obs "ada" "spec-labor" 10 "ev1" "in1")            ; ada: 10 h gross
      ($ obs 'record-event
         (make-economic-event #:id "ev-wheat" #:action 'produce #:resource-inventoried-as "r-wheat" #:resource-conforms-to "spec-wheat"
           #:resource-classified-as (list "individually-claimable") #:provider "commune" #:receiver "commune"
           #:resource-quantity (make-measure 10 "kg") #:has-point-in-time "2026-03-02T12:00:00Z"))
      (values svc obs ($ sr 'account-store) rs sr))))

(define (err? r) (eq? (car r) 'error))
(define (msg r)  (format #f "~a" (cdr r)))

(with-vat vat2
  (display "\n── no plan has spoken: every door refuses ──\n")
  (let ((r ($ svc 'record-claim "s1" "ada" "spec-wheat" 1 5 "town" #f)))
    (check "record-claim with no planned row is refused" (err? r) #t)
    (format #t "  refused with: ~a~%" (msg r))
    (check "…and says the plan holds no such claim" (and (string-contains (msg r) "holds no claim") #t) #t))
  (check "the ledger with no `fulfills` is refused"
         (catch #t (lambda () ($ as 'claim "r-wheat" 1 "ada" 1 (list sr)) 'no-error)
                (lambda (k . a) 'refused))
         'refused)
  (check "the shop's `claim` door with no planned row is refused"
         (err? ($ svc 'claim "s1" "r-wheat" 1 "ada" #f)) #t)
  (check "wheat is still all in the pool" (= 10 (measure-has-numerical-value
                                                  (economic-resource-onhand-quantity ($ obs 'get-resource "r-wheat")))) #t)

  (display "\n── the plan set 4 kg aside for ada ──\n")
  (define cid (plan-claim! obs "spec-wheat" "ada" 4 #:place "town"))
  (let ((r ($ svc 'record-claim "s1" "ada" "spec-wheat" 5 4 "town" #f)))
    (check "5 asked of a 4-row is refused" (err? r) #t))
  (let ((r ($ svc 'record-claim "s1" "ada" "spec-wheat" 3 4 "town" #f)))
    (check "3 of the 4 confirmed"                (car r) 'ok)
    (check "it fulfils the plan's own commitment" (assq-ref (cdr r) 'fulfills) cid)
    (check "the certificate drew 3 × 1 h"        (= 3 (assq-ref (cdr r) 'claimed)) #t))
  (let ((r ($ svc 'claim "s1" "r-wheat" 2 "ada" #f)))
    (check "the shop door: 2 asked, 1 remains — refused" (err? r) #t))
  (let ((r ($ svc 'claim "s1" "r-wheat" 1 "ada" #f)))
    (check "the shop door confirms the last kilo" (car r) 'ok))
  (let ((r ($ svc 'record-claim "s1" "ada" "spec-wheat" 1 4 "town" #f)))
    (check "the row is done: `already`" (and (eq? (car r) 'ok) (assq-ref (cdr r) 'already)) #t))
  (check "6 kg remain social" (= 6 (measure-has-numerical-value
                                     (economic-resource-onhand-quantity ($ obs 'get-resource "r-wheat")))) #t)

  (display "\n── a row the plan withdrew admits nothing ──\n")
  (plan-claim! obs "spec-wheat" "ada" 2 #:place "field")
  (check "the withdrawal takes" ($ obs 'retire-commitment "claim|spec-wheat|ada|field|") #t)
  (check "record-claim against it is refused" (err? ($ svc 'record-claim "s1" "ada" "spec-wheat" 1 2 "field" #f)) #t)

  (display "\n── the pool K counts only the portion above what the plan keeps ──\n")
  (check "6 on hand, nothing kept back, 1 h/kg: K = 6" (= 6 ($ as 'embodied-labor-in-pool)) #t)
  (declare-social-portion! "spec-wheat" 4)
  (check "6 on hand, 4 kept back: K = 2"              (= 2 ($ as 'embodied-labor-in-pool)) #t)
  (declare-social-portion! "spec-wheat" 10)
  (check "kept back beyond the stock: K = 0, never negative" (= 0 ($ as 'embodied-labor-in-pool)) #t))

(display "\n")
(test-summary!)
