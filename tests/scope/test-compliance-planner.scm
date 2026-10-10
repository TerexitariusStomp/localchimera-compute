;;; test-compliance-planner.scm — the SUPPLY side meets the PLANNER.
;;;
;;; The whole chain, end to end, with NO edit to planner.scm:
;;;   recipe tag  crossing:food-vending      (legal/crossings.scm reads the tag)
;;;     → legal rule  food-vending → obtain entity "Food Establishment Permit"
;;;     → the observer-aware decorate asks: do we HOLD that permit? (compliance.scm)
;;;     → if not, the decorate prunes the vend column — a possibility-tension,
;;;       exactly as a verified `forbid` or an un-held competence already does.
;;;
;;; PART 1 exercises the real decorate closure over REAL stores + a REAL observer:
;;; the prune toggles as the permit is seeded into custody. PART 2 drives the
;;; LIVE planner and shows the fill collapse when the permit is missing and
;;; recover when it is held. Pure solver / pure data ⇒ no blake3.
;;;
;;; Run: guile -L module tests/scope/test-compliance-planner.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness) (playnet knowledge recipes store) (playnet scope spatial-things) (playnet observation observer) (playnet vf schemas) (playnet scope live)
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1) (ice-9 format))

(use-modules (playnet legal crossings))
(use-modules (playnet legal registry))
(use-modules (playnet legal registry-actor))
(use-modules (playnet legal gate)) (use-modules (playnet legal compliance))
(use-modules (playnet knowledge recipes compliance-food))

;; a held credential resource conforming to the permit spec, in the scope's custody.
(define (held-permit id spec holder)
  (make-economic-resource #:id id #:name spec #:conforms-to spec #:classified-as '("credential")
    #:onhand-quantity (make-measure 1 "cert") #:primary-accountable holder #:state "active"))

;;; ─── PART 1 : the real decorate seam toggles with custody ─────────────────
(define vat (spawn-vat))
(define part1
  (with-vat vat
    (let ((rs  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                      (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))
          (sts (spawn ^spatial-thing-store (hashmap)))
          (reg (spawn ^legal-registry (list (compliance-food-rule))))
          (obs (spawn ^observer (empty-observer-state) '())))
      (seed-compliance-food-recipe rs)
      ($ sts 'add-location (make-spatial-thing #:id "world"))
      ($ sts 'add-location (make-spatial-thing #:id "foodville" #:lat 40.0 #:long -74.0
                                               #:contained-in "world"))
      (let* ((dec  (make-legal-decorate/observer
                    #:recipe-store rs #:spatial-thing-store sts
                    #:registry reg #:observer obs #:act 'food #:as-of "2026-07-14"
                    #:subject-at (lambda (p c) "scope:foodco")))
             (prune-when-missing
              (call-with-values (lambda () (dec "rp-cf-vend" "foodville@0")) list)))
        ;; now GRANT the permit into the scope's custody, re-ask
        ($ obs 'seed-resource (held-permit "res:estab-permit" "Food Establishment Permit" "scope:foodco"))
        (let ((prune-when-held
               (call-with-values (lambda () (dec "rp-cf-vend" "foodville@0")) list)))
          (list (car prune-when-missing) (car prune-when-held)
                (caddr prune-when-missing)))))))   ; skills still surface (the handler card)

(display "\n── PART 1 · the real decorate: tag → crossing → rule → custody → prune ──\n")
(format #t "  prune when permit MISSING: ~a   ·   prune when permit HELD: ~a\n"
        (list-ref part1 0) (list-ref part1 1))
(check-pred "an un-held Food Establishment Permit PRUNES the vend column" (list-ref part1 0))
(check-pred "granting the permit into custody UN-prunes it"        (not (list-ref part1 1)))
(check-pred "the person competence still surfaces as a required skill"
            (member "Food Handler Card" (list-ref part1 2)))

;;; ─── PART 2 : the LIVE planner consumes the custody-aware decorate ────────
;;; A minimal one-cell solve: produce + a cook are present at foodville; the meal
;;; demand can be met IFF the vend column runs — which the decorate gates on
;;; holding the permit. We keep the planner's PRODUCTIVE view in light mock
;;; stores (the proven test-legal-decorate harness) and let the decorate consult
;;; a REAL observer for the credential — the credential substrate, separate from
;;; the productive stock, exactly as in the design.
(define procs (list (make-recipe-process #:id "cook" #:name "Cook")))
(define p2-flows
  (list (make-recipe-flow #:id "f-out" #:action 'produce #:resource-conforms-to "meal"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-output-of "cook"
                          #:is-primary #t)
        (make-recipe-flow #:id "f-in"  #:action 'consume #:resource-conforms-to "produce"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-input-of "cook")
        (make-recipe-flow #:id "f-wk"  #:action 'work #:resource-conforms-to "cook-skill"
                          #:effort-quantity (make-measure 0.5 %effort-unit) #:recipe-input-of "cook")))
(define p2-recipes (list (make-recipe #:id "r" #:name "Cook" #:primary-output "meal"
                                      #:recipe-processes '() #:recipe-exchanges '())))
(define p2-specs (list (make-resource-specification #:id "cook-skill" #:name "Cook"
                                                    #:resource-classified-as '()
                                                    #:default-unit-of-effort %effort-unit)))
(define win (all-week-window "00:00" "23:59"))
(define p2-resources
  (list (er "pr-foodville" "produce" "a-foodville" #:place "foodville" #:qty 100.0)
        (er "ck-foodville" "cook-skill" "w-foodville" #:place "foodville" #:qty 1.0)))
(define p2-agents (list (make-agent #:id "w-foodville" #:type 'person #:primary-location "foodville"
                                    #:classified-as '() #:availability-window win)))
(define p2-spatials (list (make-spatial-thing #:id "foodville" #:lat 40.0 #:long -74.0)))

;; the decorate: prune the vend cell iff the scope does NOT hold the permit in
;; the given observer. (One cell, so fill is 0 or 1 — a clean witness.)
(define (permit-decorate obs)
  (lambda (proc cell)
    (values (not (eq? 'satisfied
                      (holding-status obs "scope:foodco" "Food Establishment Permit" "2026-07-14")))
            0.0 '())))

(define (solve-with-permit? held?)
  (define v (spawn-vat))
  (with-vat v
    (let* ((cobs (spawn ^observer (empty-observer-state) '())))
      (when held?
        ($ cobs 'seed-resource (held-permit "res:estab-permit" "Food Establishment Permit" "scope:foodco")))
      (let* ((obs (spawn ^mock `((all-resources . ,(lambda () p2-resources))
                                 (skill-hours-of . ,(lambda (a) '())) (record-event . ,(lambda (e) "ok")))))
             (as  (spawn ^mock `((all-agents . ,(lambda () p2-agents)))))
             (sts (spawn ^mock `((all-locations . ,(lambda () p2-spatials)))))
             (rs  (spawn ^mock `((all-recipes . ,(lambda () p2-recipes)) (all-resource-specs . ,(lambda () p2-specs))
                                 (get-process-chain . ,(lambda (r) procs))
                                 (flows-for-process . ,(lambda (pid)
                                   (cons (filter (lambda (f) (or (equal? (recipe-flow-recipe-input-of f) pid)
                                                                 (equal? (recipe-flow-recipe-output-of f) pid))) p2-flows) '()))))))
             (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs)))
        (call-with-values
          (lambda () (plan-scope scope #:demand (list (cons "meal#foodville@0" 10.0))
                                 #:backend 'native-c #:legal-decorate (permit-decorate cobs)))
          (lambda (i c m fill x n r) fill))))))

(display "\n── PART 2 · the live planner: no permit ⇒ the demand cannot be met ──\n")
(define fill-missing (solve-with-permit? #f))
(define fill-held    (solve-with-permit? #t))
(format #t "  fill  permit MISSING: ~,3f   ·   permit HELD: ~,3f\n" fill-missing fill-held)
(check-pred "with NO permit the vend column is pruned ⇒ demand unmet" (< fill-missing 0.05))
(check-pred "holding the permit lets the plan meet the demand"        (> fill-held 0.95))

(display "\n")
(test-summary!)
