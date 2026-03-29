;;; demand-policy.scm — Demand derivation policies for communal planning

(use-modules (srfi srfi-1))

(define (derive-dependent-demand policy dependent-total independent-total)
  "Compute derived demand quantity based on policy type.
   policy: alist with 'factor-type ('replenishment-rate | 'buffer-fraction | 'fixed)
           and 'rate or 'fixed-qty.
   Returns alist: ((qty . n) (formula . string))."
  (let ((factor-type (assq-ref policy 'factor-type))
        (rate (or (assq-ref policy 'rate) 0))
        (fixed (or (assq-ref policy 'fixed-qty) 0)))
    (case factor-type
      ((replenishment-rate)
       `((qty . ,(* rate dependent-total))
         (formula . ,(format #f "~a * ~a (replenishment)" rate dependent-total))))
      ((buffer-fraction)
       `((qty . ,(* rate independent-total))
         (formula . ,(format #f "~a * ~a (buffer fraction)" rate independent-total))))
      ((fixed)
       `((qty . ,fixed)
         (formula . ,(format #f "fixed: ~a" fixed))))
      (else
       `((qty . 0) (formula . "unknown policy type"))))))

(define (derive-communal-demand policies member-count)
  "Expand per-member policies into demand entries.
   policies: list of alists with 'spec-id, 'mode ('per-member | 'fixed),
             'qty-per-member or 'fixed-qty, 'unit.
   Returns list of demand entry alists."
  (filter-map
    (lambda (p)
      (let* ((mode (assq-ref p 'mode))
             (spec (assq-ref p 'spec-id))
             (unit (or (assq-ref p 'unit) "each"))
             (qty (case mode
                    ((per-member) (* (or (assq-ref p 'qty-per-member) 0) member-count))
                    ((fixed) (or (assq-ref p 'fixed-qty) 0))
                    (else 0))))
        (and (> qty 0)
             `((spec-id . ,spec)
               (qty . ,qty)
               (unit . ,unit)
               (formula . ,(case mode
                             ((per-member) (format #f "~a * ~a members"
                                            (assq-ref p 'qty-per-member) member-count))
                             ((fixed) (format #f "fixed: ~a" qty))
                             (else "?")))))))
    policies))
