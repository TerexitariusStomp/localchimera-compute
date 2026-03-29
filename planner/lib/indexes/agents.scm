;;; agents.scm — Agent capacity index (scheduling utility, not used in planning hot path)
;;;
;;; The planning pipeline derives capacity from EconomicResources (unitOfEffort).
;;; This index is available for the scheduling/assignment phase.

(use-modules (srfi srfi-1) (goblins utils hashmap))

(define (build-agent-index agents intents)
  "Build agent capacity index from agents + work intents.
   Returns alist of indexes."
  (let ((items (hashmap)) (by-spec (hashmap)))
    ;; Index work intents by provider agent + spec
    (for-each
      (lambda (i)
        (when (and (eq? (intent-action i) 'work)
                   (intent-provider i)
                   (not (intent-finished i)))
          (let* ((agent-id (intent-provider i))
                 (spec (intent-resource-conforms-to i))
                 (hours (if (intent-effort-quantity i)
                            (measure-has-numerical-value (intent-effort-quantity i)) 0)))
            (set! items (hashmap-set items agent-id
              `((agent-id . ,agent-id)
                (spec-id . ,spec)
                (available-hours . ,hours))))
            (when spec
              (set! by-spec (hashmap-set by-spec spec
                              (cons agent-id (hashmap-ref by-spec spec '()))))))))
      intents)
    `((items . ,items) (by-spec . ,by-spec))))

(define (query-agents-by-spec idx spec-id)
  (filter-map (lambda (aid) (hashmap-ref (assq-ref idx 'items) aid #f))
              (hashmap-ref (assq-ref idx 'by-spec) spec-id '())))

(define (get-total-agent-hours capacities)
  (fold (lambda (c acc) (+ acc (or (assq-ref c 'available-hours) 0)))
        0 capacities))
