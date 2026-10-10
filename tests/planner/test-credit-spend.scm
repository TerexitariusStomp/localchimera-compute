;;; test-credit-spend.scm — earn anywhere, spend anywhere.
;;;
;;; Credit is a person's across the federation: work validated at one scope is
;;; purchasing power at every scope, and a citizenship share is the person's
;;; once however many scopes hold an account of theirs. The claim guard, the
;;; claim's reply and the shop header all read the same federation reading
;;; (the roster's account stores), so what the header shows is what the guard
;;; admits.
;;;
;;; Run:  guile --no-auto-compile -q -L module -L tests tests/planner/test-credit-spend.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules ((playnet wire rows) #:select (wire->plain))   ; a door's rows, read back as alists
             ((playnet planner legal crossings) #:select (record-crossings)))
(use-modules (playnet test harness)
             (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1)
             (playnet planner doors service)
             ((playnet planner observation account) #:select (declare-claimable!))
             ((playnet test scope) #:select (plan-claim!))
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(declare-claimable! "spec-bread")

(define (work! obs aid hours eid iid)
  ($ obs 'register-intent
     (make-intent #:id iid #:action 'work #:resource-conforms-to "spec-labor"
                  #:effort-quantity (make-measure hours %effort-unit) #:provider aid))
  ($ obs 'record-event
     (make-economic-event #:id eid #:action 'work #:resource-conforms-to "spec-labor" #:provider aid
                          #:effort-quantity (make-measure hours %effort-unit)
                          #:has-point-in-time "2026-03-01T08:00:00Z" #:satisfies iid
                          #:in-scope-of '())))

(define vat (spawn-vat))

(with-vat vat
  (let* ((a (spawn-scope-root "Granary")) (b (spawn-scope-root "Table"))
         (svc (spawn ^planner-service (hashmap)))
         (oa ($ a 'observer)) (ob ($ b 'observer)) (rs ($ b 'recipe-store)))
    ($ svc 'add-scope! "Granary" a)
    ($ svc 'add-scope! "Table" b)
    ;; the Table makes bread at 3 hours a loaf and holds ten, set aside four for ada
    ($ rs 'add-recipe-process (make-recipe-process #:id "rp-bake" #:name "Bake"
                                                   #:process-conforms-to "pspec-bake"
                                                   #:has-duration (make-duration 3 %effort-unit)))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-w" #:action 'work
                                             #:resource-conforms-to "spec-labor"
                                             #:effort-quantity (make-measure 3 %effort-unit)
                                             #:recipe-input-of "rp-bake"))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-o" #:action 'produce
                                             #:resource-conforms-to "spec-bread"
                                             #:resource-quantity (make-measure 1 %count-unit)
                                             #:recipe-output-of "rp-bake"))
    ($ rs 'add-recipe (make-recipe #:id "recipe-bread" #:name "Bread" #:primary-output "spec-bread"
                                   #:recipe-processes (list "rp-bake")))
    ($ ob 'record-event
       (make-economic-event #:id "ev-bread" #:action 'produce #:resource-inventoried-as "r-bread" #:resource-conforms-to "spec-bread"
         #:resource-classified-as (list "individually-claimable") #:provider "commune" #:receiver "commune"
         #:resource-quantity (make-measure 10 %count-unit) #:has-point-in-time "2026-03-02T12:00:00Z"))
    (plan-claim! ob "spec-bread" "ada" 4)
    ;; ada earned her hours at the Granary; the Table has seen none of them
    (work! oa "ada" 10 "ev-ada" "in-ada")
    (check "the Table's own ledger holds none of ada's work"
           ($ ob 'validated-gross "ada" #f) 0)

    (display "\n── work earned at the Granary is spent at the Table ──\n")
    (let ((r ($ svc 'claim "Table" "r-bread" 2 "ada" #f)))     ; 2 loaves × 3 h = 6 of her 10
      (check "the claim is admitted" (car r) 'ok)
      (check "it drew six hours" (and (eq? (car r) 'ok) (= 6 (assq-ref (cdr r) 'claimed))) #t))
    ;; the record the claim writes says what the act is: a good handed over
    ;; against labour hours
    (let ((handed (filter (lambda (e) (eq? 'transfer (economic-event-action e))) ($ ob 'all-events))))
      (check "the event a claim writes derives credit-contribution"
             (and (pair? handed)
                  (every (lambda (e)
                           (and (memq 'credit-contribution
                                      (record-crossings e (lambda (id) ($ rs 'get-resource-spec id))))
                                #t))
                         handed))
             #t))

    (display "\n── the header and the guard read one thing ──\n")
    (define (credit-via scope)
      (assq-ref (wire->plain (cdr ($ svc 'scope-snapshot scope "plan-x" "ada"))) 'credit))
    (let ((via-a (credit-via "Granary")) (via-b (credit-via "Table")))
      (check "the drawable standing is the same asked through either scope"
             (and via-a via-b (= (assq-ref via-a 'drawable) (assq-ref via-b 'drawable))) #t)
      (check "and what was drawn at the Table is netted from the capacity she earned at the Granary"
             (and via-a (= (- (assq-ref via-a 'capacity) (assq-ref via-a 'drawable)) 6)) #t))

    (display "\n── a claim made through another scope reaches the home ──\n")
    (check "the first claim made the Table ada's home" ($ svc 'home-of "ada") "Table")
    (let ((r ($ svc 'claim "Granary" "r-bread" 1 "ada" #f)))     ; dialed to the Granary, the plan is the Table's
      (check "the claim is admitted, at the home" (car r) 'ok))
    (let ((r ($ svc 'my-claims "Granary" "ada")))
      (check "her claims read through the Granary are the Table's"
             (and (eq? (car r) 'ok)
                  (pair? (filter (lambda (row) (equal? (assq-ref row 'state) "held")) (assq-ref (wire->plain (cdr r)) 'rows))))
             #t))

    (display "\n── a person with no credit anywhere is refused ──\n")
    (plan-claim! ob "spec-bread" "bob" 2)
    (let ((r ($ svc 'claim "Table" "r-bread" 1 "bob" #f)))
      (check "bob has earned nothing at either scope: refused" (car r) 'error))))

(test-summary!)
