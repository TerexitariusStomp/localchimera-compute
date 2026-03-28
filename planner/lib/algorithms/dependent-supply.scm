;;; dependent-supply.scm — BFS supply absorption through bill of materials
;;;
;;; Translated from src/lib/algorithms/dependent-supply.ts
;;; Pure function (except netter mutation, which is turn-local).
;;;
;;; Given available supply (spec, qty, available-from), find recipes that
;;; consume it, forward-schedule processes, and track what gets absorbed.

;; Assumes schemas.scm, store-utils.scm, propagation.scm, netting.scm are loaded.

(use-modules (srfi srfi-1)
             (goblins utils hashmap))

(define *epsilon-ds* 1e-9)

(define *durable-actions* '(use cite))


;; =========================================================================
;; dependent-supply — main entry point
;; =========================================================================

(define* (dependent-supply plan-id supply-spec-id supply-quantity available-from
                           recipe-store plan-store observer initial-ns
                           #:key (agents #f) (generate-id-fn #f) (at-location #f))
  "Absorb available supply through recipes via BFS.
   initial-ns: <netter-state> (immutable — threaded through via set! on binding).
   Returns (values new-ns result-alist)."
  (define gen-id (or generate-id-fn (lambda () (generate-id "ds-"))))
  (define visited (make-hash-table))
  (define ns initial-ns)
  (define result-processes '())
  (define result-commitments '())
  (define result-intents '())
  (define result-surplus '())
  (define result-purchase-intents '())
  (define result-absorbed '())
  (define queue
    (list `((spec-id . ,supply-spec-id)
            (quantity . ,supply-quantity)
            (available-from . ,available-from)
            (is-derived . #f)
            (at-location . ,at-location))))

  (define (process-supply! task)
      (let* ((spec-id (assq-ref task 'spec-id))
             (qty (assq-ref task 'quantity))
             (avail-from (assq-ref task 'available-from))
             (is-derived (assq-ref task 'is-derived))
             (task-location (assq-ref task 'at-location))
             ;; Mode C gate: deduct pre-claimed consumptions (pure state monad)
             (remaining qty))
        ;; Thread netter state through net-supply
        (when ns
          (let-values (((new-ns rem) (netter-net-supply ns plan-store spec-id qty
                                       #:available-from avail-from
                                       #:at-location task-location)))
            (set! ns new-ns)
            (set! remaining rem)))

        (when (> remaining *epsilon-ds*)
          ;; Find recipes that consume this spec
          (let* ((candidates ($ recipe-store 'recipes-for-input spec-id))
                 ;; SNLT ranking (most labour-efficient first)
                 (scored (map (lambda (r)
                                (cons r (compute-snlt recipe-store (recipe-id r))))
                              candidates))
                 (sorted (sort scored (lambda (a b) (< (cdr a) (cdr b))))))

            (if (null? sorted)
                ;; No recipe can absorb this supply
                (when (not is-derived)  ;; only original supply is surplus
                  (set! result-surplus
                    (cons `((spec-id . ,spec-id) (quantity . ,remaining))
                          result-surplus)))

                ;; Try each recipe in SNLT order
                (let recipe-loop ((recipes sorted))
                  (when (and (pair? recipes) (> remaining *epsilon-ds*))
                    (let* ((recipe (caar recipes))
                           (rid (recipe-id recipe)))

                      (if (hash-ref visited rid #f)
                          ;; Cycle → skip to next recipe
                          (recipe-loop (cdr recipes))

                          (let* ((chain ($ recipe-store 'get-process-chain rid)))
                            (if (null? chain)
                                (recipe-loop (cdr recipes))

                                (begin
                                  ;; Calculate supply consumed per execution
                                  (let* ((supply-per-exec
                                           (fold (lambda (rp acc)
                                                   (let ((inputs (car ($ recipe-store 'flows-for-process
                                                                         (recipe-process-id rp)))))
                                                     (fold (lambda (f a)
                                                             (if (and (equal? (recipe-flow-resource-conforms-to f)
                                                                              spec-id)
                                                                      (not (memq (recipe-flow-action f)
                                                                                 *durable-actions*))
                                                                      (not (eq? (recipe-flow-action f) 'work))
                                                                      (recipe-flow-resource-quantity f))
                                                                 (+ a (measure-has-numerical-value
                                                                         (recipe-flow-resource-quantity f)))
                                                                 a))
                                                           acc inputs)))
                                                 0 chain)))

                                    (when (> supply-per-exec 0)
                                      (let* ((max-execs (inexact->exact (floor (/ remaining supply-per-exec))))
                                             (executions (max 1 (min max-execs 1000))))
                                        ;; Collect internally produced/consumed specs
                                        (let* ((internal-outputs
                                                 (fold (lambda (rp acc)
                                                         (let ((outputs (cdr ($ recipe-store 'flows-for-process
                                                                                (recipe-process-id rp)))))
                                                           (fold (lambda (f a)
                                                                   (let ((s (recipe-flow-resource-conforms-to f)))
                                                                     (if s (cons s a) a)))
                                                                 acc outputs)))
                                                       '() chain)))

                                          (hash-set! visited rid #t)

                                          ;; Forward-schedule processes
                                          (let loop-procs ((procs chain)
                                                           (cursor avail-from))
                                            (when (pair? procs)
                                              (let* ((rp (car procs))
                                                     (dur-s (inexact->exact
                                                              (round (/ (rp-duration-ms rp) 1000))))
                                                     (proc-begin cursor)
                                                     (proc-end (+ cursor dur-s))
                                                     (proc-id (gen-id))
                                                     (proc (make-process
                                                             proc-id (recipe-process-name rp) #f
                                                             (recipe-process-process-conforms-to rp)
                                                             #f plan-id #f #f
                                                             (number->string proc-begin)
                                                             (number->string proc-end)
                                                             #f)))
                                                (set! result-processes (cons proc result-processes))

                                                ;; Input flows
                                                (let ((inputs (car ($ recipe-store 'flows-for-process
                                                                       (recipe-process-id rp)))))
                                                  (for-each
                                                    (lambda (f)
                                                      (let ((record (create-flow-record
                                                                      f proc-id 'input executions
                                                                      (number->string proc-begin)
                                                                      plan-id agents plan-store
                                                                      task-location)))
                                                        (if (commitment? record)
                                                            (set! result-commitments
                                                              (cons record result-commitments))
                                                            (set! result-intents
                                                              (cons record result-intents)))
                                                        ;; Track absorption of supply spec
                                                        (when (equal? (recipe-flow-resource-conforms-to f) spec-id)
                                                          (let ((abs-qty (and (recipe-flow-resource-quantity f)
                                                                             (* (measure-has-numerical-value
                                                                                  (recipe-flow-resource-quantity f))
                                                                                executions))))
                                                            (when abs-qty
                                                              (set! result-absorbed
                                                                (cons `((spec-id . ,spec-id)
                                                                        (quantity . ,abs-qty)
                                                                        (recipe-id . ,rid))
                                                                      result-absorbed)))))))
                                                    inputs))

                                                ;; Output flows → enqueue as new supply
                                                (let ((outputs (cdr ($ recipe-store 'flows-for-process
                                                                        (recipe-process-id rp)))))
                                                  (for-each
                                                    (lambda (f)
                                                      (let* ((record (create-flow-record
                                                                       f proc-id 'output executions
                                                                       (number->string proc-end)
                                                                       plan-id agents plan-store
                                                                       task-location))
                                                             (out-spec (recipe-flow-resource-conforms-to f))
                                                             (out-qty (and (recipe-flow-resource-quantity f)
                                                                          (* (measure-has-numerical-value
                                                                               (recipe-flow-resource-quantity f))
                                                                             executions))))
                                                        (if (commitment? record)
                                                            (set! result-commitments
                                                              (cons record result-commitments))
                                                            (set! result-intents
                                                              (cons record result-intents)))
                                                        ;; Enqueue output as new supply (if not internal)
                                                        (when (and out-spec out-qty (> out-qty 0)
                                                                   (not (member out-spec internal-outputs)))
                                                          (set! queue
                                                            (append queue
                                                              (list `((spec-id . ,out-spec)
                                                                      (quantity . ,out-qty)
                                                                      (available-from . ,proc-end)
                                                                      (is-derived . #t)
                                                                      (at-location . ,task-location))))))))
                                                    outputs))

                                                (loop-procs (cdr procs) proc-end))))

                                          ;; Deduct from remaining
                                          (set! remaining
                                            (- remaining (* executions supply-per-exec)))

                                          (hash-remove! visited rid)))))

                                  (recipe-loop (cdr recipes)))))))

                ;; Unabsorbed → surplus (only for original supply)
                (when (and (> remaining *epsilon-ds*) (not is-derived))
                  (set! result-surplus
                    (cons `((spec-id . ,spec-id) (quantity . ,remaining))
                          result-surplus))))))))))

  ;; --- BFS main loop ---
  (let bfs-loop ()
    (when (pair? queue)
      (let ((task (car queue)))
        (set! queue (cdr queue))
        (process-supply! task)
        (bfs-loop))))

  (values ns
    `((processes . ,(reverse result-processes))
      (commitments . ,(reverse result-commitments))
      (intents . ,(reverse result-intents))
      (surplus . ,(reverse result-surplus))
      (purchase-intents . ,(reverse result-purchase-intents))
      (absorbed . ,(reverse result-absorbed)))))
