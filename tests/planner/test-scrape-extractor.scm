;;; test-scrape-extractor.scm — the SCRAPE stage of the curation pipeline
;;; (docs/planning/legal/legal-compliance-lifecycle.md §14): statute prose → a
;;; `reported` rule-pack, reviewed, then steward-verified.
;;;
;;;   (1) extract — prose → rules grouped per crossing, onto the demand
;;;       vocabulary (obtain/pay/tell/forbid), obtain riding person vs entity;
;;;   (2) evidence — every extracted demand is paired with its source clause for
;;;       the steward's review;
;;;   (3) the safety gate — NOTHING scraped is 'verified; it loads at 'reported,
;;;       so the downstream dry-run refuses autonomous submission;
;;;   (4) it FIRES — save → load-rule-packs → the extracted rule drives the live
;;;       legal fold (obtain at a food-vending context; forbid as a tension);
;;;   (5) steward-verify — the one human act promotes a reviewed rule to 'verified.
;;;
;;; Run: guile -L module tests/planner/test-scrape-extractor.scm

(use-modules (playnet test harness) (srfi srfi-1) (ice-9 format))

(use-modules (playnet planner legal crossings))
(use-modules (playnet planner legal registry))
(use-modules (playnet planner knowledge law scrape))

;; a small synthetic municipal code (the "scraped" input).
(define statute
  (string-append
   "Section 4. Any person who operates a food establishment or sells food to the "
   "public must obtain a Food Establishment Permit from the health department "
   "before commencing operations. Each individual who handles food must hold a "
   "Food Handler Card. The operator shall pay an annual food facility fee. The "
   "establishment must file a monthly sales tax return with the treasurer. "
   "Section 12. No person shall sell raw milk to the public."))

;;; ─── (1) extract prose → a reported rule-pack ─────────────────────────────
(define-values (rules report)
  (extract-rules #:jurisdiction "foodville" #:text statute
                 #:source "Foodville Municipal Code (scraped)" #:as-of "2026-07-16"
                 #:steward "scope:food.foodville"))
(define (rule-by-label lbl) (find (lambda (r) (equal? (legal-rule-label r) lbl)) rules))
(define food-rule (rule-by-label "foodville/food-vending (extracted)"))
(define (dnames r) (map demand-name (legal-rule-demands r)))

(display "\n── (1) statute prose → rules grouped per crossing ──\n")
(for-each (lambda (r) (format #t "  ~a: ~s\n" (legal-rule-label r) (dnames r))) rules)
(check "the extractor grouped the statute into two crossings"
       (sort (map legal-rule-label rules) string<?)
       '("foodville/food-vending (extracted)" "foodville/public-sale (extracted)"))
(check-pred "the food rule pulled the establishment permit, the handler card, and the fee"
            (and food-rule
                 (member "Food Establishment Permit" (dnames food-rule))
                 (member "Food Handler Card" (dnames food-rule))
                 (member "annual food facility fee" (dnames food-rule))))
;; obtain rides ENTITY for a facility permit, PERSON for a competence card.
(define (demand-named r nm) (find (lambda (d) (equal? (demand-name d) nm)) (legal-rule-demands r)))
(check "the establishment permit rides an ENTITY (a facility door)"
       (demand-rides (demand-named food-rule "Food Establishment Permit")) 'entity)
(check "the handler card rides a PERSON (a competence)"
       (demand-rides (demand-named food-rule "Food Handler Card")) 'person)

;;; ─── (2) an evidence sheet for the steward ────────────────────────────────
(display "\n── (2) every extracted demand carries its source clause ──\n")
(format #t "  ~a demands extracted, each with evidence\n" (length report))
(check "one report row per extracted demand (three obtains/pay + tell + forbid)"
       (length report) 5)
(check-pred "each row pairs the inferred demand with the clause it came from"
            (every (lambda (e) (and (assq-ref e 'kind) (assq-ref e 'name)
                                    (string? (assq-ref e 'evidence)) (assq-ref e 'strength)))
                   report))

;;; ─── (3) the safety gate: nothing scraped is trusted ──────────────────────
(display "\n── (3) everything loads at 'reported — never auto-verified ──\n")
(check-pred "NO extracted rule is 'verified (the submission gate stays shut)"
            (every (lambda (r) (eq? (legal-rule-confidence r) 'reported)) rules))

;;; ─── (4) the extracted rules FIRE in the engine (save → load → fold) ──────
(define pack (string-append (or (getenv "TMPDIR") "/tmp") "/foodville-scraped-"
                            (number->string (getpid)) ".sexp"))
(call-with-values
  (lambda () (extract-and-save pack #:jurisdiction "foodville" #:text statute
                               #:source "Foodville Municipal Code (scraped)"
                               #:as-of "2026-07-16" #:steward "scope:food.foodville"))
  (lambda (n rep) (check "extract-and-save wrote a two-rule pack" n 2)))
(define loaded (load-rule-pack pack))
(define (parent-of id) (if (equal? id "foodville") "world" #f))
(define (ctx-at cross) (legal-context #:crossings (list cross)
                                      #:place-path (jurisdiction-path "foodville" parent-of) #:act 'activity))
(define bill-food
  (call-with-values (lambda () (legal-demands (ctx-at 'food-vending) #:rules loaded))
    (lambda (bill hits) bill)))
(define bill-sale
  (call-with-values (lambda () (legal-demands (ctx-at 'public-sale) #:rules loaded))
    (lambda (bill hits) bill)))
(display "\n── (4) a reloaded scraped rule drives the live legal fold ──\n")
(format #t "  food-vending obtain-entity: ~s\n" (map demand-name (assq-ref bill-food 'obtain-entity)))
(format #t "  public-sale forbid: ~s\n" (map demand-name (assq-ref bill-sale 'forbid)))
(check-pred "the reloaded scraped rule yields the food establishment permit at a food-vending door"
            (member "Food Establishment Permit" (map demand-name (assq-ref bill-food 'obtain-entity))))
(check-pred "the extracted ban fires as a possibility-tension (forbid) at a public-sale door"
            (pair? (assq-ref bill-sale 'forbid)))

;;; ─── (5) steward-verify: the one human act promotes to 'verified ──────────
(define verified (steward-verify food-rule "scope:food.foodville"))
(display "\n── (5) a steward reviews the evidence and promotes to 'verified ──\n")
(format #t "  before: ~a   after: ~a\n" (legal-rule-confidence food-rule) (legal-rule-confidence verified))
(check "before review the rule is 'reported" (legal-rule-confidence food-rule) 'reported)
(check "steward-verify re-issues it at 'verified under the steward's scope"
       (list (legal-rule-confidence verified) (legal-rule-steward verified))
       '(verified "scope:food.foodville"))
(check "…preserving the demands it certifies"
       (sort (dnames verified) string<?) (sort (dnames food-rule) string<?))

(display "\n")
(test-summary!)
