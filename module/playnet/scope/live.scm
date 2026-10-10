;;; live.scm — the live observer → convex planner → VF commitments wiring.
;;;
;;; The deferred "step 3": close the loop on a RUNNING scope. The convex engine
;;; (planner.scm) is Goblins-free and plans over plain record lists; this thin
;;; layer gathers those lists from the live scope-root actors — observer (the
;;; event-sourced stockbook), agent-store, spatial-thing-store, recipe-store —
;;; via synchronous near-calls ($), runs `plan-from-records`, and hands back the
;;; VF `work` Commitments the plan implies. The observer holds STATE; this turns
;;; it into POLICY and the policy back into VF records the observer can fold.
;;;
;;; It uses the SAME VF record types as the observer: it imports (playnet vf schemas)
;;; and the engine's schema-load is guarded to reuse them, so records cross the
;;; boundary intact. Lives in a Goblins module but the engine inside stays pure.

(define-module (playnet scope live)
  #:use-module ((playnet vf facts located) #:select (credit-good))
  #:re-export (make-work-event)
  #:use-module (playnet vf formulas flows)
  #:use-module ((playnet knowledge dsl shorthand) #:select (flow*))
  #:use-module (playnet utils keywords)
  #:use-module ((playnet utils keyed-id) #:select (keyed-id))
  #:use-module ((playnet vf aggregation fold-node) #:select (sum-by-key))
  #:use-module (playnet utils clock)
  #:use-module ((playnet utils units) #:select (unit->substance %placeholder-unit placeholder-unit? %count-unit %effort-unit))
  #:use-module ((playnet knowledge recipes transport) #:select (recipe-hold))   ; the keep process storage composes
  #:use-module (goblins)                      ; $ — synchronous near-call (same vat)
  #:use-module (goblins actor-lib methods)    ; define-actor / methods (for ^live-planner)
  #:use-module (goblins utils hashmap)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils store-utils) #:select (meta-rows-with-prefix))
  ;; the VF record types (shared with the observer) and the few planner modules
  ;; this one reads, each by name: an umbrella import would carry every planner
  ;; module, the host's transports among them, into whatever builds this one
  #:use-module (playnet vf schemas)
  #:use-module (playnet vf formulas actions)
  #:use-module ((playnet wire rows) #:select (wire-table wire-row*))
  #:use-module (playnet vf beyond scenario)
  #:use-module ((playnet vf formulas capacity) #:select (holding-capacity))
  #:use-module ((playnet vf formulas cadence) #:select (conformance-recert-schedule))
  #:use-module ((playnet vf formulas skill-law) #:select (effective-skills))
  #:use-module ((playnet knowledge catalogues conformance) #:select (conformance-frag-weight))
  #:use-module ((playnet algorithms elastic) #:select (set-social-free-time!))
  #:use-module (ice-9 match)
  #:use-module ((playnet solve recipe-response) #:select (futures-under-record))   ; a recipe's record, laid over the futures
  #:use-module ((playnet observation practice) #:select (make-practice-view practice-view-hours practice-view-dated))
  #:use-module ((playnet vf formulas skill-law) #:select (skill-law-of competence-fold law-ref))   ; a skill's law, off its spec, folded over the record
  #:use-module (playnet observation live-registry)  ; live-availability — the registry as #:live-avail
  #:use-module (playnet vf aggregation containment)  ; the containment climb (bioregions.scm loads here too)
  #:use-module ((playnet knowledge catalogues thermal) #:select (relaxation-records))   ; the leak a body's reserve takes
  #:use-module ((playnet knowledge dsl world) #:select (store-derivations store-composition))   ; what a store stands on: the one assembly the door and the lint read
  #:use-module (playnet knowledge catalogues substances)  ; nutrient-content · closure-rows · closure-flows (reproduction, the flow-shaped table-driven closure); *nutrient-ids*; derive-contains / closed-composition (the chemistry at the door)
  #:use-module (playnet legal compliance)             ; scope-legal-decorate — the scope's law at the door
  #:use-module (playnet plan assignment)  ; the offer field → a rota, for the acts one person must carry
  #:use-module ((playnet plan store)      ; standing by the record's own terms
                #:select (intent-window-passed?))
  #:use-module ((playnet plan accepts)            ; the commitment arc: what the standing commitments ARE to this solve, and what it did to them
                #:select (commitments-before-solve commitments-after-solve scope-part))
  #:use-module ((playnet knowledge catalogues diets)    ; what a person will not eat: the eat recipe's one predicate
                #:select (diet-tags eats?))
  #:declarative? #f                           ; we (primitive-)load the engine at module init
  #:export (solve-with-readers plan-scope practice-view-of plan-scope->alist plan-scope->plan scope-bills scope-consumption scope-food-specs agent->subsistence-ctx profile-tag? scope-composition recipe-derived-contains persist-materialized! materialize-willing! gather-recipes scope-labour? scope-resource-specs
            work-intent clear-intents-by-prefix! lot-of? scope-persons spec-unit planned-row plan->rows plan-map-flows held-commitment met-quantity arriving-lots
            find-recipe-process-for-spec mode-process-for-manner trip-manner-of scope-manners
             ;; the cross-vat federation bridge (engine + engine/federation-solve.scm), re-exported
             ;; so (playnet doors service)'s federated-plan and callers can reach it:
             ;; the means consensus row (engine/federation-solve.scm): the bar across
             ;; sovereign solves, and the records-shaped world it takes
            agent->subsistence-ctx
            willing-tuples refresh-scope-priors!
             ; period ↔ wall-clock (engine)
            ;; THE capacity conversion, reachable so nothing derives a second one.
            ;; A holding becomes per-period service capacity exactly one way —
            ;; `holding-capacity` over the hours it stands available — and anything
            ;; building Svc| caps outside the solve (governance socialization, a
            ;; scope's own caps table) has to reach the same answer or the two
            ;; drift silently by a factor of the period. Exported for that, and
            ;; `resource-place`/`resource-resolver` beside them so a caller
            ;; locates a holding the way ingest does: up the containment chain.
            plan-dilemma ; floor vs wall: price both horns, choose neither
            reserve-dilemma ; floor vs the calamity stock: the reserve's two ways out
            ;; ecological limits carried as levels rather than walls — the same
            ;; view ^tension-registry serves as `eco-stocks`, reachable here so a
            ;; caller can hand them to plan-scope's #:limits.
            record-work-done record-flow-done end-fulfilled! enact-rows
            ^live-planner spawn-live-planner)
  ;; #:re-export, not #:export: live gets holding-capacity from (playnet vf formulas capacity),
  ;; and #:export of an imported binding is an UNBOUND slot that shadows the real
  ;; one for anyone importing live after planner. The rstock-* accessors are the
  ;; same story once stocks.scm became a module — and note the import has to be
  ;; HERE rather than left to the engine's module-use! below, because #:re-export
  ;; is settled when this define-module is read, long before the engine loads.
  ;; THE ENGINE — a module now ((playnet solve engine), phase 3 of the
  ;; engine-as-module arc). Imported HERE, in the define-module, because the
  ;; #:re-export below is settled when this form is read; the primitive-load
  ;; this replaces defined these names into this module, which is why they
  ;; used to sit in #:export.
  #:use-module (playnet solve engine)
  #:use-module (playnet solve solver)
  #:use-module (playnet knowledge worlds bioregions)
  #:re-export (commune->scope-record federated-solve federated-per-scope federated-relaxed-scopes warm-boundary-flows boundary-bounds federated-dilemma
               ;; stage 4 (truth-telling.md): a scope's price to the others — service.scm's federated-plan reads these
               federated-scope-pulls federated-withdrawal-displacement federated-result loose-gives
               crossing-recipe federated-flows
               allocate-means-consensus records-means-world
               scenario-shocks shock-action shock-key shock-period shock-factor
               tension-duals ingest-records! lg cell
               time->period set-period-span! period-span set-daily-horizon!
               resource-window-hours period-hours declared-period-hours
               resource-place resource-resolver)
  #:use-module (playnet vf formulas stocks)
  #:use-module (playnet solve compile)
  #:use-module ((playnet observation observer) #:select (target-passed?))
  #:use-module (playnet knowledge catalogues eco)
  ;; the seeded bioregions: importing the sheds registers each one, so a scope placed
  ;; contained-in a shed inherits its climate futures and limits by the containment walk
  #:use-module (playnet knowledge worlds sheds)
  ;; The governed INSURANCE reserve (q^res = ι·q*, one row per resource
  ;; category), read by plan-scope #:insure? to stand a `held` reserve behind
  ;; every demanded good that carries one.
  #:use-module (playnet knowledge catalogues insurance)
  #:re-export (*insurance-catalogue* insurance-row insurance-profile insurance-rows
               reserve-report reserve-controls ins-spec ins-iota ins-margin ins-alpha ins-w)
  ;; INSPECTION — the freshness stocks + inspect recipes a plan must schedule
  ;; (plan-scope #:inspect) and the loads it routes through each conformance edge
  ;; (plan-results->alist, skills AND means). Imported HERE, inside the form,
  ;; because #:re-export is settled at define-module time.
  #:use-module (playnet solve inspection)
  #:re-export (reliance-edges verif-spec scope-inspection commitment-loads)
  #:re-export (holding-capacity
               ;; the Svc| namer — one definition, in the VF compiler, now
               ;; that both loaders import it rather than each including it
               svc-good
               ;; the ratified fragility catalogue, and the same limits read
               ;; as regenerating stocks of headroom rather than as walls
               *planetary-catalogue* migrate-limit migrated->caps migrated->flows
               migrated->procs migrated->resources migrated->stock-frag
               migrated->storables migrated-limits migrated-place migrated-rate
               migrated-spec migrated-stock migrated-weight reversibility-character
               reversibility-implies reversibility-years
               rstock-spec rstock-name rstock-place rstock-init rstock-unit)
  #:use-module (playnet solve routing)
  #:use-module (playnet knowledge catalogues subsistence)
  #:use-module ((playnet knowledge catalogues rest) #:select (disposable-hours))
  #:use-module ((playnet vf facts agent-time) #:select (sleep-hours-stated set-agent-disposable! %time-tag-prefixes))
  #:use-module (playnet vf facts agent-tags)
  #:use-module ((playnet knowledge catalogues housing-substance) #:select (scope-housing resource->dwelling-unit))
  #:use-module ((playnet knowledge catalogues housing) #:select (season-of outdoor-degc))
  #:use-module ((playnet algorithms rollup) #:select (crystallized-snlt-for-spec))   ; the claim's price
  #:use-module ((playnet vf facts rail) #:select (publish-rails! rails-of publish-social-portion!
                                               set-rails! set-social-portions!))
  #:use-module ((playnet utils catch) #:select (catch* throw* with-throw-handler*)))

(cond-expand (guile) (else
  (define (getenv name) #f)                ; a page has no process environment; the PLANNER_* switches read as unset
  (define %no-entry (list 'no-entry))
  (define (hash-get-handle h key)          ; the (key . value) pair of KEY in H, or #f (Hoot has no handles)
    (let ((v (hash-ref h key %no-entry)))
      (and (not (eq? v %no-entry)) (cons key v))))))


;; the convex engine arrives through the (playnet solve engine) import in the
;; define-module above — the same door every test opens.
;; the arc-time table folds (EWMA / merge / prior file) + Valhalla client —
;; never consulted on the solve path; plan-scope only reads the merged table.
;; the reproduction-of-labour-power requirement model (the determinants folded
;; over a species base) — plain defines, included into this module.
;; the fragility catalogue + its two solver views (`catalogue->policy` reads a limit
;; as a wall, `migrated-limits` as a stock of headroom). Loaded here so plan-scope's
;; #:limits can fold the second one in; the tension registry custodies the data.
;; imported in the define-module above, so #:re-export can reach these names.

;; the seeded bioregions arrive through the shed imports in the define-module above.

;; ── prior auto-refresh: the scope's own places, when the world changed ───────
;; The prior file is stamped with the engine's tileset_last_modified; the
;; engine re-stamps when tiles (or GTFS) are rebuilt. This compares the two
;; and re-runs the matrix over the SCOPE'S OWN SpatialThings — no hand-fed
;; place list. NEVER on the solve path (it makes HTTP calls): the gateway
;; calls it at boot / on a timer; plan-scope only ever reads the file.
(define* (refresh-scope-priors! scope-root
                                #:key (manners (let ((ms (scope-manners scope-root))) (if (null? ms) '("pedestrian" "bicycle" "auto") ms)))
                                      (path "data/routing/priors.sexp")
                                      (force? #f)
                                      (period-classes (period-class-date-times)))
  "Refresh the arc-time priors for SCOPE-ROOT's located places when the
   engine's tileset stamp has drifted from the prior file's (or FORCE?).
   Returns 'fresh (nothing to do), 'refreshed, or 'engine-down."
  (let ((engine-stamp (valhalla-tileset-stamp)))
    (cond
     ((not engine-stamp) 'engine-down)
     ((and (not force?) (equal? engine-stamp (routing-priors-stamp path))) 'fresh)
     (else
      (let* ((sts (false-if-exception
                   ($ ($ scope-root 'spatial-thing-store) 'all-locations)))
             (latlon (filter-map
                      (lambda (st)
                        (let ((la (spatial-thing-lat st)) (lo (spatial-thing-long st)))
                          (and la lo (cons (spatial-thing-id st) (cons la lo)))))
                      (or sts '()))))
        (if (null? latlon) 'fresh                  ; nothing located yet — nothing to price
            (begin (refresh-priors! (map car latlon) latlon manners
                                    #:path path #:period-classes period-classes)
                   'refreshed)))))))

;; ── self-deriving period classifier ──────────────────────────────────────────
;; Period spans are DATE-granular (a period = a day under set-daily-horizon!),
;; so the class a period can honestly claim for itself is weekend-vs-weekday:
;; a span landing on Sat/Sun reads the "we" arc entries (weekend transit ≠
;; weekday), weekdays fall through to the manner-wide entry. Hour classes
;; (wd-am…) apply to OBSERVED trips (which know their epoch) and to
;; deployments with sub-day periods, which supply their own 'period-class.
(define (span-derived-period-class t)
  (let ((start (car (period-span t))))
    (and start
         (let ((e (false-if-exception (iso->epoch start))))
           (and e (let ((wd (instant->weekday e)))
                    (and (or (= wd 0) (= wd 6)) "we")))))))

;; ── the mode a trip was made by ────────────────────────────────────────────────
;; A mode is a recipe; a performed trip is a Process based on the mode's process
;; specification, and the mode recipe carries the routing manner. So the join from a
;; trip to the arc table's key runs process → specification → recipe → manner.
(define (find-recipe-process-for-spec rs spec-id)
  "Search recipes for a recipe-process whose process-conforms-to matches
   SPEC-ID. Returns the <recipe-process> record or #f. Used to bridge
   dynamically-generated process IDs (a performed trip, dependent demand) back to
   recipe topology — both share the process-spec id via 'based-on / 'process-conforms-to."
  (and spec-id
       (let loop ((recipes ($ rs 'all-recipes)))
         (cond
           ((null? recipes) #f)
           (else
            (let ((rps ($ rs 'processes-for-recipe (recipe-id (car recipes)))))
              (or (find (lambda (rp)
                          (equal? (recipe-process-process-conforms-to rp) spec-id))
                        rps)
                  (loop (cdr recipes)))))))))

(define (mode-process? rs rp)
  "RP is a travel mode: a relocation whose mover works its own journey (a `work` flow
   resolved from the recipe's own pickup — recipes/transport.scm mode-recipe)."
  (any (lambda (f) (and (eq? 'work (recipe-flow-action f)) (recipe-flow-resolve-from-flow f)))
       (car ($ rs 'flows-for-process (recipe-process-id rp)))))

(define (mode-processes rs)
  "The scope's travel modes, as recipe processes, by id."
  (sort (filter (lambda (rp) (mode-process? rs rp))
                (append-map (lambda (r) ($ rs 'processes-for-recipe (recipe-id r))) ($ rs 'all-recipes)))
        (lambda (a b) (string<? (recipe-process-id a) (recipe-process-id b)))))

(define (mode-process-for-manner rs manner)
  "The scope's travel mode for the routing costing MANNER (the lowest id when several
   carry it), or #f when none does."
  (find (lambda (rp) (equal? (recipe-manner rp) manner)) (mode-processes rs)))

(define (scope-manners scope-root)
  "The routing costings the scope's modes carry, sorted: what the prior refresh prices."
  (sort (delete-duplicates (filter-map recipe-manner (mode-processes ($ scope-root 'recipe-store)))) string<?))

(define manner-tag manner-of-tags)           ; "manner:bicycle" → "bicycle" (solve/compile, the one reader)

(define (trip-manner-of scope-root)
  "(process id → manner or #f): the costing a performed trip was made under — its
   mode recipe's, through the specification the trip is based on; a trip no mode of
   the scope covers (a costing the map offers and no recipe states) carries its own
   costing as a classification."
  (let ((obs ($ scope-root 'observer)) (rs ($ scope-root 'recipe-store)))
    (lambda (pid)
      (let* ((p  ($ obs 'get-process pid))
             (rp (and p (find-recipe-process-for-spec rs (process-based-on p)))))
        (or (and rp (recipe-manner rp))
            (and p (manner-tag (process-classified-as p))))))))

;; ── the live arc-time table: routing priors ⊕ the observer's performed trips ──
;; Trips arrive as raw facts (from to process hours begin); resolving the process to
;; its routing manner is policy vocabulary and happens HERE (MANNER-OF; a haul no
;; mode carries rides the road). Observed EWMA wins
;; per key; the prior fills the rest; absent both, the planner's rate×haversine
;; fallback carries — so this degrades gracefully all the way to geometry.
;;
;; Cached PER OBSERVER on (event-count . prior-stamp): the event log only
;; grows and the prior file only changes on refresh, so the O(events) refold
;; runs exactly when one of them moved — a metabolism re-solve with a quiet
;; log pays one near-call and one file-header read, not a fold. Keying by the
;; observer keeps co-resident scopes from ever serving each other's tables.
(define *arc-table-cache* (make-hash-table))   ; obs → ((count stamp manners) . table)
(define %haul-manner "auto")                      ; a haul no travel mode carries rides the road
(define* (live-arc-table obs #:optional (manners '()) #:key (manner-of (lambda (pid) #f)))
  (let* ((key (list (false-if-exception ($ obs 'event-count)) ; not from post-reset! globals
                    (routing-priors-stamp) manners))
         (hit (hashq-ref *arc-table-cache* obs #f)))
    (if (and (car key) hit (equal? key (car hit)))
        (cdr hit)
        (let* ((classify (or (assq-ref manners 'epoch-class)  ; epoch-secs → class;
                             epoch->period-class))            ; canonical default (solve/routing.scm)
               (trips (append-map
                       (lambda (tr)
                         (let* ((manner (or (manner-of (third tr)) %haul-manner))
                                (base (list (first tr) (second tr) manner (fourth tr)))
                                (cls (and classify (>= (length tr) 5)
                                          (classify (fifth tr)))))
                           ;; a classed trip ALSO feeds the manner-wide entry —
                           ;; the coarse signal stays whole, the classed one refines
                           (if cls
                               (list base (list (first tr) (second tr)
                                                (string-append manner "|" cls)
                                                (fourth tr)))
                               (list base))))
                       (or (false-if-exception ($ obs 'arc-observations)) '())))
               (table (arc-table-merge (routing-load-priors) (ewma-fold trips))))
          (hashq-set! *arc-table-cache* obs (cons key table))
          table))))

;; ── a citizen's own good: the CLAIM ──────────────────────────────────────────
;; A want stated for oneself is felt on "spec~aid" (engine.scm owned-spec), and
;; the edge between the scope's good and the citizen's is a recipe like any
;; other: `consume spec` + `consume credit|aid` at the good's crystallized SNLT
;; → `produce spec~aid`, custody moving because the flow says so, the way a
;; transport recipe moves place because its flow says so. It is the labour-certificate as a column: the pool's good, priced in the abstract
;; substance every good in it shares, cashed for one concrete form. Nothing
;; else in the world knows the citizen: the bake still makes "bread", the
;; reserve still stands on "bread", only the last metre is named. The eat
;; recipe (scope-consumption) is a different column: it draws the commons'
;; bare food at the person's cell and prices nothing, so a floor stays a
;; need whatever a person holds. Credit is a structural raw in the engine —
;; drawn and tallied (solve-report `credit-drawn`) — and the citizen's
;; certificate is a row of the same program over every column drawing it
;; (engine *certificates*), so the plans ranked are the ones they can afford;
;; the ledger re-reads the balance where a claim becomes an event only
;; against a race (account.scm).
       ; the plan's word on the rail, and on the portion kept back
(define* (claim-recipes goods #:key (supplied? (lambda (spec) #t)) (price (lambda (spec) #f))
                              (means? (lambda (spec) #f)) (unit-of (lambda (spec) %count-unit)))
  "(procs . flows) — one claim recipe per distinct owned good \"spec~aid\" in
   GOODS whose base good the scope can SUPPLY (SUPPLIED?: some recipe produces
   it, or stock of it stands) and that is no MEANS: what a process `use`s — an
   oven, a field — no person claims (MEANS?). The verb decides: a good only
   `use` flows touch is a means of production, custody the custodian-scope
   projection and title the ownership credential's; a good consumed is a means
   of consumption, and a claim is its edge. PRICE: spec → crystallized SNLT in
   hours, or #f / +inf.0 for a good no recipe prices — the claim then moves
   custody with no credit leg, and the good is unpriceable in the pool too.
   UNIT-OF: spec → the unit its consuming flow states. A want for a good the
   scope has no way to provide gets no column: it is an unmet want, felt at
   zero — never a wall. A claim consuming a good that can never exist is an
   empty-interior pin (engine raw-reach-set, the documented blemish), and live
   it starved a whole scope's plan on a handful of citizens' wants for a spec
   nobody grows (found 2026-09-04)."
  ;; GOODS runs O(crowd × wants) — a hash marks what is already admitted, so
  ;; this pass reads the list once where a `member` over the grown SEEN read
  ;; it once per member
  (let ((seen '()) (seen? (make-hash-table)))
    (for-each (lambda (g)
                (let ((o (spec-owner g)))
                  (when (and o (not (hash-ref seen? g #f)) (supplied? (car o)) (not (means? (car o))))
                    (hash-set! seen? g #t)
                    (set! seen (cons g seen)))))
              goods)
    (let ((pairs (map (lambda (g)
                        (let* ((o (spec-owner g)) (pid (string-append "claim~" g))
                               (snlt (price (car o))) (unit (unit-of (car o))))
                          (cons (rp pid (string-append "claim " (car o) " for " (cdr o)))
                                (append
                                 (list (make-recipe-flow #:id (string-append pid "|in") #:action 'consume #:resource-conforms-to (car o)
                                                         #:resource-quantity (make-measure 1.0 unit) #:recipe-input-of pid))
                                 (if (and (number? snlt) (< snlt +inf.0) (> snlt 0.0))
                                     (list (make-recipe-flow #:id (string-append pid "|credit") #:action 'consume
                                                             #:resource-conforms-to (credit-good (cdr o))
                                                             #:resource-quantity (make-measure snlt %effort-unit) #:recipe-input-of pid))
                                     '())
                                 (list (make-recipe-flow #:id (string-append pid "|out") #:action 'produce #:resource-conforms-to g
                                                         #:resource-quantity (make-measure 1.0 unit) #:recipe-output-of pid #:is-primary #t))))))
                      (reverse seen))))
      (cons (map car pairs) (append-map cdr pairs)))))
(define (owned-goods-of-demand demand)
  "The distinct owned goods \"spec~aid\" a DEMAND alist names — deduplicated by
   hash in one pass (first-occurrence order), since the distinct set runs
   O(crowd × wants) and a pairwise dedup read it once per member."
  (let ((seen (make-hash-table)) (acc '()))
    (for-each (lambda (d)
                (let ((g (key-spec (car d))))
                  (when (and (spec-owner g) (not (hash-ref seen g #f)))
                    (hash-set! seen g #t)
                    (set! acc (cons g acc)))))
              demand)
    (reverse acc)))

;; ── storage is mechanism: what the scope HOLDS keeps what it classifies storable ──
;; playnet.typ: "Storage is the same activity pointed through time"; a
;; container classified keep-in-place "relocates its contents through time",
;; and what it takes to move something lives in the good's classification. A
;; scope does not write storage down as a craft — its library says what it
;; MAKES. It has a durable (the ground, a silo, "storage · 2 bays") and goods
;; it classifies `storable`, and the relocation through the durable is
;; composed here, as a ride is composed from a mover and a delivery column
;; from a want: one process per keep-in-place spec the scope holds a resource
;; of, cargo the classification, expanded per conforming spec by
;; expand-cargo-classes. The holding costs the container's service — the hours
;; recipe-hold states for a stay — and nothing else.
(define %good-class "good")                 ; the root of the classification: every spec that is a good — not a container, not a service
(define (keeping-processes specs resources)
  "→ (values procs flows): a keep process per keep-in-place spec some resource conforms to."
  (let* ((held (delete-duplicates (filter-map (lambda (r) (economic-resource-conforms-to r)) resources)))
         (containers (filter (lambda (sp) (and (resource-spec-keep-in-place? sp)
                                               (member (resource-specification-id sp) held)))
                             specs)))
    (when (getenv "PLANNER_PD_DEBUG")
      (format (current-error-port) "  [keep] keep-in-place specs ~s; held ~s; containers ~s~%"
              (filter-map (lambda (sp) (and (resource-spec-keep-in-place? sp) (resource-specification-id sp))) specs)
              held (map resource-specification-id containers)))
    (let loop ((cs containers) (ps '()) (fs '()))
      (if (null? cs) (values (reverse ps) fs)
          (let ((k (resource-specification-id (car cs))))
            (call-with-values
                (lambda () (recipe-hold %good-class k #:id (string-append "keep|" k) #:unit %count-unit
                                        #:name (string-append (resource-specification-name (car cs)) " keeps what stands on it")))
              (lambda (proc flows) (loop (cdr cs) (cons proc ps) (append flows fs)))))))))

;; ── a relocation names its cargo by CLASSIFICATION ───────────────────────────
;; playnet.typ §"Transport and storage are one recipe": a move has one shape —
;; pickup a good, dropoff it, use a container — and "what it takes to move
;; something lives in its classification, not in a flag". So a relocation
;; recipe's cargo may name a classification ("storable") rather than one good,
;; and it compiles through the classification: one process per spec the scope
;; classifies so, its cargo flows retyped to that spec in the spec's own unit,
;; the container's `use` and the driver's `work` cloned as they are. The
;; ground then keeps whatever stands on it with ONE recipe, where a recipe per
;; good ("Keep pit in place", "Keep water in place") repeated the same activity
;; under every cargo's name. A cargo that IS a spec passes through unchanged.
(define (expand-cargo-classes procs flows specs)
  "→ (values procs* flows*), every relocation naming a classification expanded
   over the specs classified under it."
  (let* ((by-id (let ((h (make-hash-table))) (for-each (lambda (sp) (hash-set! h (resource-specification-id sp) sp)) specs) h))
         ;; a GOOD is what a container can hold: a spec that is not itself a
         ;; keep-in-place container and whose unit is not time (a service, a
         ;; skill). `good` is the root of the classification — "everything is
         ;; movable, it merely has one applicable recipe" — and a narrower class
         ;; names the specs classified under it, which select a recipe of their own
         ;; A SERVICE is what a recipe DELIVERS — the verb says so, as it says what
         ;; a means is (`use`) and what a claim's good is (`consume`). Delivered and
         ;; never inventoried, it has no later to be kept for: a night's shelter,
         ;; denominated in person-nights, is no more storable than an hour of care
         ;; for wearing a unit the table does not read as time.
         (service? (let ((h (make-hash-table)))
                     (for-each (lambda (f) (when (eq? (recipe-flow-action f) 'deliver-service)
                                             (hash-set! h (recipe-flow-resource-conforms-to f) #t)))
                               flows)
                     (lambda (sp) (hash-ref h (resource-specification-id sp) #f))))
         ;; …and never the sky: an ambient flow (sunlight, rain, air, the surroundings'
         ;; warmth) is drawn where it falls and kept by nothing, so a container that
         ;; kept it would turn the boundless into a good nothing sources
         ;; …and never a MEANS — a spec some recipe `use`s. A means is there the
         ;; next period by its own capacity, rendered again each period where it
         ;; stands; kept by a container it would be a second, bare good that
         ;; nothing holds.
         (means? (let ((h (make-hash-table)))
                   (for-each (lambda (f) (when (eq? (recipe-flow-action f) 'use)
                                           (hash-set! h (recipe-flow-resource-conforms-to f) #t)))
                             flows)
                   (lambda (sp) (hash-ref h (resource-specification-id sp) #f))))
         (good? (lambda (sp) (and (not (resource-spec-keep-in-place? sp))
                                  (not (service? sp))
                                  (not (means? sp))
                                  (not (member (resource-specification-id sp) *ambient-flows*))
                                  (not (eq? 'time (unit->substance (resource-specification-default-unit-of-resource sp)))))))
         (under (lambda (cls)                       ; the specs classified under CLS
                  (if (equal? cls %good-class)
                      (filter good? specs)
                      (filter (lambda (sp) (member cls (or (resource-specification-resource-classified-as sp) '()))) specs))))
         (flows-of (lambda (pid) (filter (lambda (f) (or (equal? (recipe-flow-recipe-input-of f) pid)
                                                         (equal? (recipe-flow-recipe-output-of f) pid)))
                                          flows)))
         (cargo-class (lambda (pid)                 ; the classification a relocation's pickup names, when it names one
                        (let ((pk (find (lambda (f) (and (relocating-action? (recipe-flow-action f))
                                                         (equal? (or (recipe-flow-recipe-input-of f) (recipe-flow-recipe-output-of f)) pid)))
                                        flows)))
                          (and pk (let ((c (recipe-flow-resource-conforms-to pk)))
                                    (and c (not (hash-ref by-id c #f)) (pair? (under c)) c))))))
         (retype (lambda (f pid* spec)              ; a flow of the expanded process: cargo flows to SPEC in its unit
                   (let* ((cargo? (relocating-action? (recipe-flow-action f)))
                          (q (recipe-flow-resource-quantity f))
                          (unit (resource-specification-default-unit-of-resource spec)))
                     (copy-recipe-flow f #:id (string-append (recipe-flow-id f) "~" (resource-specification-id spec))
                                       #:resource-conforms-to (if cargo? (resource-specification-id spec) (recipe-flow-resource-conforms-to f))
                                       #:resource-quantity (if (and cargo? q unit) (make-measure (measure-has-numerical-value q) unit) q)
                                       #:recipe-input-of (and (recipe-flow-recipe-input-of f) pid*)
                                       #:recipe-output-of (and (recipe-flow-recipe-output-of f) pid*))))))
    (let loop ((ps procs) (procs* '()) (flows* '()) (dropped '()))
      (if (null? ps)
          (values (reverse procs*)
                  (append (filter (lambda (f) (not (member (or (recipe-flow-recipe-input-of f) (recipe-flow-recipe-output-of f)) dropped))) flows)
                          flows*))
          (let* ((rp (car ps)) (pid (recipe-process-id rp)) (cls (cargo-class pid)))
            (if (not cls)
                (loop (cdr ps) (cons rp procs*) flows* dropped)
                (let ((own (flows-of pid)))
                  (loop (cdr ps)
                        (append (reverse
                                 (map (lambda (spec)
                                        (let ((pid* (string-append pid "~" (resource-specification-id spec))))
                                          (copy-recipe-process rp #:id pid* #:name (string-append (recipe-process-name rp) " · " (resource-specification-id spec)))))
                                      (under cls)))
                                procs*)
                        (append (append-map (lambda (spec)
                                              (let ((pid* (string-append pid "~" (resource-specification-id spec))))
                                                (map (lambda (f) (retype f pid* spec)) own)))
                                            (under cls))
                                flows*)
                        (cons pid dropped)))))))))

;; ── gather the recipe records (procs + flat flows) from the recipe-store ─────
(define* (gather-recipes rs #:key (admit? #f))
  "Walk every recipe's process chain → (values recipe-processes all-flows).
   compile-recipe re-filters the flat flow list per process.

   ADMIT? (recipe → bool), when given, is the admission seam (patchwork §5
   item 3): a recipe the policy does not admit contributes no processes and
   no flows, so the solve never sees it — a hole yielding to its filler, a
   steward's rule on lent means. Absent, every recipe in the store is the
   patchwork, as always. The predicate is injected because admission is
   governance's to decide; the store stays the scope's own patchwork either
   way. A recipe's RECORD is no gate: it reaches the solve as the response
   each future reads (#:responses)."
  (let ((procs '()) (flows '()) (seen (make-hash-table)))
    (for-each (lambda (r)
      (when (or (not admit?) (admit? r))
      (for-each (lambda (rp)
        (let ((pid (recipe-process-id rp)))
          (unless (hash-ref seen pid #f)
            (hash-set! seen pid #t)
            (set! procs (cons rp procs))
            (let ((io ($ rs 'flows-for-process pid)))   ; (inputs . outputs)
              (set! flows (append (car io) (cdr io) flows))))))
        ($ rs 'get-process-chain (recipe-id r)))))
      ($ rs 'all-recipes))
    (values (reverse procs) flows)))

;; ── reproduction of labour-power, per person, at their place ─────────────────
;; The CONSUMPTION side (playnet.typ §Means of consumption): each person EATS the
;; scope's foods → their OWN nutrient goods, which the subsistence catalogue (the
;; determinants folded over a species base) FLOORS at the person's cell. Food grown
;; anywhere is transported to the eater by the ordinary movable-goods solve — so this
;; is multi-place native and worst-off-protecting (the −log barrier diverges for
;; whoever is short, wherever they are). plan-scope #:reproduce? turns it on; default
;; off leaves every solve unchanged.

;; ── an agent's subsistence context ──────────────────────────────────────────
;; The catalogue's life-stage machinery is fine-grained — age × sex, pregnancy,
;; lactation, elder shifts at 51, climate, the day's committed labour — so the
;; context feeding it should be too. Three sources, most specific first:
;;
;;   1. a TYPED tag  "age:34" · "sex:M" · "region:cold" · "standard:1.2"
;;   2. a COARSE tag "elder" · "child" · "male" · "cold" — kept, because scopes
;;      already carry them and they should not stop working
;;   3. the default
;;
;; LABOUR-HOURS is NOT read from the availability window, and the distinction is
;; worth stating because it looks like an easy win and is not one.
;;
;; A window says WHEN A PERSON IS AVAILABLE. The labour side of the solve reads it
;; as a supply bound — how much they COULD work — which is right. L3 wants
;; something different: how much they DID work, because the day's committed labour
;; is what raises the energy and protein floor. Those coincide for a rostered
;; worker and come apart badly otherwise: a festival attendee whose window says
;; "present all week" is not thereby doing 70 hours of labour, but reading the
;; window would give them a 3740 kcal floor instead of 2383.
;;
;; So an explicit `labour-hours:N` tag states it, and absent that it stays at the
;; long-standing 5. The genuinely right source is the labour the SOLVE assigns to
;; this person — that is the committed figure by construction — but it is not
;; available when the context is built, and feeding it back is a fixed point the
;; engine does not currently take. Worth doing; not by conflating it with presence.
;; STANDARD (L4, the historical-moral layer) is read too. Absent it defaults to
;; 1 — bare physiology — which is what the catalogue does anyway; present, a
;; ratified standard lifts the floor, and may only raise, never through a ceiling.
(define* (agent->subsistence-ctx a #:optional (t 0) (shed #f))   ; t reserved: see the note on committed labour
  (let* ((tags (or (agent-classified-as a) '()))
         (has? (lambda (x) (and (member x tags) #t)))
         (hours (tag-number tags "labour-hours" 5)))
    `((sex . ,(or (tag-value tags "sex") (if (has? "male") "M" "F")))
      (age . ,(tag-number tags "age"
                          (cond ((has? "elder") 67) ((has? "child") 8) (else 30))))
      (region . ,(or (tag-value tags "region")
                     (cond ((has? "cold") "cold") ((has? "inland") "inland")
                           ((has? "hotArid") "hotArid") (else "temperate"))))
      (pregnant . ,(or (has? "pregnant") (equal? "1" (tag-value tags "pregnant"))))
      (lactating . ,(or (has? "lactating") (equal? "1" (tag-value tags "lactating"))))
      (standard . ,(tag-number tags "standard" 1))
      ;; the SHED this person works in — the scope's own bioregion by containment,
      ;; overridable per-person by a tag. The catalogue reads its warmest-quarter
      ;; temperature (its real ERA5 record) for the sweat-sodium term, so `region`
      ;; above is only the fallback for someone standing in no shed at all.
      (shed . ,(or (tag-value tags "shed") shed))
      ;; ACCLIMATED: this body has worked this heat for a fortnight and reabsorbs
      ;; sodium before it sweats. Default #f — unacclimated is the HIGHER floor,
      ;; and the new arrival is the one who is actually at risk.
      (acclimated . ,(has? "acclimated"))
      (labour-hours . ,hours)
      ;; SLEEP: a person who states a span ("sleep:23:00-07:00") states their need —
      ;; the rest catalogue reads the summed length of every span they state
      ;; (several stack: a night-shift split, a main span and a nap) in place
      ;; of the age band's
      (sleep-hours . ,(sleep-hours-stated a))
      ;; BODY: a stated height and weight rescale the energy and protein floor
      ;; (the catalogue's L2c); absent, the band's reference body stands
      (weight-kg . ,(tag-number tags "weight-kg" #f))
      (height-cm . ,(tag-number tags "height-cm" #f))
      ;; HOW HARD the hours are (the catalogue's *work-intensity* class) is the
      ;; work's own fact, never the person's: each recipe process states its
      ;; effort as a "work:<class>" tag (work-intensity-of-tags), the ValueFlows
      ;; effort quantity's class. It reaches this context once the solve's
      ;; assignment feeds it back (see the note on committed labour); until
      ;; then the hour is the unweighted, moderate one
      (labour-intensity . #f)
      ;; WHERE, for the geography layer's altitude and winter-sun rows: elevation
      ;; in metres and a coarse latitude, and the month the floor is for
      (altitude-m . ,(tag-number tags "altitude-m" #f))
      (lat . ,(tag-number tags "lat" #f))
      (month . ,(tag-number tags "month" (month-now)))
      ;; SELF: the conditions this person chose to tell the commons ("self:<id>",
      ;; the catalogue's *self-conditions*); what they keep to themselves stays
      ;; in their own browser's layer
      (self . ,(tag-values tags "self"))
      ;; DIET: the diet:/allergy:/excludes: tags as stated — the eat recipe's
      ;; menu (knowledge/diets.scm) and the catalogue's L2b layer both read them
      (diet . ,(diet-tags tags))
      ;; STEP-FREE: this body needs step-free access — what raises the housing
      ;; catalogue's accessibility gate from 0 to 1 (knowledge/housing-catalogue.scm L2)
      (step-free . ,(has? "step-free")))))

;; THE RESERVATION OF REST, registered once (matching/availability.scm): the hours of
;; DAYS days a person has left after their own reproduction time
;; (knowledge/rest-catalogue.scm), read off the same ctx the subsistence and housing
;; floors read. The solve reads it per period, the labour pool per week, and the
;; free-time fraction over it; a non-person has no body to rest.
(set-agent-disposable!
 (lambda (a days)
   (and (eq? (agent-type a) 'person)
        (disposable-hours (agent->subsistence-ctx a) #:days days))))

;; the tags the profile owns — most read by agent->subsistence-ctx above and
;; knowledge/diets.scm; "transit-access" folded into a rider's skills list by
;; engine.scm's mobility-skills instead. "walk"/"cycle" are NOT profile tags —
;; real declared skills (service.scm declare-skill/revoke-skill), the same
;; door "doctor" or "driving" goes through, not a classifiedAs fact a
;; set-profile call replaces. A set-profile replaces exactly these and no other.
(define %profile-tag-prefixes (append %time-tag-prefixes '("sex:" "age:" "pregnant:" "lactating:" "region:" "labour-hours:" "standard:" "shed:" "diet:" "allergy:" "excludes:" "weight-kg:" "height-cm:" "altitude-m:" "lat:" "month:" "self:")))
(define %profile-bare-tags '("male" "female" "child" "elder" "pregnant" "lactating" "cold" "inland" "hotArid" "acclimated" "step-free" "transit-access"))
(define (profile-tag? t)
  (and (string? t)
       (or (member t %profile-bare-tags)
           (any (lambda (p) (string-prefix? p t)) %profile-tag-prefixes))))

;; the food specs a scope PRODUCES that carry nutrition (a *food-nutrition* row).
(define (scope-food-specs flows)
  (delete-duplicates
   (filter-map (lambda (f)
                 (and (output-flow? f)
                      (let ((spec (recipe-flow-resource-conforms-to f)))
                        (and spec (pair? (nutrient-content spec 1)) spec))))
               flows)))

;; the consumption recipes (eat) + per-person floors. For each person and each food:
;; an EAT process consuming 1 unit of food → producing that person's nutrient goods
;; (amounts from the `contains` closure). Floors key to "<nut>|<pid>#<place>@<t>",
;; one set per period at the cell WHERE says the person occupies then — so a body
;; requires its subsistence every period, and the requirement travels with the
;; body. WHERE is plan-scope's `agent-cell`, the same rule the labour side reads.
;; Returns (values procs flows bands) — bands ((key rda ul w) …), each nutrient's
;; two walls as one row on the person's located nutrient good (ul #f ⇒ no ceiling).
(define %body-spec (make-resource-specification #:id "body" #:name "A body"
                                                #:default-unit-of-resource "hours/day"
                                                #:keep-in-place #t))
(define* (scope-reserves bands agents #:key (period-hours 24.0))
  "The body as an enclosure that leaks: for every (person, nutrient) BANDS stand on
   whose nutrient the body stores (reserve-nutrients), the store-shaped recipe that
   carries the person's good from period to period and loses 1 − e^(−p/τ) of it
   (catalogues/thermal.scm relaxation-records with no base and no heat), held in the person's
   own body — a keep-in-place spec, one resource per person at their place. Alist:
   procs, flows, resources, specs; empty when no stored nutrient has a band."
  ;; BANDS is O(people × nutrients) and the stored-nutrient pairs keep one row
  ;; per person — hash-indexed single passes (same first-occurrence order as
  ;; delete-duplicates) and an agent-id→place table keep this linear in the
  ;; crowd, where a pairwise dedup and a per-person `find` over AGENTS each
  ;; read the crowd once per member (O(N²) at festival scale).
  (let* ((stores (reserve-nutrients))
         (pairs (let ((seen (make-hash-table)) (acc '()))
                  (for-each (lambda (b)
                              (let* ((g (car (string-split (car b) #\#)))
                                     (parts (string-split g #\|)))
                                (when (and (= 2 (length parts)) (assoc-ref stores (car parts))
                                           (not (hash-ref seen g #f)))
                                  (hash-set! seen g #t)
                                  (set! acc (cons (list g (car parts) (cadr parts)) acc)))))
                            bands)
                  (reverse acc)))
         (people (let ((seen (make-hash-table)) (acc '()))
                   (for-each (lambda (p) (unless (hash-ref seen (caddr p) #f)
                                           (hash-set! seen (caddr p) #t)
                                           (set! acc (cons (caddr p) acc))))
                             pairs)
                   (reverse acc)))
         (places (let ((h (make-hash-table)))
                   (for-each (lambda (a) (unless (hash-get-handle h (agent-id a))
                                           (hash-set! h (agent-id a) (agent-primary-location a))))
                             agents)
                   h))
         (place-of (lambda (pid) (or (hash-ref places pid #f) "?"))))
    (if (null? pairs) '()
        (let ((recs (map (lambda (p)
                           (call-with-values
                             (lambda () (relaxation-records (car p) #f 0 "body"
                                                            #:tau (* 24.0 (assoc-ref stores (cadr p))) #:period-hours period-hours
                                                            #:id (string-append "reserve~" (cadr p) "~" (caddr p))
                                                            #:unit (or (leaf-unit (cadr p)) "x") #:enclosure-hours 1e-5))
                             cons))
                         pairs)))
          `((procs . ,(append-map car recs))
            (flows . ,(append-map cdr recs))
            (resources . ,(map (lambda (pid) (make-economic-resource #:id (string-append "body~" pid) #:conforms-to "body" #:classified-as '()
                                                                     #:accounting-quantity (make-measure 24.0 "hours/day") #:onhand-quantity (make-measure 24.0 "hours/day")
                                                                     #:current-location (place-of pid) #:primary-accountable pid))
                               people))
            (specs . ,(list %body-spec)))))))

(define* (scope-consumption people foods periods where #:optional (shed #f) #:key (specs '()) (units '()) (composition '()))
  ;; a food's classes, off its spec record when the scope has one (knowledge/diets.scm reads the fixture table otherwise)
  (define classes-of
    (let ((h (make-hash-table)))
      (for-each (lambda (sp) (hash-set! h (resource-specification-id sp) (resource-specification-resource-classified-as sp))) specs)
      (lambda (food) (hash-ref h food #f))))
  ;; DIET: the foods this person eats — no class on the food among what their
  ;; tags refuse. The floors stay as they are; the plan closes them from these.
  (define (menu-of a)
    (let ((tags (or (agent-classified-as a) '())))
      (filter (lambda (food) (eats? tags food (classes-of food))) foods)))
  ;; the nutrients a menu CARRIES — catalogues/substances.scm's menu-carries, the guard's one reader
  (define (carried menu) (menu-carries menu))
  ;; one (person, food) EAT recipe → (proc . flows). Process id uses '~' not '|' —
  ;; the planner reserves '|' as a column-key delimiter (p|proc|cell); nutrient GOODS
  ;; keep '|', which is fine for good keys.
  ;; The eat recipe draws the commons' food — the bare good, at the cell the
  ;; person occupies — and reduces it to the nutrients a floor is stated over:
  ;; the common satisfaction of needs, met from the social portion before any
  ;; distribution, never through a claim and never against the certificate.
  ;; It prices nothing. What a person HOLDS ("food~pid", a loaf a claim handed
  ;; them last plan) meets their WANT first (ingest-stock! #:persons) and feeds
  ;; no floor: a column eating one's own food cannot tell a held loaf from one
  ;; this plan claims, and the plan would claim to feed the need — the need
  ;; path through the certificate again, by the back door (found 2026-09-24).
  ;; …and the BODY'S FLOWS (catalogues/substances.scm metabolic-flows): the air's oxygen
  ;; breathed in; the food's nitrogen out as urea, what it does not digest as
  ;; faeces, the rest of its carbon as breath, its hydrogen and water as vapour,
  ;; and the heat its formation leaves once those are formed, so the first law
  ;; closes on the eat on every tracked atom with no loss unnamed; a food the
  ;; release does not carry names none and stays unread
  ;; an eat takes ONE UNIT of the food as the scope counts it (UNITS: spec → unit,
  ;; the spec's own word else the flow's that makes it). Every row is per kilogram
  ;; or per litre, so the nutrients and the body's outputs both scale by what a
  ;; unit is through the one bridge (catalogues/substances.scm unit-scale): a gram of salt
  ;; eats as a thousandth, a stock in megalitres as a million litres, and a floor
  ;; of two litres draws two millionths of it
  (define (unit-of food) (or (assoc-ref units food) "kg"))
  ;; the body eats what the SCOPE says the food is: the row in force (COMPOSITION, per
  ;; unit of the food, what the closure reads of it) stands in front of the table, per
  ;; kilogram as the body's reader takes it, so an eat closes on every atom by
  ;; construction whether the loaf's row came off the release or off its own bake
  (define (rows-eaten food scale)
    (let ((row (assoc-ref composition food)))
      (if (pair? row)
          (cons (cons food (map (lambda (e) (cons (car e) (/ (cdr e) scale))) row)) *contains*)
          *contains*)))
  ;; A SERVING. One run of an eat takes what of the food first fills one of this
  ;; body's floors: a few grams of salt, most of a kilogram of grain, two litres of
  ;; water. It is sized off the body and the food, never off the unit the scope
  ;; happens to count the food in, so every eat column carries its largest share
  ;; of a floor at one and the solve is handed columns of one scale (a kilogram
  ;; of salt a run would put a coefficient a thousand times its neighbours'
  ;; beside them). A food that fills no floor is taken a kilogram a run.
  ;; ASKED ONCE. What a kilogram of a food holds and what a body makes of it are the
  ;; food's, and a body's floors are the body's: each is read once and kept, so a
  ;; crowd of three hundred at seven foods asks seven times and three hundred, never
  ;; their product. The body's books are linear in what is eaten, so a serving's
  ;; flows are the kilogram's times the serving.
  (define (kept read)                    ; READ, remembered by its first argument
    (let ((h (make-hash-table)))
      (lambda (key . rest)
        (let ((known (hash-get-handle h key)))
          (if known (cdr known)
              (let ((v (apply read key rest))) (hash-set! h key v) v))))))
  (define held-per-kg (kept (lambda (food) (nutrient-content food 1.0))))
  (define floors-of (kept (lambda (pid a) (subsistence-bands (agent->subsistence-ctx a 0 shed)))))
  (define body-flows-per-kg (kept (lambda (food scale) (metabolic-flows food 1.0 #:contains (rows-eaten food scale)))))
  (define (serving a food)               ; in the rows' basis, kilograms or litres
    (let* ((floors (floors-of (agent-id a) a))
           (fills (filter-map (lambda (n)
                                (let ((floor (and=> (assoc-ref floors (car n)) car)))
                                  (and floor (> floor 0) (> (cdr n) 0) (/ floor (cdr n)))))
                              (held-per-kg food))))
      (if (null? fills) 1.0 (apply min fills))))
  (define (eat a food)
    (let* ((rid (string-append "eat~" food "~" (agent-id a))) (pid (agent-id a))
           (unit (unit-of food)) (scale (or (unit-scale unit) 1.0))
           (serve (serving a food))
           (rec (closure-reduction (make-recipe-process #:id rid #:name (string-append "eat " food)
                                                        #:sequence-group 0)
                                   (list (list "" food (/ serve scale) unit))   ; the serving, in the unit the scope counts the food in
                                   (closure-rows food 1 #:content (lambda (f q) (map (lambda (r) (cons (car r) (* serve (cdr r)))) (held-per-kg f))))
                                   #:name (lambda (nu) (string-append nu "|" pid)))))
      (cons (car rec)
            (append (cdr rec)
                    (map (lambda (f)
                           (let ((action (flow-action f)) (spec (flow-spec f)) (q (* serve (flow-qty f))))
                             ;; what the body draws flows INTO the eat, what it returns flows OUT of it
                             (flow* (string-append rid (if (input-action? action) "<" ">") spec) action spec q rid
                                    (if (equal? spec "ambient-heat") "kWh" "kg"))))
                         (body-flows-per-kg food scale))))))
  ;; this person's bands, located: per period at the cell they occupy, guarded to
  ;; THEIR menu — a nutrient no food they eat supplies gets no band (its floor
  ;; would be unfillable, its ceiling inert). What the DIET took off the menu —
  ;; a nutrient the scope's foods carry that none they eat does — is said out
  ;; loud: a vegan with no fortified food on the menu is a finding, never a
  ;; silent zero. An omnivore's menu is the whole menu, so the difference is
  ;; empty and nothing is said. A floor the menu carries but cannot fill under
  ;; the body's energy ceiling STANDS — the solve reads it as the infeasibility
  ;; it is — and is named here (menu-starves), since the solve's verdict names
  ;; nothing.
  (define everything (carried foods))
  ;; a floor no food this scope makes carries stands on no form: said once, for the
  ;; scope, so a dropped need (drinking water with no act that draws it) is a
  ;; finding, never a silent zero
  (let ((unmet (filter (lambda (n) (not (member n everything)))
                       (map car (subsistence-bands (agent->subsistence-ctx (car people) 0 shed))))))
    (when (pair? unmet)
      (format (current-error-port) "  [diet] no food this scope makes carries ~a — no floor stands for it (a form that carries it, drawn or grown, would)~%"
              (if (> (length unmet) 6)
                  (format #f "~a of the catalogue's ~a floors, among them ~s" (length unmet) (+ (length unmet) (length everything)) (list-head unmet 3))
                  (format #f "~s" unmet)))))
  (define (bands a)
    (let* ((pid (agent-id a)) (menu (menu-of a))
           (carries (carried menu))
           (rows (subsistence-bands (agent->subsistence-ctx a 0 shed)))
           (lost (filter (lambda (n) (and (member n everything) (not (member n carries)))) (map car rows)))
           (starves (menu-starves menu rows)))
      (when (pair? lost)
        (format (current-error-port) "  [diet] ~a (~a): no food on their menu supplies ~s — no floor stands for it~%"
                pid (string-join (diet-tags (agent-classified-as a)) " ") lost))
      (when (pair? starves)
        (format (current-error-port) "  [menu] ~a: no meal off their menu fills ~s under their energy ceiling — the floor stands, and this scope cannot meet it~%"
                pid starves))
      (closure-bands pid rows carries periods where)))
  (let ((recs (append-map (lambda (a) (map (lambda (food) (eat a food)) (menu-of a))) people)))
    (values (map car recs) (append-map cdr recs) (append-map bands people))))

;; The SUBSTITUTION CATALOGUE: specs carrying a `satisfied-by` DNF. It is the
;; conformance closure's only knowledge source, and — because a skill is just
;; another kind of EconomicResource — it feeds BOTH the labour side (an agent who
;; holds the components CONFORMS to the composite) and the means side (a durable
;; whose spec substitutes for another supplies that other's service). Read once
;; per solve. Empty (or a mock store lacking all-resource-specs) ⇒ no substitution
;; anywhere, and every closure collapses to identity.
(define (substitution-catalogue rs)
  (filter-map (lambda (s)
                (let ((sb (resource-specification-satisfied-by s)))
                  (and (pair? sb) (cons (resource-specification-id s) sb))))
              (or (false-if-exception ($ rs 'all-resource-specs)) '())))

;; ── storability is a fact about the SPEC, so the live path reads it ──────────
;; A container marked keep-in-place holds its contents where they are, so a
;; process that `use`s one and `move`s a good is a move through TIME (storage)
;; rather than through space (transport) — planner.scm's proc-temporal? asks
;; exactly that. Handing the scope's own specs to the solve is what lets a STORE
;; recipe carry a good across a period with no #:storable keyword for a caller to
;; remember: storability is a fact about what the scope HAS.
(define (scope-resource-specs rs)
  (or (false-if-exception ($ rs 'all-resource-specs)) '()))

;; What a skill is, for one scope: the labour? predicate (formulas/actions) over
;; the scope's recipes and specs, read fresh off its store — a root without one
;; (a bare mock) names no labour.
(define (scope-labour? scope-root)
  (let ((rs (false-if-exception ($ scope-root 'recipe-store))))
    (if (not rs)
        (lambda (spec) #f)
        (call-with-values (lambda () (gather-recipes rs))
          (lambda (procs flows) (labour? flows (scope-resource-specs rs)))))))

;; ── a skill's law, live ────────────────────────────────────────────────────
;; A skill's ResourceSpecification may declare its lifecycle as typed tags
;; (skill-law.scm): skill-laws reads them off the scope's specs, and
;; competence-of folds a worker's dated practice through the law to where the
;; skill stands today. A skill with no law reads as its validated ledger.
(define (skill-laws specs)
  (filter-map (lambda (sp)
                (let ((law (skill-law-of (resource-specification-resource-classified-as sp))))
                  (and law (cons (resource-specification-id sp) law))))
              specs))
;; A person's practice is theirs wherever the work was done: the view joins the
;; practice of every observer it reads (planner/observation/practice.scm), so competence,
;; the hours a conformance threshold asks for and the profile read one record.
;; An observer answers its practice as rows (`work-practice`). One that answers
;; only the per-skill ledger (`skill-hours-of`, with `skill-practice` for the
;; dated part when it has one — a mock world) is read through those instead.
(define (observer-practice obs)
  (lambda (aid)
    (catch* #t
      (lambda () ($ obs 'work-practice aid))
      (lambda _
        (append-map
         (lambda (sh)
           (let ((dated (or (false-if-exception ($ obs 'skill-practice aid (car sh))) '())))
             (if (pair? dated)
                 (map (lambda (p) (list (list 'ledger aid (car sh) (car p)) (car sh) (car p) (cdr p))) dated)
                 (list (list (list 'ledger aid (car sh)) (car sh) #f (cdr sh))))))
         (or (false-if-exception ($ obs 'skill-hours-of aid)) '()))))))
(define (practice-view-of obs peers)
  (make-practice-view (map observer-practice (delete-duplicates (cons obs peers) eq?))))
(define (competence-of view aid skill law today)
  (competence-fold (practice-view-dated view aid skill) law #:today today))
;; The engine's skill dynamics for this solve: every person's every held skill
;; that declares a law, opening at where the record leaves it — the endowment
;; at the least, so a declared skill is believed until practice speaks.
(define (skill-dynamics-of view agents skills-of laws today)
  (append-map (lambda (a)
                (if (not (eq? (agent-type a) 'person)) '()
                    (filter-map (lambda (skill)
                                  (let ((law (assoc-ref laws skill)))
                                    (and law
                                         (list (agent-id a) skill law
                                               (max (law-ref law 'endow)
                                                    (competence-of view (agent-id a) skill law today))))))
                                (or (skills-of a) '()))))
              agents))

;; Build the agent→skills function the planner consumes. Held = caller override or
;; the VF ER reading; thresholds read each agent's per-skill ledger ONCE
;; (skill-hours-of), then O(1) lookups — or, for a skill with a law, where its
;; competence stands (the same fold the profile shows). Empty catalogue ⇒
;; agent-skills passes through unchanged (and #f lets plan-from-records default).
(define* (conformance-agent-skills catalogue view resources agent-skills #:optional (laws '()) (today #f) (labour? (lambda (s) #f)))
  (if (null? catalogue)
      agent-skills
      (let ((base (or agent-skills (vf-agent-skills resources labour?)))
            ;; agent-id → ledger: the observer folds the standing work events
            ;; per ask, and the asks run once per labour row (person × period),
            ;; so each agent's ledger is read once and the rows share it
            (ledgers (make-hash-table)))
        (lambda (a)
          (let ((ledger (or (hash-ref ledgers (agent-id a) #f)
                            (let ((l (practice-view-hours view (agent-id a))))
                              (hash-set! ledgers (agent-id a) l) l))))
            (effective-skills (base a) catalogue
                              (lambda (s)
                                (let ((law (assoc-ref laws s)))
                                  (cond (law (competence-of view (agent-id a) s law today))
                                        ((assoc s ledger) => cdr)
                                        (else 0))))))))))

;; A MEANS's conformance closure: the specs it can supply. Same effective-skills a
;; worker's licences flow through, but a means has no practice ledger — it always
;; "meets" any hours floor a substitution clause names (+inf.0), because it is a
;; thing, not a labouring subject. Singleton ⇒ the spec substitutes for nothing.
(define (means-closure spec catalogue)
  (effective-skills (list spec) catalogue (lambda (_) +inf.0)))

;; Partition ITEMS into (suppliers . plain). MAKE-SUPPLIER : item → supplier-record
;; | #f — return a bundle record to pull the item into the supply side, or #f to
;; leave it on the plain side. The shared skeleton of the two substitution splits
;; below: each is just its own MAKE-SUPPLIER predicate. An empty catalogue makes
;; every closure singleton, so MAKE-SUPPLIER is #f throughout and the result is
;; (() . items) — byte-identical to no substitution, no special-case needed.
(define (partition-suppliers items make-supplier)
  (let loop ((xs items) (sups '()) (plain '()))
    (if (null? xs)
        (cons (reverse sups) (reverse plain))
        (let ((s (make-supplier (car xs))))
          (if s (loop (cdr xs) (cons s sups) plain)
                (loop (cdr xs) sups (cons (car xs) plain)))))))

;; The instrument twin of conformance-agent-skills. Service capacity reaches the
;; solve as Svc|spec eco-caps (a durable `use`d draws its per-period service; the
;; socialization path and any commune-owned means both land here). A Svc| cap whose
;; spec has a NON-SINGLETON closure becomes a resource-supplier bundling the whole
;; closure on that one capacity — so a convection-oven's hours also answer a plain
;; `oven` demand. Everything else stays a plain eco-cap. Returns (suppliers . plain).
(define (substitutable-caps-split eco-caps catalogue)
  (partition-suppliers eco-caps
    (lambda (ec)
      (and (svc-good? (car ec))
           (let* ((parts   (string-split (substring (car ec) 4) #\#))  ; Svc|spec#place@t → (spec place@t)
                  (closure (means-closure (car parts) catalogue)))
             (and (pair? (cdr closure))                                ; substitutes for something ⇒ durable? #t supplier
                  (list (car ec) closure (cadr parts) (cdr ec) #t)))))))

;; The STOCK twin: a consumable stock substitutes through the SAME closure, but its
;; budget is the record's own onhand (drawn DOWN, not a renewed service), so it
;; enters as a durable? = #f supplier over BARE goods. A record becomes a stock
;; supplier when its spec (a) has a non-singleton closure, (b) is CONSUMED as a bare
;; good somewhere in that closure — what makes it a stock, and separates it from a
;; durable (whose spec is USED, whose service arrives via Svc| and whose record must
;; stay put for that service to flow), and (c) is not fragility-tracked (removing it
;; from ingest-stock! would drop its *frag-prior* seed). The onhand becomes ONE
;; shared budget across the closure — spend it as the held spec OR any it satisfies.
(define (substitutable-stock-split resources catalogue consumed used frag period)
  ;; one place rule: a supplier sits where the containment walk says it does, the
  ;; same answer ingest-stock! reads for an ordinary holding (resource-place)
  (define resolve (resource-resolver resources))
  (partition-suppliers resources
    (lambda (r)
      (let ((spec (economic-resource-conforms-to r)))
        (and spec (not (hash-ref used spec #f)) (not (member spec frag))
             (let ((closure (means-closure spec catalogue)))
               (and (pair? (cdr closure))
                    (any (lambda (s) (hash-ref consumed s #f)) closure)
                    (list (economic-resource-id r) closure (cell (resource-place r resolve) period)
                          (mqty (economic-resource-onhand-quantity r)) #f))))))))

;; The specs a recipe set draws under a given ACTION — 'consume (a stock) vs 'use (a
;; durable's service) — as a hash-set: FLOWS and the distinct drawn specs are both
;; O(population) once per-person goods enter (the reserve recipes consume
;; "energy|pid"), so the split above reads membership in O(1) where a list dedup
;; and a `member` scan per closure element each cost a crowd a crowd's worth.
(define (specs-with-action flows action)
  (let ((h (make-hash-table)))
    (for-each (lambda (f) (when (eq? (recipe-flow-action f) action)
                            (let ((sp (recipe-flow-resource-conforms-to f)))
                              (when sp (hash-set! h sp #t)))))
              flows)
    h))

;; The whole substitution routing in ONE pass: durable Svc| caps and consumable
;; stocks alike leave their normal channel and join the supply bundles, capped by
;; their spec's closure; what does not substitute stays a plain cap / plain record.
;; Returns (values suppliers plain-caps plain-resources) — the three inputs the
;; solve needs, split together. Empty catalogue ⇒ no suppliers, inputs untouched.
;; Both halves reach the robust (#:scenarios) solve — the closure is structural,
;; identical across weather draws — so a substitutable input is available in each.
(define (substitution-split eco-caps resources catalogue flows frag period)
  (let ((cs (substitutable-caps-split eco-caps catalogue))
        (rs (substitutable-stock-split resources catalogue
              (specs-with-action flows 'consume) (specs-with-action flows 'use) frag period)))
    (values (append (car cs) (car rs)) (cdr cs) (cdr rs))))

;; ── the wiring: live scope-root → plan → VF work intents + commitments ───────
(define* (plan-scope scope-root #:key (demand '()) (periods '(0)) (movable '())
                                      (storable '()) (whole '()) (tau 0.0) (hold 0.0)
                                      ;; ECO-FRAG: located-good fragility rows ((good . (lo hi α w)) …),
                                      ;; `*frag-cap*`'s own shape — passed straight through to
                                      ;; `plan-from-records`, which accepts it beside #:eco-spec-frag.
                                      ;; A barrier on a RAW drawn at one cell; a good some column
                                      ;; produces is never read here (engine good-index: made ⇒ good).
                                      (eco-frag '())
                                      ;; PROC-FRAG: fragilities on an ACT's own level,
                                      ;; ((recipe-process-id . (lo hi α w)) …) — engine `*proc-frag*`,
                                      ;; read off the `p|proc|…` columns like `#:whole`: a wall on how
                                      ;; far an act may run, felt before it is reached. Empty ⇒
                                      ;; byte-identical, like every optional wall here.
                                      (proc-frag '())
                                      ;; ADMIT?: gather-recipes' admission seam, (recipe → bool) —
                                      ;; a recipe the policy does not admit contributes no processes
                                      ;; and no flows. Injected, because admission is governance's
                                      ;; to decide; #f ⇒ the whole patchwork, as always.
                                      (admit? #f)
                                      (eco-caps '()) (eco-spec-frag #f) (reserve '()) (backend 'native-c)
                                      ;; LIMITS: ecological limits carried as regenerating stocks of
                                      ;; headroom rather than as walls — the tension registry's
                                      ;; `eco-stocks` view of the same ratified catalogue. Each brings
                                      ;; its own level, nature's attenuation recipe where the science
                                      ;; records one, and that recipe's per-period gate. Empty ⇒ every
                                      ;; limit stays a fragility and the solve is unchanged.
                                      (limits '())
                                      ;; ((spec (element . mass-fraction) …) …) — the chemistry, as
                                      ;; policy. Given, every template gains its element rows and
                                      ;; conservation becomes a CONSTRAINT: an element cannot be
                                      ;; conjured, and an unnamed loss shows as element nobody
                                      ;; claimed (utils/capacity.scm's twin for matter). Empty ⇒ the
                                      ;; solve is byte-identical. The closure through `contains` is
                                      ;; taken caller-side (`closed-composition`), so nothing here
                                      ;; re-walks it and the engine holds no chemistry.
                                      (composition '())
                                      (warm-x #f) (decided #f) (node-budget #f) (willing? #f) (legal-forbids? #f) (legal-decorate #f)
                                      (voice-tau 0.0) (voice-pushes (quote ())) (voice-hours #f) (scope-path #f)   ; the voice field (engine
                                      ;; solve/voice-field.scm); τ = 0 ⇒ today
                                      ;; PRACTICE-PEERS: a thunk answering the other observers whose work
                                      ;; events are a person's practice too (the roster's); #f ⇒ this scope's alone
                                      (practice-peers #f)
                                      ;; AGENT-OF: (aid → agent | #f), a person's record where it is kept —
                                      ;; their home; a visitor's away days are read there. #f ⇒ this scope's store alone
                                      (agent-of #f)
                                      (pref-bound #f) (emp-rho #f) (kappa #f) (want-as-cap 'unstated) (stock-draw-hours #f)   ; the governed dials (voice/quorum.scm); unstated ⇒ the engine's standing value
                                      ;; ((aid . drawable-hours) …): each citizen's certificate, the
                                      ;; bar over their claim columns (engine *certificates*). The
                                      ;; scope door reads it off the account-store when unstated
                                      ;; (with-scope-defaults); '() ⇒ no bar, credit tallied only.
                                      (certificates '())
                                      ;; a declared partition ((start . end) …), boundaries carrying an
                                      ;; optional THH:MM — the band dial (set-clock-horizon! lays one out);
                                      ;; a day of several bands is what lets a mover make two hops in it
                                      (period-spans #f)
                                      (agent-position #f) (agent-skills #f) (horizon #f)
                                      (arc-table 'auto) (manners '()) (never-raw '()) (raws '())
                                      (agent-hours #f) (repro-floors '()) (budgeted-floors '()) (maximin? #t) (reproduce? #t)
                                      ;; the plan asked backwards (engine *acquire*): what may be bought in, at
                                      ;; what price in hours, and the tier held as a wall — rights | needs | wants
                                      (acquire '()) (promote #f)
                                      ;; the other walls of a good's band, and the calamity reserve:
                                      ;; #:repro-caps ((located-good . (hi . w))) a toxicity/spoilage
                                      ;; ceiling; #:insurance ((located-good lo hi α w)) an explicit
                                      ;; reserve. #:insure? (ON by default, like reproduce?) stands
                                      ;; the GOVERNED reserve (catalogues/insurance.scm, q^res = ι·q*)
                                      ;; behind every demanded good whose spec carries a row — a
                                      ;; ratified row is a decision already made, and a plan carries
                                      ;; it unless the scope says #:insure? #f (a study that wants the
                                      ;; want alone). No row ⇒ no reserve, nothing changes.
                                      (repro-caps '()) (insurance '()) (insure? #t)
                                      ;; ((located-good . w_d) …): the priority a want enters
                                      ;; harmony at (engine *desire-weight*, β^level); the fold's
                                      ;; quantity-weighted mean of its citizens' levels. Absent ⇒ 1.
                                      (desire-weights '())
                                      ;; INSPECTION in the solve (solve/inspection.scm): #t, or an alist
                                      ;; of scope-inspection options ((verifier . "auditor") (wear .
                                      ;; 1.0) (restore . 1.0) (fresh . 0.0)) — every conformance
                                      ;; edge the scope's recipes lean on becomes a freshness stock
                                      ;; the plan must keep, and the verifier's hours are scheduled
                                      ;; on the one budget. #f ⇒ unchanged; the recert schedule is
                                      ;; still read off the plan either way.
                                      (inspect #f)
                                      (allow-infeasible? #f)
                                      ;; ((resource-id . place) …) — governed pool SPANS: how far a
                                      ;; means' service pools, declared rather than read off where it
                                      ;; sits (span-declaration ACDC → live-span-of). Empty ⇒ every
                                      ;; pool stands at its holding place, exactly as before.
                                      (span-of '())
                                      ;; RECEDING HORIZON, #f by default (existing behaviour, byte-for-
                                      ;; byte). Time does not end; the solve does, at whichever period
                                      ;; its window currently reaches, and a receding-horizon re-solve
                                      ;; re-truncates there every time it runs. #t: whatever floor a
                                      ;; caller already declared, recurring, for a STORABLE spec — the
                                      ;; SAME convex constraint already in force at every other period —
                                      ;; also covers the one period beyond what is modeled, at the
                                      ;; horizon's own last period. No new target number: the amount
                                      ;; that already recurs is what continues to recur: the terminal
                                      ;; located-good's own already-declared floor is asked for TWICE
                                      ;; (this period's need, and the next, unmodeled, one). Desire needs
                                      ;; no matching treatment — a soft target is already "aimed at" the
                                      ;; same way at every period; the horizon's edge earns it nothing
                                      ;; extra, because nothing ends when a desire alone goes unmet.
                                      (receding-horizon? #f)
                                      ;; resource-view: a pure transform applied to the observer's
                                      ;; resources before the solve (default identity). Keeps the
                                      ;; planner governance-agnostic while letting a caller project a
                                      ;; per-solve VIEW onto them — e.g. socialization's custodian
                                      ;; projection (project-socialized-custody), a derived view of the
                                      ;; live grants, never a stored mutation.
                                      (resource-view (lambda (rs) rs))
                                      ;; arriving: the previous plan's material rows, so stock on the
                                      ;; way (a relocation's cargo, at no place in the books) counts
                                      ;; where its open dropoff lands it (arriving-lots)
                                      (arriving '())
                                      ;; robust multi-scenario (docs/planning/solve/robust-multiscenario.md):
                                      ;; a list of <planning-scenario> + the proc-ids committed before
                                      ;; the uncertainty resolves. ABSENT ⇒ ordinary deterministic solve.
                                      (scenarios '()) (first-stage-procs '())
                                      ;; contrary observations ((process action nominal reading) …):
                                      ;; the world as workers have seen it, laid over EVERY
                                      ;; future (engine/robust.scm observed-shocks); the scope's
                                      ;; standing supplies them (service standing-kw)
                                      (observed '())
                                      ;; each recipe's RESPONSE, off its own runs
                                      ;; (solve/recipe-response.scm): its acts, its flows, the
                                      ;; curve of what it captured at each stress delivered,
                                      ;; its position. Every future reads the curve at the
                                      ;; stress it delivers to the recipe's own flows — the
                                      ;; recipe yields there what its record says it delivers
                                      ;; there (futures-under-record) — so the plan leans on a
                                      ;; recipe future by future, in proportion. In the
                                      ;; future a floor is defended in without a forecast
                                      ;; (p = 0), a recipe yields by how far its record
                                      ;; covers that future beside the best-covered recipe
                                      ;; for its output: needs rest on what has been
                                      ;; proven. The scope's standing supplies them
                                      (responses '())
                                      ;; 'standing = compile the plan-store's accepts
                                      ;; (the live default); a LIST is used as given —
                                      ;; '() is the pins-freed counterfactual the
                                      ;; regret diagnostic solves (accept-regret)
                                      (pins 'standing)
                                      ;; commitments joined to the standing compile —
                                      ;; the fresh check's trial rides a CANDIDATE
                                      ;; accept through the very compile the real one
                                      ;; would get (make-fresh-check)
                                      (extra-accepts '())
                                      ;; WHERE THE SOLVE RUNS: (thunk k) — call THUNK (the pure
                                      ;; program: ingest + solve, no `$`) and hand its values
                                      ;; to K (the landing: reads the stores, persists, reads
                                      ;; the engine's tables the solve set). Inline by default;
                                      ;; the service hands a worker-thread runner that returns
                                      ;; a promise, so the vat is free while a solve runs.
                                      (solve-in #f))
  "Plan over the scope's LIVE state. demand = ((located-good . target) …). Returns
   (values intents commitments fill x newton): the work INTENDED (provider unbound)
   and the COMMITMENTS that satisfy it; x is the activity vector (a warm start for
   the next re-solve) and newton the step count. Pass #:warm-x a prior x of the
   same shape for a METABOLISM warm re-solve. Skills from each agent's skill ERs;
   hours from availabilityWindow. CONFORMANCE: a spec's `satisfied-by` lets an
   agent who holds the component skills (at ≥ the clause's validated hours) supply
   it via the effective-skills closure — so {electrician,surgeon} can fill an
   electrosurgery slot without holding electrosurgeon directly."
  (let* (;; The periods the solve will ACTUALLY run over. A #:horizon derives them
         ;; (set-daily-horizon! lays out 0…n-1 with wall-clock spans), and it does so
         ;; inside plan-from-records — so anything plan-scope computes per period must
         ;; read the horizon HERE, first, or it silently sizes itself to the single
         ;; default period while the solve runs over many.
         (periods (cond (horizon (iota (cdr horizon)))
                        (period-spans (iota (length period-spans)))   ; one period per declared band
                        (else periods)))
         ;; receding-horizon?: double whichever #:repro-floors entries the
         ;; caller ALREADY declared at the horizon's LAST period, for a spec
         ;; also named #:storable — no new number, no new channel, the SAME
         ;; recurring floor asked for once more. Non-storable and non-terminal
         ;; entries pass through untouched; plan-from-records never learns
         ;; this pass ran.
         (repro-floors
          (if (and receding-horizon? (pair? periods))
              (let ((terminal-last (apply max periods)))
                (append repro-floors
                  (filter-map (lambda (rf)
                                (and (= (period-of (cadr (string-split (car rf) #\#))) terminal-last)
                                     (member (good-spec (car rf)) storable)
                                     rf))
                              repro-floors)))
              repro-floors))
         (obs ($ scope-root 'observer))
         (as  ($ scope-root 'agent-store))
         (sts ($ scope-root 'spatial-thing-store))
         (rs  ($ scope-root 'recipe-store))
         ;; ── what #:limits contributes, named in one place ───────────────────
         ;; A migrated limit is a LEVEL, so it reaches the solve as five ordinary
         ;; inputs at once: its headroom stands among the resources (an ordinary
         ;; starting stock, so flows that already draw the spec spend it with no
         ;; recipe change anywhere); the spec carries in time; nature's attenuation
         ;; is a recipe gated per period; and the profile's governance weight goes
         ;; to #:stock-frag so the level's ≥0 balance stays felt at the optimum
         ;; rather than reverting to the swept bar. Empty ⇒ all five are '() and
         ;; the solve is untouched.
         (lim-resources (migrated->resources  limits))
         (lim-storables (migrated->storables  limits))
         (lim-caps      (migrated->caps       limits periods))
         (lim-procs     (migrated->procs      limits))
         (lim-flows     (migrated->flows      limits))
         (lim-weights   (migrated->stock-frag limits))
         (resources (append (resource-view (arriving-lots obs arriving ($ obs 'all-resources))) lim-resources))
         (storable  (append storable lim-storables))
         (eco-caps  (append eco-caps lim-caps))
         ;; MONEY is never a free raw: every spec the scope's knowledge marks
         ;; medium-of-exchange (EUR, XMR, a pooled maintenance fund's dollars) joins
         ;; never-raw, so a solve can spend only what a purse holds — a
         ;; consume-grant's stock, a donation's raise — and never conjure it.
         ;; A caller's own never-raw rides beside it.
         (never-raw (delete-duplicates
                     (append never-raw
                             (filter-map (lambda (sp)
                                           (and (resource-specification-medium-of-exchange sp)
                                                (resource-specification-id sp)))
                                         (scope-resource-specs rs)))))
         (agents    ($ as 'all-agents))
         (spatials  ($ sts 'all-locations))
         ;; The bioregion this scope sits in (walk up the contained-in tree, once).
         ;; A scope inherits BOTH channels from it unless given explicitly: its FUTURES
         ;; (#:scenarios) and its LIMITS (#:eco-spec-frag). Placing a scope in a
         ;; bioregion is all onboarding needs. ROBUST BY DEFAULT
         ;; (commitment-horizon.md): a scope with no shed and no declared
         ;; futures still solves through the robust assembly, as the one
         ;; deterministic branch — the same program, assembled through the one
         ;; door that reads standing accepts (#:pins) and held offers (#:holds).
         (shed      (scope-bioregion spatials))
         (scenarios     (let ((futures (if (null? scenarios)
                                           (or (and=> shed bioregion-scenarios)
                                               (list (make-planning-scenario "deterministic" #f 1.0 '() #f)))
                                           scenarios))
                              (seen (observed-shocks observed)))
                          (futures-under-record futures responses seen)))
         ;; THREE states, and #f is the sentinel — not a synonym for '():
         ;;   #f    (not supplied) ⇒ INHERIT the shed's fragilities by containment
         ;;   (…)                  ⇒ override with exactly those
         ;;   '()                  ⇒ explicitly NO limits (an unconstrained run,
         ;;                          inexpressible if '() meant "inherit")
         ;; Anything forwarding this value onward must pass it through AS-IS,
         ;; including #f: re-defaulting to '() anywhere in the chain silently
         ;; kills inheritance, and silently is the word — '() is a legal value
         ;; meaning "no limits", so the scope simply plans without its shed's.
         (eco-spec-frag (if eco-spec-frag
                            eco-spec-frag
                            (or (and=> shed bioregion-fragilities) '())))
         ;; One substitution catalogue, read once, feeding BOTH conformance sides:
         ;; agents (labour) and means (service capacity). A skill is just another
         ;; EconomicResource, so both close over the very same satisfied-by DNF.
         (catalogue  (substitution-catalogue rs))
         ;; each skill's law off its spec, and this instant — the record is
         ;; folded to where every held skill stands today
         (laws       (skill-laws (scope-resource-specs rs)))
         (today      (instant->unix (now)))
         (practice   (practice-view-of obs (if practice-peers (practice-peers) '())))
         (labour-of  (scope-labour? scope-root))   ; what a skill is: a worked spec (formulas/actions labour?)
         (eff-skills (conformance-agent-skills catalogue practice resources agent-skills laws today labour-of))
         ;; the engine's skill dynamics: who is trainable in what, opening where
         ;; the record leaves them (engine apply-skill-dynamics!)
         (skill-dyn  (if (null? laws) '()
                         (skill-dynamics-of practice agents (or eff-skills (vf-agent-skills resources labour-of)) laws today)))
         ;; 'auto: routing priors ⊕ observed-trip EWMA; an alist passes through;
         ;; anything else (e.g. '()) disables — pure rate×haversine geometry.
         (arcs (cond ((eq? arc-table 'auto) (live-arc-table obs manners #:manner-of (trip-manner-of scope-root)))
                     ((pair? arc-table) arc-table)
                     (else '())))
         ;; the planner classes its periods by their own spans unless the
         ;; deployment declares finer classes
         (manners* (if (assq 'period-class manners) manners
                       (cons (cons 'period-class span-derived-period-class)
                             manners)))
         ;; ── where each agent IS, per period: ONE rule, read by both sides ──
         ;; A live or declared override wins (service.scm agent-position-predicate:
         ;; live GPS → committed work → declared future); their registered home is
         ;; the floor. The planner builds the labour cell and commute origin from
         ;; it (planner.scm), and `scope-consumption` below puts the person's
         ;; reproduction floors in the same cell — so someone standing in the park
         ;; is someone whose skills are reachable from the park and whose nutrition
         ;; is wanted at the park. Reading it in two places from one rule keeps the
         ;; two halves of a person's economy in the same spot.
         (homes (let ((h (make-hash-table)))
                  (for-each (lambda (a) (hash-set! h (agent-id a) (agent-primary-location a)))
                            agents)
                  h))
         (agent-cell (lambda (id t)
                       (or (and agent-position (agent-position id t))
                           (hash-ref homes id #f)))))
    ;; Observability: with no routing arcs, arc-topology? derives nothing, so
    ;; the solve runs over the fully-connected default (every place coupled to
    ;; every other — O(P²) transport columns). Correct as a safe superset, but
    ;; silent — surface it so a degraded-to-geometry solve is visible, not
    ;; mistaken for a routing-informed one. Fires only on the empty-arcs path.
    (when (null? arcs)
      (simple-format (current-error-port)
        "[plan-scope] no routing arcs — solve fully-connected over ~A place(s)~%"
        (length spatials)))
    (call-with-values (lambda () (call-with-values (lambda () (gather-recipes rs #:admit? admit?))
                                   (lambda (ps fs)
                                     (let ((specs (scope-resource-specs rs)))
                                       (call-with-values (lambda () (keeping-processes specs (resource-view (arriving-lots obs arriving ($ obs 'all-resources)))))
                                         (lambda (kp kf) (expand-cargo-classes (append ps kp) (append fs kf) specs)))))))
      (lambda (procs00 flows00)
       (let* ((supplied (let ((h (make-hash-table)))          ; the goods this scope can hand a citizen
                          (for-each (lambda (f)
                                      (when (and (output-flow? f)
                                                 (recipe-flow-resource-conforms-to f))
                                        (hash-set! h (recipe-flow-resource-conforms-to f) #t)))
                                    (append flows00 lim-flows))
                          (for-each (lambda (r)
                                      (let ((sp (economic-resource-conforms-to r)))
                                        (when sp (hash-set! h sp #t))))
                                    resources)
                          h))
              ;; the claim's credit leg: the good's crystallized SNLT off the scope's recipes
              ;; one rollup per DISTINCT spec: the claim goods run O(crowd ×
              ;; wants) over a handful of base specs, and the rollup walks the
              ;; recipe store — memoized, each spec's price is read once
              (price-of (let ((memo (make-hash-table)))
                          (lambda (spec)
                            (if (hash-get-handle memo spec) (hash-ref memo spec)
                                (let ((h (false-if-exception (crystallized-snlt-for-spec rs spec))))
                                  (hash-set! memo spec h) h)))))
              (procs0 (append procs00 lim-procs))              ; nature's own return,
              ;; alongside the scope's recipes, each flow restated in the unit its spec is
              ;; counted in (catalogues/substances.scm flows-in-spec-units): one number for one thing,
              ;; whatever unit the recipe was written in
              (flows0 (flows-in-spec-units
                       (append flows00 lim-flows)
                       (specs->units (scope-resource-specs rs))))
              ;; THE CLAIMS, derived once every per-person recipe stands: one claim edge per
              ;; owned good a citizen asks for (demand "spec~aid") — a want, and only a
              ;; want: a need is met from the commons' own stock (the eat recipe draws the
              ;; bare food) and gets no edge, so every claim column is the certificate's
              ;; to bound. None for a means: what a process USES, no person claims, so an
              ;; oven or a field never gets an edge however it is asked for or tagged. The plan publishes the
              ;; whole rail (rail.scm rails-of: individual | communal | means) off the
              ;; verbs alone — a claim's spec is individual, a spec only the scope's own
              ;; recipes consume is communal, a `use`d spec is a means, and a good made
              ;; or stocked that is nobody's input is individual. A record's tag never
              ;; enters: the rail is derived, so no declared word can put a good on it.
              (with-claims
               (lambda (procs flows)
                 (let* (;; USED, deduplicated by a hash-set in one pass over FLOWS instead
                        ;; of `delete-duplicates` (SRFI-1, pairwise `equal?` — O(flows²)) —
                        ;; a crowd's flows make FLOWS big, and MEANS? below used to re-scan
                        ;; the deduplicated list with `member` once per flow on top of that.
                        ;; USED-SET is the same hash, reused for both: same first-occurrence
                        ;; order as delete-duplicates, O(1) membership for means?.
                        (used-set (make-hash-table))
                        (used    (let ((acc '()))
                                   (for-each (lambda (f)
                                               (when (eq? (recipe-flow-action f) 'use)
                                                 (let ((sp (recipe-flow-resource-conforms-to f)))
                                                   (when (and sp (not (hash-ref used-set sp #f)))
                                                     (hash-set! used-set sp #t)
                                                     (set! acc (cons sp acc))))))
                                             flows)
                                   (reverse acc)))
                        (means?  (lambda (spec) (hash-ref used-set spec #f)))
                        (unit-of (let ((h (make-hash-table)))
                                   (for-each (lambda (f)
                                               (let ((sp (recipe-flow-resource-conforms-to f))
                                                     (m  (recipe-flow-resource-quantity f)))
                                                 (when (and sp m (memq (recipe-flow-action f) using-up-actions) (spec-owner sp))
                                                   (hash-set! h (car (spec-owner sp)) (measure-has-unit m)))))
                                             flows)
                                   (lambda (spec) (or (hash-ref h spec #f) %count-unit))))
                        (goods   (owned-goods-of-demand demand))   ; distinct by construction
                        (cl      (claim-recipes goods
                                                #:supplied? (lambda (spec) (hash-ref supplied spec #f))
                                                #:price price-of #:means? means? #:unit-of unit-of)))
                   (let* ((claimed  (filter-map (lambda (p) (and=> (spec-owner (substring (recipe-process-id p) 6)) car))
                                                (car cl)))
                          ;; the scope's own inputs: a bare spec some recipe consumes (a
                          ;; person's owned form "spec~aid" is their claim's, not the scope's)
                          (consumed (filter-map (lambda (f)
                                                  (let ((sp (recipe-flow-resource-conforms-to f)))
                                                    (and sp (memq (recipe-flow-action f) using-up-actions) (not (spec-owner sp)) sp)))
                                                flows))
                          ;; what stands to be claimed at all: made by one of the SCOPE's
                          ;; recipes (FLOWS0 — the eat recipes appended to FLOWS are each
                          ;; person's own metabolism, and its products, nutrient pools and
                          ;; exhalations, are nobody's to claim), or stocked — a stock of
                          ;; labour (a held skill, labour-of) being no good either
                          (made     (append (filter-map (lambda (f)
                                                          (let ((sp (recipe-flow-resource-conforms-to f)))
                                                            (and sp (output-flow? f) (not (spec-owner sp)) sp)))
                                                        flows0)
                                            (filter-map (lambda (r)
                                                          (let ((sp (economic-resource-conforms-to r)))
                                                            (and sp (not (labour-of sp)) sp)))
                                                        resources))))
                     (let ((rails (rails-of #:used used #:consumed consumed #:made made #:claimed claimed)))
                       (publish-rails! rails)
                       ;; THIS scope's own word, keyed so no other scope's solve can
                       ;; ever answer for it (the legacy table above still can, and
                       ;; stays the fallback for a caller that names no store)
                       (set-rails! (false-if-exception ($ scope-root 'recipe-store)) rails)))
                   (values (append procs (car cl)) (append flows (cdr cl)))))))
        ;; reproduction of labour-power: add per-person EAT recipes (food → the
        ;; person's nutrients) + floors at the cell each person occupies in each
        ;; period. A person eats every day of the horizon, wherever they are that
        ;; day, so the plan provisions along their trajectory WHEREVER a real
        ;; carry path already reaches that cell — #:movable/#:storable if a
        ;; caller named food there, or (the honest default) a scope's own
        ;; STORE/HAUL recipe, which prices the driver's labour and any spoilage
        ;; as an ordinary consume (test-store-recipe.scm) rather than granting
        ;; food a free, lossless teleport no other good gets. Gated — off ⇒ the
        ;; plan is unchanged.
        (call-with-values
         (lambda ()
           (let ((people (and reproduce? (filter (lambda (a) (eq? (agent-type a) 'person)) agents)))
                 (foods  (and reproduce? (scope-food-specs flows0))))
             ;; a pure no-op unless the scope has BOTH eaters and nutritious foods —
             ;; so reproduction is on by default and free for every other solve.
             (if (and reproduce? (pair? people) (pair? foods))
                 (call-with-values (lambda () (scope-consumption people foods periods agent-cell (and=> shed bioregion-id)
                                                                 #:specs (scope-resource-specs rs)
                                                                 #:composition composition   ; what the scope says each food is
                                                                 ;; what a unit of each food is: the spec's stated unit, else the
                                                                 ;; unit of the flow that makes it (a mock store states no specs)
                                                                 #:units (append (specs->units (scope-resource-specs rs))
                                                                                 (filter-map (lambda (f) (and (output-flow? f) (recipe-flow-resource-conforms-to f)
                                                                                                             (and=> (recipe-flow-resource-quantity f) measure-has-unit)
                                                                                                             (cons (recipe-flow-resource-conforms-to f) (measure-has-unit (recipe-flow-resource-quantity f)))))
                                                                                             flows0))))
                   (lambda (ep ef ebands)
                     (call-with-values (lambda () (with-claims (append procs0 ep) (append flows0 ef)))
                       (lambda (p f) (values p f ebands movable)))))
                 (call-with-values (lambda () (with-claims procs0 flows0))
                   (lambda (p f) (values p f '() movable))))))
         (lambda (procs0* flows0* ebands mov)
        ;; INSPECTION: from the scope's own recipes, every conformance edge they lean
        ;; on becomes a Verif| freshness stock (wear per run, restored by an inspect
        ;; recipe costing the verifier's hours), storable, its margin a band floor
        ;; held at the governed steepness. One builder, one alist; nothing when off.
        (let* ((ins (if inspect
                        (apply scope-inspection procs0* flows0* (map spatial-thing-id spatials) periods
                               #:steepness (or (conformance-frag-weight) 0.5)
                               (if (pair? inspect)
                                   (alist->kw inspect)
                                   '()))
                        '()))
               ;; HOUSING: scope-consumption's twin, for the night. A scope whose
               ;; dwellings state their type (resource->dwelling-unit) houses its
               ;; people against the adequacy catalogue: live-in recipes per
               ;; (person, dwelling), each person's bands at the cell they occupy,
               ;; and the period's facts — a night falls, a dwelling stands — as
               ;; pins. One builder, one alist; nothing unless the scope has both
               ;; people and typed dwellings, so every other solve is unchanged.
               (hz (let ((people (filter (lambda (a) (eq? (agent-type a) 'person)) agents))
                         (units  (filter-map resource->dwelling-unit resources)))
                     (if (and reproduce? (pair? people) (pair? units))
                         (let* ((ctx (agent->subsistence-ctx (car people)))
                                ;; the season every night reads: today's month, the hemisphere of the first person who states a latitude
                                (season (season-of (or (assq-ref ctx 'month) 6)
                                                   (any (lambda (a) (assq-ref (agent->subsistence-ctx a) 'lat)) people))))
                           (scope-housing people units periods agent-cell (map spatial-thing-id spatials)
                                          #:ctx-of agent->subsistence-ctx #:season season
                                          ;; what the season is like outside, off the shed's record: what a
                                          ;; dwelling's envelope leaks against (catalogues/housing.scm outdoor-degc)
                                          #:outdoor (outdoor-degc (assq-ref ctx 'shed) season)))
                         '())))
               ;; RESERVES: a nutrient the body stores (catalogues/subsistence.scm
               ;; reserve-nutrients) carries in the person's own good from period to
               ;; period through a store-shaped recipe that leaks at the store's rate,
               ;; the body its enclosure: reproduction as conservation, read off the
               ;; bands that already stand. One builder, one alist; nothing without bands.
               (rv (if reproduce? (scope-reserves ebands agents) '()))
               (procs (append procs0* (or (assq-ref ins 'procs) '()) (or (assq-ref hz 'procs) '()) (or (assq-ref rv 'procs) '())))
               (flows (append flows0* (or (assq-ref ins 'flows) '()) (or (assq-ref hz 'flows) '()) (or (assq-ref rv 'flows) '())))
               (resources* (append resources (or (assq-ref ins 'resources) '()) (or (assq-ref rv 'resources) '())))
               (storable* (append storable (or (assq-ref ins 'storable) '())))
               (ebands* (append ebands (or (assq-ref ins 'bands) '()) (or (assq-ref hz 'bands) '())))
               ;; the calamity reserve: explicit rows, plus the governed ones behind
               ;; every demanded good that carries a catalogue row
               ;; a governed reserve stands on the SCOPE's good at the cell,
               ;; sized from every citizen's want there — owned wants folded back
               (insurance* (append insurance (if insure? (insurance-rows (unowned-demand demand)) '()))))
        ;; Substitution routes the solve's inputs: substitutable Svc| caps and
        ;; consumable stocks alike become supply bundles over their closure, and
        ;; what's left stays a plain cap / plain resource. Runs HERE, where `flows`
        ;; is in hand (the stock half needs the consume/use roles), and shadows
        ;; eco-caps + resources with the reduced sets.
        (call-with-values (lambda ()
          ;; the bare specs the fragilities concern — read through engine/fragility.scm,
          ;; since the list may hold (spec . profile) pairs OR <fragility> records
          ;; and each extent names its specs differently. `car` read only the
          ;; first shape and errors on the second.
          (substitution-split eco-caps resources* catalogue flows
                              (fragility-specs-of eco-spec-frag) (car periods)))
         (lambda (resource-suppliers eco-caps resources)
        ;; the scope's WORLD, as one alist: the program plan-from-records is
        ;; handed, and — should it have no answer — the same program each horn
        ;; of a dilemma is priced on. Built once so the two can never drift.
        (let ((world
               `((composition . ,composition) (span-of . ,span-of)
                 (demand . ,demand) (periods . ,periods) (movable . ,mov) (storable . ,storable*)
                 ;; which of this scope's acts are countable — stated by the scope,
                 ;; the same way storability is
                 (whole . ,whole)
                 (specs . ,(append (scope-resource-specs rs) (or (assq-ref rv 'specs) '())))
                 (tau . ,tau) (hold . ,hold) (eco-frag . ,eco-frag) (proc-frag . ,proc-frag) (eco-caps . ,eco-caps) (eco-spec-frag . ,eco-spec-frag)
                 (reserve . ,reserve) (backend . ,backend) (desire-weights . ,desire-weights)
                 (warm-x . ,warm-x) (decided . ,decided) (node-budget . ,node-budget) (willing? . ,willing?)
                 (voice-tau . ,voice-tau) (voice-pushes . ,voice-pushes) (voice-hours . ,voice-hours) (scope-path . ,scope-path)
                 (pref-bound . ,pref-bound) (emp-rho . ,emp-rho) (kappa . ,kappa) (want-as-cap . ,want-as-cap) (stock-draw-hours . ,stock-draw-hours)
                 (certificates . ,certificates)
                 (legal-forbids? . ,legal-forbids?) (legal-decorate . ,legal-decorate)
                 (agent-position . ,agent-cell)           ; the same rule the floors read
                 (agent-hours . ,(or agent-hours agent-window-hours))
                 (agent-skills . ,eff-skills)
                 (skill-dynamics . ,skill-dyn)
                 ;; a live scope's labour is its PEOPLE's, even when it has none yet:
                 ;; 'roster holds the per-worker regime for an unpeopled scope too, so
                 ;; work nobody can supply stops its recipe (engine *roster-labour?*)
                 (per-agent? . roster)
                 ;; live planning trusts the network: matrix arcs become topology
                 ;; wherever no transport edges were declared (declared edges win).
                 (horizon . ,horizon) (period-spans . ,period-spans) (arc-table . ,arcs) (arc-topology? . #t)
                 (stock-frag . ,lim-weights)                     ; levels, still felt at the optimum
                 ;; what a drawn stock weighs: the crystallized SNLT of every spec the
                 ;; scope holds, off the recipe store's own rollup — the price a claim
                 ;; pays and the weight the plan feels are one number (playnet.typ
                 ;; "Credits and external liquidity"). The engine keeps the finite ones.
                 (stock-prices . ,(filter-map
                                   (lambda (sp) (let ((h (price-of sp))) (and (real? h) (cons sp h))))
                                   (delete-duplicates (filter-map economic-resource-conforms-to resources))))
                 ;; reservation-aware capacity: a resource registered in the
                 ;; scope's live-registry ingests at its live `available` —
                 ;; what the reservations leave free — instead of onhand
                 (live-avail . ,(live-availability (scope-part scope-root 'live-registry)))
                 (manners . ,manners*) (never-raw . ,never-raw) (raws . ,raws)
                 (repro-floors . ,repro-floors) (budgeted-floors . ,budgeted-floors) (maximin? . ,maximin?) (bands . ,ebands*)   ; every person's nutrient bands, both walls (+ Verif| freshness margins)
                 (repro-caps . ,repro-caps) (insurance . ,insurance*) ; the other walls, and the calamity reserve
                 (resource-suppliers . ,resource-suppliers) (allow-infeasible? . ,allow-infeasible?)
                 (acquire . ,acquire) (promote . ,promote)
                 (scenarios . ,scenarios)
                 ;; the standing commitments, as this solve reads them
                 ;; (commitment-horizon.md; accepts.scm): accepts as PINS —
                 ;; hand-decided columns — and open offers as HOLDS — walls
                 ;; the solve keeps so re-solves carry the offer's
                 ;; certification — both compiled on the REFINED partition
                 ;; the solve will tile (declared-partition), so a start
                 ;; lands in its sub-day band. A caller's own #:pins list
                 ;; stands instead (the regret diagnostic's freed solve).
                 ;; A period's FACTS (housing's nightfall) ride
                 ;; the same door and stand either way: freeing the accepts frees
                 ;; what was decided, never what is so.
                 ,@(let ((cm (if (eq? pins 'standing)
                                 (commitments-before-solve scope-root flows
                                                           (declared-partition resources agents
                                                                               period-spans horizon)
                                                           extra-accepts agent-of)
                                 `((pins . ,pins) (holds . ())))))
                     `((pins . ,(append (or (assq-ref hz 'pins) '()) (or (assq-ref cm 'pins) '())))
                       (holds . ,(or (assq-ref cm 'holds) '()))))
                 ;; ROBUST non-anticipativity: if scenarios were inherited from the shed but
                 ;; the caller named no first-stage procs, COMMIT production first-stage —
                 ;; a farm plants ONCE, then the weather resolves. Empty first-stage-procs
                 ;; would let the solve "plant differently per drought" (anticipative,
                 ;; physically impossible). Production is what TRANSFORMS a good; a
                 ;; process that only RELOCATES one — a haul between places, a hold
                 ;; through time (a pickup/dropoff pair) — is recourse: the carry is
                 ;; decided once the harvest is known. Measured on the festival, with
                 ;; the carries committed first-stage: a district's harvest lost in
                 ;; one future forced its carry to 0 in EVERY future, and with all
                 ;; twelve single-district withdrawals no carry to the ground survived
                 ;; — the crowd's 3 kg floor read unmeetable while every branch alone
                 ;; met it. procs0 = the gathered procs before the reproduction EAT
                 ;; recipes, so consumption stays recourse as well.
                 ;; Housing's FACTS — a night falls, a dwelling stands — are the same in
                 ;; every future, which is what first-stage means; living in one is
                 ;; consumption and stays recourse with the eat recipes.
                 (first-stage-procs . ,(append (or (assq-ref hz 'facts) '())
                                        (if (and (pair? scenarios) (null? first-stage-procs))
                                           (let ((relocators (delete-duplicates
                                                              (filter-map (lambda (f) (and (relocating-action? (recipe-flow-action f))
                                                                                           (or (recipe-flow-recipe-input-of f) (recipe-flow-recipe-output-of f))))
                                                                          flows0))))
                                             (filter-map (lambda (p) (and (not (member (recipe-process-id p) relocators))
                                                                          (recipe-process-id p)))
                                                         procs0))
                                           first-stage-procs))))))
        (let* ((solve1 (lambda (w)
                         (call-with-values
                           (lambda () (apply plan-from-records resources agents spatials
                                             procs flows (alist->kw w)))
                           list)))
               (held (or (assq-ref world 'holds) '()))
               (bad? (lambda (res)
                       (let ((c (assq-ref (list-ref res 8) 'certificate)))
                         (and (list? c) (eq? #f (assq-ref c 'feasible?))))))
               ;; feasibility-lapse (commitment-horizon.md): when the held
               ;; program raises or certifies infeasible, re-solve without
               ;; the holds. Feasible now ⇒ the holds were the cause — every
               ;; holding offer lapses loudly and the free program stands.
               ;; Still infeasible ⇒ the world itself has no answer: the
               ;; holds are not blamed, and the held program's own reading
               ;; (dilemmas, certificate) rides as before.
               (holds-freed? #f)
               (solve! (lambda () (if (null? held) (solve1 world)
                        ;; only the PROGRAM may blame the holds, in its two
                        ;; typed voices: starvation ('planner-starvation) and
                        ;; an unplaceable standing term
                        ;; ('commitment-unplaceable) trigger the freed
                        ;; re-solve. Any other raise is a FAULT and
                        ;; propagates — under catch #t one unrelated compile
                        ;; bug lapsed every open offer in the scope.
                        (let ((r1 (catch* 'planner-starvation
                                    (lambda ()
                                      (catch* 'commitment-unplaceable
                                        (lambda () (solve1 world)) (lambda _ #f)))
                                    (lambda _ #f))))
                          (if (and r1 (not (bad? r1))) r1
                              (let ((r2 (solve1 (map (lambda (kv)
                                                       (if (eq? (car kv) 'holds) '(holds . ()) kv))
                                                     world))))
                                (cond ((bad? r2) (or r1 r2))
                                      (else (set! holds-freed? #t) r2)))))))))
        ((or solve-in (lambda (thunk k) (k (thunk)))) solve!
         (lambda (res)
        (apply
          (lambda (intents commitments material fill cols x idx ntot report)
            ;; Say it out loud when the program had no answer. The returned vector
            ;; is the phase-I point: it draws stock nobody has, so every quantity
            ;; downstream describes a plan that cannot be carried out. The
            ;; certificate names which limits are breached and by how much.
            (let ((c (assq-ref report 'certificate)))
              (when (and (list? c) (eq? #f (assq-ref c 'feasible?)))
                ;; phase-I publishes `violation`/`breached`; a KKT verdict
                ;; publishes `min-slack` — report whichever the backend produced.
                (simple-format (current-error-port)
                  "[plan-scope] INFEASIBLE — worst limit missed by ~A~A. The returned quantities are NOT a plan.~%"
                  (or (assq-ref c 'violation)
                      (and=> (assq-ref c 'min-slack) -)
                      'an-unreported-amount)
                  (let ((n (assq-ref c 'breached)))
                    (if n (simple-format #f " across ~A limit(s)" n) "")))))
            ;; what this solve did to the standing commitments: the horizon
            ;; read cached, the unbound floors named, and — when the program
            ;; stood only with its holds freed — those offers lapsed
            (commitments-after-solve scope-root world report flows procs
                                     #:holds-freed? holds-freed?)
            ;; the cell's tab: every reserve's desired q*, calamity q^res, their sum
            ;; the target, and the level the plan holds — read off the solve. And when
            ;; the program had NO answer and a reserve was among its walls, the
            ;; reserve's dilemma priced on this same world: hold the stock and go
            ;; short, or eat it and be fed — two more solves, only then.
            (let* ((c (assq-ref report 'certificate))
                   (infeasible? (and (list? c) (eq? #f (assq-ref c 'feasible?))))
                   (without (lambda (keys) (filter (lambda (kv) (not (memq (car kv) keys))) world)))
                   (dilemma (and infeasible? (pair? insurance*)
                                 (reserve-dilemma resources agents spatials procs flows
                                   #:repro-floors repro-floors #:insurance insurance* #:demand demand
                                   #:solve-opts (without '(repro-floors insurance demand reserve allow-infeasible?)))))
                   ;; and the FLOOR-vs-WALL dilemma, when a floor and an ecological
                   ;; limit were both among the walls: hold the floor past the tip,
                   ;; or hold the wall short of bare need — the same two solves
                   (walls (and infeasible? (pair? repro-floors) (pair? eco-spec-frag)
                               (plan-dilemma resources agents spatials procs flows
                                 #:repro-floors repro-floors #:eco-spec-frag eco-spec-frag #:demand demand
                                 #:solve-opts (without '(repro-floors eco-spec-frag demand allow-infeasible?))))))
              (values intents commitments material fill x ntot
                      (append
                       ;; THE DEMAND THIS SOLVE RAN ON — the caller's rows and every row
                       ;; the demand fold merged in (socialization.scm), keyed
                       ;; "spec#place@t" . target. The cache is keyed by what the CALLER
                       ;; passed, which the current-plan solve leaves empty; the plan face
                       ;; reads its independent-demand flank off this row instead.
                       `((demand . ,demand)
                         (reserves . ,(reserve-report insurance* demand (lambda (g) (good-level g cols x idx)))))
                       (if dilemma `((reserve-dilemma . ,dilemma)) '())
                       (if walls `((floor-wall-dilemma . ,walls)) '())
                       report))))
          res)))))))))))))))

;; ── A PLANNED FLOW AT THE EDGE: its row ─────────────────────────────────────
;; Inside the process a plan carries its flows as the records they are: `intend`
;; holds Intents, `work` and `material` hold Commitments, read through (playnet
;; planner formulas flows). A plan leaving the process (a door's reply, an actor's
;; standing plan) carries each flow as a ROW, an alist of plain values, written by
;; the three tables here. `plan->rows` is that crossing; a row already written
;; passes as it stands, so the crossing is safe to make twice.
(define (measured m) (and m (measure-has-numerical-value m)))
(define %intent-row
  (wire-table 'planned-intent <intent>
    `((id          id any)
      (action      action any)
      (side        ,(lambda (i ctx) (if (intent-provider i) 'offer 'need)) any)  ; provider-side offer, receiver-side need
      (provider    provider any)                       ; the worker, on an offer
      (conforms-to resource-conforms-to any)           ; the skill
      (effort      ,(lambda (i ctx) (measured (intent-effort-quantity i))) any)
      (input-of    input-of any)                       ; the process, on a need
      (at-location at-location any)
      (finished    finished any))))
(define %work-row
  (wire-table 'planned-work <commitment>
    `((id          id any)
      (action      action any)
      (provider    provider any)                       ; who is assigned
      (conforms-to resource-conforms-to any)
      (effort      ,(lambda (c ctx) (measured (commitment-effort-quantity c))) any)
      (input-of    input-of any)
      (at-location at-location any)
      (when        has-beginning any)                  ; maps to the period
      (until       has-end any)
      (in-scope-of in-scope-of any)                    ; the scope of the solve that placed it
      (satisfies   satisfies any))))                   ; (need-id offer-id), the two intents matched
(define %material-row
  (wire-table 'planned-material <commitment>
    `((id          id any)
      (action      action any)                         ; produce | consume | pickup | dropoff | use
      (conforms-to resource-conforms-to any)           ; the resource specification
      (quantity    ,(lambda (c ctx) (row-figure c)) any)   ; the row's one number: its quantity, or a means occupied its hours
      (unit        ,(lambda (c ctx) (and=> (commitment-resource-quantity c) measure-has-unit)) any)
      (effort      ,(lambda (c ctx) (measured (commitment-effort-quantity c))) any)   ; a means occupied: its hours, stated as effort
      (output-of   output-of any)                      ; the producing process
      (input-of    input-of any)                       ; the consuming process
      (classified-as resource-classified-as any)       ; ("ambient"): drawn from the world, no stock behind it
      (at-location at-location any)
      (when        has-beginning any)
      (note        note any))))
(define %flow-rows `((intend . ,%intent-row) (work . ,%work-row) (material . ,%material-row)))
(define (planned-row part f)
  "The row the planned flow F of a plan's PART (intend, work, material) crosses the edge as."
  (if (or (intent? f) (commitment? f)) (wire-row* (assq-ref %flow-rows part) f) f))
(define (plan-map-flows f plan)
  "PLAN with (F part flow) in place of each of its planned flows."
  (map (lambda (kv)
         (if (and (pair? kv) (assq (car kv) %flow-rows) (list? (cdr kv)))
             (cons (car kv) (map (lambda (x) (f (car kv) x)) (cdr kv)))
             kv))
       plan))
(define (plan->rows plan)
  "PLAN as it leaves the process: every planned flow its row."
  (plan-map-flows planned-row plan))
(define (held-commitment m scope-id)
  "The commitment the scope SCOPE-ID holds for the plan's material flow M, under the plan's
   own id. Events name the bare spec; the stage and state are the lot's."
  (let ((w (row-when m)))
    (make-flow-commitment
     #:id (row-id m) #:action (row-action m) #:note (row-note m)
     #:process (row-run m) #:spec (bare-spec (row-spec m)) #:tags (row-tags m)
     #:qty (row-quantity m) #:hours (row-effort m) #:unit (or (row-unit m) %placeholder-unit)
     #:has-point-in-time (and w (format #f "~a" w))
     #:place (row-place m) #:in-scope-of scope-id)))

;; The one plan→alist projection. CONCRETE side: who works which slot — (intend …)
;; (work …). ABSTRACT side: the value/labour-time the plan implies — (prices …) the
;; located labour prices λ(s,c), (value …) the embodied labour ℓ̂ per good, (social …)
;; the social-individual accounting (L, N·T, free time f). candidates? adds the OFFER
;; FIELD (per need-id, ((worker share offer-id) …)) — wanted on the OCapN wire, omitted
;; on the internal metabolism path (lp-alist).
(define* (plan-results->alist ints coms mat fill ntot report #:key candidates? rota? (scope-root #f))
  ;; Publish the plan's social free time f so drawable credit + consumer voice
  ;; fold in the CITIZENSHIP dividend by default (account.scm) — every real
  ;; solve enables citizenship automatically; before any solve, f=0.
  (let ((social (assq-ref report 'social)))
    (and (pair? social)
         (let ((f (assq-ref social 'free-time)))
           (and (number? f) (set-social-free-time! f)))))
  ;; CONFORMANCE RECERT — read the load the plan routes through each conformance edge
  ;; off the solved commitments, and derive its recert interval: the
  ;; edge-reliance → reliance->valid-until chain (vf/formulas/cadence.scm), with the
  ;; governed confidence-barrier steepness as the miss-harm (conformance-catalogue.scm).
  ;; period-span 1.0 ⇒ the interval is in PERIODS ("recert every N", #f = open, below the
  ;; reliance floor). now = 0, so the value is a duration; the issuer adds its clock.
  ;; SKILLS (the work commitments' effort) and MEANS (a durable's Svc| draw among the
  ;; material commitments) in one fold — commitment-loads (solve/inspection.scm).
  ;; THE PORTION THAT REMAINS SOCIAL — published beside the rail (rail.scm): per
  ;; bare spec, what the scope's own processes consume this horizon (the
  ;; material `consume` rows, less the claim columns' — a claim's draw IS the
  ;; distributed portion) plus the reserve the plan defends (q^res, the
  ;; insurance deduction). The pool K reads it so the certificate's exchange
  ;; rate counts only the distributable portion; the claim doors never need it,
  ;; since a claim can only fulfil a row this same solve planned.
  (let ((kept (make-hash-table)))
    (define (social-draw? mc)
      (let ((sp (commitment-resource-conforms-to mc)) (by (commitment-input-of mc)))
        (and sp (not (spec-owner sp))
             (not (and (string? by) (string-prefix? "claim~" by))))))
    (for-each (lambda (p) (hash-set! kept (car p) (cdr p)))
              (committed-by-spec (filter social-draw? mat) using-up-actions))
    (for-each (lambda (row)
                (let ((sp (key-spec (assq-ref row 'good))) (q (assq-ref row 'reserve)))
                  (when (and sp (number? q))
                    (hash-set! kept sp (+ q (hash-ref kept sp 0))))))
              (or (assq-ref report 'reserves) '()))
    (let ((portions (hash-map->list cons kept)))
      (publish-social-portion! portions)
      ;; THIS scope's own word alone — see set-rails! above for why
      (set-social-portions! (false-if-exception ($ scope-root 'recipe-store)) portions)))
  (let ((recert
         (conformance-recert-schedule (commitment-loads coms mat)
          #:period-span 1.0 #:harm (or (conformance-frag-weight) 1.0))))
    `((met      . ,fill)
      ;; FEASIBLE: does this plan respect every limit it was given? The compiled
      ;; backend answers an unsatisfiable program with the phase-I point — a
      ;; vector shaped like a plan, drawing stock nobody has — so `met` alone
      ;; reads 1.0 on a plan that cannot happen (and reads 1.0 trivially when a
      ;; scope carries no demand). Every consumer of this alist gets the verdict
      ;; at the top level, beside the number it qualifies.
      (feasible . ,(let ((c (assq-ref report 'certificate)))
                     (if (list? c) (assq-ref c 'feasible?) 'unknown)))
      (newton   . ,ntot)
      ;; THE VOICE — the field this solve read (τ, each column's stance) and what
      ;; each part's voice cost at the margin, in hours; present when a field stood
      ,@(let ((v (assq-ref report 'voice))) (if v `((voice . ,v)) '()))
      ;; THE BILL — what the walls made the solve buy in (engine acquire-bill),
      ;; present exactly when the caller put something up for sale
      ,@(let ((b (assq-ref report 'bill)))
          (if b `((bill . ,b) (bill-hours . ,(assq-ref report 'bill-hours))) '()))
      (intend   . ,ints)
      (work     . ,coms)
      ,@(if candidates? `((candidates . ,(assq-ref report 'candidates))) '())
      ;; THE ROTA — who carries each act that one person must carry.
      ;;
      ;; It rides beside the offer rather than replacing the `work` commitments,
      ;; and that is the whole design: `candidates` is the offer, this is ONE
      ;; answer to it, and a scope may take it, edit it, or ignore it. Publishing
      ;; it as authoritative state would decide by plumbing what belongs to the
      ;; people doing the work.
      ;;
      ;; Only INDIVISIBLE acts appear — `whole-atoms-of` reads `declare-whole!`,
      ;; so a need nobody declared whole is absent rather than assigned, and its
      ;; fractional commitments in `work` stand. Divisible work does not want a
      ;; rota; a week of farming with one name on it would be less true.
      ;;
      ;; Rotation is NOT applied here: it needs a history this projection does
      ;; not have (plan/rotation.scm takes one, and the ledger holds it). Until
      ;; that is wired the rota is fair in the plan's own terms — the tie goes to
      ;; whoever was granted most — and even-handed across weeks only by luck.
      ,@(if rota? `((rota . ,(map (lambda (s)
                                    `((slot . ,(slot-key s)) (need . ,(slot-need s))
                                      (worker . ,(slot-worker s)) (hours . ,(slot-hours s))))
                                  (assign-plan-slots (or (assq-ref report 'candidates) '())
                                                     #:atoms-of (whole-atoms-of)))))
            '())
      ;; WHAT EACH ACT NEEDS, and why the ones that are absent are absent.
      ;; Keyed by (process place period), which is what a calendar event already
      ;; carries — the browser joins, rather than being handed column keys. It
      ;; rides at the top level and not inside each `work` row because
      ;; requirements belong to the COLUMN: several commitments share one act at
      ;; one place in one period, and copying the list onto each of them would
      ;; publish the same fact several times and let the copies drift.
      (requires . ,(requirements->wire))
      (material . ,mat)         ; produce/consume/pickup/dropoff/use — the flows the books record
      (runs . ,(plan-runs))                           ; the Process each relocation's pickup and dropoff are inputs and outputs of
      (demand   . ,(or (assq-ref report 'demand) '()))  ; the rows the solve ran on, "spec#place@t" . target (fold rows included)
      (conformance-recert . ,recert)                  ; (edge . recert-interval-in-periods | #f) — skills and means, read off the plan
      ;; the acts this plan ran under a prohibition the pack was UNSURE of, with
      ;; how close each came to what the commune said it would carry
      ,@(let ((lx (assq-ref report 'legal))) (if (pair? lx) `((legal . ,lx)) '()))
      (reserves . ,(or (assq-ref report 'reserves) '()))  ; the cell's tab: q*, q^res, target, level per reserved good
      ,@(let ((d (assq-ref report 'reserve-dilemma)))     ; only when the program had no answer and a reserve was a wall
          (if d `((reserve-dilemma . ,d)) '()))
      ,@(let ((d (assq-ref report 'floor-wall-dilemma)))  ; only when the program had no answer with a floor and an ecological limit among its walls
          (if d `((floor-wall-dilemma . ,d)) '()))
      (labour-pulls . ,(assq-ref report 'labour-pulls))  ; λ(s,c) — located labour pulls   ┐ value = the dual of
      (good-pulls   . ,(assq-ref report 'good-pulls))    ; μ(g)   — material & eco pulls    ┘ the plan: Σℓλ + Σdμ
      (value    . ,(assq-ref report 'good-value))     ; ℓ̂_spec — embodied labour-hours (abstract labour)
      ;; the plan's claims, commitment-shaped: what each citizen draws from the pool,
      ;; where and when, and the certificate it costs. A citizen confirms one with the
      ;; service's `record-claim`, which records the transfer against this commitment.
      (claims   . ,(map (lambda (r)
                          (let ((cell (list-ref r 4)))
                            `((claimant    . ,(car r))
                              (conforms-to . ,(cadr r))
                              (quantity    . ,(caddr r))
                              (hours       . ,(cadddr r))
                              (at-location . ,(place-of cell))
                              (period      . ,(period-of cell)))))
                        (or (assq-ref report 'claims) '())))
      (credit-drawn . ,(or (assq-ref report 'credit-drawn) '()))  ; ((aid . hours) …) — the certificate drawdown, read off the plan
      (social   . ,(assq-ref report 'social))          ; L / available N·T / free / free-time f
      ;; the discrete layer's DECIDED state (config, cuts, fixings) — only when
      ;; a search ran; handed back through #:decided so the next solve starts
      ;; from this plan's incumbent, as #:warm-x starts it from this plan's x
      ,@(let ((d (assq-ref report 'decided))) (if d `((decided . ,d)) '()))
      ;; where each mover stands, per cell — present only when the scope reads
      ;; people or means as movers (solve-report `placement`)
      ,@(let ((p (assq-ref report 'placement))) (if p `((placement . ,p)) '()))
      ;; the robust door's marks: every live solve carries them now
      ;; (robust-by-default), a declared multi-future world shows its count
      ,@(if (assq-ref report 'robust)
            `((robust . #t) (nscenarios . ,(assq-ref report 'nscenarios))
              (first-stage-plan . ,(or (assq-ref report 'first-stage-plan) '()))
              (branch-costs . ,(or (assq-ref report 'branch-costs) '())))
            '())
      (certificate . ,(assq-ref report 'certificate))))) ; central-path gap ≤ m·t — near-optimality, as data

;; ── THE ONE DOOR: what every solve stands under by default ──────────────────
;;
;; Two things a scope stands under whether or not a caller remembers them, so
;; they are installed HERE, where the service, the socialized plug and the
;; offer reads all arrive, rather than at any one caller:
;;
;;   chemistry — `scope-composition`: element conservation as a CONSTRAINT. A
;;     conserving recipe has a zero residual and gets no row, so this is
;;     invisible until a recipe is wrong; a caller's own #:composition wins.
;;   law — `scope-legal-decorate` (compliance.scm): the root's ^legal-registry
;;     folded over the activity's crossings, place, things and holders. #f
;;     under no rules, and then the solve is byte-identical; a caller's own
;;     #:legal-decorate (even #f) wins.
;;
;; A scope that had to remember a keyword would get no conservation and no law
;; and no warning — a weaker guarantee than the one each exists for.
;; recipe-derived composition for every product the store knows how to make:
;; read each recipe-process's own consume/produce flows and attribute the net
;; substance draw to its primary product (catalogues/substances.scm `derive-contains`). This
;; is the proper-VF composition source — a crop's nutrients ARE what its grow
;; process drew from the soil — and it takes precedence over the *contains*
;; fallback table below. Robust on an empty/recipe-less store (→ '()).
(define* (recipe-derived-contains rs #:key (per-process? #f))
  "Spec-keyed derived compositions (the fixpoint), for readers and recursion.
   #:per-process? #t returns the SAME derivations keyed (pid . spec) instead —
   one row per process, the form the engine prefers for a process's outputs.
   The derivation is catalogues/substances.scm derive-compositions over the store's
   processes (world.scm store-derivations). A row here is what the thing HOLDS,
   leaf by leaf; the bars it carries to the solve ride the assembly
   (scope-composition) and are no part of what a batch is made of."
  (call-with-values (lambda () (derive-compositions (store-derivations rs)))
    (lambda (by-spec by-process undetermined)
      (map (lambda (row) (cons (car row) (remove (lambda (e) (slack-key? (car e))) (cdr row))))
           (if per-process? by-process by-spec)))))

;; ELEMENT CLOSURE, live and ON. `scope-composition` is the chemistry a scope's own
;; recipes and the substance table imply — derived where a recipe derives a product,
;; declared where none does — and `plan-scope` threads it to the solve, where
;; conservation stops being a reading of the plan and becomes a constraint on it: an
;; element cannot be conjured, and an unnamed loss shows as element nobody claimed.
;;
;; The `contains` closure is taken at the store (world.scm store-composition), since
;; the engine holds no chemistry of its own, and the lint reads the same rows there.
;;
;; DEFAULT-ON is the point. A scope that had to remember a keyword would get no element
;; accounting and no warning, which is a weaker guarantee than the one this is for. It
;; costs nothing where the knowledge is honest — a conserving recipe has a zero residual
;; and gets no row at all — so the constraint is invisible until a recipe is wrong. A
;; caller passing its own #:composition still wins, so a scope may say otherwise.
(define (scope-composition root)
  "The chemistry in force for ROOT, in the shape `plan-scope #:composition` reads.
   Spec-keyed rows (closed through `contains`) for inputs and fallbacks, plus the
   per-process rows — already elemental by construction — so a process's outputs
   read their OWN recipe's composition and two recipes for one spec stay two."
  (store-composition ($ root 'recipe-store)))

(define (with-scope-defaults scope-root args)
  (let* ((args (if (memq #:composition args) args
                   (append (list #:composition (scope-composition scope-root)) args)))
         (law  (and (not (memq #:legal-decorate args)) (scope-legal-decorate scope-root)))
         (args (if law (append (list #:legal-decorate law) args) args))
         ;; THE CERTIFICATES, read off the scope's own ledger when the caller
         ;; states none: each person's drawable credit (account.scm
         ;; effective-balance — the pool by ability, plus the citizenship
         ;; share, less what they claimed) is the row over their claim
         ;; columns. A root with no ledger (a mock, a unit world) states
         ;; nothing and the solve lays no row.
         (certs (and (not (memq #:certificates args)) (scope-certificates scope-root))))
    (if (pair? certs) (append (list #:certificates certs) args) args)))

(define (scope-certificates scope-root)
  "((aid . drawable-hours) …) for every person the scope's agent-store lists, or '()."
  (or (false-if-exception
       (let ((as ($ scope-root 'account-store)))
         (filter-map (lambda (a)
                       (and (eq? (agent-type a) 'person)
                            (let ((h (false-if-exception ($ as 'effective-balance (agent-id a)))))
                              (and (number? h) (cons (agent-id a) (exact->inexact h))))))
                     ($ ($ scope-root 'agent-store) 'all-agents))))
      '()))

;; THE THREE BILLS, at the scope's door (engine plan-bills, over a live scope):
;; with everything in #:acquire for sale at its price in hours, hold rights,
;; then needs, then wants as walls, and read what each made the solve buy.
(define (scope-bills scope-root . args)
  "engine bills-fold over plan-scope->alist: ((tier (bill . rows) (hours . h) (step . Δh) (feasible? . f) (residue . h0) …) …)."
  (let ((args* (kw-without args '(#:promote #:allow-infeasible?))))
    (bills-fold
     (lambda (tier)
       (let ((r (apply plan-scope->alist scope-root #:promote tier #:allow-infeasible? #t args*)))
         (list (or (assq-ref r 'bill) '()) (assq-ref r 'feasible)))))))

;; SUBSTITUTION REACHES THE PLAN as a proposal: for every demanded form that carries
;; nutrient rows, the scope's other foods ranked by how far each covers it against
;; the floors a body states (catalogues/substances.scm leaf-substitutes), read off the rows and
;; declared by nobody. The plan proposes, the person decides: nothing is adopted.
(define* (demand-substitutes scope-root demand #:key (floor 0.5))
  "((spec . ((other . cover) …)) …) for the demanded specs that carry nutrients and
   have a substitute covering at least FLOOR of them."
  (let* ((rs ($ scope-root 'recipe-store))
         (foods (call-with-values (lambda () (gather-recipes rs)) (lambda (procs flows) (scope-food-specs flows))))
         (against (map car (subsistence-species-base)))
         (wanted (delete-duplicates (map (lambda (d) (car (string-split (car d) #\#))) demand))))
    (filter-map (lambda (spec)
                  (and (pair? (nutrient-content spec 1))
                       (let ((subs (leaf-substitutes spec foods #:against against #:floor floor)))
                         (and (pair? subs) (cons spec subs)))))
                wanted)))

;; plan-scope's answer as one plan (with the offer field), in the two forms a plan
;; takes: `plan-scope->plan` for a reader in this process, its flows the records
;; they are; `plan-scope->alist` serialized for the OCapN wire, each flow its row.
(define (plan-scope->plan scope-root . args) (plan-scope-landed identity scope-root args))
(define (plan-scope->alist scope-root . args) (plan-scope-landed plan->rows scope-root args))
(define (plan-scope-landed shape scope-root args)
  (define (->alist intents commitments material fill x ntot report)
    (shape (->plan intents commitments material fill x ntot report)))
  (define (->plan intents commitments material fill x ntot report)
    ;; the solution vector rides the alist so a caller can warm the next
    ;; solve from it (#:warm-x, shape-guarded in engine/robust.scm); the service's
    ;; cache door pops it before anything is stored or crosses a wire
    (acons 'x x
           (acons 'substitutes (demand-substitutes scope-root (let ((m (memq #:demand args))) (if (and m (pair? (cdr m))) (cadr m) '())))
                  (plan-results->alist intents commitments material fill ntot report
                                       #:candidates? #t #:rota? #t #:scope-root scope-root))))
  ;; THE LANDING EXTENDS THROUGH HERE: plan-scope's #:solve-in receives a
  ;; continuation, and this door composes its own serialization onto it —
  ;; so an off-vat solve (service.scm plan-fn*) resolves to the alist, and
  ;; the inline default answers it directly, the one shape either way.
  (let* ((given (let ((m (memq #:solve-in args))) (and m (pair? (cdr m)) (cadr m))))
         (args  (let loop ((a args))          ; #:solve-in leaves the list; it re-enters composed
                  (cond ((null? a) '())
                        ((eq? (car a) #:solve-in) (loop (cddr a)))
                        (else (cons (car a) (loop (cdr a))))))))
    (if given
        (apply plan-scope scope-root
               #:solve-in (lambda (thunk k)
                            (given thunk (lambda (res)
                                           (call-with-values (lambda () (k res)) ->alist))))
               (with-scope-defaults scope-root args))
        (call-with-values (lambda () (apply plan-scope scope-root (with-scope-defaults scope-root args)))
          ->alist))))

;; ── THE DILEMMA: a reproduction floor against an ecological wall ─────────────
;;
;; Sometimes the only route to bare need crosses a limit. Both are hard — a floor
;; states what a plan may never do, and a fragility's tip is not a thing desire
;; can buy — so the program has no answer, and reporting "infeasible" leaves a
;; federation with nothing to act on.
;;
;; What it can act on is the PRICE OF EACH HORN, and both are ordinary solves of
;; the program already built — no new solver, the same move engine/robust.scm makes:
;;
;;   HORN A — hold the floor. Each contested profile keeps its shape, with its tip
;;     pushed beyond reach: the draw stays ACCOUNTED (deleting the profile would
;;     make the spec an unaccounted draw, and fail-closed would rightly kill the
;;     solve) while no longer binding. Read back: how far past the real tip the
;;     draw goes.
;;   HORN B — hold the wall. Each floor becomes an ordinary DESIRE of the same
;;     size: soft, so it yields to the barrier instead of colliding with it. Read
;;     back: how far short of bare need the plan lands.
;;
;; The planner does not choose. Which horn to take is a governance question about
;; whose reproduction and which boundary, and the number belongs in front of it.
;; Returns an alist: (feasible-together? horn-a horn-b), each horn carrying its
;; own plan alist plus the cost it pays.

(define (%tip-out-of-reach profile)
  "A fragility profile whose tip no plan will reach, keeping its (lo hi alpha w)
   shape so the spec stays barrier-bounded rather than becoming a free raw."
  (match profile
    ((lo hi alpha w) (list 1e12 1e12 alpha w))
    (_ profile)))

;; ── the dilemma skeleton, shared by every pair of horns ─────────────────────
;; One solve of the caller's own program with a few keywords overridden, read back
;; as a plan alist; and one reader of how much of a spec a plan draws or delivers.
;; plan-dilemma (floor vs wall) and reserve-dilemma (floor vs reserve) are two
;; pairs of horns over this one skeleton — a third pair adds a function, not a copy.
(define (%horn-solve resources agents spatials procs flows solve-opts extra)
  (call-with-values
    (lambda () (apply plan-from-records resources agents spatials procs flows
                      (alist->kw (append extra solve-opts))))
    (lambda (ints coms material fill cols x idx ntot report)
      (plan-results->alist ints coms material fill ntot report))))
;; what a horn's PLAN newly makes, and uses up, of SPEC (vf/formulas/actions.scm)
(define (%made plan spec) (committed-quantity (or (assq-ref plan 'material) '()) spec creating-actions))
(define (%used plan spec) (committed-quantity (or (assq-ref plan 'material) '()) spec using-up-actions))
;; a floor becomes a desire of the same size — the same want, now soft
(define (%floors->desires floors) (map (lambda (fl) (cons (car fl) (cdr fl))) floors))

(define* (plan-dilemma resources agents spatials procs flows
                       #:key (repro-floors '()) (eco-frag '()) (eco-prior '())
                             (eco-spec-frag '()) (demand '())
                             (contested '()) (solve-opts '()))
  "Price both horns of a floor-vs-wall collision. The walls may come as located
   ECO-FRAG rows ((good . (lo hi α w)) …), as a live scope's ECO-SPEC-FRAG — a
   list of (spec . profile) pairs and/or <fragility> records — or both. CONTESTED
   names the located goods / specs whose fragility is in the collision (default:
   all of them). DEMAND is the scope's want, on the table in every horn.
   SOLVE-OPTS is an alist of extra plan-from-records keywords, threaded to both
   solves unchanged so each horn is the caller's own program."
  (define spec-frags (as-fragilities eco-spec-frag))
  (define contested* (if (pair? contested) contested
                         (append (map car eco-frag) (map fragility-key spec-frags))))
  (define* (solve floors frag sfrag extra-demand #:key (may-fail? #f))
    (%horn-solve resources agents spatials procs flows solve-opts
                 `((repro-floors . ,floors) (eco-frag . ,frag) (eco-prior . ,eco-prior)
                   ,@(if (pair? sfrag) `((eco-spec-frag . ,sfrag)) '())
                   (demand . ,(append demand extra-demand)) (allow-infeasible? . ,may-fail?))))
  ;; located-good keys are STRINGS — assoc-ref, never assq-ref
  (define (headroom-of key)
    (let ((p (or (assoc-ref eco-frag key)
                 (and=> (find (lambda (f) (equal? (fragility-key f) key)) spec-frags) fragility-profile))))
      (and p (- (frag-tip p) (or (assoc-ref eco-prior key) 0.0)))))
  ;; the wall stood aside: a contested profile keeps its shape with its tip out of reach
  (define (relax-row kv) (if (member (car kv) contested*) (cons (car kv) (%tip-out-of-reach (cdr kv))) kv))
  (define (relax-frag f) (if (member (fragility-key f) contested*)
                             (fragility-with-profile f (%tip-out-of-reach (fragility-profile f))) f))
  ;; whether the two hold TOGETHER is the question this asks, so this one solve is
  ;; allowed to have no answer. Each horn below says for itself whether it is a plan.
  (let* ((both (solve repro-floors eco-frag spec-frags '() #:may-fail? #t))
         (together? (eq? #t (assq-ref both 'feasible))))
    (if together?
        `((feasible-together? . #t) (plan . ,both))
        (let* ((a (solve repro-floors (map relax-row eco-frag) (map relax-frag spec-frags) '() #:may-fail? #t))
               (b (solve '() eco-frag spec-frags (%floors->desires repro-floors) #:may-fail? #t)))
          `((feasible-together? . #f)
            (horn-a . ((holds . floor) (plan . ,a) (feasible . ,(assq-ref a 'feasible))
                       (overshoot . ,(map (lambda (key)
                                            (cons key (- (%used a (key-spec key))
                                                         (or (headroom-of key) 0.0))))
                                          contested*))))
            (horn-b . ((holds . wall) (plan . ,b) (feasible . ,(assq-ref b 'feasible))
                       (shortfall . ,(map (lambda (fl)
                                            (cons (car fl)
                                                  (- (cdr fl) (%made b (key-spec (car fl))))))
                                          repro-floors)))))))))

;; ── the RESERVE'S dilemma: bare need vs the calamity stock ──────────────────
;; The deterministic twin of engine/robust.scm's `reserve-yields-to`. In a scenario tree
;; the reserve yields to the p=0 tail by construction; in ONE world there is no
;; tail to name — a calamity arriving now shows up as a program with no answer,
;; the subsistence floor and the reserve both hard against a supply that cannot
;; carry both. "Held as a hard possibility-tension that out-pulls desire yet
;; yields to true calamity" (playnet.typ §q_r^*): infeasibility IS the calamity
;; signal, and this prices the two ways out, the same move as plan-dilemma:
;;   HORN A — hold the reserve. Each floor becomes a desire of the same size: the
;;     plan keeps the calamity stock and people go short. Read back: the shortfall.
;;   HORN B — eat the reserve. Each reserve becomes a SOFT want of the same size
;;     (#:reserve, the low-weight tranche): the plan feeds the floor from the stock
;;     it was holding. Read back: how much of the reserve is drawn.
;; The planner does not choose; the numbers belong in front of whoever does — and
;; a scope that eats its reserve reads, in the same alist, what is left to rebuild.
(define* (reserve-dilemma resources agents spatials procs flows
                          #:key (repro-floors '()) (insurance '()) (demand '()) (solve-opts '()))
  ;; DEMAND is the scope's want; it rides in every horn — the reserve is being
  ;; weighed against the need, with the want still on the table
  (define* (solve floors ins extra-demand #:key (may-fail? #f) (soft '()))
    (%horn-solve resources agents spatials procs flows solve-opts
                 `((repro-floors . ,floors) (insurance . ,ins) (demand . ,(append demand extra-demand))
                   (reserve . ,soft) (allow-infeasible? . ,may-fail?))))
  (define (lo-of row) (cadr row))
  (let* ((both (solve repro-floors insurance '() #:may-fail? #t))
         (together? (eq? #t (assq-ref both 'feasible))))
    (if together?
        `((feasible-together? . #t) (plan . ,both))
        ;; each horn may itself have no answer — a calamity so deep that even the
        ;; reserve cannot be held (A), or the floor cannot be met from the whole
        ;; stock (B). Each says so with its own `feasible`; that IS the finding.
        (let* ((a (solve '() insurance (%floors->desires repro-floors) #:may-fail? #t))
               ;; the reserve becomes a want of the same size at its OWN steepness w —
               ;; softened, not silenced: the plan still reaches for it with what is left
               (b (solve repro-floors '() '() #:may-fail? #t
                         #:soft (map (lambda (r) (cons (car r) (cons (lo-of r) (list-ref r 4)))) insurance))))
          `((feasible-together? . #f)
            (horn-a . ((holds . reserve) (plan . ,a) (feasible . ,(assq-ref a 'feasible))
                       ;; what the household is short: the floor, less what is
                       ;; produced ABOVE the reserve still held on the same good
                       (shortfall . ,(map (lambda (fl)
                                            (let* ((g (car fl)) (spec (key-spec g))
                                                   (held (fold (lambda (r acc) (if (equal? (car r) g) (+ acc (lo-of r)) acc))
                                                               0.0 insurance))
                                                   (above (max 0.0 (- (%made a spec) held))))
                                              (cons g (max 0.0 (- (cdr fl) above)))))
                                          repro-floors))))
            (horn-b . ((holds . floor) (plan . ,b) (feasible . ,(assq-ref b 'feasible))
                       ;; what the reserve is drawn down by: its level, less what
                       ;; the floor on the same good already took, against lo
                       (drawn . ,(map (lambda (r)
                                        (let* ((g (car r)) (spec (key-spec g))
                                               (floor (or (assoc-ref repro-floors g) 0.0))
                                               (kept (max 0.0 (- (%made b spec) floor))))
                                          (cons g (max 0.0 (- (lo-of r) kept)))))
                                      insurance)))))))))

;; ── the materialization bridge: willing-only plan → stored suggested intents ─
;; Closes the seam between the CONVEX materialization (ephemeral `work` alists
;; from a willing-only plan) and the SNAPSHOT (which reads stored intents). Each
;; materialized assignment is persisted as a work Intent — deterministic id
;; mi|worker|skill|cell, provider unbound, suggested-provider in meta — so
;; the calendar's intent row reads match-status=matched and it surfaces under the
;; calendar's "Awaiting your acceptance" for that worker, who then accepts
;; (promote-to-commitment). Prior mi| intents are cleared first, so a worker who
;; withdrew (or got re-balanced out) drops cleanly.
(define (clear-intents-by-prefix! ps prefix)
  "Drop every intent whose id carries PREFIX — the re-lay half of the
   solve-derived families (mi| suggestions, ni| open shifts): each solve
   clears its own family and lays it fresh, so re-runs and withdrawals
   are clean."
  (for-each (lambda (i)
              (let ((id (intent-id i)))
                (when (and id (string-prefix? prefix id)) ($ ps 'remove-intent id))))
            ($ ps 'all-intents)))
(define (clear-materialized-intents! ps) (clear-intents-by-prefix! ps "mi|"))

;; THE work-intent constructor — the one place the 28-field positional
;; layout is written down. Four families build through it (mi| suggestions,
;; ni| open shifts, offer: holds, the materialized bridge), so they cannot
;; drift on a positional slot the way hand-laid copies can.
(define* (work-intent id #:key (name #f) proc skill hours
                      (from #f) (until #f) (point #f) (place #f) (plan #f))
  (make-intent #:id id #:action 'work #:name name
               #:input-of proc #:resource-conforms-to skill #:effort-quantity (make-measure hours %effort-unit)
               #:has-beginning from #:has-end until #:has-point-in-time point
               #:at-location place #:planned-within plan))
(define* (persist-materialized! scope-root work-alists #:key (plan-id "plan-materialized"))
  (let ((ps ($ scope-root 'plan-store)) (n 0))
    (clear-materialized-intents! ps)
    (for-each
      (lambda (w)
        (let* ((worker (row-provider w))
               (skill  (row-spec w))
               (eff    (row-effort w))
               (proc   (row-input-of w))
               (place  (row-place w))
               (wbeg   (row-when w))            ; carry the WHEN through (schema hasBeginning)
               (wend   (row-until w))
               (period (time->period wbeg))           ; the period the commitment is FOR (0 if no spans)
               (cell   (string-append (or place "") "@" (number->string period)))
               (iid    (string-append "mi|" (or worker "?") "|" (or skill "?") "|" cell)))
          (when (and worker skill (number? eff) (> eff 1e-6))
            (set! n (+ n 1))
            ($ ps 'add-intent
               (work-intent iid #:proc proc #:skill skill #:hours eff
                            #:from wbeg #:until wend #:point wbeg
                            #:place place #:plan plan-id))
            ($ ps 'set-meta iid `((suggested-provider . ,worker))))))
      work-alists)
    n))

;; ── needs-based materialization: willing workers → the scope's OPEN needs ─────
;; The live calendar carries STORED work needs (not a goods demand), so the
;; willing loop materializes by ASSIGNMENT, not a convex re-solve: for each open
;; work need, every worker who marked willing for its (skill, cell) gets a
;; suggested mi| intent — the "race". The calendar's intent row reads suggested-provider →
;; matched → it surfaces under "Awaiting your acceptance" for that worker, who
;; accepts (promote-to-commitment; the cq>aq guard binds their hour budget THERE,
;; so over-subscribed willingness can't over-commit). Clears prior mi| first.
;; (worker skill cell) for every oi| offer-intent a worker marked status=willing —
;; the over-subscribable opt-in set. The single scan both the materializer (below,
;; as a (skill.cell)→workers hash) and the solver's willing-predicate (service.scm,
;; as a flat membership list) build from.
(define (willing-tuples ps)
  (filter-map (lambda (kv)
                (and (eq? (assq-ref (cdr kv) 'status) 'willing)
                     (list (assq-ref (cdr kv) 'worker)
                           (assq-ref (cdr kv) 'skill)
                           (assq-ref (cdr kv) 'cell))))
              (meta-rows-with-prefix ($ ps 'all-meta) "oi|")))

(define (materialize-willing! scope-root)
  (let* ((ps    ($ scope-root 'plan-store))
         (willing (make-hash-table)) (n 0))     ; (skill . cell) → list of willing workers
    (for-each (lambda (t)                        ; fold the shared scan into the (skill.cell)→workers index
                (let ((k (cons (cadr t) (caddr t))))
                  (hash-set! willing k (cons (car t) (hash-ref willing k '())))))
              (willing-tuples ps))
    (clear-materialized-intents! ps)   ; clear prior materializations (so withdrawals / re-runs are clean)
    ;; one mi| intent per (open work need × willing worker for its skill+cell)
    (for-each
      (lambda (i)
        (when (and (eq? (intent-action i) 'work) (not (intent-finished i))
                   ;; standing by the intent's OWN terms — a shift whose
                   ;; window wholly passed materializes no suggestion, the
                   ;; same read the wire makes (the persist-time filter is
                   ;; hygiene; this read is the truth)
                   (not (intent-window-passed? i (instant->unix (now))))
                   (intent-resource-conforms-to i)
                   (not (string-prefix? "mi|" (or (intent-id i) ""))))
          (let* ((skill (intent-resource-conforms-to i))
                 (place (intent-at-location i))
                 (cell  (string-append (or place "") "@" (number->string (time->period (intent-has-beginning i)))))
                 (eff   (let ((m (intent-effort-quantity i))) (if m (measure-has-numerical-value m) 1.0)))
                 (proc  (intent-input-of i))
                 (plan  (intent-planned-within i)))     ; inherit the need's plan so it surfaces in-view
            (for-each
              (lambda (w)
                (let ((iid (string-append "mi|" w "|" skill "|" cell)))
                  (set! n (+ n 1))
                  ($ ps 'add-intent
                     (work-intent iid #:proc proc #:skill skill #:hours eff
                                  #:from (intent-has-beginning i) #:until (intent-has-end i)
                                  #:point (intent-has-beginning i)
                                  #:place place #:plan plan))
                  ($ ps 'set-meta iid `((suggested-provider . ,w)))))
              (hash-ref willing (cons skill cell) '())))))
      ($ ps 'all-intents))
    n))

;; ── the confirmation mile: a committed plan → a fulfilling EconomicEvent ─────
;; The bottom edge of the VF diagram. A person sees the prefilled commitment and
;; says "this happened" (optionally tweaking effort/time); we build the matching
;; `work` EconomicEvent — provider, skill, hours, the process it fed, fulfilling
;; the commitment (the intents it satisfies take their satisfaction from the
;; commitment's edge, never from the event) — and hand it to the observer, which
;; folds it (advancing the FulfillmentState). Almost no data entry: the commitment
;; alist IS the prefilled event. wc = a commitment alist from plan-scope->alist's
;; `work` list (possibly edited); opts may carry (effort . h) (when . iso) to tweak.
;; NB the clock keyword is #:when-iso, never #:when: a parameter named
;; `when` lexically shadows the macro, the trap that broke the service's
;; record-flow method (its fix carries the story).
;; make-work-event lives in (playnet vf formulas flows) with its commitment twin; re-exported here.

(define (end-fulfilled! scope-root cid)
  "The commitment CID ended, fulfilled: one dated fact on the store's rail, beside a
   release's and an expiry's, so the drift question reads how commitments end by kind
   (end-commitment; an absent store has nothing to date)."
  (let ((ps (false-if-exception ($ scope-root 'plan-store))))
    (when ps (false-if-exception
              ($ ps 'end-commitment cid 'fulfilled (instant->unix (now)))))))

(define* (record-work-done scope-root wc #:key (effort #f) (when-iso #f))
  (let* ((obs   ($ scope-root 'observer))
         (cid   (row-id wc))
         (evid  (string-append "ev-" cid))
         (hours (or effort (row-effort wc)))
         (t     (or when-iso (row-when wc)))
         (event (make-work-event
                  #:id evid #:provider (row-provider wc) #:receiver #f
                  #:effort-qty hours #:fulfills cid
                  #:input-of (row-input-of wc) #:resource-spec (row-spec wc)
                  #:at-location (row-place wc)
                  #:has-beginning t #:has-end (row-until wc)
                  #:in-scope-of (row-scope wc)
                  #:timestamp t #:created (instant->civil (now)) #:note #f)))
    ($ obs 'record-event event)
    (end-fulfilled! scope-root cid)
    evid))

;; ── the MATERIAL confirmation: a produce/consume/pickup/dropoff/use commitment → its event ──
;; The other half of the bottom edge. Confirming a production commitment records a
;; `produce`/`consume`/`pickup`/`dropoff`/`use` EconomicEvent the observer folds, so the
;; plan's own realisation MOVES STOCK: producing bread increments a bread resource, consuming
;; flour/soil decrements the existing one. WHICH resource is a fact about the books
;; at the moment a person says "this happened", so it is resolved then (VF: an event
;; names the resource it acts on): the lots of the flow's good at the flow's place.
;;
;; A holding is a lot of the good the plan's stock key files it under (engine
;; make-stock-key, read with the vocabulary the plan was solved with), and it is where
;; its own record says, or where its container is (engine resource-place). A good owned
;; by an agent ("bread~ana") is that agent's holding; a good of the commons is the
;; scope's, whoever keeps it in custody. Lots are taken in a fixed order: the commons'
;; before a person's own, the first that holds the whole draw, else lot by lot by id;
;; stock the books do not hold is refused, never conjured. A `pickup` names BOTH resources, the origin's
;; lot and the lot its `dropoff` lands in (a fresh id when the destination holds none).
(define (scope-persons scope-root)
  (let ((store (false-if-exception ($ scope-root 'agent-store))))   ; a mock scope has none
    (person-set (if store ($ store 'all-agents) '()))))
(define* (lot-of? r good persons #:optional (vocabulary (stock-vocabulary)))
  "R is a lot of GOOD in the plan's reading: the good the stock key files it under."
  (equal? (car ((make-stock-key (list r) persons #:vocabulary vocabulary) r)) good))
(define (lot-onhand r) (mqty (economic-resource-onhand-quantity r)))
(define (met-quantity obs id)
  "What the events fulfilling row ID have met of it: the sum of their quantities, whether or
   not the row is registered as a commitment."
  (fold + 0 (map (lambda (e) (mqty (economic-event-resource-quantity e)))
                 (or ($ obs 'fulfilled-by id) '()))))
(define (arriving-lots obs rows resources)
  "RESOURCES as a solve should read them. The books keep a relocation's cargo at no place
   until its dropoff says it has arrived, and a solve reads stock by place, so cargo on the
   way would not be seen and would be hauled again. It is counted at the place the plan's
   open dropoff for its run lands it, for as much as that dropoff has yet to land: ROWS are
   the previous plan's, the plan's own word for where the stock is going. The lot a dropoff
   empties is the one its run and spec name (`carried-lot-id`)."
  (if (null? rows)
      resources
      (map (lambda (r)
             (if (or (economic-resource-current-location r) (not (> (lot-onhand r) 0)))
                 r
                 (let* ((drop (find (lambda (m) (and (eq? 'dropoff (row-action m))
                                                     (equal? (carried-lot-id m) (economic-resource-id r))))
                                    rows))
                        (left (and drop (- (row-quantity drop) (met-quantity obs (row-id drop))))))
                   (if (and drop (> left 1e-9))
                       (let ((m (make-measure (min (lot-onhand r) left)
                                              (measure-has-unit (economic-resource-onhand-quantity r)))))
                         (copy-economic-resource r #:current-location (row-place drop)
                                                 #:onhand-quantity m #:accounting-quantity m))
                       r))))
           resources)))
(define (stock-lots obs persons good place vocabulary)
  "The lots of GOOD at PLACE the books hold: the commons' first, then by id."
  (let* ((all  (or ($ obs 'all-resources) '()))
         (key  (make-stock-key all persons #:vocabulary vocabulary))
         (want (cons good place))
         (own? (lambda (r) (let ((h (economic-resource-primary-accountable r)))
                             (and h (hash-ref persons h #f) #t)))))
    (sort (filter (lambda (r) (equal? (key r) want)) all)
          (lambda (a b)
            (if (eq? (own? a) (own? b))
                (string<? (economic-resource-id a) (economic-resource-id b))
                (not (own? a)))))))
(define (draw-from lots qty)
  "((lot . taken) …): QTY drawn from LOTS in order — the first lot that holds it all,
   else lot by lot — or #f when they hold less."
  (let ((whole (find (lambda (r) (not (target-passed? qty (lot-onhand r)))) lots)))
    (if whole
        (list (cons whole qty))
        (let loop ((ls lots) (need qty) (acc '()))
          (cond ((not (target-passed? need 0)) (reverse acc))
                ((null? ls) #f)
                (else (let ((take (min need (max 0 (lot-onhand (car ls))))))
                        (loop (cdr ls) (- need take)
                              (if (> take 0) (cons (cons (car ls) take) acc) acc)))))))))
(define (lot-id-or-new lots good place)
  (if (pair? lots) (economic-resource-id (car lots)) (string-append "res|" good "|" (or place "?"))))
;; the unit an event moving GOOD counts in: the good's specification's own unit, which every
;; quantity of the plan and of a confirmation is stated in (the observer converts it into the
;; lot's own unit, and refuses a unit of another substance); else the unit of LOT, the lot it
;; draws on or lands in; else the placeholder the observer reads in the lot's unit. A lot an
;; event creates is born in the unit the event states.
(define (spec-unit scope-root spec)
  "The unit the specification SPEC counts in (its own default-unit-of-resource), or #f when the
   scope's recipe store states none."
  (let ((sp (false-if-exception ($ ($ scope-root 'recipe-store) 'get-resource-spec spec))))
    (and sp (resource-specification-default-unit-of-resource sp))))
(define (stock-unit scope-root good lot row)
  "The unit the flow ROW of GOOD is counted in: the row's own, where it states one;
   else the specification's; else the lot's; else the placeholder."
  (or (let ((u (row-unit row))) (and u (not (placeholder-unit? u)) u))
      (spec-unit scope-root (bare-spec good))
      (and lot (measure-has-unit (economic-resource-onhand-quantity lot)))
      %placeholder-unit))
(define (planned-stamp w)
  "The slot W a plan row was planned for, as the time its flow happened — unless that
   is still to come, when the flow happens as it is confirmed (#f): a confirmation is
   never dated ahead of itself."
  (let* ((iso (and w (format #f "~a" w)))
         (t   (and iso (not (string-null? iso)) (civil->instant iso))))
    (and t (<= t (now)) iso)))
;; the process an event belongs to is known by the recipe it is an instance of before the
;; event lands, so the stage effect can name it (observer register-process)
(define (register-row-process! scope-root mc runs)
  (let* ((pid (row-run mc))
         (rp  (and pid (false-if-exception ($ ($ scope-root 'recipe-store) 'get-recipe-process
                                              (or (assoc-ref runs pid) pid)))))
         (pspec (and rp (recipe-process-process-conforms-to rp))))
    (when pspec ($ ($ scope-root 'observer) 'register-process
                   (make-process #:id pid #:name pid #:based-on pspec)))))
(define* (record-flow-done scope-root mc #:key (quantity #f)
                           (when-iso #f) (event-id #f) (vocabulary #f) (runs '()))
  "Record plan row MC as having happened. RUNS maps each run the plan names to the
   recipe process it is an instance of. A relocation's cargo is a lot of its own on the
   way (`carried-lot-id`): the pickup moves it out of the lot it leaves and the dropoff
   into the lot it lands in, so what a dropoff may land is what its pickup carried.
   Every row records an event or is refused: a flow that leaves the stock as it was
   (the table's `inert-flow-actions`: a service delivered, a means used or cited) is
   one event naming no stock, a produce lands in a lot, a consume and a pickup draw
   from the lots at their place, a dropoff from its cargo, and an action this has no
   reading of is an error, never a commitment ended with nothing in the books."
  (let* ((obs   ($ scope-root 'observer))
         (act   (row-action mc))
         (good  (row-spec mc))
         (qty   (or quantity (row-quantity mc)))
         (place (row-place mc))
         (cid   (row-id mc))
         ;; EVENT-ID override: a partial confirmation records several events
         ;; against one commitment key, so the caller numbers them
         (evid  (or event-id (string-append "ev-" cid)))
         ;; no stock behind it, so the event names none: the world's own, or a flow that
         ;; leaves the stock as it was
         (stockless (or (row-ambient? mc) (and (memq act inert-flow-actions) #t)))
         (persons (scope-persons scope-root))
         (recorded (instant->civil (now)))                ; the moment the books were told, on the one clock
         (stamp   (or when-iso (planned-stamp (row-when mc)) recorded))   ; when it happened: as stated, else as planned, else now
         (vocab   (or vocabulary (stock-vocabulary)))
         (here    (if stockless '() (stock-lots obs persons good place vocab)))
         (carry   (and (not stockless) (relocating-action? act) (carried-lot-id mc)))
         (carried (and carry ($ obs 'get-resource carry)))
         ;; what the event takes from: the lots at its place (a consume, a pickup), or the carried lot (a dropoff)
         (draws   (cond (stockless '())
                        ((or (memq act using-up-actions) (and (relocating-action? act) (input-action? act)))   ; a consume, a pickup
                         (or (draw-from here qty)
                             (error "record-flow-done: the books hold no such stock to take" cid good place qty
                                    (fold + 0 (map lot-onhand here)))))
                        ((and (relocating-action? act) (output-action? act))   ; a dropoff
                         (if (and carried (not (target-passed? qty (lot-onhand carried))))
                             (list (cons carried qty))
                             (error "record-flow-done: the cargo has not been picked up to be dropped off" cid good place qty
                                    (if carried (lot-onhand carried) 0))))
                        ((memq act creating-actions) '())       ; a produce: it lands in a lot, and draws from none
                        (else (error "record-flow-done: no reading of this action as a done flow" cid act good))))
         ;; the lot an event moves into: a pickup's carried lot, a dropoff's destination lot
         (to-lot  (and (not stockless)
                       (case act
                         ((pickup)  carry)
                         ((dropoff) (lot-id-or-new here good place))
                         (else #f))))
         (into    (and (not stockless) (memq act creating-actions) (lot-id-or-new here good place)))
         ;; the agent accountable for the stock an event moves (its lot's primaryAccountable, the
         ;; rights side of the custody/rights split) is the event's provider and receiver: one
         ;; agent on both sides, so no transfer of rights arises. A cargo on its way has one
         ;; accountable agent (the first lot drawn), a consume's lot its own, a produce the
         ;; lot it lands in; a lot with none, or none yet, names none. Custody is the
         ;; custodian's, which an event names nowhere here.
         (accountable-of (lambda (lot) (and lot (economic-resource-primary-accountable lot))))
         (cargo-accountable (and (pair? draws) (relocating-action? act) (accountable-of (caar draws))))
         (event   (lambda (k rid conforms q agent unit)
                    (make-economic-event
                     #:id (if (= k 0) evid (string-append evid "." (number->string k)))
                     #:action act
                     #:input-of (row-input-of mc) #:output-of (row-output-of mc)   ; input-of / output-of
                     #:resource-inventoried-as rid #:to-resource-inventoried-as to-lot                                         ; resource-inventoried-as, to-res-inv (the lot the cargo moves into)
                     #:resource-conforms-to conforms #:resource-classified-as (and (row-ambient? mc) (list %ambient-tag))      ; conforms-to (the lot's spec), classified-as
                     #:provider agent #:receiver agent                                        ; provider, receiver: the one accountable agent
                     #:resource-quantity (and q (make-measure q unit))                   ; resource-quantity: what moved
                     #:effort-quantity (and (not q) (row-effort mc) (make-measure (row-effort mc) %effort-unit))   ; effort: a means occupied for hours
 #:has-point-in-time stamp #:created recorded                               ; has-beginning has-end has-point-in-time created
                     #:at-location place                                        ; at-location, to-location, state
                     #:fulfills cid                                    ; FULFILLS the commitment, satisfies corrects realization settles
                     #:note (row-note mc))))                 ; note in-scope-of previous exclude market
         (events  (if (or stockless (memq act creating-actions))
                      (let ((lot (and (not stockless) (pair? here) (car here))))
                        (list (event 0 into (bare-spec good) qty (accountable-of lot)
                                     (stock-unit scope-root good lot mc))))
                      (let loop ((ds draws) (k 0))
                        (if (null? ds) '()
                            (cons (event k (economic-resource-id (caar ds)) (economic-resource-conforms-to (caar ds)) (cdar ds)
                                        (or cargo-accountable (accountable-of (caar ds)))
                                        (stock-unit scope-root good (caar ds) mc))
                                  (loop (cdr ds) (+ k 1))))))))
    (register-row-process! scope-root mc runs)
    (for-each (lambda (e) ($ obs 'record-event e)) events)
    (end-fulfilled! scope-root cid)
    evid))

;; enact a whole plan's material flows at once — "it all happened as planned". The
;; books are the schedule: a row whose stock they hold is recorded, a row they cannot
;; yet serve waits for the rows that make its stock (a produce before the consume of
;; its good, a dropoff before the consume it feeds), and the rows left when no more can be
;; served are returned with the reason, never recorded against stock that is not there.
;; This reads no graph, so a closed loop (a farm and a compost heap) enacts like any
;; chain. Returns (event-ids . unmet) with unmet ((row-id . reason) ...).
(define (refusal-message args)
  "The words of an `(error \"msg\" irritant …)` as a handler receives them: (#f format
   format-args #f)."
  (apply format #f (cadr args) (caddr args)))
(define* (enact-rows scope-root rows #:key (vocabulary #f) (runs '()))
  (let ((vocab (or vocabulary (stock-vocabulary))))
   (let pass ((pending rows) (events '()))
    (let ((waiting '()) (events events))
      (for-each (lambda (mc)
                  (catch* 'misc-error          ; a refusal waits; any other failure is a bug and surfaces
                    (lambda () (set! events (cons (record-flow-done scope-root mc #:vocabulary vocab #:runs runs)
                                                  events)))
                    (lambda (key . args) (set! waiting (cons (cons mc (refusal-message args)) waiting)))))
                pending)
      (let ((waiting (reverse waiting)))
        (if (or (null? waiting) (= (length waiting) (length pending)))
            (cons (reverse events)
                  (map (lambda (w) (cons (row-id (car w)) (cdr w))) waiting))
            (pass (map car waiting) events)))))))

;; ── the metabolism: keep the plan LIVE — re-solve when reality drifts ─────────
;; "Solved" sets the targets; "metabolised" realises and adapts them between solves
;; (the doc's pair). A ^live-planner holds the STANDING plan and warm-starts the
;; next solve from it, so when an event has moved the observed state past a
;; threshold the re-solve is a few Newton steps, not a cold solve. The observer
;; calls (on-event …) on each event (or a driver does); below the threshold the
;; standing plan stands. Note: the solve runs inside the method turn — fine for a
;; scope's cadence; a production deployment would offload it.
(define (lp-snapshot scope-root)            ; total onhand per spec — what drift is measured against
  (let ((h (make-hash-table)))
    (for-each (lambda (r)
                (let ((s (economic-resource-conforms-to r)))
                  (when s (hash-set! h s (+ (hash-ref h s 0.0)
                                            (let ((m (economic-resource-onhand-quantity r))) (if m (measure-has-numerical-value m) 0.0)))))))
              ($ ($ scope-root 'observer) 'all-resources))
    h))
(define (lp-drift base now)                 ; the largest relative movement of any watched quantity
  ;; per spec, so an ample stock (the sea's fish, a meadow's feed) hides no drift
  ;; in a scarce one: a stock that moved past the threshold re-solves, whatever
  ;; else stands still. A stock appearing or vanishing moves wholly.
  (let ((d 0.0) (seen (make-hash-table)))
    (define (move! v0 v1)
      (let ((ref (max (abs v0) (abs v1))))
        (when (> ref 1e-9) (set! d (max d (/ (abs (- v1 v0)) ref))))))
    (hash-for-each (lambda (s v) (hash-set! seen s #t) (move! (hash-ref base s 0.0) v)) now)
    (hash-for-each (lambda (s v) (unless (hash-ref seen s #f) (move! v 0.0))) base)
    d))
(define* (lp-run scope-root opts warm-x #:optional (decided #f))     ; one plan over the live scope (warm if warm-x given)
  ;; WARM-X and DECIDED are the two halves of a standing plan's answer — the
  ;; activity vector and the discrete state — and both come back in: x re-centres
  ;; the barrier, decided seeds the search's incumbent
  (plan-scope scope-root
    #:demand (or (assq-ref opts 'demand) '()) #:periods (or (assq-ref opts 'periods) '(0))
    #:movable (or (assq-ref opts 'movable) '()) #:storable (or (assq-ref opts 'storable) '())
    #:whole (or (assq-ref opts 'whole) '())
    #:tau (or (assq-ref opts 'tau) 0.0) #:warm-x warm-x #:decided decided
    #:node-budget (assq-ref opts 'node-budget)     ; a governed number the scope may set beside tau
    ;; reproduction of labour-power is on by default (plan-scope's default);
    ;; an explicit #f in opts disables it (assq-ref alone can't tell absent
    ;; from a genuine #f, so probe the pair).
    #:reproduce? (let ((p (assq 'reproduce? opts))) (if p (cdr p) #t))))
(define* (lp-alist ints coms mat fill ntot report #:optional (scope-root #f))   ; internal metabolism path — no offer field
  ;; the actor's standing plan is held and handed out in rows: an actor's state and its replies are edges
  (plan->rows (plan-results->alist ints coms mat fill ntot report #:scope-root scope-root)))

(define-actor (^live-planner bcom scope-root opts plan x baseline)
  ;; plan: standing alist ; x: standing activity vector (warm start) ; baseline: snapshot
  #:portrait (lambda () (list scope-root opts plan x baseline))
  (methods
    ((plan) plan)                           ; the standing plan
    ((threshold) (or (assq-ref opts 'drift-threshold) 0.1))
    ((resolve)                              ; force a (warm) re-solve, refresh standing
     (call-with-values (lambda () (lp-run scope-root opts x (assq-ref plan 'decided)))
       (lambda (ints coms mat fill nx ntot report)
         (let ((al (lp-alist ints coms mat fill ntot report scope-root)))
           (bcom (^live-planner bcom scope-root opts al nx (lp-snapshot scope-root)) al)))))
    ((on-event ev)                          ; observer notifies; re-solve iff drift past threshold
     (let* ((now (lp-snapshot scope-root)) (d (lp-drift baseline now))
            (thr (or (assq-ref opts 'drift-threshold) 0.1)))
       (if (> d thr)
           (call-with-values (lambda () (lp-run scope-root opts x (assq-ref plan 'decided)))   ; WARM from the standing plan, x and decisions
             (lambda (ints coms mat fill nx ntot report)
               (let ((al (lp-alist ints coms mat fill ntot report scope-root)))
                 (bcom (^live-planner bcom scope-root opts al nx now)
                       `((resolved . #t) (drift . ,d) (newton . ,ntot) (met . ,fill))))))
           `((resolved . #f) (drift . ,d)))))))   ; below threshold: the standing plan stands (no bcom)

;; spawn a live planner that has already done its first (cold) solve.
(define* (spawn-live-planner scope-root #:key (demand '()) (periods '(0)) (movable '())
                                              (storable '()) (tau 0.0) (drift-threshold 0.1)
                                              (reproduce? #t) (node-budget #f))   ; the search's node budget, a governed number beside tau
  (let ((opts `((demand . ,demand) (periods . ,periods) (movable . ,movable)
                (storable . ,storable) (tau . ,tau) (drift-threshold . ,drift-threshold)
                (reproduce? . ,reproduce?) (node-budget . ,node-budget))))
    (call-with-values (lambda () (lp-run scope-root opts #f))
      (lambda (ints coms mat fill x ntot report)
        (spawn ^live-planner scope-root opts (lp-alist ints coms mat fill ntot report scope-root) x (lp-snapshot scope-root))))))


;;; ── THE SOLVE THROUGH READERS ─────────────────────────────────────────────
;;; Governance contributes to a solve as READERS of the scope, never as a
;;; solve of its own: WORLD (root sid . kw) → the resources a solve here may
;;; see with the socialized caps, the spans and the care rows; DEMAND (root
;;; sid . kw) → what the scope's tree asked for, its horizon and periods and
;;; the fold's terms, the caller's own demand riding on it; STAMP (root sid
;;; world alist) → the solve's alist with what only the projection knows
;;; (rented goods, the pool's slots as the solve left them, the steward
;;; rules, the demand it ran on). SOLVE is the plain solve, (root sid . kw)
;;; → alist. With no readers this is the plain solve, unchanged. One
;;; composition: the service's every plain solve and governance's
;;; plan-commune-scope both call it.
(define (solve-with-readers solve readers root sid . kw)
  (let* ((demand-of (assq-ref readers 'demand))
         (world-of  (assq-ref readers 'world))
         (stamp-of  (assq-ref readers 'stamp))
         (d (and demand-of (apply demand-of root sid kw)))
         (periods (if d (assq-ref d 'periods) (or (kw-ref kw #:periods) '(0))))
         (horizon (if d (assq-ref d 'horizon) (kw-ref kw #:horizon)))
         (w (and world-of (apply world-of root sid #:periods periods (kw-without kw '(#:periods)))))
         (rows (lambda (key more) (append (or (kw-ref kw key) '()) (or more '()))))
         (dem (let ((base (if d (assq-ref d 'demand) (or (kw-ref kw #:demand) '())))
                    (care (and w (assq-ref w 'care))))
                (if (pair? care) (sum-by-key care base) base)))
         (kw* (append
               (if w (list #:resource-view (let ((v (assq-ref w 'view))) (lambda (_) v))
                           #:eco-caps (rows #:eco-caps (assq-ref w 'caps))
                           #:span-of (rows #:span-of (assq-ref w 'span)))
                   '())
               (list #:demand dem #:horizon horizon #:periods periods)
               (if d (list #:desire-weights (rows #:desire-weights (assq-ref d 'desire-weights))
                           #:repro-floors (rows #:repro-floors (assq-ref d 'repro-floors))
                           #:budgeted-floors (rows #:budgeted-floors (assq-ref d 'budgeted-floors))
                           #:insurance (rows #:insurance (assq-ref d 'insurance)))
                   '())
               (kw-without kw (list #:resource-view #:eco-caps #:span-of #:demand #:horizon #:periods
                                    #:desire-weights #:repro-floors #:budgeted-floors #:insurance
                                    #:demand-scope #:home-of #:today #:period-epoch #:resolve #:care-upkeep-of
                                    #:place-scope-of #:spec-of #:rights-of #:uc-aid))))
         (alist (apply solve root sid kw*)))
    (if (and stamp-of w (list? alist)) (stamp-of root sid w alist) alist)))
