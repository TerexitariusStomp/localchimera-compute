;;; schedule-book.scm — Per-entity schedule queries

(use-modules (srfi srfi-1))

(define (schedule-blocks-for entity-id plan-store . rest)
  "All commitment/intent blocks for an entity (resource, agent, process).
   Returns list of alists with flow details."
  (let ((all-commits ($ plan-store 'all-commitments))
        (all-intents ($ plan-store 'all-intents)))
    (append
      (filter-map
        (lambda (c)
          (and (or (equal? (commitment-provider c) entity-id)
                   (equal? (commitment-receiver c) entity-id)
                   (equal? (commitment-input-of c) entity-id)
                   (equal? (commitment-output-of c) entity-id)
                   (equal? (commitment-resource-inventoried-as c) entity-id))
               `((type . commitment) (id . ,(commitment-id c))
                 (action . ,(commitment-action c))
                 (due . ,(commitment-due c))
                 (qty . ,(and (commitment-resource-quantity c)
                              (measure-has-numerical-value (commitment-resource-quantity c)))))))
        all-commits)
      (filter-map
        (lambda (i)
          (and (or (equal? (intent-provider i) entity-id)
                   (equal? (intent-receiver i) entity-id)
                   (equal? (intent-input-of i) entity-id)
                   (equal? (intent-output-of i) entity-id)
                   (equal? (intent-resource-inventoried-as i) entity-id))
               `((type . intent) (id . ,(intent-id i))
                 (action . ,(intent-action i))
                 (due . ,(intent-due i))
                 (qty . ,(and (intent-resource-quantity i)
                              (measure-has-numerical-value (intent-resource-quantity i)))))))
        all-intents))))

(define (committed-effort-on agent-id date-str plan-store)
  "Sum effort hours from work commitments on a given date (YYYY-MM-DD)."
  (let ((commits ($ plan-store 'all-commitments)))
    (fold (lambda (c acc)
            (if (and (eq? (commitment-action c) 'work)
                     (or (equal? (commitment-provider c) agent-id)
                         (equal? (commitment-receiver c) agent-id))
                     (commitment-due c)
                     (equal? (substring (commitment-due c) 0 10) date-str)
                     (commitment-effort-quantity c))
                (+ acc (measure-has-numerical-value (commitment-effort-quantity c)))
                acc))
          0 commits)))

(define (has-use-conflict resource-id from-epoch to-epoch plan-store)
  "Check if a 'use' flow overlaps [from, to)."
  (let ((blocks (schedule-blocks-for resource-id plan-store)))
    (any (lambda (b)
           (and (eq? (assq-ref b 'action) 'use)
                (assq-ref b 'due)
                ;; Simplified overlap check: block's due is within [from, to)
                (let ((block-epoch (iso-datetime->epoch (assq-ref b 'due))))
                  (and (>= block-epoch from-epoch) (< block-epoch to-epoch)))))
         blocks)))
