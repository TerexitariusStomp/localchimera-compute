;;; account.scm — Goblins actor for commune labor-credit accounting
;;;
;;; Translated from src/lib/observation/account.ts (Commune + Account)
;;;
;;; State: pools hashmap (pool-name -> number) + accounts hashmap (agent-id -> <account>).
;;; All derived properties (welfare rate, claim capacities, etc.) are computed
;;; on the fly from these two hashmaps — no separate Account actors needed.

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (srfi srfi-1))

;; Assumes schemas.scm and store-utils.scm are loaded.


;; =========================================================================
;; Record <-> list serialization
;; =========================================================================

(define (account->list a)
  (list (account-agent-id a)
        (account-gross-contribution-credited a)
        (account-claimed-capacity a)
        (account-contribution-capacity-factor a)))

(define (list->account lst) (apply make-account lst))


;; =========================================================================
;; Derived property computations (pure functions on state)
;; =========================================================================

(define (compute-total-social-svc accounts)
  "Sum of all gross_contribution_credited across accounts."
  (hashmap-fold (lambda (_k acct acc)
                  (+ acc (account-gross-contribution-credited acct)))
                0 accounts))

(define (compute-sum-unmet-capacity accounts)
  "Sum of (1 - contribution_capacity_factor) across all accounts."
  (hashmap-fold (lambda (_k acct acc)
                  (+ acc (- 1 (account-contribution-capacity-factor acct))))
                0 accounts))

(define (compute-sum-met-capacity accounts)
  "Sum of contribution_capacity_factor across all accounts."
  (hashmap-fold (lambda (_k acct acc)
                  (+ acc (account-contribution-capacity-factor acct)))
                0 accounts))

(define (compute-welfare-allocation-rate accounts)
  "Fraction of claimable pool allocated to welfare. Self-correcting:
   0% when all CCF=1, 100% when all CCF=0."
  (let ((unmet (compute-sum-unmet-capacity accounts))
        (met (compute-sum-met-capacity accounts)))
    (if (= 0 (+ met unmet)) 0
        (/ unmet (+ met unmet)))))

(define (compute-contribution-claim acct total-svc available-pool)
  "Individual claim from work contribution."
  (if (= 0 total-svc) 0
      (* (account-gross-contribution-credited acct)
         (/ available-pool total-svc))))

(define (compute-solidarity-supplement acct welfare-fund sum-unmet)
  "Solidarity supplement for reduced-capacity members."
  (if (= 0 sum-unmet) 0
      (* (- 1 (account-contribution-capacity-factor acct))
         (/ welfare-fund sum-unmet))))

(define (compute-total-claim-capacity acct total-svc available-pool
                                      welfare-fund sum-unmet)
  "Total claim = contribution + solidarity."
  (+ (compute-contribution-claim acct total-svc available-pool)
     (compute-solidarity-supplement acct welfare-fund sum-unmet)))

(define (compute-current-potential acct total-svc available-pool
                                   welfare-fund sum-unmet)
  "Available claim capacity (total - already claimed)."
  (max 0 (- (compute-total-claim-capacity acct total-svc available-pool
                                           welfare-fund sum-unmet)
             (account-claimed-capacity acct))))


;; =========================================================================
;; ^account-store — persistent Goblins actor
;; =========================================================================

(define-actor (^account-store bcom pools accounts)
  ;; pools:    hashmap of pool-name (string) -> number (SVC value)
  ;; accounts: hashmap of agent-id (string) -> <account>

  #:portrait
  (lambda () (list pools (serialize-hashmap accounts account->list)))

  #:version 1

  #:restore
  (lambda (version sp sa)
    (case version
      ((1) (spawn ^account-store sp (deserialize-hashmap sa list->account)))
      (else (error "Unknown ^account-store version" version))))

  (methods

    ;; --- Account management ---

    ((ensure-account agent-id)
     ;; Get-or-create account. Returns agent-id.
     (if (hashmap-ref accounts agent-id #f)
         agent-id  ;; already exists, no state change
         (let ((acct (make-account agent-id 0 0 1)))
           (bcom (^account-store bcom pools
                   (hashmap-set accounts agent-id acct))
                 agent-id))))

    ((get-account agent-id)
     (hashmap-ref accounts agent-id #f))

    ((all-accounts)
     (hashmap-values accounts))

    ;; --- Contributions ---

    ((credit-from-event event)
     ;; Credit labor from a VF 'work action event.
     ;; Reads effortQuantity and adds to gross_contribution_credited.
     (if (not (eq? (economic-event-action event) 'work))
         #f  ;; no-op for non-work events
         (let* ((agent-id (or (economic-event-provider event)
                              (economic-event-receiver event)))
                (qty (and (economic-event-effort-quantity event)
                          (measure-has-numerical-value
                            (economic-event-effort-quantity event))))
                (existing (hashmap-ref accounts agent-id #f))
                (acct (or existing (make-account agent-id 0 0 1)))
                (updated (make-account
                           agent-id
                           (+ (account-gross-contribution-credited acct) (or qty 0))
                           (account-claimed-capacity acct)
                           (account-contribution-capacity-factor acct))))
           (bcom (^account-store bcom pools
                   (hashmap-set accounts agent-id updated))
                 qty))))

    ((add-contribution agent-id svc-amount)
     ;; Direct SVC credit (no VF event).
     (let* ((existing (hashmap-ref accounts agent-id #f))
            (acct (or existing (make-account agent-id 0 0 1)))
            (updated (make-account
                       agent-id
                       (+ (account-gross-contribution-credited acct) svc-amount)
                       (account-claimed-capacity acct)
                       (account-contribution-capacity-factor acct))))
       (bcom (^account-store bcom pools
               (hashmap-set accounts agent-id updated)))))

    ;; --- Claims ---

    ((claim-goods agent-id svc-cost)
     ;; Claim goods from the communal pool. Returns #t on success, #f if insufficient.
     (let* ((acct (hashmap-ref accounts agent-id #f)))
       (if (not acct) #f
           (let* ((pool-svc (hashmap-ref pools "individual-claimable" 0))
                  (total-svc (compute-total-social-svc accounts))
                  (welfare-rate (compute-welfare-allocation-rate accounts))
                  (welfare-fund (* pool-svc welfare-rate))
                  (available-pool (- pool-svc welfare-fund))
                  (sum-unmet (compute-sum-unmet-capacity accounts))
                  (potential (compute-current-potential
                               acct total-svc available-pool welfare-fund sum-unmet)))
             ;; For actual claim capacity, we need elastic share
             ;; actual = share × claimable_pool
             (let* ((total-potential
                      (hashmap-fold
                        (lambda (_k a acc)
                          (+ acc (compute-current-potential
                                   a total-svc available-pool welfare-fund sum-unmet)))
                        0 accounts))
                    (share (if (= 0 total-potential) 0
                               (/ potential total-potential)))
                    (actual (* share pool-svc)))
               (if (< actual svc-cost)
                   #f  ;; insufficient capacity
                   (let* ((new-acct (make-account
                                      agent-id
                                      (account-gross-contribution-credited acct)
                                      (+ (account-claimed-capacity acct) svc-cost)
                                      (account-contribution-capacity-factor acct)))
                          (new-pool (- (hashmap-ref pools "individual-claimable" 0) svc-cost)))
                     (bcom (^account-store bcom
                             (hashmap-set pools "individual-claimable" new-pool)
                             (hashmap-set accounts agent-id new-acct))
                           #t))))))))

    ;; --- Pool management ---

    ((add-to-pool pool-name svc-value)
     (let ((current (hashmap-ref pools pool-name 0)))
       (bcom (^account-store bcom
               (hashmap-set pools pool-name (+ current svc-value))
               accounts))))

    ((get-pool-svc pool-name)
     (hashmap-ref pools pool-name 0))

    ;; --- Derived queries ---

    ((total-social-svc)
     (compute-total-social-svc accounts))

    ((welfare-allocation-rate)
     (compute-welfare-allocation-rate accounts))

    ((available-claimable-pool)
     (let* ((pool-svc (hashmap-ref pools "individual-claimable" 0))
            (welfare-rate (compute-welfare-allocation-rate accounts)))
       (- pool-svc (* pool-svc welfare-rate))))

    ((account-claim-capacity agent-id)
     ;; Return the current actual claim capacity for an agent.
     (let* ((acct (hashmap-ref accounts agent-id #f)))
       (if (not acct) 0
           (let* ((pool-svc (hashmap-ref pools "individual-claimable" 0))
                  (total-svc (compute-total-social-svc accounts))
                  (welfare-rate (compute-welfare-allocation-rate accounts))
                  (welfare-fund (* pool-svc welfare-rate))
                  (available-pool (- pool-svc welfare-fund))
                  (sum-unmet (compute-sum-unmet-capacity accounts))
                  (potential (compute-current-potential
                               acct total-svc available-pool welfare-fund sum-unmet))
                  (total-potential
                    (hashmap-fold
                      (lambda (_k a acc)
                        (+ acc (compute-current-potential
                                 a total-svc available-pool welfare-fund sum-unmet)))
                      0 accounts))
                  (share (if (= 0 total-potential) 0 (/ potential total-potential))))
             (* share pool-svc)))))))


;; =========================================================================
;; Persistence environment
;; =========================================================================

(define account-store-env
  (make-persistence-env
    `((((vf observation) ^account-store) ,^account-store))))
