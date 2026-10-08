;;; test-credit-integrity.scm — the credit ledger admits only what a member did.
;;;
;;; Credit is the ledger's other "number up, number down": validated work raises it
;;; and a claim draws it down. The doors that move it speak for the member who
;;; reached them, so each takes what the member is entitled to state and derives
;;; the rest:
;;;   record-effort — hours are a finite positive number in an hours unit, recorded
;;;                   by the commitment's own provider, up to what the commitment
;;;                   still holds
;;;   claim         — the cost is the good's crystallized labour (the door derives it),
;;;                   for a positive quantity
;;;   accept        — a work offer that names a provider is accepted by that provider
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-credit-integrity.scm

(use-modules (playnet test harness)
             ((playnet test books) #:select (mq ok? refused?))
             (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-11)
             (playnet planner doors service)
             (playnet planner scope live)
             ((playnet test scope) #:select (plan-claim! record-work!))
             ((playnet planner observation account) #:select (declare-claimable!))
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(declare-claimable! "spec-bread")

(define vat (spawn-vat))

(define (world)
  (let* ((sr  (spawn-scope-root "T"))
         (svc (spawn ^planner-service (hashmap-set (hashmap) "s1" sr))))
    (values sr svc)))
(define* (offer! sr iid hours #:key (provider #f))
  ($ ($ sr 'plan-store) 'add-intent
     (let ((it (work-intent iid #:proc "bake" #:skill "sk" #:hours hours
                            #:from "2026-10-02" #:until "2026-10-02"
                            #:point "2026-10-02" #:place "town")))
       (if provider (copy-intent it #:provider provider) it))))

;; ── record-effort ───────────────────────────────────────────────────────────
(with-vat vat
  (let-values (((sr svc) (world)))
    (let* ((obs ($ sr 'observer))
           (_    (offer! sr "i1" 3))
           (acc  ($ svc 'accept-assignment "s1" "i1" "alice"))
           (cid  (cdr acc))
           (gross (lambda (who) ($ obs 'validated-gross who))))
      (display "\n── record-effort: what counts as hours ──\n")
      (check "alice accepts her offer"                      (ok? acc) #t)
      (check "+nan.0 hours are refused"        (refused? ($ svc 'record-effort "s1" cid "alice" +nan.0 "hours")) #t)
      (check "+inf.0 hours are refused"        (refused? ($ svc 'record-effort "s1" cid "alice" +inf.0 "hours")) #t)
      (check "negative hours are refused"      (refused? ($ svc 'record-effort "s1" cid "alice" -2.0 "hours")) #t)
      (check "zero hours are refused"          (refused? ($ svc 'record-effort "s1" cid "alice" 0 "hours")) #t)
      (check "a text quantity is refused"      (refused? ($ svc 'record-effort "s1" cid "alice" "2" "hours")) #t)
      (check "kilograms are not hours"         (refused? ($ svc 'record-effort "s1" cid "alice" 0.5 "kg")) #t)
      (check "none of that reached the ledger" (gross "alice") 0)
      (check "the balance stays a number"      (number? ($ obs 'credit-balance "alice")) #t)

      (display "\n── record-effort: whose commitment, and how much it holds ──\n")
      (check "bob cannot record hours on alice's commitment"
             (refused? ($ svc 'record-effort "s1" cid "bob" 1.0 "hours")) #t)
      (check "…and bob earns nothing from the attempt"      (gross "bob") 0)
      (check "more than the commitment holds is refused"
             (refused? ($ svc 'record-effort "s1" cid "alice" 5.0 "hours")) #t)
      (check "alice records 1 hour"            (ok? ($ svc 'record-effort "s1" cid "alice" 1.0 "hours")) #t)
      (check "…and either spelling of the unit serves"
             (ok? ($ svc 'record-effort "s1" cid "alice" 1.0 "hour")) #t)
      ;; hours count in proportion to how much of the commitment is in: 2 hours of
      ;; 3 weigh 2/3 (the satisfied-intent fraction), so the ledger reads 4/3
      (check "alice's gross weighs her 2 recorded hours by the 2/3 reached"
             (< (abs (- (gross "alice") (* 2.0 (/ 2.0 3.0)))) 1e-9) #t)
      (check "the last hour fits the remainder"
             (ok? ($ svc 'record-effort "s1" cid "alice" 1.0 "hours")) #t)
      (check "a finished commitment takes no more hours"
             (refused? ($ svc 'record-effort "s1" cid "alice" 0.5 "hours")) #t)
      (check "alice's gross is exactly her 3 committed hours" (< (abs (- (gross "alice") 3.0)) 1e-9) #t))))

;; ── record-effort: any time unit is hours once converted ──────────────────────
(with-vat vat
  (let-values (((sr svc) (world)))
    (let* ((obs ($ sr 'observer))
           (_    (offer! sr "i1" 3))
           (cid  (cdr ($ svc 'accept-assignment "s1" "i1" "alice")))
           (gross (lambda (who) ($ obs 'validated-gross who))))
      (display "\n── record-effort: a time unit converts to hours ──\n")
      (check "a day is more than the 3 hours held"
             (refused? ($ svc 'record-effort "s1" cid "alice" 1 "days")) #t)
      (check "90 minutes record as an hour and a half"
             (ok? ($ svc 'record-effort "s1" cid "alice" 90 "minutes")) #t)
      ;; 1.5 of 3 hours reached: the 1.5 recorded hours weigh 1/2
      (check "…and the ledger reads 1.5 hours weighed by the half reached"
             (< (abs (- (gross "alice") (* 1.5 0.5))) 1e-6) #t)   ; the unit table states a minute to 1e-10
      (check "the remainder is the 1.5 hours not yet in"
             (refused? ($ svc 'record-effort "s1" cid "alice" 100 "minutes")) #t)
      (check "…and the other 90 minutes fit it exactly (one tolerance, as the tally's)"
             (ok? ($ svc 'record-effort "s1" cid "alice" 90 "minutes")) #t))))

;; ── record-effort: one worker's partial hours leave another's credit alone (W10) ──
;; Alice and bob each take their own offer on one process. An hour is weighed by
;; how much of ITS OWN commitment's word is answered, so bob's first hour moves
;; his credit and no one else's.
(with-vat vat
  (let-values (((sr svc) (world)))
    (let* ((obs ($ sr 'observer))
           (_    (offer! sr "i-a" 3 #:provider "alice"))
           (_    (offer! sr "i-b" 3 #:provider "bob"))
           (ca   (cdr ($ svc 'accept-assignment "s1" "i-a" "alice")))
           (cb   (cdr ($ svc 'accept-assignment "s1" "i-b" "bob")))
           (gross (lambda (who) ($ obs 'validated-gross who))))
      (display "\n── record-effort: credit is per commitment ──\n")
      (check "alice completes her 3 hours"  (ok? ($ svc 'record-effort "s1" ca "alice" 3.0 "hours")) #t)
      (check "…and holds 3"                 (< (abs (- (gross "alice") 3.0)) 1e-9) #t)
      (check "bob records 1 of his 3"       (ok? ($ svc 'record-effort "s1" cb "bob" 1.0 "hours")) #t)
      (check "alice still holds 3"          (< (abs (- (gross "alice") 3.0)) 1e-9) #t)
      (check "bob's hour weighs the third of his word it answers"
             (< (abs (- (gross "bob") (/ 1.0 3.0))) 1e-9) #t))))

;; ── accept-assignment ────────────────────────────────────────────────────────
(with-vat vat
  (let-values (((sr svc) (world)))
    (offer! sr "offer-bob" 4 #:provider "bob")
    (offer! sr "open" 2)
    (display "\n── accept-assignment: an offer names its provider ──\n")
    (check "mallory cannot accept bob's offer"
           (refused? ($ svc 'accept-assignment "s1" "offer-bob" "mallory")) #t)
    (check "bob accepts his own offer"
           (ok? ($ svc 'accept-assignment "s1" "offer-bob" "bob")) #t)
    (check "anyone may take an open work intent"
           (ok? ($ svc 'accept-assignment "s1" "open" "mallory")) #t)))

;; ── claim ────────────────────────────────────────────────────────────────────
(define (claim-world)
  (declare-claimable! "spec-bread")      ; a solve in an earlier scope clears the registry
  (let-values (((sr svc) (world)))
    (let ((rs ($ sr 'recipe-store)) (obs ($ sr 'observer)))
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
      (record-work! obs "alice" 10 "ev1" "in1")
      ($ obs 'record-event
         (make-economic-event #:id "ev-bread" #:action 'produce #:resource-inventoried-as "r-bread" #:resource-conforms-to "spec-bread"
           #:resource-classified-as (list "individually-claimable") #:provider "commune" #:receiver "commune"
           #:resource-quantity (make-measure 10 "each") #:has-point-in-time "2026-03-02T12:00:00Z"))
      (plan-claim! obs "spec-bread" "alice" 6)
      (values sr svc obs))))

(with-vat vat
  (let-values (((sr svc obs) (claim-world)))
    (let ((bal (lambda () ($ obs 'credit-balance "alice")))
          (pool (lambda () (mq (economic-resource-onhand-quantity ($ obs 'get-resource "r-bread"))))))
      (display "\n── claim: the cost is the good's crystallized labour ──\n")
      (check "alice holds 10 hours of credit"                    (= (bal) 10) #t)
      (let ((r ($ svc 'claim "s1" "r-bread" 1 "alice" 0)))
        (check "a stated cost of 0 does not make the loaf free"  (ok? r) #t)
        (check "the door charged the derived 3 hours"            (= (assq-ref (cdr r) 'claimed) 3) #t)
        (check "the balance fell by 3"                           (= (bal) 7) #t))
      (let ((r ($ svc 'claim "s1" "r-bread" 1 "alice" -100)))
        (check "a negative stated cost does not mint credit"     (ok? r) #t)
        (check "the door charged the derived 3 hours again"      (= (assq-ref (cdr r) 'claimed) 3) #t)
        (check "the balance fell to 4"                           (= (bal) 4) #t))
      (let ((before (bal)) (stock (pool)))
        (check "a negative quantity is refused"   (refused? ($ svc 'claim "s1" "r-bread" -1 "alice" -100)) #t)
        (check "a zero quantity is refused"       (refused? ($ svc 'claim "s1" "r-bread" 0 "alice" #f)) #t)
        (check "a NaN quantity is refused"        (refused? ($ svc 'claim "s1" "r-bread" +nan.0 "alice" #f)) #t)
        (check "refused claims leave the balance"  (= (bal) before) #t)
        (check "…and the pool's stock"             (= (pool) stock) #t)))))

(test-summary!)
