;;; ddmrp.scm — Demand-Driven MRP as relational constraints
;;;
;;; Buffer zone management: ADU, DLT, NFP, zone classification,
;;; replenishment signal generation. All expressed as relations
;;; and CLP(FD) constraints.
;;;
;;; Ref: Ptak & Smith — Demand Driven Material Requirements Planning

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))

(define *seconds-per-day* 86400)
(define *consuming-actions* '(consume combine pickup accept))
(define *non-consuming* '(use work cite deliver-service))


;;; ── Fact relations for DDMRP data ─────────────────────────────────────────────

(define (buffer-zone-o facts spec-id tor toy tog adu dlt-days)
  "Relate a spec to its buffer zone parameters."
  (in-list-o `(buffer-zone ,spec-id ,tor ,toy ,tog ,adu ,dlt-days) facts))

(define (event-o facts eid action spec-id qty timestamp)
  "Relate an event to its fields."
  (in-list-o `(event ,eid ,action ,spec-id ,qty ,timestamp) facts))

(define (buffered-spec-o facts spec-id)
  "Is SPEC-ID a buffered (decoupled) spec?"
  (fresh (tor toy tog adu dlt)
    (buffer-zone-o facts spec-id tor toy tog adu dlt)))


;;; ── Accumulation helpers ──────────────────────────────────────────────────────

(define (sum-qty-o items total)
  "Sum quantities from a concrete list of (... qty ...) items.
   ITEMS is a ground Scheme list. TOTAL is unified with the sum."
  (project (items)
    (== total (fold (lambda (item acc) (+ acc (or (car item) 0))) 0 items))))

(define (filter-events-o facts spec-id action-list from-time to-time result)
  "Filter event facts matching spec, actions, and time window. Ground computation."
  (project (facts spec-id action-list from-time to-time)
    (== result
         (filter-map
           (lambda (f)
             (and (eq? (car f) 'event)
                  (equal? (cadddr f) spec-id)       ;; spec matches
                  (memq (caddr f) action-list)       ;; action matches
                  (let ((ts (list-ref f 5)))          ;; timestamp
                    (and ts (>= ts from-time) (<= ts to-time)))
                  (list (list-ref f 4))))             ;; qty
           facts))))


;;; ── ADU (Average Daily Usage) ─────────────────────────────────────────────────

(define (adu-o facts spec-id window-days as-of adu)
  "Relate a spec to its Average Daily Usage over a time window."
  (fresh (consuming total)
    (filter-events-o facts spec-id *consuming-actions*
                     (- as-of (* window-days *seconds-per-day*)) as-of
                     consuming)
    (sum-qty-o consuming total)
    (project (total)
      (== adu (if (> window-days 0)
                  (inexact->exact (round (/ total window-days)))
                  0)))))


;;; ── Buffer Zone Levels ────────────────────────────────────────────────────────

(define (buffer-levels-o adu dlt-days lead-time-factor variability-factor
                         tor toy tog)
  "Compute TOR/TOY/TOG from ADU, DLT, and profile factors.
   All CLP(FD) arithmetic."
  (fresh (red-base yellow green)
    ;; red-base = ADU × DLT × lead-time-factor (as integers)
    (*fd adu dlt-days red-base)
    ;; For simplicity, apply factors via project (they're often fractional)
    (project (red-base adu dlt-days)
      (let* ((red (inexact->exact (round (* red-base lead-time-factor))))
             (yel (inexact->exact (round (* adu dlt-days))))
             (grn (inexact->exact (round (* adu dlt-days variability-factor)))))
        (fresh ()
          (== tor red)
          (+fd red yel toy)
          (+fd toy grn tog))))))


;;; ── NFP (Net Flow Position) ───────────────────────────────────────────────────

(define (nfp-o onhand onorder qualified-demand nfp)
  "Net Flow Position = onhand + onorder - qualified-demand.
   All CLP(FD) arithmetic."
  (fresh (supply)
    (+fd onhand onorder supply)
    (-fd supply qualified-demand nfp)))


;;; ── Zone Classification ───────────────────────────────────────────────────────

(define (zone-o nfp tor toy tog zone)
  "Classify NFP into buffer zone color."
  (conde
    ((<=fd nfp tor) (== zone 'red))
    ((<fd tor nfp) (<=fd nfp toy) (== zone 'yellow))
    ((<fd toy nfp) (<=fd nfp tog) (== zone 'green))
    ((<fd tog nfp) (== zone 'excess))))

(define (buffer-status-o onhand tor toy tog zone)
  "Classify onhand inventory into a zone."
  (zone-o onhand tor toy tog zone))


;;; ── Onhand from inventory facts ───────────────────────────────────────────────

(define (onhand-o facts spec-id onhand)
  "Sum onhand quantity for a spec from inventory facts."
  (project (facts spec-id)
    (== onhand
         (fold (lambda (f acc)
                 (if (and (eq? (car f) 'inventory)
                          (equal? (caddr f) spec-id))
                     (+ acc (cadddr f))
                     acc))
               0 facts))))


;;; ── Onorder from intent facts ─────────────────────────────────────────────────

(define (onorder-o facts spec-id onorder)
  "Sum onorder quantity (output intents not finished) for a spec."
  (project (facts spec-id)
    (== onorder
         (fold (lambda (f acc)
                 (if (and (eq? (car f) 'intent)
                          (equal? (cadddr f) spec-id)     ;; spec matches
                          (eq? (list-ref f 8) 'output)    ;; output direction
                          (not (list-ref f 10)))           ;; not finished
                     (+ acc (or (list-ref f 4) 0))
                     acc))
               0 facts))))


;;; ── Qualified Demand ──────────────────────────────────────────────────────────

(define (qualified-demand-o facts spec-id horizon-end qd)
  "Sum consuming commitments + intents due before horizon."
  (project (facts spec-id horizon-end)
    (== qd
         (fold (lambda (f acc)
                 (cond
                   ;; Commitments
                   ((and (eq? (car f) 'commitment)
                         (equal? (cadddr f) spec-id)
                         (memq (caddr f) *consuming-actions*)
                         (list-ref f 5)  ;; has due date
                         (<= (list-ref f 5) horizon-end))
                    (+ acc (or (list-ref f 4) 0)))
                   ;; Intents
                   ((and (eq? (car f) 'intent)
                         (equal? (cadddr f) spec-id)
                         (eq? (list-ref f 7) 'input)  ;; consuming
                         (list-ref f 5)  ;; has due
                         (<= (list-ref f 5) horizon-end)
                         (not (list-ref f 10)))  ;; not finished
                    (+ acc (or (list-ref f 4) 0)))
                   (else acc)))
               0 facts))))


;;; ── Replenishment Signal Generation ───────────────────────────────────────────

(define (replenishment-signal-o nfp zone tog spec-id signal)
  "Generate a replenishment signal if zone is red or yellow."
  (conde
    ;; Red or yellow → signal to replenish up to TOG
    ((conde ((== zone 'red)) ((== zone 'yellow)))
     (fresh (replenish-qty)
       (-fd tog nfp replenish-qty)
       (signal-o 'replenishment spec-id replenish-qty 'ddmrp signal)))
    ;; Green or excess → no signal
    ((conde ((== zone 'green)) ((== zone 'excess)))
     (== signal #f))))


;;; ── DLT (Decoupled Lead Time) ─────────────────────────────────────────────────

(define (dlt-o facts buffered-specs spec-id dlt)
  "Compute decoupled lead time for a spec. Stops at buffer boundaries.
   DLT = sum of process durations, recursing only through non-buffered inputs."
  (dlt-step facts buffered-specs spec-id dlt '()))

(define (dlt-step facts buffered-specs spec-id dlt visited)
  (if (member spec-id visited)
      (== dlt 0)  ;; cycle guard
      (project (facts buffered-specs spec-id visited)
        (let* ((recipe-fact (find (lambda (f)
                                    (and (eq? (car f) 'recipe)
                                         (equal? (cadddr f) spec-id)))
                                  facts))
               (rid (and recipe-fact (cadr recipe-fact))))
          (if (not rid)
              (== dlt 0)  ;; no recipe
              (let* ((chain-fact (find (lambda (f)
                                        (and (eq? (car f) 'chain)
                                             (equal? (cadr f) rid)))
                                      facts))
                     (pids (and chain-fact (caddr chain-fact)))
                     (new-visited (cons spec-id visited)))
                (== dlt
                    (fold (lambda (pid acc)
                            (let* ((proc-fact (find (lambda (f)
                                                      (and (eq? (car f) 'process)
                                                           (equal? (cadr f) pid)))
                                                    facts))
                                   (dur-ms (if proc-fact (cadddr proc-fact) 0))
                                   (dur-days (/ dur-ms 86400000)))
                              (+ acc dur-days)))
                          0 (or pids '())))))))))


;;; ── Full DDMRP evaluation for a spec ──────────────────────────────────────────

(define (ddmrp-evaluate-o facts spec-id today-seconds result)
  "Run full DDMRP evaluation for a spec: onhand, onorder, QD, NFP, zone, signal."
  (fresh (onhand onorder dlt-days tor toy tog zone nfp qd signal)
    (buffer-zone-o facts spec-id tor toy tog _adu dlt-days)
    (onhand-o facts spec-id onhand)
    (onorder-o facts spec-id onorder)
    (project (today-seconds dlt-days)
      (qualified-demand-o facts spec-id
                          (+ today-seconds (* dlt-days *seconds-per-day*)) qd))
    (nfp-o onhand onorder qd nfp)
    (zone-o nfp tor toy tog zone)
    (replenishment-signal-o nfp zone tog spec-id signal)
    (== result `((spec-id . ,spec-id)
                 (onhand . ,onhand)
                 (onorder . ,onorder)
                 (qualified-demand . ,qd)
                 (nfp . ,nfp)
                 (zone . ,zone)
                 (signal . ,signal)))))
