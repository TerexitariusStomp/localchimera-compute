;;; test-planner-service-socialized.scm — socialization live through the PRODUCTION
;;; plan API (^planner-service), via the injected plan-fn seam.
;;;
;;; The production gateway routes plans to ^planner-service's `plan` method, which
;;; until now called plan-scope->alist plainly — no socialization. This test spawns
;;; the service with `#:plan-fn (socialized-plan-fn store)` (the one line a
;;; governance spawn adds, reusing plan-commune-scope) and confirms that a bike
;;; Alice socialized into her commune is scheduled — bounded by the grant — when the
;;; plan comes through the SERVICE, with no governance dependency inside the service.
;;; Intra-commune: the bike lives in the commune's own observer, so the default
;;; (no-federation) resolver suffices; the plug derives the commune-aid from the
;;; scope-root's own name.
;;;
;;; Run:  guile -L module -L tests tests/planner/test-planner-service-socialized.scm

(setenv "PLAYNET_DATA_DIR"
        (string-append (or (getenv "TMPDIR") "/tmp") "/pn-svc-soc-test"))

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test harness)
             (playnet planner vf schemas)
             (playnet planner doors service)          ; ^planner-service
             (playnet governance socialization) (playnet keri acdc-store)               ; socialize-private-resource, socialized-plan-fn
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

(define OWNER   "EAlice")
(define COMMUNE "ECommune")
(define FUTURE  "2099-12-31T00:00:00Z")

(define procs (list (make-recipe-process #:id "deliver" #:name "Deliver")))
(define flows
  (list (make-recipe-flow #:id "d-use" #:action 'use #:resource-conforms-to "bike" #:resource-quantity (make-measure 1.0 %count-unit) #:effort-quantity (make-measure 1.0 %effort-unit)
                          #:recipe-input-of "deliver")
        (make-recipe-flow #:id "d-out" #:action 'produce #:resource-conforms-to "delivered" #:resource-quantity (make-measure 1.0 "kg")
                          #:recipe-output-of "deliver" #:is-primary #t)))
(define recipes (list (make-recipe #:id "deliver-recipe" #:name "Deliver"
                                   #:primary-output "delivered" #:recipe-processes '()
                                   #:recipe-exchanges '())))

;; Alice's bike lives in HER commune's books (intra-commune socialization).
(define (bike)
  (make-economic-resource #:id "res:bike" #:conforms-to "bike" #:classified-as '()
                          #:onhand-quantity (make-measure 1 %count-unit) #:current-location "town" #:primary-accountable OWNER))
(define spatials (list (make-spatial-thing #:id "town" #:lat 40.0 #:long -74.0)))
(define vat (spawn-vat #:name "planner-service-socialized"))

;; one plan through the SERVICE for a grant of QTY, demand 5 parcels. Returns met.
(define (run qty)
  (with-vat vat
    (let* ((store (spawn-acdc-store))
           (_ (when qty (socialize-private-resource store OWNER COMMUNE "bike" qty #:until FUTURE)))
                      ;; the stores state what the fold nodes register and read at wiring
           ;; (service.scm scope-node-specs): listeners, the hours reads, the cells
           (obs (spawn ^mock `((all-resources . ,(lambda () (list (bike))))
                               (record-event  . ,(lambda (e) "ok"))
                               (skills-of     . ,(lambda (aid) '()))
                               (add-event-listener . ,(lambda (f) #t))
                               (hours-by      . ,(lambda (key-of . _) '()))
                               (hours-on      . ,(lambda (part . _) 0)))))
           (as  (spawn ^mock `((all-agents    . ,(lambda () '()))
                               (set-on-agent  . ,(lambda (f) #t)))))
           (acct (spawn ^mock `((credit-cells . ,(lambda () '())) (add-change-listener . ,(lambda (f) #t)))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs  (spawn ^mock `((all-recipes       . ,(lambda () recipes))
                               (get-process-chain . ,(lambda (rid) procs))
                               (flows-for-process . ,(lambda (pid)
                                 (cons (filter (lambda (f) (or (equal? (recipe-flow-recipe-input-of f) pid)
                                                               (equal? (recipe-flow-recipe-output-of f) pid)))
                                               flows) '()))))))
           (ps  (spawn ^mock `((all-meta . ,(lambda () '())) (all-commitments . ,(lambda () '())) (all-intents . ,(lambda () '()))
                               (add-intent-listener . ,(lambda (f) #t)) (set-fresh-check . ,(lambda (f) #t)))))
           ;; the scope-root: its `name` is the commune AID the plug keys grants to.
           (root (spawn ^mock `((name                . ,(lambda () COMMUNE))
                                (observer            . ,(lambda () obs))
                                (agent-store         . ,(lambda () as))
                                (spatial-thing-store . ,(lambda () sts))
                                (recipe-store        . ,(lambda () rs))
                                (plan-store          . ,(lambda () ps))
                                (account-store       . ,(lambda () acct)))))
           ;; the scope-id (add-scope! key) IS the commune AID the grants are keyed to.
           (scopes (hashmap-set (hashmap) COMMUNE root))
           ;; THE ONE WIRING LINE: the service, socialization-aware, no governance dep inside it.
           (svc (spawn ^planner-service scopes plain-plan-fn #f (socialized-readers store)))
           (res ($ svc 'plan COMMUNE (list (list "delivered" "town" 0 5.0)))))
      (and (eq? (car res) 'ok) (assq-ref (cdr res) 'met)))))

(define lent-2 (run 2))
(define lent-4 (run 4))

(display "\n── socialization through the production ^planner-service plan API ──\n")
(format #t "  lent 2 ⇒ demand met ~,2f   (≈ 2/5)~%" lent-2)
(format #t "  lent 4 ⇒ demand met ~,2f   (≈ 4/5)~%" lent-4)

(check "the service applies socialization via the plug: lent 2 ⇒ ~2/5"
       (and lent-2 (> lent-2 0.35) (< lent-2 0.45)))
(check "lend more ⇒ more communal use through the service: lent 4 ⇒ ~4/5"
       (and lent-4 (> lent-4 0.75) (< lent-4 0.85)))
(check "the grant sizes it, derived per-solve inside the service call"
       (> lent-4 lent-2))

(test-summary!)
