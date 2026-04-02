;;; ddmrp.scm — DDMRP Algorithm Layer for playnet
;;;
;;; Pure-function computations for the Demand Driven MRP planning cycle.
;;; All functions are stateless and side-effect-free.
;;;
;;; Translated from old/planner/src/lib/algorithms/ddmrp.ts
;;;
;;; DDMRP ref: Ptak & Smith "Demand Driven Material Requirements Planning"
;;;   Ch 7  — Strategic Inventory Positioning
;;;   Ch 8  — Buffer Profiles and Levels (zone formula)
;;;   Ch 9  — Supply Order Generation (NFP, replenishment)
;;;   Ch 10 — DDS&OP (ADU, DLT, execution alerts)
;;;   Ch 12 — Signal Integrity
;;;
;;; Data representation: alists with symbol keys.
;;; Buffer zone:  ((id . "bz-1") (spec-id . "flour") (tor . 20) (toy . 40) (tog . 60)
;;;               (adu . 5) (adu-unit . "kg") (dlt-days . 7) (moq . 10) (moq-unit . "kg"))
;;; NFP result:   ((onhand . 35) (onorder . 10) (qualified-demand . 15)
;;;               (nfp . 30) (zone . green) (priority . 0.5))
;;; Health entry: ((date . "2026-03-15") (onhand . 42) (pct . 72) (zone . green))
;;;
;;; Hoot/WASM compatible.

(define-module (playnet ddmrp)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:export (;; alist helpers
            alist-ref alist-set alist-update

            ;; Duration
            duration->days

            ;; Zone classification
            buffer-status
            classify-zone

            ;; ADU
            compute-adu
            blend-adu

            ;; Buffer zone formula
            compute-buffer-zone
            compute-min-max-buffer

            ;; Adjustment factors
            aggregate-adjustment-factors

            ;; NFP / netting
            compute-nfp

            ;; Buffer health history
            buffer-health-history

            ;; Replenishment
            generate-replenishment-signal

            ;; Alerts
            on-hand-alert
            ltm-alert-zone
            average-on-hand-target

            ;; Scheduling
            sort-by-priority-and-sequence

            ;; Prioritized share
            prioritized-share))


;;; ── alist helpers ─────────────────────────────────────────────────────────────

(define (alist-ref al key . default)
  "Look up KEY in alist AL. Return default (or #f) if not found."
  (let ((pair (assq key al)))
    (if pair
        (cdr pair)
        (if (null? default) #f (car default)))))

(define (alist-set al key val)
  "Return a new alist with KEY set to VAL (replaces existing or adds)."
  (cons (cons key val)
        (filter (lambda (p) (not (eq? (car p) key))) al)))

(define (alist-update al key fn default)
  "Update KEY in AL by applying FN to its current value (or DEFAULT)."
  (alist-set al key (fn (alist-ref al key default))))


;;; ── Constants ─────────────────────────────────────────────────────────────────

;; Actions that record usage/effort but do NOT reduce physical inventory
(define *non-consuming-actions*
  '(use work cite deliver-service))


;;; ── 1. duration->days ─────────────────────────────────────────────────────────

(define (duration->days d)
  "Convert a VF Duration alist to calendar days.
   D should have 'has-unit and 'has-numerical-value keys."
  (let ((val (alist-ref d 'has-numerical-value 0))
        (unit (alist-ref d 'has-unit "")))
    (cond
     ((member unit '("m" "min" "minutes")) (/ val 1440))
     ((member unit '("h" "hours"))         (/ val 24))
     ((member unit '("d" "days"))          val)
     ((member unit '("w" "weeks"))         (* val 7))
     (else 0))))


;;; ── 2. classify-zone ──────────────────────────────────────────────────────────

(define (classify-zone value tor toy tog)
  "Classify a numeric VALUE into a zone symbol given thresholds."
  (cond
   ((<= value 0)   'stockout)
   ((<= value tor) 'red)
   ((<= value toy) 'yellow)
   ((<= value tog) 'green)
   (else           'excess)))

(define (classify-zone/no-stockout value tor toy tog)
  "Like classify-zone but without stockout (for NFP which can be negative)."
  (cond
   ((<= value tor) 'red)
   ((<= value toy) 'yellow)
   ((<= value tog) 'green)
   (else           'excess)))


;;; ── 3. buffer-status ──────────────────────────────────────────────────────────

(define (buffer-status onhand bz)
  "Current on-hand buffer status — physical position relative to zone boundaries.
   Returns an alist with onhand, pct, zone, red-pct, and optional tipping-point-breached."
  (let* ((tor (alist-ref bz 'tor 0))
         (toy (alist-ref bz 'toy 0))
         (tog (alist-ref bz 'tog 0))
         (pct (if (> tog 0) (* (/ onhand tog) 100) 0))
         (red-pct (if (> tor 0) (* (/ onhand tor) 100) 0))
         (zone (classify-zone/no-stockout onhand tor toy tog))
         (tipping (alist-ref bz 'tipping-point #f))
         (base `((onhand . ,onhand)
                 (pct . ,pct)
                 (zone . ,zone)
                 (red-pct . ,red-pct))))
    (if tipping
        (alist-set base 'tipping-point-breached (< onhand tipping))
        base)))


;;; ── 4. compute-adu ────────────────────────────────────────────────────────────

(define (compute-adu events spec-id window-days as-of-str)
  "Rolling average daily usage from historical EconomicEvents.
   EVENTS: list of event alists. SPEC-ID: string. WINDOW-DAYS: number.
   AS-OF-STR: \"YYYY-MM-DD\" string.
   Returns alist with adu, unit, window-days, computed-from, sample-count."
  (let* ((qualifying
          (filter (lambda (e)
                    (and (equal? (alist-ref e 'resource-conforms-to) spec-id)
                         (eq? (alist-ref e 'onhand-effect) 'decrement)
                         (not (alist-ref e 'exclude-from-adu #f))
                         (alist-ref e 'date #f)))
                  events))
         (total-consumed
          (fold (lambda (e sum) (+ sum (alist-ref e 'quantity 0)))
                0 qualifying))
         (dates (map (lambda (e) (alist-ref e 'date)) qualifying))
         (unique-dates (delete-duplicates dates equal?))
         (unit (if (null? qualifying) "" (alist-ref (car qualifying) 'unit "")))
         (adu (if (> window-days 0) (/ total-consumed window-days) 0))
         (computed-from (if (null? dates) as-of-str
                            (fold (lambda (d best) (if (string<? d best) d best))
                                  (car dates) (cdr dates)))))
    `((adu . ,adu)
      (unit . ,unit)
      (window-days . ,window-days)
      (computed-from . ,computed-from)
      (sample-count . ,(length unique-dates)))))


;;; ── 5. blend-adu ──────────────────────────────────────────────────────────────

(define* (blend-adu past-adu forward-adu #:optional (blend-ratio 1))
  "Blend past (historical) and forward (forecast) ADU.
   blend-ratio = 0 -> pure forward, 1 -> pure past, 0.5 -> equal weight."
  (+ (* past-adu blend-ratio) (* forward-adu (- 1 blend-ratio))))


;;; ── 6. aggregate-adjustment-factors ───────────────────────────────────────────

(define (aggregate-adjustment-factors adjustments as-of-str spec-id)
  "Aggregate all active DemandAdjustmentFactors for a spec on a given date.
   ADJUSTMENTS: list of factor alists. AS-OF-STR: \"YYYY-MM-DD\".
   Returns alist with demand-adj-factor, zone-adj-factor, green/yellow/red zone
   factors, lead-time-adj-factor, supply-offset-days."
  (let loop ((adj adjustments)
             (demand 1) (zone 1) (green-z 1) (yellow-z 1) (red-z 1)
             (lead-time 1) (supply-offset 0))
    (if (null? adj)
        `((demand-adj-factor . ,demand)
          (zone-adj-factor . ,zone)
          (green-zone-adj-factor . ,green-z)
          (yellow-zone-adj-factor . ,yellow-z)
          (red-zone-adj-factor . ,red-z)
          (lead-time-adj-factor . ,lead-time)
          (supply-offset-days . ,supply-offset))
        (let* ((a (car adj))
               (a-spec (alist-ref a 'spec-id))
               (valid-from (alist-ref a 'valid-from ""))
               (valid-to (alist-ref a 'valid-to ""))
               (factor (alist-ref a 'factor 1))
               (type (alist-ref a 'type))
               (target-zone (alist-ref a 'target-zone #f))
               (offset (alist-ref a 'supply-offset-days 0)))
          (if (or (not (equal? a-spec spec-id))
                  (string>? valid-from as-of-str)
                  (string<? valid-to as-of-str))
              ;; Skip: doesn't match spec or not in active window
              (loop (cdr adj) demand zone green-z yellow-z red-z lead-time supply-offset)
              ;; Active: compound by type
              (cond
               ((eq? type 'demand)
                (loop (cdr adj) (* demand factor) zone green-z yellow-z red-z lead-time (+ supply-offset offset)))
               ((eq? type 'zone)
                (cond
                 ((eq? target-zone 'green)
                  (loop (cdr adj) demand zone (* green-z factor) yellow-z red-z lead-time (+ supply-offset offset)))
                 ((eq? target-zone 'yellow)
                  (loop (cdr adj) demand zone green-z (* yellow-z factor) red-z lead-time (+ supply-offset offset)))
                 ((eq? target-zone 'red)
                  (loop (cdr adj) demand zone green-z yellow-z (* red-z factor) lead-time (+ supply-offset offset)))
                 (else ;; legacy untagged -> red
                  (loop (cdr adj) demand (* zone factor) green-z yellow-z red-z lead-time (+ supply-offset offset)))))
               ((eq? type 'lead-time)
                (loop (cdr adj) demand zone green-z yellow-z red-z (* lead-time factor) (+ supply-offset offset)))
               (else
                (loop (cdr adj) demand zone green-z yellow-z red-z lead-time (+ supply-offset offset)))))))))


;;; ── 7. compute-buffer-zone ────────────────────────────────────────────────────

(define* (compute-buffer-zone profile adu adu-unit dlt-days moq moq-unit
                              #:key (demand-adj-factor 1)
                                    (lead-time-adj-factor 1)
                                    (zone-adj-factor 1)
                                    (red-zone-adj-factor 1)
                                    (yellow-zone-adj-factor 1)
                                    (green-zone-adj-factor 1)
                                    (doc-days #f))
  "Pure formula: TOR / TOY / TOG from profile settings + ADU + DLT + MOQ + adjustments.
   PROFILE: alist with lead-time-factor, variability-factor, order-cycle-days.
   Returns alist with effective-adu, effective-dlt, red-base, red-safety, tor, toy, tog."
  (let* ((ltf (alist-ref profile 'lead-time-factor 1))
         (vf  (alist-ref profile 'variability-factor 0))
         (profile-doc (alist-ref profile 'order-cycle-days #f))
         (effective-adu (* adu demand-adj-factor))
         (effective-dlt (* dlt-days lead-time-adj-factor))
         ;; Per-zone ZAF dispatch (Ch 8 S8.2.2)
         (effective-red-zaf (* red-zone-adj-factor zone-adj-factor))
         (effective-yellow-zaf yellow-zone-adj-factor)
         (effective-green-zaf green-zone-adj-factor)
         ;; Red zone
         (red-base (* effective-adu effective-dlt ltf))
         (red-safety (* red-base vf))
         (tor (* (+ red-base red-safety) effective-red-zaf))
         ;; Yellow zone
         (toy (+ tor (* effective-adu effective-dlt effective-yellow-zaf)))
         ;; Green zone: three-way max (order-cycle, DLT coverage, MOQ) * green ZAF
         (effective-doc (or doc-days profile-doc))
         (green-base (* (max (if effective-doc (* effective-adu effective-doc) 0)
                             red-base
                             moq)
                        effective-green-zaf))
         (tog (+ toy green-base)))
    `((effective-adu . ,effective-adu)
      (effective-dlt . ,effective-dlt)
      (red-base . ,red-base)
      (red-safety . ,red-safety)
      (tor . ,tor)
      (toy . ,toy)
      (tog . ,tog))))

(define* (compute-min-max-buffer profile adu adu-unit dlt-days moq moq-unit
                                 #:rest args)
  "Min-max buffer variant (Ch 7): no yellow zone — TOY = TOR."
  (let ((result (apply compute-buffer-zone profile adu adu-unit dlt-days moq moq-unit args)))
    (alist-set result 'toy (alist-ref result 'tor))))


;;; ── 8. compute-nfp ────────────────────────────────────────────────────────────

(define (compute-nfp onhand onorder qualified-demand bz)
  "Compute Net Flow Position from pre-computed components.
   Returns alist with onhand, onorder, qualified-demand, nfp, zone, priority."
  (let* ((tor (alist-ref bz 'tor 0))
         (toy (alist-ref bz 'toy 0))
         (tog (alist-ref bz 'tog 0))
         (nfp (- (+ onhand onorder) qualified-demand))
         (zone (classify-zone/no-stockout nfp tor toy tog))
         (priority (if (> tog 0) (/ nfp tog) 0)))
    `((onhand . ,onhand)
      (onorder . ,onorder)
      (qualified-demand . ,qualified-demand)
      (nfp . ,nfp)
      (zone . ,zone)
      (priority . ,priority))))


;;; ── 9. buffer-health-history ──────────────────────────────────────────────────

(define (buffer-health-history events current-onhand bz from-date to-date)
  "Reconstruct daily on-hand buffer status over [FROM-DATE, TO-DATE].
   EVENTS: list of event alists with 'date, 'delta (signed quantity change).
   CURRENT-ONHAND: today's physical balance.
   BZ: buffer zone alist.
   FROM-DATE, TO-DATE: \"YYYY-MM-DD\" strings.
   Returns list of ((date . \"...\") (onhand . N) (pct . N) (zone . sym))."
  (let* ((tor (alist-ref bz 'tor 0))
         (toy (alist-ref bz 'toy 0))
         (tog (alist-ref bz 'tog 0))
         ;; Bucket net delta per day within window
         (daily-net
          (let loop ((evts events) (acc '()))
            (if (null? evts) acc
                (let* ((e (car evts))
                       (d (alist-ref e 'date ""))
                       (delta (alist-ref e 'delta 0)))
                  (if (or (string<? d from-date) (string>? d to-date) (= delta 0))
                      (loop (cdr evts) acc)
                      (loop (cdr evts)
                            (let ((existing (assoc d acc equal?)))
                              (if existing
                                  (alist-set acc d (+ (cdr existing) delta))
                                  (cons (cons d delta) acc)))))))))
         ;; Total delta in window
         (total-delta (fold (lambda (p sum) (+ sum (cdr p))) 0 daily-net))
         ;; Back-compute starting on-hand
         (start-oh (- current-onhand total-delta)))
    ;; Walk day by day from from-date to to-date
    ;; Simple approach: generate date strings and accumulate
    (let day-loop ((date-str from-date) (oh start-oh) (result '()))
      (if (string>? date-str to-date)
          (reverse result)
          (let* ((day-delta (let ((p (assoc date-str daily-net equal?)))
                              (if p (cdr p) 0)))
                 (new-oh (+ oh day-delta))
                 (zone (cond
                        ((<= new-oh tor) 'red)
                        ((<= new-oh toy) 'yellow)
                        ((<= new-oh tog) 'green)
                        (else 'excess)))
                 (pct (if (> tog 0) (* (/ new-oh tog) 100) 0))
                 (entry `((date . ,date-str) (onhand . ,new-oh) (pct . ,pct) (zone . ,zone)))
                 (next-date (next-day date-str)))
            (day-loop next-date new-oh (cons entry result)))))))


;;; ── Date helpers ──────────────────────────────────────────────────────────────

(define (next-day date-str)
  "Increment a \"YYYY-MM-DD\" date string by one day.
   Simple calendar arithmetic — handles month/year boundaries."
  (let* ((year  (string->number (substring date-str 0 4)))
         (month (string->number (substring date-str 5 7)))
         (day   (string->number (substring date-str 8 10)))
         (days-in-month
          (lambda (y m)
            (cond ((member m '(1 3 5 7 8 10 12)) 31)
                  ((member m '(4 6 9 11)) 30)
                  ((= m 2) (if (and (= 0 (modulo y 4))
                                    (or (not (= 0 (modulo y 100)))
                                        (= 0 (modulo y 400))))
                               29 28)))))
         (new-day (+ day 1)))
    (cond
     ((<= new-day (days-in-month year month))
      (format #f "~4,'0d-~2,'0d-~2,'0d" year month new-day))
     ((< month 12)
      (format #f "~4,'0d-~2,'0d-01" year (+ month 1)))
     (else
      (format #f "~4,'0d-01-01" (+ year 1))))))


;;; ── 10. generate-replenishment-signal ─────────────────────────────────────────

(define (generate-replenishment-signal spec-id bz nfp-result today-str gen-id)
  "Wrap an NFP result + buffer zone into a ReplenishmentSignal.
   GEN-ID: thunk returning a unique string.
   Returns alist."
  (let* ((moq (let ((m (alist-ref bz 'moq 0))) (if (> m 0) m 1)))
         (tog (alist-ref bz 'tog 0))
         (nfp-val (alist-ref nfp-result 'nfp 0))
         (raw (- tog nfp-val))
         (recommended-qty (if (<= raw 0) moq
                              (* (ceiling (/ raw moq)) moq)))
         (dlt-days (alist-ref bz 'dlt-days 0))
         (offset-days (alist-ref bz 'supply-offset-days 0)))
    `((id . ,(gen-id))
      (spec-id . ,spec-id)
      (buffer-zone-id . ,(alist-ref bz 'id ""))
      (onhand . ,(alist-ref nfp-result 'onhand 0))
      (onorder . ,(alist-ref nfp-result 'onorder 0))
      (qualified-demand . ,(alist-ref nfp-result 'qualified-demand 0))
      (nfp . ,nfp-val)
      (priority . ,(alist-ref nfp-result 'priority 0))
      (zone . ,(alist-ref nfp-result 'zone 'red))
      (recommended-qty . ,recommended-qty)
      (due-date . ,today-str)  ;; TODO: add dlt-days + offset-days
      (status . open)
      (created-at . ,today-str))))


;;; ── 11. on-hand-alert ─────────────────────────────────────────────────────────

(define* (on-hand-alert onhand bz #:optional (alert-threshold 0.5))
  "On-hand execution alert (DDMRP C5 alert type (a)).
   Returns alist with onhand, buffer-status, alert-level, alert-threshold, threshold-qty."
  (let* ((status (buffer-status onhand bz))
         (tor (alist-ref bz 'tor 0))
         (threshold-qty (* tor alert-threshold))
         (alert-level (cond
                       ((<= onhand 0) 'critical)
                       ((<= onhand threshold-qty) 'warning)
                       (else #f))))
    `((onhand . ,onhand)
      (buffer-status . ,status)
      (alert-level . ,alert-level)
      (alert-threshold . ,alert-threshold)
      (threshold-qty . ,threshold-qty))))


;;; ── 12. ltm-alert-zone ────────────────────────────────────────────────────────

(define (ltm-alert-zone days-remaining dlt-days)
  "LTM sub-zone for an open supply order.
   Returns 'green, 'yellow, 'red, or #f (outside alert horizon)."
  (let* ((alert-horizon (/ dlt-days 3))
         (third (/ alert-horizon 3)))
    (cond
     ((> days-remaining alert-horizon) #f)
     ((> days-remaining (* third 2)) 'green)
     ((> days-remaining third) 'yellow)
     (else 'red))))


;;; ── 13. average-on-hand-target ────────────────────────────────────────────────

(define (average-on-hand-target bz)
  "Average on-hand target = TOR + (TOG - TOY) / 2."
  (let ((tor (alist-ref bz 'tor 0))
        (toy (alist-ref bz 'toy 0))
        (tog (alist-ref bz 'tog 0)))
    (+ tor (/ (- tog toy) 2))))


;;; ── 14. sort-by-priority-and-sequence ─────────────────────────────────────────

(define (sort-by-priority-and-sequence slots)
  "Sort scheduling slots by sequence group ASC, then nfp-pct ASC.
   Each slot is an alist with 'nfp-pct and optional 'sequence-group."
  (sort slots
        (lambda (a b)
          (let ((ga (alist-ref a 'sequence-group 0))
                (gb (alist-ref b 'sequence-group 0)))
            (if (not (= ga gb))
                (< ga gb)
                (< (alist-ref a 'nfp-pct 0)
                   (alist-ref b 'nfp-pct 0)))))))


;;; ── 15. prioritized-share ─────────────────────────────────────────────────────

(define (prioritized-share slots total-supply)
  "Allocate scarce supply across buffer locations using DDMRP sequential zone-fill.
   SLOTS: list of alists with 'id, 'buffer-zone (alist), 'nfp (alist).
   Returns alist mapping slot id -> allocated quantity."
  (let* ((ids (map (lambda (s) (alist-ref s 'id)) slots))
         (initial-alloc (map (lambda (id) (cons id 0)) ids)))

    (define (get-alloc alloc id)
      (let ((p (assoc id alloc equal?)))
        (if p (cdr p) 0)))

    (define (pos slot alloc)
      (+ (alist-ref (alist-ref slot 'nfp) 'nfp 0)
         (get-alloc alloc (alist-ref slot 'id))))

    (define (fill-phase alloc remaining get-want)
      (let* ((wants (map (lambda (s)
                           (let ((w (max 0 (get-want s alloc))))
                             (cons (alist-ref s 'id) w)))
                         slots))
             (total-want (fold (lambda (w sum) (+ sum (cdr w))) 0 wants)))
        (cond
         ((<= remaining 0) (values alloc remaining))
         ((<= total-want 0) (values alloc remaining))
         ((>= remaining total-want)
          ;; Enough for all
          (values
           (fold (lambda (w al)
                   (alist-set al (car w) (+ (get-alloc al (car w)) (cdr w))))
                 alloc wants)
           (- remaining total-want)))
         (else
          ;; Proportional
          (values
           (fold (lambda (w al)
                   (if (> (cdr w) 0)
                       (let ((share (* remaining (/ (cdr w) total-want))))
                         (alist-set al (car w) (+ (get-alloc al (car w)) share)))
                       al))
                 alloc wants)
           0)))))

    (let*-values
        (((alloc1 rem1)
          (fill-phase initial-alloc total-supply
                      (lambda (s al)
                        (- (alist-ref (alist-ref s 'buffer-zone) 'tor 0) (pos s al)))))
         ((alloc2 rem2)
          (fill-phase alloc1 rem1
                      (lambda (s al)
                        (- (alist-ref (alist-ref s 'buffer-zone) 'toy 0) (pos s al)))))
         ;; Phase 3: distribute remaining proportionally by green zone size
         ((alloc3 _rem3)
          (if (<= rem2 0)
              (values alloc2 0)
              (let* ((green-sizes
                      (map (lambda (s)
                             (let* ((bz (alist-ref s 'buffer-zone))
                                    (gs (max 0 (- (alist-ref bz 'tog 0) (alist-ref bz 'toy 0))))
                                    (room (max 0 (- (alist-ref bz 'tog 0) (pos s alloc2)))))
                               (list (alist-ref s 'id) gs room)))
                           slots))
                     (total-green (fold (lambda (g sum) (+ sum (cadr g))) 0 green-sizes)))
                (if (<= total-green 0)
                    (values alloc2 rem2)
                    (let loop ((gs green-sizes) (al alloc2) (rem rem2))
                      (if (or (null? gs) (<= rem 0))
                          (values al rem)
                          (let* ((g (car gs))
                                 (id (car g))
                                 (g-size (cadr g))
                                 (room (caddr g)))
                            (if (and (> g-size 0) (> room 0))
                                (let ((share (min (* rem (/ g-size total-green)) room)))
                                  (loop (cdr gs)
                                        (alist-set al id (+ (get-alloc al id) share))
                                        (- rem share)))
                                (loop (cdr gs) al rem))))))))))
      alloc3)))
