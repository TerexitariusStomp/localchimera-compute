;;; tests/planner/test-ability-contribution.scm — FROM EACH ACCORDING TO ABILITY.
;;;
;;; The certificate reads what a person gives against what they could give:
;;; r_p = validated hours / capacity (elastic.scm ability-contribution). A
;;; half-capacity person who worked all of their half has given everything,
;;; and draws the same share as a full-capacity person who worked all of
;;; theirs. Solidarity is in the measure — no welfare fund is carved from the
;;; pool, no supplement is added beside the contribution. Someone who can
;;; give nothing has given all they could: the standard, the mean of those
;;; who can.
;;;
;;; Run:  guile -L module tests/planner/test-ability-contribution.scm
(use-modules (playnet test harness)
             (playnet planner observation account) (playnet planner scope root) (playnet planner vf schemas)
             ((playnet planner observation account) #:select (declare-claimable! set-person-substrate!))
             ((playnet test scope) #:select (record-work!))
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(declare-claimable! "spec-bread")

(define vat (spawn-vat))
(define-values (obs as)
  (with-vat vat
    (let* ((sr  (spawn-scope-root "Ability Scope"))
           (rs  ($ sr 'recipe-store))
           (obs ($ sr 'observer))
           (as  ($ sr 'account-store)))
      ($ rs 'add-recipe-process
         (make-recipe-process #:id "rp-bake" #:name "Bake" #:process-conforms-to "pspec-bake"
                              #:has-duration (make-duration 3 "hours")))
      ($ rs 'add-recipe-flow
         (make-recipe-flow #:id "rf-bake-work" #:action 'work #:resource-conforms-to "spec-labor"
                           #:effort-quantity (make-measure 3 "hours") #:recipe-input-of "rp-bake"))
      ($ rs 'add-recipe-flow
         (make-recipe-flow #:id "rf-bake-out" #:action 'produce #:resource-conforms-to "spec-bread"
                           #:resource-quantity (make-measure 1 "each") #:recipe-output-of "rp-bake"))
      ($ rs 'add-recipe (make-recipe #:id "recipe-bread" #:name "Bread"
                                     #:primary-output "spec-bread"
                                     #:recipe-processes (list "rp-bake")))
      ;; ada: full capacity, 10 h. ben: half capacity, 5 h — all of his half.
      (record-work! obs "ada" 10 "ev-ada" "in-ada")
      (record-work! obs "ben" 5  "ev-ben" "in-ben")
      ($ as 'credit-from-event ($ obs 'get-event "ev-ada"))
      ($ as 'credit-from-event ($ obs 'get-event "ev-ben"))
      ($ as 'set-ccf "ben" 1/2)
      ;; the pool: 10 loaves at 3 h = 30 h
      ($ obs 'record-event
         (make-economic-event #:id "ev-bread" #:action 'produce #:resource-inventoried-as "r-bread" #:resource-conforms-to "spec-bread"
           #:resource-classified-as (list "individually-claimable") #:provider "commune" #:receiver "commune"
           #:resource-quantity (make-measure 10 "each") #:has-point-in-time "2026-03-02T12:00:00Z"))
      (values obs as))))

(with-vat vat
  (display "\n── ada gave 10 of her 10, ben 5 of his 5 ──\n")
  (check "ada's ability reads 10"           (= 10 ($ as 'citizen-ability "ada")) #t)
  (check "ben's 5 h at half capacity read 10" (= 10 ($ as 'citizen-ability "ben")) #t)
  (check "Σ r = 20"                         (= 20 ($ as 'ability-norm)) #t)
  (check "equal shares of the 30 h pool: ada 15" (= 15 ($ as 'effective-balance "ada")) #t)
  (check "…ben 15 — he gave everything he could" (= 15 ($ as 'effective-balance "ben")) #t)

  (display "\n── conservation: the shares sum to the pool ──\n")
  (check "15 + 15 = 30" (= 30 (+ ($ as 'total-claim-capacity "ada") ($ as 'total-claim-capacity "ben"))) #t)

  (display "\n── cy can give nothing: she has given all she could ──\n")
  ($ as 'ensure-account "cy")
  ($ as 'set-ccf "cy" 0)
  (check "cy reads as the standard — the mean of those who can, 10" (= 10 ($ as 'citizen-ability "cy")) #t)
  (check "three equal shares of 30: 10 each" (= 10 ($ as 'effective-balance "cy")) #t)
  (check "…and ada's is now 10 too"           (= 10 ($ as 'effective-balance "ada")) #t)

  (display "\n── ben's capacity restored: his 5 h are half a contribution again ──\n")
  ($ as 'set-ccf "ben" 1)
  (check "ben reads 5"                          (= 5 ($ as 'citizen-ability "ben")) #t)
  (check "the standard for cy moves with it: (10 + 5)/2 = 7.5" (= 15/2 ($ as 'citizen-ability "cy")) #t)

  (display "\n── a second key is no citizen: it reads nothing, and splitting gains nothing ──\n")
  ;; personhood is one per human: only these three are witnessed persons
  (set-person-substrate! (lambda (aid) (and (member aid '("ada" "ben" "cy")) #t)))
  ($ as 'ensure-account "ada-2")           ; ada's phantom second key, capacity 0, no hours
  ($ as 'set-ccf "ada-2" 0)
  (check "the phantom reads no standard share: 0" (= 0 ($ as 'citizen-ability "ada-2")) #t)
  (check "the norm is the three citizens' alone: 10 + 5 + 7.5" (= 45/2 ($ as 'ability-norm)) #t)
  (check "…and it can draw nothing"               (= 0 ($ as 'effective-balance "ada-2")) #t)
  (set-person-substrate! #f))

(display "\n")
(test-summary!)
