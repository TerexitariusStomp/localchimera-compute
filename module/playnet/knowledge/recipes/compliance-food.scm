;;; compliance-food.scm — the food-distribution worked example for the legal
;;; compliance lifecycle (docs/legal/legal-compliance-lifecycle.md §10).
;;;
;;; A scope that VENDS food to the public trips a `food-vending` crossing (public
;;; sale). A jurisdiction answers that crossing with an ENTITY permit demand (a
;;; Food Establishment Permit) and a PERSON competence (a Food Handler Card). The
;;; recipe below only TRIPS the crossing — via a `crossing:food-vending` tag on
;;; the vended good, read by legal/crossings.scm — exactly as food-surplus.scm trips
;;; `share-food`. The permit REQUIREMENT is derived from the legal rule
;;; (legal/registry.scm), and ENFORCED by compliance.scm's observer-aware
;;; decorate: an un-held permit prunes the vend process's column.
;;;
;;; This keeps the two representations clean: the recipe carries the crossing
;;; (an intrinsic, placeless fact), the rule carries the demand (per
;;; jurisdiction), and the observer carries the holding (what we actually have).

;; ─── Resource specifications ────────────────────────────────────────────────
;; The vended good is tagged with the crossing it trips; the meal spec is what
;; the public receives. (id name note image classified-as unit … — 11 fields,
;; mirroring food-surplus.scm.)
(define-module (playnet knowledge recipes compliance-food)
  #:use-module ((playnet utils units) #:select (%effort-unit))
  #:use-module (playnet legal registry)
  #:use-module (playnet vf schemas)
  #:use-module (goblins)
  #:use-module ((playnet knowledge recipes handover) #:select (state-exchange!))
  #:export (cf-sorted-produce-spec cf-meal-spec cf-cook-skill-spec cf-food-permit-spec
            cf-handler-card-spec seed-compliance-food-recipe compliance-food-rule
            fd-member-produce-spec fd-public-produce-spec fd-member-meal-spec
            fd-public-meal-spec fd-cook-spec seed-food-distribution-recipes
            banville-food-ban-rule))

(define cf-sorted-produce-spec
  (make-resource-specification
    #:id "spec-cf-produce" #:name "Sorted Produce (for vending)"
    #:resource-classified-as '("food") #:default-unit-of-resource "kg"))

(define cf-meal-spec
  (make-resource-specification
    #:id "spec-cf-meal" #:name "Prepared Meal" #:resource-classified-as '("food") #:default-unit-of-resource "meal"))

(define cf-cook-skill-spec
  (make-resource-specification
    #:id "spec-cf-cook" #:name "Cook" #:resource-classified-as '() #:default-unit-of-resource %effort-unit))

;; The credential specs — a permit/licence is an ordinary <resource-specification>
;; whose id is the demand-name (compliance.scm demand->spec-id). A held credential
;; is an <economic-resource> conforming to one of these.
(define cf-food-permit-spec
  (make-resource-specification
    #:id "Food Establishment Permit" #:name "Food Establishment Permit" #:resource-classified-as '("credential") #:default-unit-of-resource "cert"))

(define cf-handler-card-spec
  (make-resource-specification
    #:id "Food Handler Card" #:name "Food Handler Card" #:resource-classified-as '("credential") #:default-unit-of-resource "cert"))

;; ─── Seed function ──────────────────────────────────────────────────────────
(define (seed-compliance-food-recipe recipe-store)
  "Seed the public food-vending recipe: sorted produce + cook labour → a meal
   handed to the public (trips food-vending). Registers the credential specs too,
   so a held permit/card can conform to them."
  (for-each (lambda (s) ($ recipe-store 'add-resource-spec s))
            (list cf-sorted-produce-spec cf-meal-spec cf-cook-skill-spec
                  cf-food-permit-spec cf-handler-card-spec))

  ;; the meal is SOLD: handed over with money coming back
  (state-exchange! recipe-store "rx-cf-vend" "A meal, sold to the public" #:money "spec-eur")
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-cf-vend" #:name "Vend Meal to Public"
                          #:has-duration (make-duration 0.5 %effort-unit)))

  ;; consume sorted produce
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-cf-produce-in" #:action 'consume #:resource-conforms-to "spec-cf-produce"
                       #:resource-quantity (make-measure 1.0 "kg") #:recipe-input-of "rp-cf-vend"))
  ;; cook labour
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-cf-cook" #:action 'work #:resource-conforms-to "spec-cf-cook"
                       #:effort-quantity (make-measure 0.5 %effort-unit) #:recipe-input-of "rp-cf-vend"))
  ;; produce the meal for the public (the output the demand pulls)
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-cf-meal-out" #:action 'produce #:resource-conforms-to "spec-cf-meal"
                       #:resource-quantity (make-measure 1.0 "meal") #:recipe-output-of "rp-cf-vend" #:recipe-clause-of "rx-cf-vend" #:is-primary #t))

  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-cf-vend" #:name "Vend Meal to Public" #:primary-output "spec-cf-meal"
                  #:recipe-processes (list "rp-cf-vend") #:recipe-exchanges (list "rx-cf-vend"))))

;; ─── The jurisdiction's rule : the crossing → the demand ────────────────────
;; A steward would register this in the ^legal-registry. Public food-vending in
;; `foodville` demands an entity Food Establishment Permit + a person Food
;; Handler Card + sales tax. (Uses the `rule`/`obtain`/`pay` vocabulary from
;; legal/registry.scm — load it before calling.)
(define (compliance-food-rule)
  (rule (all-of (in-jurisdiction "foodville") (on-crossing 'food-vending))
        (list (obtain #:rides 'entity #:name "Food Establishment Permit"
                      #:issuer "foodville-health" #:per 'each-site
                      #:spec '(fire-safety hygiene labeling))
              (obtain #:rides 'person #:name "Food Handler Card"
                      #:per 'each-handler #:spec '(hygiene-training))
              (pay #:name "Sales Tax" #:base 'gross-receipts #:rate 0.09))
        #:label "foodville/food-vending" #:source "(worked example ordinance)"
        #:as-of "2026-01-01" #:confidence 'verified #:steward "scope:food.foodville"))

;; ─── Multi-jurisdiction food-distribution kit ───────────────────────────────
;; TWO ways to feed people, tripping DIFFERENT crossings — so the SAME goal
;; (a fed person) carries different legal requirements by jurisdiction:
;;   SHARE — member-to-member, trips `share-food` → licenceless everywhere (the
;;           appendix: internal provision on credit summons no establishment).
;;   VEND  — public sale,      trips `food-vending` → a permit where a
;;           jurisdiction demands one, forbidden where it bans it, free where it
;;           has no rule.
;; The crossing tag rides the CONSUMED produce spec (legal/crossings.scm reads it), so
;; the requirement is derived from the recipe, not hand-attached.
(define fd-member-produce-spec
  (make-resource-specification #:id "spec-fd-member-produce" #:name "Produce (member share)"
    #:resource-classified-as '("food") #:default-unit-of-resource "kg"))
(define fd-public-produce-spec
  (make-resource-specification #:id "spec-fd-public-produce" #:name "Produce (public vend)"
    #:resource-classified-as '("food") #:default-unit-of-resource "kg"))
(define fd-member-meal-spec
  (make-resource-specification #:id "member-meal" #:name "Meal (members)"
                               #:resource-classified-as '("food") #:default-unit-of-resource "meal"))
(define fd-public-meal-spec
  (make-resource-specification #:id "public-meal" #:name "Meal (public)"
                               #:resource-classified-as '("food") #:default-unit-of-resource "meal"))
(define fd-cook-spec
  (make-resource-specification #:id "fd-cook" #:name "Cook" #:resource-classified-as '()
                               #:default-unit-of-resource %effort-unit))

(define (seed-food-distribution-recipes recipe-store)
  "Seed the SHARE (member, licenceless) and VEND (public, permit-bearing) recipes
   — same process ids the mock planner and the legal decorate both key on:
   rp-fd-share, rp-fd-vend."
  (for-each (lambda (s) ($ recipe-store 'add-resource-spec s))
            (list fd-member-produce-spec fd-public-produce-spec
                  fd-member-meal-spec fd-public-meal-spec fd-cook-spec))
  ;; SHARE → member-meal: handed over with nothing coming back (share-food)
  (state-exchange! recipe-store "rx-fd-share" "A meal, shared with members")
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-fd-share" #:name "Share Meal with Members"
                          #:has-duration (make-duration 0.5 %effort-unit)))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-fd-share-in" #:action 'consume #:resource-conforms-to "spec-fd-member-produce"
                       #:resource-quantity (make-measure 1.0 "kg") #:recipe-input-of "rp-fd-share"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-fd-share-cook" #:action 'work #:resource-conforms-to "fd-cook"
                       #:effort-quantity (make-measure 0.5 %effort-unit) #:recipe-input-of "rp-fd-share"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-fd-share-out" #:action 'produce #:resource-conforms-to "member-meal"
                       #:resource-quantity (make-measure 1.0 "meal") #:recipe-output-of "rp-fd-share" #:recipe-clause-of "rx-fd-share" #:is-primary #t))
  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-fd-share" #:name "Share Meal with Members" #:primary-output "member-meal"
                  #:recipe-processes (list "rp-fd-share") #:recipe-exchanges (list "rx-fd-share")))
  ;; VEND → public-meal: handed over with money coming back (food-vending)
  (state-exchange! recipe-store "rx-fd-vend" "A meal, sold to the public" #:money "spec-eur")
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-fd-vend" #:name "Vend Meal to Public"
                          #:has-duration (make-duration 0.5 %effort-unit)))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-fd-vend-in" #:action 'consume #:resource-conforms-to "spec-fd-public-produce"
                       #:resource-quantity (make-measure 1.0 "kg") #:recipe-input-of "rp-fd-vend"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-fd-vend-cook" #:action 'work #:resource-conforms-to "fd-cook"
                       #:effort-quantity (make-measure 0.5 %effort-unit) #:recipe-input-of "rp-fd-vend"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-fd-vend-out" #:action 'produce #:resource-conforms-to "public-meal"
                       #:resource-quantity (make-measure 1.0 "meal") #:recipe-output-of "rp-fd-vend" #:recipe-clause-of "rx-fd-vend" #:is-primary #t))
  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-fd-vend" #:name "Vend Meal to Public" #:primary-output "public-meal"
                  #:recipe-processes (list "rp-fd-vend") #:recipe-exchanges (list "rx-fd-vend"))))

;; the jurisdictions answer food-vending differently. foodville = a permit
;; (compliance-food-rule, above). banville = an outright ban. freeville = no rule.
(define (banville-food-ban-rule)
  (rule (all-of (in-jurisdiction "banville") (on-crossing 'food-vending))
        (list (forbid #:reason "public food-vending prohibited"))
        #:label "banville/food-vending-ban" #:source "(worked example ordinance)"
        #:as-of "2026-01-01" #:confidence 'verified #:steward "scope:uc"))
