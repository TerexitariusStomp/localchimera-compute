;;; observer.scm — Goblins actor for the VF event-sourced stockbook
;;;
;;; Architecture: The Observer is a FOLD.
;;;
;;;   observer-record-event : (state, event) -> (state, affected)
;;;
;;; Each event is folded over the observer state through a pipeline of
;;; five pure phases:
;;;
;;;   1. phase-append-event     — prepend event to log
;;;   2. phase-index-event      — update lookup indexes
;;;   3. phase-apply-effects    — VF action effects on resources
;;;   4. phase-implied-transfer — cross-agent rights transfer
;;;   5. phase-track            — fulfillment/satisfaction/settlement
;;;
;;; The actor's bcom IS the fold's commit step. Each message delivery
;;; is one fold iteration; bcom commits the new accumulator.

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (srfi srfi-1)
             (srfi srfi-9)
             (ice-9 match))

;; Assumes schemas.scm and store-utils.scm are loaded.


;; ═════════════════════════════════════════════════════════════════════════
;; Observer state + functional updaters
;; ═════════════════════════════════════════════════════════════════════════

(define-record-type <observer-state>
  (make-observer-state events resources fulfillments satisfactions
                       claim-states idx-by-resource idx-by-process
                       idx-by-agent idx-by-action events-by-id
                       idx-by-spec agreements batches resource-batches)
  observer-state?
  (events          os-events)
  (resources       os-resources)
  (fulfillments    os-fulfillments)
  (satisfactions   os-satisfactions)
  (claim-states    os-claim-states)
  (idx-by-resource os-idx-by-resource)
  (idx-by-process  os-idx-by-process)
  (idx-by-agent    os-idx-by-agent)
  (idx-by-action   os-idx-by-action)
  (events-by-id    os-events-by-id)
  (idx-by-spec     os-idx-by-spec)       ;; spec-id -> list of resource-ids
  (agreements      os-agreements)         ;; agreement-id -> agreement alist
  (batches         os-batches)            ;; batch-id -> <batch-lot-record>
  (resource-batches os-resource-batches)) ;; resource-id -> list of batch-ids

(define (empty-observer-state)
  (make-observer-state
    '() (hashmap) (hashmap) (hashmap) (hashmap)
    (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
    (hashmap) (hashmap) (hashmap) (hashmap)))

;; Single-field updaters — eliminates 14-field reconstruction boilerplate
;; Each passes through all other fields unchanged.
(define* (os-rebuild st #:key (events #f) (resources #f) (fulfillments #f)
                          (satisfactions #f) (claim-states #f)
                          (ibr #f) (ibp #f) (iba #f) (ibact #f) (ebi #f)
                          (ibs #f) (agreements #f) (batches #f) (rb #f))
  "Functional update helper — pass keyword args to override fields."
  (make-observer-state
    (or events (os-events st)) (or resources (os-resources st))
    (or fulfillments (os-fulfillments st)) (or satisfactions (os-satisfactions st))
    (or claim-states (os-claim-states st))
    (or ibr (os-idx-by-resource st)) (or ibp (os-idx-by-process st))
    (or iba (os-idx-by-agent st)) (or ibact (os-idx-by-action st))
    (or ebi (os-events-by-id st)) (or ibs (os-idx-by-spec st))
    (or agreements (os-agreements st)) (or batches (os-batches st))
    (or rb (os-resource-batches st))))

;; Convenience single-field updaters
(define (os-set-events st v)        (os-rebuild st #:events v))
(define (os-set-resources st v)     (os-rebuild st #:resources v))
(define (os-set-fulfillments st v)  (os-rebuild st #:fulfillments v))
(define (os-set-satisfactions st v) (os-rebuild st #:satisfactions v))
(define (os-set-claim-states st v)  (os-rebuild st #:claim-states v))
(define (os-set-agreements st v)    (os-rebuild st #:agreements v))
(define (os-set-batches st bv rbv)  (os-rebuild st #:batches bv #:rb rbv))
(define (os-set-indexes st ibr ibp iba ibact ebi)
  (os-rebuild st #:ibr ibr #:ibp ibp #:iba iba #:ibact ibact #:ebi ebi))


;; ═════════════════════════════════════════════════════════════════════════
;; Fold context: state + affected-resources accumulator
;; ═════════════════════════════════════════════════════════════════════════

(define-record-type <fold-ctx>
  (make-fold-ctx state affected)
  fold-ctx?
  (state    ctx-state)
  (affected ctx-affected))

(define (ctx-update-state ctx f)
  (make-fold-ctx (f (ctx-state ctx)) (ctx-affected ctx)))


;; ═════════════════════════════════════════════════════════════════════════
;; Quantity helpers
;; ═════════════════════════════════════════════════════════════════════════

(define (measure-qty m)
  (if m (measure-has-numerical-value m) 0))

(define (event-qty event)
  (or (economic-event-resource-quantity event)
      (economic-event-effort-quantity event)))

(define (add-to-measure m amount)
  (if m
      (make-measure (+ (measure-has-numerical-value m) amount)
                    (measure-has-unit m))
      (make-measure amount "each")))

(define (append-index hm key val)
  (hashmap-set hm key (cons val (hashmap-ref hm key '()))))


;; ═════════════════════════════════════════════════════════════════════════
;; VF action effect application (pure — unchanged from before)
;; ═════════════════════════════════════════════════════════════════════════

(define (apply-quantity-effect resource field-accessor effect direction qty)
  (let ((current (measure-qty (field-accessor resource))))
    (case effect
      ((increment)           (if (eq? direction 'from) (+ current qty) current))
      ((decrement)           (if (eq? direction 'from) (- current qty) current))
      ((decrement-increment) (if (eq? direction 'from) (- current qty) (+ current qty)))
      ((increment-to)        (if (eq? direction 'to) (+ current qty) current))
      ((no-effect) current)
      (else current))))

(define (apply-resource-effects resource event action-def direction)
  (let* ((qty (measure-qty (event-qty event)))
         (unit (or (and (event-qty event) (measure-has-unit (event-qty event)))
                   (or (and (economic-resource-accounting-quantity resource)
                            (measure-has-unit (economic-resource-accounting-quantity resource)))
                       "each")))
         (new-acct (apply-quantity-effect resource economic-resource-accounting-quantity
                     (action-definition-accounting-effect action-def) direction qty))
         (new-onhand (apply-quantity-effect resource economic-resource-onhand-quantity
                       (action-definition-onhand-effect action-def) direction qty))
         (loc-eff (action-definition-location-effect action-def))
         (new-location
           (cond
             ((and (economic-event-to-location event)
                   (or (and (eq? loc-eff 'update) (eq? direction 'from))
                       (and (eq? loc-eff 'update-to) (eq? direction 'to))
                       (eq? loc-eff 'new)))
              (economic-event-to-location event))
             ((and (economic-event-at-location event) (eq? loc-eff 'new))
              (economic-event-at-location event))
             (else (economic-resource-current-location resource))))
         (contain-eff (action-definition-contained-effect action-def))
         (new-contained
           (cond
             ((and (eq? contain-eff 'update) (eq? direction 'from)
                   (economic-event-to-resource-inventoried-as event))
              (economic-event-to-resource-inventoried-as event))
             ((and (eq? contain-eff 'remove) (eq? direction 'from)) #f)
             (else (economic-resource-contained-in resource))))
         (acct-eff (action-definition-accountable-effect action-def))
         (new-accountable
           (cond
             ((or (eq? acct-eff 'new)
                  (and (eq? acct-eff 'update-to) (eq? direction 'to)))
              (or (economic-event-receiver event)
                  (economic-resource-primary-accountable resource)))
             (else (economic-resource-primary-accountable resource))))
         (stage-eff (action-definition-stage-effect action-def))
         (new-stage
           (if (and (eq? stage-eff 'update) (eq? direction 'from)
                    (economic-event-output-of event))
               (economic-event-output-of event)
               (economic-resource-stage resource)))
         (state-eff (action-definition-state-effect action-def))
         (new-state
           (if (and (economic-event-state event)
                    (or (and (eq? state-eff 'update) (eq? direction 'from))
                        (and (eq? state-eff 'update-to) (eq? direction 'to))))
               (economic-event-state event)
               (economic-resource-state resource))))
    (make-economic-resource
      (economic-resource-id resource)
      (economic-resource-name resource)
      (economic-resource-note resource)
      (economic-resource-image resource)
      (economic-resource-tracking-identifier resource)
      (economic-resource-conforms-to resource)
      (economic-resource-classified-as resource)
      (make-measure new-acct unit)
      (make-measure new-onhand unit)
      new-location
      (economic-resource-current-virtual-location resource)
      new-accountable
      (economic-resource-custodian-scope resource)
      new-stage
      new-state
      new-contained
      (economic-resource-unit-of-effort resource)
      (economic-resource-lot resource)
      (economic-event-id event)
      (economic-resource-availability-window resource))))


;; ═════════════════════════════════════════════════════════════════════════
;; Phase 1: Append event to log
;; ═════════════════════════════════════════════════════════════════════════

(define (phase-append-event st event)
  (os-set-events st (cons event (os-events st))))


;; ═════════════════════════════════════════════════════════════════════════
;; Phase 2: Index event (pure — no set!)
;; ═════════════════════════════════════════════════════════════════════════

(define (phase-index-event st event)
  (let* ((eid (economic-event-id event))
         (ibr (os-idx-by-resource st))
         (ibp (os-idx-by-process st))
         (iba (os-idx-by-agent st))
         (ibact (os-idx-by-action st))
         (ebi (os-events-by-id st))
         ;; Conditional index updates via let* threading
         (ibr (if (economic-event-resource-inventoried-as event)
                  (append-index ibr (economic-event-resource-inventoried-as event) eid)
                  ibr))
         (ibr (if (economic-event-to-resource-inventoried-as event)
                  (append-index ibr (economic-event-to-resource-inventoried-as event) eid)
                  ibr))
         (ibp (if (economic-event-input-of event)
                  (append-index ibp (economic-event-input-of event) eid) ibp))
         (ibp (if (economic-event-output-of event)
                  (append-index ibp (economic-event-output-of event) eid) ibp))
         (iba (if (economic-event-provider event)
                  (append-index iba (economic-event-provider event) eid) iba))
         (iba (if (economic-event-receiver event)
                  (append-index iba (economic-event-receiver event) eid) iba))
         (ibact (append-index ibact (economic-event-action event) eid))
         (ebi (hashmap-set ebi eid event)))
    (os-set-indexes st ibr ibp iba ibact ebi)))


;; ═════════════════════════════════════════════════════════════════════════
;; Phase 3: Apply resource effects (via fold-ctx)
;; ═════════════════════════════════════════════════════════════════════════

(define (apply-direction-effects ctx event def resource-id direction)
  "Apply VF effects to a resource. Returns updated fold-ctx."
  (if (not resource-id) ctx
      (let ((resource (hashmap-ref (os-resources (ctx-state ctx)) resource-id #f)))
        (if (not resource) ctx
            (let ((updated (apply-resource-effects resource event def direction)))
              (make-fold-ctx
                (os-set-resources (ctx-state ctx)
                  (hashmap-set (os-resources (ctx-state ctx)) resource-id updated))
                (cons updated (ctx-affected ctx))))))))

(define (phase-apply-effects ctx event def)
  (let* ((ctx (apply-direction-effects ctx event def
                (economic-event-resource-inventoried-as event) 'from))
         (ctx (apply-direction-effects ctx event def
                (economic-event-to-resource-inventoried-as event) 'to)))
    ctx))


;; ═════════════════════════════════════════════════════════════════════════
;; Phase 4: Implied transfer
;; ═════════════════════════════════════════════════════════════════════════

(define (phase-implied-transfer ctx event def)
  (let ((from-id (economic-event-resource-inventoried-as event)))
    (if (and (eq? (action-definition-implies-transfer def) 'all-rights)
             from-id
             (economic-event-provider event)
             (economic-event-receiver event)
             (not (equal? (economic-event-provider event)
                          (economic-event-receiver event))))
        (let ((r (hashmap-ref (os-resources (ctx-state ctx)) from-id #f)))
          (if (not r) ctx
              (let ((updated (make-economic-resource
                               (economic-resource-id r) (economic-resource-name r)
                               (economic-resource-note r) (economic-resource-image r)
                               (economic-resource-tracking-identifier r)
                               (economic-resource-conforms-to r)
                               (economic-resource-classified-as r)
                               (economic-resource-accounting-quantity r)
                               (economic-resource-onhand-quantity r)
                               (economic-resource-current-location r)
                               (economic-resource-current-virtual-location r)
                               (economic-event-receiver event)
                               (economic-resource-custodian-scope r)
                               (economic-resource-stage r)
                               (economic-resource-state r)
                               (economic-resource-contained-in r)
                               (economic-resource-unit-of-effort r)
                               (economic-resource-lot r)
                               (economic-resource-previous-event r)
                               (economic-resource-availability-window r))))
                (ctx-update-state ctx
                  (lambda (st)
                    (os-set-resources st
                      (hashmap-set (os-resources st) from-id updated)))))))
        ctx)))


;; ═════════════════════════════════════════════════════════════════════════
;; Phase 5: Tracking (fulfillment / satisfaction / settlement)
;; ═════════════════════════════════════════════════════════════════════════

(define (track-fulfillment st event)
  (let* ((cid (economic-event-fulfills event))
         (fs (hashmap-ref (os-fulfillments st) cid #f)))
    (if (not fs) st
        (let* ((qty (measure-qty (event-qty event)))
               (new-fulfilled (add-to-measure (fulfillment-state-total-fulfilled fs) qty))
               (new-events (cons (economic-event-id event)
                                 (fulfillment-state-fulfilling-events fs)))
               (done? (>= (measure-has-numerical-value new-fulfilled)
                          (measure-has-numerical-value
                            (fulfillment-state-total-committed fs))))
               (over? (> (measure-has-numerical-value new-fulfilled)
                         (measure-has-numerical-value
                           (fulfillment-state-total-committed fs))))
               (new-fs (make-fulfillment-state cid
                         (fulfillment-state-total-committed fs)
                         new-fulfilled new-events done? over?)))
          (os-set-fulfillments st
            (hashmap-set (os-fulfillments st) cid new-fs))))))

(define (track-satisfaction st event)
  (let* ((iid (economic-event-satisfies event))
         (ss (hashmap-ref (os-satisfactions st) iid #f)))
    (if (not ss) st
        (let* ((qty (measure-qty (event-qty event)))
               (new-satisfied (add-to-measure (satisfaction-state-total-satisfied ss) qty))
               (new-events (cons (economic-event-id event)
                                 (satisfaction-state-satisfying-events ss)))
               (done? (>= (measure-has-numerical-value new-satisfied)
                          (measure-has-numerical-value
                            (satisfaction-state-total-desired ss))))
               (new-ss (make-satisfaction-state iid
                         (satisfaction-state-total-desired ss)
                         new-satisfied new-events
                         (satisfaction-state-satisfying-commitments ss) done?)))
          (os-set-satisfactions st
            (hashmap-set (os-satisfactions st) iid new-ss))))))

(define (track-settlement st event)
  (let* ((cid (economic-event-settles event))
         (cs (hashmap-ref (os-claim-states st) cid #f)))
    (if (not cs) st
        (let* ((qty (measure-qty (event-qty event)))
               (new-settled (add-to-measure (claim-state-total-settled cs) qty))
               (new-events (cons (economic-event-id event)
                                 (claim-state-settling-events cs)))
               (done? (>= (measure-has-numerical-value new-settled)
                          (measure-has-numerical-value
                            (claim-state-total-claimed cs))))
               (new-cs (make-claim-state cid
                         (claim-state-total-claimed cs)
                         new-settled new-events done?)))
          (os-set-claim-states st
            (hashmap-set (os-claim-states st) cid new-cs))))))

(define (phase-track st event)
  (let* ((st (if (economic-event-fulfills event) (track-fulfillment st event) st))
         (st (if (economic-event-satisfies event) (track-satisfaction st event) st))
         (st (if (economic-event-settles event) (track-settlement st event) st)))
    st))


;; ═════════════════════════════════════════════════════════════════════════
;; Action definition lookup
;; ═════════════════════════════════════════════════════════════════════════

(define (get-action-def action-sym)
  (let ((entry (assq action-sym *action-definitions*)))
    (if entry (cdr entry)
        (error (format #f "Unknown VF action: ~a" action-sym)))))


;; ═════════════════════════════════════════════════════════════════════════
;; THE FOLD KERNEL: observer-record-event
;; ═════════════════════════════════════════════════════════════════════════

(define (observer-record-event st event)
  "The fold kernel: (state, event) -> (values state affected-resources).

   Pipeline:
     1. append event to log
     2. index into lookup maps
     3. apply VF resource effects (from + to)
     4. apply implied transfer
     5. track fulfillment / satisfaction / settlement"
  (let* ((def (get-action-def (economic-event-action event)))
         ;; Phases 1-2: bare state
         (st  (phase-append-event st event))
         (st  (phase-index-event  st event))
         ;; Phases 3-4: fold-ctx (state + affected accumulator)
         (ctx (make-fold-ctx st '()))
         (ctx (phase-apply-effects    ctx event def))
         (ctx (phase-implied-transfer ctx event def))
         ;; Phase 5: back to bare state
         (st  (phase-track (ctx-state ctx) event)))
    (values st (reverse (ctx-affected ctx)))))


;; ═════════════════════════════════════════════════════════════════════════
;; Record <-> list serialization for persistence
;; ═════════════════════════════════════════════════════════════════════════

(define (sm m) (if (and m (measure? m))
                   (list (measure-has-numerical-value m) (measure-has-unit m)) #f))
(define (dm lst) (if (and lst (pair? lst)) (make-measure (car lst) (cadr lst)) #f))

(define (economic-event->list e)
  (list (economic-event-id e) (economic-event-action e)
        (economic-event-input-of e) (economic-event-output-of e)
        (economic-event-resource-inventoried-as e)
        (economic-event-to-resource-inventoried-as e)
        (economic-event-resource-conforms-to e)
        (economic-event-resource-classified-as e)
        (economic-event-provider e) (economic-event-receiver e)
        (sm (economic-event-resource-quantity e))
        (sm (economic-event-effort-quantity e))
        (economic-event-has-beginning e) (economic-event-has-end e)
        (economic-event-has-point-in-time e) (economic-event-created e)
        (economic-event-at-location e) (economic-event-to-location e)
        (economic-event-state e)
        (economic-event-fulfills e) (economic-event-satisfies e)
        (economic-event-corrects e) (economic-event-realization-of e)
        (economic-event-settles e) (economic-event-note e)
        (economic-event-in-scope-of e) (economic-event-previous-event e)
        (economic-event-exclude-from-adu e) (economic-event-market-value e)))

(define (list->economic-event lst)
  (match lst
    ((id action input-of output-of rias trias rct rca
      provider receiver rq eq hb he hpit created at-loc to-loc state
      fulfills satisfies corrects real-of settles note
      in-scope prev excl-adu mktval)
     (make-economic-event
       id action input-of output-of rias trias rct rca
       provider receiver (dm rq) (dm eq)
       hb he hpit created at-loc to-loc state
       fulfills satisfies corrects real-of settles note
       in-scope prev excl-adu mktval))))

(define (economic-resource->list r)
  (list (economic-resource-id r) (economic-resource-name r)
        (economic-resource-note r) (economic-resource-image r)
        (economic-resource-tracking-identifier r)
        (economic-resource-conforms-to r) (economic-resource-classified-as r)
        (sm (economic-resource-accounting-quantity r))
        (sm (economic-resource-onhand-quantity r))
        (economic-resource-current-location r)
        (economic-resource-current-virtual-location r)
        (economic-resource-primary-accountable r)
        (economic-resource-custodian-scope r)
        (economic-resource-stage r) (economic-resource-state r)
        (economic-resource-contained-in r) (economic-resource-unit-of-effort r)
        (economic-resource-lot r) (economic-resource-previous-event r)
        (economic-resource-availability-window r)))

(define (list->economic-resource lst)
  (match lst
    ((id name note image tracking conforms-to classified-as
      acct-qty onhand-qty location virt-loc accountable custodian
      stage state contained-in uoe lot prev-event avail-window)
     (make-economic-resource
       id name note image tracking conforms-to classified-as
       (dm acct-qty) (dm onhand-qty)
       location virt-loc accountable custodian
       stage state contained-in uoe lot prev-event avail-window))))

(define (fulfillment-state->list fs)
  (list (fulfillment-state-commitment-id fs)
        (sm (fulfillment-state-total-committed fs))
        (sm (fulfillment-state-total-fulfilled fs))
        (fulfillment-state-fulfilling-events fs)
        (fulfillment-state-finished fs)
        (fulfillment-state-over-fulfilled fs)))

(define (list->fulfillment-state lst)
  (match lst
    ((cid tc tf events finished over)
     (make-fulfillment-state cid (dm tc) (dm tf) events finished over))))

(define (satisfaction-state->list ss)
  (list (satisfaction-state-intent-id ss)
        (sm (satisfaction-state-total-desired ss))
        (sm (satisfaction-state-total-satisfied ss))
        (satisfaction-state-satisfying-events ss)
        (satisfaction-state-satisfying-commitments ss)
        (satisfaction-state-finished ss)))

(define (list->satisfaction-state lst)
  (match lst
    ((iid td ts events commitments finished)
     (make-satisfaction-state iid (dm td) (dm ts) events commitments finished))))

(define (claim-state->list cs)
  (list (claim-state-claim-id cs)
        (sm (claim-state-total-claimed cs))
        (sm (claim-state-total-settled cs))
        (claim-state-settling-events cs)
        (claim-state-finished cs)))

(define (list->claim-state lst)
  (match lst
    ((cid tc ts events finished)
     (make-claim-state cid (dm tc) (dm ts) events finished))))

(define (serialize-observer-state st)
  (list (map economic-event->list (os-events st))
        (serialize-hashmap (os-resources st) economic-resource->list)
        (serialize-hashmap (os-fulfillments st) fulfillment-state->list)
        (serialize-hashmap (os-satisfactions st) satisfaction-state->list)
        (serialize-hashmap (os-claim-states st) claim-state->list)
        (os-idx-by-resource st) (os-idx-by-process st)
        (os-idx-by-agent st) (os-idx-by-action st)
        (serialize-hashmap (os-events-by-id st) economic-event->list)
        (os-idx-by-spec st)
        (os-agreements st)        ;; alists — already serializable
        (os-batches st)           ;; empty for now
        (os-resource-batches st)));; empty for now

(define (deserialize-observer-state data)
  (match data
    ((sevents sresources sfulfillments ssatisfactions sclaim-states
      sibr sibp siba sibact sebi sibs . rest)
     (let ((sagr (if (pair? rest) (car rest) (hashmap)))
           (sbat (if (and (pair? rest) (pair? (cdr rest))) (cadr rest) (hashmap)))
           (srb  (if (and (pair? rest) (pair? (cdr rest)) (pair? (cddr rest)))
                     (caddr rest) (hashmap))))
       (make-observer-state
         (map list->economic-event sevents)
         (deserialize-hashmap sresources list->economic-resource)
         (deserialize-hashmap sfulfillments list->fulfillment-state)
         (deserialize-hashmap ssatisfactions list->satisfaction-state)
         (deserialize-hashmap sclaim-states list->claim-state)
         sibr sibp siba sibact
         (deserialize-hashmap sebi list->economic-event)
         sibs sagr sbat srb)))))


;; ═════════════════════════════════════════════════════════════════════════
;; ^observer — persistent Goblins actor
;; ═════════════════════════════════════════════════════════════════════════

(define-actor (^observer bcom st)

  #:portrait
  (lambda () (list (serialize-observer-state st)))

  #:version 1

  #:restore
  (lambda (version data)
    (case version
      ((1) (spawn ^observer (deserialize-observer-state data)))
      (else (error "Unknown ^observer version" version))))

  (methods

    ;; --- Core: the fold step ---

    ((record-event event)
     (call-with-values
       (lambda () (observer-record-event st event))
       (lambda (new-st affected)
         (bcom (^observer bcom new-st) affected))))

    ;; --- Registration (using os-set-* updaters) ---

    ((register-commitment commitment)
     (let* ((cid (commitment-id commitment))
            (qty (or (commitment-resource-quantity commitment)
                     (commitment-effort-quantity commitment)
                     (make-measure 0 "each")))
            (fs (make-fulfillment-state cid qty
                  (make-measure 0 (measure-has-unit qty)) '() #f #f)))
       (bcom (^observer bcom
               (os-set-fulfillments st
                 (hashmap-set (os-fulfillments st) cid fs))))))

    ((register-intent intent)
     (let* ((iid (intent-id intent))
            (qty (or (intent-resource-quantity intent)
                     (intent-effort-quantity intent)
                     (make-measure 0 "each")))
            (ss (make-satisfaction-state iid qty
                  (make-measure 0 (measure-has-unit qty)) '() '() #f)))
       (bcom (^observer bcom
               (os-set-satisfactions st
                 (hashmap-set (os-satisfactions st) iid ss))))))

    ((register-claim claim)
     (let* ((cid (claim-id claim))
            (qty (or (claim-resource-quantity claim)
                     (claim-effort-quantity claim)
                     (make-measure 0 "each")))
            (cs (make-claim-state cid qty
                  (make-measure 0 (measure-has-unit qty)) '() #f)))
       (bcom (^observer bcom
               (os-set-claim-states st
                 (hashmap-set (os-claim-states st) cid cs))))))

    ((seed-resource resource)
     (let* ((rid (economic-resource-id resource))
            (spec (economic-resource-conforms-to resource))
            (new-resources (hashmap-set (os-resources st) rid resource))
            (new-idx-spec (if spec
                              (let ((existing (hashmap-ref (os-idx-by-spec st) spec '())))
                                (if (member rid existing) (os-idx-by-spec st)
                                    (hashmap-set (os-idx-by-spec st) spec (cons rid existing))))
                              (os-idx-by-spec st))))
       (bcom (^observer bcom (os-rebuild st #:resources new-resources #:ibs new-idx-spec)))))

    ;; --- Queries (read-only, no state change) ---

    ((get-event id)      (hashmap-ref (os-events-by-id st) id #f))
    ((all-events)        (reverse (os-events st)))
    ((get-resource id)   (hashmap-ref (os-resources st) id #f))
    ((all-resources)     (hashmap-values (os-resources st)))

    ((events-for-resource rid)
     (filter-map (lambda (eid) (hashmap-ref (os-events-by-id st) eid #f))
                 (hashmap-ref (os-idx-by-resource st) rid '())))

    ((events-for-process pid)
     (filter-map (lambda (eid) (hashmap-ref (os-events-by-id st) eid #f))
                 (hashmap-ref (os-idx-by-process st) pid '())))

    ((events-for-agent aid)
     (filter-map (lambda (eid) (hashmap-ref (os-events-by-id st) eid #f))
                 (hashmap-ref (os-idx-by-agent st) aid '())))

    ((events-with-action action)
     (filter-map (lambda (eid) (hashmap-ref (os-events-by-id st) eid #f))
                 (hashmap-ref (os-idx-by-action st) action '())))

    ((conforming-resources spec-id)
     ;; O(log n) via idx-by-spec instead of O(R) hashmap-filter
     (let ((rids (hashmap-ref (os-idx-by-spec st) spec-id '())))
       (filter-map (lambda (rid) (hashmap-ref (os-resources st) rid #f)) rids)))

    ((resources-contained-in container-id)
     (hashmap-filter
       (lambda (r) (equal? (economic-resource-contained-in r) container-id))
       (os-resources st)))

    ((get-fulfillment cid)  (hashmap-ref (os-fulfillments st) cid #f))
    ((get-satisfaction iid) (hashmap-ref (os-satisfactions st) iid #f))
    ((get-claim-state cid)  (hashmap-ref (os-claim-states st) cid #f))

    ((inventory)
     (hashmap-filter
       (lambda (r)
         (or (> (measure-qty (economic-resource-accounting-quantity r)) 0)
             (> (measure-qty (economic-resource-onhand-quantity r)) 0)))
       (os-resources st)))

    ;; --- Inventory slicing ---

    ((inventory-for-spec spec-id)
     (hashmap-filter
       (lambda (r) (and (equal? (economic-resource-conforms-to r) spec-id)
                        (or (> (measure-qty (economic-resource-accounting-quantity r)) 0)
                            (> (measure-qty (economic-resource-onhand-quantity r)) 0))))
       (os-resources st)))

    ((inventory-at-location location-id)
     (hashmap-filter
       (lambda (r) (and (equal? (economic-resource-current-location r) location-id)
                        (or (> (measure-qty (economic-resource-accounting-quantity r)) 0)
                            (> (measure-qty (economic-resource-onhand-quantity r)) 0))))
       (os-resources st)))

    ((inventory-for-agent agent-id)
     (hashmap-filter
       (lambda (r) (and (equal? (economic-resource-primary-accountable r) agent-id)
                        (or (> (measure-qty (economic-resource-accounting-quantity r)) 0)
                            (> (measure-qty (economic-resource-onhand-quantity r)) 0))))
       (os-resources st)))

    ;; --- Inverse event queries ---

    ((fulfilled-by commitment-id)
     (filter (lambda (e) (equal? (economic-event-fulfills e) commitment-id))
             (os-events st)))

    ((satisfied-by intent-id)
     (filter (lambda (e) (equal? (economic-event-satisfies e) intent-id))
             (os-events st)))

    ((settled-by claim-id)
     (filter (lambda (e) (equal? (economic-event-settles e) claim-id))
             (os-events st)))

    ;; --- Event trace ---

    ((trace-resource resource-id)
     ;; Walk previousEvent chain, return chronological (oldest first)
     (let ((resource (hashmap-ref (os-resources st) resource-id #f)))
       (if (not resource) '()
           (let loop ((eid (economic-resource-previous-event resource))
                      (seen '()) (result '()))
             (if (or (not eid) (member eid seen)) (reverse result)
                 (let ((event (hashmap-ref (os-events-by-id st) eid #f)))
                   (if (not event) (reverse result)
                       (loop (economic-event-previous-event event)
                             (cons eid seen)
                             (cons event result)))))))))

    ((active-events-for-resource resource-id)
     ;; Events excluding those that have been corrected
     (let* ((all-evts (filter-map (lambda (eid) (hashmap-ref (os-events-by-id st) eid #f))
                                  (hashmap-ref (os-idx-by-resource st) resource-id '())))
            (corrected-ids (map (lambda (e) (economic-event-corrects e))
                                (filter economic-event-corrects all-evts))))
       (filter (lambda (e) (not (member (economic-event-id e) corrected-ids)))
               all-evts)))

    ;; --- Skill queries ---

    ((skills-of agent-id)
     (hashmap-filter
       (lambda (r) (equal? (economic-resource-primary-accountable r) agent-id))
       (os-resources st)))

    ((agents-with-skill spec-id)
     (delete-duplicates
       (filter-map (lambda (r)
                     (and (equal? (economic-resource-conforms-to r) spec-id)
                          (economic-resource-primary-accountable r)))
                   (hashmap-values (os-resources st)))))

    ;; --- Resource queries ---

    ((resources-by-state state-val)
     (hashmap-filter
       (lambda (r) (equal? (economic-resource-state r) state-val))
       (os-resources st)))

    ((unplanned-events process-id)
     (filter (lambda (e) (not (economic-event-fulfills e)))
             (filter-map (lambda (eid) (hashmap-ref (os-events-by-id st) eid #f))
                         (hashmap-ref (os-idx-by-process st) process-id '()))))

    ;; --- Batch/lot tracking ---

    ((get-batch batch-id)
     (hashmap-ref (os-batches st) batch-id #f))

    ((batches-for-resource resource-id)
     (filter-map (lambda (bid) (hashmap-ref (os-batches st) bid #f))
                 (hashmap-ref (os-resource-batches st) resource-id '())))

    ;; --- Agreement storage ---

    ((register-agreement agreement)
     (let ((aid (if (pair? agreement) (assq-ref agreement 'id)
                    (agreement-id agreement))))
       (bcom (^observer bcom
               (os-set-agreements st
                 (hashmap-set (os-agreements st) aid agreement))))))

    ((get-agreement id)
     (hashmap-ref (os-agreements st) id #f))

    ;; --- Exchange recording ---

    ((record-exchange agreement events-list)
     ;; Register agreement, tag events with realizationOf, record each
     (let* ((aid (if (pair? agreement) (assq-ref agreement 'id)
                     (agreement-id agreement)))
            (new-agreements (hashmap-set (os-agreements st) aid agreement))
            ;; We need to record events sequentially, threading state
            ;; Use the fold kernel directly
            (initial-st (os-set-agreements st new-agreements)))
       ;; Fold events through observer-record-event
       (let loop ((evts events-list) (current-st initial-st) (all-affected '()))
         (if (null? evts)
             (bcom (^observer bcom current-st) (reverse all-affected))
             (call-with-values
               (lambda () (observer-record-event current-st (car evts)))
               (lambda (nst affected)
                 (loop (cdr evts) nst (append (reverse affected) all-affected))))))))

    ;; --- Correction ---

    ((apply-correction correction-event)
     ;; Negate the original event's effects, then record the correction
     (let* ((original-id (economic-event-corrects correction-event))
            (original (and original-id (hashmap-ref (os-events-by-id st) original-id #f))))
       (if (not original)
           ;; Original not found — just record the correction event as-is
           (call-with-values
             (lambda () (observer-record-event st correction-event))
             (lambda (nst affected) (bcom (^observer bcom nst) affected)))
           ;; Negate original's effects, then record correction
           (let* ((def (get-action-def (economic-event-action original)))
                  ;; Negate from-resource
                  (st1 (let ((rid (economic-event-resource-inventoried-as original)))
                         (if (not rid) st
                             (let ((r (hashmap-ref (os-resources st) rid #f)))
                               (if (not r) st
                                   (let ((negated (negate-resource-effects r original def 'from)))
                                     (os-set-resources st
                                       (hashmap-set (os-resources st) rid negated))))))))
                  ;; Negate to-resource
                  (st2 (let ((rid (economic-event-to-resource-inventoried-as original)))
                         (if (not rid) st1
                             (let ((r (hashmap-ref (os-resources st1) rid #f)))
                               (if (not r) st1
                                   (let ((negated (negate-resource-effects r original def 'to)))
                                     (os-set-resources st1
                                       (hashmap-set (os-resources st1) rid negated)))))))))
             ;; Now record the correction event on the negated state
             (call-with-values
               (lambda () (observer-record-event st2 correction-event))
               (lambda (nst affected) (bcom (^observer bcom nst) affected)))))))

    ;; --- Recompute resource from events ---

    ((recompute-resource resource-id)
     ;; Replay all events to rebuild resource state from scratch
     (let* ((events-for-r (filter-map
                            (lambda (eid) (hashmap-ref (os-events-by-id st) eid #f))
                            (hashmap-ref (os-idx-by-resource st) resource-id '())))
            (resource (hashmap-ref (os-resources st) resource-id #f)))
       (if (or (null? events-for-r) (not resource)) #f
           ;; Reset quantities to 0 and replay
           (let* ((unit (or (and (economic-resource-accounting-quantity resource)
                                 (measure-has-unit (economic-resource-accounting-quantity resource)))
                            "each"))
                  (reset (make-economic-resource
                           (economic-resource-id resource)
                           (economic-resource-name resource)
                           (economic-resource-note resource)
                           (economic-resource-image resource)
                           (economic-resource-tracking-identifier resource)
                           (economic-resource-conforms-to resource)
                           (economic-resource-classified-as resource)
                           (make-measure 0 unit) (make-measure 0 unit)
                           (economic-resource-current-location resource)
                           (economic-resource-current-virtual-location resource)
                           (economic-resource-primary-accountable resource)
                           (economic-resource-custodian-scope resource)
                           (economic-resource-stage resource)
                           (economic-resource-state resource)
                           (economic-resource-contained-in resource)
                           (economic-resource-unit-of-effort resource)
                           (economic-resource-lot resource)
                           (economic-resource-previous-event resource)
                           (economic-resource-availability-window resource))))
             ;; Replay non-correction events
             (fold (lambda (event r)
                     (if (economic-event-corrects event) r
                         (let* ((def (get-action-def (economic-event-action event)))
                                (dir (cond
                                       ((equal? (economic-event-resource-inventoried-as event) resource-id) 'from)
                                       ((equal? (economic-event-to-resource-inventoried-as event) resource-id) 'to)
                                       (else #f))))
                           (if dir (apply-resource-effects r event def dir) r))))
                   reset events-for-r)))))

    ;; --- Clear ---

    ((clear)
     (bcom (^observer bcom (empty-observer-state))))))


;; ═════════════════════════════════════════════════════════════════════════
;; Negate resource effects (for corrections)
;; ═════════════════════════════════════════════════════════════════════════

(define (negate-resource-effects resource event def direction)
  "Reverse the quantity effects of an event on a resource."
  (let* ((qty (measure-qty (event-qty event)))
         (unit (or (and (event-qty event) (measure-has-unit (event-qty event)))
                   (or (and (economic-resource-accounting-quantity resource)
                            (measure-has-unit (economic-resource-accounting-quantity resource)))
                       "each")))
         ;; Reverse: what was increment becomes decrement and vice versa
         (acct-eff (action-definition-accounting-effect def))
         (new-acct (let ((current (measure-qty (economic-resource-accounting-quantity resource))))
                     (case acct-eff
                       ((increment)           (if (eq? direction 'from) (- current qty) current))
                       ((decrement)           (if (eq? direction 'from) (+ current qty) current))
                       ((decrement-increment) (if (eq? direction 'from) (+ current qty) (- current qty)))
                       ((increment-to)        (if (eq? direction 'to) (- current qty) current))
                       (else current))))
         (onhand-eff (action-definition-onhand-effect def))
         (new-onhand (let ((current (measure-qty (economic-resource-onhand-quantity resource))))
                       (case onhand-eff
                         ((increment)           (if (eq? direction 'from) (- current qty) current))
                         ((decrement)           (if (eq? direction 'from) (+ current qty) current))
                         ((decrement-increment) (if (eq? direction 'from) (+ current qty) (- current qty)))
                         ((increment-to)        (if (eq? direction 'to) (- current qty) current))
                         (else current)))))
    (make-economic-resource
      (economic-resource-id resource)
      (economic-resource-name resource)
      (economic-resource-note resource)
      (economic-resource-image resource)
      (economic-resource-tracking-identifier resource)
      (economic-resource-conforms-to resource)
      (economic-resource-classified-as resource)
      (make-measure new-acct unit) (make-measure new-onhand unit)
      (economic-resource-current-location resource)
      (economic-resource-current-virtual-location resource)
      (economic-resource-primary-accountable resource)
      (economic-resource-custodian-scope resource)
      (economic-resource-stage resource)
      (economic-resource-state resource)
      (economic-resource-contained-in resource)
      (economic-resource-unit-of-effort resource)
      (economic-resource-lot resource)
      (economic-resource-previous-event resource)
      (economic-resource-availability-window resource))))


;; ═════════════════════════════════════════════════════════════════════════
;; Persistence environment
;; ═════════════════════════════════════════════════════════════════════════

(define observer-env
  (make-persistence-env
    `((((vf observation) ^observer) ,^observer))))
