;;; test-live-wiring.scm — (playnet scope live): live scope-root → plan → VF work Commitments
;;;
;;; Exercises plan-scope against goblins actor stores (mocked here, but reached the
;;; same way the real scope-root is — synchronous near-calls inside a vat). The
;;; convex engine plans over the records the observer/agent/spatial/recipe stores
;;; hand back, and emits VF `work` Commitments (action=work, provider=agent,
;;; conformsTo=skill, effort=hours, inputOf=process). Skills are resolved from each
;;; agent's skill ERs (held resources), hours from their availabilityWindow.

(use-modules (playnet solve report))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness)
             (playnet vf schemas) (srfi srfi-1)
             (playnet scope live)
             (playnet test planner bread)
             (playnet doors service)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

;; generic mock actor: dispatch a method symbol to a table of (sym . proc)
;; ── VF records: bread chain (skills on work flows), soil stock, agents' skill ERs ──
(define procs bread-procs) (define flows bread-flows) (define recipes bread-recipes)
(define resources bread-resources) (define win bread-window)
(define agents bread-agents) (define spatials bread-spatials)

(define vat (spawn-vat #:name "live-test"))
(define both
  (with-vat vat
    (let* ((obs (spawn ^mock `((all-resources . ,(lambda () resources))
                               (hours-by . ,(lambda (key-of . _) '())) (hours-on . ,(lambda (part . _) 0)))))
           (as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs  (spawn ^mock `((all-recipes . ,(lambda () recipes))
                               (get-recipe-process . ,(lambda (pid) #f))   ; no process record: a store with no holes (hole-admit)
                               (get-process-chain . ,(lambda (rid) procs))
                               (flows-for-process . ,(lambda (pid)
                                  (cons (filter (lambda (f) (or (equal? (recipe-flow-recipe-input-of f) pid)
                                                                (equal? (recipe-flow-recipe-output-of f) pid))) flows) '()))))))
           ;; the position predicate (live/expected trajectory) reads all-meta + all-commitments
           (ps  (spawn ^mock `((all-meta . ,(lambda () '())) (all-commitments . ,(lambda () '())) (all-intents . ,(lambda () '())))))
           (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs #:plan-store ps))
           ;; the real OCapN-facing service actor, holding this scope
           (svc (spawn ^planner-service (hashmap-set (hashmap) "s1" scope)))
           (svc-plan ($ svc 'plan "s1" '(("bread" "town" 0 8.0)) '())))
      (list (plan-scope->alist scope #:demand '(("bread#town@0" . 8.0)) #:backend 'native-c)
            svc-plan))))

(define result  (car both))      ; direct plan-scope->alist
(define svc-env (cadr both))     ; (ok . alist) from ^planner-service.plan
(define work (assq-ref result 'work))
(define (provider-skills p) (sort (delete-duplicates (filter-map (lambda (w) (and (equal? (assq-ref w 'provider) p) (assq-ref w 'conforms-to))) work)) string<?))

(display "\n── (playnet scope live): plan-scope over a live scope-root ──\n")
(check "demand substantially met"        (> (assq-ref result 'met) 0.9))
(check "every commitment action = work"  (every (lambda (w) (eq? (assq-ref w 'action) 'work)) work))
(check "farmer farms (skill-farm)"       (member "skill-farm" (provider-skills "farmer")) )
(check "bob works only the skills he holds (skill-bake, skill-fish), and works one"
       (let ((ps (provider-skills "bob")))
         (and (pair? ps) (every (lambda (s) (member s '("skill-bake" "skill-fish"))) ps))))
(check "ada is multi-skilled: bakes AND mills"
       (equal? (provider-skills "ada") '("skill-bake" "skill-mill")))
(check "commitments carry effort hours"
       (every (lambda (w) (> (assq-ref w 'effort) 0)) work))
(check "located at town"                 (every (lambda (w) (equal? (assq-ref w 'at-location) "town")) work))

(define intend (assq-ref result 'intend))
(define needs  (filter (lambda (i) (eq? (assq-ref i 'side) 'need))  intend))
(define offers (filter (lambda (i) (eq? (assq-ref i 'side) 'offer)) intend))
(display "\n── two-sided matching: need + offer intents, commitments satisfy both ──\n")
(check "plan emits NEED intents (receiver side, provider unbound)"
       (and (pair? needs) (every (lambda (i) (not (assq-ref i 'provider))) needs)))
(check "plan emits OFFER intents (provider side, a worker offers)"
       (and (pair? offers) (every (lambda (i) (assq-ref i 'provider)) offers)))
(check "intents are not yet finished (intended, not committed)"
       (every (lambda (i) (not (assq-ref i 'finished))) intend))
(check "every commitment satisfies BOTH a need and an offer intent"
       (let ((ids (map (lambda (i) (assq-ref i 'id)) intend)))
         (every (lambda (w) (let ((s (assq-ref w 'satisfies)))
                              (and (list? s) (= (length s) 2) (every (lambda (id) (member id ids)) s)))) work)))

(display "\n── the abstract side: embodied labour (value), located pulls, free time ──\n")
(define value  (assq-ref result 'value))
(define pulls (assq-ref result 'labour-pulls))
(define social (assq-ref result 'social))
(check "embodied labour ℓ̂: grain = 0.5h/unit (direct grow labour)"
       (< (abs (- (assoc-ref value "grain") 0.5)) 0.01))
;; The recipes (bread-commune-seed.scm): the mill takes 1.2 grain and 0.3 h to make 1 flour AND
;; 0.17 bran, so its labour is shared across both products by mass; the bake takes 0.75 flour
;; and 0.5 h for 1 bread. The value of each is the identity those recipes define.
(define flour-value (/ (+ 0.3 (* 1.2 (assoc-ref value "grain"))) (+ 1.0 0.17)))
(check "embodied labour ℓ̂: flour = (0.3 mill + 1.2 grain) shared with the bran it is milled beside"
       (< (abs (- (assoc-ref value "flour") flour-value)) 0.01))
(check "embodied labour ℓ̂: bread = 0.5 bake + 0.75 flour (Leontief)"
       (< (abs (- (assoc-ref value "bread") (+ 0.5 (* 0.75 flour-value)))) 0.01))
(check "located labour pulls λ(skill@cell) are emitted, all positive"
       (and (pair? pulls) (every (lambda (p) (> (cdr p) 0)) pulls)))
(check "social-individual accounting present (L, available, free, free-time)"
       (and (assq-ref social 'direct-labour) (assq-ref social 'available)
            (assq-ref social 'free-time)))
(check "the accounting identity (direct + transport + training) + free = available (N·T)"
       (< (abs (- (+ (assq-ref social 'direct-labour) (assq-ref social 'transport)
                     (assq-ref social 'training) (assq-ref social 'free))
                  (assq-ref social 'available))) 0.01))
(check "free time f = 1 − L/(N·T) ∈ [0,1]"
       (let ((f (assq-ref social 'free-time))) (and (>= f 0) (<= f 1))))

(display "\n── ^planner-service 'plan (the OCapN-facing deployment path) ──\n")
(check "service returns an ok envelope"  (eq? (car svc-env) 'ok))
(check "service plan also substantially met" (> (assq-ref (cdr svc-env) 'met) 0.9))
(check "service plan emits work commitments"
       (every (lambda (w) (eq? (assq-ref w 'action) 'work)) (assq-ref (cdr svc-env) 'work)))

(test-summary!)
