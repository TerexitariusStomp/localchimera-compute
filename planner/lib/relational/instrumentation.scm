;;; instrumentation.scm — Planner performance instrumentation
;;;
;;; Wraps plan-o, demand-o, and plan-federation-o to record:
;;;   - wall time per call
;;;   - residual at termination
;;;   - search steps taken
;;;   - depth reached
;;;   - plan structure (satisfied / unmet / produce counts)
;;;
;;; Data is stored in a mutable log — a plain list in reverse chronological
;;; order. The log is the feedback signal for a future self-optimization loop.
;;;
;;; Usage:
;;;   (define log (make-perf-log))
;;;   (define result (instrumented-plan n ctx log #:max-depth 10))
;;;   (perf-log-entries log)   → list of entries
;;;   (perf-log-summary log)   → alist of aggregate metrics

(use-modules (srfi srfi-1)
             (srfi srfi-9))


;;; ── Performance log ──────────────────────────────────────────────────────────

(define-record-type <perf-log>
  (%make-perf-log entries)
  perf-log?
  (entries perf-log-entries set-perf-log-entries!))

(define (make-perf-log)
  (%make-perf-log '()))

(define (perf-log-append! log entry)
  (set-perf-log-entries! log (cons entry (perf-log-entries log))))

(define (perf-log-clear! log)
  (set-perf-log-entries! log '()))


;;; ── Entry structure ──────────────────────────────────────────────────────────
;;; Each entry is an alist:
;;;   ((type . plan|demand|federation)
;;;    (wall-ms . number)
;;;    (specs . list)        — specs queried
;;;    (residual . number)   — total unmet qty at end
;;;    (satisfied . number)  — count of satisfied terms
;;;    (unmet . number)      — count of unmet terms
;;;    (produced . number)   — count of produce terms
;;;    (depth . number)      — max-depth used
;;;    (result-count . number))  — how many plans found

(define (make-entry type wall-ms specs residual
                    satisfied-count unmet-count produced-count
                    depth result-count)
  `((type . ,type)
    (wall-ms . ,wall-ms)
    (specs . ,specs)
    (residual . ,residual)
    (satisfied . ,satisfied-count)
    (unmet . ,unmet-count)
    (produced . ,produced-count)
    (depth . ,depth)
    (result-count . ,result-count)))


;;; ── Plan structure analysis ──────────────────────────────────────────────────

(define (count-plan-terms plan)
  "Walk a plan tree and count (satisfied N) (unmet N) (produce N)."
  (let loop ((tree plan) (sat 0) (unm 0) (prod 0) (resid 0))
    (cond
      ((not (pair? tree)) (values sat unm prod resid))
      ;; A plan-term: (satisfied spec qty alloc)
      ((and (pair? tree) (eq? (car tree) 'satisfied))
       (values (+ sat 1) unm prod resid))
      ;; (unmet spec remaining)
      ((and (pair? tree) (eq? (car tree) 'unmet))
       (let ((qty (if (and (pair? (cdr tree)) (pair? (cddr tree)))
                      (caddr tree) 0)))
         (values sat (+ unm 1) prod (+ resid (if (number? qty) qty 0)))))
      ;; (produce spec rid scale sub-plans)
      ((and (pair? tree) (eq? (car tree) 'produce))
       (let ((subs (if (>= (length tree) 5) (list-ref tree 4) '())))
         (let-values (((s u p r) (count-plan-terms subs)))
           (values (+ sat s) (+ unm u) (+ prod 1 p) (+ resid r)))))
      ;; List of (demand plan-term) pairs from all-demands-o
      ((and (pair? tree) (pair? (car tree)) (list? (car tree)))
       (let-values (((s1 u1 p1 r1) (count-plan-terms (car tree))))
         (let-values (((s2 u2 p2 r2) (count-plan-terms (cdr tree))))
           (values (+ s1 s2) (+ u1 u2) (+ p1 p2) (+ r1 r2)))))
      ;; (demand-alist plan-term) — unwrap the plan-term
      ((and (pair? tree) (pair? (car tree)) (pair? (cadr tree)))
       (count-plan-terms (cadr tree)))
      ;; Recurse into pairs
      (else
       (let-values (((s1 u1 p1 r1) (count-plan-terms (car tree))))
         (let-values (((s2 u2 p2 r2) (count-plan-terms (cdr tree))))
           (values (+ s1 s2) (+ u1 u2) (+ p1 p2) (+ r1 r2))))))))


;;; ── Timing ───────────────────────────────────────────────────────────────────

(define (current-time-ms)
  "Monotonic wall time in milliseconds."
  (let ((t (get-internal-real-time)))
    (inexact->exact (round (* (/ t internal-time-units-per-second) 1000)))))


;;; ── Instrumented wrappers ────────────────────────────────────────────────────

(define* (instrumented-plan n ctx log
                            #:key (max-depth 10) (demand-order #f))
  "Run plan-o and record performance data to LOG."
  (let* ((t0 (current-time-ms))
         (results (run-plan n #f (plan)
                   (plan-o ctx plan #:max-depth max-depth
                                    #:demand-order demand-order)))
         (t1 (current-time-ms))
         (wall (- t1 t0))
         (result-count (length results))
         (first-plan (if (null? results) '() (car results))))
    (let-values (((sat unm prod resid) (count-plan-terms first-plan)))
      (let ((entry (make-entry 'plan wall '() resid
                               sat unm prod max-depth result-count)))
        (perf-log-append! log entry)
        results))))

(define* (instrumented-federation facts scope-ids parent-map ctx-map log)
  "Run plan-federation-o and record performance data to LOG."
  (let* ((t0 (current-time-ms))
         (results (run-plan 1 #f (result)
                   (plan-federation-o facts scope-ids parent-map ctx-map result)))
         (t1 (current-time-ms))
         (wall (- t1 t0))
         (first (if (null? results) '() (car results)))
         (residual (if (pair? first)
                       (or (assq-ref first 'residual) 0) 0)))
    (let ((entry (make-entry 'federation wall scope-ids residual
                             0 0 0 0 (length results))))
      (perf-log-append! log entry)
      results)))


;;; ── Aggregate metrics ────────────────────────────────────────────────────────

(define (perf-log-summary log)
  "Aggregate statistics from all entries in LOG."
  (let* ((entries (perf-log-entries log))
         (n (length entries)))
    (if (= n 0)
        '((count . 0))
        (let* ((walls (map (lambda (e) (assq-ref e 'wall-ms)) entries))
               (resids (map (lambda (e) (assq-ref e 'residual)) entries))
               (sats (map (lambda (e) (assq-ref e 'satisfied)) entries))
               (unmets (map (lambda (e) (assq-ref e 'unmet)) entries)))
          `((count . ,n)
            (total-wall-ms . ,(apply + walls))
            (avg-wall-ms . ,(inexact->exact (round (/ (apply + walls) n))))
            (max-wall-ms . ,(apply max walls))
            (min-wall-ms . ,(apply min walls))
            (total-residual . ,(apply + resids))
            (avg-residual . ,(/ (apply + resids) n))
            (zero-residual-count . ,(length (filter zero? resids)))
            (total-satisfied . ,(apply + sats))
            (total-unmet . ,(apply + unmets)))))))


;;; ── Pretty-print ─────────────────────────────────────────────────────────────

(define (perf-log-display log)
  "Print a human-readable summary to current output port."
  (let ((summary (perf-log-summary log)))
    (display "── Planner Performance ──\n")
    (for-each (lambda (pair)
                (display "  ")
                (display (car pair))
                (display ": ")
                (display (cdr pair))
                (newline))
              summary)))
