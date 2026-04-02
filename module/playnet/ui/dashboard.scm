;;; dashboard.scm — DDOMDashboard and sub-components in SXML
;;;
;;; Translated from old/planner/src/lib/components/dashboard/DDOMDashboard.svelte
;;; and its sub-components: PlanningScreen, SignalIntegrityReport,
;;; BufferStatusDashboard, FlowExceptionReport, TimeBufferBoard.
;;;
;;; All functions are pure: data in, SXML out. No DOM mutation.
;;;
;;; Hoot/WASM compatible.

(define-module (playnet ui dashboard)
  #:use-module (srfi srfi-1)
  #:use-module (playnet ddmrp)
  #:use-module (playnet ui components)
  #:export (;; Sub-components
            planning-row
            planning-screen
            signal-integrity-report
            buffer-status-dashboard
            flow-exception-report
            time-buffer-board

            ;; Main dashboard
            ddom-dashboard))


;;; ── planning-screen ───────────────────────────────────────────────────────────
;;; Translated from PlanningScreen.svelte
;;; Table with 8 columns: Part, Supply, On-Hand, Demand, NFP, Priority %, Rec. Qty, Action

(define (planning-row row on-replenish)
  "Render a single planning table row.
   ROW: alist with spec-id, spec-name, open-supply, onhand, qualified-demand,
        nfp, zone, priority (0-1 fraction), recommended-qty (#f or number),
        action ('replenish or 'none).
   ON-REPLENISH: procedure taking spec-id, or #f."
  (let* ((zone (alist-ref row 'zone 'green))
         (nfp (alist-ref row 'nfp 0))
         (priority (alist-ref row 'priority 0))
         (rec-qty (alist-ref row 'recommended-qty #f))
         (action (alist-ref row 'action 'none))
         (spec-id (alist-ref row 'spec-id ""))
         (nfp-prefix (if (>= nfp 0) "+" "")))
    `(tr (@ (class ,(symbol->string zone)))
       (td (@ (class "part")) ,(alist-ref row 'spec-name ""))
       (td (@ (class "num")) ,(fmt-num (alist-ref row 'open-supply 0)))
       (td (@ (class "num")) ,(fmt-num (alist-ref row 'onhand 0)))
       (td (@ (class "num")) ,(fmt-num (alist-ref row 'qualified-demand 0)))
       (td (@ (class ,(if (< nfp 0) "num neg" "num")))
         ,(string-append nfp-prefix (fmt-num nfp)))
       (td (@ (class "num"))
         ,(priority-cell (* priority 100) zone))
       (td (@ (class "num"))
         ,(if rec-qty (fmt-num rec-qty) "—"))
       (td
         ,(if (eq? action 'replenish)
              `(button (@ (class "act")
                          ,@(if on-replenish
                                `((click ,(lambda (e) (on-replenish spec-id))))
                                '()))
                 "Replenish")
              (zone-badge 'green #:label "OK"))))))

(define* (planning-screen rows #:key on-replenish (class ""))
  "Planning table: Part/Supply/On-Hand/Demand/NFP/Priority/Rec.Qty/Action.
   ROWS: list of planning row alists."
  `(table (@ (class ,(string-append "ps " class)))
     (thead
       (tr
         (th "Part") (th "Supply") (th "On-Hand") (th "Demand")
         (th "NFP") (th "Priority %") (th "Rec. Qty") (th "Action")))
     (tbody
       ,@(map (lambda (r) (planning-row r on-replenish)) rows))))


;;; ── signal-integrity-report ───────────────────────────────────────────────────
;;; Translated from SignalIntegrityReport.svelte
;;; 7-column table: Signal, Spec, Rec. Qty, Approved Qty, Fulfillment, Due, Status

(define (signal-row-zone entry)
  "Compute row zone for a signal integrity entry."
  (let* ((is-late (alist-ref entry 'late #f))
         (is-over (alist-ref entry 'over-fulfilled #f))
         (qty-diff (alist-ref entry 'qty-diff 0))
         (rec-qty (alist-ref entry 'recommended-qty 1))
         (dev-ratio (if (> rec-qty 0) (/ (abs qty-diff) rec-qty) 0)))
    (cond
     ((or is-late is-over) 'red)
     ((> dev-ratio 0.1) 'yellow)
     (else 'green))))

(define* (signal-integrity-report entries #:key (class ""))
  "Signal integrity table showing recommendation vs actual deviations.
   ENTRIES: list of alists with signal-id, spec-id, recommended-qty,
            approved-qty, fulfilled, due-date, late, over-fulfilled, qty-diff."
  `(table (@ (class ,(string-append "sir " class)))
     (thead
       (tr (th "Signal") (th "Spec") (th "Rec. Qty")
           (th "Approved Qty") (th "Fulfillment") (th "Due") (th "")))
     (tbody
       ,@(map
          (lambda (e)
            (let* ((zone (signal-row-zone e))
                   (sig-id (alist-ref e 'signal-id ""))
                   (spec-id (alist-ref e 'spec-id ""))
                   (rec-qty (alist-ref e 'recommended-qty 0))
                   (approved-qty (alist-ref e 'approved-qty 0))
                   (qty-diff (alist-ref e 'qty-diff 0))
                   (fulfilled (alist-ref e 'fulfilled 0))
                   (due-date (alist-ref e 'due-date #f))
                   (is-late (alist-ref e 'late #f))
                   (is-over (alist-ref e 'over-fulfilled #f))
                   (status-label (cond (is-late "LATE") (is-over "OVER") (else "OK")))
                   (fill-pct (if (> approved-qty 0) (min 100 (* (/ fulfilled approved-qty) 100)) 0)))
              `(tr (@ (class ,(symbol->string zone)))
                 (td (@ (class "id")) ,(truncate-id sig-id 8))
                 (td ,(truncate-id spec-id 12))
                 (td (@ (class "num")) ,(fmt-num rec-qty))
                 (td (@ (class ,(if (not (= qty-diff 0)) "num dev" "num")))
                   ,(fmt-num approved-qty)
                   ,@(if (not (= qty-diff 0))
                         `((span (@ (class "diff"))
                             ,(string-append "("
                                             (if (> qty-diff 0) "+" "")
                                             (fmt-num qty-diff) ")")))
                         '()))
                 (td
                   ;; Simple fulfillment bar
                   (div (@ (class "fulfillment-bar"))
                     (div (@ (class ,(string-append "fill " (symbol->string zone)))
                             (style ,(string-append "width:" (fmt-num fill-pct) "%"))))))
                 (td (@ (class "num")) ,(or due-date "—"))
                 (td ,(zone-badge zone #:label status-label)))))
          entries))))


;;; ── buffer-status-dashboard ───────────────────────────────────────────────────
;;; Translated from BufferStatusDashboard.svelte
;;; Flex grid of buffer funnel cards with zone badges

(define* (buffer-status-dashboard entries #:key (class ""))
  "Grid of buffer funnel visualizations.
   ENTRIES: list of alists with buffer-zone (alist), onhand, spec-name (optional)."
  `(div (@ (class ,(string-append "bsd " class)))
     ,@(map
        (lambda (e)
          (let* ((bz (alist-ref e 'buffer-zone))
                 (onhand (alist-ref e 'onhand 0))
                 (spec-name (alist-ref e 'spec-name #f))
                 (status (buffer-status onhand bz))
                 (zone (alist-ref status 'zone 'red))
                 (pct (alist-ref status 'pct 0)))
            `(div (@ (class "entry"))
               ,(buffer-funnel bz onhand)
               ,@(if spec-name
                     `((span (@ (class "name")) ,spec-name))
                     '())
               ,(zone-badge zone #:pct pct))))
        entries)))


;;; ── flow-exception-report ─────────────────────────────────────────────────────
;;; Translated from FlowExceptionReport.svelte
;;; Vertical list of domain-tagged exception entries

(define (domain-zone domain)
  "Map exception domain to a zone for color coding."
  (cond
   ((eq? domain 'execution) 'excess)
   ((eq? domain 'planning)  'yellow)
   ((eq? domain 'scheduling) 'green)
   (else 'red)))

(define* (flow-exception-report entries #:key (class ""))
  "List of flow exception entries with domain-colored badges.
   ENTRIES: list of alists with order-id, date, domain (symbol), duration, due-date."
  `(div (@ (class ,(string-append "fer " class)))
     ,@(map
        (lambda (e)
          (let* ((order-id (alist-ref e 'order-id ""))
                 (date (alist-ref e 'date ""))
                 (domain (alist-ref e 'domain 'other))
                 (duration (alist-ref e 'duration #f))
                 (due-date (alist-ref e 'due-date #f))
                 (dz (domain-zone domain)))
            `(div (@ (class "fer-row"))
               (span (@ (class "id")) ,(truncate-id order-id 8))
               ,(zone-badge dz #:label (string-upcase (symbol->string domain)))
               (span ,(or date ""))
               ,@(if duration
                     `((span (@ (class "dur")) ,(string-append (fmt-num duration) "d")))
                     '())
               ,@(if due-date
                     `((span (@ (class "muted")) ,due-date))
                     '()))))
        entries)))


;;; ── time-buffer-board ─────────────────────────────────────────────────────────
;;; Translated from TimeBufferBoard.svelte
;;; Horizontal time-buffer axis with positioned dots per commitment

(define (time-zone days-left dlt-days)
  "Classify a commitment's time position into a zone.
   DAYS-LEFT: can be negative (overdue). DLT-DAYS: decoupled lead time."
  (let ((third (/ dlt-days 3)))
    (cond
     ((< days-left 0) 'late)
     ((< days-left third) 'red)
     ((< days-left (* third 2)) 'yellow)
     ((< days-left dlt-days) 'green)
     (else 'early))))

(define* (time-buffer-board commitments bz today-str #:key (class ""))
  "Time buffer visualization with zone axis and positioned commitment dots.
   COMMITMENTS: list of alists with id, due (date string or #f).
   BZ: buffer zone alist with dlt-days.
   TODAY-STR: \"YYYY-MM-DD\" string."
  (let* ((dlt-days (alist-ref bz 'dlt-days 1))
         (rows
          (map (lambda (c)
                 (let* ((due (alist-ref c 'due #f))
                        (days-left (if due
                                       ;; Simple string date difference approximation
                                       ;; In real use, proper date math would be needed
                                       (alist-ref c 'days-left 0)
                                       #f))
                        (tz (if days-left (time-zone days-left dlt-days) 'early))
                        (pct (if days-left
                                 (clamp (- 100 (* (/ days-left dlt-days) 100)) 0 100)
                                 0)))
                   `((commitment . ,c)
                     (zone . ,tz)
                     (days-left . ,days-left)
                     (pct . ,pct))))
               commitments)))
    `(div (@ (class ,(string-append "tbb " class)))
       ;; Zone axis header
       (div (@ (class "axis"))
         (span (@ (class "early-lbl")) "Earlier")
         (div (@ (class "zones"))
           (div (@ (class "z green") (style "flex:1")) (span "G"))
           (div (@ (class "z yellow") (style "flex:0.5")) (span "Y"))
           (div (@ (class "z red") (style "flex:0.5")) (span "R")))
         (span (@ (class "late-lbl")) "Late"))
       ;; Commitment rows
       ,@(map
          (lambda (r)
            (let* ((c (alist-ref r 'commitment))
                   (tz (alist-ref r 'zone 'early))
                   (days-left (alist-ref r 'days-left #f))
                   (pct (alist-ref r 'pct 0))
                   (c-id (alist-ref c 'id "")))
              `(div (@ (class "row"))
                 (span (@ (class "id")) ,(truncate-id c-id 8))
                 (div (@ (class "track"))
                   (div (@ (class ,(string-append "dot " (symbol->string tz)))
                           (style ,(string-append "left:" (fmt-num pct) "%")))))
                 ,(zone-badge tz)
                 ,@(if days-left
                       `((span (@ (class "days"))
                           ,(string-append
                             (if (>= days-left 0) (fmt-num days-left) "!")
                             " d")))
                       '()))))
          rows))))


;;; ── ddom-dashboard ────────────────────────────────────────────────────────────
;;; Translated from DDOMDashboard.svelte
;;; 3-column layout composing all sub-components

(define* (ddom-dashboard #:key (planning-rows '())
                               (signal-entries '())
                               (buffer-entries '())
                               (exception-entries '())
                               (commitments '())
                               (buffer-zone #f)
                               (today-str "")
                               on-replenish
                               (class ""))
  "DDOM Dashboard — 3-column layout.
   Col 1: PlanningScreen + SignalIntegrityReport
   Col 2: BufferStatusDashboard
   Col 3: FlowExceptionReport + TimeBufferBoard"
  `(div (@ (class ,(string-append "ddom " class)))
     (div (@ (class "col"))
       ,(planning-screen planning-rows #:on-replenish on-replenish)
       ,(signal-integrity-report signal-entries))
     (div (@ (class "col"))
       ,(buffer-status-dashboard buffer-entries))
     (div (@ (class "col"))
       ,(flow-exception-report exception-entries)
       ,@(if buffer-zone
             `(,(time-buffer-board commitments buffer-zone today-str))
             '()))))


;;; ── string-upcase helper ──────────────────────────────────────────────────────

(define (string-upcase s)
  "Convert string to uppercase."
  (list->string (map char-upcase (string->list s))))
