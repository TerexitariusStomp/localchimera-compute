;;; test-held-good-is-not-a-skill.scm — a good a person holds is not a skill they have.
;;;
;;; vf-agent-skills (solve/engine.scm) read every resource an agent held with an
;;; on-hand quantity as one of their skills, so work asking for skill WATER was met
;;; by a person whose only link to water was a stock of it. A skill is a WORKED
;;; spec — one stating an effort unit, or one a recipe draws as work (formulas/
;;; actions labour-specs) — and the solver, the roster (labour-fold) and the
;;; holders table all read that one function.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-held-good-is-not-a-skill.scm

(use-modules (playnet test harness) (playnet test scope)
             (playnet planner vf schemas) (playnet planner scope live)
             ((playnet planner formulas actions) #:select (labour-specs labour?))
             ((playnet planner facts person-facts) #:select (generic-labour-spec))
             (goblins) (srfi srfi-1) (ice-9 format))

(define PLACE "town")
(define vat (spawn-vat #:name "held-good"))
(define win (all-week-window "00:00" "23:59"))

;; A bread recipe whose one work flow asks for WORK-SKILL; ANN holds SKILLS and
;; GOODS alike as plain resources — what tells them apart is the recipe's word.
(define (run skills goods work-skill)
  (let* ((procs (list (make-recipe-process #:id "bake" #:name "Bake")))
         (flows (list
                 (make-recipe-flow #:id "bw" #:action 'work #:resource-conforms-to work-skill #:effort-quantity (make-measure 1.0 "hours") #:recipe-input-of "bake")
                 (make-recipe-flow #:id "bi" #:action 'consume #:resource-conforms-to "wheat" #:resource-quantity (make-measure 1.0 "kg") #:recipe-input-of "bake")
                 (make-recipe-flow #:id "bo" #:action 'produce #:resource-conforms-to "bread" #:resource-quantity (make-measure 10.0 "kg") #:recipe-output-of "bake" #:is-primary #t)))
         (recipes (list (make-recipe #:id "r" #:name "Bread" #:primary-output "bread" #:recipe-processes (list "bake"))))
         (agents (list (make-agent #:id "ann" #:type 'person #:name "ann" #:primary-location PLACE #:classified-as '() #:availability-window win)))
         (held (lambda (id spec)
                 (make-economic-resource #:id id #:conforms-to spec #:classified-as '()
                                         #:accounting-quantity (make-measure 5.0 "each") #:onhand-quantity (make-measure 5.0 "each")
                                         #:current-location PLACE #:primary-accountable "ann")))
         (resources (append (map (lambda (s) (held (string-append "ann-holds-" s) s)) skills)
                            (map (lambda (g) (held (string-append "ann-" g) g)) goods)))
         (spatials (list (make-spatial-thing #:id PLACE #:lat 40.0 #:long -74.0))))
    (with-vat vat
      (let* ((obs (spawn ^mock `((all-resources . ,(lambda () resources)) (record-event . ,(lambda (e) "ok")))))
             (as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
             (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
             (rs  (spawn ^mock `((all-recipes . ,(lambda () recipes)) (get-process-chain . ,(lambda (rid) procs))
                                 (flows-for-process . ,(lambda (pid) (cons (filter (lambda (f) (equal? (recipe-flow-recipe-input-of f) pid)) flows)
                                                                           (filter (lambda (f) (equal? (recipe-flow-recipe-output-of f) pid)) flows)))))))
             (root (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs)))
        (plan-scope->alist root #:demand '(("bread#town@0" . 40.0)) #:eco-caps (list (cons "wheat#town@0" 100.0)) #:backend 'native-c #:reproduce? #f)))))

(define (hours r) (fold + 0.0 (map (lambda (w) (or (assq-ref w 'effort) 0)) (or (assq-ref r 'work) '()))))

(display "\n── what labour is ──\n")
(let ((flows (list (make-recipe-flow #:id "w" #:action 'work #:resource-conforms-to "welding")
                   (make-recipe-flow #:id "c" #:action 'consume #:resource-conforms-to "water"))))
  (check "a spec a recipe works is labour; one it consumes is not"
         (labour-specs flows '()) '("welding"))
  (check "a spec stating an effort unit is labour by its own word"
         (labour-specs '() (list generic-labour-spec)) '("spec-labor"))
  (check-pred "the predicate indexes both" (let ((l? (labour? flows (list generic-labour-spec))))
                                              (and (l? "welding") (l? "spec-labor") (not (l? "water"))))))

(display "\n── the solve ──\n")
(let ((r (run '() '("water") "welding")))
  (check "a stock of water is no skill: the work asking for WELDING finds nobody in a woman holding water" (hours r) 0.0))
(let ((r (run '() '("water") "water")))
  (check-pred "…and only the recipe's own word makes a spec labour: a recipe that WORKS water reads her stock as the skill"
              (> (hours r) 0.0)))
(let ((r (run '("welding") '() "welding")))
  (check-pred "the skill resource itself meets the work" (> (hours r) 0.0)))
(let ((r (run '("welding") '("water") "welding")))
  (check-pred "a held good beside a held skill changes nothing" (> (hours r) 0.0)))

(test-summary!)
