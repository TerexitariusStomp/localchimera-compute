;;; formulas/actions.scm — every reading of the action table, stated once.
;;;
;;; The action table (vf/schemas.scm `*action-definitions*`) says, per action, which
;;; quantity it carries, whether it is a process input or output, and what it does to a
;;; resource's quantities, location and rights. Code that branches on a verb asks one of
;;; a few questions of that table: is this an input, does it consume, does it take
;;; effort, does it make a thing, does it move one. Each question is answered here, by a
;;; predicate over the table's columns, so a caller states the question and the answer
;;; follows the table. A caller that spells a list of verbs by hand holds a copy that
;;; can drift from it.
;;;
;;; docs/planning/books/beyond-valueflows.md §6.2 is the plan. Three things hold it:
;;; tests/planner/vf-conformance-verbs-test.scm reads the same sets from all_vf.TTL by
;;; the same predicates and holds these to them; tools/lint-verbs.scm counts the sites
;;; that still spell verbs by hand, and that count only falls; and this file is the one
;;; home, so the table file (vf/schemas.scm) stays the vocabulary.
;;;
;;; What the table cannot say is declared at the end, as columns of playnet's own:
;;; which acts RELOCATE (VF's pickup ≡ accept and dropoff ≡ modify in every cell but
;;; `pairsWith`), and which pairs of acts FULFIL one another's commitments.

(define-module (playnet planner formulas actions)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner vf schemas)
  #:use-module ((playnet planner formulas flows) #:select (row-action row-spec row-quantity))
  #:export (actions-where action-input-output
            ;; a process's sides
            process-input-actions process-output-actions input-action? output-action?
            consuming-actions inert-flow-actions effort-actions labour-actions in-place-actions
            ;; the books (docs/observation/readings-are-counts.md)
            *stock-moving-actions* *adjustment-actions* *flow-actions* *rights-moving-actions*
            ;; what a recipe makes
            making-actions output-flow? upstream-closure creating-actions using-up-actions
            committed-by-spec committed-quantity
            ;; playnet's own columns
            relocating-actions relocating-action? relocating-side same-flow?
            ;; the sets the doors and the algorithms ask for
            transferring-actions occupying-actions drawing-actions nonconsuming-input-actions
            onhand-sign
            ;; what a skill is
            labour-specs labour?))

(define (actions-where pred)
  "The actions whose table row satisfies PRED, in the table's order."
  (filter-map (lambda (p) (and (pred (cdr p)) (car p))) *action-definitions*))

(define (%role d) (action-definition-input-output d))
(define (%onhand d) (action-definition-onhand-effect d))
(define (%accounting d) (action-definition-accounting-effect d))
(define (%moves-a-stock? d) (and (memq (%accounting d) '(increment decrement)) #t))

;; an action's side of a process, off the table: input | output | output-input |
;; not-applicable (an action the table does not hold stands on neither side)
(define (action-input-output action-sym)
  "Return the input-output classification for a VF action symbol."
  (let ((entry (assq action-sym *action-definitions*)))
    (if entry (%role (cdr entry)) 'not-applicable)))

;;; ── playnet's own columns ───────────────────────────────────────────────────

;; A relocation is a pickup with its dropoff (accounting S7: a stock relocation is a
;; run). The table cannot tell pickup from accept, or dropoff from modify.
(define relocating-actions '(pickup dropoff))
(define (relocating-action? action) (and (memq action relocating-actions) #t))
(define (relocating-side io)
  "The relocating action on the IO side ('input: the pickup; 'output: the dropoff)."
  (find (lambda (a) (eq? (action-input-output a) io)) relocating-actions))

;; An acquisition is planned as a produce and recorded as a raise, a loss as a lower
;; against a consume: the pairs of actions that bring a good into the books, and take
;; it out, fulfil one another's commitments.
(define (same-flow? a b)
  (or (eq? a b)
      (and (memq a *stock-moving-actions*) (memq b *stock-moving-actions*)
           (eq? (action-definition-accounting-effect (cdr (assq a *action-definitions*)))
                (action-definition-accounting-effect (cdr (assq b *action-definitions*))))
           #t)))

;;; ── a process's sides ───────────────────────────────────────────────────────

;; A flow that goes INTO a process (consume, use, work, cite, pickup, accept, combine).
(define process-input-actions
  (actions-where (lambda (d) (eq? (%role d) 'input))))

;; A flow that comes OUT of a process; deliver-service is both ways in the table
;; (`outputInput`: a service is made and handed over in one act).
(define process-output-actions
  (actions-where (lambda (d) (memq (%role d) '(output output-input)))))

;; The side an action stands on, as a question. A balance (of mass, of energy, of a
;; nutrient) is taken over the stock-moving flows (`*flow-actions*`) and sums one side
;; against the other: these say which.
(define (input-action? action)  (and (memq action process-input-actions) #t))
(define (output-action? action) (and (memq action process-output-actions) #t))

;; An input that takes stock down: onhand `decrement` (consume, combine, pickup, accept).
(define consuming-actions
  (actions-where (lambda (d) (and (eq? (%role d) 'input) (eq? (%onhand d) 'decrement)))))

;; A flow that leaves the stock as it was: a means used or cited, labour, a service.
(define inert-flow-actions
  (actions-where (lambda (d) (and (not (eq? (%role d) 'not-applicable))
                                  (eq? (%onhand d) 'no-effect)))))

;; An act that carries effort: the table's event quantity is `effort` (work) or both (use).
(define effort-actions
  (actions-where (lambda (d) (memq (action-definition-event-quantity d) '(effort-quantity both)))))
;; An act that IS labour: effort alone (work). A `use` carries hours too, but of a
;; means — the thing used is not a skill.
(define labour-actions
  (actions-where (lambda (d) (eq? (action-definition-event-quantity d) 'effort-quantity))))

;; An act on a thing where it stands, which then stands elsewhere or in other hands'
;; care: location effect `update` (pickup · dropoff · accept · modify). VF reads a
;; custody transfer into these when provider and receiver differ (transfers.md).
(define in-place-actions
  (actions-where (lambda (d) (eq? (action-definition-location-effect d) 'update))))

;;; ── the books ───────────────────────────────────────────────────────────────
;;; Which actions MOVE a stock (create or destroy a quantity on the books) is what the
;;; table says of their accounting effect, so the sets a reader of events keys on
;;; derive from it and a new action joins them by construction.
;;;   stock-moving   accounting effect a single increment or decrement: produce,
;;;                  consume, raise, lower (a transfer's decrement-increment moves a
;;;                  stock between hands and makes none)
;;;   adjustment     stock-moving with no input/output side: raise and lower, the
;;;                  count that found the ledger off (VF actions.md)
;;;   flow           stock-moving into or out of a process: produce and consume
(define *stock-moving-actions* (actions-where %moves-a-stock?))
(define *adjustment-actions*
  (actions-where (lambda (d) (and (%moves-a-stock? d) (eq? (%role d) 'not-applicable)))))
(define *flow-actions*
  (actions-where (lambda (d) (and (%moves-a-stock? d) (not (eq? (%role d) 'not-applicable))))))
;; the actions that move RIGHTS from provider to receiver: the table's
;; accountable-effect is `update-to` (transfer, transfer-all-rights). A sale, a
;; gift and a tax are all one of these; what tells them apart is what comes back.
(define *rights-moving-actions*
  (actions-where (lambda (d) (eq? (action-definition-accountable-effect d) 'update-to))))

;; A hand-off between agents: rights move (accountable `update-to`), or custody moves
;; (location `update-to`) with no accounting effect — transfer, transfer-all-rights,
;; transfer-custody. A `move` moves the thing with its accounting, so it is not one.
(define transferring-actions
  (actions-where (lambda (d) (or (eq? (action-definition-accountable-effect d) 'update-to)
                                 (and (eq? (action-definition-location-effect d) 'update-to)
                                      (eq? (action-definition-accounting-effect d) 'no-effect))))))
;; An act that OCCUPIES a thing for a while: event quantity `both` (use).
(define occupying-actions
  (actions-where (lambda (d) (eq? (action-definition-event-quantity d) 'both))))
;; What a process DRAWS on from the world: a stock used up, or a means occupied.
(define drawing-actions
  (append (actions-where (lambda (d) (and (eq? (action-definition-input-output d) 'input)
                                          (eq? (action-definition-accounting-effect d) 'decrement))))
          occupying-actions))
;; An input that consumes nothing and is not labour: a means occupied, a reference cited.
(define nonconsuming-input-actions
  (actions-where (lambda (d) (and (eq? (action-definition-input-output d) 'input)
                                  (eq? (action-definition-onhand-effect d) 'no-effect)
                                  (not (eq? (action-definition-event-quantity d) 'effort-quantity))))))
;; The sign an act puts on a stock on hand: +1 for an increment, -1 for a decrement,
;; #f where the table says no effect (a use, a work) or a relocation of the same thing.
(define (onhand-sign action)
  (let ((d (assq action *action-definitions*)))
    (and d (case (action-definition-onhand-effect (cdr d))
             ((increment increment-to) 1)
             ((decrement) -1)
             (else #f)))))

;;; ── what a recipe makes ─────────────────────────────────────────────────────
;; The one reading of "this flow is an output": an act that puts a quantity on hand
;; (onhand `increment` or `increment-to`: produce · modify · separate · raise · copy)
;; or is made and handed over at once (`output-input`: deliver-service), and is no
;; relocation (a dropoff lands what a pickup took; nothing is made). Labour, a means
;; used or cited and a transfer between hands have no such onhand effect, so the
;; table itself leaves them out. compile-process lays the template's outputs by this,
;; and every reader asking "can the scope supply this good?" (live.scm's claims and
;; food, accepts.scm's pins) asks it here, so a good the plan can make is a good the
;; plan knows it can make. Read off the literal verb `produce` instead, a night's
;; shelter — a `deliver-service` — was made by two recipes and claimable by nobody:
;; the citizen's want stood at zero beside nine nights delivered.
(define making-actions
  (remove relocating-action?
          (actions-where (lambda (d) (or (eq? (%role d) 'output-input)
                                         (memq (%onhand d) '(increment increment-to)))))))
(define (output-flow? rf)
  (and (memq (recipe-flow-action rf) making-actions) #t))

;; "How much MORE is there?" is a narrower question than "what does this process
;; make?". VF (concepts/actions.md): a produce brings a new resource into being and a
;; deliverService a new service, which no inventory holds; a modify and a separate
;; hand back the SAME resource an accept or a combine took in, and a dropoff the one
;; a pickup took. So what comes newly into being is the output that adds to the
;; books (accounting `increment`) or is made and handed over at once
;; (`output-input`): produce · deliver-service. A tally of what a plan produces
;; reads this; a repaired bicycle is no new bicycle.
(define creating-actions
  (actions-where (lambda (d) (or (eq? (%role d) 'output-input)
                                 (and (eq? (%role d) 'output) (eq? (%accounting d) 'increment))))))

;; Its other side: what is GONE after the process (VF: "after the process the
;; specified quantity of the consumed input is gone"). The input that takes a
;; quantity off the books (accounting `decrement`): consume. An accept, a combine and
;; a pickup take a thing off hand that comes back.
(define using-up-actions
  (actions-where (lambda (d) (and (eq? (%role d) 'input) (eq? (%accounting d) 'decrement)))))

(define (committed-by-spec commitments actions)
  "What the COMMITMENTS whose action is in ACTIONS commit of each specification,
   ((spec . quantity) …) in the order the specifications are first met: with
   `creating-actions` what a plan newly makes, with `using-up-actions` what it
   uses up. A row is a commitment, an intent or a stored plan row, read by the
   flow readers. The one tally every reading of a plan's material is written with."
  (let ((sum (make-hash-table)) (order '()))
    (for-each (lambda (c)
                (let ((spec (row-spec c)) (q (row-quantity c)))
                  (when (and spec q (memq (row-action c) actions))
                    (unless (hash-ref sum spec) (set! order (cons spec order)))
                    (hash-set! sum spec (+ q (hash-ref sum spec 0.0))))))
              commitments)
    (map (lambda (spec) (cons spec (hash-ref sum spec))) (reverse order))))
(define (committed-quantity commitments spec actions)
  "How much of SPEC the COMMITMENTS whose action is in ACTIONS commit, as a number;
   0.0 where they commit none of it."
  (or (assoc-ref (committed-by-spec commitments actions) spec) 0.0))

(define* (upstream-closure flows specs #:key (inputs '(consume)))
  "The upstream of SPECS in the recipe FLOWS: the least set of specs, and the
   processes passed through, closed under 'a process that MAKES a member
   (output-flow?) takes in its inputs' — the flows whose action is in INPUTS
   (consume; with use, the capacity it draws on as well). → (values specs
   processes), processes in the order they are first met."
  (let loop ((frontier (delete-duplicates specs)) (seen '()) (procs '()))
    (if (null? frontier)
        (values seen procs)
        (let* ((made (delete-duplicates
                      (filter-map (lambda (f)
                                    (and (output-flow? f)
                                         (member (recipe-flow-resource-conforms-to f) frontier)
                                         (recipe-flow-recipe-output-of f)))
                                  flows)))
               (new-procs (lset-difference equal? made procs))
               (taken (delete-duplicates
                       (filter-map (lambda (f)
                                     (and (memq (recipe-flow-action f) inputs)
                                          (member (recipe-flow-recipe-input-of f) new-procs)
                                          (recipe-flow-resource-conforms-to f)))
                                   flows)))
               (seen* (append seen frontier)))
          (loop (lset-difference equal? taken seen*) seen* (append procs new-procs))))))

;; ── what a skill is ──────────────────────────────────────────────────────────
;; A skill is a ResourceSpecification that is WORKED: it states a unit of effort
;; (defaultUnitOfEffort — the field VF gives a worked spec, which `skill*` writes),
;; or some recipe flow draws it under a labour action (the table's `work`). A
;; resource conforming to such a spec, held by a person at on-hand > 0, is a
;; skill they hold. Nothing about a resource's id says so: the roster
;; (pools/labour-fold), the solver (engine vf-agent-skills), the holders table and
;; the socialization view all read this one function, so a stock of water a person
;; holds never reads as the skill "water" unless a recipe works water.
(define (labour-specs flows specs)
  "The spec ids that are labour, read off the recipe FLOWS and the resource SPECS:
   a spec stating an effort unit, a spec standing in a `satisfied-by` relation (a
   composite skill and the parts that satisfy it — the relation is between
   skills), and a spec a recipe works."
  (delete-duplicates
   (append (filter-map (lambda (sp) (and (resource-specification-default-unit-of-effort sp)
                                         (resource-specification-id sp)))
                       specs)
           (append-map (lambda (sp)
                         (let ((by (resource-specification-satisfied-by sp)))
                           (if (pair? by)
                               (cons (resource-specification-id sp)
                                     ;; a DNF: clauses of (spec . threshold) pairs
                                     (append-map (lambda (clause)
                                                   (filter-map (lambda (t) (cond ((pair? t) (and (string? (car t)) (car t)))
                                                                                 ((string? t) t) (else #f)))
                                                               (if (list? clause) clause (list clause))))
                                                 by))
                               '())))
                       specs)
           (filter-map (lambda (f) (and (memq (recipe-flow-action f) labour-actions)
                                        (recipe-flow-resource-conforms-to f)))
                       flows))))

(define (labour? flows specs)
  "The predicate (spec-id → bool) over labour-specs, indexed once."
  (let ((t (make-hash-table)))
    (for-each (lambda (sp) (hash-set! t sp #t)) (labour-specs flows specs))
    (lambda (spec) (and spec (hash-ref t spec #f) #t))))
