;;; rollup.scm — Cost rollup: standard (from recipe) and actual (from events)

(use-modules (srfi srfi-1))

(define* (rollup-standard-cost recipe-id recipe-store
                               #:key (price-of (lambda (spec unit) 0))
                                     (scale-factor 1))
  "Standard cost from recipe: sum input values per stage.
   price-of: (spec-id unit) -> price-per-unit.
   Returns alist: ((total . n) (by-stage . list))."
  (let* ((chain ($ recipe-store 'get-process-chain recipe-id)))
    (let ((stages
            (map (lambda (rp)
                   (let* ((pid (recipe-process-id rp))
                          (flows ($ recipe-store 'flows-for-process pid))
                          (inputs (car flows))
                          (stage-cost
                            (fold (lambda (f acc)
                                    (let* ((spec (recipe-flow-resource-conforms-to f))
                                           (rq (recipe-flow-resource-quantity f))
                                           (qty (if rq (* (measure-has-numerical-value rq) scale-factor) 0))
                                           (unit (if rq (measure-has-unit rq) "each"))
                                           (price (if spec (price-of spec unit) 0)))
                                      (+ acc (* qty price))))
                                  0 inputs)))
                     `((process-id . ,pid) (name . ,(recipe-process-name rp))
                       (cost . ,stage-cost))))
                 chain)))
      `((total . ,(fold (lambda (s acc) (+ acc (assq-ref s 'cost))) 0 stages))
        (by-stage . ,stages)))))

(define* (rollup-actual-cost resource-id observer
                             #:key (price-of (lambda (spec unit) 0)))
  "Actual cost from recorded events: trace backward, sum input values.
   Returns alist: ((total . n) (by-event . list))."
  (let* ((events ($ observer 'events-for-resource resource-id))
         ;; Filter to consuming inputs
         (input-events (filter (lambda (e)
                                 (memq (economic-event-action e) '(consume use work cite)))
                               events))
         (entries
           (map (lambda (e)
                  (let* ((spec (economic-event-resource-conforms-to e))
                         (rq (economic-event-resource-quantity e))
                         (eq (economic-event-effort-quantity e))
                         (qty (cond (rq (measure-has-numerical-value rq))
                                    (eq (measure-has-numerical-value eq))
                                    (else 0)))
                         (unit (cond (rq (measure-has-unit rq))
                                     (eq (measure-has-unit eq))
                                     (else "each")))
                         (price (if spec (price-of spec unit) 0)))
                    `((event-id . ,(economic-event-id e))
                      (spec-id . ,spec) (qty . ,qty) (cost . ,(* qty price)))))
                input-events)))
    `((total . ,(fold (lambda (entry acc) (+ acc (assq-ref entry 'cost))) 0 entries))
      (by-event . ,entries))))

(define (cost-variance standard actual)
  "variance = standard - actual (positive = under budget)."
  (let ((std (assq-ref standard 'total))
        (act (assq-ref actual 'total)))
    `((variance . ,(- std act))
      (variance-pct . ,(if (> std 0) (* (/ (- std act) std) 100) 0)))))
