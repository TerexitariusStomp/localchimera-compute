;;; test-household-care.scm — cooking, childcare and eldercare/sick-care: the
;;; family docs/planning/food/reproduction-of-labour-power.md §4 names as still
;;; missing once cleaning, dishes and laundry are recipes (test-household-
;;; recipe.scm). Same shape, same weight: real recipes a plan can choose
;;; among, illustrative numbers a household with its own measure replaces.
;;;
;;; Run from repo root:
;;;   guile --no-auto-compile -q -L module \
;;;     tests/scope/test-household-care.scm

(use-modules (playnet solve federation-solve))
(use-modules (playnet test harness))
(use-modules (playnet knowledge recipes household) (playnet scope root) (playnet vf schemas) (srfi srfi-1))
(use-modules (playnet knowledge catalogues substances))
(use-modules (goblins) (goblins persistence-store memory)
             (srfi srfi-1))

(display "\n── Setup: household ──\n")

(define vat (spawn-vat #:name "household-care"))
(define scope (with-vat vat (spawn-scope-root "Household Care Test")))
(define rs (with-vat vat ($ scope 'recipe-store)))
(with-vat vat (seed-household-care-recipes rs))

(define (chain id) (with-vat vat ($ rs 'get-process-chain id)))
(define (flows pid)
  (let ((io (with-vat vat ($ rs 'flows-for-process pid))))
    (append (car io) (cdr io))))
(define (flow-of pid id) (find (lambda (f) (equal? id (recipe-flow-id f))) (flows pid)))
(define (qty f) (and f (recipe-flow-resource-quantity f)
                     (measure-has-numerical-value (recipe-flow-resource-quantity f))))
(define (effort f) (and f (recipe-flow-effort-quantity f)
                        (measure-has-numerical-value (recipe-flow-effort-quantity f))))

(display "\n── every recipe is seeded, each a single step ──\n")
(for-each
 (lambda (id) (check-pred (string-append id " seeded as a one-step recipe")
                          (= 1 (length (chain id)))))
 '("recipe-hh-cook" "recipe-hh-mind-child" "recipe-hh-care"))

(display "\n── cooking: raw food and labour in, a cooked meal out ──\n")
(check-pred "cooking delivers a cooked meal as its primary output"
            (string=? "spec-hh-meal-cooked"
                      (recipe-primary-output (with-vat vat ($ rs 'get-recipe "recipe-hh-cook")))))
(check "45 minutes of somebody's time, 1.5 kg of raw food, for four meals"
       (and (= 0.75 (effort (flow-of "rp-hh-cook" "rf-hh-ck-work")))
            (= 1.5 (qty (flow-of "rp-hh-cook" "rf-hh-ck-in")))
            (= 4 (qty (flow-of "rp-hh-cook" "rf-hh-ck-out")))))
(check "the work is named skill-hh-cooking, its own line, not the general skill-hh-domestic"
       (equal? "skill-hh-cooking" (recipe-flow-resource-conforms-to (flow-of "rp-hh-cook" "rf-hh-ck-work"))))

(display "\n── childcare and eldercare: labour and nothing else, an hour for an hour ──\n")
(check-pred "childcare delivers a child minded"
            (string=? "spec-hh-child-minded"
                      (recipe-primary-output (with-vat vat ($ rs 'get-recipe "recipe-hh-mind-child")))))
(check-pred "eldercare delivers care given"
            (string=? "spec-hh-care-given"
                      (recipe-primary-output (with-vat vat ($ rs 'get-recipe "recipe-hh-care")))))
(check "an hour minded is an hour of skill-hh-childcare worked, one for one"
       (and (= 1.0 (effort (flow-of "rp-hh-mind-child" "rf-hh-cc-work")))
            (= 1.0 (qty (flow-of "rp-hh-mind-child" "rf-hh-cc-out")))
            (equal? "skill-hh-childcare" (recipe-flow-resource-conforms-to (flow-of "rp-hh-mind-child" "rf-hh-cc-work")))))
(check "an hour of care given is an hour of skill-hh-eldercare worked, one for one"
       (and (= 1.0 (effort (flow-of "rp-hh-care" "rf-hh-cr-work")))
            (= 1.0 (qty (flow-of "rp-hh-care" "rf-hh-cr-out")))
            (equal? "skill-hh-eldercare" (recipe-flow-resource-conforms-to (flow-of "rp-hh-care" "rf-hh-cr-work")))))
(check-pred "childcare carries no means and no material flow at all — labour, and nothing else"
            (null? (filter (lambda (f) (memq (recipe-flow-action f) '(use consume)))
                           (flows "rp-hh-mind-child"))))
(check-pred "…and neither does eldercare"
            (null? (filter (lambda (f) (memq (recipe-flow-action f) '(use consume)))
                           (flows "rp-hh-care"))))

;;; ── the material claim: no tracked element is conjured or destroyed ──────────
(display "\n── conservation: cooking and care touch no tracked element ──\n")
(define all-procs (append-map chain '("recipe-hh-cook" "recipe-hh-mind-child" "recipe-hh-care")))
(define (substance-flows pid) (balance-flows (flows pid) #:basis? #f))
(define offenders
  (filter-map
   (lambda (rp)
     (let* ((pid (recipe-process-id rp))
            (fs (substance-flows pid))
            (res (and (pair? fs) (check-conservation fs))))
       (and res (pair? res) (cons pid res))))
   all-procs))
(for-each (lambda (o) (format #t "  UNBALANCED ~a: ~s\n" (car o) (cdr o))) offenders)
(check-pred "no cooking or care process conjures or destroys a tracked element"
            (null? offenders))

(test-summary!)
