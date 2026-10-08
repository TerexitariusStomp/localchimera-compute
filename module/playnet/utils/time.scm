;;; module/playnet/utils/time.scm — shared time helpers
;;;
;;; Extracted from ai/key-pool.scm, policy.scm, poller.scm, reconciler.scm
;;; where it was defined identically four times.

(define-module (playnet utils time)
  #:use-module (srfi srfi-19)
  #:export (current-epoch-seconds))

(define (current-epoch-seconds)
  "Current wall-clock time as integer seconds since Unix epoch.

   UNIX deliberately: these stamps interoperate with external protocols
   (KERI event timestamps, Monero policy windows, fleet reconciliation)
   that speak Unix time. The PLANNER's numeric instants ride a different
   clock — (playnet utils clock), GPS scale — and the two must not mix:
   an instant enters a plan ledger only through that module's boundary."
  (time-second (current-time time-utc)))
