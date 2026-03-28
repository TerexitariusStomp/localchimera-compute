;;; dependent-demand.scm — BFS demand explosion through bill of materials
;;;
;;; Translated from src/lib/algorithms/dependent-demand.ts
;;; Pure function (except netter mutation, which is turn-local).
;;;
;;; Given a demand (spec, qty, due-date), recursively explode through recipes:
;;;   1. Net against inventory and scheduled outputs
;;;   2. Find best recipe (lowest SNLT)
;;;   3. Back-schedule process chain from due date
;;;   4. Create intents/commitments for each flow
;;;   5. Enqueue each input as new demand (BFS)
;;;   6. Stop at decoupling points (buffer boundaries)

;; Assumes schemas.scm, store-utils.scm, propagation.scm, sne.scm,
;; netting.scm, signals.scm are loaded.

(use-modules (srfi srfi-1)
             (srfi srfi-11)
             (goblins utils hashmap))

(define *epsilon-dd* 1e-9)


;; =========================================================================
;; dependent-demand — main entry point
;; =========================================================================

(define* (dependent-demand plan-id demand-spec-id demand-quantity due-date
                           recipe-store plan-store observer initial-ns
                           #:key (agents #f) (generate-id-fn #f) (sne-index #f)
                                 (at-location #f) (honor-decoupling-points #f)
                                 (buffered-specs '()))
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

  ;; --- Explode a single recipe for remaining demand ---
  (define (explode-recipe! spec-id remaining unit needed-by task-location for-process-id)
    (let* ((candidates ($ recipe-store 'recipes-for-output spec-id))
           (scored (map (lambda (r)
                          (cons r (compute-snlt recipe-store (recipe-id r) spec-id)))
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
                          '() chain)))

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

                   ;; Input flows → enqueue demands
                   (for-each
                     (lambda (f)
                       (let* ((action (recipe-flow-action f))
                              (in-spec (recipe-flow-resource-conforms-to f))
                              (rq (recipe-flow-resource-quantity f))
                              (in-qty (and rq (* (measure-has-numerical-value rq) scale)))
                              (in-unit (and rq (measure-has-unit rq))))
                         ;; Create flow record
                         (let ((rec (create-flow-record f pid 'input scale
                                      (number->string proc-begin)
                                      plan-id agents plan-store task-location)))
                           (if (commitment? rec)
                               (set! result-commitments (cons rec result-commitments))
                               (set! result-intents (cons rec result-intents))))
                         ;; Enqueue input demand (skip work, internal, durable)
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
                                       (for-process-id . ,pid))))))))
                     inputs)

                   (proc-loop (cdr procs) proc-begin))))

             (hash-remove! visited rid)))))))

  ;; --- Process one demand task ---
  (define (process-demand! task)
    (let* ((spec-id (assq-ref task 'spec-id))
           (qty (assq-ref task 'quantity))
           (needed-by (assq-ref task 'needed-by))
           (unit (or (assq-ref task 'unit) "each"))
           (task-loc (assq-ref task 'at-location))
           (for-pid (assq-ref task 'for-process-id)))

      (when (> qty *epsilon-dd*)
        ;; Net against inventory + scheduled outputs (pure state monad)
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
                ;; Explode recipe
                (explode-recipe! spec-id remaining unit needed-by task-loc for-pid)))))))

  ;; --- Initialize queue and run BFS ---
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
