;;; self-optimize.scm — Parameter tuning loop for the planner
;;;
;;; Takes a workload (facts + demands), runs the planner with different
;;; parameter settings, and selects the configuration that minimizes
;;; residual demand (primary) and wall time (secondary).
;;;
;;; Tunable parameters:
;;;   - max-depth       (1–20)
;;;   - max-steps       (10–200, federation only)
;;;   - demand-order    (by-due-date, by-local-first, or #f)
;;;   - scale-upper     (10–500, CLP(FD) scale range)
;;;
;;; The loop is intentionally simple — no gradient, no SA. Just:
;;;   1. Run with current params, record metrics
;;;   2. Generate candidate perturbations
;;;   3. Run each candidate, record metrics
;;;   4. Keep the best, discard the rest
;;;   5. Repeat until stable or budget exhausted
;;;
;;; This matches the BGP analogy: local policy adjustments, no global
;;; optimizer, convergence through iteration.

(use-modules (srfi srfi-1)
             (srfi srfi-9))


;;; ── Parameter set ────────────────────────────────────────────────────────────

(define-record-type <planner-params>
  (make-planner-params max-depth max-steps scale-upper demand-order)
  planner-params?
  (max-depth     params-max-depth)
  (max-steps     params-max-steps)
  (scale-upper   params-scale-upper)
  (demand-order  params-demand-order))

(define default-params
  (make-planner-params 10 50 100 #f))


;;; ── Perturbation ─────────────────────────────────────────────────────────────

(define (clamp lo hi x) (max lo (min hi x)))

(define (perturb-params params rng)
  "Generate a list of candidate parameter sets by tweaking one dimension at a time."
  (let ((d  (params-max-depth params))
        (s  (params-max-steps params))
        (su (params-scale-upper params))
        (o  (params-demand-order params)))
    (list
     ;; Depth perturbations
     (make-planner-params (clamp 1 20 (- d 2)) s su o)
     (make-planner-params (clamp 1 20 (+ d 2)) s su o)
     ;; Steps perturbations (federation)
     (make-planner-params d (clamp 10 200 (- s 10)) su o)
     (make-planner-params d (clamp 10 200 (+ s 20)) su o)
     ;; Scale upper bound
     (make-planner-params d s (clamp 10 500 (- su 20)) o)
     (make-planner-params d s (clamp 10 500 (+ su 50)) o)
     ;; Demand order variants
     (make-planner-params d s su #f)
     (make-planner-params d s su 'by-due-date)
     (make-planner-params d s su 'by-local-first))))


;;; ── Scoring ──────────────────────────────────────────────────────────────────

(define (score-result residual wall-ms)
  "Lower is better. Residual dominates; wall time is tiebreaker.
   Residual is weighted 1000x to ensure it always wins over time."
  (+ (* 1000 residual) wall-ms))


;;; ── Optimization loop ────────────────────────────────────────────────────────

(define* (optimize-params run-fn #:key
                          (initial-params default-params)
                          (max-rounds 5)
                          (budget-ms 30000))
  "Find the best planner params by iterative perturbation.

   RUN-FN: (params → (values residual wall-ms))
     A closure that runs the planner with given params and returns metrics.
     The caller builds this closure over their specific facts/demands.

   Returns: (values best-params best-residual best-wall-ms history)
     history = list of (params residual wall-ms) for all evaluated configs."
  (let loop ((current initial-params)
             (round 0)
             (total-ms 0)
             (history '()))
    ;; Evaluate current
    (let-values (((resid wall) (run-fn current)))
      (let* ((current-score (score-result resid wall))
             (history* (cons (list current resid wall) history)))
        (if (or (= round max-rounds)
                (> (+ total-ms wall) budget-ms)
                (= resid 0))  ;; perfect — no point continuing
            ;; Done: find best from history
            (let* ((best (fold (lambda (h best)
                                (if (< (score-result (cadr h) (caddr h))
                                       (score-result (cadr best) (caddr best)))
                                    h best))
                              (car history*) (cdr history*)))
                   (bp (car best)))
              (values bp (cadr best) (caddr best) (reverse history*)))
            ;; Generate and evaluate perturbations
            (let perturb-loop ((candidates (perturb-params current round))
                               (best-params current)
                               (best-resid resid)
                               (best-wall wall)
                               (inner-total (+ total-ms wall))
                               (inner-history history*))
              (if (or (null? candidates)
                      (> inner-total budget-ms))
                  ;; Move to next round with best found
                  (loop best-params (+ round 1) inner-total inner-history)
                  (let* ((candidate (car candidates)))
                    ;; Skip duplicates
                    (if (and (= (params-max-depth candidate) (params-max-depth best-params))
                             (= (params-max-steps candidate) (params-max-steps best-params))
                             (= (params-scale-upper candidate) (params-scale-upper best-params))
                             (equal? (params-demand-order candidate) (params-demand-order best-params)))
                        (perturb-loop (cdr candidates) best-params best-resid
                                      best-wall inner-total inner-history)
                        (let-values (((c-resid c-wall) (run-fn candidate)))
                          (let* ((c-score (score-result c-resid c-wall))
                                 (new-history (cons (list candidate c-resid c-wall) inner-history)))
                            (if (< c-score (score-result best-resid best-wall))
                                (perturb-loop (cdr candidates) candidate c-resid
                                              c-wall (+ inner-total c-wall) new-history)
                                (perturb-loop (cdr candidates) best-params best-resid
                                              best-wall (+ inner-total c-wall) new-history))))))))))))))


;;; ── Display ──────────────────────────────────────────────────────────────────

(define (display-optimization-result params residual wall-ms history)
  "Pretty-print optimization results."
  (display "── Optimization Complete ──\n")
  (display "  Best params:\n")
  (display "    max-depth:    ") (display (params-max-depth params)) (newline)
  (display "    max-steps:    ") (display (params-max-steps params)) (newline)
  (display "    scale-upper:  ") (display (params-scale-upper params)) (newline)
  (display "    demand-order: ") (display (params-demand-order params)) (newline)
  (display "  Residual: ") (display residual) (newline)
  (display "  Wall time: ") (display wall-ms) (display " ms\n")
  (display "  Configs evaluated: ") (display (length history)) (newline)
  (display "  History:\n")
  (for-each (lambda (h)
              (let ((p (car h)))
                (display "    d=") (display (params-max-depth p))
                (display " s=") (display (params-max-steps p))
                (display " su=") (display (params-scale-upper p))
                (display " → resid=") (display (cadr h))
                (display " wall=") (display (caddr h))
                (display "ms\n")))
            history))
