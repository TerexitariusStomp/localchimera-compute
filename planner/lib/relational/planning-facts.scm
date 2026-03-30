;;; planning-facts.scm — Lift VF records to plain tuples, query as relations
;;;
;;; The lift runs once at session start: records → tagged tuples.
;;; Fact relations query tuples via in-list-o + unification.
;;;
;;; Fact shapes:
;;;   (recipe    RID NAME PRIMARY-OUTPUT)
;;;   (chain     RID (PID1 PID2 ...))
;;;   (process   PID NAME DURATION-MS)
;;;   (flow      PID DIRECTION SPEC-ID QTY UNIT ACTION)
;;;   (inventory RESOURCE-ID SPEC-ID QTY LOCATION)
;;;
;;; Assumes schemas.scm, propagation.scm, and kanren-planning.scm are loaded.

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))

(define *non-consuming-actions* '(use work cite deliver-service))


;;; ── Lift ──────────────────────────────────────────────────────────────────────

(define* (lift-planning-facts recipe-store #:optional (observer #f))
  "Extract all planning facts from store actors as plain tuples.
   If OBSERVER is provided, inventory resources are included."
  (let ((all-recipes ($ recipe-store 'all-recipes)))
    (append
      ;; Recipe facts
      (map (lambda (r)
             `(recipe ,(recipe-id r) ,(recipe-name r) ,(recipe-primary-output r)))
           all-recipes)
      ;; Chain facts (topo-sorted process-id lists)
      (filter-map
        (lambda (r)
          (let ((chain ($ recipe-store 'get-process-chain (recipe-id r))))
            (and (pair? chain)
                 `(chain ,(recipe-id r)
                         ,(map recipe-process-id chain)))))
        all-recipes)
      ;; Process facts
      (append-map
        (lambda (r)
          (let ((chain ($ recipe-store 'get-process-chain (recipe-id r))))
            (map (lambda (rp)
                   `(process ,(recipe-process-id rp)
                             ,(recipe-process-name rp)
                             ,(rp-duration-ms rp)))
                 chain)))
        all-recipes)
      ;; Flow facts
      (append-map
        (lambda (r)
          (let ((chain ($ recipe-store 'get-process-chain (recipe-id r))))
            (append-map
              (lambda (rp)
                (let* ((pid (recipe-process-id rp))
                       (pair ($ recipe-store 'flows-for-process pid))
                       (inputs (car pair))
                       (outputs (cdr pair)))
                  (append
                    (map (lambda (f)
                           `(flow ,pid input
                                  ,(recipe-flow-resource-conforms-to f)
                                  ,(and (recipe-flow-resource-quantity f)
                                        (measure-has-numerical-value
                                          (recipe-flow-resource-quantity f)))
                                  ,(and (recipe-flow-resource-quantity f)
                                        (measure-has-unit
                                          (recipe-flow-resource-quantity f)))
                                  ,(recipe-flow-action f)))
                         inputs)
                    (map (lambda (f)
                           `(flow ,pid output
                                  ,(recipe-flow-resource-conforms-to f)
                                  ,(and (recipe-flow-resource-quantity f)
                                        (measure-has-numerical-value
                                          (recipe-flow-resource-quantity f)))
                                  ,(and (recipe-flow-resource-quantity f)
                                        (measure-has-unit
                                          (recipe-flow-resource-quantity f)))
                                  ,(recipe-flow-action f)))
                         outputs))))
              chain)))
        all-recipes)
      ;; Inventory facts (if observer provided)
      (if observer
          (filter-map
            (lambda (r)
              (let ((qty (measure-qty (economic-resource-accounting-quantity r))))
                (and (> qty 0)
                     `(inventory ,(economic-resource-id r)
                                ,(economic-resource-conforms-to r)
                                ,(inexact->exact (round qty))
                                ,(economic-resource-current-location r)))))
            ($ observer 'all-resources))
          '()))))


;;; ── Fact relations ────────────────────────────────────────────────────────────

(define (recipe-o facts rid name output)
  "Relate a recipe ID, name, and primary output spec."
  (in-list-o `(recipe ,rid ,name ,output) facts))

(define (chain-o facts rid pids)
  "Relate a recipe ID to its topo-sorted process-id list."
  (in-list-o `(chain ,rid ,pids) facts))

(define (process-o facts pid name duration-ms)
  "Relate a process ID to its name and duration."
  (in-list-o `(process ,pid ,name ,duration-ms) facts))

(define (flow-o facts pid direction spec-id qty unit action)
  "Relate a process to one of its flows."
  (in-list-o `(flow ,pid ,direction ,spec-id ,qty ,unit ,action) facts))

(define (inventory-o facts resource-id spec-id qty location)
  "Relate an inventory resource to its spec, quantity, and location."
  (in-list-o `(inventory ,resource-id ,spec-id ,qty ,location) facts))


;;; ── Arithmetic helpers removed — scale via *fd, inputs via flow-o ─────────────
;;; compute-scale and collect-consuming-inputs were here.
;;; Now replaced by CLP(FD) *fd for scale and collect-inputs-relational
;;; in demand-relation.scm.

(define (compute-scale facts rid spec-id demand-qty)
  "Compute scale factor for a recipe to produce DEMAND-QTY of SPEC-ID."
  (let* ((output-flows (filter (lambda (f)
                                 (and (eq? (cadr f) 'output)  ;; direction
                                      (equal? (caddr f) spec-id)))  ;; spec
                               (filter (lambda (f) (eq? (car f) 'flow)) facts)))
         ;; Find the output flow for this recipe's last process
         (chain-fact (find (lambda (f)
                            (and (eq? (car f) 'chain) (equal? (cadr f) rid)))
                          facts))
         (pids (and chain-fact (caddr chain-fact)))
         (last-pid (and pids (pair? pids) (last pids)))
         (primary (and last-pid
                       (find (lambda (f)
                               (and (eq? (car f) 'flow)
                                    (equal? (cadr f) last-pid)
                                    (eq? (caddr f) 'output)
                                    (equal? (cadddr f) spec-id)))
                             facts)))
         (out-qty (if primary (list-ref primary 4) 1)))
    (if (and out-qty (> out-qty 0))
        (/ demand-qty out-qty)
        demand-qty)))

(define (collect-consuming-inputs facts rid scale due-date)
  "Collect consuming input demands as (spec-id scaled-qty needed-by) triples.
   Back-schedules from DUE-DATE using process durations."
  (let* ((chain-fact (find (lambda (f)
                            (and (eq? (car f) 'chain) (equal? (cadr f) rid)))
                          facts))
         (pids (if chain-fact (caddr chain-fact) '()))
         ;; Collect internal output specs (don't recurse into these)
         (internal-specs
           (filter-map (lambda (f)
                         (and (eq? (car f) 'flow)
                              (member (cadr f) pids)
                              (eq? (caddr f) 'output)
                              (cadddr f)))
                       facts)))
    ;; Back-schedule through process chain
    (let loop ((procs (reverse pids)) (cursor due-date) (acc '()))
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
                 ;; Find consuming input flows for this process
                 (input-flows
                   (filter (lambda (f)
                             (and (eq? (car f) 'flow)
                                  (equal? (cadr f) pid)
                                  (eq? (caddr f) 'input)
                                  (not (memq (list-ref f 6) *non-consuming-actions*))
                                  (not (member (cadddr f) internal-specs))
                                  (list-ref f 4)))  ;; has qty
                           facts))
                 (new-inputs
                   (map (lambda (f)
                          (list (cadddr f)                       ;; spec-id
                                (* (list-ref f 4) scale)         ;; scaled qty
                                proc-begin))                     ;; needed-by
                        input-flows)))
            (loop (cdr procs) proc-begin (append acc new-inputs)))))))
