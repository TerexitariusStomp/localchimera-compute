;;; ddmrp.scm — Complete DDMRP as relational constraints
;;;
;;; Every function from the imperative ddmrp.scm, expressed as relations.
;;; Relational where meaningful (zone classification, signal routing, variability lookup).
;;; project where honest (arithmetic on ground lifted values).
;;;
;;; Ref: Ptak & Smith — Demand Driven Material Requirements Planning

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))

(define *seconds-per-day* 86400)
(define *consuming-actions* '(consume combine pickup accept))
(define *non-consuming* '(use work cite deliver-service))
(define *epsilon* 1e-9)


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Fact relations
;;; ══════════════════════════════════════════════════════════════════════════════

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


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Location hierarchy (relational — transitive closure)
;;; ══════════════════════════════════════════════════════════════════════════════

(define (location-descendant-or-equal-o facts loc ancestor)
  (conde
    ((== loc ancestor))
    ((fresh (mid)
       (location-parent-o facts loc mid)
       (location-descendant-or-equal-o facts mid ancestor)))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Zone classification (relational — bidirectional via CLP(FD))
;;; ══════════════════════════════════════════════════════════════════════════════

(define (zone-o nfp tor toy tog zone)
  (conde
    ((<=fd nfp tor) (== zone 'red))
    ((<fd tor nfp) (<=fd nfp toy) (== zone 'yellow))
    ((<fd toy nfp) (<=fd nfp tog) (== zone 'green))
    ((<fd tog nfp) (== zone 'excess))))

(define (buffer-status-o onhand tor toy tog zone pct)
  (zone-o onhand tor toy tog zone)
  (project (onhand tog)
    (== pct (if (> tog 0) (inexact->exact (round (* (/ onhand tog) 100))) 100))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Variability factor (relational — 3x3 lookup, any direction)
;;; ══════════════════════════════════════════════════════════════════════════════

(define *variability-table*
  '((vf low    low    0.10) (vf low    medium 0.25) (vf low    high   0.50)
    (vf medium low    0.25) (vf medium medium 0.50) (vf medium high   0.75)
    (vf high   low    0.50) (vf high   medium 0.75) (vf high   high   1.00)))

(define (variability-factor-o vrd vrs factor)
  (in-list-o `(vf ,vrd ,vrs ,factor) *variability-table*))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; ADU — Average Daily Usage
;;; ══════════════════════════════════════════════════════════════════════════════

(define (adu-o facts spec-id window-days as-of adu)
  "Rolling ADU from historical consuming events."
  (project (facts spec-id window-days as-of)
    (let* ((window-start (- as-of (* window-days *seconds-per-day*)))
           (consuming (filter (lambda (f)
                                (and (eq? (car f) 'event)
                                     (equal? (cadddr f) spec-id)
                                     (memq (caddr f) *consuming-actions*)
                                     (list-ref f 5)
                                     (>= (list-ref f 5) window-start)
                                     (<= (list-ref f 5) as-of)))
                              facts))
           (total (fold (lambda (f a) (+ a (or (list-ref f 4) 0))) 0 consuming)))
      (== adu (if (> window-days 0) (/ total window-days) 0)))))

(define (forward-adu-o facts spec-id window-days as-of fwd-adu)
  "Forward-looking ADU from planned consuming intents."
  (project (facts spec-id window-days as-of)
    (let* ((horizon-end (+ as-of (* window-days *seconds-per-day*)))
           (consuming (filter (lambda (f)
                                (and (eq? (car f) 'intent)
                                     (equal? (cadddr f) spec-id)
                                     (eq? (list-ref f 7) 'input)
                                     (not (memq (caddr f) *non-consuming*))
                                     (list-ref f 6)
                                     (>= (list-ref f 6) as-of)
                                     (<= (list-ref f 6) horizon-end)))
                              facts))
           (total (fold (lambda (f a) (+ a (or (list-ref f 4) 0))) 0 consuming)))
      (== fwd-adu (if (> window-days 0) (/ total window-days) 0)))))

(define (blend-adu-o past forward ratio blended)
  "Blend past and forward ADU. ratio: 0=forward-only, 1=past-only."
  (project (past forward ratio)
    (== blended (+ (* past ratio) (* forward (- 1 ratio))))))

(define (bootstrap-adu-o actual days-actual estimated window-days result)
  "Blended ADU for incomplete demand history."
  (project (actual days-actual estimated window-days)
    (if (>= days-actual window-days)
        (== result `((blended-adu . ,actual) (complete . #t) (days . ,window-days)))
        (let* ((d-est (- window-days days-actual))
               (bl (/ (+ (* actual days-actual) (* estimated d-est)) window-days)))
          (== result `((blended-adu . ,bl) (complete . #f) (days . ,days-actual)))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Lead Time (DLT)
;;; ══════════════════════════════════════════════════════════════════════════════

(define (recipe-lead-time-o facts recipe-id dlt)
  "Simple DLT = sum of process durations in chain."
  (fresh (pids)
    (chain-o facts recipe-id pids)
    (project (facts pids)
      (== dlt (fold (lambda (pid a)
                      (let ((pf (find (lambda (f) (and (eq? (car f) 'process)
                                                        (equal? (cadr f) pid))) facts)))
                        (+ a (if pf (/ (cadddr pf) 86400000.0) 0))))
                    0 pids)))))

(define (decoupled-lead-time-o facts buffered-specs spec-id dlt)
  "DLT stopping at buffer boundaries. Recursive with cycle guard."
  (project (facts buffered-specs spec-id)
    (== dlt (dlt-compute facts buffered-specs spec-id '()))))

(define (dlt-compute facts buffered-specs spec-id visited)
  "Pure Scheme: recursive DLT computation."
  (if (member spec-id visited) 0
      (let ((rf (find (lambda (f) (and (eq? (car f) 'recipe) (equal? (cadddr f) spec-id))) facts)))
        (if (not rf) 0
            (let* ((rid (cadr rf))
                   (cf (find (lambda (f) (and (eq? (car f) 'chain) (equal? (cadr f) rid))) facts))
                   (pids (if cf (caddr cf) '()))
                   (nv (cons spec-id visited)))
              (fold (lambda (pid a)
                      (let* ((pf (find (lambda (f) (and (eq? (car f) 'process)
                                                         (equal? (cadr f) pid))) facts))
                             (dur (if pf (/ (cadddr pf) 86400000.0) 0))
                             (input-dlt
                               (fold (lambda (f best)
                                       (let ((in-sp (and (eq? (car f) 'flow)
                                                          (equal? (cadr f) pid)
                                                          (eq? (caddr f) 'input)
                                                          (not (memq (list-ref f 6) *non-consuming*))
                                                          (cadddr f))))
                                         (if (and in-sp (not (member in-sp buffered-specs)))
                                             (max best (dlt-compute facts buffered-specs in-sp nv))
                                             best)))
                                     0 facts)))
                        (+ a dur input-dlt)))
                    0 pids))))))

(define (leg-lead-time-o facts recipe-id upstream-stage downstream-stage dlt)
  "DLT for one decoupled routing leg between two stages."
  (fresh (pids)
    (chain-o facts recipe-id pids)
    (project (facts pids upstream-stage downstream-stage)
      (let* ((find-stage (lambda (stage)
               (list-index (lambda (pid)
                 (let ((pf (find (lambda (f) (and (eq? (car f) 'process)
                                                   (equal? (cadr f) pid))) facts)))
                   (and pf (equal? (list-ref pf 2) stage)))) pids)))
             (si (or (and upstream-stage (find-stage upstream-stage)) 0))
             (ei (or (and downstream-stage (find-stage downstream-stage)) (- (length pids) 1))))
        (if (or (> si ei) (< si 0))
            (== dlt 0)
            (== dlt (let loop ((i si) (t 0))
                      (if (> i ei) t
                          (let* ((pid (list-ref pids i))
                                 (pf (find (lambda (f) (and (eq? (car f) 'process)
                                                             (equal? (cadr f) pid))) facts))
                                 (d (if pf (/ (cadddr pf) 86400000.0) 0)))
                            (loop (+ i 1) (+ t d)))))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Qualified Demand (with OST spike filtering)
;;; ══════════════════════════════════════════════════════════════════════════════

(define (qualified-demand-o facts spec-id today dlt-days ost-horizon ost-mult adu qd)
  "OST-filtered demand from commitments + intents."
  (project (facts spec-id today dlt-days ost-horizon ost-mult adu)
    (let* ((hz (or ost-horizon (inexact->exact (ceiling (* dlt-days 0.5)))))
           (he (+ today (* hz *seconds-per-day*)))
           (spike (and ost-mult (* adu ost-mult)))
           (cm (fold (lambda (f a)
                       (if (and (eq? (car f) 'commitment)
                                (equal? (cadddr f) spec-id)
                                (not (list-ref f 8))
                                (memq (caddr f) *consuming-actions*)
                                (list-ref f 5) (<= (list-ref f 5) he))
                           (let ((q (or (list-ref f 4) 0)))
                             (if (and spike (> q spike)) a (+ a q)))
                           a))
                     0 facts))
           (it (fold (lambda (f a)
                       (if (and (eq? (car f) 'intent)
                                (equal? (cadddr f) spec-id)
                                (eq? (list-ref f 7) 'input)
                                (not (list-ref f 10))
                                (not (memq (caddr f) *non-consuming*))
                                (list-ref f 6) (<= (list-ref f 6) he))
                           (let ((q (or (list-ref f 4) 0)))
                             (if (and spike (> q spike)) a (+ a q)))
                           a))
                     0 facts)))
      (== qd (+ cm it)))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; NFP computation
;;; ══════════════════════════════════════════════════════════════════════════════

(define (onhand-at-location-o facts spec-id at-location onhand)
  (project (facts spec-id at-location)
    (== onhand (fold (lambda (f a)
                       (if (and (eq? (car f) 'inventory) (equal? (caddr f) spec-id)
                                (or (not at-location) (equal? (list-ref f 3) at-location)))
                           (+ a (cadddr f)) a))
                     0 facts))))

(define (onorder-o facts spec-id onorder)
  (project (facts spec-id)
    (== onorder (fold (lambda (f a)
                        (if (and (eq? (car f) 'commitment) (equal? (cadddr f) spec-id)
                                 (not (list-ref f 8)) (memq (caddr f) '(produce transfer)))
                            (+ a (or (list-ref f 4) 0)) a))
                      0 facts))))

(define (nfp-o onhand onorder qd nfp)
  (fresh (supply) (+fd onhand onorder supply) (-fd supply qd nfp)))

(define (compute-nfp-o facts spec-id today at-loc result)
  (fresh (onhand onorder qd nfp tor toy tog adu dlt zone)
    (buffer-zone-fact-o facts spec-id tor toy tog adu dlt)
    (onhand-at-location-o facts spec-id at-loc onhand)
    (onorder-o facts spec-id onorder)
    (qualified-demand-o facts spec-id today dlt #f #f adu qd)
    (nfp-o onhand onorder qd nfp)
    (zone-o nfp tor toy tog zone)
    (project (nfp tog)
      (== result `((nfp . ,nfp) (onhand . ,onhand) (onorder . ,onorder)
                   (qualified-demand . ,qd) (zone . ,zone)
                   (priority . ,(if (> tog 0) (/ nfp tog) 1.0)))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Buffer level computation (full Ptak & Smith formula)
;;; ══════════════════════════════════════════════════════════════════════════════

(define (buffer-levels-o adu dlt ltf vf moq doc-days
                         daf ltaf zaf-r zaf-y zaf-g
                         tor toy tog red-base red-safety)
  (project (adu dlt ltf vf moq doc-days daf ltaf zaf-r zaf-y zaf-g)
    (let* ((ea (* adu daf)) (ed (* dlt ltaf))
           (rb (* ea ed ltf)) (rs (* rb vf))
           (tr (* (+ rb rs) zaf-r))
           (ty (+ tr (* ea ed zaf-y)))
           (gr (max (* ea doc-days) rb moq))
           (tg (+ ty (* gr zaf-g))))
      (fresh ()
        (== red-base (inexact->exact (round rb)))
        (== red-safety (inexact->exact (round rs)))
        (== tor (inexact->exact (round tr)))
        (== toy (inexact->exact (round ty)))
        (== tog (inexact->exact (round tg)))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Adjustment factor aggregation
;;; ══════════════════════════════════════════════════════════════════════════════

(define (aggregate-adjustments-o facts spec-id as-of at-loc result)
  (project (facts spec-id as-of at-loc)
    (let* ((active (filter (lambda (f)
                             (and (eq? (car f) 'adjustment-factor)
                                  (equal? (cadr f) spec-id)
                                  (or (not (list-ref f 6)) (not at-loc)
                                      (equal? (list-ref f 6) at-loc))
                                  (<= (list-ref f 4) as-of)
                                  (>= (list-ref f 5) as-of)))
                           facts)))
      (== result
           (fold (lambda (f acc)
                   (let* ((typ (caddr f)) (fac (cadddr f))
                          (cur (or (assq-ref acc typ) 1.0)))
                     (cons (cons typ (* cur fac))
                           (filter (lambda (p) (not (eq? (car p) typ))) acc))))
                 '((demand . 1.0) (lead-time . 1.0) (red . 1.0)
                   (yellow . 1.0) (green . 1.0))
                 active)))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Replenishment signal (with MOQ rounding + due-date)
;;; ══════════════════════════════════════════════════════════════════════════════

(define (replenishment-signal-o nfp zone tog spec-id moq dlt offset today signal)
  (conde
    ((conde ((== zone 'red)) ((== zone 'yellow)))
     (project (nfp tog moq dlt offset today)
       (let* ((raw (- tog nfp))
              (qty (if (and moq (> moq 0))
                       (inexact->exact (* (ceiling (/ raw moq)) moq))
                       (inexact->exact (round raw))))
              (due (+ today (* (+ (inexact->exact (ceiling dlt)) (or offset 0))
                               *seconds-per-day*))))
         (signal-o 'replenishment spec-id qty 'ddmrp signal))))
    ((conde ((== zone 'green)) ((== zone 'excess)))
     (== signal #f))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Prioritized share allocation (3-phase zone-fill)
;;; ══════════════════════════════════════════════════════════════════════════════

(define (prioritized-share-o slots total-supply result)
  (project (slots total-supply)
    (let* ((remaining total-supply)
           (allocs (make-hash-table))
           (ref (lambda (id) (or (hash-ref allocs id) 0)))
           (set! (lambda (id v) (hash-set! allocs id v)))
           ;; Phase 1: fill to TOR
           (_ (for-each (lambda (s)
                (let* ((id (assq-ref s 'id)) (oh (assq-ref s 'onhand))
                       (gap (max 0 (- (assq-ref s 'tor) oh)))
                       (a (min gap remaining)))
                  (when (> a 0) (set! id a) (set! remaining (- remaining a))))) slots))
           ;; Phase 2: fill to TOY
           (_ (when (> remaining *epsilon*)
                (for-each (lambda (s)
                  (let* ((id (assq-ref s 'id)) (al (ref id))
                         (oh (+ (assq-ref s 'onhand) al))
                         (gap (max 0 (- (assq-ref s 'toy) oh)))
                         (a (min gap remaining)))
                    (when (> a 0) (set! id (+ al a)) (set! remaining (- remaining a))))) slots)))
           ;; Phase 3: distribute by green proportion
           (_ (when (> remaining *epsilon*)
                (let ((tg (fold (lambda (s a)
                                  (+ a (- (assq-ref s 'tog) (assq-ref s 'toy)))) 0 slots)))
                  (when (> tg 0)
                    (for-each (lambda (s)
                      (let* ((id (assq-ref s 'id))
                             (g (- (assq-ref s 'tog) (assq-ref s 'toy)))
                             (a (* remaining (/ g tg))) (al (ref id)))
                        (when (> a *epsilon*) (set! id (+ al a))))) slots))))))
      (== result (hash-map->list cons allocs)))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Analytics
;;; ══════════════════════════════════════════════════════════════════════════════

(define (adu-differential-o old new pct)
  (project (old new)
    (== pct (if (> old 0) (* (/ (- new old) old) 100) 0))))

(define (detect-adu-alert-o history alert)
  (project (history)
    (let* ((m (if (null? history) 0 (/ (apply + history) (length history))))
           (l (if (null? history) 0 (car history))))
      (cond ((> l (* m 2)) (== alert 'spike))
            ((< l (* m 0.2)) (== alert 'void))
            (else (== alert #f))))))

(define (adu-drift-o series threshold alert)
  (project (series threshold)
    (if (< (length series) 3) (== alert #f)
        (let* ((diffs (let lp ((s series) (a '()))
                        (if (null? (cdr s)) (reverse a)
                            (lp (cdr s) (cons (- (cadr s) (car s)) a)))))
               (td (apply + diffs)))
          (cond ((and (every positive? diffs) (> td threshold)) (== alert 'rising))
                ((and (every negative? diffs) (> (abs td) threshold)) (== alert 'falling))
                (else (== alert #f)))))))

(define (ltm-alert-o due-sec dlt-days today zone)
  (project (due-sec dlt-days today)
    (let* ((dr (/ (- due-sec today) *seconds-per-day*)) (ah (/ dlt-days 3)))
      (if (> dr ah) (== zone #f)
          (let ((th (/ ah 3)))
            (cond ((> dr (* th 2)) (== zone 'green))
                  ((> dr th) (== zone 'yellow))
                  (else (== zone 'red))))))))

(define (ltm-5zone-o due-sec dlt-days today zone)
  (project (due-sec dlt-days today)
    (let ((dr (/ (- due-sec today) *seconds-per-day*)))
      (cond ((< dr 0) (== zone 'late))
            ((< dr (/ dlt-days 9)) (== zone 'red))
            ((< dr (/ dlt-days 4.5)) (== zone 'yellow))
            ((< dr (/ dlt-days 3)) (== zone 'green))
            (else (== zone 'early))))))

(define (material-release-date-o due leg-days release)
  (project (due leg-days)
    (== release (- due (* leg-days *seconds-per-day*)))))

(define (on-hand-alert-o onhand tor fraction alert)
  (project (onhand tor fraction)
    (== alert (if (< onhand (* tor fraction)) 'critical #f))))

(define (time-buffer-o onhand adu days)
  (project (onhand adu) (== days (if (> adu 0) (/ onhand adu) 999))))

(define (execution-priority-o nfp tog priority)
  (project (nfp tog) (== priority (if (> tog 0) (/ nfp tog) 1.0))))

(define (sort-by-priority-o slots sorted)
  (project (slots)
    (== sorted (sort slots (lambda (a b)
      (let ((ga (or (assq-ref a 'sequence-group) 0))
            (gb (or (assq-ref b 'sequence-group) 0)))
        (if (not (= ga gb)) (< ga gb)
            (< (or (assq-ref a 'nfp-pct) 0) (or (assq-ref b 'nfp-pct) 0)))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; On-hand projection
;;; ══════════════════════════════════════════════════════════════════════════════

(define (project-on-hand-o facts spec-id today dlt-days init-oh tor toy tog projection)
  (project (facts spec-id today dlt-days init-oh tor toy tog)
    (let ((days (max 1 (inexact->exact (ceiling dlt-days)))))
      (== projection
           (let loop ((d 0) (oh init-oh) (acc '()))
             (if (> d days) (reverse acc)
                 (let* ((ds (+ today (* d *seconds-per-day*)))
                        (de (+ ds *seconds-per-day*))
                        (dem (fold (lambda (f a)
                               (cond ((and (eq? (car f) 'commitment) (equal? (cadddr f) spec-id)
                                           (memq (caddr f) *consuming-actions*)
                                           (list-ref f 5) (>= (list-ref f 5) ds) (< (list-ref f 5) de))
                                      (+ a (or (list-ref f 4) 0)))
                                     ((and (eq? (car f) 'intent) (equal? (cadddr f) spec-id)
                                           (eq? (list-ref f 7) 'input)
                                           (list-ref f 6) (>= (list-ref f 6) ds) (< (list-ref f 6) de))
                                      (+ a (or (list-ref f 4) 0)))
                                     (else a))) 0 facts))
                        (rec (fold (lambda (f a)
                               (if (and (eq? (car f) 'commitment) (equal? (cadddr f) spec-id)
                                        (memq (caddr f) '(produce transfer)) (not (list-ref f 8))
                                        (list-ref f 5) (>= (list-ref f 5) ds) (< (list-ref f 5) de))
                                   (+ a (or (list-ref f 4) 0)) a)) 0 facts))
                        (noh (- (+ oh rec) dem))
                        (z (cond ((<= noh tor) 'red) ((<= noh toy) 'yellow)
                                 ((<= noh tog) 'green) (else 'excess))))
                   (loop (+ d 1) noh
                         (cons `((day . ,d) (demand . ,dem) (receipts . ,rec)
                                 (projected-onhand . ,(inexact->exact (round noh)))
                                 (zone . ,z)) acc)))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Buffer recalibration
;;; ══════════════════════════════════════════════════════════════════════════════

(define (recalibrate-buffer-o facts spec-id new-adu new-dlt
                               ltf vf moq doc-days as-of result)
  (fresh (tor toy tog rb rs adj daf ltaf zr zy zg)
    (aggregate-adjustments-o facts spec-id as-of #f adj)
    (project (adj)
      (fresh ()
        (== daf (or (assq-ref adj 'demand) 1.0))
        (== ltaf (or (assq-ref adj 'lead-time) 1.0))
        (== zr (or (assq-ref adj 'red) 1.0))
        (== zy (or (assq-ref adj 'yellow) 1.0))
        (== zg (or (assq-ref adj 'green) 1.0))))
    (buffer-levels-o new-adu new-dlt ltf vf moq doc-days daf ltaf zr zy zg
                     tor toy tog rb rs)
    (== result `((spec-id . ,spec-id) (adu . ,new-adu) (dlt . ,new-dlt)
                 (tor . ,tor) (toy . ,toy) (tog . ,tog)
                 (red-base . ,rb) (red-safety . ,rs)))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Full DDMRP evaluation
;;; ══════════════════════════════════════════════════════════════════════════════

(define (ddmrp-evaluate-o facts spec-id today result)
  (fresh (tor toy tog adu dlt oh oo qd nfp zone sig)
    (buffer-zone-fact-o facts spec-id tor toy tog adu dlt)
    (onhand-at-location-o facts spec-id #f oh)
    (onorder-o facts spec-id oo)
    (qualified-demand-o facts spec-id today dlt #f #f adu qd)
    (nfp-o oh oo qd nfp)
    (zone-o nfp tor toy tog zone)
    (replenishment-signal-o nfp zone tog spec-id 0 dlt 0 today sig)
    (== result `((spec-id . ,spec-id) (onhand . ,oh) (onorder . ,oo)
                 (qualified-demand . ,qd) (nfp . ,nfp) (zone . ,zone)
                 (signal . ,sig)))))
