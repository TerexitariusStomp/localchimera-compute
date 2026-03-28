;;; resource-flows.scm — Cash flow / resource flow timeline

(use-modules (srfi srfi-1))

(define* (cash-flow-report agent-id report-start report-end observer plan-store
                          #:key (granularity 'day))
  "Build period-bucketed flow timeline for an agent.
   granularity: day | week | month.
   Returns alist: ((periods . list) (total-inflow . n) (total-outflow . n))."
  (let* ((all-events ($ observer 'all-events))
         (agent-events (filter (lambda (e)
                                 (or (equal? (economic-event-provider e) agent-id)
                                     (equal? (economic-event-receiver e) agent-id)))
                               all-events))
         ;; Bucket by period
         (bucket-key
           (lambda (iso-date)
             (case granularity
               ((day) (substring iso-date 0 10))
               ((week) (substring iso-date 0 7))  ;; simplified: YYYY-MM
               ((month) (substring iso-date 0 7))
               (else (substring iso-date 0 10)))))
         (buckets (make-hash-table))
         (total-in 0)
         (total-out 0))
    (for-each
      (lambda (e)
        (let* ((ts (or (economic-event-has-point-in-time e)
                       (economic-event-has-beginning e)
                       (economic-event-created e)))
               (in-range (and ts
                              (or (not report-start) (string>=? ts report-start))
                              (or (not report-end) (string<=? ts report-end))))
               (qty (if (economic-event-resource-quantity e)
                        (measure-has-numerical-value (economic-event-resource-quantity e))
                        0)))
          (when in-range
            (let ((key (bucket-key ts))
                  (is-inflow (equal? (economic-event-receiver e) agent-id))
                  (is-outflow (equal? (economic-event-provider e) agent-id)))
              (let ((entry (hash-ref buckets key '((inflow . 0) (outflow . 0)))))
                (hash-set! buckets key
                  `((inflow . ,(+ (assq-ref entry 'inflow) (if is-inflow qty 0)))
                    (outflow . ,(+ (assq-ref entry 'outflow) (if is-outflow qty 0))))))
              (when is-inflow (set! total-in (+ total-in qty)))
              (when is-outflow (set! total-out (+ total-out qty)))))))
      agent-events)
    `((periods . ,(sort (hash-map->list
                          (lambda (k v) `((period . ,k) ,@v))
                          buckets)
                        (lambda (a b) (string<? (assq-ref a 'period)
                                                (assq-ref b 'period)))))
      (total-inflow . ,total-in)
      (total-outflow . ,total-out)
      (net . ,(- total-in total-out)))))
