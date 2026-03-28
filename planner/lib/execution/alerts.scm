;;; alerts.scm — Goblins actor for execution alert accumulation
;;;
;;; Translated from src/lib/execution/alerts.ts (AlertStore)
;;; State: append-only list of alert alists.
;;;
;;; Alerts are alists (not records) with a 'kind symbol discriminator:
;;;   buffer-status: kind, spec-id, zone, onhand, tor, toy, tog, timestamp
;;;   adu-shift:     kind, spec-id, direction, previous-adu, current-adu, change-pct, timestamp
;;;   material-sync: kind, spec-id, process-id, input-commitment-id, required-qty,
;;;                  projected-available, shortage, timestamp
;;;   lead-time:     kind, order-id, spec-id, due-date, days-remaining, alert-zone, timestamp

(use-modules (goblins)
             (goblins actor-lib methods)
             (srfi srfi-1))

;; Assumes store-utils.scm is loaded.


;; =========================================================================
;; Alert accessors (alist-based)
;; =========================================================================

(define (alert-kind alert)    (assq-ref alert 'kind))
(define (alert-spec-id alert) (assq-ref alert 'spec-id))
(define (alert-timestamp alert) (assq-ref alert 'timestamp))


;; =========================================================================
;; ^alert-store
;; =========================================================================

(define-actor (^alert-store bcom alerts)
  ;; alerts: list of alists (newest first)

  #:portrait
  (lambda () (list alerts))

  #:version 1

  #:restore
  (lambda (version data)
    (case version
      ((1) (spawn ^alert-store data))
      (else (error "Unknown ^alert-store version" version))))

  (methods

    ((push-alert alert)
     ;; Add a single alert (alist with 'kind key).
     (bcom (^alert-store bcom (cons alert alerts))))

    ((of-kind kind)
     ;; Filter alerts by kind symbol.
     (filter (lambda (a) (eq? (alert-kind a) kind)) alerts))

    ((for-spec spec-id)
     ;; Filter alerts by spec-id.
     (filter (lambda (a) (equal? (alert-spec-id a) spec-id)) alerts))

    ((since timestamp)
     ;; All alerts with timestamp >= the given ISO string.
     (filter (lambda (a)
               (let ((ts (alert-timestamp a)))
                 (and ts (string>=? ts timestamp))))
             alerts))

    ((all-alerts)
     (reverse alerts))

    ((alert-count)
     (length alerts))

    ((clear)
     (bcom (^alert-store bcom '())))))


;; =========================================================================
;; Persistence environment
;; =========================================================================

(define alert-store-env
  (make-persistence-env
    `((((vf execution) ^alert-store) ,^alert-store))))
