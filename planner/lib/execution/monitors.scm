;;; monitors.scm — Execution monitors and sinks
;;;
;;; Translated from src/lib/execution/monitors.ts
;;; Monitors: pure functions (observer-event, ctx) -> list of alerts
;;; Sinks: side-effect functions (observer-event, ctx) -> void
;;;
;;; In the Goblins model, monitors run within the observer's vat turn.
;;; They read from stores synchronously and produce alert alists.

;; Assumes schemas.scm, store-utils.scm, ddmrp.scm are loaded.

(use-modules (srfi srfi-1)
             (goblins utils hashmap))


;; ═════════════════════════════════════════════════════════════════════════
;; Monitors (pure: event -> alerts)
;; ═════════════════════════════════════════════════════════════════════════

(define (buffer-status-monitor event ctx)
  "Emit buffer-status alerts when resource updates affect buffered specs.
   ctx: alist with observer, plan-store, buffer-zone-store keys."
  (let* ((obs (assq-ref ctx 'observer))
         (bzs (assq-ref ctx 'buffer-zone-store))
         (spec-id (economic-event-resource-conforms-to event)))
    (if (not spec-id) '()
        (let ((zone ($ bzs 'find-zone spec-id)))
          (if (not zone) '()
              (let* ((resources ($ obs 'conforming-resources spec-id))
                     (onhand (fold (lambda (r acc)
                                     (+ acc (measure-qty
                                              (economic-resource-onhand-quantity r))))
                                   0 resources))
                     (status (buffer-status onhand zone))
                     (z (assq-ref status 'zone)))
                (if (memq z '(green excess)) '()
                    (list `((kind . buffer-status)
                            (spec-id . ,spec-id)
                            (zone . ,z)
                            (onhand . ,onhand)
                            (tor . ,(buffer-zone-tor zone))
                            (toy . ,(buffer-zone-toy zone))
                            (tog . ,(buffer-zone-tog zone))
                            (timestamp . ,(or (economic-event-has-point-in-time event)
                                              (number->string (current-time)))))))))))))

(define (material-sync-monitor event ctx)
  "Emit material-sync alerts for process inputs with projected shortage."
  ;; Simplified: check if the event's process has input commitments
  ;; that can't be met by current inventory
  '())  ;; Placeholder — full implementation needs process commitment scan

(define (create-adu-shift-monitor)
  "Factory: returns a stateful monitor that tracks ADU variance.
   Emits adu-shift alerts when ADU breaches high/low thresholds."
  (let ((prev-adu-by-spec (make-hash-table)))
    (lambda (event ctx)
      (let ((spec-id (economic-event-resource-conforms-to event))
            (bzs (assq-ref ctx 'buffer-zone-store)))
        (if (not spec-id) '()
            (let ((zone (and bzs ($ bzs 'find-zone spec-id))))
              (if (not zone) '()
                  (let* ((current-adu (buffer-zone-adu zone))
                         (prev (hash-ref prev-adu-by-spec spec-id #f))
                         (high-pct (or (buffer-zone-adu-alert-high-pct zone) 0.3))
                         (low-pct (or (buffer-zone-adu-alert-low-pct zone) 0.3)))
                    (hash-set! prev-adu-by-spec spec-id current-adu)
                    (if (not prev) '()
                        (let ((change-pct (if (> prev 0) (/ (- current-adu prev) prev) 0)))
                          (cond
                            ((> change-pct high-pct)
                             (list `((kind . adu-shift) (spec-id . ,spec-id)
                                     (direction . surge)
                                     (previous-adu . ,prev) (current-adu . ,current-adu)
                                     (change-pct . ,change-pct)
                                     (timestamp . ,(number->string (current-time))))))
                            ((< change-pct (- low-pct))
                             (list `((kind . adu-shift) (spec-id . ,spec-id)
                                     (direction . drop)
                                     (previous-adu . ,prev) (current-adu . ,current-adu)
                                     (change-pct . ,change-pct)
                                     (timestamp . ,(number->string (current-time))))))
                            (else '()))))))))))))


;; ═════════════════════════════════════════════════════════════════════════
;; Sinks (side-effects: event -> void)
;; ═════════════════════════════════════════════════════════════════════════

(define (create-snapshot-sink)
  "Factory: returns a sink that records daily buffer snapshots."
  (let ((last-date (make-hash-table)))
    (lambda (event ctx)
      (let ((bzs (assq-ref ctx 'buffer-zone-store))
            (sns (assq-ref ctx 'snapshot-store))
            (obs (assq-ref ctx 'observer)))
        (when (and bzs sns obs)
          (let ((today (substring (or (economic-event-has-point-in-time event)
                                      (number->string (current-time)))
                                  0 10)))
            (for-each
              (lambda (zone)
                (let ((spec (buffer-zone-spec-id zone)))
                  (unless (equal? (hash-ref last-date spec #f) today)
                    (hash-set! last-date spec today)
                    (let* ((resources ($ obs 'conforming-resources spec))
                           (onhand (fold (lambda (r a)
                                          (+ a (measure-qty
                                                 (economic-resource-onhand-quantity r))))
                                        0 resources))
                           (status (buffer-status onhand zone)))
                      ($ sns 'record-snapshot
                         (make-buffer-snapshot spec today onhand
                           (buffer-zone-tor zone) (buffer-zone-toy zone)
                           (buffer-zone-tog zone) (assq-ref status 'zone)))))))
              ($ bzs 'all-zones))))))))

(define (create-recalibration-sink profiles events-list recipe-store)
  "Factory: returns a sink that triggers buffer recalibration on overdue zones."
  (lambda (event ctx)
    (let ((bzs (assq-ref ctx 'buffer-zone-store)))
      (when bzs
        (let* ((as-of (or (and (economic-event-has-point-in-time event)
                               (iso-datetime->epoch (economic-event-has-point-in-time event)))
                          (current-time)))
               (due ($ bzs 'zones-due-for-recalibration as-of profiles)))
          ;; Recalibrate each overdue zone
          (for-each
            (lambda (zone)
              (let ((profile (hashmap-ref profiles (buffer-zone-profile-id zone) #f)))
                (when profile
                  (let* ((adu-result (compute-adu events-list (buffer-zone-spec-id zone)
                                       84 as-of))
                         (adu (assq-ref adu-result 'adu))
                         (updated (recalibrate-buffer-zone zone adu
                                    (buffer-zone-dlt-days zone) profile '() as-of)))
                    ($ bzs 'replace-zone updated)))))
            due))))))


;; ═════════════════════════════════════════════════════════════════════════
;; Standard factories
;; ═════════════════════════════════════════════════════════════════════════

(define (standard-monitors)
  "Default monitor set for a scope."
  (list buffer-status-monitor
        material-sync-monitor
        (create-adu-shift-monitor)))

(define (standard-sinks)
  "Default sink set for a scope."
  (list (create-snapshot-sink)))
