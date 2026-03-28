;;; intents.scm — Intent query index

(use-modules (srfi srfi-1) (goblins utils hashmap))

(define (build-intent-index intents)
  "Build multi-key index from intent list. Returns alist of indexes."
  (let ((items (hashmap))
        (by-spec (hashmap)) (by-action (hashmap))
        (by-agent (hashmap)) (by-plan (hashmap)))
    (for-each
      (lambda (i)
        (let ((id (intent-id i)))
          (set! items (hashmap-set items id i))
          (when (intent-resource-conforms-to i)
            (set! by-spec (hashmap-set by-spec (intent-resource-conforms-to i)
                            (cons id (hashmap-ref by-spec (intent-resource-conforms-to i) '())))))
          (set! by-action (hashmap-set by-action (intent-action i)
                            (cons id (hashmap-ref by-action (intent-action i) '()))))
          (when (intent-provider i)
            (set! by-agent (hashmap-set by-agent (intent-provider i)
                            (cons id (hashmap-ref by-agent (intent-provider i) '())))))
          (when (intent-receiver i)
            (set! by-agent (hashmap-set by-agent (intent-receiver i)
                            (cons id (hashmap-ref by-agent (intent-receiver i) '())))))
          (when (intent-planned-within i)
            (set! by-plan (hashmap-set by-plan (intent-planned-within i)
                            (cons id (hashmap-ref by-plan (intent-planned-within i) '())))))))
      intents)
    `((items . ,items) (by-spec . ,by-spec) (by-action . ,by-action)
      (by-agent . ,by-agent) (by-plan . ,by-plan))))

(define (query-intents-by-spec index spec-id)
  (filter-map (lambda (id) (hashmap-ref (assq-ref index 'items) id #f))
              (hashmap-ref (assq-ref index 'by-spec) spec-id '())))

(define (query-intents-by-action index action)
  (filter-map (lambda (id) (hashmap-ref (assq-ref index 'items) id #f))
              (hashmap-ref (assq-ref index 'by-action) action '())))

(define (query-intents-by-agent index agent-id)
  (filter-map (lambda (id) (hashmap-ref (assq-ref index 'items) id #f))
              (hashmap-ref (assq-ref index 'by-agent) agent-id '())))

(define (query-intents-by-plan index plan-id)
  (filter-map (lambda (id) (hashmap-ref (assq-ref index 'items) id #f))
              (hashmap-ref (assq-ref index 'by-plan) plan-id '())))
