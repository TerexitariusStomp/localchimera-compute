;;; test-recipe-library.scm — the recipe-library actor serves recipes to the planner
;;;
;;; Seeds an in-memory recipe library with the bread chain, then uses it AS the
;;; recipe-store a scope hands to plan-scope — showing the library drops straight
;;; into the planner (the intended sim/test use), and that the catalogue/seed API
;;; works.

(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness)
             (srfi srfi-1)
             (playnet planner scope live)
             (playnet planner knowledge dsl recipe-library)
             (playnet test planner bread)   ; bread-defs · bread-plain-resources · bread-plain-agents · bread-spatials
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

;; ── the town: the seed's own recipes as library defs, its stock and its skilled
;; people — the whole table, since a town that plans its people's reproduction
;; feeds them the whole band, and grain alone starves them (bread-commune-seed)
(define resources bread-plain-resources) (define agents bread-plain-agents) (define spatials bread-spatials)

(define vat (spawn-vat #:name "lib-test"))
(define out
  (with-vat vat
    (let* ((rl  (spawn-recipe-library (bread-defs)))   ; the library IS the recipe-store
           (obs (spawn ^mock `((all-resources . ,(lambda () resources)))))
           (as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rl)))
      (list ($ rl 'catalog) ($ rl 'count)
            (plan-scope->alist scope #:demand '(("bread#town@0" . 20.0)) #:backend 'native-c)))))

(define catalog (car out))
(define plan    (caddr out))
(define work    (assq-ref plan 'work))

(display "\n── recipe-library: catalogue + planning over it ──\n")
(check "library catalogues the bread recipe among the town's"
       (equal? (assoc-ref catalog "bread-recipe") "Bread"))
(check "library holds every recipe of the town's table — one per product"
       (= (cadr out) (length bread-recipes)))
(check "planner plans over the library: demand met" (> (assq-ref plan 'met) 0.5))
;; which of the table's foods close the band is the plan's to choose (with the fields
;; drawing on the whole air the crops alone can, and the baker's hours go to the
;; loaves), so the property is that the floors HOLD, whatever was fished or milked
(check "and emits work commitments for the bread recipe's skills, the town's floors held beside them"
       (let ((skills (delete-duplicates (map (lambda (w) (assq-ref w 'conforms-to)) work))))
         (and (lset<= equal? '("skill-bake" "skill-farm" "skill-mill") skills)
              (eq? #t (assq-ref plan 'feasible)))))

(test-summary!)
