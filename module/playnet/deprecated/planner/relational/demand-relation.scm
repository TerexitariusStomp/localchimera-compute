;;; demand-relation.scm — Core demand relation, fully relational
;;;
;;; Allocation via global sum constraints in CLP(FD). No sums threading.
;;; Each allocation declares a claim; the constraint solver ensures feasibility.
;;; Uses map-goal-o from (playnet deprecated kanren-constraints) for all list solvers.
;;; schedule-inputs-fold unifies the two ground scheduling folds.

(define-module (playnet deprecated planner relational demand-relation)
  #:use-module (playnet deprecated planner relational compute)
  #:use-module (playnet deprecated planner relational allocation)
  #:use-module (playnet deprecated planner relational planning-facts)
  ;; *non-consuming* comes from compute now — a module that both imports a name
  ;; and #:exports it publishes a second, unbound slot for it.
  #:export (*default-depth* demand-o after-allocation produce-branch
            transport-recipe-o transport-branch schedule-inputs-fold
            back-schedule-inputs use-schedule-inputs cite-schedule-inputs
            resolve-container-from-use-plans solve-inputs-o solve-use-inputs-o
            solve-cite-inputs-o))

(use-modules (playnet deprecated kanren-constraints)
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


;;; ── demand-o ──────────────────────────────────────────────────────────────────

(define* (demand-o ctx spec-id qty due plan-term
                   #:key (depth *default-depth*) (visited '())
                         (at-location #f) (container-id #f)
                         (allocator allocate-o)
                         (buffered-specs '())
                         (replenishment? #f))
  "Relate a demand to a plan-term. Fully relational — no sums threading.

   Optional parameters for buffer-aware planning (DDMRP):
     allocator      — alternative allocate-o-shaped function (e.g.
                      ddmrp-allocate-o for 3-tier TOY/TOR/0). Default
                      is plain allocate-o.
     buffered-specs — list of spec-ids that are at decoupling points.
                      When the search hits a recipe input that's in
                      this set, it won't recurse via produce-branch
                      (the spec is sourced from inventory, not made).
     replenishment? — true if this demand is itself a replenishment
                      for a buffer. Allows produce-branch to fire
                      even for buffered specs (so the buffer can be
                      refilled). Default #f."
  (if (or (= depth 0) (member spec-id visited))
      fail
      (fresh (remaining allocated)
        (allocator (ctx-facts ctx) spec-id qty remaining allocated
                   #:indexes (ctx-indexes ctx) #:at-location at-location
                   #:container-id container-id)
        (after-allocation ctx spec-id qty due remaining allocated
                          plan-term depth (cons spec-id visited) at-location
                          allocator buffered-specs replenishment?))))


;;; ── after-allocation ──────────────────────────────────────────────────────────

(define (after-allocation ctx spec-id qty due remaining allocated
                          plan-term depth visited at-location
                          allocator buffered-specs replenishment?)
  "Branch: satisfied (remaining=0) or need more (remaining>0).
   Decoupling gate: when SPEC-ID is in BUFFERED-SPECS and we are NOT
   in a replenishment context, skip produce/transport branches —
   buffered specs are sourced from inventory, not made or moved.
   This is what makes a 'decoupling point' a decoupling point."
  (conde
    ((== remaining 0)
     (== plan-term `(satisfied ,spec-id ,qty ,allocated ,at-location)))
    ((<fd 0 remaining)
     (if (and (member spec-id buffered-specs) (not replenishment?))
         ;; Decoupled — only mark unmet, don't try to produce/transport
         (== plan-term `(unmet ,spec-id ,remaining ,at-location))
         (conde
           ((produce-branch ctx spec-id remaining due plan-term
                             depth visited at-location
                             allocator buffered-specs replenishment?))
           ((transport-branch ctx spec-id remaining due plan-term at-location
                               allocator))
           ((== plan-term `(unmet ,spec-id ,remaining ,at-location))))))))


;;; ── produce-branch ────────────────────────────────────────────────────────────

(define (produce-branch ctx spec-id remaining due plan-term
                        depth visited at-location
                        allocator buffered-specs replenishment?)
  "Find a recipe, compute scale via *fd (respecting MBQ), collect inputs.
   ALLOCATOR / BUFFERED-SPECS / REPLENISHMENT? are threaded into the
   recursive solve-inputs-o calls so the buffer-aware semantics
   propagate through the BOM. NOTE: recursive sub-input demands always
   set replenishment?=#f — even if the parent recipe is itself a
   replenishment, its sub-inputs are not themselves replenishments.
   This preserves correct decoupling at every BOM level."
  (let ((facts (ctx-facts ctx)))
    (fresh (rid rname pids last-pid out-qty out-unit out-action
            scale total-produced)
      ;; Find recipe, chain, output flow — unified dispatch
      (fact-recipe-o ctx rid rname spec-id)
      (fact-chain-o ctx rid pids)
      (lasto pids last-pid)
      (fact-flow-o ctx last-pid 'output spec-id out-qty out-unit out-action)
      ;; Scale via CLP(FD) — lower bound from MBQ of last process,
      ;; upper bound derived from the demand itself: at most enough
      ;; runs to satisfy `remaining` (no gratuitous over-production).
      ;; out-qty is ground after fact-flow-o; remaining is ground
      ;; after the outer allocator labeled it. Both must be projected
      ;; here so the bound can be computed in Scheme. Falls back to
      ;; the legacy hardcoded ceiling of 100 if either projection
      ;; lands on a non-integer (defensive — shouldn't happen).
      (project (pids last-pid out-qty remaining)
        (let* ((proc-fact (find (lambda (f) (and (eq? (car f) 'process)
                                                  (equal? (cadr f) last-pid)))
                                facts))
               (mbq (if (and proc-fact (> (length proc-fact) 4))
                        (list-ref proc-fact 4) 1))
               (max-scale
                 (if (and (integer? remaining) (integer? out-qty)
                          (> out-qty 0))
                     ;; ceiling(remaining / out-qty) — exactly enough
                     ;; to satisfy the demand, no more.
                     (max mbq (quotient (+ remaining out-qty -1) out-qty))
                     ;; Fallback for non-ground or zero out-qty
                     100)))
          (fresh ()
            (rangeo scale mbq max-scale)
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
                                      (- depth 1) visited at-location use-plans
                                      allocator buffered-specs)
                      (solve-cite-inputs-o facts citing cite-plans)
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

(define (transport-branch ctx spec-id remaining due plan-term at-location
                          allocator)
  "Allocate from a different location via =/= disequality.
   Uses ALLOCATOR (defaults to allocate-o via demand-o's caller) so
   buffer-aware allocation tiers apply to the source-location pull.

   Note: source-loc must be projected to a ground value before being
   passed to the allocator. allocate-o filters resources via Scheme
   equal? on the at-location keyword, which doesn't walk substitutions
   — passing an unwalked logic var here makes the filter fail to match
   any inventory. The (project (source-loc) ...) wrapper is what made
   this branch reachable in the first place; without it, transport
   silently dropped every cross-location demand."
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
          ;; Allocate from source location — must project both source-loc
          ;; and remaining to ground values first. allocate-o filters
          ;; resources via Scheme equal? on at-location and uses qty
          ;; in a Scheme (min ...) call inside allocate-from-o, neither
          ;; of which walks the substitution. Without project, the
          ;; unwalked vars cause the filter to miss every resource and
          ;; (min ...) to throw a wrong-type error.
          (project (source-loc remaining)
            (allocator facts spec-id remaining remaining2 allocated
                       #:indexes indexes #:at-location source-loc))
          (== remaining2 0)
          (conde
            ((transport-recipe-o facts spec-id transport-rid)
             (== plan-term `(transport ,spec-id ,allocated
                                       ,source-loc ,at-location ,transport-rid)))
            ((== plan-term `(transport ,spec-id ,allocated
                                       ,source-loc ,at-location #f))))))))


;;; ── schedule-inputs-fold (unified ground fold) ──────────────────────────────
;;; back-schedule-inputs and use-schedule-inputs share 80% structure:
;;; iterate pids in reverse, compute time cursor, filter flows, map results.
;;; Extracted into a single fold parameterized by flow predicate and mapper.

(define (schedule-inputs-fold facts pids scale due flow-pred flow-mapper)
  "Generic ground fold over a process chain for input scheduling.
   flow-pred: (flow-fact internal-specs) -> #t if this flow should be collected
   flow-mapper: (flow-fact scale proc-begin proc-end) -> output item"
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
                 (matching-flows
                   (filter (lambda (f)
                             (and (eq? (car f) 'flow)
                                  (equal? (cadr f) pid)
                                  (eq? (caddr f) 'input)
                                  (flow-pred f internal-specs)
                                  (list-ref f 4)))
                           facts))
                 (new-items
                   (map (lambda (f) (flow-mapper f scale proc-begin proc-end))
                        matching-flows)))
            (loop (cdr procs) proc-begin (append acc new-items)))))))

(define (back-schedule-inputs facts pids scale due)
  "Collect consuming input demands. Ground fold — no search."
  (schedule-inputs-fold facts pids scale due
    ;; flow-pred: consuming inputs not in internal-specs
    (lambda (f internal-specs)
      (and (not (memq (list-ref f 6) *non-consuming*))
           (not (member (cadddr f) internal-specs))))
    ;; flow-mapper: (spec qty needed-by resolve-from)
    (lambda (f scale proc-begin proc-end)
      (list (cadddr f)
            (inexact->exact (ceiling (* (list-ref f 4) scale)))
            proc-begin
            (list-ref f 7)))))

(define (use-schedule-inputs facts pids scale due)
  "Collect use/accept/pickup/work input flows with time windows."
  (schedule-inputs-fold facts pids scale due
    ;; flow-pred: use-type inputs not in internal-specs
    (lambda (f internal-specs)
      (and (memq (list-ref f 6) '(use accept pickup work))
           (not (member (cadddr f) internal-specs))))
    ;; flow-mapper: (spec qty begin end flow-id)
    (lambda (f scale proc-begin proc-end)
      (list (cadddr f)
            (inexact->exact (ceiling (* (list-ref f 4) scale)))
            proc-begin proc-end
            (list-ref f 8)))))


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


;;; ── Input solvers (via map-goal-o) ───────────────────────────────────────────

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

(define* (solve-inputs-o ctx inputs sub-plans
                         depth visited at-location use-plans
                         #:optional (allocator allocate-o) (buffered-specs '()))
  "Solve consuming inputs via map-goal-o.
   ALLOCATOR and BUFFERED-SPECS propagate buffer-aware planning into
   the recursive demand-o calls. Sub-input demands always run with
   replenishment?=#f — sub-inputs are not themselves replenishments."
  (map-goal-o inputs
    (lambda (input result)
      (let* ((in-spec (car input))
             (in-qty (cadr input))
             (needed-by (caddr input))
             (resolve-from (if (> (length input) 3) (list-ref input 3) #f))
             (container-ids (resolve-container-from-use-plans resolve-from use-plans))
             (container-id (if (and container-ids (pair? container-ids))
                               (car container-ids) #f)))
        (fresh (sub-plan)
          (demand-o ctx in-spec in-qty needed-by sub-plan
                    #:depth depth #:visited visited #:at-location at-location
                    #:container-id container-id
                    #:allocator allocator
                    #:buffered-specs buffered-specs
                    #:replenishment? #f)
          (== result (list in-spec sub-plan)))))
    sub-plans))

(define (solve-use-inputs-o ctx use-inputs use-plans)
  "Allocate use-resources via map-goal-o."
  (map-goal-o use-inputs
    (lambda (u result)
      (let* ((spec (car u)) (qty (cadr u))
             (begin-t (caddr u)) (end-t (cadddr u))
             (flow-id (if (> (length u) 4) (list-ref u 4) #f)))
        (fresh (remaining allocated)
          (allocate-o (ctx-facts ctx) spec qty remaining allocated
                      #:indexes (ctx-indexes ctx))
          (== remaining 0)
          (== result `(use-window ,spec ,qty ,allocated
                                  ,begin-t ,end-t ,flow-id)))))
    use-plans))

(define (solve-cite-inputs-o facts cited-specs cite-plans)
  "Check existence of cited resources via map-goal-o."
  (map-goal-o cited-specs
    (lambda (spec result)
      (fresh (rid qty loc)
        (inventory-o facts rid spec qty loc)
        (<fd 0 qty)
        (== result `(cited ,spec ,rid))))
    cite-plans))
