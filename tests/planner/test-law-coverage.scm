;;; test-law-coverage.scm — a pack can be correct, linted, in force, and silent.
;;;
;;; A rule only fires when a recipe trips its crossing. So a scope can carry a
;;; whole PLU — 25 rules, every jurisdiction placed, every window in order — and
;;; have it say nothing at all about what the federation actually does, because
;;; its rules guard on crossings no recipe trips. Nothing at runtime tells the
;;; two apart: the plan runs, no demand appears, and permission is indis-
;;; tinguishable from unlegislated.
;;;
;;; That is the same failure the rest of the legal layer keeps producing, one
;;; layer further out, and it cannot be fixed by writing more rules — only by
;;; saying which side of the gap you are on.
;;;
;;; Run: guile -L module tests/planner/test-law-coverage.scm

(use-modules (playnet test harness) (playnet planner knowledge recipes store) (playnet planner knowledge recipes food-surplus) (srfi srfi-1)
             (playnet planner legal gate) (playnet planner legal crossings)
             (playnet planner knowledge law lint)
             (playnet planner knowledge law context-pack)
             (playnet planner knowledge recipes compliance-food)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (ice-9 format))

(define contexts "docs/legal/contexts")
;; EVERY French pack, derived — not a list of the two that existed when this was
;; written. Naming them froze a snapshot: two more French packs landed later and
;; "the French packs alone" quietly stopped meaning all of them, which is the
;; same defect as a rule that can never fire and never says so.
(define fr-only
  (filter (lambda (p) (string-prefix? "fr-" (basename p))) (pack-paths contexts)))

;; the recipes a food-distributing commune actually runs
(define recipe-x
  (let ((vat (spawn-vat)))
    (with-vat vat
      (let ((rs (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap))))
        (seed-food-surplus-recipe rs)
        (seed-food-surplus-3step-recipe rs)
        (seed-compliance-food-recipe rs)
        (store-crossings rs)))))

(define (kinds fs k)
  (sort (map finding-subject (filter (lambda (f) (eq? k (finding-kind f))) fs))
        (lambda (a b) (string< (symbol->string a) (symbol->string b)))))

(display "\n── what the commune does, and what its law speaks to ──\n")
(format #t "  crossings its recipes trip: ~a\n"
        (sort recipe-x (lambda (a b) (string< (symbol->string a) (symbol->string b)))))

(define fr (law-coverage recipe-x (pack-crossings fr-only)))
(format #t "  under the FRENCH packs alone — uncovered ~a\n" (kinds fr 'uncovered-crossing))
(format #t "                                inert     ~a\n" (kinds fr 'inert-crossing))
(check-pred "the French packs are INERT for this commune — every rule guards a crossing no recipe trips"
            (and (null? (lset-intersection eq? recipe-x (pack-crossings fr-only)))
                 (pair? (kinds fr 'inert-crossing))))
(check-pred "…so everything the commune actually does is reported as uncovered, not passed over"
            (equal? (kinds fr 'uncovered-crossing)
                    (sort recipe-x (lambda (a b) (string< (symbol->string a) (symbol->string b))))))

(display "\n── and with the German pack, which was curated to a use case ──\n")
(define all (law-coverage recipe-x (pack-crossings contexts)))
(format #t "  uncovered ~a\n" (kinds all 'uncovered-crossing))
(check-pred "de.sexp covers the food ground the French pack does not — measurably, not by impression"
            (< (length (kinds all 'uncovered-crossing))
               (length (kinds fr 'uncovered-crossing))))
(check-pred "an uncovered crossing is a WARNING — a known unknown, not a defect"
            (every (lambda (f) (eq? 'warning (finding-severity f)))
                   (filter (lambda (f) (eq? 'uncovered-crossing (finding-kind f))) all)))
(check-pred "an inert one is INFO — the law is loaded and simply cannot fire here"
            (every (lambda (f) (eq? 'info (finding-severity f)))
                   (filter (lambda (f) (eq? 'inert-crossing (finding-kind f))) all)))

(display "\n── the shape of an answer ──\n")
;;; The point is not that the gap closes. It is that "my law says nothing about
;;; this" becomes something a scope can be told, instead of something it has to
;;; infer from a plan that ran without complaint.
(check-pred "a scope whose recipes trip nothing the packs guard learns exactly that"
            (pair? (kinds fr 'uncovered-crossing)))
(test-summary!)
