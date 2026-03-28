;;; metabolism.scm — Metabolic balance: net input/output accounting

(use-modules (srfi srfi-1) (goblins utils hashmap))

(define *input-actions* '(consume use work accept pickup))
(define *output-actions* '(produce modify deliver-service dropoff))

(define* (metabolic-balance events horizon-from horizon-to
                           #:key (market-prices (hashmap)))
  "Net balance = total-output - total-input (value-weighted).
   Returns alist: ((net-balance . n) (total-input . n) (total-output . n)
                    (by-spec . alist))."
  (let ((by-spec (make-hash-table))
        (total-input 0)
        (total-output 0))
    (for-each
      (lambda (e)
        (let* ((ts (or (economic-event-has-point-in-time e)
                       (economic-event-has-beginning e)))
               (in-range (or (not ts)
                             (and (or (not horizon-from) (string>=? ts horizon-from))
                                  (or (not horizon-to) (string<=? ts horizon-to)))))
               (action (economic-event-action e))
               (spec (economic-event-resource-conforms-to e))
               (qty (if (economic-event-resource-quantity e)
                        (measure-has-numerical-value (economic-event-resource-quantity e)) 0))
               (price (if spec (hashmap-ref market-prices spec 1) 1))
               (value (* qty price)))
          (when in-range
            (cond
              ((memq action *input-actions*)
               (set! total-input (+ total-input value))
               (when spec
                 (let ((entry (hash-ref by-spec spec '((input . 0) (output . 0)))))
                   (hash-set! by-spec spec
                     `((input . ,(+ (assq-ref entry 'input) value))
                       (output . ,(assq-ref entry 'output)))))))
              ((memq action *output-actions*)
               (set! total-output (+ total-output value))
               (when spec
                 (let ((entry (hash-ref by-spec spec '((input . 0) (output . 0)))))
                   (hash-set! by-spec spec
                     `((input . ,(assq-ref entry 'input))
                       (output . ,(+ (assq-ref entry 'output) value)))))))))))
      events)
    `((net-balance . ,(- total-output total-input))
      (total-input . ,total-input)
      (total-output . ,total-output)
      (by-spec . ,(hash-map->list cons by-spec)))))
