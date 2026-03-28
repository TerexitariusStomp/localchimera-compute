;;; custody.scm — Custody protocol: entrustment limits, penalties, tranches
;;;
;;; State machine for resource custody tracking. The ledger is an alist-based
;;; mutable structure (used within a single turn, like the netter).

(use-modules (srfi srfi-1) (goblins utils hashmap))

;; ═════════════════════════════════════════════════════════════════════════
;; Custody ledger
;; ═════════════════════════════════════════════════════════════════════════

(define (make-custody-ledger)
  "Create empty custody ledger. Mutable hash-tables (turn-local)."
  (let ((records (make-hash-table))    ;; resource-id -> custody-record
        (by-agent (make-hash-table)))  ;; agent-id -> list of resource-ids
    `((records . ,records) (by-agent . ,by-agent))))

(define (ledger-records ledger) (assq-ref ledger 'records))
(define (ledger-by-agent ledger) (assq-ref ledger 'by-agent))

;; ═════════════════════════════════════════════════════════════════════════
;; Entrustment limit calculation
;; ═════════════════════════════════════════════════════════════════════════

(define* (entrustment-limit total-claim-capacity svc-market-equivalent
                           #:optional (alpha 0.5))
  "entrustment_limit[i] = alpha * total_claim_capacity * svc_market_equivalent."
  (* alpha total-claim-capacity svc-market-equivalent))

(define (incentive-compatible value-accessible-solo n-colluders-required
                              individual-entrustment-limit)
  "Theft-irrationality check: (value / n) < limit."
  (< (/ value-accessible-solo n-colluders-required)
     individual-entrustment-limit))

(define (custody-level value hierarchy)
  "Find minimum hierarchy level that covers the value.
   hierarchy: list of (level . entrustment-limit) alists, sorted ascending.
   Returns level or #f."
  (let ((found (find (lambda (h) (>= (cdr h) value)) hierarchy)))
    (and found (car found))))

;; ═════════════════════════════════════════════════════════════════════════
;; State machine transitions
;; ═════════════════════════════════════════════════════════════════════════

(define (apply-transfer-custody event market-value ledger)
  "Transition: provider releases, receiver acquires custody. Returns #t on success."
  (if (not (eq? (economic-event-action event) 'transfer-custody)) #f
      (let* ((rid (or (economic-event-resource-inventoried-as event)
                      (economic-event-to-resource-inventoried-as event)))
             (prov (economic-event-provider event))
             (recv (economic-event-receiver event))
             (records (ledger-records ledger))
             (by-agent (ledger-by-agent ledger)))
        (when rid
          ;; Release from provider
          (when prov
            (hash-set! by-agent prov
              (delete rid (hash-ref by-agent prov '()))))
          ;; Acquire by receiver
          (when recv
            (hash-set! by-agent recv
              (cons rid (hash-ref by-agent recv '()))))
          ;; Update record
          (hash-set! records rid
            `((resource-id . ,rid) (status . held) (holder . ,recv)
              (market-value . ,market-value) (pending-penalty . 0))))
        #t)))

(define (settle-custody resource-id releasing-agent-id market-value ledger)
  "Mark resource settled (consumed/destroyed), release provider liability."
  (let ((records (ledger-records ledger))
        (by-agent (ledger-by-agent ledger)))
    (if (not (hash-ref records resource-id #f)) #f
        (begin
          (hash-set! by-agent releasing-agent-id
            (delete resource-id (hash-ref by-agent releasing-agent-id '())))
          (hash-set! records resource-id
            `((resource-id . ,resource-id) (status . settled)
              (holder . #f) (market-value . ,market-value) (pending-penalty . 0)))
          #t))))

(define (current-custodian resource-id ledger)
  "Who currently holds the resource? Returns agent-id or #f."
  (let ((rec (hash-ref (ledger-records ledger) resource-id #f)))
    (and rec (equal? (assq-ref rec 'status) 'held) (assq-ref rec 'holder))))

(define (held-by agent-id ledger)
  "All resources currently held by agent."
  (filter-map
    (lambda (rid)
      (let ((rec (hash-ref (ledger-records ledger) rid #f)))
        (and rec (equal? (assq-ref rec 'status) 'held) rec)))
    (hash-ref (ledger-by-agent ledger) agent-id '())))

;; ═════════════════════════════════════════════════════════════════════════
;; Penalties & tranches
;; ═════════════════════════════════════════════════════════════════════════

(define (penalty-svc missing-value svc-market-equivalent total-claim-capacity)
  "penalty = min(missing / svc_equiv, total_claim_capacity)."
  (min (if (> svc-market-equivalent 0) (/ missing-value svc-market-equivalent) 0)
       total-claim-capacity))

(define (apply-penalty record penalty-amount)
  "Accumulate penalty. Returns applied amount."
  (let ((current (or (assq-ref record 'pending-penalty) 0)))
    (set-cdr! (assq 'pending-penalty record) (+ current penalty-amount))
    penalty-amount))

(define (tranche-coverage loss-value tranches)
  "Distribute loss through ordered tranches. Returns list of (level absorbed remaining)."
  (let loop ((ts tranches) (remaining loss-value) (result '()))
    (if (or (null? ts) (<= remaining 0))
        (reverse result)
        (let* ((t (car ts))
               (level (assq-ref t 'level))
               (pool (assq-ref t 'pool))
               (absorbed (min pool remaining)))
          (loop (cdr ts) (- remaining absorbed)
                (cons `((level . ,level) (absorbed . ,absorbed)
                        (remaining . ,(- remaining absorbed)))
                      result))))))

(define* (scope-entrustment-capacity member-records total-claim-capacities
                                     svc-market-equivalent #:optional (alpha 0.5))
  "Aggregate individual entrustment limits for a scope."
  (fold (lambda (rec acc)
          (let* ((agent-id (assq-ref rec 'holder))
                 (cap (if agent-id (hash-ref total-claim-capacities agent-id 0) 0)))
            (+ acc (entrustment-limit cap svc-market-equivalent alpha))))
        0 member-records))

(define (check-ownership-invariant resources universal-commune-id)
  "Returns communal resources violating UC ownership (accountable != commune)."
  (filter (lambda (r)
            (and (economic-resource-classified-as r)
                 (member "communal" (economic-resource-classified-as r))
                 (not (equal? (economic-resource-primary-accountable r) universal-commune-id))))
          resources))

(define (build-custody-ledger events . rest)
  "Rebuild ledger from event history."
  (let ((market-values (if (pair? rest) (car rest) (make-hash-table)))
        (ledger (make-custody-ledger)))
    (for-each
      (lambda (e)
        (when (eq? (economic-event-action e) 'transfer-custody)
          (let ((mv (or (economic-event-market-value e)
                        (hash-ref market-values (economic-event-id e) 0))))
            (apply-transfer-custody e mv ledger))))
      events)
    ledger))
