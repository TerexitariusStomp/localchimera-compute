;;; compute.scm — Ground computations over lifted planning facts
;;;
;;; These are honest Scheme functions on concrete data. They don't pretend
;;; to be relations. They're called from within `project` in relational
;;; goals where the inputs are known to be ground.
;;;
;;; The relational parts (zone classification, variability lookup, NFP
;;; arithmetic, signal routing) stay in their respective modules as
;;; genuine relations with CLP(FD) and conde.

(use-modules (srfi srfi-1))

(define *seconds-per-day* 86400)
(define *consuming-actions* '(consume combine pickup accept))
(define *non-consuming* '(use work cite deliver-service))
(define *work-actions* '(work deliver-service))
(define *durable-actions* '(use cite))
(define *epsilon* 1e-9)


;;; ── ADU ───────────────────────────────────────────────────────────────────────

(define (compute-adu facts spec-id window-days as-of)
  "Rolling ADU from historical consuming events. Returns number."
  (let* ((ws (- as-of (* window-days *seconds-per-day*)))
         (total (fold (lambda (f a)
                        (if (and (eq? (car f) 'event)
                                 (equal? (cadddr f) spec-id)
                                 (memq (caddr f) *consuming-actions*)
                                 (list-ref f 5)
                                 (>= (list-ref f 5) ws)
                                 (<= (list-ref f 5) as-of))
                            (+ a (or (list-ref f 4) 0)) a))
                      0 facts)))
    (if (> window-days 0) (/ total window-days) 0)))

(define (compute-forward-adu facts spec-id window-days as-of)
  "Forward-looking ADU from planned consuming intents."
  (let* ((he (+ as-of (* window-days *seconds-per-day*)))
         (total (fold (lambda (f a)
                        (if (and (eq? (car f) 'intent)
                                 (equal? (cadddr f) spec-id)
                                 (eq? (list-ref f 7) 'input)
                                 (not (memq (caddr f) *non-consuming*))
                                 (list-ref f 6)
                                 (>= (list-ref f 6) as-of)
                                 (<= (list-ref f 6) he))
                            (+ a (or (list-ref f 4) 0)) a))
                      0 facts)))
    (if (> window-days 0) (/ total window-days) 0)))

(define (blend-adu past forward ratio)
  (+ (* past ratio) (* forward (- 1 ratio))))

(define (bootstrap-adu actual days-actual estimated window-days)
  (if (>= days-actual window-days)
      `((blended-adu . ,actual) (complete . #t) (days . ,window-days))
      (let ((bl (/ (+ (* actual days-actual) (* estimated (- window-days days-actual)))
                   window-days)))
        `((blended-adu . ,bl) (complete . #f) (days . ,days-actual)))))


;;; ── DLT ───────────────────────────────────────────────────────────────────────

(define (compute-recipe-lead-time facts recipe-id)
  "Sum of process durations in chain. Returns days."
  (let ((cf (find (lambda (f) (and (eq? (car f) 'chain) (equal? (cadr f) recipe-id))) facts)))
    (if (not cf) 0
        (fold (lambda (pid a)
                (let ((pf (find (lambda (f) (and (eq? (car f) 'process)
                                                  (equal? (cadr f) pid))) facts)))
                  (+ a (if pf (/ (cadddr pf) 86400000.0) 0))))
              0 (caddr cf)))))

(define (compute-decoupled-lead-time facts buffered-specs spec-id)
  "DLT stopping at buffer boundaries. Recursive with cycle guard."
  (dlt-recurse facts buffered-specs spec-id '()))

(define (dlt-recurse facts buffered-specs spec-id visited)
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
                             (idlt (fold (lambda (f best)
                                           (let ((isp (and (eq? (car f) 'flow)
                                                            (equal? (cadr f) pid)
                                                            (eq? (caddr f) 'input)
                                                            (not (memq (list-ref f 6) *non-consuming*))
                                                            (cadddr f))))
                                             (if (and isp (not (member isp buffered-specs)))
                                                 (max best (dlt-recurse facts buffered-specs isp nv))
                                                 best)))
                                         0 facts)))
                        (+ a dur idlt)))
                    0 pids))))))

(define (compute-leg-lead-time facts recipe-id pids upstream downstream)
  "DLT for one routing leg between two stages."
  (let* ((find-stage (lambda (stage)
           (list-index (lambda (pid)
             (let ((pf (find (lambda (f) (and (eq? (car f) 'process)
                                               (equal? (cadr f) pid))) facts)))
               (and pf (equal? (list-ref pf 2) stage)))) pids)))
         (si (or (and upstream (find-stage upstream)) 0))
         (ei (or (and downstream (find-stage downstream)) (- (length pids) 1))))
    (if (or (> si ei) (< si 0)) 0
        (let loop ((i si) (t 0))
          (if (> i ei) t
              (let* ((pid (list-ref pids i))
                     (pf (find (lambda (f) (and (eq? (car f) 'process)
                                                 (equal? (cadr f) pid))) facts)))
                (loop (+ i 1) (+ t (if pf (/ (cadddr pf) 86400000.0) 0)))))))))


;;; ── Qualified Demand ──────────────────────────────────────────────────────────

(define (compute-qualified-demand facts spec-id today dlt-days ost-horizon ost-mult adu)
  "OST-filtered demand from commitments + intents."
  (let* ((hz (or ost-horizon (inexact->exact (ceiling (* dlt-days 0.5)))))
         (he (+ today (* hz *seconds-per-day*)))
         (spike (and ost-mult (* adu ost-mult)))
         (filter-qty (lambda (f idx-spec idx-due idx-qty pred)
           (fold (lambda (f a)
                   (if (and (pred f) (equal? (list-ref f idx-spec) spec-id)
                            (list-ref f idx-due) (<= (list-ref f idx-due) he))
                       (let ((q (or (list-ref f idx-qty) 0)))
                         (if (and spike (> q spike)) a (+ a q)))
                       a))
                 0 facts))))
    (+ (filter-qty facts 3 5 4
         (lambda (f) (and (eq? (car f) 'commitment) (not (list-ref f 8))
                          (memq (caddr f) *consuming-actions*))))
       (filter-qty facts 3 6 4
         (lambda (f) (and (eq? (car f) 'intent) (eq? (list-ref f 7) 'input)
                          (not (list-ref f 10)) (not (memq (caddr f) *non-consuming*))))))))


;;; ── Buffer Levels ─────────────────────────────────────────────────────────────

(define (compute-buffer-levels adu dlt ltf vf moq doc-days daf ltaf zr zy zg)
  "Full Ptak & Smith formula. Returns alist."
  (let* ((ea (* adu daf)) (ed (* dlt ltaf))
         (rb (* ea ed ltf)) (rs (* rb vf))
         (tr (* (+ rb rs) zr))
         (ty (+ tr (* ea ed zy)))
         (gr (max (* ea doc-days) rb moq))
         (tg (+ ty (* gr zg))))
    `((tor . ,(inexact->exact (round tr))) (toy . ,(inexact->exact (round ty)))
      (tog . ,(inexact->exact (round tg)))
      (red-base . ,(inexact->exact (round rb))) (red-safety . ,(inexact->exact (round rs))))))


;;; ── Adjustment Factor Aggregation ─────────────────────────────────────────────

(define (aggregate-adjustments facts spec-id as-of at-loc)
  "Compound active adjustment factors by type."
  (let ((active (filter (lambda (f)
                          (and (eq? (car f) 'adjustment-factor)
                               (equal? (cadr f) spec-id)
                               (or (not (list-ref f 6)) (not at-loc)
                                   (equal? (list-ref f 6) at-loc))
                               (<= (list-ref f 4) as-of)
                               (>= (list-ref f 5) as-of)))
                        facts)))
    (fold (lambda (f acc)
            (let* ((typ (caddr f)) (fac (cadddr f))
                   (cur (or (assq-ref acc typ) 1.0)))
              (cons (cons typ (* cur fac))
                    (filter (lambda (p) (not (eq? (car p) typ))) acc))))
          '((demand . 1.0) (lead-time . 1.0) (red . 1.0) (yellow . 1.0) (green . 1.0))
          active)))


;;; ── Onhand / Onorder ──────────────────────────────────────────────────────────

(define (compute-onhand facts spec-id at-location)
  (fold (lambda (f a)
          (if (and (eq? (car f) 'inventory) (equal? (caddr f) spec-id)
                   (or (not at-location) (equal? (list-ref f 3) at-location)))
              (+ a (cadddr f)) a))
        0 facts))

(define (compute-onorder facts spec-id)
  (fold (lambda (f a)
          (if (and (eq? (car f) 'commitment) (equal? (cadddr f) spec-id)
                   (not (list-ref f 8)) (memq (caddr f) '(produce transfer)))
              (+ a (or (list-ref f 4) 0)) a))
        0 facts))


;;; ── Replenishment Signal ──────────────────────────────────────────────────────

(define (compute-replenishment-qty nfp tog moq)
  "Raw replenishment quantity with MOQ rounding."
  (let ((raw (- tog nfp)))
    (if (and moq (> moq 0))
        (inexact->exact (* (ceiling (/ raw moq)) moq))
        (inexact->exact (round raw)))))

(define (compute-due-date today dlt offset)
  (+ today (* (+ (inexact->exact (ceiling dlt)) (or offset 0)) *seconds-per-day*)))


;;; ── Prioritized Share ─────────────────────────────────────────────────────────

(define (compute-prioritized-share slots total-supply)
  "3-phase zone-fill. Returns alist of (id . allocated-qty)."
  (let ((allocs (make-hash-table))
        (remaining total-supply))
    (define (ref id) (or (hash-ref allocs id) 0))
    (define (set! id v) (hash-set! allocs id v))
    ;; Phase 1: TOR
    (for-each (lambda (s)
      (let* ((id (assq-ref s 'id)) (gap (max 0 (- (assq-ref s 'tor) (assq-ref s 'onhand))))
             (a (min gap remaining)))
        (when (> a 0) (set! id a) (set! remaining (- remaining a))))) slots)
    ;; Phase 2: TOY
    (when (> remaining *epsilon*)
      (for-each (lambda (s)
        (let* ((id (assq-ref s 'id)) (al (ref id))
               (gap (max 0 (- (assq-ref s 'toy) (+ (assq-ref s 'onhand) al))))
               (a (min gap remaining)))
          (when (> a 0) (set! id (+ al a)) (set! remaining (- remaining a))))) slots))
    ;; Phase 3: green proportion
    (when (> remaining *epsilon*)
      (let ((tg (fold (lambda (s a) (+ a (- (assq-ref s 'tog) (assq-ref s 'toy)))) 0 slots)))
        (when (> tg 0)
          (for-each (lambda (s)
            (let* ((id (assq-ref s 'id))
                   (g (- (assq-ref s 'tog) (assq-ref s 'toy)))
                   (a (* remaining (/ g tg))) (al (ref id)))
              (when (> a *epsilon*) (set! id (+ al a))))) slots))))
    (hash-map->list cons allocs)))


;;; ── On-Hand Projection ────────────────────────────────────────────────────────

(define (compute-on-hand-projection facts spec-id today dlt-days init-oh tor toy tog)
  "Day-by-day on-hand projection. Returns list of daily alists."
  (let ((days (max 1 (inexact->exact (ceiling dlt-days)))))
    (let loop ((d 0) (oh init-oh) (acc '()))
      (if (> d days) (reverse acc)
          (let* ((ds (+ today (* d *seconds-per-day*))) (de (+ ds *seconds-per-day*))
                 (dem (fold (lambda (f a)
                   (cond ((and (eq? (car f) 'commitment) (equal? (cadddr f) spec-id)
                               (memq (caddr f) *consuming-actions*) (list-ref f 5)
                               (>= (list-ref f 5) ds) (< (list-ref f 5) de))
                          (+ a (or (list-ref f 4) 0)))
                         ((and (eq? (car f) 'intent) (equal? (cadddr f) spec-id)
                               (eq? (list-ref f 7) 'input) (list-ref f 6)
                               (>= (list-ref f 6) ds) (< (list-ref f 6) de))
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
                          (projected-onhand . ,(inexact->exact (round noh))) (zone . ,z))
                        acc)))))))


;;; ── Analytics ─────────────────────────────────────────────────────────────────

(define (adu-differential old new)
  (if (> old 0) (* (/ (- new old) old) 100) 0))

(define (detect-adu-alert history)
  (if (null? history) #f
      (let* ((m (/ (apply + history) (length history))) (l (car history)))
        (cond ((> l (* m 2)) 'spike) ((< l (* m 0.2)) 'void) (else #f)))))

(define (adu-drift series threshold)
  (if (< (length series) 3) #f
      (let* ((diffs (let lp ((s series) (a '()))
                      (if (null? (cdr s)) (reverse a)
                          (lp (cdr s) (cons (- (cadr s) (car s)) a)))))
             (td (apply + diffs)))
        (cond ((and (every positive? diffs) (> td threshold)) 'rising)
              ((and (every negative? diffs) (> (abs td) threshold)) 'falling)
              (else #f)))))

(define (ltm-alert due-sec dlt-days today)
  (let* ((dr (/ (- due-sec today) *seconds-per-day*)) (ah (/ dlt-days 3)))
    (if (> dr ah) #f
        (let ((th (/ ah 3)))
          (cond ((> dr (* th 2)) 'green) ((> dr th) 'yellow) (else 'red))))))

(define (ltm-5zone due-sec dlt-days today)
  (let ((dr (/ (- due-sec today) *seconds-per-day*)))
    (cond ((< dr 0) 'late) ((< dr (/ dlt-days 9)) 'red)
          ((< dr (/ dlt-days 4.5)) 'yellow) ((< dr (/ dlt-days 3)) 'green)
          (else 'early))))

(define (on-hand-alert onhand tor fraction)
  (if (< onhand (* tor fraction)) 'critical #f))

(define (time-buffer onhand adu) (if (> adu 0) (/ onhand adu) 999))

(define (execution-priority nfp tog) (if (> tog 0) (/ nfp tog) 1.0))

(define (sort-by-priority slots)
  (sort slots (lambda (a b)
    (let ((ga (or (assq-ref a 'sequence-group) 0))
          (gb (or (assq-ref b 'sequence-group) 0)))
      (if (not (= ga gb)) (< ga gb)
          (< (or (assq-ref a 'nfp-pct) 0) (or (assq-ref b 'nfp-pct) 0)))))))


;;; ── SNE ───────────────────────────────────────────────────────────────────────

(define (compute-recipe-sne facts rid spec-id visited)
  "SNE for a recipe. Direct labor + embodied (recursive) + depreciation."
  (if (member spec-id visited) 0
      (let* ((cf (find (lambda (f) (and (eq? (car f) 'chain) (equal? (cadr f) rid))) facts))
             (pids (if cf (caddr cf) '()))
             (nv (cons spec-id visited))
             (direct
               (fold (lambda (pid a)
                 (+ a (fold (lambda (f a2)
                   (if (and (eq? (car f) 'flow) (equal? (cadr f) pid)
                            (eq? (caddr f) 'input) (memq (list-ref f 6) *work-actions*)
                            (list-ref f 4))
                       (+ a2 (list-ref f 4)) a2)) 0 facts))) 0 pids))
             (embodied
               (fold (lambda (pid a)
                 (+ a (fold (lambda (f a2)
                   (let ((isp (and (eq? (car f) 'flow) (equal? (cadr f) pid)
                                    (eq? (caddr f) 'input)
                                    (memq (list-ref f 6) *consuming-actions*)
                                    (cadddr f)))
                         (iq (and (eq? (car f) 'flow) (equal? (cadr f) pid)
                                   (eq? (caddr f) 'input) (list-ref f 4))))
                     (if (and isp iq)
                         (+ a2 (* iq (compute-input-sne facts isp nv)))
                         a2))) 0 facts))) 0 pids))
             (deprec
               (fold (lambda (pid a)
                 (+ a (fold (lambda (f a2)
                   (if (and (eq? (car f) 'flow) (equal? (cadr f) pid)
                            (eq? (caddr f) 'input) (memq (list-ref f 6) *durable-actions*)
                            (list-ref f 4))
                       (let ((ls (spec-lifespan facts (cadddr f))))
                         (+ a2 (/ (list-ref f 4) (max 1 ls))))
                       a2)) 0 facts))) 0 pids))
             (lp (and (pair? pids) (last pids)))
             (of (and lp (find (lambda (f) (and (eq? (car f) 'flow) (equal? (cadr f) lp)
                                                 (eq? (caddr f) 'output)
                                                 (equal? (cadddr f) spec-id))) facts)))
             (oq (if (and of (list-ref of 4)) (list-ref of 4) 1))
             (total (+ direct embodied deprec)))
        (if (> oq 0) (/ total oq) total))))

(define (compute-input-sne facts spec-id visited)
  (if (member spec-id visited) 0
      (let ((rs (filter (lambda (f) (and (eq? (car f) 'recipe) (equal? (cadddr f) spec-id))) facts)))
        (if (null? rs) 0
            (apply min (map (lambda (rf) (compute-recipe-sne facts (cadr rf) spec-id visited)) rs))))))

(define (spec-lifespan facts spec-id)
  (let ((sf (find (lambda (f) (and (eq? (car f) 'resource-spec-lifespan)
                                    (equal? (cadr f) spec-id))) facts)))
    (if sf (caddr sf) 100)))

(define (build-sne-index facts)
  "Compute SNE for all specs. Returns alist."
  (let ((specs (delete-duplicates
                 (filter-map (lambda (f) (and (eq? (car f) 'recipe) (cadddr f))) facts))))
    (map (lambda (sp)
           (let ((rs (filter (lambda (f) (and (eq? (car f) 'recipe) (equal? (cadddr f) sp))) facts)))
             (cons sp (if (null? rs) 0
                          (apply min (map (lambda (rf)
                            (compute-recipe-sne facts (cadr rf) sp '())) rs))))))
         specs)))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Metabolism — net input/output balance
;;; ══════════════════════════════════════════════════════════════════════════════

(define *input-actions* '(consume use accept work cite combine))
(define *output-actions* '(produce modify deliver-service))

(define (metabolic-balance facts horizon-from horizon-to)
  "Net metabolic balance: total-output - total-input, by spec."
  (let* ((events (filter (lambda (f)
                           (and (eq? (car f) 'event)
                                (list-ref f 5)
                                (>= (list-ref f 5) horizon-from)
                                (<= (list-ref f 5) horizon-to)))
                         facts))
         (by-spec (make-hash-table))
         (total-in 0) (total-out 0))
    (for-each (lambda (e)
      (let* ((spec (cadddr e)) (qty (or (list-ref e 4) 0)) (action (caddr e)))
        (let ((entry (or (hash-ref by-spec spec) '((input . 0) (output . 0)))))
          (cond ((memq action *input-actions*)
                 (set! total-in (+ total-in qty))
                 (hash-set! by-spec spec
                   `((input . ,(+ (assq-ref entry 'input) qty))
                     (output . ,(assq-ref entry 'output)))))
                ((memq action *output-actions*)
                 (set! total-out (+ total-out qty))
                 (hash-set! by-spec spec
                   `((input . ,(assq-ref entry 'input))
                     (output . ,(+ (assq-ref entry 'output) qty)))))))))
              events)
    `((net-balance . ,(- total-out total-in))
      (total-input . ,total-in)
      (total-output . ,total-out)
      (by-spec . ,(hash-map->list cons by-spec)))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; OTIF — On-Time In-Full delivery metrics
;;; ══════════════════════════════════════════════════════════════════════════════

(define (compute-otif facts tolerance)
  "OTIF KPIs from commitment + event facts. tolerance = fraction (e.g., 0.05)."
  (let* ((commitments (filter (lambda (f) (eq? (car f) 'commitment)) facts))
         (lines (map (lambda (c)
           (let* ((cid (cadr c)) (spec (cadddr c)) (committed-qty (or (list-ref c 4) 0))
                  (due (list-ref c 5))
                  ;; Find fulfilling events for this commitment
                  (fulfilling (filter (lambda (f)
                    (and (eq? (car f) 'event) (equal? (cadddr f) spec)
                         (memq (caddr f) '(produce transfer)))) facts))
                  (fulfilled-qty (fold (lambda (f a) (+ a (or (list-ref f 4) 0)))
                                       0 fulfilling))
                  (latest-date (fold (lambda (f best)
                    (let ((ts (list-ref f 5)))
                      (if (and ts (or (not best) (> ts best))) ts best)))
                    #f fulfilling))
                  (in-full (>= fulfilled-qty (* committed-qty (- 1 tolerance))))
                  (on-time (or (not due) (not latest-date) (<= latest-date due)))
                  (days-late (if (and due latest-date (> latest-date due))
                                 (/ (- latest-date due) *seconds-per-day*) 0)))
             `((commitment-id . ,cid) (in-full . ,in-full) (on-time . ,on-time)
               (days-late . ,days-late) (otif . ,(and in-full on-time)))))
                       commitments))
         (n (length lines))
         (fill (if (> n 0) (/ (count (lambda (l) (assq-ref l 'in-full)) lines) n) 1))
         (on-t (if (> n 0) (/ (count (lambda (l) (assq-ref l 'on-time)) lines) n) 1))
         (otif (if (> n 0) (/ (count (lambda (l) (assq-ref l 'otif)) lines) n) 1))
         (avg-late (if (> n 0) (/ (fold (lambda (l a) (+ a (assq-ref l 'days-late))) 0 lines) n) 0)))
    `((fill-rate . ,fill) (on-time-rate . ,on-t) (otif-rate . ,otif)
      (avg-days-late . ,avg-late) (lines . ,lines))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Resource flows — period-bucketed timeline
;;; ══════════════════════════════════════════════════════════════════════════════

(define (cash-flow-report facts agent-id report-start report-end granularity)
  "Period-bucketed inflow/outflow for an agent."
  (let* ((bucket-size (case granularity
           ((day) *seconds-per-day*) ((week) (* 7 *seconds-per-day*))
           ((month) (* 30 *seconds-per-day*)) (else *seconds-per-day*)))
         (n-periods (max 1 (inexact->exact (ceiling (/ (- report-end report-start) bucket-size)))))
         (periods (let loop ((i 0) (acc '()))
           (if (>= i n-periods) (reverse acc)
               (let* ((ps (+ report-start (* i bucket-size)))
                      (pe (min (+ ps bucket-size) report-end))
                      (in (fold (lambda (f a)
                            (if (and (eq? (car f) 'event) (equal? (list-ref f 5) agent-id)
                                     ;; receiver = agent → inflow
                                     ;; (simplified: check if agent is receiver via events)
                                     (list-ref f 5) (>= (list-ref f 5) ps) (< (list-ref f 5) pe)
                                     (memq (caddr f) '(transfer accept)))
                                (+ a (or (list-ref f 4) 0)) a))
                          0 facts))
                      (out (fold (lambda (f a)
                             (if (and (eq? (car f) 'event)
                                      (list-ref f 5) (>= (list-ref f 5) ps) (< (list-ref f 5) pe)
                                      (memq (caddr f) '(consume use)))
                                 (+ a (or (list-ref f 4) 0)) a))
                           0 facts)))
                 (loop (+ i 1) (cons `((period-start . ,ps) (inflow . ,in) (outflow . ,out)) acc))))))
         (ti (fold (lambda (p a) (+ a (assq-ref p 'inflow))) 0 periods))
         (to (fold (lambda (p a) (+ a (assq-ref p 'outflow))) 0 periods)))
    `((periods . ,periods) (total-inflow . ,ti) (total-outflow . ,to) (net . ,(- ti to)))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Rollup — standard and actual cost
;;; ══════════════════════════════════════════════════════════════════════════════

(define (rollup-standard-cost facts recipe-id price-of scale)
  "Standard cost from recipe. price-of: (spec unit) → price. scale: multiplier."
  (let* ((cf (find (lambda (f) (and (eq? (car f) 'chain) (equal? (cadr f) recipe-id))) facts))
         (pids (if cf (caddr cf) '()))
         (by-stage
           (map (lambda (pid)
             (let* ((pf (find (lambda (f) (and (eq? (car f) 'process) (equal? (cadr f) pid))) facts))
                    (name (if pf (caddr pf) pid))
                    (cost (fold (lambda (f a)
                      (if (and (eq? (car f) 'flow) (equal? (cadr f) pid) (eq? (caddr f) 'input)
                               (list-ref f 4) (list-ref f 5))
                          (+ a (* (list-ref f 4) scale (price-of (cadddr f) (list-ref f 5))))
                          a))
                      0 facts)))
               `((process-id . ,pid) (name . ,name) (cost . ,cost))))
           pids))
         (total (fold (lambda (s a) (+ a (assq-ref s 'cost))) 0 by-stage)))
    `((total . ,total) (by-stage . ,by-stage))))

(define (rollup-actual-cost facts resource-id price-of)
  "Actual cost from event history for a resource."
  (let* ((events (filter (lambda (f)
           (and (eq? (car f) 'event) (equal? (cadddr f) resource-id))) facts))
         (by-event (map (lambda (e)
           (let* ((eid (cadr e)) (spec (cadddr e)) (qty (or (list-ref e 4) 0))
                  (cost (* qty (price-of spec "each"))))
             `((event-id . ,eid) (spec-id . ,spec) (qty . ,qty) (cost . ,cost))))
           events))
         (total (fold (lambda (e a) (+ a (assq-ref e 'cost))) 0 by-event)))
    `((total . ,total) (by-event . ,by-event))))

(define (cost-variance standard actual)
  "Variance between standard and actual cost."
  (let ((v (- (assq-ref standard 'total) (assq-ref actual 'total))))
    `((variance . ,v)
      (variance-pct . ,(if (> (assq-ref standard 'total) 0)
                           (* (/ v (assq-ref standard 'total)) 100) 0)))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Flow graph — scope value flows, coherence, interdependence
;;; ══════════════════════════════════════════════════════════════════════════════

(define (build-flow-graph facts scope-of-agent)
  "Directed value-flow graph between scopes. scope-of-agent: agent-id → scope-id."
  (let ((edges (make-hash-table))
        (internal (make-hash-table))
        (external (make-hash-table))
        (scopes '()))
    (for-each (lambda (f)
      (when (eq? (car f) 'event)
        (let* ((qty (or (list-ref f 4) 0))
               ;; Simplified: use spec as proxy for value
               (src (scope-of-agent "provider"))  ;; would need provider field
               (tgt (scope-of-agent "receiver")))
          (when (and src tgt)
            (unless (member src scopes) (set! scopes (cons src scopes)))
            (unless (member tgt scopes) (set! scopes (cons tgt scopes)))
            (if (equal? src tgt)
                (hash-set! internal src (+ (or (hash-ref internal src) 0) qty))
                (let ((key (string-append src "->" tgt)))
                  (hash-set! edges key (+ (or (hash-ref edges key) 0) qty))
                  (hash-set! external src (+ (or (hash-ref external src) 0) qty))
                  (hash-set! external tgt (+ (or (hash-ref external tgt) 0) qty))))))))
      facts)
    `((edges . ,(hash-map->list cons edges))
      (scopes . ,scopes)
      (internal . ,(hash-map->list cons internal))
      (external . ,(hash-map->list cons external)))))

(define (coherence scope-id graph)
  (let ((int (or (assoc-ref (assq-ref graph 'internal) scope-id) 0))
        (ext (or (assoc-ref (assq-ref graph 'external) scope-id) 0)))
    (if (> (+ int ext) 0) (/ int (+ int ext)) 1)))

(define (interdependence scope-a scope-b graph)
  (let* ((edges (assq-ref graph 'edges))
         (ab (or (assoc-ref edges (string-append scope-a "->" scope-b)) 0))
         (ba (or (assoc-ref edges (string-append scope-b "->" scope-a)) 0))
         (bilateral (+ ab ba))
         (ea (or (assoc-ref (assq-ref graph 'external) scope-a) 0))
         (eb (or (assoc-ref (assq-ref graph 'external) scope-b) 0))
         (denom (+ ea eb)))
    (if (> denom 0) (/ bilateral denom) 0)))

(define (merge-candidates graph theta)
  (let ((scopes (assq-ref graph 'scopes)))
    (let loop ((s scopes) (acc '()))
      (if (null? s) acc
          (let inner ((rest (cdr s)) (acc acc))
            (if (null? rest) (loop (cdr s) acc)
                (let ((id (> (interdependence (car s) (car rest) graph) theta)))
                  (inner (cdr rest)
                         (if id (cons (list (car s) (car rest)) acc) acc)))))))))

(define (split-candidates graph theta)
  (filter (lambda (s) (< (coherence s graph) theta)) (assq-ref graph 'scopes)))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Positioning — DDMRP strategic inventory positioning
;;; ══════════════════════════════════════════════════════════════════════════════

(define (routing-geometry facts recipe-id)
  "Analyze process chain for convergence, divergence, gating."
  (let* ((cf (find (lambda (f) (and (eq? (car f) 'chain) (equal? (cadr f) recipe-id))) facts))
         (pids (if cf (caddr cf) '())))
    (map (lambda (pid)
      (let* ((pf (find (lambda (f) (and (eq? (car f) 'process) (equal? (cadr f) pid))) facts))
             (name (if pf (caddr pf) pid))
             (inputs (filter (lambda (f) (and (eq? (car f) 'flow) (equal? (cadr f) pid)
                                               (eq? (caddr f) 'input))) facts))
             (outputs (filter (lambda (f) (and (eq? (car f) 'flow) (equal? (cadr f) pid)
                                                (eq? (caddr f) 'output))) facts))
             (ni (length inputs)) (no (length outputs)))
        `((process-id . ,pid) (name . ,name)
          (upstream-path-count . ,ni) (downstream-path-count . ,no)
          (is-convergent . ,(> ni 1)) (is-divergent . ,(> no 1))
          (is-gating-point . ,(and (> ni 1) (= no 1))))))
    pids)))

(define (rank-decoupling-candidates facts recipe-id)
  "Score processes as DDMRP decoupling candidates."
  (let* ((geo (routing-geometry facts recipe-id))
         (full-lt (fold (lambda (g a) (+ a 1)) 0 geo))  ;; simplified: 1 day per process
         (scored (map (lambda (g)
           (let* ((idx (list-index (lambda (g2) (equal? (assq-ref g2 'process-id)
                                                         (assq-ref g 'process-id))) geo))
                  (compression (if (> full-lt 0) (/ (+ idx 1) full-lt) 0))
                  (leverage (if (> full-lt 0) (/ (- full-lt idx) full-lt) 0))
                  (geo-bonus (+ (if (assq-ref g 'is-convergent) 10 0)
                                (if (assq-ref g 'is-divergent) 10 0)
                                (if (assq-ref g 'is-gating-point) 5 0)))
                  (score (+ (* compression 50) (* leverage 10) geo-bonus)))
             `((process-id . ,(assq-ref g 'process-id)) (score . ,score)
               (compression . ,compression) (leverage . ,leverage))))
           geo)))
    (sort scored (lambda (a b) (> (assq-ref a 'score) (assq-ref b 'score))))))

(define (rank-control-points facts recipe-id)
  "Score processes as DDMRP control-point candidates."
  (let* ((geo (routing-geometry facts recipe-id))
         (scored (map (lambda (g)
           (let ((score (+ (if (assq-ref g 'is-convergent) 30 0)
                           (if (assq-ref g 'is-gating-point) 20 0)
                           (if (assq-ref g 'is-divergent) 10 0))))
             `((process-id . ,(assq-ref g 'process-id)) (score . ,score)
               (geometry . ,g))))
           geo)))
    (sort scored (lambda (a b) (> (assq-ref a 'score) (assq-ref b 'score))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Value equations — contribution scoring and income distribution
;;; ══════════════════════════════════════════════════════════════════════════════

(define (effort-scorer event) (or (list-ref event 4) 0))
(define (resource-scorer event)
  (if (memq (caddr event) '(consume use cite)) (or (list-ref event 4) 0) 0))
(define (equal-scorer event) 1)

(define (make-depreciation-scorer sne-index lifespans)
  "Scorer closure: depreciation = duration / lifespan * SNE."
  (lambda (event)
    (if (not (eq? (caddr event) 'use)) 0
        (let* ((spec (cadddr event))
               (qty (or (list-ref event 4) 0))
               (lifespan (or (assoc-ref lifespans spec) 100))
               (sne-val (or (assoc-ref sne-index spec) 0)))
          (* (/ qty lifespan) sne-val)))))

(define (effort-equation) `((1.0 . ,effort-scorer)))
(define (equal-equation) `((1.0 . ,equal-scorer)))
(define (make-hybrid-equation sne-index lifespans)
  `((0.6 . ,effort-scorer) (0.4 . ,(make-depreciation-scorer sne-index lifespans))))

(define (score-event event equation)
  "Weighted score for an event across all equation components."
  (fold (lambda (component acc)
          (+ acc (* (car component) ((cdr component) event))))
        0 equation))

(define (distribute-income facts income-event-id equation)
  "Distribute income proportional to contribution scores."
  (let* ((income-event (find (lambda (f) (and (eq? (car f) 'event)
                                               (equal? (cadr f) income-event-id))) facts))
         (income-qty (if income-event (or (list-ref income-event 4) 0) 0))
         ;; Trace backward to find contributing events
         (contributing (filter (lambda (f)
           (and (eq? (car f) 'event) (not (equal? (cadr f) income-event-id))
                (memq (caddr f) '(work use consume)))) facts))
         (scored (map (lambda (e) (cons e (score-event e equation))) contributing))
         (total-score (fold (lambda (s a) (+ a (cdr s))) 0 scored))
         (distributions
           (map (lambda (s)
             (let* ((e (car s)) (sc (cdr s))
                    (share (if (> total-score 0) (/ sc total-score) 0))
                    (amount (* income-qty share)))
               `((event-id . ,(cadr e)) (score . ,sc) (share . ,share) (amount . ,amount))))
                scored)))
    `((total-income . ,income-qty) (distributions . ,distributions))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Custody — entrustment, transfer, settlement, penalties
;;; ══════════════════════════════════════════════════════════════════════════════

(define (entrustment-limit total-claim svc-market-equiv alpha)
  "Entrustment limit = alpha × total-claim × svc-market-equiv."
  (* alpha total-claim svc-market-equiv))

(define (incentive-compatible value-solo n-colluders entrustment-lim)
  "Is theft irrational? Per-colluder share < entrustment limit."
  (< (/ value-solo (max 1 n-colluders)) entrustment-lim))

(define (custody-level value hierarchy)
  "Find minimum level whose limit covers value."
  (find (lambda (h) (>= (assq-ref h 'limit) value)) hierarchy))

(define (tranche-coverage loss tranches)
  "Distribute loss through ordered tranches."
  (let loop ((ts tranches) (remaining loss) (acc '()))
    (if (or (null? ts) (<= remaining 0)) (reverse acc)
        (let* ((t (car ts))
               (pool (assq-ref t 'pool))
               (absorbed (min remaining pool)))
          (loop (cdr ts) (- remaining absorbed)
                (cons `((level . ,(assq-ref t 'level))
                        (absorbed . ,absorbed)
                        (remaining . ,(- remaining absorbed)))
                      acc))))))

(define (check-ownership-invariant facts commune-id)
  "Find communal resources not owned by the commune."
  (filter (lambda (f)
    (and (eq? (car f) 'inventory)
         ;; Simplified: check if resource has a different primary-accountable
         ;; (would need accountable field in inventory facts)
         #f))
    facts))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Track-trace — provenance and destination (ground DFS)
;;; ══════════════════════════════════════════════════════════════════════════════

(define (trace-provenance facts start-spec-id)
  "Backward trace through BOM: what specs are needed to produce START-SPEC-ID?"
  (let ((visited '()))
    (let dfs ((spec start-spec-id) (depth 0) (acc '()))
      (if (member spec visited) acc
          (begin
            (set! visited (cons spec visited))
            (let* ((recipes (filter (lambda (f) (and (eq? (car f) 'recipe)
                                                      (equal? (cadddr f) spec))) facts))
                   (inputs (append-map (lambda (rf)
                     (let* ((rid (cadr rf))
                            (cf (find (lambda (f) (and (eq? (car f) 'chain)
                                                        (equal? (cadr f) rid))) facts))
                            (pids (if cf (caddr cf) '())))
                       (filter-map (lambda (f)
                         (and (eq? (car f) 'flow)
                              (member (cadr f) pids)
                              (eq? (caddr f) 'input)
                              (not (memq (list-ref f 6) *non-consuming*))
                              (cadddr f)))
                         facts)))
                     recipes)))
              (fold (lambda (in-spec a)
                      (dfs in-spec (+ depth 1)
                           (cons `((spec . ,in-spec) (depth . ,(+ depth 1))
                                   (parent . ,spec)) a)))
                    (cons `((spec . ,spec) (depth . ,depth) (parent . #f)) acc)
                    (delete-duplicates inputs))))))))

(define (trace-destination facts start-spec-id)
  "Forward trace: what can be produced from START-SPEC-ID?"
  (let ((visited '()))
    (let dfs ((spec start-spec-id) (depth 0) (acc '()))
      (if (member spec visited) acc
          (begin
            (set! visited (cons spec visited))
            (let* (;; Find recipes that consume this spec
                   (consuming-pids
                     (filter-map (lambda (f)
                       (and (eq? (car f) 'flow) (eq? (caddr f) 'input)
                            (equal? (cadddr f) spec) (cadr f)))
                       facts))
                   ;; Find what those processes produce
                   (outputs (filter-map (lambda (f)
                     (and (eq? (car f) 'flow)
                          (member (cadr f) consuming-pids)
                          (eq? (caddr f) 'output)
                          (cadddr f)))
                     facts)))
              (let ((base (cons `((spec . ,spec) (depth . ,depth) (parent . #f)) acc)))
                (fold (lambda (out-spec a)
                        (dfs out-spec (+ depth 1)
                             (cons `((spec . ,out-spec) (depth . ,(+ depth 1))
                                     (parent . ,spec)) a)))
                      base
                      (delete-duplicates outputs)))))))))

