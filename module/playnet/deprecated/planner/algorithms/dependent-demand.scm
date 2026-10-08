;;; dependent-demand.scm — recipe scaling + cascade (the BOM explosion).
;;;
;;; Spec: docs/playnet.typ §"The surface as a stock network" (recipe scaled
;;;       to the gap, exploded up the graph, stopping at scope boundaries).
;;;
;;; This is the spec's recipe scaling and composition, done: a gap on a
;;; stock summons its recipe scaled to the gap; the recipe decomposes into
;;; work-intents + input-intents; input-intents cascade upstream as gaps on
;;; upstream stocks until raw materials, imports, or a decoupling point
;;; (a scope boundary). Replenishment is pulled by drawdown, not forecast.
;;;
;;; Given a demand (spec, qty, due-date), recursively explode through recipes:
;;;   1. Net against on-hand stock and scheduled outputs (use existing first)
;;;   2. Handle durable inputs: `use` (depreciation, not consumption) and
;;;      `cite` (existence gate) — means of production, not consumed
;;;   3. Check transport routing (cross-scope transfer: pickup/dropoff)
;;;   4. Select recipe by lowest crystallized SNLT
;;;      [Stage-3: recipe *recomposition* — pull-sensitive alternatives.]

;; An unmet intent is a transfer with no known provider — the scope
;; needs this resource from outside but hasn't identified a source.
;; Previously tracked as a separate "purchase-intents" list; now unified
;; into the regular intents list and identified by this predicate.
(define-module (playnet deprecated planner algorithms dependent-demand)
  #:use-module (goblins)
  #:use-module (playnet planner vf schemas)
  #:use-module (playnet planner algorithms propagation)
  #:use-module (playnet utils store-utils)
  #:use-module (playnet planner algorithms skill-matcher)
  #:use-module (playnet planner observation observer)
  #:use-module (playnet deprecated planner algorithms netting)
  #:export (unmet-intent? *epsilon-dd* *non-consuming-dd* flow-allows-resource?
            dependent-demand))

(define (unmet-intent? i)
  "An unmet intent is one with action='transfer — within a dependent-demand
   result, this action is used exclusively for demands that couldn't be met
   by internal recipes or inventory. Regular demand-explosion produces
   consume/use/work/cite intents, never transfer."
  (eq? (intent-action i) 'transfer))
;;;   5. Back-schedule process chain from due date
;;;   6. Create intents/commitments for each flow
;;;   7. Container-mediated resolution (resolveFromFlow)
;;;   8. Enqueue each input as new demand (BFS)
;;;   9. Stop at decoupling points (buffer boundaries)

;; Assumes schemas.scm, store-utils.scm, propagation.scm, sne.scm,
;; netting.scm, signals.scm are loaded.

(use-modules (srfi srfi-1)
             (srfi srfi-11)
             (goblins utils hashmap))

(define *epsilon-dd* 1e-9)
(define *non-consuming-dd* '(use work cite deliver-service))


;; =========================================================================
;; dependent-demand — main entry point
;; =========================================================================

(define (flow-allows-resource? flow resource)
  "Does RESOURCE satisfy the FLOW's spec/state/stage filter?

   Lifted out of tests/planner/test-food-cold-chain-vf.scm, which held the only
   definition while dependent-demand below already called it — so any non-#f
   flow reaching that filter was an unbound-variable crash. The test is the
   spec: strict spec match, with state and stage enforced only when the flow
   declares one."
  (and (equal? (recipe-flow-resource-conforms-to flow)
               (economic-resource-conforms-to resource))
       (or (not (recipe-flow-state flow))
           (equal? (recipe-flow-state flow) (economic-resource-state resource)))
       (or (not (recipe-flow-stage flow))
           (equal? (recipe-flow-stage flow) (economic-resource-stage resource)))))

(define* (dependent-demand plan-id demand-spec-id demand-quantity due-date
                           recipe-store plan-store observer initial-ns
                           #:key (agents #f) (generate-id-fn #f) (sne-index #f)
                                 (at-location #f) (honor-decoupling-points #f)
                                 (buffered-specs '()) (location-store #f)
                                 (agent-store #f) (scope-agent-id #f)
                                 (alert-store #f))
  "Explode a demand through the bill of materials via BFS.
   initial-ns: <netter-state> (immutable — threaded through via set! on binding).
   Returns (values new-ns result-alist)."

  (define gen-id (or generate-id-fn (lambda () (generate-id "dd-"))))
  (define visited (make-hash-table))

  ;; Netter state (binding mutated, value immutable)
  (define ns initial-ns)

  ;; Mutable accumulators (BFS traversal state)
  (define result-processes '())
  (define result-commitments '())
  (define result-intents '())
  ;; (purchase-intents removed — unified into result-intents)
  (define result-allocated '())
  (define result-boundary-stops '())
  (define result-work-assignments '())  ;; ((intent-id . X) (suggested-provider . Y) ...)
  (define assigned-agents '())  ;; agents already committed to work flows (no double-booking)
  (define queue '())


  ;; ── Durable input: USE action (time-slot scheduling) ──────────────

  (define* (handle-use-demand! spec-id qty unit needed-by process-end for-pid task-loc
                               #:optional (flow #f))
    "Schedule a time-slot for 'use' action. Returns resource-id or #f.
     Filters by: quantity > 0, flow state/stage acceptance."
    (if (not observer) #f
        (let* ((candidates ($ observer 'conforming-resources spec-id))
               (filtered (filter (lambda (r)
                                   (and (> (measure-qty (economic-resource-onhand-quantity r)) 0)
                                        (or (not flow)
                                            (flow-allows-resource? flow r))))
                                 candidates)))
          (let use-loop ((rs filtered))
            (if (null? rs)
                ;; No available unit → purchase intent
                (begin
                  (set! result-intents
                    (cons (make-intent #:id (gen-id) #:action 'transfer
                                       #:input-of for-pid #:resource-conforms-to spec-id
                                       #:resource-quantity (make-measure qty unit) #:receiver (and agents (assq-ref agents 'receiver)) #:due needed-by #:at-location task-loc
                                       #:planned-within plan-id)
                          result-intents))
                  #f)
                (let* ((r (car rs))
                       (rid (economic-resource-id r)))
                  ;; Try to reserve time-slot via netter
                  ;; (simplified — netter doesn't have netUse, just check availability)
                  (let ((use-intent (make-intent #:id (gen-id) #:action 'use
                                     #:input-of for-pid #:resource-inventoried-as rid #:resource-conforms-to spec-id
                                     #:resource-quantity (make-measure qty unit)
                                     #:provider (and agents (assq-ref agents 'provider))
                                     #:receiver (and agents (assq-ref agents 'receiver))
                                     #:has-beginning (and needed-by (number->string needed-by))
                                     #:has-end (and process-end (number->string process-end)) #:at-location task-loc #:planned-within plan-id)))
                    (set! result-intents (cons use-intent result-intents))
                    rid)))))))


  ;; ── Durable input: CITE action (existence gate) ───────────────────

  (define (handle-cite-demand! spec-id for-pid task-loc)
    "Check existence for 'cite' action. Returns #t if exists, #f otherwise."
    (if (not observer) #f
        (let* ((candidates ($ observer 'conforming-resources spec-id))
               (exists (any (lambda (r)
                              (> (measure-qty (economic-resource-accounting-quantity r)) 0))
                            candidates)))
          (unless exists
            (set! result-intents
              (cons (make-intent #:id (gen-id) #:action 'transfer
                                 #:input-of for-pid #:resource-conforms-to spec-id
                                 #:resource-quantity (make-measure 1 "each") #:receiver (and agents (assq-ref agents 'receiver)) #:at-location task-loc #:planned-within plan-id)
                    result-intents)))
          exists)))


  ;; ── Transport routing (cross-location) ────────────────────────────

  (define (find-transport-recipe spec-id demand-location)
    "Find transport recipe + source location for cross-location demand.
     Returns (recipe . from-location) or #f.

     Source locations are scored by net-available (post-netter) rather
     than raw onhand, so prior allocations from earlier demands in
     this BFS are accounted for. Without this, two demands targeting
     the same remote inventory would both see the full onhand count
     and both pick the same (potentially exhausted) source."
    (if (or (not demand-location) (not observer)) #f
        (let* ((all-resources ($ observer 'all-resources))
               ;; Collect unique candidate source locations
               (candidate-locs
                 (delete-duplicates
                   (filter-map
                     (lambda (r)
                       (and (equal? (economic-resource-conforms-to r) spec-id)
                            (not (economic-resource-contained-in r))
                            (economic-resource-current-location r)
                            (not (equal? (economic-resource-current-location r) demand-location))
                            (not (and location-store
                                      ($ location-store 'is-descendant-or-equal
                                         (economic-resource-current-location r) demand-location)))
                            (> (measure-qty (economic-resource-onhand-quantity r)) 0)
                            (economic-resource-current-location r)))
                     all-resources)
                   equal?))
               ;; Score each location by net-available (post-netter)
               (candidates
                 (filter-map
                   (lambda (loc)
                     (let ((avail (netter-net-available ns plan-store observer spec-id
                                    #:at-location loc #:location-store location-store)))
                       (and (> avail *epsilon-dd*) (cons loc avail))))
                   candidate-locs)))
          (if (null? candidates) #f
              ;; Check for transport recipes
              (let ((t-recipes ($ recipe-store 'recipes-for-transport spec-id)))
                (if (null? t-recipes) #f
                    ;; Pick location with most net-available inventory
                    (let* ((sorted-locs (sort candidates (lambda (a b) (> (cdr a) (cdr b)))))
                           (from-loc (caar sorted-locs))
                           ;; Pick best recipe by SNLT
                           (scored (map (lambda (r)
                                          (cons r (compute-snlt recipe-store (recipe-id r) spec-id)))
                                        t-recipes))
                           (best (caar (sort scored (lambda (a b) (< (cdr a) (cdr b)))))))
                      (cons best from-loc))))))))


  ;; ── Explode a single recipe for remaining demand ──────────────────

  (define (explode-recipe! spec-id remaining unit needed-by task-location for-process-id
                           . rest)
    (let* ((transport-info (and (pair? rest) (car rest)))
           ;; Recipe selection: transport overrides production
           (candidates (if transport-info
                          (list (car transport-info))
                          ($ recipe-store 'recipes-for-output spec-id)))
           ;; Score by SNE (if available) or SNLT
           (scored (map (lambda (r)
                          (cons r (if sne-index
                                      (or (hashmap-ref sne-index (recipe-id r) #f)
                                          (compute-snlt recipe-store (recipe-id r) spec-id))
                                      (compute-snlt recipe-store (recipe-id r) spec-id))))
                        candidates))
           (sorted (sort scored (lambda (a b) (< (cdr a) (cdr b)))))
           (best (and (pair? sorted) (caar sorted))))

      (cond
        ;; No recipe → purchase intent
        ((not best)
         (set! result-intents
           (cons (make-intent #:id (gen-id) #:action 'transfer
                              #:input-of for-process-id #:resource-conforms-to spec-id
                              #:resource-quantity (make-measure remaining unit)
                              #:provider (and agents (assq-ref agents 'provider))
                              #:receiver (and agents (assq-ref agents 'receiver)) #:due needed-by #:at-location task-location
                              #:planned-within plan-id)
                 result-intents)))

        ;; Cycle → skip
        ((hash-ref visited (recipe-id best) #f) #f)

        ;; Explode recipe
        (else
         (let ((rid (recipe-id best)))
           (hash-set! visited rid #t)
           (let* ((chain ($ recipe-store 'get-process-chain rid))
                  ;; Find output qty for scaling
                  (last-proc (and (pair? chain) (last chain)))
                  (last-outs (and last-proc
                                  (cdr ($ recipe-store 'flows-for-process
                                           (recipe-process-id last-proc)))))
                  (primary (and last-outs
                                (find (lambda (f)
                                        (equal? (recipe-flow-resource-conforms-to f) spec-id))
                                      last-outs)))
                  (out-qty (if (and primary (recipe-flow-resource-quantity primary))
                               (measure-has-numerical-value
                                 (recipe-flow-resource-quantity primary))
                               1))
                  (raw-scale (/ remaining out-qty))
                  ;; Enforce minimum batch quantity
                  (scale (fold (lambda (rp s)
                                 (let ((mbq (recipe-process-minimum-batch-quantity rp)))
                                   (if (and mbq (> (measure-has-numerical-value mbq) 0))
                                       (max s (/ (measure-has-numerical-value mbq) out-qty))
                                       s)))
                               raw-scale chain))
                  ;; Internal specs (don't recurse into)
                  (internal
                    (fold (lambda (rp acc)
                            (let ((outs (cdr ($ recipe-store 'flows-for-process
                                                (recipe-process-id rp)))))
                              (fold (lambda (f a)
                                      (let ((s (recipe-flow-resource-conforms-to f)))
                                        (if s (cons s a) a)))
                                    acc outs)))
                          '() chain))
                  ;; Container anchor resolution map
                  (anchor-resolved (make-hash-table)))

             ;; Back-schedule processes (reverse from due date)
             (let proc-loop ((procs (reverse chain)) (cursor needed-by))
               (when (pair? procs)
                 (let* ((rp (car procs))
                        (dur-s (inexact->exact (round (/ (rp-duration-ms rp) 1000))))
                        (proc-end cursor)
                        (proc-begin (- cursor dur-s))
                        (pid (gen-id))
                        (proc (make-process #:id pid #:name (recipe-process-name rp)
                                #:based-on (recipe-process-process-conforms-to rp) #:planned-within plan-id
                                #:has-beginning (number->string proc-begin)
                                #:has-end (number->string proc-end)))
                        (flows-pair ($ recipe-store 'flows-for-process
                                       (recipe-process-id rp)))
                        (inputs (car flows-pair))
                        (outputs (cdr flows-pair))
                        ;; Skill matching: compute per-flow agent map for work flows
                        (work-flows (filter (lambda (f) (eq? (recipe-flow-action f) 'work)) inputs))
                        (flow-agent-map
                          (if (and agent-store (pair? work-flows))
                              (match-work-flows work-flows observer agent-store
                                #:scope-id scope-agent-id
                                #:already-assigned assigned-agents)
                              '())))

                   ;; Update assigned-agents accumulator with newly matched agents
                   (for-each (lambda (pair)
                               (when (cdr pair)
                                 (set! assigned-agents (cons (cdr pair) assigned-agents))))
                             flow-agent-map)

                   (set! result-processes (cons proc result-processes))

                   ;; Phase 0: Resolve use-anchor flows first
                   (for-each
                     (lambda (f)
                       (when (and (eq? (recipe-flow-action f) 'use)
                                  (recipe-flow-resolve-from-flow f))
                         (let ((resolved-id (handle-use-demand!
                                              (recipe-flow-resource-conforms-to f)
                                              (if (recipe-flow-resource-quantity f)
                                                  (* (measure-has-numerical-value
                                                       (recipe-flow-resource-quantity f)) scale)
                                                  1)
                                              (if (recipe-flow-resource-quantity f)
                                                  (measure-has-unit (recipe-flow-resource-quantity f))
                                                  "each")
                                              proc-begin proc-end pid task-location f)))
                           (when resolved-id
                             (hash-set! anchor-resolved
                               (recipe-flow-id f) resolved-id)))))
                     inputs)

                   ;; Output flows
                   (for-each
                     (lambda (f)
                       (let ((rec (create-flow-record f pid 'output scale
                                    (number->string proc-end)
                                    plan-id agents plan-store task-location)))
                         (if (commitment? rec)
                             (set! result-commitments (cons rec result-commitments))
                             (set! result-intents (cons rec result-intents)))))
                     outputs)

                   ;; Phase A: Anchor input flows (those WITHOUT resolveFromFlow)
                   (for-each
                     (lambda (f)
                       (let* ((action (recipe-flow-action f))
                              (in-spec (recipe-flow-resource-conforms-to f))
                              (rq (recipe-flow-resource-quantity f))
                              (in-qty (and rq (* (measure-has-numerical-value rq) scale)))
                              (in-unit (and rq (measure-has-unit rq)))
                              (has-resolve (recipe-flow-resolve-from-flow f)))
                         ;; Skip Phase B flows (handled separately)
                         (unless has-resolve
                           ;; Create flow record (unless already handled in Phase 0)
                           (unless (hash-ref anchor-resolved (recipe-flow-id f) #f)
                             ;; For work flows, resolve per-flow agent; one lookup
                             (let* ((match (and (eq? action 'work)
                                                (assoc (recipe-flow-id f) flow-agent-map)))
                                    (matched-agent (and match (cdr match)))
                                    (flow-agents
                                      (if match
                                          ;; Work flow: always Intent (no provider → no Commitment)
                                          `((receiver . ,(and agents (assq-ref agents 'receiver))))
                                          ;; Non-work flow: use global agents as before
                                          agents))
                                    (rec (create-flow-record f pid 'input scale
                                           (number->string proc-begin)
                                           plan-id flow-agents plan-store task-location)))
                               ;; Collect work assignment (intent-id paired with suggested agent)
                               (when (and match matched-agent)
                                 (set! result-work-assignments
                                   (cons `((intent-id . ,(intent-id rec))
                                           (suggested-provider . ,matched-agent)
                                           (spec-id . ,in-spec)
                                           (process-id . ,pid))
                                         result-work-assignments)))
                               ;; Alert for unmatched work flows
                               (when (and alert-store match (not matched-agent))
                                 ($ alert-store 'push-alert
                                    `((kind . unmatched-role)
                                      (spec-id . ,in-spec)
                                      (process-id . ,pid)
                                      (plan-id . ,plan-id)
                                      (message . ,(string-append
                                                    "No agent with skill "
                                                    (or in-spec "unknown")
                                                    " available")))))
                               ;; Work flows always → Intent; non-work keeps existing dispatch
                               (if match
                                   (set! result-intents (cons rec result-intents))
                                   (if (commitment? rec)
                                       (set! result-commitments (cons rec result-commitments))
                                       (set! result-intents (cons rec result-intents))))))
                           ;; Enqueue input demand
                           (when (and in-spec in-qty
                                      (not (eq? action 'work))
                                      (not (member in-spec internal))
                                      (not (memq action '(use cite))))
                             (set! queue
                               (append queue
                                 (list `((spec-id . ,in-spec)
                                         (quantity . ,in-qty)
                                         (needed-by . ,proc-begin)
                                         (unit . ,(or in-unit "each"))
                                         (at-location . ,task-location)
                                         (for-process-id . ,pid)))))))))
                     inputs)

                   ;; Phase B: Dependent flows (those WITH resolveFromFlow)
                   (for-each
                     (lambda (f)
                       (when (recipe-flow-resolve-from-flow f)
                         (let* ((action (recipe-flow-action f))
                                (in-spec (recipe-flow-resource-conforms-to f))
                                (rq (recipe-flow-resource-quantity f))
                                (in-qty (and rq (* (measure-has-numerical-value rq) scale)))
                                (in-unit (and rq (measure-has-unit rq)))
                                (container-id (hash-ref anchor-resolved
                                                (recipe-flow-resolve-from-flow f) #f)))
                           ;; Always create flow record
                           (let ((rec (create-flow-record f pid 'input scale
                                        (number->string proc-begin)
                                        plan-id agents plan-store task-location)))
                             (if (commitment? rec)
                                 (set! result-commitments (cons rec result-commitments))
                                 (set! result-intents (cons rec result-intents))))
                           ;; Enqueue with container constraint
                           (if (not container-id)
                               ;; No container resolved → purchase intent
                               (when (and in-spec in-qty)
                                 (set! result-intents
                                   (cons (make-intent #:id (gen-id) #:action 'transfer
                                                      #:input-of pid #:resource-conforms-to in-spec
                                                      #:resource-quantity (make-measure in-qty (or in-unit "each"))
                                                      #:receiver (and agents (assq-ref agents 'receiver)) #:due proc-begin #:at-location task-location
                                                      #:planned-within plan-id)
                                         result-intents)))
                               ;; Container resolved → enqueue with containedIn constraint
                               (when (and in-spec in-qty (> in-qty *epsilon-dd*))
                                 (set! queue
                                   (append queue
                                     (list `((spec-id . ,in-spec)
                                             (quantity . ,in-qty)
                                             (needed-by . ,proc-begin)
                                             (unit . ,(or in-unit "each"))
                                             (at-location . ,task-location)
                                             (for-process-id . ,pid)
                                             (resolved-container-id . ,container-id))))))))))
                     inputs)

                   (proc-loop (cdr procs) proc-begin))))

             (hash-remove! visited rid)))))))


  ;; ── Process one demand task ───────────────────────────────────────

  (define (process-demand! task)
    (let* ((spec-id (assq-ref task 'spec-id))
           (qty (assq-ref task 'quantity))
           (needed-by (assq-ref task 'needed-by))
           (unit (or (assq-ref task 'unit) "each"))
           (task-loc (assq-ref task 'at-location))
           (for-pid (assq-ref task 'for-process-id))
           (durable-action (assq-ref task 'durable-action))
           (process-end (assq-ref task 'process-end))
           (container-id (assq-ref task 'resolved-container-id)))

      (when (> qty *epsilon-dd*)
        (cond
          ;; Container-resolved demands: net with containedIn constraint
          (container-id
           (let-values (((new-ns remaining alloc)
                         (netter-net-demand ns plan-store observer spec-id qty
                           #:contained-in container-id
                           #:at-location task-loc #:needed-by needed-by
                           #:plan-id plan-id #:location-store location-store)))
             (set! ns new-ns)
             (for-each (lambda (a) (set! result-allocated (cons a result-allocated))) alloc)
             (when (> remaining *epsilon-dd*)
               ;; Gap → purchase intent
               (set! result-intents
                 (cons (make-intent #:id (gen-id) #:action 'transfer
                                    #:input-of for-pid #:resource-conforms-to spec-id
                                    #:resource-quantity (make-measure remaining unit) #:receiver (and agents (assq-ref agents 'receiver)) #:due needed-by #:at-location task-loc
                                    #:planned-within plan-id)
                       result-intents)))))

          ;; Durable: use (time-slot scheduling)
          ((eq? durable-action 'use)
           (handle-use-demand! spec-id qty unit needed-by process-end for-pid task-loc))

          ;; Durable: cite (existence gate)
          ((eq? durable-action 'cite)
           (handle-cite-demand! spec-id for-pid task-loc))

          ;; Normal demand: net → transport check → explode
          (else
           (let-values (((new-ns remaining alloc)
                         (netter-net-demand ns plan-store observer spec-id qty
                           #:at-location task-loc #:needed-by needed-by
                           #:plan-id plan-id #:location-store location-store)))
             (set! ns new-ns)
             (for-each (lambda (a) (set! result-allocated (cons a result-allocated))) alloc)

             (when (> remaining *epsilon-dd*)
               ;; Check decoupling point
               (if (and honor-decoupling-points (member spec-id buffered-specs))
                   (let ((existing (or (assoc-ref result-boundary-stops spec-id) 0)))
                     (set! result-boundary-stops
                       (cons (cons spec-id (+ existing remaining))
                             (filter (lambda (p) (not (equal? (car p) spec-id)))
                                     result-boundary-stops))))
                   ;; Check transport routing
                   (let ((transport (find-transport-recipe spec-id task-loc)))
                     (explode-recipe! spec-id remaining unit needed-by task-loc for-pid
                                      transport)))))))
        )))


  ;; ── Initialize queue and run BFS ──────────────────────────────────

  (set! queue
    (list `((spec-id . ,demand-spec-id)
            (quantity . ,demand-quantity)
            (needed-by . ,due-date)
            (unit . ,(or (and observer
                             (let ((spec ($ recipe-store 'get-resource-spec demand-spec-id)))
                               (and spec (resource-specification-default-unit-of-resource spec))))
                         "each"))
            (at-location . ,at-location))))

  (let bfs-loop ()
    (when (pair? queue)
      (let ((task (car queue)))
        (set! queue (cdr queue))
        (process-demand! task)
        (bfs-loop))))

  ;; Return (values new-netter-state result-alist)
  (values ns
    `((processes . ,(reverse result-processes))
      (commitments . ,(reverse result-commitments))
      (intents . ,(reverse result-intents))
      ;; purchase-intents removed — unmet intents are in the intents list
      ;; above, identifiable via (unmet-intent? i). This empty field is
      ;; kept temporarily for backwards compatibility with callers that
      ;; destructure by key; it will be removed once all consumers migrate.
      (purchase-intents . ())
      (allocated . ,(reverse result-allocated))
      (boundary-stops . ,result-boundary-stops)
      (work-assignments . ,(reverse result-work-assignments)))))
