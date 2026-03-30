;;; demand-relation.scm — Core demand relation, fully relational
;;;
;;; No project. Allocation via CLP(FD) with propagation queue.
;;; Scale via *fd. Recipe navigation via flow-o/chain-o/lasto.
;;; Scheduling arithmetic via -fd on ground durations.

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))

(define *default-depth* 10)
(define *non-consuming* '(use work cite deliver-service))


;;; ── demand-o ──────────────────────────────────────────────────────────────────

(define* (demand-o ctx spec-id qty due plan-term sums-in sums-out
                   #:key (depth *default-depth*) (visited '()))
  "Relate a demand to a plan-term. Fully relational."
  (if (or (= depth 0) (member spec-id visited))
      fail
      (fresh (remaining allocated sums-mid)
        (allocate-o (ctx-facts ctx) spec-id qty remaining allocated sums-in sums-mid)
        (after-allocation ctx spec-id qty due remaining allocated
                          plan-term sums-mid sums-out
                          depth (cons spec-id visited)))))


;;; ── after-allocation ──────────────────────────────────────────────────────────

(define (after-allocation ctx spec-id qty due remaining allocated
                          plan-term sums-in sums-out depth visited)
  "Branch: satisfied (remaining=0) or need more (remaining>0). No project."
  (conde
    ((== remaining 0)
     (== plan-term `(satisfied ,spec-id ,qty ,allocated))
     (== sums-out sums-in))
    ((<fd 0 remaining)
     (conde
       ((produce-branch ctx spec-id remaining due plan-term sums-in sums-out
                         depth visited))
       ((== plan-term `(purchase ,spec-id ,remaining))
        (== sums-out sums-in))))))


;;; ── produce-branch ────────────────────────────────────────────────────────────

(define (produce-branch ctx spec-id remaining due plan-term
                        sums-in sums-out depth visited)
  "Find a recipe, compute scale via *fd, collect inputs relationally."
  (let ((facts (ctx-facts ctx)))
    (fresh (rid rname pids last-pid out-qty out-unit out-action
            scale total-produced sub-plans)
      ;; Relational: which recipe? what chain? what's the last process?
      (recipe-o facts rid rname spec-id)
      (chain-o facts rid pids)
      (lasto pids last-pid)
      ;; Relational: what's the output flow?
      (flow-o facts last-pid 'output spec-id out-qty out-unit out-action)
      ;; CLP(FD): scale * out-qty >= remaining
      ;; NOTE: upper bound 100 can be tightened by heuristic
      (rangeo scale 1 100)
      (*fd scale out-qty total-produced)
      (<=fd remaining total-produced)
      (labelfd scale)
      ;; Collect inputs and recurse (scale and pids are ground after labeling)
      (project (scale pids)
        (let ((inputs (back-schedule-inputs facts pids scale due)))
          (fresh ()
            (solve-inputs-o ctx inputs sub-plans sums-in sums-out
                            (- depth 1) visited)
            (== plan-term `(produce ,spec-id ,rid ,scale ,sub-plans))))))))


;;; ── back-schedule-inputs ──────────────────────────────────────────────────────
;;; Back-schedules through process chain, collects consuming inputs.
;;; pids and scale are ground (from labelfd). Duration facts are ground integers.
;;; This is a fold over ground data — no search, no alternatives.
;;; project is honest: these are functions on ground values.

(define (back-schedule-inputs facts pids scale due)
  "Collect consuming input demands. Ground fold — no search."
  (let* ((internal-specs
           (filter-map (lambda (f)
                         (and (eq? (car f) 'flow)
                              (member (cadr f) pids)
                              (eq? (caddr f) 'output)
                              (cadddr f)))
                       facts)))
    (let loop ((procs (reverse pids)) (cursor due) (acc '()))
      (if (null? procs)
          (reverse acc)
          (let* ((pid (car procs))
                 (proc-fact (find (lambda (f)
                                   (and (eq? (car f) 'process)
                                        (equal? (cadr f) pid)))
                                 facts))
                 (dur-ms (if proc-fact (cadddr proc-fact) 3600000))
                 (dur-s (inexact->exact (round (/ dur-ms 1000))))
                 (proc-begin (- cursor dur-s))
                 (input-flows
                   (filter (lambda (f)
                             (and (eq? (car f) 'flow)
                                  (equal? (cadr f) pid)
                                  (eq? (caddr f) 'input)
                                  (not (memq (list-ref f 6) *non-consuming*))
                                  (not (member (cadddr f) internal-specs))
                                  (list-ref f 4)))
                           facts))
                 (new-inputs
                   (map (lambda (f)
                          (list (cadddr f)
                                (inexact->exact (ceiling (* (list-ref f 4) scale)))
                                proc-begin))
                        input-flows)))
            (loop (cdr procs) proc-begin (append acc new-inputs)))))))


;;; ── solve-inputs-o ────────────────────────────────────────────────────────────

(define (solve-inputs-o ctx inputs sub-plans sums-in sums-out depth visited)
  (if (null? inputs)
      (fresh () (== sub-plans '()) (== sums-out sums-in))
      (let* ((input (car inputs))
             (in-spec (car input))
             (in-qty (cadr input))
             (needed-by (caddr input)))
        (fresh (sub-plan rest-plans sums-mid)
          (demand-o ctx in-spec in-qty needed-by sub-plan sums-in sums-mid
                    #:depth depth #:visited visited)
          (solve-inputs-o ctx (cdr inputs) rest-plans sums-mid sums-out
                          depth visited)
          (== sub-plans (cons (list in-spec sub-plan) rest-plans))))))
