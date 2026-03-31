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
