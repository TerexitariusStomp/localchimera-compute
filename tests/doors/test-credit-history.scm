;;; tests/doors/test-credit-history.scm — THE CITIZEN'S CREDIT, DATED.
;;;
;;; The certificate carries four figures (earned, drawn, spendable, waiting). The
;;; history door (service `my-credit-history`) lists the acts behind them, and
;;; reads each through the predicate its figure reads, so the two cannot
;;; disagree: what the rows say earned, less what they say drawn, is the balance
;;; the observer holds; what they say is waiting is its pending; an act the log
;;; backed out is listed as voided and counts toward none of them.
;;;
;;; Run:  guile -L module tests/doors/test-credit-history.scm
(use-modules ((playnet utils units) #:select (%count-unit %effort-unit))
             ((playnet wire rows) #:select (plain-reply))
             ((playnet utils clock) #:select (iso-now))
             (playnet test harness)
             (playnet scope root) (playnet vf schemas) (srfi srfi-1)
             (playnet doors service)
             ((playnet observation observer) #:select (back-out))
             ((playnet vf formulas flows) #:select (make-work-event))
             ((playnet observation account) #:select (declare-claimable!))
             ((playnet test scope) #:select (plan-claim! record-work!))
             (goblins) (goblins vat) (goblins utils hashmap))

(declare-claimable! "spec-bread")
(define vat (spawn-vat))
(define-values (svc obs)
  (with-vat vat
    (let* ((sr  (spawn-scope-root "History Scope"))
           (obs ($ sr 'observer))
           (rs  ($ sr 'recipe-store))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "s1" sr))))
      ;; bread is priced by a recipe: 3 h of labour a loaf, which a claim draws
      ($ rs 'add-recipe-process
         (make-recipe-process #:id "rp-bake" #:name "Bake" #:process-conforms-to "pspec-bake"
                              #:has-duration (make-duration 3 %effort-unit)))
      ($ rs 'add-recipe-flow
         (make-recipe-flow #:id "rf-bake-work" #:action 'work #:resource-conforms-to "spec-labor"
                           #:effort-quantity (make-measure 3 %effort-unit) #:recipe-input-of "rp-bake"))
      ($ rs 'add-recipe-flow
         (make-recipe-flow #:id "rf-bake-out" #:action 'produce #:resource-conforms-to "spec-bread"
                           #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-bake"))
      ($ rs 'add-recipe (make-recipe #:id "recipe-bread" #:name "Bread"
                                     #:primary-output "spec-bread"
                                     #:recipe-processes (list "rp-bake")))
      ($ obs 'record-event
         (make-economic-event #:id "ev-bread" #:action 'produce #:resource-inventoried-as "r-bread" #:resource-conforms-to "spec-bread"
           #:resource-classified-as (list "individually-claimable") #:provider "commune" #:receiver "commune"
           #:resource-quantity (make-measure 10 %count-unit) #:has-point-in-time "2026-03-02T12:00:00Z"))
      (values svc obs))))

(define (rows) (assq-ref (cdr (plain-reply ($ svc 'my-credit-history "s1" "ada"))) 'rows))
(define (of kind) (filter (lambda (r) (equal? (assq-ref r 'kind) kind)) (rows)))
(define (sum kind) (fold + 0 (map (lambda (r) (assq-ref r 'hours)) (of kind))))
(define (same? a b) (< (abs (- a b)) 1e-9))

(with-vat vat
  (display "\n── no acts: an empty account ──\n")
  (check "ok"    (car ($ svc 'my-credit-history "s1" "ada")) 'ok)
  (check "empty" (rows) '())

  (display "\n── old work, then work inside its window ──\n")
  (record-work! obs "ada" 30 "ev-old" "in-old")
  (record-work! obs "ada" 5 "ev-new" "in-new" #:when (iso-now))
  (check "the old work is listed as earned" (and (pair? (of "earned")) #t) #t)
  (check "the figures the rows give are the observer's own"
         (and (same? (sum "earned") ($ obs 'validated-gross "ada"))
              (same? (sum "waiting") ($ obs 'pending-gross "ada")))
         #t)
  (check "every row names an instant" (every (lambda (r) (string? (assq-ref r 'at))) (rows)) #t)
  (check "newest first"
         (let ((ats (map (lambda (r) (assq-ref r 'at)) (rows))))
           (equal? ats (sort ats string>?)))
         #t)

  (display "\n── diffuse work nobody has answered, inside its window: waiting ──\n")
  ($ obs 'record-event
     (make-work-event #:id "ev-diffuse" #:resource-spec "spec-labor" #:provider "ada"
                      #:effort-qty 4 #:effort-unit "hour"
                      #:has-beginning (iso-now) #:timestamp (iso-now)))
  (check "a waiting row of four hours" (and (= 1 (length (of "waiting"))) (same? (sum "waiting") 4)) #t)
  (check "…which is the certificate's pending" (same? (sum "waiting") ($ obs 'pending-gross "ada")) #t)
  (check "…and is not yet earned" (same? (sum "earned") ($ obs 'validated-gross "ada")) #t)

  (display "\n── she takes bread: drawn ──\n")
  (plan-claim! obs "spec-bread" "ada" 3 #:place "town")
  ($ svc 'record-claim "s1" "ada" "spec-bread" 2 3 "town" #f)
  (check "a drawn row" (and (= 1 (length (of "drawn"))) #t) #t)
  (check "drawn is what the ledger claimed" (same? (sum "drawn") ($ obs 'claim-effort "ada")) #t)
  (check "…six hours: two loaves at three" (same? (sum "drawn") 6) #t)
  (check "earned less drawn is the balance" (same? (- (sum "earned") (sum "drawn")) ($ obs 'credit-balance "ada")) #t)
  (check "another citizen sees none of it"
         (assq-ref (cdr (plain-reply ($ svc 'my-credit-history "s1" "bo"))) 'rows) '())

  (display "\n── the old work is backed out: voided, and counted nowhere ──\n")
  (let ((before (sum "earned")))
    ($ obs 'record-event
       (back-out ($ obs 'get-event "ev-old") #:id "ev-old-void" #:note "contested" #:at "2026-10-01T00:00:00Z"))
    (check "it is listed as voided"  (and (= 1 (length (of "voided"))) #t) #t)
    (check "…at the hours it stated" (same? (sum "voided") 30) #t)
    (check "…and no longer earns"    (same? (- before (sum "earned")) 30) #t)
    (check "earned still equals the observer's gross" (same? (sum "earned") ($ obs 'validated-gross "ada")) #t)))

(display "\n")
(test-summary!)
