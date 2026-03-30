;;; netter-goals.scm — Allocation goals for the relational planner
;;;
;;; Goals that thread the netter state through miniKanren search.
;;; Use `project` to ground arguments before calling netter operations.
;;; Use `<plan-ctx>` for store references.

(use-modules (playnet kanren-planning)
             (srfi srfi-11))

(define *epsilon-rp* 1e-9)

(define* (net-demand-o ctx spec-id qty remaining allocated
                       #:key (needed-by #f))
  "Goal: net demand against inventory + scheduled outputs.
   SPEC-ID and QTY must be ground (project ensures this)."
  (project (spec-id qty)
    (lambda (st)
      (let-values (((new-ns rem alloc)
                    (netter-net-demand (planning-state-netter st)
                      (ctx-ps ctx) (ctx-obs ctx) spec-id qty
                      #:plan-id (ctx-plan-id ctx)
                      #:location-store (ctx-ls ctx)
                      #:needed-by needed-by)))
        (let ((st* (make-planning-state (planning-state-subst st)
                     (planning-state-counter st) new-ns)))
          ((conj (== remaining rem) (== allocated alloc)) st*))))))

(define* (net-supply-o ctx spec-id qty remaining
                       #:key (available-from #f))
  "Goal: deduct pre-claimed consuming flows from supply."
  (project (spec-id qty)
    (lambda (st)
      (let-values (((new-ns rem)
                    (netter-net-supply (planning-state-netter st)
                      (ctx-ps ctx) spec-id qty
                      #:available-from available-from
                      #:location-store (ctx-ls ctx))))
        (let ((st* (make-planning-state (planning-state-subst st)
                     (planning-state-counter st) new-ns)))
          ((== remaining rem) st*))))))

(define* (reserve-o ctx spec-id qty reserved)
  "Goal: reserve capacity for buffer replenishment."
  (project (spec-id qty)
    (lambda (st)
      (let-values (((new-ns actually-reserved)
                    (netter-reserve (planning-state-netter st)
                      (ctx-ps ctx) (ctx-obs ctx) spec-id qty
                      #:plan-id (ctx-plan-id ctx)
                      #:location-store (ctx-ls ctx))))
        (let ((st* (make-planning-state (planning-state-subst st)
                     (planning-state-counter st) new-ns)))
          ((== reserved actually-reserved) st*))))))

(define (demand-satisfied? remaining)
  (< remaining *epsilon-rp*))
