;;; module/playnet/doors/plan-wire.scm — a landed plan as the faces read it: the dial plan, the matter graph, the fragility wheel, the location slacks, the snapshot. Pure over a scope root and a cached solve.
;;;
;;; A library the planner service's doors call (docs/planning/codebase-layout.md §12): a
;;; verb takes the scope root and the arguments; the door is the gate and one call.

(define-module (playnet doors plan-wire)
  #:use-module (playnet solve report)
  #:use-module ((goblins) #:select ($))
  #:use-module ((playnet algorithms elastic) #:select (current-social-free-time))
  #:use-module ((playnet doors counts) #:select (count-readable?))
  #:use-module ((playnet doors inventory) #:select (measure->qty scope-inventory-wire))
  #:use-module ((playnet doors record-rows) #:select (lookup-spec-name record-context))
  #:use-module ((playnet economy payouts) #:select (intent-private?))
  #:use-module ((playnet knowledge catalogues compiler) #:select (catalogue->wire))
  #:use-module ((playnet knowledge catalogues eco) #:select (*planetary-catalogue*))
  #:use-module ((playnet knowledge catalogues substances) #:select (*contains* composition-in-force environment-spec? substance-content substances->wire))
  #:use-module ((playnet plan accepts) #:select (floors->wire))
  #:use-module ((playnet plan store) #:select (intent-window-passed? proposal-stands?))
  #:use-module ((playnet pools credit-fold) #:select (consumer-voice global-effective-balance global-total-claim-capacity))
  #:use-module ((playnet scope live) #:select (agent->subsistence-ctx recipe-derived-contains reserve-controls scope-labour?))
  #:use-module ((playnet scope snapshot) #:select (dedup-locations scope-locations->wire))
  #:use-module ((playnet solve engine) #:select (key-spec spec-base spec-owner))
  #:use-module ((playnet utils clock) #:select ((now . clock-now) instant->unix))
  #:use-module ((playnet vf facts rail) #:select (social-portions))
  #:use-module ((playnet vf formulas actions) #:select (committed-by-spec creating-actions using-up-actions))
  #:use-module ((playnet vf formulas flows) #:select (row-action row-effort row-figure row-id row-input-of row-note row-output-of row-place row-provider row-quantity row-run row-spec row-until row-when))
  #:use-module ((playnet vf schemas) #:select (agent-id agent-name agent-relationship-subject agent-type economic-resource-conforms-to economic-resource-onhand-quantity economic-resource-primary-accountable intent-finished intent-id measure-has-numerical-value measure-has-unit proposal-proposed-to recipe-flow-action recipe-flow-is-primary recipe-flow-resource-conforms-to recipe-flow-resource-quantity recipe-id recipe-primary-output recipe-process-id recipe-process-name recipe-process-sequence-group rented-frag-profile rented-frag-tip rented-goods))
  #:use-module ((playnet wire rows) #:select (with-context))
  #:use-module ((srfi srfi-1) #:select (delete-duplicates filter-map find last remove))
  #:export (scope-member-ids scope-members skill-holders willing-by-key process-output-spec
            recipe-producing recipe-yield plan-flow->wire plan-results->dial-plan solve-part
            scope-plan-wire matter-results->wire scope-matter-wire rented-controls scope-rented-goods
            scope-fragility-wire scope-reproduction-people location-slacks wire-number scope-credit->wire
            build-snapshot))

(define (scope-member-ids scope-root scope-id)
  "The ids of the agents with a relationship in SCOPE-ID, in the order the scope
   knows them (a member's colour on the page is its place in it)."
  (delete-duplicates
   (map agent-relationship-subject
        ($ ($ scope-root 'agent-store) 'relationships-in-scope scope-id))))

(define (scope-members scope-root scope-id)
  "The ids among `scope-member-ids` whose agent the agent store holds."
  (let ((as ($ scope-root 'agent-store)))
    (filter (lambda (id) ($ as 'get-agent id)) (scope-member-ids scope-root scope-id))))


;;; ── Willingness overlay (the offer-side: who could help, who's signalled) ──
;;; The solver-offers-first loop, surfaced on the read path with no re-solve:
;;; each work intent carries the candidate set (scope members holding the skill)
;;; and the willing 'race (workers who marked status=willing|invited|declined,
;;; persisted as oi|worker|skill|cell meta on the plan-store). The cell is
;;; location@0 — the same key the convex *willing?* gate reads, so the toggle
;;; round-trips and a later willing-only plan honours it.

(define (skill-holders obs labour?)
  "spec-id → list of agent-ids who hold it as a skill ER (onhand > 0): the
   roster's one reading of a held skill (LABOUR?, scope-labour? of the root —
   the same predicate skill-specs-for-agent reads), so a means a person holds
   never reads as a skill they have."
  (let ((tbl (make-hash-table)))
    (for-each
      (lambda (r)
        (let ((pa   (economic-resource-primary-accountable r))
              (spec (economic-resource-conforms-to r)))
          (when (and pa spec
                     (labour? spec)
                     (> (measure-has-numerical-value
                          (economic-resource-onhand-quantity r)) 0))
            (hash-set! tbl spec (cons pa (hash-ref tbl spec '()))))))
      ($ obs 'all-resources))
    tbl))

(define (willing-by-key ps)
  "(skill . cell) → list of (worker . status) from oi| willingness meta."
  (let ((tbl (make-hash-table)))
    (for-each
      (lambda (kv)
        (let ((parts (string-split (car kv) #\|)))     ; oi | worker | skill | cell
          (when (and (= (length parts) 4) (string=? (car parts) "oi"))
            (let ((status (assq-ref (cdr kv) 'status)))
              (when status
                (let ((k (cons (list-ref parts 2) (list-ref parts 3))))
                  (hash-set! tbl k (cons (cons (list-ref parts 1) status)
                                         (hash-ref tbl k '())))))))))
      ($ ps 'all-meta))
    tbl))

;;; ── Snapshot builder (read path) ─────────────────────────────────────

;;; ── The plan, for the dial's plan section ────────────────────────────────
;; Honest coverage WITHOUT solver surgery: the cached solve gives `material`
;; (produced per spec) and we know the `demand` it solved for (target per spec),
;; so per-need fill = produced/target — exactly what mean-fill computes. `work`
;; effort, attributed to the spec each process outputs, is the labour ledger.

;; the primary-output spec of a recipe-process (its deliverable), or #f
(define (process-output-spec rs proc-id)
  (and proc-id
       (let ((outs (cdr ($ rs 'flows-for-process proc-id))))
         (and (pair? outs)
              (recipe-flow-resource-conforms-to
               (or (find recipe-flow-is-primary outs) (car outs)))))))

;; the recipe whose declared deliverable is SPEC, or #f
(define (recipe-producing rs spec)
  (and spec (find (lambda (r) (equal? (recipe-primary-output r) spec))
                  ($ rs 'all-recipes))))

;; per-run yield of a recipe: the primary-output quantity of its terminal step
(define (recipe-yield rs rcp)
  (let* ((procs (sort ($ rs 'processes-for-recipe (recipe-id rcp))
                      (lambda (a b) (< (or (recipe-process-sequence-group a) 0)
                                       (or (recipe-process-sequence-group b) 0)))))
         (outs  (and (pair? procs)
                     (cdr ($ rs 'flows-for-process (recipe-process-id (last procs)))))))
    (and (pair? outs)
         (measure->qty (recipe-flow-resource-quantity
                        (or (find recipe-flow-is-primary outs) (car outs)))))))

;; ── the plan-flow face: the solve's ACTUAL production decomposition ──────────
;; One PRODUCTION per recipe-process that RAN — its real produced good + quantity,
;; the real goods & labour it consumed (the LP's chosen allocation, so a good made
;; by two processes surfaces as two productions: the genuine split), the means it
;; uses, and the period it runs in. Built from the same produce/consume/work
;; commitments the matter Sankey reads — the real flow graph, not a reconstruction
;; from recipe topology. Pure over the solve alist, like plan-results->dial-plan.
(define (plan-flow->wire rs material work)
  (define (nm spec) (or (lookup-spec-name rs spec) spec))
  (let ((prod  (make-hash-table))     ; pid → (cons out-spec qty-summed)
        (draw  (make-hash-table))     ; pid → hash spec→qty (goods consumed)
        (lab   (make-hash-table))     ; pid → labour-hours summed
        (per   (make-hash-table))     ; pid → earliest period, or #f
        (order '()))                  ; pids, first-seen order
    (define (see! pid)      (unless (member pid order) (set! order (cons pid order))))
    (define (note-per! pid w) (when (and w (not (hash-ref per pid #f))) (hash-set! per pid w)))
    (for-each
     (lambda (m)
       (let ((act (row-action m)) (spec (row-spec m))
             (qty (or (row-quantity m) 0)) (w (row-when m))
             (op (row-output-of m)) (ip (row-input-of m)))
         (cond
          ((and (memq act creating-actions) op (string? spec))
           (see! op) (note-per! op w)
           (let ((cur (hash-ref prod op #f)))
             (hash-set! prod op (cons spec (+ (if cur (cdr cur) 0) qty)))))
          ((and (memq act using-up-actions) ip (string? spec))
           (see! ip) (note-per! ip w)
           (let ((h (or (hash-ref draw ip #f)
                        (let ((n (make-hash-table))) (hash-set! draw ip n) n))))
             (hash-set! h spec (+ (hash-ref h spec 0) qty)))))))
     material)
    (for-each
     (lambda (wc)
       (let ((ip (row-input-of wc)) (eff (or (row-effort wc) 0)) (w (row-when wc)))
         (when ip (see! ip) (note-per! ip w)
               (hash-set! lab ip (+ (hash-ref lab ip 0) eff)))))
     work)
    (filter-map
     (lambda (pid)
       (let ((out (hash-ref prod pid #f)))
         (and out
              (let* ((rp    ($ rs 'get-recipe-process pid))
                     (flows (and rp ($ rs 'flows-for-process pid)))
                     (uses  (if (pair? flows)
                                (filter-map (lambda (f)
                                              (and (eq? (recipe-flow-action f) 'use)
                                                   (recipe-flow-resource-conforms-to f)))
                                            (car flows)) '()))
                     (ounit (and (pair? flows)
                                 (let ((pf (find recipe-flow-is-primary (cdr flows))))
                                   (and pf (recipe-flow-resource-quantity pf)
                                        (measure-has-unit (recipe-flow-resource-quantity pf))))))
                     (dh    (hash-ref draw pid #f))
                     (goods (if dh (map (lambda (kv)
                                          `((spec . ,(nm (car kv))) (id . ,(car kv))
                                            (q . ,(exact->inexact (cdr kv))) (action . "consume")))
                                        (hash-map->list cons dh)) '()))
                     (means (map (lambda (s) `((spec . ,(nm s)) (id . ,s) (action . "use"))) uses))
                     (lh    (hash-ref lab pid 0))
                     (work* (if (> lh 0)
                                (list `((spec . "labour") (q . ,(exact->inexact lh)) (action . "work"))) '()))
                     (w     (hash-ref per pid #f)))
                `((id     . ,pid)
                  (spec   . ,(nm (car out)))
                  (specId . ,(car out))
                  (name   . ,(or (and rp (recipe-process-name rp)) pid))
                  (q      . ,(exact->inexact (cdr out)))
                  ,@(if (string? ounit) `((u . ,ounit)) '())
                  ,@(if w `((period . ,(if (number? w) (number->string w) w))) '())
                  (in     . ,(append goods means work*)))))))
     (reverse order))))

;; (demand . solve-alist) → the dial's plan shape: a ledger + per-need rows
;; (each demanded spec, its met fraction, the recipe that fills it, runs, labour).
(define (plan-results->dial-plan scope-root demand alist)
  (let* ((rs       ($ scope-root 'recipe-store))
         (material (or (assq-ref alist 'material) '()))
         (work     (or (assq-ref alist 'work) '()))
         (social   (or (assq-ref alist 'social) '()))
         (overall  (or (assq-ref alist 'met) 0))
         (targets  (make-hash-table))
         ;; produced per spec (the produce-side material flows), the tally's
         (produced (committed-by-spec material creating-actions))
         (labour   (make-hash-table)))
    ;; target per spec (summed over places/periods): the caller's what-if
    ;; rows (spec place period qty), else the rows the solve RAN ON — the
    ;; alist's `demand`, keyed "spec#place@t" (live.scm plan-results->alist —
    ;; the caller's rows AND the demand fold's, which the current-plan
    ;; solve caches under an empty caller demand)
    ;; The alist's rows are the SUPERSET (the fold's plus the caller's, merged
    ;; before the solve), so they win whenever the solve published them; the
    ;; caller's rows stand in for an alist that carries none (an older cached
    ;; row, a test's hand-built alist).
    (let ((ran-on (or (assq-ref alist 'demand) '())))
      (if (pair? ran-on)
          (for-each (lambda (d)
                      (when (and (pair? d) (string? (car d)) (number? (cdr d)))
                        (let ((spec (key-spec (car d))))
                          (hash-set! targets spec (+ (hash-ref targets spec 0) (cdr d))))))
                    ran-on)
          (for-each (lambda (d)
                      (let ((spec (and (pair? d) (list-ref d 0)))
                            (t (and (>= (length d) 4) (list-ref d 3))))
                        (when (and spec t)
                          (hash-set! targets spec (+ (hash-ref targets spec 0) t)))))
                    demand)))
    ;; labour per spec: each work commitment's effort → the spec its process makes
    (for-each (lambda (w)
                (let ((out (process-output-spec rs (row-input-of w)))
                      (eff (or (row-effort w) 0)))
                  (when out (hash-set! labour out (+ (hash-ref labour out 0) eff)))))
              work)
    (let ((needs
           (map (lambda (kv)
                  (let* ((spec (car kv)) (target (cdr kv))
                         (prod (or (assoc-ref produced spec) 0))
                         (met  (if (> target 0) (min 1.0 (/ prod target)) 1.0))
                         ;; an owned good ("meal~aid") is delivered by a
                         ;; zero-labour column off the scope's own good — the
                         ;; recipe, the runs and the labour all live on the
                         ;; BASE spec, so the join reads across the delivery
                         (base (spec-base spec))
                         (rcp  (recipe-producing rs base))
                         (yld  (and rcp (recipe-yield rs rcp)))
                         (prod-b (if (equal? base spec) prod (or (assoc-ref produced base) prod)))
                         (runs (if (and yld (> yld 0)) (inexact->exact (round (/ prod-b yld))) 0)))
                    `((id       . ,spec)
                      (label    . ,(let ((b (spec-base spec))) (or (lookup-spec-name rs b) b)))
                      ;; whose good this is — a want stated for oneself is
                      ;; delivered on the citizen's own good ("spec~aid")
                      ,@(let ((o (spec-owner spec))) (if o `((for . ,(cdr o))) '()))
                      (met      . ,(exact->inexact met))
                      (want     . ,(exact->inexact target))   ; the scope's aggregate DEMAND for this need
                      (recipeId . ,(if rcp (recipe-id rcp) ""))
                      (runs     . ,runs)
                      (labourH  . ,(let ((h (hash-ref labour spec 0)))
                                     (if (zero? h) (hash-ref labour base 0) h))))))
                (hash-map->list cons targets))))
      `((scope    . ,($ scope-root 'name))
        (coverage . ,(exact->inexact overall))
        ;; the solve's verdict, carried beside the coverage it qualifies: a
        ;; coverage read off an infeasible solve describes provisioning drawn
        ;; from stock nobody has (live.scm `feasible`).
        (feasible . ,(let ((f (assq-ref alist 'feasible)))
                       (cond ((eq? f #f) 'no) ((eq? f #t) 'yes) (else 'unknown))))
        ;; the discrete layer's verdict, when a search ran: how many batch keys
        ;; (2^keys configurations), how many nodes it solved, whether the tree
        ;; was exhausted (certified) or the gap it left, and the recourse columns
        ;; a two-stage solve kept relaxed. Absent when nothing was declared.
        ,@(let* ((cert (assq-ref alist 'certificate))
                 (d (and (list? cert) (assq-ref cert 'discrete))))
            (if (list? d)
                `((discrete . ((keys . ,(or (assq-ref d 'keys) 0))
                               (nodes . ,(or (assq-ref d 'nodes) 0))
                               (budget . ,(or (assq-ref d 'budget) 0))     ; the node budget this solve ran under — bound when uncertified
                               (certified . ,(if (assq-ref d 'certified?) 'yes 'no))
                               (gap . ,(or (assq-ref d 'gap) 0.0))
                               (recourseRelaxed . ,(or (assq-ref d 'recourse-relaxed) '())))))
                '()))
        ;; where each mover stands: mover → cell → presence (solve-report `placement`)
        ,@(let ((p (assq-ref alist 'placement))) (if p `((placement . ,p)) '()))
        (labourH  . ,(or (assq-ref social 'direct-labour) 0))
        (produced . ,(map (lambda (kv) `((spec . ,(or (lookup-spec-name rs (car kv)) (car kv)))
                                         (q . ,(cdr kv))))
                          produced))
        (needs    . ,needs)
        ;; THE PORTION KEPT BACK, per good (rail.scm social-portion): what the
        ;; scope's own processes consume this horizon plus the reserve — the
        ;; deductions before anything is shared out; the shop's social view
        ;; shows it beside what was asked and what is left over
        (kept     . ,(map (lambda (kv) `((spec . ,(car kv)) (name . ,(or (lookup-spec-name rs (car kv)) (car kv))) (q . ,(cdr kv))))
                          (filter (lambda (kv) (> (cdr kv) 0)) (social-portions rs))))
        ;; the solve's ACTUAL production decomposition (the plan-flow face): real
        ;; per-process produce/consume/labour flows, the LP's chosen allocation.
        (flow     . ,(plan-flow->wire rs material work))
        ;; THE SCHEDULE: the same commitments with their SPACE-TIME coordinates
        ;; kept — who works what where on which clock moment, and each material
        ;; flow at its own cell (a haul's pickup at the origin, its dropoff at
        ;; the destination; a spanning run's output at its ARRIVAL band). The
        ;; WHAT EACH ACT NEEDS — and, for the acts that are absent, why.
        ;;
        ;; The fields are named `proc`, `place` and `when` because that is what
        ;; a schedule row beside it calls the same three facts, and a commitment
        ;; takes its `when` from the very period-span this `when` is: the join a
        ;; reader writes is equality on identically-named fields, with nothing to
        ;; convert and no period arithmetic to get wrong.
        ;;
        ;; Rows for acts that never ran carry `why` and appear in no schedule —
        ;; that is the point of them, and a reader must treat a MISSING row as
        ;; "not published for this act" rather than as "this act needs nothing".
        (requires .
          ,(map (lambda (r)
                  `((proc  . ,(assq-ref r 'process))
                    (place . ,(assq-ref r 'place))
                    (when  . ,(assq-ref r 'begin))
                    (until . ,(row-until r))
                    ,@(let ((w (assq-ref r 'why))) (if w `((why . ,w)) '()))
                    (needs . ,(map (lambda (n)
                                     (let ((nm (assq-ref n 'name)))
                                       `((kind  . ,(assq-ref n 'kind))
                                         (name  . ,nm)                    ; the id, kept: labels are not join keys
                                         (label . ,(or (lookup-spec-name rs nm) nm))
                                         (qty   . ,(assq-ref n 'qty))
                                         (unit  . ,(assq-ref n 'unit))
                                         (met   . ,(assq-ref n 'met)))))
                                   (or (assq-ref r 'needs) '())))))
                (or (assq-ref alist 'requires) '())))
        ;; aggregate views above sum these away; the schedule board reads them
        ;; as they are. Rows are slimmed for the wire and labels resolved.
        (schedule .
          ((work . ,(map (lambda (w)
                           `((who    . ,(or (row-provider w) ""))
                             (skill  . ,(let ((sk (row-spec w)))
                                          (or (lookup-spec-name rs sk) sk "")))
                             (effort . ,(or (row-effort w) 0))
                             (place  . ,(or (row-place w) ""))
                             (when   . ,(or (row-when w) ""))
                             (until  . ,(or (row-until w) ""))
                             (proc   . ,(or (row-input-of w) ""))))
                         work))
           (material . ,(map (lambda (m)
                               `((id      . ,(or (row-id m) ""))          ; the plan's own row id: what a confirmation names
                                 (action . ,(row-action m))
                                 (spec-id . ,(or (row-spec m) ""))
                                 (spec   . ,(let ((sp (row-spec m)))
                                              (or (lookup-spec-name rs sp) sp "")))
                                 (qty    . ,(or (row-figure m) 0))   ; a use row's figure is its hours
                                 (place  . ,(or (row-place m) ""))
                                 (when   . ,(or (row-when m) ""))
                                 (proc   . ,(or (row-run m) ""))
                                 (note   . ,(or (row-note m) ""))))
                             material))))))))
;; one part of a cached solve ((demand . plan), the service's last-solve-ref): the plan's KEY, or none
(define (solve-part cached key)
  (or (and cached (assq-ref (cdr cached) key)) '()))
(define* (scope-plan-wire scope-root cached #:optional (stale? #f))
  (let ()
    (and cached
         (let ((p (plan-results->dial-plan scope-root (car cached) (cdr cached))))
           ;; stale-while-revalidating: this plan predates a decision whose
           ;; re-solve has not landed yet — shown, and said to be old
           (if stale? (acons 'stale #t p) p)))))

;;; ── The substance-flow lens, for the matter face ─────────────────────────
;; Lift a solve's PRODUCT flows to SUBSTANCE flows and shape them as the matter
;; Sankey's {substances, nodes, links}. Every material commitment carries the
;; producing (output-of) or consuming (input-of) process, so we rebuild a
;; process→process graph: a spec produced by P and consumed by Q flows P→Q,
;; apportioned by each side's share. Produced-but-unconsumed exits to a sink:
;; spec; consumed-but-unproduced enters from a source:spec. Each link's product
;; mass is lifted to conserved elements through knowledge/catalogues/substances.scm's
;; `contains` closure; the browser colours bands by element and reads the rift
;; (the share reaching a sink) off the graph. Pure over the solve alist, like
;; plan-results->dial-plan — so it is testable without the wire.
;; Pure ValueFlows: a solve's substance flows ARE produce/consume events over
;; substance EconomicResources. `produce` links a process (its output-of) TO a
;; resource (raising its quantity); `consume` links a resource TO a process (its
;; input-of, lowering it). So the graph is the native VF shape — process ↔
;; resource — and there is nothing to invent: no pools, sinks, sources, or
;; matching. A resource only produced-into rises; only consumed-from falls; both
;; is a cycle. The RIFT is just the substance resources whose quantity DRIFTS:
;; the environment's stocks (soil, air, water) that we fail to keep balanced.
(define (matter-results->wire scope-root alist)
  (let* ((rs    ($ scope-root 'recipe-store))
         (comp  (composition-in-force (recipe-derived-contains rs) *contains*))  ; one precedence, named
         (mat   (or (assq-ref alist 'material) '()))
         (nodes (make-hash-table))     ; id → label  (kind derived from the id)
         (links (make-hash-table))     ; (from . to) → ((element . mass) …)
         (drift (make-hash-table)))    ; resource-id → ((element . produced−consumed) …)
    (define (spec-name spec) (or (lookup-spec-name rs spec) spec))
    (define (proc-label pid)
      (or (and pid (let ((rp ($ rs 'get-recipe-process pid))) (and rp (recipe-process-name rp))))
          pid))
    (define (res-id spec) (string-append "res:" spec))
    (define (touch! id label) (unless (hash-ref nodes id #f) (hash-set! nodes id label)))
    (define (bump! tbl key content sign)
      (let ((bag (hash-ref tbl key '())))
        (for-each (lambda (p)
                    (let ((c (assoc (car p) bag)))
                      (set! bag (if c (map (lambda (q) (if (eq? q c) (cons (car p) (+ (cdr c) (* sign (cdr p)))) q)) bag)
                                      (cons (cons (car p) (* sign (cdr p))) bag)))))
                  content)
        (hash-set! tbl key bag)))
    ;; one VF event → one link (process↔resource) + the resource's running drift
    (define (event! proc spec qty produce?)
      (let ((content (and proc (> qty 0) (substance-content spec qty #:contains comp))))
        (when (pair? content)
          (let ((res (res-id spec)) (proc-id (or proc "·")))
            (touch! res (spec-name spec)) (touch! proc-id (proc-label proc))
            (bump! links (if produce? (cons proc-id res) (cons res proc-id)) content 1)
            (bump! drift res content (if produce? 1 -1))))))   ; produce raises, consume lowers
    (for-each (lambda (m)
                (let ((act (row-action m)) (spec (row-spec m))
                      (qty (or (row-quantity m) 0)))
                  (cond ((memq act creating-actions) (event! (row-output-of m) spec qty #t))
                        ((memq act using-up-actions) (event! (row-input-of m)  spec qty #f)))))
              mat)
    (let ((link-list (map (lambda (kv)
                            `((from . ,(caar kv)) (to . ,(cdar kv))
                              (flows . ,(map (lambda (p) (cons (string->symbol (car p)) (cdr p))) (cdr kv)))))
                          (hash-map->list cons links))))
      (and (pair? link-list)
           `((substances . ,(substances->wire))
             (nodes . ,(map (lambda (kv)
                              (let* ((id (car kv)) (resource? (string-prefix? "res:" id))
                                     (spec (and resource? (substring id 4))))
                                `((id . ,id) (label . ,(cdr kv))
                                  (kind . ,(if resource? "resource" "process"))
                                  ,@(if resource?
                                        ;; an environment stock (soil/air/water) — its drift IS
                                        ;; the rift; the productive economy's own resources aren't.
                                        `((env   . ,(environment-spec? spec))
                                          (drift . ,(map (lambda (p) (cons (string->symbol (car p)) (cdr p)))
                                                         (hash-ref drift id '()))))
                                        '()))))
                            (hash-map->list cons nodes)))
             (links . ,link-list))))))

(define (scope-matter-wire scope-root cached)
  (and cached (matter-results->wire scope-root (cdr cached))))

;;; ── the fragility face wire ─────────────────────────────────────────────────
;; The federation's registered fragilities as the wheel reads them: each
;; catalogue agent with its display fields and its LIVE normalized slack s — how
;; close THIS federation's own draw sits to the agent's precautionary tip. The
;; draw of each frag-capped spec is summed from the solve's material events (the
;; same source the matter wire reads); catalogue->wire (eco-catalogue.scm) turns
;; it into s = 1 − draw/tip with the SAME frag math the barrier uses. Registering
;; a new agent makes it appear here — the registry is the source of truth. #f
;; until a solve has run (day-boot falls back to the committed witness snapshot).
;; The scope's RENTED fragilities as the wheel reads them — the tenure family
;; beside the ecological boundaries. Every resource the scope holds under SPLIT
;; tenure (custody here, rights elsewhere — a rented social-media channel, a
;; loaned-in means) becomes a control on its Svc| service good, slack s = 1−draw/tip
;; from the shared %rented-frag-profile — the SAME frag math the barrier and the
;; ecological wheel use, so a rented wedge reads on the same dial as a planetary
;; boundary. DRAW-OF reads the last solve's per-spec draw (0 ⇒ present but not yet
;; leaned on ⇒ s≈1).
;;
;; GOODS is the union of two sources, because rented tenure arises two ways:
;;   • STORED on the observer — a comms channel account (custody=scope, rights=platform);
;;   • PROJECTED per-solve — a commune's socialized means (custody=commune, rights=owner),
;;     which live only in plan-commune-scope's custody projection and are surfaced back
;;     through the solve alist's `rented-goods`. Deduped, so the same good counts once.
(define (rented-controls goods draw-of)
  ;; profile PER SPEC (rented-frag-profile, schemas.scm): the shared default
  ;; for most kinds, the steeper housing rows for the kinds whose recall is a
  ;; displacement — one table, read here and by the barrier alike.
  (map (lambda (good)                                ; "Svc|<spec>"
         (let* ((spec (substring good 4))            ; the bare channel/durable spec
                (tip  (rented-frag-tip spec))
                (w    (list-ref (rented-frag-profile spec) 3))
                (draw (draw-of spec))
                (s (max 1e-3 (min 1.0 (if (> tip 0.0) (/ (- tip draw) tip) 1.0)))))
             (list (cons 'spec good) (cons 'kind "rented")
                   (cons 'control spec) (cons 'group "rented")
                   (cons 'unit "draws") (cons 'w w)
                   (cons 'source "held under another's rights — revocable custody (deplatform / owner-recall)")
                   (cons 'current draw) (cons 'tip tip) (cons 's s))))
       goods))

;; the rented Svc| goods for a scope: STORED loaned-in resources on the observer
;; (comms channels) ∪ the last solve's PROJECTED `rented-goods` (socialized means).
(define (scope-rented-goods scope-root cached-alist)
  (let ((stored    (rented-goods ($ ($ scope-root 'observer) 'all-resources)))
        (projected (or (and (pair? cached-alist) (assq-ref cached-alist 'rented-goods)) '())))
    (delete-duplicates (append stored projected))))

(define (scope-fragility-wire scope-root cached)
  (let ()
    (and cached
         (let ((draws (make-hash-table)))
           (for-each (lambda (m)
                       (let ((spec (row-spec m)) (qty (or (row-quantity m) 0)))
                         (when (string? spec)
                           (hash-set! draws spec (+ (hash-ref draws spec 0) (abs qty))))))
                     (solve-part cached 'material))
           `((source . "the federation's registered fragilities — tension-registry / eco-catalogue.scm")
             ;; the commune's REAL people (reproduction of labour-power) — real
             ;; person-agents, their subsistence attributes from classified-as, and
             ;; their INTAKE read off the last plan's per-person nutrient production.
             ;; The dial uses these instead of its demo POPULATION when present; the
             ;; browser computes the floors/slack itself (nutrition.js == catalogue).
             (people . ,(scope-reproduction-people scope-root (cdr cached)))
             (controls . ,(let ((draw-of (lambda (spec) (hash-ref draws spec 0.0))))
                             (append (catalogue->wire *planetary-catalogue* draw-of)
                                     (rented-controls (scope-rented-goods scope-root (cdr cached)) draw-of)
                                     ;; the calamity reserves the last plan held — the tab, as wedges
                                     (reserve-controls (or (assq-ref (cdr cached) 'reserves) '()))))))))))

;; project the scope's person-agents as the fragility face reads them (POPULATION
;; shape): attributes via agent->subsistence-ctx, intake from the plan's material
;; (per-person nutrient production, spec "nutrient|pid"). #f when the scope has no
;; people, so the dial keeps its demo cohort.
(define (scope-reproduction-people scope-root solve-alist)
  (let* ((as ($ scope-root 'agent-store))
         (people (filter (lambda (a) (eq? (agent-type a) 'person)) ($ as 'all-agents)))
         (intake-of
          (lambda (pid)
            (let ((sfx (string-append "|" pid)))
              (filter-map (lambda (p)
                            (let ((spec (car p)))
                              (and (string? spec) (string-suffix? sfx spec)
                                   (cons (substring spec 0 (- (string-length spec) (string-length sfx)))
                                         (abs (cdr p))))))
                          (committed-by-spec (or (assq-ref solve-alist 'material) '()) creating-actions))))))
    (and (pair? people)
         (map (lambda (a)
                (let ((ctx (agent->subsistence-ctx a)) (pid (agent-id a)))
                  `((id . ,pid) (name . ,(or (agent-name a) pid))
                    (sex . ,(assq-ref ctx 'sex)) (age . ,(assq-ref ctx 'age))
                    (region . ,(assq-ref ctx 'region)) (pregnant . ,(assq-ref ctx 'pregnant))
                    (lactating . ,(assq-ref ctx 'lactating)) (labour . ,(assq-ref ctx 'labour-hours))
                    (intake . ,(intake-of pid)))))
              people))))

;; ── per-LOCATION demand shortfall, as a slack s = met∕want ∈ (0,1] ──────────
;; The truest reading of "social-desire, in a place": how much of what was
;; WANTED there the last solve actually DELIVERED. want is the demand summed by
;; place (demand tuples are (spec place period qty), demand->keyed); met is the
;; produce-side material flow at that at-location. s = min(1, met∕want) — 1
;; whole, → 0 starved. The dial's earth face folds these LEAF slacks up the
;; containment tree by geometric mean (worst-off-leaning), so each container is
;; tinted by the desire left unmet within it (app/tabs/containers.js). Returns
;; a hashtable place-id → slack (only places that carried demand), or #f before
;; the first solve — a place with no entry reads as whole.
(define (location-slacks cached)
  (let ()
    (and cached
         (let ((want (make-hash-table)) (met (make-hash-table)) (out (make-hash-table)))
           (for-each (lambda (d)                         ; demand: (spec place period qty)
                       (when (and (list? d) (>= (length d) 4) (string? (list-ref d 1)))
                         (let ((place (list-ref d 1)) (q (or (list-ref d 3) 0)))
                           (hash-set! want place (+ (hash-ref want place 0) q)))))
                     (car cached))
           (for-each (lambda (m)                         ; produced flows, by at-location
                       (when (memq (row-action m) creating-actions)
                         (let ((place (row-place m)) (q (or (row-quantity m) 0)))
                           (when (string? place)
                             (hash-set! met place (+ (hash-ref met place 0) q))))))
                     (solve-part cached 'material))
           (hash-for-each (lambda (place w)
                            (when (> w 0)
                              (hash-set! out place (min 1.0 (/ (hash-ref met place 0.0) w)))))
                          want)
           out))))   ; populate at module load; best-effort, no-op if absent


;; The fold keeps hours exact (a fraction of whole hours is an exact ratio such as
;; 4/3); the wire carries numbers the syrup encoder can write, so an exact ratio
;; leaves as an inexact number where the credit standing is read.
(define (wire-number x)
  (if (and (number? x) (exact? x) (not (integer? x))) (exact->inexact x) x))
(define* (scope-credit->wire scope-root aid #:optional (roots (list scope-root)))
  "The acting citizen's live credit standing — the numbers the shop face
   renders (playnet.typ §The credit identity). Everything is DERIVED at
   read time from the observer's event log + the elastic account layer;
   nothing here is a stored balance.
     gross     — validated work hours (the earn side, ledger-gross)
     claimed   — hours drawn as individually-claimable transfers
     drawable  — elastic purchasing power: contribution by ability +
                 citizenship·f − claimed (global-effective-balance), read over
                 ROOTS: every scope the person has credit at, the same reading
                 the claim guard admits against
     capacity  — the same before subtracting claimed (the bar's full width)
     pool      — K: embodied labour in the scope's unclaimed claimable stock
     voice     — consumer voice v_p^cons (share of the pool, sums to 1)
     free-time — social free time f from the last plan solve
     pending   — hours in the validation window (observer pending-gross):
                 diffuse work the scope's silence vests at the lapse"
  (catch #t
    (lambda ()
      (let* ((obs   ($ scope-root 'observer))
             (gross   (wire-number ($ obs 'validated-gross aid #f)))
             (balance (wire-number ($ obs 'credit-balance aid))))
        `((gross     . ,gross)
          (claimed   . ,(max 0 (- gross balance)))
          (drawable  . ,(global-effective-balance aid roots))
          (capacity  . ,(global-total-claim-capacity aid roots))
          (pool      . ,($ ($ scope-root 'account-store) 'embodied-labor-in-pool))
          (voice     . ,(consumer-voice aid roots))
          (free-time . ,(current-social-free-time))
          (pending   . ,(wire-number ($ obs 'pending-gross aid))))))
    (lambda args
      (pk 'scope-credit->wire-failed aid args)
      #f)))

(define* (build-snapshot scope-root scope-id plan-id #:optional (acting-aid #f)
                         #:key (extra-locations '()) (recipe-responses '()) (credit-roots #f)
                              (cached #f) (stale? #f))
  (let* ((rs   ($ scope-root 'recipe-store))
         (as   ($ scope-root 'agent-store))
         (obs  ($ scope-root 'observer))
         (ps   ($ scope-root 'plan-store))
         (als  ($ scope-root 'alert-store))
         (preg ($ scope-root 'process-registry))
         ;; a member's PAYOUT intents (destination addresses) are theirs
         ;; alone: my-payouts answers the member, the snapshot that every
         ;; browser in the scope receives carries none of them
         ;; an offer-backing intent (offer:…, offers.scm offer-work) is the
         ;; bounded rung's hold — it reaches exactly its person through the
         ;; PROPOSALS arm's proposed-to filter, and riding the open-intents
         ;; arm too would surface every directed offer to the whole scope
         (offer-intent? (lambda (i)
                          (string-prefix? "offer:" (or (intent-id i) ""))))
         (intents-raw (remove (lambda (i) (or (intent-private? i)
                                              (offer-intent? i)))
                              (if plan-id
                                  ($ ps 'intents-for-plan plan-id)
                                  ($ ps 'all-intents))))
         (cmts        (if plan-id
                          ($ ps 'commitments-for-plan plan-id)
                          ($ ps 'all-commitments)))
         (nowu        (instant->unix (clock-now)))
         ;; standing by the record's own terms: unfinished AND its window —
         ;; where it names one — not wholly passed. Yesterday's laid shift is
         ;; dead on the wire the moment its day ends, whether or not a solve
         ;; ran since to clear it; an undated need stands, which is what makes
         ;; it standing.
         (open-intents (filter (lambda (i) (and (not (intent-finished i))
                                                (not (intent-window-passed? i nowu))))
                               intents-raw))
         (member-ids (scope-member-ids scope-root scope-id))
         (alerts  ($ als 'of-kind 'unmatched-role))
         ;; willingness overlay tables — one scan each, shared across intents
         (holders (skill-holders obs (scope-labour? scope-root)))
         (willing (willing-by-key ps))
         ;; the standing solve's labour pulls, the plan's pull on each open shift
         (pulls   (or (and cached (pair? cached) (assq-ref (cdr cached) 'labour-pulls)) '()))
         ;; what the record rows join through (record-rows.scm): the reply carries it
         (ctx     (record-context scope-id rs as obs ps preg #:holders holders #:willing willing #:pulls pulls
                                  #:member-ids member-ids #:responses recipe-responses)))
    (with-context
    `((scope-id . ,scope-id)
      (scope-name . ,($ scope-root 'name))
      (members . ,(filter-map (lambda (id) ($ as 'get-agent id)) member-ids))
      ;; the scope's known places — for the location picker (expected trajectory)
      ;; venue coordinates are public (only the USER's own position is
      ;; coarsened); the dial resolves a work-intent's at-location to a
      ;; map pin through these.
      ;; contained-in carries the containment FOREST (room ⊂ venue ⊂ commune ⊂
      ;; …); `slack` is the per-place demand shortfall (met∕want) from the last
      ;; solve. The dial's earth face draws the forest as nested regions and
      ;; folds the leaf slacks up it (geomean), tinting each container by the
      ;; social-desire left unmet within it (app/tabs/containers.js).
      ;; the viewer's own places, UNIONED with any federation siblings' (a
      ;; commune that shares this scope's top-level federation node). Viewing one
      ;; commune thus shows the whole `fed ⊃ {commune-a ⊃ venue-a, commune-b ⊃
      ;; venue-b}` tree, so the overlay greens across the federation as a boundary
      ;; flow fills a deficit commune. extra-locations is #f/'() for a lone scope.
      (locations . ,(dedup-locations
                      (append (scope-locations->wire scope-root (location-slacks cached))
                              (or extra-locations '()))))
      (plans . ,($ ps 'all-plans))
      ;; the scope's recipe topology — the dial's plan drill-down reads this to
      ;; show how each need is provisioned (need ↦ recipe ↦ work).
      (recipes . ,($ rs 'all-recipes))
      ;; the scope's on-hand stock (inventory tab) — real economic resources by
      ;; rail/where/keeps, replacing the browser's DEMO_STOCK fallback. #f (⇒ demo)
      ;; when the scope carries no resources yet.
      (inventory . ,(scope-inventory-wire scope-root scope-id))
      ;; the most recent solve's coverage, if any — per-need fill, the recipe
      ;; filling it, and the labour ledger. #f until a solve has run this session.
      (plan . ,(scope-plan-wire scope-root cached stale?))
      ;; the same solve as a SUBSTANCE-flow graph (the matter face): product
      ;; flows lifted to conserved elements via the contains relation. #f until
      ;; a solve has run. day-boot stringifies the masses → window.__matterFlow.
      (matter . ,(scope-matter-wire scope-root cached))
      ;; the federation's registered fragilities + their live slack (the fragility
      ;; face). #f until a solve; it reaches the app through the scope snapshot (the "fragility" topic).
      (fragility . ,(scope-fragility-wire scope-root cached))
      (intents . ,open-intents)
      ;; a count the custodian is not to read ahead is its counter's alone
      ;; until its window opens (counting.scm regimes)
      (commitments . ,(filter (lambda (c) (count-readable? c acting-aid nowu)) cmts))
      ;; social invites directed at the asking agent — proposals whose
      ;; proposed-to whitelist includes them. The dial shows these as invited
      ;; (yellow, respond-only) events; accept routes to accept-invite.
      ;; …and only proposals that still ASK something (proposal-stands?):
      ;; the acceptance window open, the published intent still an intent
      ;; with its own window open. A record outliving its question is
      ;; history — the meta rail keeps it; the wire does not.
      (proposals . ,(if acting-aid
                        (filter-map
                         (lambda (p)
                           (let ((pt (proposal-proposed-to p)))
                             (and (pair? pt) (member acting-aid pt)
                                  (proposal-stands? p ps nowu)
                                  p)))
                         ($ ps 'all-proposals))
                        '()))
      ;; the asking citizen's live credit standing (shop face header);
      ;; #f for anonymous snapshots
      (credit . ,(and acting-aid (scope-credit->wire scope-root acting-aid (or credit-roots (list scope-root)))))
      ;; the LIVED layer: every economic event the observer holds — what
      ;; actually happened, beside the plan that asked for it. Both ends of a
      ;; move ride, so the map can draw the journey.
      (events . ,(or ($ obs 'all-events) '()))
      (alerts . ,alerts)
      ;; the escalation door's reading, per floor-defending process: rung,
      ;; days-to-forcing, the branches' stretch — the dial's data
      (floors . ,(floors->wire ps)))
     ctx)))