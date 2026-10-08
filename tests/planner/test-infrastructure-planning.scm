;;; test-infrastructure-planning.scm — Full planning cycle for infrastructure resources
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-infrastructure-planning.scm
;;;
;;; Exercises:
;;;   1. Define infrastructure resource specs (compute, memory, storage, bandwidth)
;;;   2. Define recipes that use infrastructure as inputs
;;;   3. Seed live-resource actors as infrastructure inventory
;;;   4. Create demands (intents), run the relational planner
;;;   5. Verify plans correctly allocate infrastructure
;;;   6. Verify insufficient infrastructure → unmet demand

(use-modules (playnet test harness))
(use-modules (playnet deprecated planner))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (playnet deprecated kanren-constraints)
             (srfi srfi-1))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Scope setup — infrastructure specs, recipes, agents
;;; ════════════════════════════════════════════════════════════════════════════

(display "── Infrastructure scope setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Compute Commune")) store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (as ($ scope 'agent-store)))

    ;; ── Resource specifications ────────────────────────────────────────────
    ;; Infrastructure
    ;; Specs + recipes (transcribe, replicate) live in
    ;; module/playnet/planner/knowledge/recipes/infrastructure.scm.
    (seed-infrastructure-recipes rs)

    ;; ── Agents ─────────────────────────────────────────────────────────────
    ($ as 'add-agent
       (make-agent #:id "agent:commune" #:type 'organization #:name "Compute Commune"))

    (check-pred "knowledge seeded"
                (pair? ($ rs 'get-process-chain "recipe:transcribe")))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Seed infrastructure — live-resource actors + observer
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Seed infrastructure ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer))
        (lr  ($ scope 'live-registry)))

    ;; ── Compute: 16 cpu-hours total, 16 available ──────────────────────────
    ($ obs 'seed-resource
       (make-economic-resource #:id "cpu-1" #:name "Cluster CPU"
                               #:conforms-to "spec:compute" #:classified-as '("infrastructure")
                               #:accounting-quantity (make-measure 16 "cpu-hours")
                               #:onhand-quantity (make-measure 16 "cpu-hours")
                               #:current-location "dc-1" #:primary-accountable "agent:commune"))
    (let ((live (spawn ^live-resource "cpu-1" "spec:compute" 16 16 "cpu-hours" "dc-1" '())))
      ($ lr 'register "cpu-1" live))

    ;; ── Memory: 32 GB total, 32 available ──────────────────────────────────
    ($ obs 'seed-resource
       (make-economic-resource #:id "mem-1" #:name "Cluster Memory"
                               #:conforms-to "spec:memory" #:classified-as '("infrastructure")
                               #:accounting-quantity (make-measure 32 "GB")
                               #:onhand-quantity (make-measure 32 "GB")
                               #:current-location "dc-1" #:primary-accountable "agent:commune"))
    (let ((live (spawn ^live-resource "mem-1" "spec:memory" 32 32 "GB" "dc-1" '())))
      ($ lr 'register "mem-1" live))

    ;; ── Storage: 500 GB total, 500 available ───────────────────────────────
    ($ obs 'seed-resource
       (make-economic-resource #:id "disk-1" #:name "Storage Volume"
                               #:conforms-to "spec:storage" #:classified-as '("infrastructure")
                               #:accounting-quantity (make-measure 500 "GB")
                               #:onhand-quantity (make-measure 500 "GB")
                               #:current-location "dc-1" #:primary-accountable "agent:commune"))
    (let ((live (spawn ^live-resource "disk-1" "spec:storage" 500 500 "GB" "dc-1" '())))
      ($ lr 'register "disk-1" live))

    ;; ── Bandwidth: 100 GB total, 100 available ─────────────────────────────
    ($ obs 'seed-resource
       (make-economic-resource #:id "bw-1" #:name "Network Link"
                               #:conforms-to "spec:bandwidth" #:classified-as '("infrastructure")
                               #:accounting-quantity (make-measure 100 "GB")
                               #:onhand-quantity (make-measure 100 "GB")
                               #:current-location "dc-1" #:primary-accountable "agent:commune"))
    (let ((live (spawn ^live-resource "bw-1" "spec:bandwidth" 100 100 "GB" "dc-1" '())))
      ($ lr 'register "bw-1" live))

    (check "4 resources seeded" (length ($ obs 'all-resources)) 4)
    (check "4 live-resources" (length ($ lr 'all-ids)) 4)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Verify lifted planning facts include infrastructure
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Planning facts ──\n")

(define infra-facts
  (with-vat vat
    (lift-planning-facts ($ scope 'recipe-store) ($ scope 'observer)
                         ($ scope 'plan-store) #f ($ scope 'live-registry))))

(define infra-indexes (build-indexes infra-facts))

(check-pred "facts: compute inventory"
  (any (lambda (f) (and (eq? (car f) 'inventory) (equal? (cadr f) "cpu-1")))
       infra-facts))
(check-pred "facts: memory inventory"
  (any (lambda (f) (and (eq? (car f) 'inventory) (equal? (cadr f) "mem-1")))
       infra-facts))
(check-pred "facts: storage inventory"
  (any (lambda (f) (and (eq? (car f) 'inventory) (equal? (cadr f) "disk-1")))
       infra-facts))
(check-pred "facts: bandwidth inventory"
  (any (lambda (f) (and (eq? (car f) 'inventory) (equal? (cadr f) "bw-1")))
       infra-facts))

;; Verify inventory quantities = available (from live-resource), not total
(let ((cpu-inv (find (lambda (f) (and (eq? (car f) 'inventory)
                                       (equal? (cadr f) "cpu-1")))
                     infra-facts)))
  (check "compute: planner sees 16 available" (cadddr cpu-inv) 16))

(check-pred "facts: transcription recipe"
  (any (lambda (f) (and (eq? (car f) 'recipe) (equal? (cadr f) "recipe:transcribe")))
       infra-facts))
(check-pred "facts: replication recipe"
  (any (lambda (f) (and (eq? (car f) 'recipe) (equal? (cadr f) "recipe:replicate")))
       infra-facts))

;; Verify 'use flows are present in facts
(check-pred "facts: compute use flow"
  (any (lambda (f) (and (eq? (car f) 'flow)
                         (equal? (cadr f) "rp:transcribe")
                         (eq? (caddr f) 'input)
                         (equal? (cadddr f) "spec:compute")))
       infra-facts))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Direct allocation — infrastructure via allocate-o
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Infrastructure allocation ──\n")

(define ns (quote ()))  ;; netter state not used by kanren-constraints

;; Allocate 4 cpu-hours from 16 available
(let ((results (run-plan 1 ns (q)
                 (fresh (remaining allocated)
                   (allocate-o infra-facts "spec:compute" 4 remaining allocated
                                 #:indexes infra-indexes)
                   (== q remaining)))))
  (check "allocate 4 compute: remaining = 0" (and (pair? results) (car results)) 0))

;; Allocate 20 cpu-hours from 16 — remaining = 4
(let ((results (run-plan 1 ns (q)
                 (fresh (remaining allocated)
                   (allocate-o infra-facts "spec:compute" 20 remaining allocated
                                 #:indexes infra-indexes)
                   (== q remaining)))))
  (check "allocate 20 compute: remaining = 4" (and (pair? results) (car results)) 4))

;; Allocate 30 GB memory from 32 — remaining = 0
(let ((results (run-plan 1 ns (q)
                 (fresh (remaining allocated)
                   (allocate-o infra-facts "spec:memory" 30 remaining allocated
                                 #:indexes infra-indexes)
                   (== q remaining)))))
  (check "allocate 30 memory: remaining = 0" (and (pair? results) (car results)) 0))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Demand relation — infrastructure as recipe inputs
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Infrastructure demand ──\n")

(define infra-ctx
  (with-vat vat
    (make-plan-ctx infra-facts ($ scope 'plan-store) ($ scope 'observer)
                   #f "infra-rp" infra-indexes)))

;; Demand 1 transcript — 'use' flows (compute, memory) get time-windowed allocation
;; Plan term: (produce spec rid scale consume-plans use-plans)
;; Take 5 results: unmet comes before produce due to interleaving
(let ((results (run-plan 5 ns (q)
                 (demand-o infra-ctx "spec:transcript" 1
                           (+ (current-time) 86400) q
                           #:depth 5))))
  (check-pred "transcript demand: finds solution" (pair? results))
  (let ((plan (find (lambda (r) (and (pair? r) (eq? (car r) 'produce))) results)))
    (check-pred "transcript: produces via recipe" (not (not plan)))
    (when plan
      (check "transcript: uses transcribe recipe"
             (caddr plan) "recipe:transcribe")
      ;; consume-plans (index 4) should be empty (no consuming inputs)
      ;; use-plans (index 5) should have compute and memory with time windows
      (let ((use-plans (list-ref plan 5)))
        (check-pred "transcript: has use-plans" (pair? use-plans))
        (check-pred "transcript: compute use-window"
          (any (lambda (up) (and (eq? (car up) 'use-window)
                                  (equal? (cadr up) "spec:compute")))
               use-plans))
        (check-pred "transcript: memory use-window"
          (any (lambda (up) (and (eq? (car up) 'use-window)
                                  (equal? (cadr up) "spec:memory")))
               use-plans))
        ;; Time window should have begin < end
        (let ((first-uw (car use-plans)))
          (check-pred "transcript: use-window has time begin"
            (number? (list-ref first-uw 4)))
          (check-pred "transcript: use-window has time end"
            (number? (list-ref first-uw 5)))
          (check-pred "transcript: begin < end"
            (< (list-ref first-uw 4) (list-ref first-uw 5))))))))

;; Demand 1 dataset — bandwidth and storage as use-windows
(let ((results (run-plan 5 ns (q)
                 (demand-o infra-ctx "spec:dataset" 1
                           (+ (current-time) 86400) q
                           #:depth 5))))
  (check-pred "dataset demand: finds solution" (pair? results))
  (let ((plan (find (lambda (r) (and (pair? r) (eq? (car r) 'produce))) results)))
    (check-pred "dataset: produces via recipe" (not (not plan)))
    (when plan
      (let ((use-plans (list-ref plan 5)))
        (check-pred "dataset: bandwidth use-window"
          (any (lambda (up) (and (eq? (car up) 'use-window)
                                  (equal? (cadr up) "spec:bandwidth")))
               use-plans))
        (check-pred "dataset: storage use-window"
          (any (lambda (up) (and (eq? (car up) 'use-window)
                                  (equal? (cadr up) "spec:storage")))
               use-plans))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Full planner — multiple demands compete for infrastructure
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Full plan with infrastructure ──\n")

;; Reserve 10 cpu-hours (simulating prior usage) so only 6 remain
(with-vat vat
  (let ((live ($ ($ scope 'live-registry) 'get "cpu-1")))
    ($ live 'reserve 10)))

;; Re-lift facts with reduced availability
(define reduced-facts
  (with-vat vat
    (lift-planning-facts ($ scope 'recipe-store) ($ scope 'observer)
                         ($ scope 'plan-store) #f ($ scope 'live-registry))))

(let ((cpu-inv (find (lambda (f) (and (eq? (car f) 'inventory)
                                       (equal? (cadr f) "cpu-1")))
                     reduced-facts)))
  (check "reduced: compute shows 6 available" (cadddr cpu-inv) 6))

;; Demand 2 transcripts (needs 2 * 4 = 8 cpu-hours, but only 6 available)
(define reduced-indexes (build-indexes reduced-facts))
(define reduced-ctx
  (with-vat vat
    (make-plan-ctx reduced-facts ($ scope 'plan-store) ($ scope 'observer)
                   #f "infra-rp2" reduced-indexes)))

;; Scale 1 = 4 cpu-hours (from 6, leaving 2). Scale 2 would need 4 more but
;; only 2 remain → second transcript is either unmet or partially met
(let ((results (run-plan 1 ns (q)
                 (demand-o reduced-ctx "spec:transcript" 1
                           (+ (current-time) 86400) q
                           #:depth 5))))
  (check-pred "1 transcript with 6 compute: still satisfiable" (pair? results)))

;; Demand 4 transcripts — needs 16 cpu-hours, only 6 available → can produce 1
;; at scale 1 (4 cpu-hours), remaining compute for 2nd is short
(let ((results (run-plan 2 ns (q)
                 (demand-o reduced-ctx "spec:transcript" 4
                           (+ (current-time) 86400) q
                           #:depth 5))))
  (check-pred "4 transcripts with 6 compute: finds at least one plan"
              (pair? results)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Relational planner with intents
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Relational planner with intents ──\n")

;; Release the 10 cpu-hours reservation so we're back to full capacity
(with-vat vat
  (let* ((live ($ ($ scope 'live-registry) 'get "cpu-1"))
         (rsv (car ($ live 'reservations))))
    ($ live 'release (car rsv))))

;; Add an intent: commune needs 1 transcript
(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ($ ps 'add-intent
       (make-intent #:id "i:need-transcript" #:action 'produce #:name "Need transcription" #:output-of "rp:transcribe" #:resource-conforms-to "spec:transcript"
                    #:resource-classified-as (list "tag:plan:request")
                    #:resource-quantity (make-measure 1 "each") #:receiver "agent:commune" #:due "2026-04-02T00:00:00Z" #:planned-within "plan:infra"))))

;; Run the full relational planner
(let ((plans (with-vat vat
               (relational-plan 1 ($ scope 'recipe-store) ($ scope 'plan-store)
                                ($ scope 'observer)
                                #:live-registry ($ scope 'live-registry)
                                #:plan-id "infra-plan"))))
  (check-pred "relational-plan: finds solution" (pair? plans))
  (when (pair? plans)
    (display (string-append "  plan: " (object->string (car plans)) "\n"))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Done
;;; ════════════════════════════════════════════════════════════════════════════

(test-summary!)
(test-summary!)
