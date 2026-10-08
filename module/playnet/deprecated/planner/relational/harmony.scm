;;; harmony.scm — Harmony: the resolution of tension.
;;;
;;; Spec: docs/playnet.typ §"Desire, possibility, and the resolving chord",
;;;       §"Desire as harmony".
;;;
;;; The plan maximises harmony = relaxes tension. Tension has two species;
;;; this module computes the SOFT one — *desire-tension*: the unmet want on
;;; a final good, a bounded quadratic shortfall weighted by social desire.
;;; (The HARD species — *possibility-tension*: labour L<=A, ecological and
;;; fragility barriers — enters via the gap and attractor-regret layers;
;;; full harmony subtracts both.)
;;;
;;;   u = (output - goal) / goal
;;;   harmony = -(u^2)   if u < 0   (desire-tension: quadratic deficit)
;;;   harmony = sqrt(u)  if u >= 0  (surplus: diminishing reward)
;;;
;;; The curve is universal; differentiation between specs comes from a
;;; governance-set priority weight (social desire, exponentially scaled).
;;; The marginal harmony of relaxing one unit of a tension is its *pull*
;;; (see labour/shadow-prices.scm). Harmony is not the absence of tension —
;;; it is tension well-resolved.
;;;
;;; Priority has two representations:
;;;   LEVEL  — small integer (0-10ish), user-facing, set by governance
;;;   WEIGHT — exponential (base^level), internal multiplier on harmony
;;; A 9-level spread produces ~1000x weight difference by default.
;;;
;;; Harmony is computed at the independent-demand level only. Intermediate
;;; resources do not have harmony goals; their allocation importance is
;;; derived from downstream output harmony.
;;;
;;; Key relations:
;;;   harmony-o           — raw harmony for one (goal, output) pair
;;;   weighted-harmony-o  — priority-weighted harmony
;;;   plan-harmony-o      — total weighted harmony for an entire plan
;;;   harmony-diff-o      — relational trade-off trace between two plans
;;;
;;; ── HOW "RELATIONAL" IS THIS HARMONY? ──────────────────────────────────────
;;;
;;; Harmony lives at three levels of "relational" sophistication. Knowing
;;; which level applies where helps avoid confusion.
;;;
;;; LEVEL A — Composable goal (✓ available)
;;;   harmony-o, weighted-harmony-o, plan-harmony-o, harmony-diff-o ARE
;;;   miniKanren goals. They can be composed into queries:
;;;
;;;     (run-plan 1 #f (plan h)
;;;       (plan-o ctx plan)               ; produce a plan
;;;       (plan-harmony-o plan h ...))    ; bind h to its harmony
;;;
;;;   You get back (plan, harmony-score) pairs. The harmony goal acts
;;;   like any other relation in the query. Internally each is wrapped
;;;   in `project` because the arithmetic isn't expressible in CLP(FD)
;;;   (see Level C). That makes them forward-only — the plan must be
;;;   ground when the goal runs.
;;;
;;; LEVEL B — Search-ordering signal (✓ available)
;;;   At the leaf level, default-relational-leaf-planner passes
;;;   by-harmony-priority to plan-o as #:demand-order when weight-fn
;;;   is given. This means demands are processed in priority order;
;;;   under greedy allocation, high-weight specs (essentials) get
;;;   served before low-weight specs (luxuries) when resources are
;;;   scarce.
;;;
;;;   At the federation level, advance-worst-by-harmony and the
;;;   harmony-aware retraction sort steer the lazy stream search
;;;   toward harmony-improving moves.
;;;
;;;   This is steering, not constraining: it changes the order in
;;;   which the search explores, but doesn't prune branches by an
;;;   explicit harmony bound.
;;;
;;; LEVEL C — In-search constraint (✗ NOT available — architectural limit)
;;;   Truly bidirectional harmony — "find a plan where total harmony >
;;;   threshold T" with the constraint pruning the search — would
;;;   require the harmony arithmetic to live inside CLP(FD). It can't:
;;;   - The deficit branch uses (-u^2), quadratic but float-valued
;;;   - The surplus branch uses sqrt, not in CLP(FD) at all
;;;   - The weighting uses (expt base level) with float base
;;;
;;;   To get Level C, you'd need to either:
;;;     1. Discretize harmony with scaled-integer approximations and
;;;        a piecewise-linear curve (loses fidelity, gains pruning)
;;;     2. Switch to CLP(R) or another constraint domain that can
;;;        handle real arithmetic
;;;
;;;   We deliberately use the float-based harmony function for accuracy,
;;;   accepting that it can only be USED post-search (Level A) and as
;;;   a STEERING signal (Level B), not as a CONSTRAINT (Level C).
;;;
;;; In short:
;;;   Level A + B = what we have, and it's substantial.
;;;   Level C     = future work, requires giving up float math.

(define-module (playnet deprecated planner relational harmony)
  #:use-module (playnet deprecated planner relational plan-walk)
  #:export (*harmony-epsilon* *default-priority-base* *default-priority-level*
            priority-level->weight make-weight-fn compute-harmony
            compute-weighted-harmony harmony-o weighted-harmony-o
            extract-demand-outcomes plan-harmony plan-harmony-o harmony-above-o
            harmony-at-least-o harmony-diff harmony-diff-o retraction-loss-exact
            retraction-loss-upper retraction-harmony-impact))

(use-modules (playnet deprecated kanren-constraints)
             (srfi srfi-1))


;;; ── Epsilon for harmony arithmetic ──────────────────────────────────────────

(define *harmony-epsilon* 1e-9)


;;; ── Priority levels → weights ───────────────────────────────────────────────
;;;
;;; Governance sets priority as a small-integer LEVEL (e.g. 0-10). The harmony
;;; math uses an exponentially-scaled WEIGHT. This separation keeps the
;;; user-facing interface intuitive ("bread is level 10, Porsche is level 1")
;;; while preserving the exponential differentiation the math needs.
;;;
;;; Default base is chosen so that a 9-level spread (level 1 → level 10)
;;; produces ~1000x weight difference: base^9 = 1000 → base ≈ 2.154.
;;; This lines up with the intuition that "an essential should dominate a
;;; luxury by roughly 1000x when both are scarce."

(define *default-priority-base* 2.154434690031884)  ;; 1000^(1/9)

(define *default-priority-level* 0)  ;; level 0 = weight 1 (unweighted)

(define* (priority-level->weight level #:key (base *default-priority-base*))
  "Convert a user-facing priority LEVEL (small integer) to a weight
   multiplier (exponentially scaled). Level 0 → weight 1."
  (expt base level))

(define* (make-weight-fn level-fn #:key (base *default-priority-base*))
  "Wrap a LEVEL-FN: (spec-id) → level into a weight function:
   (spec-id) → base^level. Used to build priority-fn for harmony from
   governance-set levels."
  (lambda (spec-id)
    (let ((level (level-fn spec-id)))
      (priority-level->weight (or level *default-priority-level*)
                              #:base base))))


;;; ── Ground harmony computation ──────────────────────────────────────────────

(define (compute-harmony goal output)
  "Raw harmony for a (goal, output) pair. Pure numeric."
  (cond
    ((<= goal *harmony-epsilon*)
     ;; Goal is zero (or nearly so) — no demand, harmony is zero.
     0)
    (else
     (let ((u (/ (- output goal) goal)))
       (cond
         ((< u 0) (- (* u u)))
         ((= u 0) 0)
         (else (sqrt u)))))))

(define (compute-weighted-harmony goal output priority)
  "Priority-weighted harmony. Priority is a multiplier (higher = matters more)."
  (* priority (compute-harmony goal output)))


;;; ── harmony-o: relate (goal, output) to harmony score ──────────────────────

(define (harmony-o goal output h)
  "Relate a goal and an output level to the raw harmony score.
   Forward-biased: goal and output must be ground. The arithmetic
   involves sqrt which CLP(FD) cannot handle symbolically."
  (project (goal output)
    (== h (compute-harmony goal output))))

(define (weighted-harmony-o goal output priority h)
  "Relate (goal, output, priority) to weighted harmony."
  (project (goal output priority)
    (== h (compute-weighted-harmony goal output priority))))


;;; ── extract-demand-outcomes ─────────────────────────────────────────────────
;;; Walks top-level (demand plan-term) pairs only — independent demands.
;;; Produces ((spec-id . s) (goal . g) (output . o)) per demand.
;;; Uses fold-demand-pairs from plan-walk.scm.

(define (extract-demand-outcomes plan)
  "Extract per-independent-demand outcomes from a plan produced by
   all-demands-o. Returns a list of alists with spec-id, goal, output."
  (reverse
    (fold-demand-pairs
      (lambda (demand term acc)
        (let* ((spec (or (assq-ref demand 'spec-id)
                         (plan-term-spec term)))
               (goal (or (assq-ref demand 'quantity)
                         (plan-term-qty term))))
          (cond
            ((not (and spec goal)) acc)
            ((satisfied-term? term)
             (cons `((spec-id . ,spec) (goal . ,goal) (output . ,goal))
                   acc))
            ((unmet-term? term)
             (let* ((remaining (plan-term-qty term))
                    (output (max 0 (- goal remaining))))
               (cons `((spec-id . ,spec) (goal . ,goal) (output . ,output))
                     acc)))
            (else acc))))
      '() plan)))


;;; ── plan-harmony: total weighted harmony for a plan ─────────────────────────

(define* (plan-harmony plan #:key (priority-fn #f))
  "Compute total weighted harmony for PLAN. Returns alist:
     ((total . n) (per-spec . list-of-alists))
   PRIORITY-FN: (spec-id) -> number. Defaults to 1 (unweighted)."
  (let* ((outcomes (extract-demand-outcomes plan))
         (weighted
           (map (lambda (o)
                  (let* ((spec (assq-ref o 'spec-id))
                         (goal (assq-ref o 'goal))
                         (output (assq-ref o 'output))
                         (prio (if priority-fn (priority-fn spec) 1))
                         (raw (compute-harmony goal output))
                         (wh (* prio raw)))
                    `((spec-id . ,spec)
                      (goal . ,goal)
                      (output . ,output)
                      (priority . ,prio)
                      (raw-harmony . ,raw)
                      (weighted-harmony . ,wh))))
                outcomes))
         (total (fold (lambda (o acc)
                        (+ acc (assq-ref o 'weighted-harmony)))
                      0 weighted)))
    `((total . ,total) (per-spec . ,weighted))))


;;; ── plan-harmony-o: relational wrapper ──────────────────────────────────────

(define* (plan-harmony-o plan total-harmony #:key (priority-fn #f))
  "Relate PLAN to its total weighted harmony.
   Forward-biased: plan must be ground."
  (project (plan)
    (let ((result (plan-harmony plan #:priority-fn priority-fn)))
      (== total-harmony (assq-ref result 'total)))))


;;; ── harmony-above-o: post-search soft-constraint filter ────────────────────
;;;
;;; Level A composable goal: succeeds iff PLAN's total weighted harmony
;;; is strictly greater than THRESHOLD. Used to filter the result
;;; stream of `(run-plan n ...)` after a plan is enumerated, e.g.
;;;
;;;   (run-plan 5 #f (plan)
;;;     (plan-o ctx plan)
;;;     (harmony-above-o plan -2.0 #:priority-fn weight-fn))
;;;
;;; This is NOT a Level C in-search constraint — the harmony branches
;;; (sqrt for surplus, -u² for deficit, expt for priority weighting)
;;; involve float arithmetic that CLP(FD) cannot prune over. The
;;; consequence: every candidate plan is fully constructed before its
;;; harmony is checked. For most planners enumerating ≤10 candidates
;;; this is fine; for larger searches use it together with the demand-
;;; ordering steering signal (by-harmony-priority) so that low-harmony
;;; branches are deprioritized in the search order itself. See the
;;; "LEVEL B — Search-ordering signal" docs above.

(define* (harmony-above-o plan threshold #:key (priority-fn #f))
  "Soft constraint: PLAN's total weighted harmony must exceed THRESHOLD.
   Forward-biased: PLAN must be ground when this goal runs.
   Composes with run-plan to filter the candidate stream."
  (project (plan)
    (let* ((result (plan-harmony plan #:priority-fn priority-fn))
           (total (assq-ref result 'total)))
      (if (> total threshold) succeed fail))))

(define* (harmony-at-least-o plan threshold #:key (priority-fn #f))
  "Like harmony-above-o but inclusive: total >= THRESHOLD."
  (project (plan)
    (let* ((result (plan-harmony plan #:priority-fn priority-fn))
           (total (assq-ref result 'total)))
      (if (>= total threshold) succeed fail))))


;;; ── harmony-diff-o: trade-off trace between two plans ──────────────────────

(define* (harmony-diff plan-a plan-b #:key (priority-fn #f))
  "Compute per-spec trade-offs between two plans. Returns alist:
     ((total-a . n) (total-b . n) (delta . n) (gains . list) (losses . list))
   Spec-ids are compared with equal? (they may be strings or symbols)."
  (let* ((ra (plan-harmony plan-a #:priority-fn priority-fn))
         (rb (plan-harmony plan-b #:priority-fn priority-fn))
         (ps-a (assq-ref ra 'per-spec))
         (ps-b (assq-ref rb 'per-spec))
         ;; Index plan-b outcomes by spec-id for joining (use equal? lookup)
         (find-by-spec
           (lambda (ps spec)
             (find (lambda (o) (equal? (assq-ref o 'spec-id) spec)) ps)))
         (deltas
           (filter-map
             (lambda (a)
               (let* ((spec (assq-ref a 'spec-id))
                      (b (find-by-spec ps-b spec))
                      (ha (assq-ref a 'weighted-harmony))
                      (hb (if b (assq-ref b 'weighted-harmony) 0))
                      (d (- hb ha)))
                 (and (> (abs d) *harmony-epsilon*)
                      `((spec-id . ,spec)
                        (harmony-a . ,ha)
                        (harmony-b . ,hb)
                        (delta . ,d)))))
             ps-a))
         ;; Also include specs that appear only in plan-b
         (a-specs (map (lambda (o) (assq-ref o 'spec-id)) ps-a))
         (b-only
           (filter-map
             (lambda (b)
               (let* ((spec (assq-ref b 'spec-id))
                      (hb (assq-ref b 'weighted-harmony)))
                 (and (not (member spec a-specs))
                      (> (abs hb) *harmony-epsilon*)
                      `((spec-id . ,spec)
                        (harmony-a . 0)
                        (harmony-b . ,hb)
                        (delta . ,hb)))))
             ps-b))
         (all-deltas (append deltas b-only))
         (gains (filter (lambda (d) (> (assq-ref d 'delta) 0)) all-deltas))
         (losses (filter (lambda (d) (< (assq-ref d 'delta) 0)) all-deltas)))
    `((total-a . ,(assq-ref ra 'total))
      (total-b . ,(assq-ref rb 'total))
      (delta . ,(- (assq-ref rb 'total) (assq-ref ra 'total)))
      (gains . ,gains)
      (losses . ,losses))))

(define* (harmony-diff-o plan-a plan-b explanation #:key (priority-fn #f))
  "Relate two plans to their harmony trade-off trace.
   Forward-biased: plan-a and plan-b must be ground."
  (project (plan-a plan-b)
    (== explanation (harmony-diff plan-a plan-b #:priority-fn priority-fn))))


;;; ── Retraction harmony-loss ────────────────────────────────────────────────
;;;
;;; Retracting a candidate moves its slot from harmony 0 (satisfied) to
;;; some negative value. The exact loss depends on how much of the
;;; candidate is retracted:
;;;
;;;   Fully retracted (transfer = cand-qty):
;;;     output = 0, goal = cand-qty, u = -1
;;;     raw loss = 1, weighted loss = weight(spec) × 1
;;;
;;;   Partially retracted (transfer < cand-qty):
;;;     output = cand-qty - transfer, u = -(transfer / cand-qty)
;;;     raw loss = (transfer / cand-qty)², weighted = weight × that
;;;
;;; Two functions:
;;;   retraction-loss-exact  — given a specific transfer amount
;;;   retraction-loss-upper  — worst-case (full retraction), used for
;;;                            initial sort ordering where transfer is
;;;                            not yet known

(define (retraction-loss-exact cand transfer-qty weight-fn)
  "Exact weighted-harmony loss from retracting TRANSFER-QTY units
   of CAND. TRANSFER-QTY must satisfy 0 <= transfer <= cand-qty."
  (let* ((spec (assq-ref cand 'spec-id))
         (cand-qty (or (assq-ref cand 'qty) 0))
         (weight (if (and spec weight-fn) (weight-fn spec) 1)))
    (if (or (<= cand-qty 0) (<= transfer-qty 0))
        0
        (let ((u (/ transfer-qty cand-qty)))
          (* weight u u)))))

(define (retraction-loss-upper cand weight-fn)
  "Upper bound: loss if CAND is fully retracted. Equals weight(spec).
   Used as a sort key when the transfer amount isn't yet known.
   Monotone in weight, so ordering matches 'lowest-weight first'."
  (let ((spec (assq-ref cand 'spec-id)))
    (if (and spec weight-fn) (weight-fn spec) 1)))

;; Backward-compat alias — old name, upper-bound semantics.
(define (retraction-harmony-impact cand . rest)
  (let ((weight-fn (and (pair? rest)
                        (let loop ((r rest))
                          (cond
                            ((null? r) #f)
                            ((eq? (car r) #:priority-fn)
                             (and (pair? (cdr r)) (cadr r)))
                            (else (loop (cdr r))))))))
    (retraction-loss-upper cand weight-fn)))
