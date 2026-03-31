;;; ddmrp.scm — DDMRP relations (the genuinely bidirectional parts)
;;;
;;; Zone classification, variability lookup, NFP arithmetic, location
;;; hierarchy — these are real relations that work in any direction.
;;; Ground computations (ADU, DLT, qualified demand, buffer levels,
;;; projection, analytics) live in compute.scm as honest Scheme functions.

(use-modules (playnet kanren-constraints))


;;; ── Fact relations ────────────────────────────────────────────────────────────

(define (buffer-zone-fact-o facts spec-id tor toy tog adu dlt-days)
  (in-list-o `(buffer-zone ,spec-id ,tor ,toy ,tog ,adu ,dlt-days) facts))

(define (event-fact-o facts eid action spec-id qty timestamp)
  (in-list-o `(event ,eid ,action ,spec-id ,qty ,timestamp) facts))

(define (location-parent-o facts child parent)
  (in-list-o `(location-parent ,child ,parent) facts))

(define (adjustment-factor-o facts spec-id factor-type factor-value
                             valid-from valid-to at-location)
  (in-list-o `(adjustment-factor ,spec-id ,factor-type ,factor-value
                                 ,valid-from ,valid-to ,at-location) facts))

(define (buffered-spec-o facts spec-id)
  (fresh (tor toy tog adu dlt)
    (buffer-zone-fact-o facts spec-id tor toy tog adu dlt)))


;;; ── Location hierarchy (relational transitive closure) ────────────────────────

(define (location-descendant-or-equal-o facts loc ancestor)
  (conde
    ((== loc ancestor))
    ((fresh (mid)
       (location-parent-o facts loc mid)
       (location-descendant-or-equal-o facts mid ancestor)))))


;;; ── Zone classification (genuinely bidirectional via CLP(FD)) ─────────────────
;;; "What zone is NFP 120 in?" AND "What NFP range gives green zone?"

(define (zone-o nfp tor toy tog zone)
  (conde
    ((<=fd nfp tor) (== zone 'red))
    ((<fd tor nfp) (<=fd nfp toy) (== zone 'yellow))
    ((<fd toy nfp) (<=fd nfp tog) (== zone 'green))
    ((<fd tog nfp) (== zone 'excess))))


;;; ── Variability factor (relational 3x3 lookup — any direction) ────────────────
;;; "What factor for high VRD + medium VRS?" AND "What VRD/VRS gives factor 0.50?"

(define *variability-table*
  '((vf low    low    0.10) (vf low    medium 0.25) (vf low    high   0.50)
    (vf medium low    0.25) (vf medium medium 0.50) (vf medium high   0.75)
    (vf high   low    0.50) (vf high   medium 0.75) (vf high   high   1.00)))

(define (variability-factor-o vrd vrs factor)
  (in-list-o `(vf ,vrd ,vrs ,factor) *variability-table*))


;;; ── NFP arithmetic (CLP(FD) — bidirectional) ─────────────────────────────────
;;; "NFP given onhand/onorder/demand" AND "What onhand gives NFP 100?"

(define (nfp-o onhand onorder qd nfp)
  (fresh (supply) (+fd onhand onorder supply) (-fd supply qd nfp)))


;;; ── Replenishment signal routing (relational branching) ───────────────────────

(define (replenishment-needed-o zone needed)
  "Is replenishment needed? Relational."
  (conde
    ((== zone 'red) (== needed #t))
    ((== zone 'yellow) (== needed #t))
    ((== zone 'green) (== needed #f))
    ((== zone 'excess) (== needed #f))))


;;; ── Full DDMRP evaluation (orchestrates relations + computations) ─────────────

(define (ddmrp-evaluate-o facts spec-id today result)
  "Complete DDMRP evaluation. Uses relations for zone/NFP, compute.scm for ground data."
  (fresh (tor toy tog adu dlt oh oo qd nfp zone needed)
    (buffer-zone-fact-o facts spec-id tor toy tog adu dlt)
    (project (facts spec-id today dlt adu)
      (let ((oh-val (compute-onhand facts spec-id #f))
            (oo-val (compute-onorder facts spec-id))
            (qd-val (compute-qualified-demand facts spec-id today dlt #f #f adu)))
        (fresh ()
          (== oh oh-val) (== oo oo-val) (== qd qd-val)
          (nfp-o oh oo qd nfp)
          (zone-o nfp tor toy tog zone)
          (replenishment-needed-o zone needed)
          (project (nfp tog)
            (let ((sig (and needed (> tog nfp)
                            `((kind . replenishment) (spec-id . ,spec-id)
                              (qty . ,(compute-replenishment-qty nfp tog 0))
                              (source . ddmrp)))))
              (== result `((spec-id . ,spec-id) (onhand . ,oh) (onorder . ,oo)
                           (qualified-demand . ,qd) (nfp . ,nfp) (zone . ,zone)
                           (signal . ,sig))))))))))
