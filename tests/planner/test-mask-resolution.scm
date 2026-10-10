;;; test-mask-resolution.scm — subject-across-masks: a demand binds to WHICHEVER
;;; per-door mask holds that door (playnet.typ: a mask is per-door, not per-asset).
;;;
;;; `mask-subject-of` builds the `subject-of` reconcile/holding-status already take,
;;; so the compliance fold needs no change: an entity demand routes to the mask
;;; covering its spec, a person demand to the named practitioner. Pure data ⇒ no blake3.
;;;
;;; Run: guile -L module tests/planner/test-mask-resolution.scm

(use-modules (playnet test harness) (playnet planner observation observer) (playnet planner vf schemas) (srfi srfi-1)
             (goblins) (goblins vat) (srfi srfi-1) (ice-9 format))

(use-modules (playnet planner legal crossings))
(use-modules (playnet planner legal registry))
(use-modules (playnet planner legal registry-actor))
(use-modules (playnet planner legal compliance)) (use-modules (playnet planner legal adapters))

(define (held-cred id spec holder)
  (make-economic-resource #:id id #:name spec #:conforms-to spec #:classified-as '("credential")
    #:onhand-quantity (make-measure 1 "cert") #:primary-accountable holder #:state "active"))
(define (rule-food)
  (rule (all-of (in-jurisdiction "foodville") (on-crossing 'food-vending))
        (list (obtain #:rides 'entity #:name "Food Establishment Permit"))
        #:label "foodville/food-vending" #:confidence 'verified #:steward "s"))
(define (rule-build)
  (rule (all-of (in-jurisdiction "buildville") (on-crossing 'built-structure))
        (list (obtain #:rides 'entity #:name "Building Permit"))
        #:label "buildville/built-structure" #:confidence 'verified #:steward "s"))

(define vat (spawn-vat))
(define out
  (with-vat vat
    (let ((obs (spawn ^observer (empty-observer-state) '())))
      ;; two PER-DOOR masks: FoodCo holds the food-vending door in foodville,
      ;; BuildCo the built-structure door in buildville. Each covers exactly its door.
      (define maskA (spawn-adapter #:id "mask:food" #:name "FoodCo" #:jurisdiction 'foodville
                                   #:crossings '(food-vending) #:place-path '("foodville" "world")
                                   #:rules (list (rule-food))))
      (define maskB (spawn-adapter #:id "mask:build" #:name "BuildCo" #:jurisdiction 'buildville
                                   #:crossings '(built-structure) #:place-path '("buildville" "world")
                                   #:rules (list (rule-build))))
      (define masks (list maskA maskB))
      (define subj (mask-subject-of masks))
      ;; grant the food permit into FoodCo's custody (NOT BuildCo's)
      ($ obs 'seed-resource (held-cred "res:fp" "Food Establishment Permit" "mask:food"))
      (list
       ;; ── the resolver binds each demand to its door's mask ──
       (subj (obtain #:rides 'entity #:name "Food Establishment Permit") 'obtain-entity)  ; mask:food
       (subj (obtain #:rides 'entity #:name "Building Permit")           'obtain-entity)  ; mask:build
       (subj (obtain #:rides 'entity #:name "Liquor License")            'obtain-entity)  ; fallback
       (subj (obtain #:rides 'person #:name "Food Handler Card")         'obtain-person)  ; person
       (adapter-spawn-entity-needs maskA) (adapter-spawn-entity-needs maskB)
       ;; ── integration: reconcile the food bill with the mask resolver ──
       (call-with-values
         (lambda () (legal-demands (legal-context #:crossings '(food-vending)
                                                  #:place-path '("foodville" "world"))
                                   #:rules (list (rule-food))))
         (lambda (bill hits) (reconcile bill hits obs "2026-07-14" #:subject-of subj)))))))

(define r-food  (list-ref out 0)) (define r-build (list-ref out 1))
(define r-unk   (list-ref out 2)) (define r-person(list-ref out 3))
(define needsA  (list-ref out 4)) (define needsB (list-ref out 5))
(define recon   (list-ref out 6))

(display "\n── subject-across-masks: each door's demand binds to its own mask ──\n")
(format #t "  food→~s  build→~s  unknown→~s  person→~s\n" r-food r-build r-unk r-person)
(check "each mask covers exactly its own door" (list needsA needsB)
       '(("Food Establishment Permit") ("Building Permit")))
(check "the food permit resolves to FoodCo's mask"     r-food  "mask:food")
(check "the building permit resolves to BuildCo's mask" r-build "mask:build")
(check "a door no mask holds falls back"                r-unk   'scope)
(check "a person competence rides the named practitioner, not a mask" r-person 'person)

(display "\n── integration: reconcile routes each demand to its mask's custody ──\n")
(format #t "  reconciliation: ~s\n" recon)
(let ((perm (find (lambda (e) (equal? (caddr e) "Food Establishment Permit")) recon)))
  (check-pred "the permit demand appears in the reconciliation" (and perm #t))
  (check "…keyed to FoodCo's mask (the door's holder)" (caddr (car perm)) "mask:food")
  (check "…and satisfied, since FoodCo holds it" (entry-status perm) 'satisfied))

(display "\n")
(test-summary!)
