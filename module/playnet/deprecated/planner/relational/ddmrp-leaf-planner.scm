;;; ddmrp-leaf-planner.scm — Relational DDMRP as a federation leaf-planner
;;;
;;; This module is a leaf-planner extension for federation.scm. It does
;;; DDMRP-style planning (buffer-aware allocation, decoupling-point
;;; honoring, derived replenishment, supply routing) entirely
;;; relationally — no multi-pass orchestrator, no imperative state
;;; threading, no Pass 1b retry.
;;;
;;; KEY INSIGHT — why no multi-pass:
;;;
;;; Imperative DDMRP (plan-for-unit.scm) needs Pass 0/1/2/1b/Supply
;;; because it can't backtrack. Each pass is "greedy commitment, then
;;; fix up". In the relational paradigm:
;;;
;;;   - The TOY guard isn't a phase gate. It's a different conservation
;;;     floor on the existing CLP(FD) claim registry. allocate-o
;;;     accepts a #:floors keyword giving the list of conservation
;;;     floors to try; DDMRP passes (TOY TOR 0).
;;;
;;;   - Pass 1b (retry deferred) disappears. miniKanren backtracks for
;;;     free.
;;;
;;;   - Pass 1 + Pass 2 collapse into one constraint problem. Primary
;;;     demand and derived replenishment are sub-goals in the same
;;;     fresh scope.
;;;
;;;   - Decoupling = a "gate" inside demand-o's after-allocation: when
;;;     spec is buffered AND we're not in a replenishment context,
;;;     skip produce/transport branches. The spec is sourced from
;;;     inventory or marked unmet.
;;;
;;; ARCHITECTURE:
;;;
;;;   ddmrp-leaf-planner (federation protocol entry)
;;;     │
;;;     ▼
;;;   ddmrp-plan-o (single master relation)
;;;     │
;;;     ├── ddmrp-demand-o (thin wrapper passing #:allocator and
;;;     │   │              #:buffered-specs to demand-o)
;;;     │   │
;;;     │   └── demand-o (demand-relation.scm — no longer duplicated)
;;;     │       │
;;;     │       └── ddmrp-allocate-o (thin wrapper passing #:floors)
;;;     │           │
;;;     │           └── allocate-o (allocation.scm — parameterized)
;;;     │
;;;     ├── replenishment-o (derived demand for consumed buffered
;;;     │   │              specs; passes #:replenishment? #t to open
;;;     │   │              the gate so the buffer can be refilled)
;;;     │   │
;;;     │   └── ddmrp-demand-o (recursive)
;;;     │
;;;     └── supply-routing-o (forward supply absorption)
;;;
;;; All sub-goals run in the SAME fresh scope inside ddmrp-plan-o.
;;;
;;; THIS MODULE OWNS NO DUPLICATION. All buffer-aware logic lives as
;;; parameter additions in allocation.scm and demand-relation.scm.
;;; The wrappers below just pass the right parameters.
;;;
;;; FUTURE WORK (deferred to v2):
;;;
;;;   1. Cascade replenishment: if replenishing flour requires
;;;      consuming yeast (also buffered) and yeast's buffer drops
;;;      below TOY because of this, the second-order replenishment
;;;      isn't triggered. v1 is one-pass replenishment; cascade would
;;;      need replenishment-o to fixed-point or call itself.
;;;
;;;   2. Supply forward BFS: supply-routing-o currently only emits
;;;      surplus terms for inventory above TOG. The full DDMRP supply
;;;      phase does forward BFS through recipes (analog of
;;;      dependent-supply.scm), absorbing supply through production
;;;      paths and routing surplus to under-stocked buffers.
;;;
;;;   3. Bread-unmet pre-existing limitation: plain demand-o returns
;;;      `unmet` for some multi-process recipe fixtures (verified by
;;;      direct comparison). This is a relational planner issue
;;;      affecting both planners — not specific to DDMRP. Likely
;;;      related to back-schedule-inputs internal-spec filtering or
;;;      the *fd scale constraint construction. Needs separate
;;;      investigation.
;;;
;;;   4. Container-aware buffered allocation: when a container ID is
;;;      provided, allocation filters resources by container before
;;;      applying floors. Behavior is consistent with allocate-o but
;;;      not exercised in DDMRP tests yet.

(define-module (playnet deprecated planner relational ddmrp-leaf-planner)
  #:use-module (goblins)
  #:use-module (playnet deprecated planner relational plan-walk)
  #:use-module (playnet deprecated planner relational plan-relation)
  #:use-module (playnet deprecated planner relational allocation)
  #:use-module (playnet deprecated planner relational federation)
  #:use-module (playnet deprecated planner relational demand-relation)
  #:use-module (playnet vf schemas)
  #:use-module (playnet utils store-utils)
  #:use-module (playnet deprecated planner relational harmony)
  #:export (buffered-spec-set buffer-zone-fact toy-floor tor-floor decoupling-stop?
            ddmrp-allocate-o ddmrp-demand-o collect-consumed-from-plans
            earliest-due-from-demands *cascade-depth* replenishment-o
            replenishment-cascade-o sum-onhand-from-facts *supply-bfs-depth*
            supply-routing-o absorb-excess find-consuming-recipe
            recipe-consumes-amount process-input-qty recipe-outputs-with-amounts
            ddmrp-plan-o ddmrp-leaf-planner extract-demands-from-ctx
            build-ddmrp-federation-result))

(use-modules (playnet deprecated kanren-constraints)
             (srfi srfi-1))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Buffer helpers (ground)
;;; ══════════════════════════════════════════════════════════════════════════════

(define (buffered-spec-set facts)
  "All spec-ids that have a (buffer-zone ...) fact in FACTS.
   Used as the decoupling-points set."
  (filter-map (lambda (f)
                (and (eq? (car f) 'buffer-zone) (cadr f)))
              facts))

(define (buffer-zone-fact facts spec-id)
  "Lookup the (buffer-zone spec-id tor toy tog adu dlt) fact, or #f."
  (find (lambda (f)
          (and (eq? (car f) 'buffer-zone)
               (equal? (cadr f) spec-id)))
        facts))

(define (toy-floor facts spec-id)
  "TOY level for SPEC-ID, or 0 if unbuffered."
  (let ((bz (buffer-zone-fact facts spec-id)))
    (if bz (cadddr bz) 0)))

(define (tor-floor facts spec-id)
  "TOR level for SPEC-ID, or 0 if unbuffered."
  (let ((bz (buffer-zone-fact facts spec-id)))
    (if bz (caddr bz) 0)))

(define (decoupling-stop? buffered-specs spec-id)
  "True if SPEC-ID is at a decoupling point (buffered)."
  (and (member spec-id buffered-specs) #t))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; ddmrp-allocate-o — thin wrapper around allocate-o with 3-tier floors
;;; ══════════════════════════════════════════════════════════════════════════════

(define* (ddmrp-allocate-o facts spec-id qty remaining allocated
                            #:key (indexes #f) (at-location #f) (container-id #f))
  "DDMRP 3-tier allocation. Wraps allocate-o with #:floors for the
   TOY → TOR → 0 conde branches. Unbuffered specs degrade to a 1-tier
   sacrifice (since TOY=TOR=0)."
  (allocate-o facts spec-id qty remaining allocated
              #:indexes indexes
              #:at-location at-location
              #:container-id container-id
              #:floors (list (toy-floor facts spec-id)
                             (tor-floor facts spec-id)
                             0)))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; ddmrp-demand-o — thin wrapper around demand-o with buffer-awareness
;;; ══════════════════════════════════════════════════════════════════════════════

(define* (ddmrp-demand-o ctx buffered-specs spec-id qty due plan-term
                          #:key (depth 10) (visited '())
                                (at-location #f) (container-id #f)
                                (replenishment? #f))
  "DDMRP demand. Wraps demand-o with the DDMRP allocator and the
   decoupling-points set. Set REPLENISHMENT? to #t when the demand
   itself is a buffer replenishment (so produce-branch fires even
   for buffered specs)."
  (demand-o ctx spec-id qty due plan-term
            #:depth depth #:visited visited
            #:at-location at-location #:container-id container-id
            #:allocator ddmrp-allocate-o
            #:buffered-specs buffered-specs
            #:replenishment? replenishment?))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Consumed-spec extraction (ground helper)
;;; ══════════════════════════════════════════════════════════════════════════════

(define (collect-consumed-from-plans plans)
  "Walk PLANS (a list of (demand plan-term) pairs) and return a list
   of (spec-id . total-qty) pairs for everything consumed via
   'satisfied' terms."
  (let ((tally (make-hash-table)))
    (fold-plan-terms
      (lambda (term _acc)
        (when (satisfied-term? term)
          (let ((alloc (plan-term-alloc term))
                (spec (plan-term-spec term)))
            (when (and spec (list? alloc))
              (let ((cur (hash-ref tally spec 0))
                    (taken (fold (lambda (a a-acc) (+ a-acc (cadr a))) 0 alloc)))
                (hash-set! tally spec (+ cur taken))))))
        #f)
      #f plans)
    (hash-map->list cons tally)))

(define (earliest-due-from-demands demands)
  "Find the earliest due time across DEMANDS, or (current-time) as fallback."
  (let ((dues (filter-map
                (lambda (d)
                  (let ((v (assq-ref d 'due)))
                    (cond ((not v) #f)
                          ((number? v) v)
                          ((string? v) (iso-datetime->epoch v))
                          (else #f))))
                demands)))
    (if (null? dues) (current-time) (apply min dues))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; replenishment-o — cascade-aware replenishment
;;; ══════════════════════════════════════════════════════════════════════════════
;;;
;;; The buffer-invariant insight: rather than running ONE pass of
;;; replenishment and hoping it doesn't cause more buffered consumption,
;;; we recursively replenish until all buffered specs are above TOY (or
;;; we hit the cascade depth bound).
;;;
;;; Each cascade round:
;;;   1. Computes consumed specs from the most recent round of plans
;;;   2. Filters to buffered specs whose post-consumption inventory
;;;      drops below TOY
;;;   3. Excludes specs we've ALREADY replenished in this cascade
;;;      (the visited-set prevents infinite loops between mutually-
;;;      consuming buffered specs)
;;;   4. Generates and solves replenishment demands for the new needs
;;;   5. Recurses on the new round's plans to catch second-order
;;;      consumption
;;;
;;; Bounded by *cascade-depth* to prevent runaway recursion.

(define *cascade-depth* 5)

(define (replenishment-o ctx buffered-specs primary-plans demands replenish-plans)
  "Cascade-aware replenishment. Recursively generates replenishment
   rounds until no buffered spec needs replenishing (or the cascade
   depth bound hits). The recursion is the relational analog of an
   imperative fixed-point loop — but expressed as a single relation
   that miniKanren unifies in one search."
  (replenishment-cascade-o ctx buffered-specs primary-plans
                            '() demands replenish-plans *cascade-depth*))

(define (replenishment-cascade-o ctx buffered-specs round-plans
                                  already-replenished demands
                                  out-derived depth-left)
  "One cascade round. Looks at ROUND-PLANS to find newly-consumed
   buffered specs that aren't yet in ALREADY-REPLENISHED. Generates a
   round of replenishment, then recurses on those plans to catch any
   second-order needs. OUT-DERIVED is bound to the accumulated
   replenishment plans across all rounds."
  (project (ctx round-plans already-replenished)
    (let* ((facts (ctx-facts ctx))
           (consumed (collect-consumed-from-plans round-plans))
           (replen-due (earliest-due-from-demands demands))
           (new-needs
             (filter-map
               (lambda (entry)
                 (let* ((spec (car entry))
                        (consumed-qty (cdr entry)))
                   (and (member spec buffered-specs)
                        ;; Skip specs already replenished in earlier rounds
                        ;; (visited-set prevents infinite loops)
                        (not (member spec already-replenished))
                        (let* ((onhand (sum-onhand-from-facts facts spec))
                               (post (- onhand consumed-qty))
                               (toy (toy-floor facts spec))
                               (gap (- toy post)))
                          (and (> gap 0) (cons spec gap))))))
               consumed)))
      (cond
        ;; Base case: nothing more to replenish, or we've hit the depth bound
        ((or (null? new-needs) (<= depth-left 0))
         (== out-derived '()))
        ;; Recursive case: solve this round, then check the round's
        ;; plans for second-order needs
        (else
         (fresh (this-round cascade-rest)
           (let ((replen-demands
                   (map (lambda (entry)
                          `((spec-id . ,(car entry))
                            (quantity . ,(inexact->exact (ceiling (cdr entry))))
                            (due . ,replen-due)
                            (at-location . #f)))
                        new-needs)))
             (all-demands-o ctx replen-demands this-round
                            #:allocator ddmrp-allocate-o
                            #:buffered-specs buffered-specs
                            #:replenishment? #t))
           (replenishment-cascade-o ctx buffered-specs this-round
             (append already-replenished (map car new-needs))
             demands cascade-rest (- depth-left 1))
           (project (this-round cascade-rest)
             (== out-derived (append this-round cascade-rest)))))))))

(define (sum-onhand-from-facts facts spec-id)
  "Sum the onhand quantity for SPEC-ID across all inventory facts."
  (fold (lambda (f acc)
          (if (and (eq? (car f) 'inventory)
                   (equal? (caddr f) spec-id))
              (+ acc (cadddr f))
              acc))
        0 facts))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; supply-routing-o — forward supply absorption (v2: forward BFS)
;;; ══════════════════════════════════════════════════════════════════════════════
;;;
;;; The relational analog of dependent-supply.scm. For each unit of
;;; excess inventory (above buffered TOG), forward-schedule it through
;;; recipes that consume it. Recursively absorb the recipe's outputs as
;;; new supply tasks. Surplus that can't be absorbed becomes
;;; (surplus ...) plan-terms.
;;;
;;; The KEY INSIGHT (per docs/planner-known-gaps.md): the imperative
;;; version uses a queue and visited-set (~200 lines). The relational
;;; version uses recursive Scheme calls inside a project block — the
;;; recursion structure IS the BFS. No queue. No explicit visited set.
;;; Bounded by *supply-bfs-depth* to prevent runaway recursion.

(define *supply-bfs-depth* 3)

(define (supply-routing-o ctx buffered-specs supply-plans)
  "Forward supply absorption. For each excess inventory unit (above
   buffered TOG), absorb via consuming recipes recursively. Binds
   SUPPLY-PLANS with the resulting plan-term list."
  (project (ctx)
    (let* ((facts (ctx-facts ctx))
           (excess-units
             (filter-map
               (lambda (f)
                 (and (eq? (car f) 'inventory)
                      (let* ((spec (caddr f))
                             (qty (cadddr f))
                             (loc (list-ref f 4))
                             (bz (buffer-zone-fact facts spec))
                             (tog (and bz (list-ref bz 4))))
                        (and bz (> qty tog)
                             (cons spec (cons (- qty tog) loc))))))
               facts))
           (absorbed
             (map (lambda (excess)
                    (let ((spec (car excess))
                          (qty (cadr excess))
                          (loc (cddr excess)))
                      (absorb-excess facts spec qty loc *supply-bfs-depth*)))
                  excess-units)))
      (== supply-plans absorbed))))

(define (absorb-excess facts spec qty loc depth)
  "Try to absorb QTY of SPEC at LOC via a consuming recipe.
   Returns a plan-term:
     (forward spec consumed-qty rid execs sub-tasks)  if absorbed
     (surplus spec qty loc)                             if not
   Recurses on the recipe's outputs as new absorption tasks.
   Bounded by DEPTH to prevent infinite cycles."
  (cond
    ((<= depth 0)
     `(surplus ,spec ,qty ,loc))
    (else
     (let ((consumer (find-consuming-recipe facts spec)))
       (cond
         ((not consumer)
          `(surplus ,spec ,qty ,loc))
         (else
          (let* ((rid (car consumer))
                 (per-exec (cdr consumer)))
            (if (or (not per-exec) (<= per-exec 0))
                `(surplus ,spec ,qty ,loc)
                (let* ((execs (max 1
                                (inexact->exact
                                  (floor (/ qty per-exec)))))
                       (consumed (* execs per-exec))
                       (leftover (- qty consumed))
                       (outputs (recipe-outputs-with-amounts facts rid execs))
                       (sub-tasks
                         (map (lambda (out)
                                (absorb-excess facts (car out) (cdr out)
                                               loc (- depth 1)))
                              outputs))
                       (leftover-term
                         (if (> leftover 0)
                             (list `(surplus ,spec ,leftover ,loc))
                             '())))
                  `(forward ,spec ,consumed ,rid ,execs
                            ,(append leftover-term sub-tasks)))))))))))

(define (find-consuming-recipe facts spec)
  "Find the FIRST recipe whose chain includes a process with an input
   flow consuming SPEC. Returns (rid . per-exec-qty) or #f if none.
   Per-exec qty is summed across the chain (a recipe might consume the
   same spec at multiple processes — rare, but possible)."
  (let loop ((fs facts))
    (cond
      ((null? fs) #f)
      ((not (eq? (caar fs) 'recipe)) (loop (cdr fs)))
      (else
       (let* ((rid (cadar fs))
              (per-exec (recipe-consumes-amount facts rid spec)))
         (if (and per-exec (> per-exec 0))
             (cons rid per-exec)
             (loop (cdr fs))))))))

(define (recipe-consumes-amount facts rid spec)
  "Total amount of SPEC consumed per execution of recipe RID.
   Looks up the recipe's chain and sums consume-action input flows
   for SPEC across all processes in the chain."
  (let* ((chain-fact (find (lambda (f)
                             (and (eq? (car f) 'chain)
                                  (equal? (cadr f) rid)))
                           facts))
         (pids (if chain-fact (caddr chain-fact) '())))
    (if (null? pids)
        #f
        (let ((total
                (fold (lambda (pid acc)
                        (+ acc (process-input-qty facts pid spec)))
                      0 pids)))
          (if (> total 0) total #f)))))

(define (process-input-qty facts pid spec)
  "Sum the input qty of SPEC for process PID across all consume-style
   input flows. Excludes use/cite/work flows (those don't consume)."
  (fold (lambda (f acc)
          (if (and (eq? (car f) 'flow)
                   (equal? (cadr f) pid)
                   (eq? (caddr f) 'input)
                   (equal? (cadddr f) spec)
                   (memq (list-ref f 6) '(consume accept pickup))
                   (number? (list-ref f 4)))
              (+ acc (list-ref f 4))
              acc))
        0 facts))

(define (recipe-outputs-with-amounts facts rid execs)
  "Return ((output-spec . qty) ...) for the recipe RID at EXECS executions.
   Walks the chain and collects produce-action output flows."
  (let* ((chain-fact (find (lambda (f)
                             (and (eq? (car f) 'chain)
                                  (equal? (cadr f) rid)))
                           facts))
         (pids (if chain-fact (caddr chain-fact) '())))
    (filter-map
      (lambda (f)
        (and (eq? (car f) 'flow)
             (member (cadr f) pids)
             (eq? (caddr f) 'output)
             (eq? (list-ref f 6) 'produce)
             (number? (list-ref f 4))
             (cons (cadddr f) (* execs (list-ref f 4)))))
      facts)))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; ddmrp-plan-o — the master relation
;;; ══════════════════════════════════════════════════════════════════════════════

(define (ddmrp-plan-o ctx demands plan)
  "Master relation. Solves DEMANDS as primary; generates derived
   replenishment for consumed buffered specs; routes supply surplus.
   Binds PLAN to the combined plan structure. Single fresh scope —
   the search finds plans where all sub-goals are satisfied at once."
  (let ((buffered (buffered-spec-set (ctx-facts ctx))))
    (fresh (primary derived supply)
      (all-demands-o ctx demands primary
                     #:allocator ddmrp-allocate-o
                     #:buffered-specs buffered)
      (replenishment-o ctx buffered primary demands derived)
      (supply-routing-o ctx buffered supply)
      (== plan `((primary . ,primary)
                 (derived . ,derived)
                 (supply . ,supply))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; ddmrp-leaf-planner — federation protocol entry point
;;; ══════════════════════════════════════════════════════════════════════════════

;; *default-leaf-result-count* is defined in federation.scm — shared by both
;; the default and DDMRP leaf-planners as the upper bound on enumeration.

(define (ddmrp-leaf-planner scope-id ctx cfg)
  "DDMRP single-relation leaf planner. Conforms to federation's
   leaf-planner protocol. Returns a list of federation-results sorted
   by plan coherence (most self-sufficient first).

   IMPORTANT: the relational solver can never fail because the unmet
   branch in after-allocation is always available. So 'first solution'
   is not the same as 'best solution'. We enumerate up to N alternatives
   and rank them by coherence (the per-scope self-sufficiency metric)
   so that the federation gets a principled choice — not whatever
   conde branch ordering happened to find first.

   See plan-walk.scm:plan-coherence and docs/planner-known-gaps.md for
   the conceptual rationale."
  (if (not ctx)
      '()
      (let* ((demands (extract-demands-from-ctx ctx))
             (max-results (or (and cfg (cfg-max-steps cfg))
                              *default-leaf-result-count*))
             ;; Enumerate alternatives — the search may produce many
             ;; including all-unmet ones; coherence ranking sorts them.
             (raw-plans (run-plan max-results '() (plan)
                          (ddmrp-plan-o ctx demands plan)))
             ;; Rank by coherence descending (more self-sufficient first)
             (sorted (sort raw-plans
                       (lambda (a b)
                         (> (plan-coherence a) (plan-coherence b))))))
        (map (lambda (plan)
               (build-ddmrp-federation-result plan scope-id cfg))
             sorted))))

(define (extract-demands-from-ctx ctx)
  "Lift open intents from the ctx's plan-store as a list of demand alists.
   Mirrors extract-open-demands in plan-relation.scm."
  (let ((ps (ctx-ps ctx)))
    (filter-map
      (lambda (i)
        (let ((rq (intent-resource-quantity i)))
          (and rq (> (measure-has-numerical-value rq) 1e-9)
               `((spec-id . ,(intent-resource-conforms-to i))
                 (quantity . ,(inexact->exact (round (measure-has-numerical-value rq))))
                 (unit . ,(measure-has-unit rq))
                 (due . ,(or (intent-due i) #f))
                 (at-location . ,(intent-at-location i))))))
      ($ ps 'open-intents))))

(define (build-ddmrp-federation-result plan scope-id cfg)
  "Convert a reified plan from ddmrp-plan-o into a federation-result
   alist. Plan structure: ((primary . ...) (derived . ...) (supply . ...)).
   The result includes a 'coherence field with the plan-level coherence
   metric, useful for diagnostics and federation-level prioritization."
  (let* ((primary (or (assq-ref plan 'primary) '()))
         (derived (or (assq-ref plan 'derived) '()))
         (supply  (or (assq-ref plan 'supply) '()))
         ;; Coherence: how much of the plan is internally sourced
         (coherence (plan-coherence plan))
         ;; Deficits from BOTH primary and derived (replenishment may also unmet)
         (defs (append (extract-deficits primary scope-id)
                       (extract-deficits derived scope-id)))
         ;; Surpluses come from the supply phase's (surplus ...) terms
         (surps (filter-map
                  (lambda (term)
                    (and (pair? term) (eq? (car term) 'surplus)
                         `((scope-id . ,scope-id)
                           (spec-id  . ,(cadr term))
                           (qty      . ,(caddr term)))))
                  supply))
         ;; Retraction candidates from both primary AND derived.
         ;; Lazy: unused alternatives don't pay the walk; force-cands at
         ;; consumer sites handles both promise and inline-list forms.
         (cands (delay
                  (append (extract-retraction-candidates primary scope-id)
                          (extract-retraction-candidates derived scope-id))))
         (resid (fold (lambda (d a) (+ a (assq-ref d 'qty))) 0 defs))
         ;; Optional harmony — uses cfg-weight-fn from federation-config
         (weight-fn (and cfg (cfg-weight-fn cfg)))
         (harmony-result (and weight-fn
                              (plan-harmony primary #:priority-fn weight-fn)))
         (base `((scope . ,scope-id)
                 (plan . ,plan)
                 (deficits . ,defs)
                 (surpluses . ,surps)
                 (retraction-candidates . ,cands)
                 (residual . ,resid)
                 (coherence . ,coherence))))
    (if harmony-result
        (cons `(harmony . ,harmony-result) base)
        base)))
