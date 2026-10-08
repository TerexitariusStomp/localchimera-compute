;;; test-crystallized-claim.scm — claims settle at SNLT_crystallized
;;;
;;; playnet.typ: "credit and recipe-sizing use SNLT_crystallized (the total
;;; congealed in a unit)" — the surface's areas keep SNLT_direct. This suite
;;; pins the distinction with a recipe where the two DIVERGE: a cake takes
;;; 1 h of direct work plus 2 kg of flour, and flour itself takes 0.5 h/kg —
;;; so direct = 1 h but crystallized = 1 + 2×0.5 = 2 h. The pool K, the
;;; derived claim cost, and the wire price must all say 2, never 1.
;;; Run: guile -L module tests/planner/test-crystallized-claim.scm

(use-modules (playnet test harness))
(use-modules (playnet planner algorithms propagation) (playnet planner algorithms rollup) (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1))
(use-modules (playnet planner doors service))
(use-modules (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))


(use-modules ((playnet planner observation account) #:select (declare-claimable!)))
;; the rail is read off the recipes: this fixture stands in for the plan and
;; declares that a claim recipe stands for spec-cake (account.scm spec-claimable?)
(declare-claimable! "spec-cake")
(use-modules ((playnet test scope) #:select (plan-claim!)))   ; the plan's row, stood by the fixture

(define (work! obs aid skill hours eid iid)
  ($ obs 'register-intent
     (make-intent #:id iid #:action 'work #:resource-conforms-to skill
                  #:effort-quantity (make-measure hours "hour") #:provider aid))
  ($ obs 'record-event
     (make-economic-event #:id eid #:action 'work #:resource-conforms-to skill #:provider aid
                          #:effort-quantity (make-measure hours "hour")
                          #:has-point-in-time "2026-03-01T08:00:00Z" #:satisfies iid
                          #:in-scope-of '())))

(define (recipe! rs id name spec work-h . inputs)
  ;; one-process recipe: WORK-H hours + INPUTS ((spec qty unit) …) → 1 SPEC
  (let ((rp (string-append "rp-" id)))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id rp #:name name #:process-conforms-to (string-append "pspec-" id)
                            #:has-duration (make-duration work-h "hours")))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id (string-append "rf-" id "-work") #:action 'work
                         #:resource-conforms-to "spec-labor"
                         #:effort-quantity (make-measure work-h "hours") #:recipe-input-of rp))
    (for-each
     (lambda (in)
       ($ rs 'add-recipe-flow
          (make-recipe-flow #:id (string-append "rf-" id "-" (car in)) #:action 'consume #:resource-conforms-to (car in)
                            #:resource-quantity (make-measure (cadr in) (caddr in))
                            #:recipe-input-of rp)))
     inputs)
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id (string-append "rf-" id "-out") #:action 'produce #:resource-conforms-to spec
                         #:resource-quantity (make-measure 1 "each") #:recipe-output-of rp))
    ($ rs 'add-recipe (make-recipe #:id id #:name name #:primary-output spec
                                   #:recipe-processes (list rp)))))

(define vat (spawn-vat))
(define-values (svc-ref rs-ref obs-ref)
  (with-vat vat
    (let* ((sr  (spawn-scope-root "Crystal Scope"))
           (rs  ($ sr 'recipe-store))
           (obs ($ sr 'observer))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "s1" sr))))
      (recipe! rs "recipe-flour" "Mill flour" "spec-flour" 0.5)
      (recipe! rs "recipe-cake"  "Bake cake"  "spec-cake"  1
               '("spec-flour" 2 "kg"))
      ;; alice earns 10 validated hours; 5 claimable cakes exist
      (work! obs "alice" "spec-labor" 10 "ev1" "in1")
      (plan-claim! obs "spec-cake" "alice" 2)   ; the plan's row: two cakes for alice
      ($ obs 'record-event
         (make-economic-event #:id "ev-cake" #:action 'produce #:resource-inventoried-as "r-cake" #:resource-conforms-to "spec-cake"
           #:resource-classified-as (list "individually-claimable") #:provider "commune" #:receiver "commune"
           #:resource-quantity (make-measure 5 "each") #:has-point-in-time "2026-03-02T12:00:00Z"))
      (values svc rs obs))))

(with-vat vat
  (let ((svc svc-ref) (rs rs-ref) (obs obs-ref))
    (display "\n── the two measures diverge on a recipe with inputs ──\n")
    (check "direct = 1 h (work only)"
           (= 1 (min-snlt-for-spec rs "spec-cake")) #t)
    (check "crystallized = 2 h (work + embodied flour)"
           (= 2 (crystallized-snlt-for-spec rs "spec-cake")) #t)

    (display "\n── the claim settles at the CRYSTALLIZED cost ──\n")
    (let ((r ($ svc 'claim "s1" "r-cake" 1 "alice" #f)))
      (check "claim ok"              (car r) 'ok)
      (check "cost = 2 h, not 1"     (= 2 (assq-ref (cdr r) 'claimed)) #t)
      (check "balance 10 − 2 = 8"    (= 8 (assq-ref (cdr r) 'balance)) #t)
      ;; K values the remaining 4 cakes in the same measure: 4 × 2 = 8
      (check "pool K = 4 × 2 = 8 (crystallized, matching the claim)"
             (= 8 (assq-ref (assq-ref (cdr r) 'credit) 'pool)) #t))

    (display "\n── a claim carries WHERE and WHEN onto the transfer ──\n")
    (let* ((r  ($ svc 'claim "s1" "r-cake" 1 "alice" #f
                  "loc-commons-pantry" "2026-08-01T09:00:00Z"))
           (ev (find (lambda (e) (and (eq? (economic-event-action e) 'transfer)
                                      (equal? (economic-event-to-location e)
                                              "loc-commons-pantry")))
                     ($ obs 'all-events))))
      (check "claim ok"            (car r) 'ok)
      (check "to-location = where" (and ev #t) #t)
      (check "has-point-in-time = when"
             (and ev (economic-event-has-point-in-time ev)) "2026-08-01T09:00:00Z"))))

(display "\n")
(test-summary!)
