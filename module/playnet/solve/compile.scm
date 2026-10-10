;;; compile.scm — §5, THE VF COMPILER, the module (playnet solve compile).
;;;
;;; WHY THIS IS ITS OWN FILE. The compile stage is what BOTH the engine and the
;;; (playnet planner) umbrella need, and each imports it: `compile-process` and
;;; `compile-recipe` are bound the same way on every path, so a test states
;;; (playnet solve compile) beside its engine import and the use-unit GUARD
;;; (an engine-side register) and the use-unit TEST (the recipe catalogue) can
;;; be written in one file.
;;;
;;; The section is self-contained: `*templates*` is defined below, and the only
;;; outside name is `*action-definitions*` from schemas.scm.

;; ════════════════════════════════════════════════════════════════════════════
;; §5 — THE VF COMPILER: RecipeProcess + its RecipeFlows → one compiled `template`
;; ════════════════════════════════════════════════════════════════════════════
;; The knowledge layer already IS activity analysis: a RecipeProcess is a column,
;; a RecipeFlow a coefficient (sign/role read off the standard action table), a
;; ResourceSpecification a row. So we don't invent a model — we compile records.
;; A `template` is NOT a RecipeProcess record — it is that process WITH its flows
;; folded in, the compiled column-PATTERN (accessed by `proc-*`, below). Tiling a
;; template over the cells (§6) is what yields the located ACTIVITIES (the columns
;; of x). Shape: (id outputs inputs labour skill-labours _ moved relocated), where
;; outputs/inputs = alist (spec . qty), skill-labours = ((skill . hours) …), the
;; 6th slot is reserved/empty, moved/relocated = (spec …). See compile-process.
;; VF (actions.md): a `work` flow carries no resource — only the provider agent —
;; and "the type of work or skill involved can be identified by a resource
;; specification": that is the work flow's resourceConformsTo. So the process's
;; SKILL is read straight off the recipe here (not bolted on). effortQuantity is
;; the hours (a time-based action; it affects no economic resource).
(define-module (playnet solve compile)
  #:use-module ((playnet vf facts agent-tags) #:select (tag-value))
  #:use-module ((playnet vf facts located) #:select (svc-good svc-good? bar-spec lg cell))
  #:re-export (svc-good %ambient-tag)   ; the Svc| namer is the key grammar's (facts/located); re-exported for the two loaders that read it here
  #:use-module ((playnet vf formulas flows) #:select (%ambient-tag))
  #:use-module (srfi srfi-1)
  #:use-module (playnet vf schemas)
  #:use-module (playnet vf formulas actions)
  #:use-module (playnet utils units)
  #:use-module (playnet knowledge dsl shorthand)
  #:re-export (rp out in wrk out/u in/u wrk/u)   ; the recipe spelling is the DSL's (knowledge/dsl/shorthand.scm)
  #:re-export (output-flow? upstream-closure)   ; what a recipe makes is read off the action table, beside it (schemas.scm)
  #:export (mqty action-def alist-add compile-process proc-id proc-outputs
            proc-inputs proc-labour proc-skill-labours proc-moved proc-relocated
            proc-timed-svc proc-duration proc-batch proc-whole? proc-tags proc-output-good compile-recipe recipe-manner manner-of-tags
            qualified-good good-names bare-spec *templates* set-templates!
            *use-unit-gaps* use-unit-gaps clear-use-unit-gaps!
            *batch-unit-gaps* batch-unit-gaps clear-batch-unit-gaps!))

(cond-expand (guile) (else (define (getenv name) #f)))   ; a page has no process environment; the PLANNER_* switches read as unset

(define (mqty m) (if m (measure-has-numerical-value m) 0.0))
(define (action-def a) (let ((p (assq a *action-definitions*))) (and p (cdr p))))
(define (alist-add al key v)                ; accumulate v into key's entry (per-skill labour)
  (if (assoc key al) (map (lambda (p) (if (equal? (car p) key) (cons key (+ (cdr p) v)) p)) al)
      (cons (cons key v) al)))
;; svc-good lives here, beside compile-process — the only thing that mints
;; one — so the engine and the umbrella, which both import this module, name
;; the service good the same way; a recipe with a `use` flow compiles on
;; either path.
;; svc-good (facts/located): the per-period SERVICE good of a durable `use`d in a process — the instrument twin of lab-good's Lab| pool (both are structural pools, see spec-skips-balance? / STRUCTURAL). Located via (lg (svc-good spec) cell). Kept core-local like lab-good; svc-eco-caps builds the located form directly in the sibling umbrella.

(define* (compile-process rp-id flows duration #:optional (duration-hours #f) (batch #f) (whole? #f) (tags '()))
  ;; a process may carry SEVERAL work flows of DIFFERENT skills (VF allows it), so
  ;; labour is captured PER skill: skill-labours = ((skill . hours) …). total labour
  ;; (the 4th field) is their sum; a work flow naming no skill is "general" labour.
  ;; BATCH is the recipe's minimumBatchQuantity (a <measure>, or #f) and WHOLE? says
  ;; the act happens a whole number of times; both compile into the template, since
  ;; a compiled recipe outlives the reset! that begins each solve (see proc-timed-svc).
  (let ((outputs '()) (inputs '()) (skill-labours '()) (moved '()) (relocated '()) (timed-svc '())
        (out-units '()))                    ; (spec . unit) of each output flow — what a batch quantity is read against
    (for-each
     (lambda (rf)
       (let* ((action (recipe-flow-action rf))
              ;; the flow says which stage the resource is in AT THIS END, so an
              ;; output at a stage and an input requiring it name the same good
              (spec (qualified-good (recipe-flow-resource-conforms-to rf)
                                    (recipe-flow-stage rf) (recipe-flow-state rf)))
              (rq (mqty (recipe-flow-resource-quantity rf))) (eff (mqty (recipe-flow-effort-quantity rf)))
              (ad (action-def action)) (oh (and ad (action-definition-onhand-effect ad))))
         ;; EVERY VF action mapped to its role in the located plan (a transform of located stocks).
         (cond ((eq? action 'work) (set! skill-labours (alist-add skill-labours (or spec "general") eff)))   ; living LABOUR (skill = resourceConformsTo)
               ;; A durable USED draws its per-period SERVICE, and a `use` states
               ;; that in TWO quantities: resourceQuantity is how many are engaged,
               ;; effortQuantity for how long. Both matter — taking one and
               ;; discarding the other is how two ovens came to bake 1.33 loaves.
               ;; transport.scm's shared builder already says it plainly: "occupy
               ;; COUNT of the resource for HOURS".
               ;;
               ;; Svc| is denominated in UNIT-PERIODS (capacity = the stock that
               ;; stands available), so a duration has to be read as the share of
               ;; the period it occupies. Only a TIME-valued effort is a duration;
               ;; the marking here is what tells build-located to divide by the
               ;; period's own length, where the period is finally known. An
               ;; effort in any other unit is a plain multiplier. An ABSENT one
               ;; means the run occupies the unit for as long as the run takes —
               ;; the process's own `has-duration` — falling back to the whole
               ;; period only for a process that states no length at all.
               ((eq? action 'use)
                (let* ((n (if (> rq 0.0) rq 1.0))
                       (eu (and=> (recipe-flow-effort-quantity rf) measure-has-unit))
                       (timed? (and (> eff 0.0) (eq? 'time (unit->substance eu))))
                       ;; HOW LONG the run occupies it, when the flow does not say.
                       ;; The PROCESS says: `has-duration` is how long one run takes,
                       ;; and a means engaged for a run is engaged for the run's own
                       ;; length. Reading the PERIOD's length instead makes a plan a
                       ;; function of the partition — refine a day into thirds and
                       ;; three times as many runs fit, each still yielding one
                       ;; output, so a finer lattice manufactures product from
                       ;; nothing. The process duration holds still while the lattice
                       ;; moves, which is what makes it the right length to read.
                       (proc-hours (and (not (> eff 0.0)) duration (> duration 0.0)
                                        duration))
                       (occupied (or (and timed? eff) proc-hours)))
                  ;; occupied for a stated length, from either source ⇒ the draw is
                  ;; already in unit-hours and build-located must not scale it again
                  (when occupied (set! timed-svc (cons spec timed-svc)))
                  ;; UNIT-LINT (PLANNER_UNIT_LINT=1) — an honesty report, in the
                  ;; RAW-LINT tradition, not an error. The solver is unit-free:
                  ;; `mqty` takes a measure's NUMBER and drops its unit, so nothing
                  ;; downstream can tell a duration from a count. This is the last
                  ;; point where the unit still exists.
                  ;;
                  ;; The invariant that actually matters is that a `use`'s draw and
                  ;; its spec's capacity are denominated the same way. THIS
                  ;; function cannot check it — a template is compiled before any
                  ;; catalogue is ingested, so only the flow is in scope here —
                  ;; while `defaultUnitOfResource` states the other half one phase
                  ;; later. tests/planner/test-use-unit-lint.scm holds the two
                  ;; together, and enforces the one pairing that fails to cancel:
                  ;; a spec counted in TIME drawn with no duration.
                  ;;
                  ;; What remains here is the report a single flow can justify. A
                  ;; non-time effort reads as a plain multiplier on the count,
                  ;; which is right whenever the capacity is stated in that same
                  ;; unit — a `slot` drawn against a channel stocked in slots. No
                  ;; recipe in the tree does that today (a channel states its slots
                  ;; as the COUNT, and takes no effort at all), so this branch has
                  ;; no live subjects and exists for the one it would catch: `1.0
                  ;; "ha"` sitting in an effort slot, reading as a duration to
                  ;; every human who meets it.
                  ;;
                  ;; The OTHER way to miswrite a `use` — a duration in the COUNT
                  ;; slot, `1.5 hours` of a van reading as 1.5 vans held all day —
                  ;; cannot be judged from here, and the reason is the one above.
                  ;; It is wrong against a stock counted in vans and RIGHT against
                  ;; a stock counted in van-hours, where the period's length
                  ;; multiplies both sides and cancels. Deciding it needs the
                  ;; spec's own unit, which lives in the recipe store and never
                  ;; reaches this function. Worse, a durable's derived cap is
                  ;; stock × the window's hours (see ingest-located), so a spec
                  ;; whose stock is ALREADY denominated in hours takes the period's
                  ;; length twice. Both halves have to be read together, and
                  ;; neither is visible from here.
                  ;; RECORDED, not just printed. This report was env-gated to
                  ;; stderr, so it fired only for someone who already suspected a
                  ;; unit problem and knew the variable's name — and the two comms
                  ;; fixtures carried exactly this defect for months while the
                  ;; sentence that diagnoses it sat right here, unread. A `use`
                  ;; drawing 1.0 "slot" against a channel capped in hours, on a
                  ;; process stating no duration, occupied that channel for the
                  ;; whole period: reach saturated at 100/24 = 4.17 whatever the
                  ;; demand, which read as an unmet want rather than a mismatch.
                  ;;
                  ;; So it accumulates, in the register this repo already uses for
                  ;; honesty reports a caller can ASSERT on — `chain-duration-gaps`,
                  ;; `composition-unstated`, `ungrounded-claims`. A gap you can
                  ;; query is a work-list; a gap you can only print is a rumour.
                  ;; The stderr line stays for anyone running with the variable set.
                  (when (and (> eff 0.0) (not timed?))
                    (set! *use-unit-gaps*
                          (cons (list rp-id spec (or eu "no unit")) *use-unit-gaps*))
                    (when (getenv "PLANNER_UNIT_LINT")
                      (format (current-error-port)
                              "[UNIT-LINT] ~a `use`s ~a with a non-time effort in ~s — read as a count multiplier; correct iff its capacity is stated in ~s too~%"
                              rp-id spec (or eu "no unit") (or eu "the same unit"))))
                  (set! inputs (acons (svc-good spec)
                                      (* n (or occupied (if (> eff 0.0) eff 1.0)))
                                      inputs))))
               ((eq? action 'cite) #t)                                                                        ; CITE: non-rival reference — must be available, but draws no capacity (rolls embodied value into the output; no allocation constraint)
               ((output-flow? rf) (set! outputs (acons spec rq outputs))                                     ; a MAKING: a service delivered, or produce · modify · separate · raise · copy (output-flow?)
                                  (set! out-units (acons spec (and=> (recipe-flow-resource-quantity rf) measure-has-unit) out-units)))
               ((relocating-action? action) (set! relocated (cons spec relocated)))                      ; TRANSPORT: pickup@origin / dropoff@destination of the SAME good (locationEffect) → an ARC activity (relocate, not a same-cell consume/produce)
               ((eq? action 'move) (set! moved (cons spec moved)))                                           ; MOVE: spatial relocation, same custody → mark the good movable
               ((memq action transferring-actions) #t)                           ; TRANSFER: re-assign custody/rights BETWEEN agents — the provisioning/exchange interface (cross-scope pulls, §solve-decomposed), not a within-scope production flow
               ((eq? oh 'decrement) (set! inputs (acons spec rq inputs)))                                     ; consume · accept · combine · lower
               ((eq? oh 'decrement-increment) (set! moved (cons spec moved)))                                 ; any other same-resource relocate → movable
               (else #t))))
     flows)
    ;; A DURATION IS TIME, and labour is what the `work` flows state. A process
    ;; with a duration and no work flow takes that long and asks nobody's hours:
    ;; a night in a bed, a dough proving, a field in fallow. The length still
    ;; rides the template (the run-length field below) for leads and windows.
    ;; Read as "general" labour it made every such act wait on a worker nobody
    ;; is — free where labour was an open aggregate, pruned where it was people.
    (let ((total (fold (lambda (sl a) (+ a (cdr sl))) 0.0 skill-labours)))
      (list rp-id outputs inputs total skill-labours '() (delete-duplicates moved) (delete-duplicates relocated)
            (delete-duplicates timed-svc)
            ;; wall-clock length of ONE run in HOURS, when the recipe stated it.
            ;; This is the only honest source — inferring it from labour hours
            ;; would read an aggregate sector's 10⁴ h-per-unit as an atomic month
            ;; and prune real columns. A stated has-duration is an atomic-run
            ;; claim; its absence is "no within-band claim" (§3.2's register).
            ;; DURATION-HOURS is the unit-converted reading (180 "days" = 4320 h);
            ;; the bare DURATION number stays what the legacy `use` fallback
            ;; above reads, a pre-existing seam recorded in the open threads.
            (or duration-hours duration 0.0)
            ;; the recipe's discreteness, in the column's own denomination (RUNS)
            (batch-runs rp-id batch outputs out-units)
            (and whole? #t)
            ;; the process's classification (VF processClassifiedAs), the
            ;; strings only: the folksonomy tags a part can name (parts.scm
            ;; kind `tag`), read onto its columns by the engine's column-terms
            (if (list? tags) (filter string? tags) '())))))
(define (proc-id c) (car c)) (define (proc-outputs c) (cadr c))
(define (proc-inputs c) (caddr c)) (define (proc-labour c) (cadddr c))
(define (proc-skill-labours c) (if (> (length c) 4) (list-ref c 4) '()))
(define (proc-moved c) (if (> (length c) 6) (list-ref c 6) '()))  ; (spec …) RELOCATED by a `move` flow → made movable (6th slot reserved/unused — `use` now compiles to a Svc consume)
(define (proc-relocated c) (if (> (length c) 7) (list-ref c 7) '()))
;; (spec …) whose `use` states a DURATION — its Svc draw is a share of the period,
;; divided by the period's length at build time. Carried IN the template, beside
;; moved/relocated, because a compiled recipe outlives the reset! that clears the
;; solve's tables: held in a global it was recorded at compile time and wiped
;; before a single column was built.
(define (proc-timed-svc c) (if (> (length c) 8) (list-ref c 8) '()))  ; (spec …) picked-up @origin / dropped-off @destination → an ARC (transport) activity
(define (proc-duration c) (if (> (length c) 9) (list-ref c 9) 0.0))   ; wall-clock hours of ONE run (has-duration), 0 = no within-band claim
;; ── the recipe's DISCRETENESS, carried in the template ───────────────────────
;; A column's level counts RUNS of the recipe, so both declarations are stated in
;; runs here, whatever the recipe wrote them in. §7 of the engine reads them into
;; its per-process tables at ingest (the same door `#:whole` uses).
(define (proc-batch c) (if (> (length c) 10) (list-ref c 10) #f))    ; run at ≥ this many runs or not at all (VF minimumBatchQuantity), #f = divisible
(define (proc-whole? c) (and (> (length c) 11) (list-ref c 11)))     ; the act happens a whole number of times (processClassifiedAs "whole-count")
(define (proc-tags c) (if (> (length c) 12) (list-ref c 12) '()))     ; its classification strings, whole-count included
(define (proc-output-good c)                 ; a template's primary output good, or #f
  (and (pair? (proc-outputs c)) (caar (proc-outputs c))))
;; The router's costing a transport process travels under: its
;; "manner:<costing>" classification, or #f when it states none.
(define (manner-of-tags tags) (tag-value (or tags '()) "manner"))
(define (recipe-manner rp) (manner-of-tags (recipe-process-process-classified-as rp)))
(define (compile-recipe procs flows)        ; labour from explicit work-flows, else has-duration
  ;; bucket flows by their process id ONCE (input-of / output-of) — O(F+P), not an
  ;; O(P·F) per-process filter. On a dense table (e.g. a national I-O with ~10³
  ;; processes × ~10⁵ flows) the quadratic walk is the difference between minutes and
  ;; an instant; the live recipe-store path hits the same scaling.
  (let ((by-pid (make-hash-table)))
    (for-each
     (lambda (rf)
       (let ((i (recipe-flow-recipe-input-of rf)) (o (recipe-flow-recipe-output-of rf)))
         (when i (hash-set! by-pid i (cons rf (hash-ref by-pid i '()))))
         (when (and o (not (equal? o i))) (hash-set! by-pid o (cons rf (hash-ref by-pid o '()))))))
     flows)
    (map (lambda (rp)
           (let* ((pid (recipe-process-id rp))
                  (dur (let ((d (recipe-process-has-duration rp))) (and d (duration-has-numerical-value d))))
                  ;; the duration in HOURS for scheduling: the stated unit is
                  ;; converted (days ×24, weeks ×168); an unstated or unknown
                  ;; unit reads as hours, the tree's dominant convention
                  (dur-h (let ((d (recipe-process-has-duration rp)))
                           (and d (let ((u (duration-has-unit d)))
                                    (if (and u (unit-known? u))
                                        (convert-unit (duration-has-numerical-value d) u)
                                        (duration-has-numerical-value d)))))))
             (compile-process pid (hash-ref by-pid pid '()) dur dur-h
                              (recipe-process-minimum-batch-quantity rp)
                              (whole-count-tag? (recipe-process-process-classified-as rp))
                              (recipe-process-process-classified-as rp))))
         procs)))

;; ── minimum batch: a MEASURE on the recipe, a floor in RUNS on the column ────
;; VF states minimumBatchQuantity as a quantity of what the process makes; the
;; column it constrains counts runs. So the measure is read against the recipe's
;; own outputs: stated in the unit of one of them, the floor is that quantity
;; over the per-run output (80 loaves over 20 a run = 4 runs); stated in no
;; unit it counts runs directly. A unit that matches no output is read as runs
;; too, and RECORDED in the batch-unit register — the same honesty channel the
;; `use` unit report uses — so a recipe stating "80 kg" over a process that
;; outputs loaves is a queryable gap and never a silent 80-run floor.
;;
;; A fractional floor is fine: 80 loaves over 30 a run is x = 0 or x ≥ 2.67, and
;; the search splits exactly there. Whole counts are the OTHER declaration.
(define (whole-count-tag? tags)
  (and (list? tags) (any (lambda (t) (and (string? t) (member t '("whole-count" "whole")))) tags) #t))
(define (unit-matches? a b)                 ; the same unit, spelt the same or convertible within one substance
  (or (equal? a b)
      (and (string? a) (string? b) (unit-known? a) (unit-known? b)
           (eq? (unit->substance a) (unit->substance b))
           (not (memq (unit->substance a) '(other rate))))))
(define (batch-runs rp-id m outputs out-units)
  (and m
       (let ((q (mqty m)) (u (measure-has-unit m)))
         (and (> q 0.0)
              (let ((hit (and u (find (lambda (ou) (unit-matches? (cdr ou) u)) out-units))))
                (cond
                 (hit
                  (let* ((spec (car hit)) (ou (cdr hit)) (per (or (assoc-ref outputs spec) 0.0))
                         ;; both sides to the substance's base when the spellings differ
                         (q* (if (equal? ou u) q (convert-unit q u)))
                         (per* (if (equal? ou u) per (convert-unit per ou))))
                    (and (> per* 0.0) (/ q* per*))))
                 ((count-unit? u) q)
                 (else
                  (set! *batch-unit-gaps* (cons (list rp-id u (map cdr out-units)) *batch-unit-gaps*))
                  (when (getenv "PLANNER_UNIT_LINT")
                    (format (current-error-port)
                            "[UNIT-LINT] ~a states a minimum batch in ~s, which none of its outputs is measured in (~a) — read as a floor in RUNS~%"
                            rp-id u (map cdr out-units)))
                  q)))))))
;; ((process batch-unit (output-unit …)) …) — every minimum batch whose unit
;; matched none of the process's outputs; `batch-unit-gaps` reads it,
;; `clear-batch-unit-gaps!` resets between sweeps.
(define *batch-unit-gaps* '())
(define (batch-unit-gaps) (reverse *batch-unit-gaps*))
(define (clear-batch-unit-gaps!) (set! *batch-unit-gaps* '()))

;; ── the bread chain, as REAL ValueFlows records (the worked example) ─────────
;; ── A STAGE IS PART OF WHAT A THING IS ───────────────────────────────────────
;; Soil after legumes is not soil after maize; an opened patient is not a waiting
;; one; a line that has just run peanuts is not a clean line. VF says this with
;; `stage` (which process it has been through) and `state` (what condition it is
;; in), and the solve read neither — so every sequence constraint had to be
;; smuggled in as an invented spec.
;;
;; It needs no new machinery, because the lattice already identifies a good BY
;; ITS NAME: qualify the name and the material flow does the rest. An act that
;; outputs a stage produces that good, an act that requires it consumes it, and
;; the ordering falls out of the balance rows — no indicator variable, no product
;; of binaries. This is the same move `Svc|spec` and `Cond|durable` already make,
;; read as a suffix rather than a prefix.
;;
;; So "changeover priced by which act preceded" stops needing a binary wherever
;; the difference has a CARRIER, which is nearly always: the residue, the
;; contamination, the condition of the field IS the state, and a state is a good.
(define %stage-sep "/")
(define %state-sep "!")                  ; its own character: "~" belongs to the owner (spec-owner)
(define (qualified-good spec stage state)
  "SPEC, narrowed by the stage it has been through and the condition it is in."
  (let* ((add (lambda (g sep q)
                (if (and (string? q) (not (string-null? q)))
                    (string-append g sep q)
                    g)))
         (g (add spec %stage-sep stage)))
    (add g %state-sep state)))

(define (good-names spec stage state)
  "The names SPEC goes by in a plan, most specific first: with its stage and its
   state, with its stage, with its state, bare. A plan's goods use whichever of
   them its recipes name; a holding is a lot of any good whose name is among them."
  (delete-duplicates (list (qualified-good spec stage state)
                           (qualified-good spec stage #f)
                           (qualified-good spec #f state)
                           spec)))

(define (bare-spec good)
  "The specification GOOD is a lot of: its name before any stage, state or owner
   (\"~\") separator. A manual scan: Hoot has no char-sets."
  (let ((seps (append (string->list %stage-sep) (string->list %state-sep) '(#\~))))
    (let loop ((i 0))
      (cond ((= i (string-length good)) good)
            ((memv (string-ref good i) seps) (substring good 0 i))
            (else (loop (+ i 1)))))))

;; the compiled recipes of the problem in hand — supplied per solve
;; (ingest-records!, or a caller's own compile-recipe), cleared by reset!.
(define *templates* '())
;; 78 sites outside this file assign *templates* directly — `(set! *templates*
;; (compile-recipe …))` is the engine's, the studies' and the benches' shared
;; idiom, and it keeps working through an import. But only while this file also
;; assigns it: a module that never writes its own global lets the compiler
;; resolve its reads directly, so an importer's set! writes a box the module no
;; longer consults. Interpreted that is invisible; compiled, the two views
;; diverge in silence. This setter keeps the variable boxed — and names the
;; mutable surface, which is the honest version of what those 78 sites do.
(define (set-templates! ts) (set! *templates* ts))
;; THE WORKED EXAMPLE used to be loaded here. It cannot be: `setup-space` and
;; its four siblings assign twelve of the ENGINE's globals (*places*, *periods*,
;; *demand*, *templates* …), so it has to define into whichever module loaded
;; the engine — which is what a primitive-load from planner.scm does and what a
;; load from inside this module would not. It sits beside the engine now, which
;; is where the comment always said it belonged.

;; ── the use-unit register ───────────────────────────────────────────────────
;; ((process spec effort-unit) …) — every `use` whose effortQuantity carries a
;; NON-TIME unit, so its draw reads as a plain count multiplier. That is right
;; exactly when the spec's capacity is stated in the same unit, and silently off
;; by a period's length when it is not (compile-process). Accumulated rather than
;; printed so a test can assert on it; `use-unit-gaps` is the reader and
;; `clear-use-unit-gaps!` resets between sweeps.
;;
;; REACHES ONE ASSEMBLY PATH, and that is the reason it carries no test yet.
;; This file is loaded by `primitive-load` (most planner tests, the fixtures);
;; the (playnet planner) umbrella never includes it, assembling the engine from
;; ~96 include-from-path fragments instead. `compile-process` therefore exists on
;; two paths, and a guard installed here is invisible to anything that loads the
;; engine the other way — including test-use-unit-lint, which is exactly the file
;; that would assert on this. See planner-coherence-open-threads.md §7.5.
(define *use-unit-gaps* '())
(define (use-unit-gaps) (reverse *use-unit-gaps*))
(define (clear-use-unit-gaps!) (set! *use-unit-gaps* '()))
