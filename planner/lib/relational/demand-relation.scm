;;; demand-relation.scm — Core demand relation, fully relational
;;;
;;; Allocation via CLP(FD) with propagation queue.
;;; Scale via *fd with MBQ lower bound. Recipe navigation via indexed lookups.
;;; Three input solvers: consume (recursive), use (time-windowed), cite (gate).
;;; Location-aware allocation when at-location is provided.

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))

(define *default-depth* 10)
;; Actions excluded from recursive demand explosion in back-schedule-inputs.
;; 'use' → time-windowed allocation (solve-use-inputs-o)
;; 'cite' → existence gate (solve-cite-inputs-o)
;; 'work' / 'deliver-service' → labor/service, not resource allocation
(define *non-consuming* '(use work cite deliver-service))


;;; ── demand-o ──────────────────────────────────────────────────────────────────

(define* (demand-o ctx spec-id qty due plan-term sums-in sums-out
                   #:key (depth *default-depth*) (visited '())
                         (at-location #f) (container-id #f))
  "Relate a demand to a plan-term. Fully relational."
  (if (or (= depth 0) (member spec-id visited))
      fail
      (fresh (remaining allocated sums-mid)
        (allocate-o (ctx-facts ctx) spec-id qty remaining allocated sums-in sums-mid
                    #:indexes (ctx-indexes ctx) #:at-location at-location
                    #:container-id container-id)
        (after-allocation ctx spec-id qty due remaining allocated
                          plan-term sums-mid sums-out
                          depth (cons spec-id visited) at-location))))


;;; ── after-allocation ──────────────────────────────────────────────────────────

(define (after-allocation ctx spec-id qty due remaining allocated
                          plan-term sums-in sums-out depth visited at-location)
  "Branch: satisfied (remaining=0) or need more (remaining>0)."
  (conde
    ((== remaining 0)
     (== plan-term `(satisfied ,spec-id ,qty ,allocated ,at-location))
     (== sums-out sums-in))
    ((<fd 0 remaining)
     (conde
       ((produce-branch ctx spec-id remaining due plan-term sums-in sums-out
                         depth visited at-location))
       ((transport-branch ctx spec-id remaining due plan-term sums-in sums-out
                           at-location))
       ((== plan-term `(unmet ,spec-id ,remaining ,at-location))
        (== sums-out sums-in))))))


;;; ── produce-branch ────────────────────────────────────────────────────────────

(define (produce-branch ctx spec-id remaining due plan-term
                        sums-in sums-out depth visited at-location)
  "Find a recipe, compute scale via *fd (respecting MBQ), collect inputs."
  (let ((facts (ctx-facts ctx))
        (indexes (ctx-indexes ctx)))
    (fresh (rid rname pids last-pid out-qty out-unit out-action
            scale total-produced)
      ;; Find recipe
      (if indexes
          (recipe-indexed-o indexes spec-id rid rname)
          (recipe-o facts rid rname spec-id))
      (if indexes
          (chain-indexed-o indexes rid pids)
          (chain-o facts rid pids))
      (lasto pids last-pid)
      ;; Output flow
      (if indexes
          (flow-indexed-o indexes last-pid 'output spec-id out-qty out-unit out-action)
          (flow-o facts last-pid 'output spec-id out-qty out-unit out-action))
      ;; Scale via CLP(FD) — lower bound from MBQ of last process
      (project (pids last-pid)
        (let* ((proc-fact (find (lambda (f) (and (eq? (car f) 'process)
                                                  (equal? (cadr f) last-pid)))
                                facts))
               (mbq (if (and proc-fact (> (length proc-fact) 4))
                        (list-ref proc-fact 4) 1)))
          (fresh ()
            (rangeo scale mbq 100)
            (*fd scale out-qty total-produced)
            (<=fd remaining total-produced)
            (labelfd scale)
            ;; Collect all three input types
            (project (scale)
              (let ((consuming (back-schedule-inputs facts pids scale due))
                    (using (use-schedule-inputs facts pids scale due))
                    (citing (cite-schedule-inputs facts pids)))
                ;; Solve use-inputs FIRST — they provide anchor resource-ids
                ;; for container resolution of dependent consuming flows
                (fresh (consume-plans use-plans cite-plans sums-m2 sums-m3)
                  (solve-use-inputs-o ctx using use-plans sums-in sums-m2)
                  (project (use-plans)
                    (fresh ()
                      (solve-inputs-o ctx consuming consume-plans sums-m2 sums-m3
                                      (- depth 1) visited at-location use-plans)
                      (solve-cite-inputs-o (ctx-facts ctx) citing cite-plans)
                      (== plan-term `(produce ,spec-id ,rid ,scale
                                              ,consume-plans ,use-plans
                                              ,cite-plans)))))))))))))


;;; ── transport-branch ─────────────────────────────────────────────────────────
;;; Sources from a different location when local allocation + production fail.
;;; miniKanren explores all source locations via inventory-o naturally.

(define (transport-branch ctx spec-id remaining due plan-term
                          sums-in sums-out at-location)
  "Allocate from a different location. Only tried when at-location is set."
  (if (not at-location) fail
      (let ((facts (ctx-facts ctx))
            (indexes (ctx-indexes ctx)))
        (fresh (rid source-loc source-qty contained-in)
          ;; Find inventory at ANY location
          (in-list-o `(inventory ,rid ,spec-id ,source-qty ,source-loc ,contained-in)
                     (if indexes
                         (idx-ref indexes 'inventory-by-spec spec-id)
                         (filter (lambda (f) (and (eq? (car f) 'inventory)
                                                   (equal? (caddr f) spec-id)))
                                 facts)))
          (<fd 0 source-qty)
          ;; Not contained (free resource) and at a different location
          (== contained-in #f)
          (project (source-loc)
            (if (equal? source-loc at-location) fail
                (fresh (remaining2 allocated sums-mid)
                  (allocate-o facts spec-id remaining remaining2 allocated
                              sums-in sums-mid
                              #:indexes indexes #:at-location source-loc)
                  (== remaining2 0)
                  (== plan-term `(transport ,spec-id ,allocated
                                            ,source-loc ,at-location))
                  (== sums-out sums-mid))))))))


;;; ── back-schedule-inputs ──────────────────────────────────────────────────────
;;; Collects consuming inputs with back-scheduled times. Ground fold.

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
                                proc-begin
                                (list-ref f 7)))  ;; resolve-from (flow-id or #f)
                        input-flows)))
            (loop (cdr procs) proc-begin (append acc new-inputs)))))))


;;; ── use-schedule-inputs ───────────────────────────────────────────────────────
;;; Collects 'use' flows with time windows. Terminal — no recursion.

(define (use-schedule-inputs facts pids scale due)
  "Collect 'use' input flows with time windows. Ground fold."
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
                 (proc-end cursor)
                 (proc-begin (- cursor dur-s))
                 (use-flows
                   (filter (lambda (f)
                             (and (eq? (car f) 'flow)
                                  (equal? (cadr f) pid)
                                  (eq? (caddr f) 'input)
                                  (eq? (list-ref f 6) 'use)
                                  (not (member (cadddr f) internal-specs))
                                  (list-ref f 4)))
                           facts))
                 (new-uses
                   (map (lambda (f)
                          (list (cadddr f)
                                (inexact->exact (ceiling (* (list-ref f 4) scale)))
                                proc-begin proc-end))
                        use-flows)))
            (loop (cdr procs) proc-begin (append acc new-uses)))))))


;;; ── cite-schedule-inputs ──────────────────────────────────────────────────────
;;; Collects 'cite' flows. Terminal — existence gate only.

(define (cite-schedule-inputs facts pids)
  "Collect 'cite' input spec-ids. No scheduling — just existence check."
  (filter-map (lambda (f)
                (and (eq? (car f) 'flow)
                     (member (cadr f) pids)
                     (eq? (caddr f) 'input)
                     (eq? (list-ref f 6) 'cite)
                     (cadddr f)))
              facts))


;;; ── solve-inputs-o ────────────────────────────────────────────────────────────
;;; Consuming inputs carry (spec qty needed-by resolve-from). When resolve-from
;;; is set, look up the anchor's resource-id from use-plans and pass as
;;; container-id to demand-o (only allocate from resources inside that container).

(define (resolve-container-from-use-plans resolve-from use-plans)
  "Look up the resource-id allocated by the anchor use-window for RESOLVE-FROM."
  (if (not resolve-from) #f
      (let ((uw (find (lambda (up)
                        ;; use-plan = (use-window spec qty allocated begin end)
                        ;; Match by checking if the anchor flow-id matches resolve-from
                        ;; For now: match by spec (resolve-from is a flow-id, but
                        ;; we don't have flow-ids in use-plans — match by the resource
                        ;; that was allocated)
                        #f)  ;; TODO: full flow-id resolution requires flow-ids in facts
                      use-plans)))
        ;; Fallback: use the first use-plan's allocated resource-id
        ;; (correct when there's only one use anchor in the recipe)
        (if (and (pair? use-plans) (pair? (car use-plans)))
            (let ((first-uw (car use-plans)))
              ;; use-window = (use-window spec qty ((rid take) ...) begin end)
              (let ((alloc (list-ref first-uw 3)))
                (if (pair? alloc) (caar alloc) #f)))
            #f))))

(define (solve-inputs-o ctx inputs sub-plans sums-in sums-out
                        depth visited at-location use-plans)
  (if (null? inputs)
      (fresh () (== sub-plans '()) (== sums-out sums-in))
      (let* ((input (car inputs))
             (in-spec (car input))
             (in-qty (cadr input))
             (needed-by (caddr input))
             (resolve-from (if (> (length input) 3) (list-ref input 3) #f))
             (container (resolve-container-from-use-plans resolve-from use-plans)))
        (fresh (sub-plan rest-plans sums-mid)
          (demand-o ctx in-spec in-qty needed-by sub-plan sums-in sums-mid
                    #:depth depth #:visited visited #:at-location at-location
                    #:container-id container)
          (solve-inputs-o ctx (cdr inputs) rest-plans sums-mid sums-out
                          depth visited at-location use-plans)
          (== sub-plans (cons (list in-spec sub-plan) rest-plans))))))


;;; ── solve-use-inputs-o ───────────────────────────────────────────────────────
;;; Allocates 'use' resources from inventory (non-recursive, time-windowed).

(define (solve-use-inputs-o ctx use-inputs use-plans sums-in sums-out)
  (if (null? use-inputs)
      (fresh () (== use-plans '()) (== sums-out sums-in))
      (let* ((u (car use-inputs))
             (spec (car u)) (qty (cadr u))
             (begin-t (caddr u)) (end-t (cadddr u)))
        (fresh (remaining allocated rest-plans sums-mid)
          (allocate-o (ctx-facts ctx) spec qty remaining allocated
                      sums-in sums-mid #:indexes (ctx-indexes ctx))
          ;; Must fully satisfy — can't "produce" a tool/oven/server
          (== remaining 0)
          (solve-use-inputs-o ctx (cdr use-inputs) rest-plans sums-mid sums-out)
          (== use-plans (cons `(use-window ,spec ,qty ,allocated ,begin-t ,end-t)
                              rest-plans))))))


;;; ── solve-cite-inputs-o ──────────────────────────────────────────────────────
;;; Checks existence of cited resources. No allocation — just a gate.

(define (solve-cite-inputs-o facts cited-specs cite-plans)
  (if (null? cited-specs)
      (== cite-plans '())
      (let ((spec (car cited-specs)))
        (fresh (rid qty loc rest-plans)
          (inventory-o facts rid spec qty loc)
          (<fd 0 qty)
          (solve-cite-inputs-o facts (cdr cited-specs) rest-plans)
          (== cite-plans (cons `(cited ,spec ,rid) rest-plans))))))
