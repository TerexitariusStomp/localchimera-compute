;;; demand-relation.scm — Core demand relation, fully relational
;;;
;;; Allocation via global sum constraints in CLP(FD). No sums threading.
;;; Each allocation declares a claim; the constraint solver ensures feasibility.
;;; Three input solvers: consume (recursive), use (time-windowed), cite (gate).

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))

(define *default-depth* 10)
;; Actions excluded from recursive demand explosion in back-schedule-inputs.
;; Each is handled by a specialized solver instead:
;;
;; Time-windowed (solve-use-inputs-o) — resource occupied during process:
;;   use     — tool/equipment, unavailable during process
;;   accept  — enters repair/modification, paired with modify output
;;   pickup  — enters transport, paired with dropoff output
;;   work    — labor with resource-quantity (e.g., "2 welders"), occupies agents
;;
;; Existence gate (solve-cite-inputs-o) — resource must exist:
;;   cite            — referenced for credit, remains available
;;   deliver-service — service availability (not inventoried)
(define *non-consuming* '(use accept pickup work cite deliver-service))


;;; ── demand-o ──────────────────────────────────────────────────────────────────

(define* (demand-o ctx spec-id qty due plan-term
                   #:key (depth *default-depth*) (visited '())
                         (at-location #f) (container-id #f))
  "Relate a demand to a plan-term. Fully relational — no sums threading."
  (if (or (= depth 0) (member spec-id visited))
      fail
      (fresh (remaining allocated)
        (allocate-o (ctx-facts ctx) spec-id qty remaining allocated
                    #:indexes (ctx-indexes ctx) #:at-location at-location
                    #:container-id container-id)
        (after-allocation ctx spec-id qty due remaining allocated
                          plan-term depth (cons spec-id visited) at-location))))


;;; ── after-allocation ──────────────────────────────────────────────────────────

(define (after-allocation ctx spec-id qty due remaining allocated
                          plan-term depth visited at-location)
  "Branch: satisfied (remaining=0) or need more (remaining>0)."
  (conde
    ((== remaining 0)
     (== plan-term `(satisfied ,spec-id ,qty ,allocated ,at-location)))
    ((<fd 0 remaining)
     (conde
       ((produce-branch ctx spec-id remaining due plan-term
                         depth visited at-location))
       ((transport-branch ctx spec-id remaining due plan-term at-location))
       ((== plan-term `(unmet ,spec-id ,remaining ,at-location)))))))


;;; ── produce-branch ────────────────────────────────────────────────────────────

(define (produce-branch ctx spec-id remaining due plan-term
                        depth visited at-location)
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
                ;; Solve use-inputs FIRST — anchor resource-ids for container resolution
                (fresh (consume-plans use-plans cite-plans)
                  (solve-use-inputs-o ctx using use-plans)
                  (project (use-plans)
                    (fresh ()
                      (solve-inputs-o ctx consuming consume-plans
                                      (- depth 1) visited at-location use-plans)
                      (solve-cite-inputs-o (ctx-facts ctx) citing cite-plans)
                      (== plan-term `(produce ,spec-id ,rid ,scale
                                              ,consume-plans ,use-plans
                                              ,cite-plans)))))))))))))


;;; ── transport-branch ─────────────────────────────────────────────────────────

(define (transport-recipe-o facts spec-id transport-rid)
  "Relate SPEC-ID to a transport recipe (one with pickup + dropoff flows)."
  (fresh (rname pickup-pid dropoff-pid pids resolve1 resolve2 fid1 fid2
          qty1 unit1 qty2 unit2)
    (in-list-o `(flow ,pickup-pid input ,spec-id ,qty1 ,unit1 pickup ,resolve1 ,fid1) facts)
    (in-list-o `(flow ,dropoff-pid output ,spec-id ,qty2 ,unit2 dropoff ,resolve2 ,fid2) facts)
    (recipe-o facts transport-rid rname spec-id)
    (chain-o facts transport-rid pids)
    (project (pids pickup-pid dropoff-pid)
      (if (and (member pickup-pid pids) (member dropoff-pid pids))
          succeed
          fail))))

(define (transport-branch ctx spec-id remaining due plan-term at-location)
  "Allocate from a different location via =/= disequality."
  (if (not at-location) fail
      (let ((facts (ctx-facts ctx))
            (indexes (ctx-indexes ctx)))
        (fresh (rid source-loc source-qty contained-in
                remaining2 allocated transport-rid)
          (in-list-o `(inventory ,rid ,spec-id ,source-qty ,source-loc ,contained-in)
                     (if indexes
                         (idx-ref indexes 'inventory-by-spec spec-id)
                         (filter (lambda (f) (and (eq? (car f) 'inventory)
                                                   (equal? (caddr f) spec-id)))
                                 facts)))
          (<fd 0 source-qty)
          (== contained-in #f)
          (=/= source-loc at-location)
          ;; Allocate from source location
          (allocate-o facts spec-id remaining remaining2 allocated
                      #:indexes indexes #:at-location source-loc)
          (== remaining2 0)
          (conde
            ((transport-recipe-o facts spec-id transport-rid)
             (== plan-term `(transport ,spec-id ,allocated
                                       ,source-loc ,at-location ,transport-rid)))
            ((== plan-term `(transport ,spec-id ,allocated
                                       ,source-loc ,at-location #f))))))))


;;; ── back-schedule-inputs ──────────────────────────────────────────────────────

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
                                (list-ref f 7)))
                        input-flows)))
            (loop (cdr procs) proc-begin (append acc new-inputs)))))))


;;; ── use-schedule-inputs ───────────────────────────────────────────────────────

(define (use-schedule-inputs facts pids scale due)
  "Collect use/accept/pickup/work input flows with time windows."
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
                                  (memq (list-ref f 6) '(use accept pickup work))
                                  (not (member (cadddr f) internal-specs))
                                  (list-ref f 4)))
                           facts))
                 (new-uses
                   (map (lambda (f)
                          (list (cadddr f)
                                (inexact->exact (ceiling (* (list-ref f 4) scale)))
                                proc-begin proc-end
                                (list-ref f 8)))
                        use-flows)))
            (loop (cdr procs) proc-begin (append acc new-uses)))))))


;;; ── cite-schedule-inputs ──────────────────────────────────────────────────────

(define (cite-schedule-inputs facts pids)
  "Collect cite and deliver-service input spec-ids. Existence check only."
  (filter-map (lambda (f)
                (and (eq? (car f) 'flow)
                     (member (cadr f) pids)
                     (eq? (caddr f) 'input)
                     (memq (list-ref f 6) '(cite deliver-service))
                     (cadddr f)))
              facts))


;;; ── solve-inputs-o ────────────────────────────────────────────────────────────

(define (resolve-container-from-use-plans resolve-from use-plans)
  "Look up ALL resource-ids allocated by the anchor use-window for RESOLVE-FROM."
  (if (not resolve-from) #f
      (let ((uw (find (lambda (up)
                        (and (pair? up) (>= (length up) 7)
                             (equal? (list-ref up 6) resolve-from)))
                      use-plans)))
        (if uw
            (let ((alloc (list-ref uw 3)))
              (if (pair? alloc) (map car alloc) #f))
            #f))))

(define (solve-inputs-o ctx inputs sub-plans
                        depth visited at-location use-plans)
  "Solve consuming inputs. No sums threading — claims are global constraints."
  (if (null? inputs)
      (== sub-plans '())
      (let* ((input (car inputs))
             (in-spec (car input))
             (in-qty (cadr input))
             (needed-by (caddr input))
             (resolve-from (if (> (length input) 3) (list-ref input 3) #f))
             (container-ids (resolve-container-from-use-plans resolve-from use-plans))
             (container-id (if (and container-ids (pair? container-ids))
                               (car container-ids) #f)))
        (fresh (sub-plan rest-plans)
          (demand-o ctx in-spec in-qty needed-by sub-plan
                    #:depth depth #:visited visited #:at-location at-location
                    #:container-id container-id)
          (solve-inputs-o ctx (cdr inputs) rest-plans
                          depth visited at-location use-plans)
          (== sub-plans (cons (list in-spec sub-plan) rest-plans))))))


;;; ── solve-use-inputs-o ───────────────────────────────────────────────────────

(define (solve-use-inputs-o ctx use-inputs use-plans)
  "Allocate use-resources. No sums threading — claims are global constraints."
  (if (null? use-inputs)
      (== use-plans '())
      (let* ((u (car use-inputs))
             (spec (car u)) (qty (cadr u))
             (begin-t (caddr u)) (end-t (cadddr u))
             (flow-id (if (> (length u) 4) (list-ref u 4) #f)))
        (fresh (remaining allocated rest-plans)
          (allocate-o (ctx-facts ctx) spec qty remaining allocated
                      #:indexes (ctx-indexes ctx))
          (== remaining 0)
          (solve-use-inputs-o ctx (cdr use-inputs) rest-plans)
          (== use-plans (cons `(use-window ,spec ,qty ,allocated
                                           ,begin-t ,end-t ,flow-id)
                              rest-plans))))))


;;; ── solve-cite-inputs-o ──────────────────────────────────────────────────────

(define (solve-cite-inputs-o facts cited-specs cite-plans)
  (if (null? cited-specs)
      (== cite-plans '())
      (let ((spec (car cited-specs)))
        (fresh (rid qty loc rest-plans)
          (inventory-o facts rid spec qty loc)
          (<fd 0 qty)
          (solve-cite-inputs-o facts (cdr cited-specs) rest-plans)
          (== cite-plans (cons `(cited ,spec ,rid) rest-plans))))))
