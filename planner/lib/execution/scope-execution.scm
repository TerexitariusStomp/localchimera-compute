;;; scope-execution.scm — Execution engine for a scope
;;;
;;; Translated from src/lib/execution/scope-execution.ts
;;; Starts reactive monitoring: subscribes to the observer and dispatches
;;; events through monitors (pure -> alerts) and sinks (side effects).
;;;
;;; In the Goblins model, this runs within the scope's vat.
;;; The observer doesn't have subscribe() in the actor model — instead,
;;; the execution engine wraps record-event calls with monitor dispatch.

;; Assumes monitors.scm and all store actors are loaded.


;; ═════════════════════════════════════════════════════════════════════════
;; Execution context
;; ═════════════════════════════════════════════════════════════════════════

(define (make-execution-context observer plan-store buffer-zone-store
                                snapshot-store)
  "Build an execution context alist for monitors and sinks."
  `((observer . ,observer)
    (plan-store . ,plan-store)
    (buffer-zone-store . ,buffer-zone-store)
    (snapshot-store . ,snapshot-store)))


;; ═════════════════════════════════════════════════════════════════════════
;; record-and-monitor — wraps observer.record-event with monitor dispatch
;; ═════════════════════════════════════════════════════════════════════════

(define* (record-and-monitor observer event ctx alert-store
                             #:key (monitors (standard-monitors))
                                   (sinks (standard-sinks)))
  "Record an event via the observer, then dispatch through monitors and sinks.
   Returns affected resources (from observer.record-event).
   Alerts are pushed to alert-store."
  (let ((affected ($ observer 'record-event event)))
    ;; Dispatch monitors: pure event -> alerts
    (for-each
      (lambda (monitor)
        (let ((alerts (monitor event ctx)))
          (for-each (lambda (alert) ($ alert-store 'push-alert alert))
                    alerts)))
      monitors)
    ;; Dispatch sinks: side effects
    (for-each
      (lambda (sink) (sink event ctx))
      sinks)
    affected))
