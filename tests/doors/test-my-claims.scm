;;; tests/doors/test-my-claims.scm — THE CITIZEN'S ORDER BOOK: asked, held, taken.
;;;
;;; The shop face reads one list (service `my-claims`): a want the plan has not
;;; answered (asked), a claim commitment the plan registered for the citizen
;;; (held, with what remains), and a row confirmed in full (taken). Each row
;;; carries the good's crystallized SNLT, so the face prices nothing.
;;;
;;; Run:  guile -L module tests/doors/test-my-claims.scm
(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules ((playnet wire rows) #:select (plain-reply))   ; a door's rows, read back as alists
             (playnet test harness)
             (playnet scope root) (playnet vf schemas) (srfi srfi-1)
             (playnet doors service)
             ((playnet observation account) #:select (declare-claimable!))
             ((playnet test scope) #:select (plan-claim! record-work!))
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(declare-claimable! "spec-bread")
(define vat (spawn-vat))
(define-values (svc obs)
  (with-vat vat
    (let* ((sr  (spawn-scope-root "Book Scope"))
           (rs  ($ sr 'recipe-store))
           (obs ($ sr 'observer))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "s1" sr))))
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
      (record-work! obs "ada" 30 "ev1" "in1")
      ($ obs 'record-event
         (make-economic-event #:id "ev-bread" #:action 'produce #:resource-inventoried-as "r-bread" #:resource-conforms-to "spec-bread"
           #:resource-classified-as (list "individually-claimable") #:provider "commune" #:receiver "commune"
           #:resource-quantity (make-measure 10 %count-unit) #:has-point-in-time "2026-03-02T12:00:00Z"))
      (values svc obs))))

(define (rows) (assq-ref (cdr (plain-reply ($ svc 'my-claims "s1" "ada"))) 'rows))
(define (row state) (find (lambda (r) (equal? (assq-ref r 'state) state)) (rows)))

(with-vat vat
  (display "\n── nothing asked: an empty book ──\n")
  (check "ok"    (car ($ svc 'my-claims "s1" "ada")) 'ok)
  (check "empty" (rows) '())

  (display "\n── a want stated, no plan yet: asked ──\n")
  ($ svc 'declare-need "s1" "ada" "spec-bread" 3 %count-unit "town" "[]" "" "" "" "" "bread")
  (let ((r (row "asked")))
    (check "one row, asked"        (and r #t) #t)
    (check "…for bread, 3"         (and r (equal? (assq-ref r 'spec) "spec-bread") (= 3 (assq-ref r 'total))) #t)
    (check "…priced at 3 h"        (and r (= 3 (assq-ref r 'snlt))) #t)
    (check "…nothing held or taken" (and (not (row "held")) (not (row "taken"))) #t))

  (display "\n── the plan answers: held ──\n")
  (define cid (plan-claim! obs "spec-bread" "ada" 3 #:place "town"))
  (let ((r (row "held")))
    (check "the asked row became held" (and r (not (row "asked"))) #t)
    (check "…3 remaining of 3"        (and r (= 3 (assq-ref r 'total)) (= 3 (assq-ref r 'remaining))) #t)
    (check "…it is the plan's own commitment" (and r (equal? (assq-ref r 'id) cid)) #t))

  (display "\n── she takes 2: held, 1 remaining ──\n")
  ($ svc 'record-claim "s1" "ada" "spec-bread" 2 3 "town" #f)
  (let ((r (row "held")))
    (check "still held"     (and r #t) #t)
    (check "1 remaining"    (and r (= 1 (assq-ref r 'remaining)) (= 2 (assq-ref r 'fulfilled))) #t))

  (display "\n── she takes the last: taken ──\n")
  ($ svc 'record-claim "s1" "ada" "spec-bread" 1 3 "town" #f)
  (let ((r (row "taken")))
    (check "taken"          (and r (not (row "held"))) #t)
    (check "3 of 3"         (and r (= 3 (assq-ref r 'fulfilled)) (= 0 (assq-ref r 'remaining))) #t)))

(display "\n")
(test-summary!)
