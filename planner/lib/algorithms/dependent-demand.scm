;;; dependent-demand.scm — BFS demand explosion through bill of materials
;;;
;;; Translated from src/lib/algorithms/dependent-demand.ts
;;; Pure function (except netter mutation, which is turn-local).
;;;
;;; Given a demand (spec, qty, due-date), recursively explode through recipes:
;;;   1. Net against inventory and scheduled outputs
;;;   2. Handle durable inputs (use = time-slot, cite = existence gate)
;;;   3. Check transport routing (cross-location pickup/dropoff)
;;;   4. Find best recipe (lowest SNLT or SNE)
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

(define* (dependent-demand plan-id demand-spec-id demand-quantity due-date
                           recipe-store plan-store observer initial-ns
                           #:key (agents #f) (generate-id-fn #f) (sne-index #f)
                                 (at-location #f) (honor-decoupling-points #f)
                                 (buffered-specs '()) (location-store #f))
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
  (define result-purchase-intents '())
  (define result-allocated '())
  (define result-boundary-stops '())
  (define queue '())


  ;; ── Durable input: USE action (time-slot scheduling) ──────────────

  (define (handle-use-demand! spec-id qty unit needed-by process-end for-pid task-loc)
    "Schedule a time-slot for 'use' action. Returns resource-id or #f."
    (if (not observer) #f
        (let* ((candidates ($ observer 'conforming-resources spec-id))
               (filtered (filter (lambda (r)
                                   (and (> (measure-qty (economic-resource-onhand-quantity r)) 0)
                                        (not (economic-resource-contained-in r))))
                                 candidates)))
          (let use-loop ((rs filtered))
            (if (null? rs)
                ;; No available unit → purchase intent
                (begin
                  (set! result-purchase-intents
                    (cons (make-intent (gen-id) 'transfer #f #f #f
                                       for-pid #f #f spec-id #f
                                       (make-measure qty unit) #f #f #f
                                       #f (and agents (assq-ref agents 'receiver))
                                       #f #f #f needed-by task-loc #f #f
                                       plan-id #f #f #f #f)
                          result-purchase-intents))
                  #f)
                (let* ((r (car rs))
                       (rid (economic-resource-id r)))
                  ;; Try to reserve time-slot via netter
                  ;; (simplified — netter doesn't have netUse, just check availability)
                  (let ((use-intent (make-intent (gen-id) 'use #f #f #f
                                     for-pid #f rid spec-id #f
                                     (make-measure qty unit) #f #f #f
                                     (and agents (assq-ref agents 'provider))
                                     (and agents (assq-ref agents 'receiver))
                                     (and needed-by (number->string needed-by))
                                     (and process-end (number->string process-end))
                                     #f #f task-loc #f #f plan-id #f #f #f #f)))
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
            (set! result-purchase-intents
              (cons (make-intent (gen-id) 'transfer #f #f #f
                                 for-pid #f #f spec-id #f
                                 (make-measure 1 "each") #f #f #f
                                 #f (and agents (assq-ref agents 'receiver))
                                 #f #f #f #f task-loc #f #f plan-id #f #f #f #f)
                    result-purchase-intents)))
          exists)))


  ;; ── Transport routing (cross-location) ────────────────────────────

  (define (find-transport-recipe spec-id demand-location)
    "Find transport recipe + source location for cross-location demand.
     Returns (recipe . from-location) or #f."
    (if (or (not demand-location) (not observer)) #f
        (let* ((all-resources ($ observer 'all-resources))
               ;; Find candidate source locations
               (candidates
                 (fold (lambda (r acc)
                         (if (and (equal? (economic-resource-conforms-to r) spec-id)
                                  (not (economic-resource-contained-in r))
                                  (economic-resource-current-location r)
                                  (not (equal? (economic-resource-current-location r) demand-location))
                                  (not (and location-store
                                            ($ location-store 'is-descendant-or-equal
                                               (economic-resource-current-location r) demand-location)))
                                  (> (measure-qty (economic-resource-onhand-quantity r)) 0))
                             (let* ((loc (economic-resource-current-location r))
                                    (existing (assoc-ref acc loc)))
                               (cons (cons loc (+ (or existing 0)
                                                   (measure-qty (economic-resource-onhand-quantity r))))
                                     (filter (lambda (p) (not (equal? (car p) loc))) acc)))
                             acc))
                       '() all-resources)))
          (if (null? candidates) #f
              ;; Check for transport recipes
              (let ((t-recipes ($ recipe-store 'recipes-for-transport spec-id)))
                (if (null? t-recipes) #f
                    ;; Pick location with most inventory
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
         (set! result-purchase-intents
           (cons (make-intent (gen-id) 'transfer #f #f #f
                              for-process-id #f #f spec-id #f
                              (make-measure remaining unit) #f #f #f
                              (and agents (assq-ref agents 'provider))
                              (and agents (assq-ref agents 'receiver))
                              #f #f #f needed-by task-location #f #f
                              plan-id #f #f #f #f)
                 result-purchase-intents)))

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
                        (proc (make-process pid (recipe-process-name rp) #f
                                (recipe-process-process-conforms-to rp)
                                #f plan-id #f #f
                                (number->string proc-begin)
                                (number->string proc-end) #f))
                        (flows-pair ($ recipe-store 'flows-for-process
                                       (recipe-process-id rp)))
                        (inputs (car flows-pair))
                        (outputs (cdr flows-pair)))

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
                                              proc-begin proc-end pid task-location)))
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
                             (let ((rec (create-flow-record f pid 'input scale
                                          (number->string proc-begin)
                                          plan-id agents plan-store task-location)))
                               (if (commitment? rec)
                                   (set! result-commitments (cons rec result-commitments))
                                   (set! result-intents (cons rec result-intents)))))
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
                                 (set! result-purchase-intents
                                   (cons (make-intent (gen-id) 'transfer #f #f #f
                                                      pid #f #f in-spec #f
                                                      (make-measure in-qty (or in-unit "each"))
                                                      #f #f #f #f
                                                      (and agents (assq-ref agents 'receiver))
                                                      #f #f #f proc-begin task-location #f #f
                                                      plan-id #f #f #f #f)
                                         result-purchase-intents)))
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
                           #:at-location task-loc #:needed-by needed-by
                           #:plan-id plan-id)))
             (set! ns new-ns)
             (for-each (lambda (a) (set! result-allocated (cons a result-allocated))) alloc)
             (when (> remaining *epsilon-dd*)
               ;; Gap → purchase intent
               (set! result-purchase-intents
                 (cons (make-intent (gen-id) 'transfer #f #f #f
                                    for-pid #f #f spec-id #f
                                    (make-measure remaining unit) #f #f #f
                                    #f (and agents (assq-ref agents 'receiver))
                                    #f #f #f needed-by task-loc #f #f
                                    plan-id #f #f #f #f)
                       result-purchase-intents)))))

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
                           #:plan-id plan-id)))
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
      (purchase-intents . ,(reverse result-purchase-intents))
      (allocated . ,(reverse result-allocated))
      (boundary-stops . ,result-boundary-stops))))
