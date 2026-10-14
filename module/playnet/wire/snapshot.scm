;;; wire/snapshot.scm — a scope's snapshot, as the page reads it.
;;;
;;; The planner answers `scope-snapshot` with alists in its own vocabulary; the
;;; page reads one JSON object (ui/app/seam.ts, ScopeSnapshot). The tables here
;;; are that reading, one per row, and the snapshot's own table is the door's
;;; reply, so a scope's snapshot leaves the planner finished; the page's spine
;;; (hoot/day-boot.scm) folds a person's memberships' snapshots into one with
;;; `fold-snapshots`. Plain Scheme with no planner behind it.

(define-module (playnet wire snapshot)
  #:use-module (playnet wire rows)
  #:use-module (srfi srfi-1)
  #:export (clock->wire
            arc->wire
            location->wire location-row
            plan-need->wire plan-need-row
            flow-in->wire flow-in-row
            flow-prod->wire flow-prod-row
            plan->wire plan-row plan-yield-row plan-kept-row plan-discrete-row
            %inv-resource-wire
            expected->wire
            inv-resource->wire inventory-resource-row
            %inv-spec-wire
            inv-spec->wire inventory-spec-row
            inventory->wire inventory-row
            %credit-wire
            credit->wire credit-row
            msym->str
            matter-sub->wire
            matter-node->wire
            matter-link->wire
            matter->wire
            fold-snapshots))

;; serialized with the KERI canonical-JSON writer (string keys, vectors
;; as arrays — times ride as hour+minute pairs).

;; readers a table's computed entries share: each names the key it reads, so
;; the row's maker admits it
(define (keyed key default) (cons key (lambda (row ctx) (alist-ref row key default))))
(define (listed key) (cons key (lambda (row ctx) (let ((v (alist-ref row key '()))) (and (list? v) v)))))
(define (text-only key) (cons key (lambda (row ctx) (let ((v (alist-ref row key #f))) (and (string? v) v)))))
(define (whole key default) (cons key (lambda (row ctx) (int-field row key default))))

;; the record's clock, only where the record STATED one — an absent clock
;; stays absent on the wire, and the dial renders the row undated-in-its-day
(define (clocked key default)
  (cons key (lambda (row ctx) (and (integer? (alist-ref row 'sh #f)) (int-field row key default)))))
(define %clock-entries
  `(("sh" ,(clocked 'sh 0) (omit-false int)) ("sm" ,(clocked 'sm 0) (omit-false int))
    ("eh" ,(clocked 'eh 10) (omit-false int)) ("em" ,(clocked 'em 0) (omit-false int))))
(define %clock-wire (wire-table 'clock #f %clock-entries))
(define (clock->wire rec) (wire-row* %clock-wire rec))

;; one recurrence arc (a record's window, a slot's) → wire: its days by name, and
;; the weeks of the month (1–5) and months (1–12) it names, left out where it names none
(define (named-list key) (cons key (lambda (a ctx) (let ((l (alist-ref a key #f))) (and (pair? l) l)))))
(define %arc-wire
  (wire-table 'arc #f
    `(("start" ,(text-only 'start) str) ("end" ,(text-only 'end) str)
      ("days" (days . ,(lambda (a ctx) (or ((cdr (listed 'days)) a ctx) '()))) (list str))
      ("weeks" ,(named-list 'weeks) (omit-false (list num)))
      ("months" ,(named-list 'months) (omit-false (list num))))))
(define (arc->wire a) (wire-row* %arc-wire a))

;; coords ride as numbers. contained-in carries the containment forest (room ⊂
;; venue ⊂ commune ⊂ …), drawn as nested desire regions (containers.js). The
;; boundary is the SpatialThing's EXTENT (schemas.scm): a GeoJSON-geometry JSON
;; string, opaque to the wire, which the dial parses and draws. slack is the
;; per-place demand shortfall met∕want.
(define %location-wire
  (wire-table 'location #f
    '(("id" id str) ("name" name str) ("lat" lat num) ("lng" long num)
      ("containedIn" contained-in opt-str) ("boundary" boundary opt-str)
      ;; what the place says about itself (a venue's access note, the sentence
      ;; that finds a box left under a bridge) and the address its namer gave
      ("note" note opt-str) ("address" address opt-str)
      ("slack" slack num))))
(define (location->wire s) (wire-row* %location-wire s))
(define location-row (row-maker %location-wire))

;; recipes ride the snapshot too — the dial's plan drill-down reads them; their tables
;; read the recipe records (doors/record-rows.scm).

;; the plan: real coverage from the most recent solve (or #f until one runs).
;; per-need met / coverage / labour are numbers; runs is an integer.
(define %plan-need-wire
  (wire-table 'plan-need #f
    `(("id" id str) ("label" label str)
      ;; whose good this is: a want stated for oneself is delivered on the
      ;; citizen's own good ("spec~aid"); absent on the scope's own rows
      ("for" for (omit-false str))
      ("met" met num)
      ("want" want num)                              ; the scope's aggregate demand → the wheel
      ("recipeId" recipeId str)
      ("runs" runs int)
      ("labourH" labourH num)
      ;; the hands raised for it in this snapshot: the willing race the reply's
      ;; context carries ((skill . cell) → ((worker . status) …), doors/record-rows.scm
      ;; record-context), counted over every cell on the need's bare spec — as
      ;; fresh as the day is, a hand raised since the solve ran still counts
      ("willing" ,(lambda (n ctx)
                    (let ((tbl (and ctx (alist-ref ctx 'willing)))
                          (base (let ((id (alist-ref n 'id)))
                                  (if (string? id) (car (string-split id #\~)) ""))))
                      (if (hash-table? tbl)
                          (let ((hands '()))
                            (hash-for-each (lambda (k v)
                                             (when (equal? (car k) base)
                                               (for-each (lambda (ws)
                                                           (unless (eq? (cdr ws) 'declined)
                                                             (set! hands (cons (car ws) hands))))
                                                         v)))
                                           tbl)
                            (length (delete-duplicates hands)))
                          0)))
       int))))
(define (plan-need->wire n) (wire-row* %plan-need-wire n))
(define plan-need-row (row-maker %plan-need-wire))
;; one input of a production (a consumed good / used means / worked labour), and one
;; production (a recipe-process that ran) — the solve's ACTUAL flows for the plan-flow face.
(define %flow-in-wire
  (wire-table 'flow-in #f
    `(("spec" spec str) ("id" id str) ("q" ,(keyed 'q 0) num) ("action" action str))))
(define (flow-in->wire f) (wire-row* %flow-in-wire f))
(define flow-in-row (row-maker %flow-in-wire))
(define %flow-prod-wire
  (wire-table 'flow-prod #f
    `(("id" id str) ("spec" spec str) ("specId" specId str) ("name" name str)
      ("q" ,(keyed 'q 0) num) ("u" u str) ("period" period str)
      ("in" in (rows flow-in)))))
(define (flow-prod->wire p) (wire-row* %flow-prod-wire p))
(define flow-prod-row (row-maker %flow-prod-wire))
;; the schedule's rows are the commitment records themselves and what each act
;; needs the engine's requirement rows, tables joining through the scope's stores
;; (doors/record-rows.scm commitment-record, act-requires); the plan table
;; below names them
;; a line of the ledger: what the plan makes of a good, its id, its name and the
;; unit it is counted in
(define %plan-yield-wire
  (wire-table 'plan-yield #f '(("specId" specId str) ("spec" spec str) ("q" q num) ("u" u str))))
(define %plan-kept-wire (wire-table 'plan-kept #f '(("spec" spec str) ("name" name str) ("q" q num))))
(define %plan-discrete-wire
  (wire-table 'plan-discrete #f
    '(("keys" keys int) ("nodes" nodes int) ("budget" budget int)
      ("certified" certified bool) ("gap" gap num) ("recourseRelaxed" recourseRelaxed (list str)))))
(define plan-yield-row (row-maker %plan-yield-wire))
(define plan-kept-row (row-maker %plan-kept-wire))
(define plan-discrete-row (row-maker %plan-discrete-wire))
(define %plan-wire
  (wire-table 'plan #f
    `(("scope" scope str) ("coverage" coverage num)
      ;; "yes" | "no" | "unknown" — whether the solve respected every limit it was
      ;; given. A coverage from an infeasible solve counts provisioning drawn from
      ;; stock nobody has, so the dial shows the verdict beside the number.
      ("feasible" (feasible . ,(lambda (p ctx) (let ((f (alist-ref p 'feasible))) (if (symbol? f) f "unknown")))) str)
      ;; true while a decision's re-solve has not landed — the plan is shown
      ;; and said to be old (stale-while-revalidating, service scope-plan-wire)
      ("stale" stale bool)
      ("labourH" labourH num)
      ("produced" produced (rows plan-yield))
      ("needs" needs (rows plan-need))
      ;; the portion kept back per good (rail.scm social-portion): the scope's own
      ;; processes' draw this horizon plus the reserve, before anything is shared out
      ("kept" kept (rows plan-kept))
      ;; the discrete layer's verdict, when a search ran; where each mover stands
      ("discrete" discrete (omit-false (row plan-discrete)))
      ("placement" placement (omit-false (map (map num))))
      ;; the solve's real production decomposition; #f (⇒ the browser reconstructs from
      ;; recipe topology) until a solve has run and produced flows.
      ("flow" flow (some-rows flow-prod))
      ;; what each act needs, by (proc, place, when); a missing row says the solve
      ;; published nothing for that act, an empty `needs` that it needs nothing
      ("requires" requires (rows act-requires))
      ;; the SPACE-TIME schedule — every work and material commitment on its own
      ;; clock moment and place, each the commitment-record row it is
      ;; (doors/record-rows.scm): one vocabulary for a commitment wherever it is
      ;; read. The calendar's `sched` source and the plan face's schedule board
      ;; read it (ingest.ts ingestSchedule); the aggregate views above sum these
      ;; away, so it rides beside them, as it is. False until a solve has run.
      ("schedule" schedule (some-rows commitment-record)))))
(define* (plan->wire p #:optional (ctx '())) (wire-row* %plan-wire p ctx))
(define plan-row (row-maker %plan-wire))

;; the inventory: the scope's real economic resources by rail (shop +
;; inventory faces). Specs carry the folksonomy join (categories) and the
;; crystallized-SNLT price in hours; resources carry the claimable id the
;; shop's claim call sends back. Numbers ride as strings, as the page's row types say.
(define %inv-resource-wire
  (wire-table 'inventory-resource #f
  '(("id" id str) ("name" name str) ("image" image opt-str) ("conforms-to" conforms-to str)
    ("onhand" onhand num) ("unit" unit str)
    ("distribution-mode" distribution-mode opt-str)
    ;; who owns it and who holds it are two facts, and the wire says both; the
    ;; holder's name is the join the page shows
    ("primary-accountable" primary-accountable opt-str)
    ("custodian" custodian opt-str) ("custodian-scope" custodian-scope opt-str)
    ("custodian-name" custodian-name str) ("location" location str)
    ("stage" stage str) ("state" state str)
    ;; a CONTAINER keeps what is in it where it is (its specification's
    ;; keep-in-place): a silo, a fridge, a box under a bridge — a drop point
    ("container?" container? bool) ("has-children?" has-children? bool)
    ;; what it sits in, the code its label carries, and its lot: the code, the
    ;; date, and which date that is (best-before | use-by); "" where unstated
    ("contained-in" contained-in str) ("code" tracking-identifier str)
    ("lot-code" lot-code str) ("expires" expires str) ("expires-kind" expires-kind str))))
;; the range the plan leaves a stock in at the instant asked, and the flows that
;; make it (count-door.scm expected-range)
(define %expected-flow-wire
  (wire-table 'expected-flow #f
  '(("id" id str) ("action" action str) ("quantity" quantity num)
    ("when" when str) ("proc" proc str))))
(define %expected-wire
  (wire-table 'expected #f
    '(("low" low num) ("high" high num) ("flows" flows (rows expected-flow)))))
(define (expected->wire e) (wire-row* %expected-wire e))
;; a stock's row, with the plan's range where a flow of the plan bears on it
(define %inv-stock-wire
  (wire-table 'inventory-stock #f
    `(,@(wire-table-entries %inv-resource-wire)
      ("expected" (expected . ,(lambda (r ctx) (let ((e (alist-ref r 'expected #f))) (and (pair? e) e))))
       (omit-false (row expected))))))
(define (inv-resource->wire r) (wire-row* %inv-stock-wire r))
(define inventory-resource-row (row-maker %inv-resource-wire))   ; `expected` is the count door's computed entry
(define %inv-spec-wire
  (wire-table 'inventory-spec #f
  '(("categories" categories strs)
    ("id" id str) ("name" name str) ("note" note str) ("image" image opt-str)
    ("unit" default-unit str) ("substitutable" substitutable bool)
    ("count" resource-count int) ("onhandTotal" onhand-total num) ("snlt" snlt num))))
(define (inv-spec->wire s) (wire-row* %inv-spec-wire s))
(define inventory-spec-row (row-maker %inv-spec-wire))
(define %inventory-wire
  (wire-table 'inventory #f
    '(("scope" scope-id str) ("specs" specs (rows inventory-spec))
      ("resources" resources (rows inventory-stock)))))
(define (inventory->wire inv) (wire-row* %inventory-wire inv))
(define inventory-row (row-maker %inventory-wire))

;; the citizen's live credit standing (playnet.typ §The credit identity) —
;; every field is derived server-side from the event log.
(define %credit-wire
  (wire-table 'credit #f
  '(("gross" gross num) ("claimed" claimed num) ("drawable" drawable num)
    ("capacity" capacity num) ("pool" pool num) ("voice" voice num)
    ("freeTime" free-time num)
    ;; hours in the validation window: diffuse work the scope's silence vests at the lapse
    ("pending" pending num))))
(define (credit->wire c) (wire-row c %credit-wire))
(define credit-row (row-maker %credit-wire))

;; the matter face: a substance-flow graph from the same solve. Masses are
;; numbers; a substance is its symbol and the colour it is drawn in; a tally
;; keyed by substance is an object under the substances' names. An environment
;; resource's `drift` is its net quantity produced less consumed, per element: the rift.
(define %matter-substance-wire
  (wire-table 'matter-substance #f
    `(("symbol" ,(lambda (s ctx) (car (->list s))) str) ("color" ,(lambda (s ctx) (cadr (->list s))) str))))
(define %matter-node-wire
  (wire-table 'matter-node #f
    `(("id" id str) ("label" label str) ("kind" kind str) ("env" env bool)
      ("drift" drift (map num)))))
(define (matter-node->wire n) (wire-row* %matter-node-wire n))
(define %matter-link-wire
  (wire-table 'matter-link #f
    `(("from" from str) ("to" to str) ("flows" flows (map num)))))
(define (matter-link->wire l) (wire-row* %matter-link-wire l))
(define %matter-wire
  (wire-table 'matter #f
    `(("substances" substances (rows matter-substance))
      ("nodes" nodes (rows matter-node)) ("links" links (rows matter-link)))))
(define (matter->wire m) (wire-row* %matter-wire m))

;; the scope itself: its members, its plans and a payout are tables over their records
;; (doors/record-rows.scm); an alert is one the execution layer raised
(define %alert-wire
  (wire-table 'alert #f
    '(("kind" kind str) ("specId" spec-id str) ("processId" process-id str)
      ("planId" plan-id str) ("message" message str) ("timestamp" timestamp str))))
;; a reproduction floor's standing (plan/accepts.scm floors->wire): the rung the
;; horizon sweep read for the process, the days until it forces, each branch's factor
(define %floor-wire
  (wire-table 'floor #f
    '(("proc" proc str) ("rung" rung num) ("daysToForcing" days-to-forcing num)
      ("branchFactors" branch-factors (map num)))))
;; the federation's registered fragilities and their live slack (service.scm
;; scope-fragility-wire): each control's tip and current draw, s its slack; the
;; commune's people with what the plan makes for each, per nutrient
(define %eco-control-wire
  (wire-table 'eco-control #f
    '(("spec" spec str) ("kind" kind (omit-false str)) ("control" control str) ("group" group str)
      ("unit" unit str) ("w" w num) ("source" source str)
      ("current" current num) ("tip" tip num) ("target" target (omit-false num)) ("s" s num))))
(define %person-intake-wire
  (wire-table 'person-intake #f
    '(("id" id str) ("name" name str) ("sex" sex str) ("age" age num) ("region" region str)
      ("pregnant" pregnant bool) ("lactating" lactating bool) ("labour" labour num)
      ("standard" standard num)   ; the scope's ratified standard: the floors the dial draws are the plan's, so both read one number
      ("intake" intake (map num)))))
(define %fragility-wire
  (wire-table 'fragility #f
    '(("source" source str) ("people" people (rows person-intake)) ("controls" controls (rows eco-control)))))

;; The snapshot: what the scope-snapshot door answers, one scope's arms as the
;; page reads them. A `gathered` arm is appended across a person's memberships
;; by `fold-snapshots`; every other arm is the dialed scope's own.
(define %snapshot-wire
  (reply-table 'scope-snapshot
    `(("commitments" commitments (gathered commitment-record))
      ("intents"     intents (gathered intent-record))
      ("proposals"   proposals (gathered proposal))
      ("recipes"     recipes (rows recipe))
      ("plan"        plan (some-row plan))
      ("matter"      matter (some-row matter))
      ("inventory"   inventory (some-row inventory))
      ("credit"      credit (some-row credit))
      ;; the federation's registered fragilities and their live slack, once a solve holds them
      ("fragility"   fragility (some-row fragility))
      ("locations"   locations (gathered location))
      ;; the LIVED layer — what actually happened, beside the plan
      ("events"      events (gathered event))
      ;; the scope itself: its name, its members, its plans, its alerts and floors
      ("scopeId"     scope-id str) ("scopeName" scope-name str)
      ("members"     members (rows member))
      ("plans"       plans (rows plan-ref))
      ("alerts"      alerts (rows alert))
      ("floors"      floors (rows floor)))))

(define (absent-of kind)
  "What an arm of KIND reads as where the dialed scope's snapshot has none yet."
  (case (if (pair? kind) (car kind) kind)
    ((rows gathered strs) (vector))
    ((str) "")
    (else #f)))
(define (fold-snapshots prim others)
  "The snapshot the page paints for a person: PRIM, the dialed scope's finished
   snapshot (or '() while it is in flight), leading, with each gathered arm of
   OTHERS, the person's other memberships' snapshots, appended behind it. The
   dialed scope's own arms ride as they stand, absent as the kind's empty."
  (map (lambda (entry)
         (let* ((key (car entry)) (kind (caddr entry))
                (own (let ((v (and (pair? prim) (assoc-ref prim key))))
                       (if (or (not v) (eq? v 'null)) (absent-of kind) v))))
           (cons key
                 (if (and (pair? kind) (eq? (car kind) 'gathered))
                     (list->vector (apply append (map (lambda (s) (->list (or (assoc-ref s key) '())))
                                                      (cons prim others))))
                     own))))
       (wire-table-entries %snapshot-wire)))
