;;; comms/metabolism.scm — read the four derived Stage-1 quantities off ONE solve.
;;;
;;; The comms campaign is expressed as located ValueFlows (compose/publish
;;; processes, channels as `use`d Svc goods, a reproduction need as a demand), so
;;; ONE located solve yields all of Stage 1 with no bolt-ons:
;;;   • selection / dual-of : good-pulls — the pull on each need
;;;   • fragility           : a rented channel's Svc good carries a frag barrier,
;;;                           so the solve ROUTES reach onto sovereign channels
;;;   • scheduling          : per-period Svc|channel capacity → per-period activity
;;;   • selection (endog.)  : the solve allocates compose/publish to the need
;;;
;;; Everything here is a READ of the single solve-report — the derived dual-of the
;;; deterministic ranker (comms/plan.scm rank-comm-intents) consumes is now the solver's
;;; own arithmetic, not a lookup. Load AFTER planner.scm; globals must be set.

(define (comms-solve)
  "Run the located metabolism solve on the current planner globals under the
   NATIVE backend (so λ = t/slack duals are exact). → (values x t cols idx report)."
  (set! *backend* 'native)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((res (call-with-values
                    (lambda () (solve-native forms labform (located-warm cols ncol idx))) list))
             (x (car res)) (t (cadr res)))
        (values x t cols idx (solve-report x cols idx t))))))

(define (comms-dual-of report)
  "The DERIVED dual-of: a closure over the solve's good-pulls mapping a located-
   good key → its pull (0.0 if absent). This is exactly what
   rank-comm-intents (comms/plan.scm) wants — selection priority = the solver's dual."
  (let ((gp (assq-ref report 'good-pulls)))   ; 'good-pulls is a symbol → assq-ref ok
    (lambda (good-key)                          ; but the good keys are STRINGS → need assoc
      (let ((p (assoc good-key gp))) (if p (cdr p) 0.0)))))

(define (process-schedule x idx proc place periods)
  "The per-period activity level of PROC at PLACE — the derived posting schedule
   over the horizon. → ((period . level) …), 0.0 where the column is absent."
  (map (lambda (p)
         (let ((i (hash-ref idx (string-append "p|" proc "|" place "@" (number->string p)) #f)))
           (cons p (if i (vector-ref x i) 0.0))))
       periods))

(define (schedule-total sched) (fold + 0.0 (map cdr sched)))

;; ─── service bridge : the solve's duals → the ranker's (intent-id → dual) ────
;; comms-dual-of keys by located-good; rank-comm-intents (comms/plan.scm) keys by
;; intent-id. INTENT->GOOD bridges them (an intent-id → its need's located-good),
;; so selection in the live service is the solver's own shadow prices.
(define (comms-intent-dual-of report intent->good)
  (let ((dual-of (comms-dual-of report)))
    (lambda (intent-id) (dual-of (intent->good intent-id)))))
