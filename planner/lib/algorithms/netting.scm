;;; netting.scm — PlanNetter: pure state monad for soft-allocation
;;;
;;; The netter tracks which inventory and scheduled flows have been claimed
;;; (soft-allocated) during a planning pass, preventing double-counting.
;;;
;;; Architecture: State Monad.
;;;   Each operation: (netter-state, args) -> (values new-state result)
;;;   fork = identity (immutable state = free fork)
;;;   retract = restore a saved state value
;;;
;;; The netter state is an immutable record containing two hashmaps.
;;; No mutation, no closures, no set!.

;; Assumes schemas.scm, store-utils.scm, signals.scm are loaded.

(use-modules (srfi srfi-1)
             (srfi srfi-9)
             (srfi srfi-11)
             (goblins utils hashmap))

(define *non-consuming-actions-net* '(use work cite deliver-service))

(define (planning-signal? tags)
  (and tags (any (lambda (t) (string-prefix? "tag:plan:" t)) tags)))


;; ═════════════════════════════════════════════════════════════════════════
;; Netter state — immutable record
;; ═════════════════════════════════════════════════════════════════════════

(define-record-type <netter-state>
  (make-netter-state allocated claimed-by-plan conservation-floors)
  netter-state?
  (allocated           ns-allocated)           ;; hashmap of flow-id -> #t
  (claimed-by-plan     ns-claimed-by-plan)     ;; hashmap of plan-id -> list of flow-ids
  (conservation-floors ns-conservation-floors)) ;; hashmap of spec-id -> min-qty

(define* (empty-netter-state #:optional (floors (hashmap)))
  (make-netter-state (hashmap) (hashmap) floors))


;; ═════════════════════════════════════════════════════════════════════════
;; Internal helpers (pure)
;; ═════════════════════════════════════════════════════════════════════════

(define (ns-allocated? ns id)
  (hashmap-ref (ns-allocated ns) id #f))

(define (ns-allocate ns id)
  "Return new netter-state with id marked as allocated."
  (make-netter-state
    (hashmap-set (ns-allocated ns) id #t)
    (ns-claimed-by-plan ns)
    (ns-conservation-floors ns)))

(define (ns-allocate+track ns id plan-id)
  "Allocate and track under a plan ID."
  (let* ((new-alloc (hashmap-set (ns-allocated ns) id #t))
         (existing (hashmap-ref (ns-claimed-by-plan ns) plan-id '()))
         (new-claims (hashmap-set (ns-claimed-by-plan ns) plan-id
                                  (cons id existing))))
    (make-netter-state new-alloc new-claims (ns-conservation-floors ns))))


;; ═════════════════════════════════════════════════════════════════════════
;; net-demand: (ns, stores, args) -> (values ns remaining allocated-pairs)
;; ═════════════════════════════════════════════════════════════════════════

(define* (netter-net-demand ns plan-store observer spec-id qty
                            #:key (at-location #f) (contained-in #f)
                                  (stage #f) (state #f) (needed-by #f)
                                  (plan-id #f) (location-store #f))
  "Net demand against inventory + scheduled outputs. Pure state operation.
   Returns (values new-ns remaining allocated-pairs)."
  (let ((remaining qty)
        (inventory-allocated '())
        (current-ns ns)
        (floor (hashmap-ref (ns-conservation-floors ns) spec-id 0)))

    ;; Step 1: Observer inventory
    (when observer
      (let ((resources ($ observer 'conforming-resources spec-id)))
        (for-each
          (lambda (r)
            (when (> remaining *epsilon-pu*)
              (let* ((acct-qty (measure-qty (economic-resource-accounting-quantity r)))
                     (pass-contain (if contained-in
                                       (equal? (economic-resource-contained-in r) contained-in)
                                       (not (economic-resource-contained-in r))))
                     (pass-loc (or (not at-location)
                                   (equal? (economic-resource-current-location r) at-location)
                                   (and location-store
                                        ($ location-store 'is-descendant-or-equal
                                           (economic-resource-current-location r) at-location))))
                     (pass-stage (or (not stage) (equal? (economic-resource-stage r) stage)))
                     (pass-state (or (not state) (equal? (economic-resource-state r) state))))
                (when (and (> acct-qty 0) pass-contain pass-loc pass-stage pass-state)
                  (let* ((allocatable (max 0 (- acct-qty floor)))
                         (take (min allocatable remaining)))
                    (when (> take *epsilon-pu*)
                      (set! inventory-allocated
                        (cons (list (economic-resource-id r) spec-id take)
                              inventory-allocated))
                      (set! remaining (- remaining take))))))))
          resources)))

    ;; Step 2: Scheduled output intents
    (when (and (not contained-in) (> remaining *epsilon-pu*))
      (let ((intents ($ plan-store 'intents-for-spec spec-id)))
        (for-each
          (lambda (i)
            (when (and (> remaining *epsilon-pu*)
                       (intent-output-of i)
                       (not (intent-finished i))
                       (not (ns-allocated? current-ns (intent-id i)))
                       (not (planning-signal? (intent-resource-classified-as i)))
                       (intent-resource-quantity i))
              (let* ((iqty (measure-has-numerical-value (intent-resource-quantity i)))
                     (pass-time (or (not needed-by) (not (intent-due i))
                                    (<= (iso-datetime->epoch (intent-due i)) needed-by)))
                     (pass-loc (or (not at-location)
                                   (equal? (intent-at-location i) at-location)
                                   (and location-store (intent-at-location i)
                                        ($ location-store 'is-descendant-or-equal
                                           (intent-at-location i) at-location)))))
                (when (and (> iqty 0) pass-time pass-loc)
                  (let ((take (min iqty remaining)))
                    (set! current-ns
                      (if plan-id
                          (ns-allocate+track current-ns (intent-id i) plan-id)
                          (ns-allocate current-ns (intent-id i))))
                    (set! remaining (- remaining take)))))))
          intents)))

    ;; Step 3: Scheduled output commitments
    (when (and (not contained-in) (> remaining *epsilon-pu*))
      (let ((commitments ($ plan-store 'commitments-for-spec spec-id)))
        (for-each
          (lambda (c)
            (when (and (> remaining *epsilon-pu*)
                       (commitment-output-of c)
                       (not (commitment-finished c))
                       (not (ns-allocated? current-ns (commitment-id c)))
                       (commitment-resource-quantity c))
              (let* ((cqty (measure-has-numerical-value (commitment-resource-quantity c)))
                     (pass-time (or (not needed-by) (not (commitment-due c))
                                    (<= (iso-datetime->epoch (commitment-due c)) needed-by)))
                     (pass-loc (or (not at-location)
                                   (equal? (commitment-at-location c) at-location)
                                   (and location-store (commitment-at-location c)
                                        ($ location-store 'is-descendant-or-equal
                                           (commitment-at-location c) at-location)))))
                (when (and (> cqty 0) pass-time pass-loc)
                  (let ((take (min cqty remaining)))
                    (set! current-ns
                      (if plan-id
                          (ns-allocate+track current-ns (commitment-id c) plan-id)
                          (ns-allocate current-ns (commitment-id c))))
                    (set! remaining (- remaining take)))))))
          commitments)))

    (values current-ns remaining (reverse inventory-allocated))))


;; ═════════════════════════════════════════════════════════════════════════
;; net-supply: (ns, stores, args) -> (values ns remaining)
;; ═════════════════════════════════════════════════════════════════════════

(define* (netter-net-supply ns plan-store spec-id qty
                            #:key (available-from #f) (at-location #f)
                                  (location-store #f))
  "Deduct pre-claimed consuming flows from supply quantity.
   Returns (values new-ns remaining)."
  (let ((remaining qty)
        (current-ns ns))
    (let ((intents ($ plan-store 'intents-for-spec spec-id)))
      (for-each
        (lambda (i)
          (when (and (> remaining *epsilon-pu*)
                     (intent-input-of i)
                     (not (intent-finished i))
                     (not (ns-allocated? current-ns (intent-id i)))
                     (not (memq (intent-action i) *non-consuming-actions-net*))
                     (intent-resource-quantity i))
            (let* ((iqty (measure-has-numerical-value (intent-resource-quantity i)))
                   (pass-time (or (not available-from) (not (intent-due i))
                                  (>= (iso-datetime->epoch (intent-due i)) available-from)))
                   (pass-loc (or (not at-location)
                                 (equal? (intent-at-location i) at-location)
                                 (and location-store (intent-at-location i)
                                      ($ location-store 'is-descendant-or-equal
                                         (intent-at-location i) at-location)))))
              (when (and (> iqty 0) pass-time pass-loc)
                (let ((take (min iqty remaining)))
                  (set! current-ns (ns-allocate current-ns (intent-id i)))
                  (set! remaining (- remaining take)))))))
        intents))
    (values current-ns remaining)))


;; ═════════════════════════════════════════════════════════════════════════
;; retract: restore netter state by removing a plan's claims
;; ═════════════════════════════════════════════════════════════════════════

(define (netter-retract ns plan-id)
  "Remove all allocations made under plan-id. Returns new netter-state."
  (let* ((claims (hashmap-ref (ns-claimed-by-plan ns) plan-id '()))
         (new-alloc (fold (lambda (id hm) (hashmap-remove hm id))
                          (ns-allocated ns) claims))
         (new-claims (hashmap-remove (ns-claimed-by-plan ns) plan-id)))
    (make-netter-state new-alloc new-claims (ns-conservation-floors ns))))


;; ═════════════════════════════════════════════════════════════════════════
;; fork: free! immutable state = identity
;; ═════════════════════════════════════════════════════════════════════════

(define (netter-fork ns)
  "Fork the netter. Returns the same state (immutable = free fork)."
  ns)


;; ═════════════════════════════════════════════════════════════════════════
;; reserve: pre-claim capacity for buffer replenishment (Pass 0)
;; ═════════════════════════════════════════════════════════════════════════

(define* (netter-reserve ns plan-store observer spec-id qty
                         #:key (plan-id #f) (location-store #f))
  "Reserve capacity for buffer replenishment. Claims inventory + scheduled
   outputs up to qty. Returns (values new-ns actually-reserved)."
  (let-values (((new-ns remaining _alloc)
                (netter-net-demand ns plan-store observer spec-id qty
                  #:plan-id plan-id #:location-store location-store)))
    (values new-ns (- qty remaining))))


;; ═════════════════════════════════════════════════════════════════════════
;; net-available: query available quantity without claiming
;; ═════════════════════════════════════════════════════════════════════════

(define* (netter-net-available ns plan-store observer spec-id
                               #:key (at-location #f) (location-store #f))
  "Return available quantity for a spec (inventory + scheduled - floor).
   Does NOT modify netter state."
  ;; Net against a huge quantity to find how much is available
  (let-values (((_ns remaining _alloc)
                (netter-net-demand ns plan-store observer spec-id 999999999
                  #:at-location at-location #:location-store location-store)))
    (- 999999999 remaining)))
