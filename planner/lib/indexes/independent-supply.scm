;;; independent-supply.scm — Supply index from inventory + scheduled outputs

(use-modules (srfi srfi-1) (goblins utils hashmap))

(define (build-independent-supply-index resources intents)
  "Build supply index from on-hand inventory + scheduled output intents.
   Capacity resources (unit-of-effort set) are excluded — they represent
   agent time budgets, not material inventory.
   Returns alist of indexes."
  (let ((supply (hashmap)) (by-spec (hashmap)) (by-scope (hashmap))
        (counter 0))
    ;; Inventory slots from resources (skip capacity resources)
    (for-each
      (lambda (r)
        (let ((qty (measure-qty (economic-resource-onhand-quantity r))))
          (when (and (> qty 0)
                     (not (economic-resource-unit-of-effort r)))
            (let ((id (string-append "inv:" (economic-resource-id r))))
              (set! supply (hashmap-set supply id
                `((id . ,id) (slot-type . inventory)
                  (spec-id . ,(economic-resource-conforms-to r))
                  (quantity . ,qty)
                  (at-location . ,(economic-resource-current-location r)))))
              (when (economic-resource-conforms-to r)
                (set! by-spec (hashmap-set by-spec (economic-resource-conforms-to r)
                                (cons id (hashmap-ref by-spec (economic-resource-conforms-to r) '())))))))))
      resources)
    ;; Scheduled supply from output intents (provider, not finished)
    (for-each
      (lambda (i)
        (when (and (not (intent-finished i))
                   (intent-provider i)
                   (intent-output-of i)
                   (intent-resource-quantity i)
                   (> (measure-has-numerical-value (intent-resource-quantity i)) 0))
          (let ((id (string-append "sched:" (intent-id i))))
            (set! supply (hashmap-set supply id
              `((id . ,id) (slot-type . scheduled)
                (spec-id . ,(intent-resource-conforms-to i))
                (quantity . ,(measure-has-numerical-value (intent-resource-quantity i)))
                (available-from . ,(intent-due i))
                (at-location . ,(intent-at-location i)))))
            (when (intent-resource-conforms-to i)
              (set! by-spec (hashmap-set by-spec (intent-resource-conforms-to i)
                              (cons id (hashmap-ref by-spec (intent-resource-conforms-to i) '()))))))))
      intents)
    `((supply . ,supply) (by-spec . ,by-spec) (by-scope . ,by-scope))))

(define (query-supply-by-spec idx id)
  (filter-map (lambda (sid) (hashmap-ref (assq-ref idx 'supply) sid #f))
              (hashmap-ref (assq-ref idx 'by-spec) id '())))
(define (get-total-supply-quantity slots)
  (fold (lambda (s acc) (+ acc (or (assq-ref s 'quantity) 0))) 0 slots))
