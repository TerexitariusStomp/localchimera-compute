;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; rollover-scheduler.scm — ^rollover-scheduler actor
;;;
;;; On each `tick`, the scheduler:
;;;   1. Pulls ρ and σ_I from its <covariance-view>
;;;   2. Applies the bound attribution formula to produce the
;;;      extractable rollover premium
;;;   3. Fires a user-supplied on-tick callback with the pricing alist,
;;;      so callers can refresh `Proposal.reciprocal`, emit a credential,
;;;      log, or do whatever downstream side-effect the deployment wants
;;;
;;; The scheduler itself does not cron. A shepherd service (or any other
;;; timer) calls `(tick as-of-seconds)` on cadence. This keeps the actor
;;; pure and testable without real clocks.
;;;
;;; Historical state (last result + tick count) is tracked via bcom so
;;; callers can audit pricing cadence after the fact.

(define-module (localchimera algorithms rollover-scheduler)
  #:use-module (goblins actor-lib methods)
  #:use-module (localchimera vf schemas)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (localchimera algorithms option-premium)
  #:export (^rollover-scheduler spawn-rollover-scheduler))

(define-actor (^rollover-scheduler bcom view B N R C on-tick
                                   last-result tick-count)
  ;; view:        <covariance-view> — ρ, σ_I source
  ;; B, N, R, C:  Bound parameters captured at spawn. For MVP
  ;;              these are fixed; change by spawning a new scheduler.
  ;; on-tick:     procedure (pricing-alist as-of-seconds) → any, or #f.
  ;; last-result: most recent pricing alist, or #f before first tick.
  ;; tick-count:  monotonic count of ticks applied.

  ;; on-tick is a caller-supplied closure (refresh Proposal.reciprocal,
  ;; emit a credential, log — whatever the deployment wants) and can't
  ;; survive a portrait. Excluded here; restore leaves it #f (the `when
  ;; on-tick` guard below already treats that as "no callback wired," so
  ;; this degrades to silently not firing the side-effect rather than
  ;; crashing — callers that need it re-wire via 'rewire-on-tick!.
  #:portrait
  (lambda () (list view B N R C last-result tick-count))

  #:version 1

  #:restore
  (lambda (version v b n r c result count)
    (case version
      ((1) (spawn ^rollover-scheduler v b n r c #f result count))
      (else (error "Unknown ^rollover-scheduler version" version))))

  (methods

    ((tick as-of-seconds)
     (let ((r (compute-attributed-premium/live view
                #:B B #:N N #:R R #:C C
                #:to-ts as-of-seconds)))
       (when on-tick (on-tick r as-of-seconds))
       (bcom (^rollover-scheduler bcom view B N R C on-tick
                                  r (+ 1 tick-count))
             r)))

    ((last-result) last-result)
    ((tick-count)  tick-count)
    ((view)        view)
    ((params)      `((B . ,B) (N . ,N) (R . ,R) (C . ,C)))

    ((rewire-on-tick! new-on-tick)
     "Re-supply the on-tick callback lost on restore (see #:portrait)."
     (bcom (^rollover-scheduler bcom view B N R C new-on-tick
                                last-result tick-count)))))


(define* (spawn-rollover-scheduler view
                                   #:key (B 0) (N 0) (R 0) (C 0)
                                         (on-tick #f))
  "Spawn a ^rollover-scheduler around VIEW with bound params
   (B, N, R, C). on-tick is called after each tick with
   (pricing-alist as-of-seconds)."
  (spawn ^rollover-scheduler view B N R C on-tick #f 0))
