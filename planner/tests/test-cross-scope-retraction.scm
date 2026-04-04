;;; test-cross-scope-retraction.scm — Tests for cross-scope priority-aware retraction
;;;
;;; Scenario: 3 sibling scopes (kitchen, workshop, garden) share a common spec (wood).
;;; Kitchen has a low-priority demand for wood (luxury).
;;; Workshop has a high-priority deficit for wood (metabolic).
;;; Garden has no wood.
;;; The federation should retract kitchen's low-priority satisfied demand
;;; to free capacity for workshop's high-priority deficit.

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1)
             (srfi srfi-11))

(define pass-count 0)
(define fail-count 0)
(define (check label pred)
  (if pred
      (begin (set! pass-count (+ pass-count 1))
             (format #t "  PASS  ~a\n" label))
      (begin (set! fail-count (+ fail-count 1))
             (format #t "  FAIL  ~a\n" label))))
(define (approx= a b . r) (< (abs (- a b)) (if (pair? r) (car r) 0.01)))


;; ═══════════════════════════════════════════════════════════════════════
;; Test 1: retract-across-scopes in plan-federation
;; ═══════════════════════════════════════════════════════════════════════

(display "\n=== Test: Cross-scope retraction via plan-federation ===\n")

;; We simulate the federation result structure directly to test
;; retract-across-scopes in isolation.

(let* (;; Kitchen: satisfied wood demand (low priority - consumption/green = 63)
       (kitchen-result
         `((plan-id . "plan-kitchen")
           (processes . ((bake-something)))
           (purchase-intents . ())
           (deficit-signals . ())
           (surplus-signals . ())
           (retraction-candidates
             . (((scope-id . "kitchen")
                 (plan-id . "plan-kitchen-wood")
                 (spec-id . "spec-wood")
                 (qty . 10)
                 (slot . ((spec-id . "spec-wood") (remaining-quantity . 10))))))
           (netter-state . ,(empty-netter-state))))

       ;; Workshop: has a deficit for wood (high priority - metabolic/red = 50)
       (workshop-result
         `((plan-id . "plan-workshop")
           (processes . ())
           (purchase-intents . ())
           (deficit-signals . (((kind . deficit) (spec-id . "spec-wood")
                                (qty . 8) (source . metabolic-debt))))
           (surplus-signals . ())
           (retraction-candidates . ())
           (netter-state . ,(empty-netter-state))))

       ;; Garden: no wood involvement
       (garden-result
         `((plan-id . "plan-garden")
           (processes . ((grow-tomato)))
           (purchase-intents . ())
           (deficit-signals . ())
           (surplus-signals . ())
           (retraction-candidates . ())
           (netter-state . ,(empty-netter-state))))

       ;; Build by-scope hashmap
       (by-scope (hashmap-set
                   (hashmap-set
                     (hashmap-set (hashmap) "kitchen" kitchen-result)
                     "workshop" workshop-result)
                   "garden" garden-result))

       ;; Priority function: kitchen wood = 63 (consumption/green), workshop wood = 50 (metabolic/red)
       (priority-fn (lambda (scope-id spec-id)
                      (cond
                        ((equal? scope-id "kitchen") 63)   ;; low priority
                        ((equal? scope-id "workshop") 50)  ;; high priority
                        (else 53))))                        ;; default

       ;; No parent-child relationships
       (parent-of (hashmap))

       ;; Remaining deficits after lateral matching (no surplus to match)
       (remaining-defs '(((scope-id . "workshop") (spec-id . "spec-wood") (qty . 8)))))

  ;; Run cross-scope retraction
  (let-values (((new-by-scope retractions final-defs)
                (retract-across-scopes by-scope remaining-defs priority-fn parent-of)))

    (check "retraction occurred" (pair? retractions))
    (check "one retraction" (= 1 (length retractions)))

    (when (pair? retractions)
      (let ((r (car retractions)))
        (check "retracted from kitchen" (equal? "kitchen" (assq-ref r 'from-scope)))
        (check "retracted to workshop" (equal? "workshop" (assq-ref r 'to-scope)))
        (check "retracted spec-wood" (equal? "spec-wood" (assq-ref r 'spec-id)))
        (check "retracted qty 8" (= 8 (assq-ref r 'quantity)))
        (check "priority cost 63" (= 63 (assq-ref r 'priority-cost)))))

    (check "deficit resolved" (null? final-defs))

    ;; Verify kitchen's retraction candidates are updated (10 - 8 = 2 remaining)
    (let* ((new-kitchen (hashmap-ref new-by-scope "kitchen" '()))
           (new-cands (or (assq-ref new-kitchen 'retraction-candidates) '())))
      (check "kitchen candidate reduced to 2"
             (and (pair? new-cands)
                  (= 2 (assq-ref (car new-cands) 'qty)))))))


;; ═══════════════════════════════════════════════════════════════════════
;; Test 2: Priority ordering — never retract high-priority
;; ═══════════════════════════════════════════════════════════════════════

(display "\n=== Test: Priority ordering — retract lowest first ===\n")

(let* (;; Two scopes with satisfied demands for the same spec
       ;; Scope A: high priority (ecological = 10), should NOT be retracted
       ;; Scope B: low priority (consumption = 63), SHOULD be retracted
       (scope-a-result
         `((plan-id . "plan-a")
           (processes . ((protect-wetland)))
           (deficit-signals . ())
           (surplus-signals . ())
           (retraction-candidates
             . (((scope-id . "scope-a")
                 (plan-id . "plan-a-water")
                 (spec-id . "spec-water")
                 (qty . 20)
                 (slot . ((spec-id . "spec-water") (remaining-quantity . 20))))))
           (netter-state . ,(empty-netter-state))))

       (scope-b-result
         `((plan-id . "plan-b")
           (processes . ((fill-pool)))
           (deficit-signals . ())
           (surplus-signals . ())
           (retraction-candidates
             . (((scope-id . "scope-b")
                 (plan-id . "plan-b-water")
                 (spec-id . "spec-water")
                 (qty . 15)
                 (slot . ((spec-id . "spec-water") (remaining-quantity . 15))))))
           (netter-state . ,(empty-netter-state))))

       ;; Scope C: has a deficit for water
       (scope-c-result
         `((plan-id . "plan-c")
           (processes . ())
           (deficit-signals . (((kind . deficit) (spec-id . "spec-water")
                                (qty . 10) (source . metabolic-debt))))
           (surplus-signals . ())
           (retraction-candidates . ())
           (netter-state . ,(empty-netter-state))))

       (by-scope (hashmap-set
                   (hashmap-set
                     (hashmap-set (hashmap) "scope-a" scope-a-result)
                     "scope-b" scope-b-result)
                   "scope-c" scope-c-result))

       (priority-fn (lambda (scope-id spec-id)
                      (cond
                        ((equal? scope-id "scope-a") 10)   ;; ecological — never retract
                        ((equal? scope-id "scope-b") 63)   ;; consumption — retract first
                        ((equal? scope-id "scope-c") 50)   ;; metabolic deficit
                        (else 53))))

       (parent-of (hashmap))
       (remaining-defs '(((scope-id . "scope-c") (spec-id . "spec-water") (qty . 10)))))

  (let-values (((new-by-scope retractions final-defs)
                (retract-across-scopes by-scope remaining-defs priority-fn parent-of)))

    (check "retracted from scope-b not scope-a"
           (and (pair? retractions)
                (equal? "scope-b" (assq-ref (car retractions) 'from-scope))))
    (check "deficit resolved" (null? final-defs))
    (check "scope-a untouched"
           (pair? (or (assq-ref (hashmap-ref new-by-scope "scope-a" '())
                                'retraction-candidates) '())))))


;; ═══════════════════════════════════════════════════════════════════════
;; Test 3: Lazy termination — don't retract more than needed
;; ═══════════════════════════════════════════════════════════════════════

(display "\n=== Test: Minimal retraction — only what's needed ===\n")

(let* (;; Two low-priority scopes with large satisfied demands
       (scope-x-result
         `((plan-id . "plan-x")
           (processes . ((luxury-1)))
           (deficit-signals . ())
           (surplus-signals . ())
           (retraction-candidates
             . (((scope-id . "scope-x")
                 (plan-id . "plan-x-steel")
                 (spec-id . "spec-steel")
                 (qty . 100)
                 (slot . ((spec-id . "spec-steel") (remaining-quantity . 100))))))
           (netter-state . ,(empty-netter-state))))

       (scope-y-result
         `((plan-id . "plan-y")
           (processes . ((luxury-2)))
           (deficit-signals . ())
           (surplus-signals . ())
           (retraction-candidates
             . (((scope-id . "scope-y")
                 (plan-id . "plan-y-steel")
                 (spec-id . "spec-steel")
                 (qty . 100)
                 (slot . ((spec-id . "spec-steel") (remaining-quantity . 100))))))
           (netter-state . ,(empty-netter-state))))

       ;; Small deficit
       (scope-z-result
         `((plan-id . "plan-z")
           (processes . ())
           (deficit-signals . (((kind . deficit) (spec-id . "spec-steel")
                                (qty . 5) (source . metabolic-debt))))
           (surplus-signals . ())
           (retraction-candidates . ())
           (netter-state . ,(empty-netter-state))))

       (by-scope (hashmap-set
                   (hashmap-set
                     (hashmap-set (hashmap) "scope-x" scope-x-result)
                     "scope-y" scope-y-result)
                   "scope-z" scope-z-result))

       (priority-fn (lambda (scope-id spec-id)
                      (cond
                        ((equal? scope-id "scope-x") 62)   ;; slightly higher priority
                        ((equal? scope-id "scope-y") 63)   ;; lowest priority — retract first
                        ((equal? scope-id "scope-z") 50)
                        (else 53))))

       (parent-of (hashmap))
       (remaining-defs '(((scope-id . "scope-z") (spec-id . "spec-steel") (qty . 5)))))

  (let-values (((new-by-scope retractions final-defs)
                (retract-across-scopes by-scope remaining-defs priority-fn parent-of)))

    (check "only one retraction needed" (= 1 (length retractions)))
    (check "retracted from scope-y (lowest priority)"
           (equal? "scope-y" (assq-ref (car retractions) 'from-scope)))
    (check "retracted only 5 (not 100)"
           (= 5 (assq-ref (car retractions) 'quantity)))
    (check "deficit resolved" (null? final-defs))

    ;; scope-y should still have remaining retraction capacity (100 - 5 = 95)
    (let* ((new-y (hashmap-ref new-by-scope "scope-y" '()))
           (new-cands (or (assq-ref new-y 'retraction-candidates) '())))
      (check "scope-y has remaining candidate"
             (and (pair? new-cands)
                  (= 95 (assq-ref (car new-cands) 'qty)))))))


;; ═══════════════════════════════════════════════════════════════════════
;; Test 4: plan-federation integration with priority-fn
;; ═══════════════════════════════════════════════════════════════════════

(display "\n=== Test: plan-federation with priority-fn ===\n")

(define store2 (make-memory-store))
(define scope-env
  (make-persistence-env
    `((((vf) ^scope-root) ,^scope-root)
      (((vf planning) ^store-registry) ,^store-registry))
    #:extends (list recipe-store-env agent-store-env observer-env
                    plan-store-env buffer-zone-store-env
                    account-store-env capacity-buffer-store-env
                    spatial-thing-store-env snapshot-store-env
                    alert-store-env store-registry-env
                    process-registry-env
                    live-registry-env live-resource-env)))

(define-values (vat3 alpha beta)
  (spawn-persistent-vat
    scope-env
    (lambda ()
      (values (spawn-scope "Alpha")
              (spawn-scope "Beta")))
    store2))

;; Seed: both scopes share spec-wood
(define wood-spec (make-resource-specification "spec-wood" "Wood" #f #f #f "kg" #f #f #f #f #f))

(with-vat vat3
  ;; Alpha: has 50 wood, demands 40 (low priority)
  (let ((rs ($ alpha 'recipe-store))
        (ps ($ alpha 'plan-store))
        (obs ($ alpha 'observer)))
    ($ rs 'add-resource-spec wood-spec)
    ($ obs 'seed-resource
       (make-economic-resource "r-alpha-wood" "Alpha Wood" #f #f #f "spec-wood" #f
         (make-measure 50 "kg") (make-measure 50 "kg")
         "loc-alpha" #f "agent-alpha" #f #f #f #f #f #f #f #f))
    ($ ps 'add-intent
       (make-intent "i-alpha-wood" 'consume "Alpha wants wood" #f #f #f #f #f
                    "spec-wood" #f
                    (make-measure 40 "kg") #f #f #f
                    #f "agent-alpha"
                    #f #f #f "2026-04-01T00:00:00Z"
                    #f #f #f #f #f #f #f #f)))

  ;; Beta: has 0 wood, demands 10 (high priority — needs it metabolically)
  (let ((rs ($ beta 'recipe-store))
        (ps ($ beta 'plan-store))
        (obs ($ beta 'observer)))
    ($ rs 'add-resource-spec wood-spec)
    ;; No inventory — Beta has no wood
    ($ ps 'add-intent
       (make-intent "i-beta-wood" 'consume "Beta needs wood urgently" #f #f #f #f #f
                    "spec-wood" #f
                    (make-measure 10 "kg") #f #f #f
                    #f "agent-beta"
                    #f #f #f "2026-04-01T00:00:00Z"
                    #f #f #f #f #f #f #f #f))))

(with-vat vat3
  (let* ((priority-fn (lambda (scope-id spec-id)
                        (cond
                          ((equal? scope-id "alpha") 63)  ;; luxury
                          ((equal? scope-id "beta") 10)   ;; ecological/critical
                          (else 53))))
         (parent-of (hashmap))
         (result (plan-federation
                   '("alpha" "beta")
                   '((from . 1711584000) (to . 1712188800))
                   #f #f
                   (lambda (scope-id child-results)
                     (let* ((scope-root (if (equal? scope-id "alpha") alpha beta))
                            (rs ($ scope-root 'recipe-store))
                            (ps ($ scope-root 'plan-store))
                            (obs ($ scope-root 'observer)))
                       (plan-for-unit
                         (list scope-id) '((from . 1711584000) (to . 1712188800))
                         rs ps obs
                         #:scope-id scope-id
                         #:plan-name (string-append scope-id " plan"))))
                   #:parent-of parent-of
                   #:priority-fn priority-fn)))

    (let ((retractions (or (assq-ref result 'retractions) '()))
          (remaining-defs (or (assq-ref result 'remaining-deficits) '())))
      (format #t "  retractions: ~a\n" (length retractions))
      (format #t "  remaining deficits: ~a\n" (length remaining-defs))
      (check "result has retractions field" (list? (assq-ref result 'retractions)))
      (check "result has remaining-deficits field" (list? (assq-ref result 'remaining-deficits))))))


;; ═══════════════════════════════════════════════════════════════════════
;; Test 5: Relational federation retraction stream
;; ═══════════════════════════════════════════════════════════════════════

(display "\n=== Test: Relational federation retraction candidates ===\n")

;; Test extract-retraction-candidates from a relational plan
(let* ((plan `(((spec-a) (satisfied "spec-wood" 10 (("inv:1" 10))))
               ((spec-b) (satisfied "spec-flour" 5 (("inv:2" 5))))
               ((spec-c) (unmet "spec-steel" 3))))
       (cands (extract-retraction-candidates plan "test-scope")))
  (check "extracted 2 candidates (satisfied demands)"
         (= 2 (length cands)))
  (check "first candidate is spec-wood"
         (equal? "spec-wood" (assq-ref (car cands) 'spec-id)))
  (check "second candidate is spec-flour"
         (equal? "spec-flour" (assq-ref (cadr cands) 'spec-id)))
  (check "candidates have scope-id"
         (equal? "test-scope" (assq-ref (car cands) 'scope-id))))


;; ═══════════════════════════════════════════════════════════════════════
;; Test 6: demand-priority module
;; ═══════════════════════════════════════════════════════════════════════

(display "\n=== Test: Demand priority module ===\n")

(let ((pf (make-priority-fn)))
  (check "default priority is 53" (= 53 (pf "any-scope" "any-spec"))))

(let ((pf (make-priority-fn
            #:governance-fn (lambda (scope-id spec-id)
                              (if (equal? spec-id "spec-critical") 10 #f)))))
  (check "governance override for critical spec" (= 10 (pf "any" "spec-critical")))
  (check "governance falls back to default for other" (= 53 (pf "any" "spec-normal"))))


;; ═══════════════════════════════════════════════════════════════════════
;; Summary
;; ═══════════════════════════════════════════════════════════════════════

(format #t "\n~a/~a cross-scope retraction checks passed" pass-count (+ pass-count fail-count))
(if (> fail-count 0)
    (begin (format #t ", ~a failed.\n" fail-count) (exit 1))
    (display ".\n"))
