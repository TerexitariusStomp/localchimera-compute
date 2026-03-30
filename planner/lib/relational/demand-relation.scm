;;; demand-relation.scm — Core demand relation, CLP(FD) throughout
;;;
;;; Allocation via CLP(FD) domain constraints with deferred labeling.
;;; Scale via *fd over finite domains.
;;; Recipe navigation via relational queries (flow-o, chain-o).
;;; project only for: list-last, ground multiplication, duration subtraction.

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))

(define *default-depth* 10)
(define *non-consuming* '(use work cite deliver-service))


;;; ── demand-o ──────────────────────────────────────────────────────────────────

(define* (demand-o ctx spec-id qty due plan-term sums-in sums-out
                   #:key (depth *default-depth*) (visited '()))
  "Relate a demand to a plan-term. Threads running sums for shared allocation."
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
  "Branch on remaining: satisfied (=0) or need more (>0)."
  (conde
    ;; Fully satisfied from inventory
    ((== remaining 0)
     (== plan-term `(satisfied ,spec-id ,qty ,allocated))
     (== sums-out sums-in))
    ;; Need more — produce or purchase
    ((<fd 0 remaining)
     (conde
       ((produce-branch ctx spec-id remaining due plan-term sums-in sums-out
                         depth visited))
       ((== plan-term `(purchase ,spec-id ,remaining))
        (== sums-out sums-in))))))


;;; ── produce-branch ────────────────────────────────────────────────────────────

(define (produce-branch ctx spec-id remaining due plan-term
                        sums-in sums-out depth visited)
  "Find a recipe for SPEC-ID, compute scale via *fd, recurse on inputs."
  (let ((facts (ctx-facts ctx)))
    (fresh (rid rname pids)
      ;; Relational: which recipe produces this spec?
      (recipe-o facts rid rname spec-id)
      ;; Relational: what's the process chain?
      (chain-o facts rid pids)
      ;; Scale computation via CLP(FD)
      (project (pids)
        (let ((last-pid (last pids)))
          (fresh (out-qty out-unit out-action scale total-produced)
            ;; Relational: find output flow of last process
            (flow-o facts last-pid 'output spec-id out-qty out-unit out-action)
            ;; CLP(FD): scale * out-qty >= remaining
            ;; NOTE: upper bound 100 could be tightened by domain heuristic
            (rangeo scale 1 100)
            (*fd scale out-qty total-produced)
            (<=fd remaining total-produced)
            (labelfd scale)
            ;; Collect consuming inputs and recurse
            (project (scale)
              (let ((inputs (collect-inputs-relational facts pids scale due)))
                (fresh (sub-plans)
                  (solve-inputs-o ctx inputs sub-plans sums-in sums-out
                                  (- depth 1) visited)
                  (== plan-term
                       `(produce ,spec-id ,rid ,scale ,sub-plans)))))))))))


;;; ── collect-inputs-relational ─────────────────────────────────────────────────
;;; Back-schedules through process chain, collects consuming input flows.
;;; Uses Scheme on ground values (pids list, scale, durations) — these are
;;; all concrete by this point (pids from chain-o, scale from labelfd).
;;; project is honest: these are functions on ground values.

(define (collect-inputs-relational facts pids scale due)
  "Collect consuming input demands as (spec-id scaled-qty needed-by) triples."
  (let* (;; Internal output specs (don't recurse into these)
         (internal-specs
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
                                  (list-ref f 4)))  ;; has qty
                           facts))
                 (new-inputs
                   (map (lambda (f)
                          (list (cadddr f)                         ;; spec-id
                                (inexact->exact
                                  (ceiling (* (list-ref f 4) scale)))  ;; scaled qty
                                proc-begin))                       ;; needed-by
                        input-flows)))
            (loop (cdr procs) proc-begin (append acc new-inputs)))))))


;;; ── solve-inputs-o ────────────────────────────────────────────────────────────

(define (solve-inputs-o ctx inputs sub-plans sums-in sums-out depth visited)
  "Solve input demands, threading running sums through."
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
