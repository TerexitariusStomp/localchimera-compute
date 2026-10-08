;;; test-claim-service.scm — settlement over the ^planner-service surface
;;;
;;; The service now exposes `claim` (draw earned credit for an individually-
;;; claimable good) and `credit-balance` (read purchasing power) — the same
;;; methods the gateway/browser reach over OCapN. Validates the draw succeeds,
;;; the balance nets it, and an over-draw is rejected.
;;; Run: guile -L module tests/planner/test-claim-service.scm

(use-modules (playnet test harness))
(use-modules (playnet planner scope root) (playnet planner vf schemas))
(use-modules (playnet planner doors service))
(use-modules (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

;; satisfying work → validated gross for AID

(use-modules ((playnet planner observation account) #:select (declare-claimable!)))
;; the rail is read off the recipes: this fixture stands in for the plan and
;; declares that a claim recipe stands for spec-bread (account.scm spec-claimable?)
(declare-claimable! "spec-bread")

(define (work! obs aid skill hours eid iid)
  ($ obs 'register-intent
     (make-intent #:id iid #:action 'work #:resource-conforms-to skill
                  #:effort-quantity (make-measure hours "hour") #:provider aid))
  ($ obs 'record-event
     (make-economic-event #:id eid #:action 'work #:resource-conforms-to skill #:provider aid
                          #:effort-quantity (make-measure hours "hour")
                          #:has-point-in-time "2026-03-01T08:00:00Z" #:satisfies iid
                          #:in-scope-of '())))

(define vat (spawn-vat))
(use-modules ((playnet test scope) #:select (plan-claim!)))   ; the plan's row, stood by the fixture
(define-values (svc-ref obs-ref)
  (with-vat vat
    (let* ((sr  (spawn-scope-root "Claim Scope"))
           (rs  ($ sr 'recipe-store))
           (obs ($ sr 'observer))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "s1" sr))))
      ;; bread recipe so SNLT = 3hr/loaf
      ($ rs 'add-recipe-process
         (make-recipe-process #:id "rp-bake" #:name "Bake" #:process-conforms-to "pspec-bake"
                              #:has-duration (make-duration 3 "hours")))
      ($ rs 'add-recipe-flow
         (make-recipe-flow #:id "rf-bake-work" #:action 'work #:resource-conforms-to "spec-labor"
                           #:effort-quantity (make-measure 3 "hours") #:recipe-input-of "rp-bake"))
      ($ rs 'add-recipe-flow
         (make-recipe-flow #:id "rf-bake-out" #:action 'produce #:resource-conforms-to "spec-bread"
                           #:resource-quantity (make-measure 1 "each") #:recipe-output-of "rp-bake"))
      ($ rs 'add-recipe (make-recipe #:id "recipe-bread" #:name "Bread" #:primary-output "spec-bread"
                                     #:recipe-processes (list "rp-bake")))
      ;; alice earns 10 validated hours (gross); commune produces 10 claimable loaves
      (work! obs "alice" "spec-labor" 10 "ev1" "in1")
      ($ obs 'record-event
         (make-economic-event #:id "ev-bread" #:action 'produce #:resource-inventoried-as "r-bread" #:resource-conforms-to "spec-bread"
           #:resource-classified-as (list "individually-claimable") #:provider "commune" #:receiver "commune"
           #:resource-quantity (make-measure 10 "each") #:has-point-in-time "2026-03-02T12:00:00Z"))
      ;; the plan set 4 loaves aside for alice: the row each claim below fulfils
      (plan-claim! obs "spec-bread" "alice" 4)
      (values svc obs))))

(with-vat vat
  (let ((svc svc-ref))
    (display "\n── credit-balance over the service ──\n")
    (let ((r ($ svc 'credit-balance "s1" "alice")))
      (check "ok"                 (car r) 'ok)
      (check "alice gross = 10"   (assq-ref (cdr r) 'balance) 10))

    (display "\n── claim draws credit (2 loaves @ 3hr = 6) ──\n")
    (let ((r ($ svc 'claim "s1" "r-bread" 2 "alice" 6)))
      (check "claim ok"           (car r) 'ok)
      (check "drew 6"             (= 6 (assq-ref (cdr r) 'claimed)) #t)   ; derived from the recipe, so inexact
      (check "balance now 10 − 6 = 4" (= 4 (assq-ref (cdr r) 'balance)) #t))
    (check "credit-balance reflects the draw"
           (= 4 (assq-ref (cdr ($ svc 'credit-balance "s1" "alice")) 'balance)) #t)

    (display "\n── labor-cost #f ⇒ derived server-side (1 loaf × 3hr SNLT) ──\n")
    (let ((r ($ svc 'claim "s1" "r-bread" 1 "alice" #f)))
      (check "claim ok"            (car r) 'ok)
      (check "cost derived = 3"    (= 3 (assq-ref (cdr r) 'claimed)) #t)
      (check "balance now 4 − 3 = 1" (= 1 (assq-ref (cdr r) 'balance)) #t)
      (check "credit block rides along"
             (number? (assq-ref (assq-ref (cdr r) 'credit) 'drawable)) #t))

    (display "\n── a draw beyond what the plan set aside is rejected ──\n")
    (let ((r ($ svc 'claim "s1" "r-bread" 5 "alice" #f)))   ; the plan held 4; 3 are taken
      (check "over-draw → error" (car r) 'error))))

(display "\n")
(test-summary!)
