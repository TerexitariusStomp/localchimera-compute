;;; module/playnet/doors/service.scm — OCapN-facing facade for the planner
;;;
;;; The actor lives INSIDE planner-vat alongside ^scope-root and the
;;; underlying stores, so its methods have synchronous near-call access
;;; to plan-store/observer/agent-store/recipe-store via `$`. The lobby
;;; (in gateway-vat) holds a reference to it; the browser (across the
;;; OCapN websocket) calls it via `<-`. The vat boundary is the OCapN
;;; wire — there are no `with-vat` hops inside the actor's methods.
;;;
;;; Return values are always plain alists (or primitives) — never actor
;;; refs or records — so the wire format is OCapN-friendly and the
;;; browser projection layer can consume them unchanged.

(define-module (playnet doors service)
  #:use-module (playnet vf formulas flows)
  #:use-module (playnet doors record-rows)   ; a record as the page's row, with the snapshot's context
  #:use-module ((playnet knowledge catalogues housing) #:select (housing-gate?))
  #:use-module ((playnet solve recipe-response) #:select (response-margin curve-reach capture-at standing-position))
  #:use-module ((playnet vf formulas shocks) #:select (%stress-band))
  #:use-module ((playnet knowledge dsl holes) #:select (hole-admit compose-admit))
  #:use-module ((playnet knowledge catalogues substances) #:select (conservation-reading boundary-process? balance-flows))
  ;; containment-chain, used by the breadcrumb path around line 2122 — the
  ;; call was there without the import, so that branch was an unbound-variable
  ;; crash whenever a caller asked for a location chain.
  #:use-module (playnet vf aggregation containment)
  #:use-module (playnet pools labour-fold)     ; the labour fold
  #:use-module (playnet pools availability-pool)
  #:use-module ((playnet federation uc-matching)
                #:select (solve-uc-matching))          ; UC matching over the roster
  #:use-module (playnet federation descent)        ; the fold's dual: deployments walk down
  #:use-module (playnet vf aggregation unfold-node) ; the allocation descent's split
  #:use-module ((playnet vf aggregation fold-node)
                #:select (fold-node-reparent! wire-fold-parent!)) ; refederation, two exact messages
  #:use-module ((playnet folksonomy actor) #:select (^folksonomy))
  #:use-module ((playnet folksonomy graph) #:select (make-folksonomy))
  #:use-module ((playnet pools credit-fold)
                #:select (^credit-pool wire-credit-node!))  ; the sixth fold: universal credit
  #:use-module ((playnet pools voice-fold)
                #:select (^voice-pool wire-voice-node!))    ; the eighth: producer voice over parts
  #:use-module ((playnet observation adjustment)
                #:select (count-difference adjustment-event count-record-event))   ; a count lands the difference, stated once
  #:use-module (playnet utils envelope)    ; success, failure, catch-as-failure: the answer every door gives
  #:use-module (playnet doors inventory)   ; what a scope holds, as the inventory tab reads it
  #:use-module (playnet doors counts)
  #:use-module (playnet doors count-door)   ; a count lands; the planned count is scheduled and offered   ; what the ledger says of counts: standing, last, whose turn, the label
  #:use-module ((playnet pools reading-fold)
                #:select (^reading-pool wire-reading-node! readings-between window-fold cell->alist
                          node-readings-reply readings-between-reply))  ; the ninth: readings, every source kept apart, and their history
  #:use-module ((playnet knowledge catalogues thermal) #:select (declare-thermal-form!))   ; a state is a form: the scope declares it
  #:use-module ((playnet vf facts parts) #:select (validate-hand part->string))
  #:use-module ((playnet voice quorum) #:select (governance-policy policy-dials))   ; the governed dials, one registry
  #:use-module ((playnet pools slack-fold)
                #:select (^slack-node))                    ; the seventh: desire, per place
  #:use-module ((playnet economy means-fold)
                #:select (^means-pool wire-means-node! capacity-cells))
  #:use-module ((playnet economy demand-fold)
                #:select (^demand-node wire-demand-node! federation-home-of federation-voice-of
                          %demand-key-parts %need-cells %needs-of-plan-store))
  #:use-module ((playnet vf aggregation fold-node) #:select (sum-cells))
  #:use-module ((playnet plan store)
                ;; the open shifts skip accepted cells; the wire reads standing
                ;; from each record's OWN terms (the store's one temporal law)
                #:select (standing-accepts proposal-stands? intent-window-passed?
                          window-close-epoch))
  #:use-module (playnet utils clock)
  #:use-module ((playnet utils clock) #:select ((now . clock-now)))   ; the clock's now under a name no local `now` shadows
  #:use-module (playnet utils paths)
  #:use-module (goblins)
  #:use-module (ice-9 threads)               ; the solve's own thread (plan-fn*)
  #:use-module (goblins actor-lib methods)
  #:use-module ((playnet protocol dispatch) #:select (declared-methods))
  #:use-module (goblins utils hashmap)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)             ; <scope-nodes>
  #:use-module (playnet utils keywords)  ; alist->kw kw->alist kw-without kw-ref
  #:use-module ((playnet utils units) #:select (time-unit? hours-in %count-unit %effort-unit))   ; effort in any time unit, counted in hours
  #:use-module ((playnet utils keyed-id) #:select (keyed-id))
  #:use-module (srfi srfi-13)            ; string-prefix?
  #:use-module (ice-9 match)
  #:use-module (playnet algorithms rollup)
  #:use-module (playnet algorithms skill-matcher)
  #:use-module (playnet execution capacity-execute)
  #:use-module (playnet knowledge catalogues compiler)
  #:use-module (playnet knowledge catalogues eco)
  #:use-module (playnet knowledge recipes store)
  #:use-module (playnet algorithms elastic)
  #:use-module (playnet pools credit-fold)
  #:use-module (playnet vf facts rail)
  #:use-module (playnet vf schemas)
  #:use-module ((playnet vf serdes) #:select (vf-serialize vf-deserialize))
  ;; a read door's reply leaves as the rows the page reads
  #:use-module ((playnet wire replies) #:select (finished))
  #:use-module ((playnet wire rows) #:select (with-context wire-row* wire->plain))
  #:use-module (playnet vf formulas actions)
  #:use-module (playnet observation states)
  #:use-module (playnet vf beyond schedules)
  #:use-module (playnet utils store-utils)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet observation observer) #:select (target-passed? reach-slack))
  #:use-module ((playnet solve compile) #:select (bare-spec))
  #:use-module ((playnet solve engine) #:select (key-spec owned-spec spec-owner spec-base *desire-w0* want-as-cap? cap-scale-of stock-vocabulary))   ; the one key split; a citizen's own good; one whole hand; the shipped shape + its per-spec reference scale
  #:use-module (playnet scope live)   ; plan-scope->alist (the convex planner over the live scope)
  #:use-module ((playnet knowledge catalogues subsistence) #:select (sub-spec subsistence-species-base))   ; the floors a substitute is read against
  #:use-module ((playnet utils common) #:select (string-or-false take-up-to))
  #:use-module ((playnet utils store-utils) #:select (generate-id))
  #:use-module ((playnet observation evidence) #:select (evidence-hash? evidence-tag tags-evidence))
  #:use-module (playnet doors offers) ; the commitment arc's doors: offer-work, present-offers, accept-regret, the fresh check, commitment-drift
  #:use-module ((playnet vf formulas skill-law) #:select (skill-law-of competence-fold))   ; a skill's law off its spec, folded over the record
  #:use-module (playnet vf formulas counting)   ; the planned count: cadence, regime, process grammar
  #:use-module ((playnet plan accepts) #:select (floors->wire ->epoch deployment-bindings))  ; the dial's data: floors on the snapshot; the one clock coercion; standing accepts/holds as matching seeds
  #:use-module (playnet doors service chat)   ; event chats, stratum-stamped
  #:use-module (playnet doors service brief)  ; parse-overrides / plan-brief->string (orb)
  #:use-module ((playnet matching affinity)        ; need↔offer classification affinity
                #:select (chain-index match-pool))
  #:use-module ((playnet vf facts availability)    ; window overlap for the match's time dimension,
                #:select (availability-windows-overlap?     ; and the dated week the arcs wire carries
                          make-dated-week dated-week? dated-week-week dated-week-dated))
  #:use-module ((playnet matching filter-rule)     ; the slot's criteria sidecar + eligibility rule
                #:select (criteria-json->alist criteria-ref rule-passes? priority-for context))
  #:use-module ((playnet matching spatial) #:select (haversine-distance))
  #:use-module ((playnet folksonomy graph) #:select (category-term?))
  #:use-module ((json parser) #:select (json-string->scm))  ; dial availability JSON
  #:use-module ((json builder) #:select (scm->json-string)) ; bioregion boundary → wire string
  #:use-module ((playnet knowledge dsl vf-lint) #:select (lint-records))
  #:use-module ((playnet knowledge dsl findings) #:select (findings->wire))
  #:use-module ((ice-9 textual-ports) #:select (get-string-all))
  #:use-module (playnet knowledge dsl world)
  #:use-module ((playnet knowledge law jurisdiction-at) #:select (jurisdiction-at))
  #:use-module ((playnet legal registry) #:select (place-chain))
  #:use-module (playnet knowledge worlds presets)
  #:use-module (playnet knowledge catalogues substances)  ; substance-flow lens
  #:use-module ((playnet doors family solve) #:select (family-split family-bills family-externalities))
  #:use-module ((playnet doors family local) #:select (family-needs-of-json family-members-of-json))  ; the family face's purse split + its price to the others
  #:use-module (playnet vf facts tension-terms)               ; a need's kind + attached voice, as classification terms
  #:use-module (playnet lang provenance)          ; prose-claim graph (what-realizes …)
  #:use-module (playnet doors service provenance-trace) ; explain-claim / make-pull-of (injected)
  #:use-module (playnet vf facts audit)                   ; stage 3: needs are facts — the audit of a ratified kind
  #:use-module ((playnet solve externality)              ; the declaration-time price + the burn-meter
                #:select (marginal-displacement marginal-rows note-solve moved-summary voice-displacement))
  #:export (plain-plan-fn ^planner-service agent-position-predicate
            standing-demand-node-of standing-credit-uc scope-of-place spec-of-resource
            plan-results->dial-plan
            scope-matter-wire matter-results->wire
            materialize-composition! plan-claims!)
  #:re-export (scope-composition recipe-derived-contains)
  #:use-module ((playnet scope snapshot) #:select (scope-locations->wire dedup-locations))
  #:use-module (playnet doors slots)
  #:use-module ((playnet scope replica) #:select (scope->replica replica->text))
  #:use-module ((playnet observation log-observe) #:select (%log-actions do-log-observe)))   ; an observation of one's own doing   ; a scope's books, copied to its member's device   ; what people ask for and offer: the slot doors' own bodies   ; a scope's places, as a snapshot carries them
(use-modules ((playnet observation account) #:select (spec-claimable? resource-individually-claimable?   ; the rail, read off the recipes
                                                              claim-commitment claim-cid-terms open-claim-for fulfillment-remaining))   ; the plan's claim, the one word a claim door honours
             ((playnet vf facts rail) #:select (spec-rail social-portions)))   ; live in live.scm, at the solve door; the portion kept back, published there

;;; ── The legal layer (the `legal-snapshot` method below regenerates the
;;; law-face snapshot live) ──────────────────────────────────────────────
;;; The fold + the activity catalogue + the reform mirrors + the shared
;;; snapshot builder. Self-contained (no clash with the planner module): the
;;; same code the offline emitter (tools/emit/emit-law-snapshot.scm) runs, so the
;;; browser pulls dual-power/burden from the running planner instead of the
;;; committed law-snapshot.json.
(use-modules (playnet legal registry))
(use-modules (playnet vf facts partition))
(use-modules ((playnet observation practice) #:select (join-by-id practice-view-hours practice-view-dated)))
(use-modules ((playnet vf facts person-facts)
              #:select (need-id need-prefix need-id? means-id means-prefix means-id?
                        skill-id generic-skill-id skill-spec generic-labour-spec generic-labour-spec-id person-place-id person-place-prefix dwelling-id
                        position-key position-key? position-prefix person-argument-position
                        home-row home-row-aid
                        location-share-key location-modes fix-fresh?
                        person-write-doors person-read-doors)))
(use-modules (playnet federation crossing-set))
(use-modules (playnet legal reform))
(use-modules (playnet knowledge law aspects))             ; aspects as ProcessSpecs (grounds L,I,D)
(use-modules (playnet legal crossings))                        ; the OPEN crossing catalogue
(use-modules (playnet vf facts places))                    ; the ONE containment tree
(use-modules (playnet knowledge law context-pack))    ; a jurisdiction = one drop-in file
(use-modules (playnet knowledge catalogues us-states-fips))
(use-modules (playnet knowledge worlds free-food-distribution))
(use-modules (playnet knowledge law activities))
(use-modules (playnet knowledge law reform-mirrors))
(use-modules (playnet knowledge law structural-demands))
(use-modules (playnet knowledge law snapshot-build))
;; the fragility catalogue (the registry's source of truth) — for the fragility
;; face wire. Loaded here because the planner core loads only tension-kinds.
(use-modules (playnet knowledge catalogues eco))
(use-modules (playnet knowledge worlds bioregions))    ; set-spatial-boundary! — the boundary-seeding wire (≈:1297) calls it, and until this import it resolved NOWHERE in this module: the wire test re-implements the seeding, so only an unbound-variable scan saw it

;;; ── Payout helpers (see the payout methods in ^planner-service) ──────────
(define %payout-spec "spec-xmr")
(define (intent-private? i)
  "An intent that names something of one member's that no other reader is
   owed — today the payout intents, which carry a destination address. Kept
   out of the snapshot and the query door; the member reads their own via
   my-payouts."
  (let ((id (intent-id i)))
    (and (string? id) (string-prefix? "payout:" id))))
(define (payout-source-id aid)
  "The member's claimed-XMR record: what the shop's claim of `res-xmr-main`
   lands in (account.scm: to-resource = resource-id ^ \"-\" ^ aid)."
  (string-append "res-xmr-main-" aid))
(define (monero-address-plausible? a)
  "Shape check only — a standard/sub address (95) or an integrated one (106)
   in the base58 alphabet. The wallet is the authority on validity; this
   keeps a typo from becoming a parked intent."
  (and (string? a)
       (memv (string-length a) '(95 106))
       (string-every (lambda (c)
                       (string-index "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz" c))
                     a)
       #t))
(define (payouts-of ps aid)
  "The payout intents, AID's own or (AID #f) everyone's, oldest first."
  (sort (filter (lambda (i)
                  (and (string? (intent-id i))
                       (string-prefix? "payout:" (intent-id i))
                       (or (not aid) (equal? aid (intent-provider i)))))
                ($ ps 'all-intents))
        (lambda (a b) (string<? (intent-id a) (intent-id b)))))
(define* (payout-available obs ps aid #:key (owed 0.0))
  "What AID may still ask to send: their claimed XMR on hand, plus OWED (what
   the commons owes them, already priced in XMR — economy/debts.scm
   debts-owed-in-xmr, injected as owed-of; see the ^planner-service header),
   less every payout of theirs still OPEN — pending, sending, or unsettled
   (a transfer the gateway lost sight of reserves the claim until an
   operator settles or fails it, so a re-ask can never pay twice)."
  (let* ((r  ($ obs 'get-resource (payout-source-id aid)))
         (oh (and r (economic-resource-onhand-quantity r)))
         (have (+ (if oh (measure-has-numerical-value oh) 0) owed))
         (pending (fold + 0 (map (lambda (i) (measure-has-numerical-value (intent-resource-quantity i)))
                                 (filter (lambda (i) (payout-open? (intent-state i)))
                                         (payouts-of ps aid))))))
    (max 0 (- have pending))))
(define (payout-open? state)
  (or (member state '("pending" "sending"))
      (and (string? state) (string-prefix? "unsettled:" state))))
(define (payout->alist i)
  "A payout intent as the plain alist its readers (the runner, the member's list) hold:
   the payout table's row, read back."
  (wire->plain (wire-row* %payout-wire i)))
(define* (payout-restate! ps i state finished? #:key (began (intent-has-beginning i)))
  "The intent with a new STATE (and finished flag), re-added silently —
   an intent is immutable, so a status change is remove + add of its twin.
   BEGAN (has-beginning) is the instant the coins started moving."
  ($ ps 'remove-intent (intent-id i))
  ($ ps 'add-intent-silent
     (copy-intent i #:has-beginning began #:state state #:finished finished?)))

;;; ── A journey is a performed Process ─────────────────────────────────
;; The trip's process and the commitment for its arrival are named from the
;; departure's commitment, so the arrival finds them again; both ids are opaque.
(define (trip-ids cid)
  "(process-id . arrival-commitment-id) of the journey whose departure commitment is CID."
  (cons (keyed-id "trip" cid) (keyed-id "arrive" cid)))

(define (trip-good rs mode-rp)
  "The good a trip moves: the pickup flow's spec of its MODE-RP, a rider when no mode
   of the scope covers the way it was made."
  (or (and mode-rp
           (let ((f (find (lambda (f) (eq? 'pickup (recipe-flow-action f)))
                          (car ($ rs 'flows-for-process (recipe-process-id mode-rp))))))
             (and f (recipe-flow-resource-conforms-to f))))
      "spec-rider"))

(define (ensure-place! sts place)
  "A \"geo:lat,lng\" place is minted as a SpatialThing, so every trip's location
   references one; any other id is the caller's own."
  (when (and (string? place) (string-prefix? "geo:" place)
             (not (false-if-exception ($ sts 'get-location place))))
    (let* ((parts (string-split (substring place 4) #\,))
           (lat (and (= 2 (length parts)) (string->number (car parts))))
           (lon (and lat (string->number (cadr parts)))))
      (when (and lat lon)
        ($ sts 'add-location (make-spatial-thing #:id place #:name place #:lat lat #:long lon))))))

;;; ── EconomicEvent builder ────────────────────────────────────────────
;;; Wraps the 29-positional-arg make-economic-event with keyword args.
;;; Field defaults are #f, so callers only specify what they care about.

(define* (make-trip-event #:key id action input-of output-of agent (beg #f) (end #f)
                                point spec from to fulfills note scope)
  "A journey's pickup or dropoff event, resource-less: the trip's process as
   INPUT-OF (the pickup) or OUTPUT-OF (the dropoff), one SPEC moved (the mode's pickup
   flow's, a rider), the departure BEG or the arrival END and the instant POINT, the
   origin FROM and, for the dropoff, the destination TO, FULFILLING the commitment of
   its own end. The observer pairs the two by the process."
  (make-economic-event
    #:id id #:action action #:input-of input-of #:output-of output-of #:resource-conforms-to spec
    #:provider agent #:receiver agent #:resource-quantity (and spec (make-measure 1 %count-unit))
    #:has-beginning beg #:has-end end #:has-point-in-time point #:created (iso-now)
    #:at-location from #:to-location to
    #:fulfills fulfills
    #:note note #:in-scope-of (list scope)))

;; make-work-event lives in live.scm: the ONE constructor of a work event, shared
;; with record-work-done, so every door records the same terms on the same fields.

;;; ── Member projection ────────────────────────────────────────────────

(define (cat-terms . category-lists)
  "Flatten classification strings into folksonomy term-ids: genuine
   categories only (category-term?), legacy slash-paths expanded into their
   segments — the same expansion categories->seed-doc used to seed the
   commons' cut, so a spec's tags and the template's terms meet by id. The
   segments of one path are the specific-to-general ladder a match needs."
  (delete-duplicates
   (append-map
    (lambda (c)
      (if (category-term? c)
          (filter (lambda (s) (not (string-null? s))) (string-split c #\/))
          '()))
    (apply append (map (lambda (l) (if (list? l) l '())) category-lists)))))


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

;;; ── Process / recipe-process lookup helpers ──────────────────────────

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

;; THE LAST SOLVE, per scope: (cons demand solve-alist). A solve / plan /
;; materialize lands it; build-snapshot reads it so the dial shows the REAL
;; coverage of the most recent solve. It lives in the scope's OWN plan-store
;; (a "solve:last" meta row — persisted, so a restart draws the last plan),
;; reached through a door the service sets at construction: a scope's result
;; is written by its own descent leaf into its own store and read from
;; there, so "each scope touches only its slice" holds down to storage, not
;; only in the routing. Outside a service (unit worlds with no roster) the
;; same door falls back to a process table.
(define (%solve-store-of scope-id) (%standing 'solve-store scope-id))   ; the live service's plan-store for a scope, or #f
(define %last-solve-fallback (make-hash-table))
;; a store that cannot hold the row (a mock, a minimal root) falls back to
;; the process table — the same grace every other door here extends to mocks
;; The store holds a plan's flows as the records they are, in the serialized form
;; every stored VF record takes (vf/serdes.scm); a row written before the flows
;; were records reads back as the row it is. The read is kept per stored value, so
;; a plan read twice is one plan.
(define %solve-read (make-hash-table))            ; scope-id → (stored . plan)
(define (solve->stored v)
  (cons (car v) (plan-map-flows (lambda (part f) (vf-serialize f)) (cdr v))))
(define (stored->solve scope-id stored)
  (let ((seen (hash-ref %solve-read scope-id #f)))
    (if (and seen (eq? (car seen) stored)) (cdr seen)
        (let ((v (cons (car stored) (plan-map-flows (lambda (part f) (vf-deserialize f)) (cdr stored)))))
          (hash-set! %solve-read scope-id (cons stored v))
          v))))
(define (last-solve-ref scope-id)
  (let ((ps (and %solve-store-of scope-id (%solve-store-of scope-id))))
    (or (and ps
             (false-if-exception
              (let* ((row ($ ps 'get-meta "solve:last"))
                     (stored (and row (assq-ref row 'solve))))
                (and (pair? stored) (stored->solve scope-id stored)))))
        (hash-ref %last-solve-fallback scope-id #f))))
;; the solve's OWN unix-seconds rides in the same durable row as the plan,
;; so a restart can tell a durable plan is FRESH without re-solving to find
;; out — %solve-at (below) is in-process only, and reading #f from it after
;; every restart used to read as "never solved", sweeping the whole roster
;; on every boot even when the durable plan was minutes old (found live).
(define (last-solve-at-ref scope-id)
  (let ((ps (and %solve-store-of scope-id (%solve-store-of scope-id))))
    (and ps (false-if-exception
             (let ((row ($ ps 'get-meta "solve:last")))
               (and row (assq-ref row 'at)))))))
(define (last-solve-set! scope-id v at)
  (let ((ps (and %solve-store-of (%solve-store-of scope-id))))
    (unless (and ps (false-if-exception
                     (begin ($ ps 'set-meta "solve:last"
                                (list (cons 'solve (solve->stored v)) (cons 'at at)))
                            #t)))
      (hash-set! %last-solve-fallback scope-id v))))

;; ── the burn-meter: the externality display, persisted per solve ───────────
;; The same door discipline as the solve cache one screen up: the scope's own
;; plan-store meta when it can hold the row, the process table when it cannot
;; (mocks, minimal roots). What accumulates is stage 0's data — the moved-
;; distribution that sizes a voice budget, and the scope's measured VCG bill
;; (solve/externality.scm, truth-telling.md).
(define %externality-fallback (make-hash-table))
(define (externality-history-ref scope-id)
  (let ((ps (and %solve-store-of scope-id (%solve-store-of scope-id))))
    (or (and ps (false-if-exception
                 (let ((row ($ ps 'get-meta "externality:history")))
                   (and row (assq-ref row 'history)))))
        (hash-ref %externality-fallback scope-id '()))))
(define (externality-history-set! scope-id hist)
  (let ((ps (and %solve-store-of (%solve-store-of scope-id))))
    (unless (and ps (false-if-exception
                     (begin ($ ps 'set-meta "externality:history"
                               (list (cons 'history hist))) #t)))
      (hash-set! %externality-fallback scope-id hist))))
(define (note-externalities! scope-id alist)
  "One solve landed: price the demand it RAN ON at its own duals and keep
   the display. Both come off the alist — `demand`, the fold's wants keyed
   \"spec#place@t\" (plan-commune-scope), and the duals — so a landing that
   carries no prices (the federated descent) notes nothing. The display's
   unit is the SPEC, so asks sum per spec across places and periods. Never
   the reason a solve fails — a noting error is reported and dropped."
  (catch #t
    (lambda ()
      (let ((asks '()))
        (for-each (lambda (d)
                    ;; the display's unit is the SCOPE's spec: a citizen's
                    ;; own good ("spec~aid") folds onto it
                    (let ((spec (spec-base (key-spec (car d)))) (q (cdr d)))
                      (when (number? q)
                        (let ((row (assoc spec asks)))
                          (if row (set-cdr! row (+ (cdr row) q))
                              (set! asks (cons (cons spec q) asks)))))))
                  (or (assq-ref alist 'demand) '()))
        (let ((rows (marginal-rows asks (make-pull-of alist))))
          (when (pair? rows)
            (externality-history-set!
             scope-id
             (note-solve (externality-history-ref scope-id) rows #:at (iso-now)))))))
    (lambda (key . args)
      (format (current-error-port) "note-externalities! ~a: ~a ~a~%" scope-id key args))))




;; how MET a spec is, as of the scope's last solve: produced/target from the
;; cached plan (0..1), or #f when no solve has run — the communal tier of a
;; need's "how it's met", on the row itself so the drawer needs no second read
(define *met-memo* (make-hash-table))   ; scope-root → (cached-solve . its dial plan)

;; a need's row reads how far it is met through this: the last solve of SCOPE-ID
(define (met-of-scope scope-root scope-id)
  (lambda (spec) (spec-met scope-root scope-id spec)))

(define (spec-met scope-root scope-id spec)
  ;; keyed by the scope's own root object, not its id string: two different
  ;; ^planner-service instances can name a scope the same thing (every test's
  ;; "Granary"), and a bare scope-id key would let one instance's cached plan
  ;; answer another's spec-met before it has ever solved
  (let* ((cached (and scope-id (last-solve-ref scope-id)))
         (memo (and cached (hash-ref *met-memo* scope-root #f)))
         ;; the projection once per solve, not once per row
         (plan (and cached
                    (if (and memo (eq? (car memo) cached)) (cdr memo)
                        (let ((p (plan-results->dial-plan scope-root (car cached) (cdr cached))))
                          (hash-set! *met-memo* scope-root (cons cached p))
                          p))))
         (row (and plan (find (lambda (n) (equal? (assq-ref n 'id) spec))
                              (or (assq-ref plan 'needs) '())))))
    (and row (assq-ref row 'met))))

;; The UC means allocations, landed: scope-root → ((spec . (located-good . cap)) …),
;; written by the `means-plan` verb (the consensus row run live) and MERGED into
;; every subsequent solve's #:eco-caps — so a scope's next plan is bounded by
;; what the federation allocated it, warm-started from what it held before.
;; Keyed by the scope's own root, not its id string — same reason as
;; *slot-criteria*/*met-memo* above: two ^planner-service instances can both
;; have a "Granary".
(define *means-caps* (make-hash-table))
(define (means-caps-of root)
  (map cdr (hash-ref *means-caps* root '())))
;; ── the process-wide door to the live service's standing demand nodes ──────
;; A solve turn (planner-vat) needs "aid → this scope's ^demand-node" without
;; crossing a vat and without the service $-ing itself mid-turn, so the
;; service publishes its lookup here at construction. One service per process
;; in production; a later spawn takes the door over, which is what a test
;; wants too. Kept boxed by the set! below (the silent-divergence rule).
(define %standing-service #f)   ; THE ONE HANDLE: the live service's reads, (what . args) → value, set at construction
(define (%standing what . args)
  (and %standing-service (apply %standing-service what args)))
(define (scope-of-place place-id)
  "The scope whose spatial-thing store holds PLACE-ID, or #f."
  (any (lambda (e)
         (and (any (lambda (st) (equal? place-id (spatial-thing-id st)))
                   ($ ($ (cdr e) 'spatial-thing-store) 'all-locations))
              (car e)))
       (or (%standing 'roster) '())))
(define (spec-of-resource resource-id)
  "The spec RESOURCE-ID conforms to, in whichever scope holds it, or #f."
  (any (lambda (e)
         (let ((r ($ ($ (cdr e) 'observer) 'get-resource resource-id)))
           (and r (economic-resource-conforms-to r))))
       (or (%standing 'roster) '())))

;; ── every node a scope stands up, as one record ────────────────────────────
;; Eight folds and three descents; a scope has all eleven from the moment it is
;; wired, the UC roots are one such record, and every read, reparent and
;; wiring walks the record's fields. Wired ⇔ the record exists.
(define-record-type <scope-nodes>
  (make-scope-nodes labour means demand folksonomy credit slack voice reading deployment allocation solve)
  scope-nodes?
  (labour nodes-labour) (means nodes-means) (demand nodes-demand) (folksonomy nodes-folksonomy)
  (credit nodes-credit) (slack nodes-slack) (voice nodes-voice) (reading nodes-reading)
  (deployment nodes-deployment) (allocation nodes-allocation) (solve nodes-solve))
(define %fold-kinds (list nodes-labour nodes-means nodes-demand nodes-folksonomy nodes-credit nodes-slack nodes-voice nodes-reading))
(define %descent-kinds (list nodes-deployment nodes-allocation nodes-solve))
(define (standing-credit-uc)
  "The federation's standing ^credit-pool (the UC root's), or #f: the pool a
citizen's voice is read against."
  (%standing 'credit-uc))

(define (standing-demand-node-of aid)
  "The standing ^demand-node the live ^planner-service keeps for AID, or #f.
demand-of / demand-cells-of read such a node directly — the drop-in for a
scope walk wherever a solve wants the scope's declared needs."
  (%standing 'demand-node aid))

(define (set-means-cap! root spec cap-pair)
  (hash-set! *means-caps* root
             (cons (cons spec cap-pair)
                   (filter (lambda (e) (not (equal? spec (car e))))
                           (hash-ref *means-caps* root '())))))
;; ── warm starts and freshness, beside the cache they qualify ───────────────
;; The solution vector is the NEXT solve's warm start and nothing else: popped
;; off the alist here into an in-process table (a restart cold-starts, which
;; is the honest default), so what the callers see, the wire carries and the
;; plan-store persists stays lean. The stale mark is the snapshot's
;; while-revalidating answer: an accept re-solves on a LATER vat turn, and
;; until that solve lands the cached plan describes the world before the
;; decision — the wire says so instead of showing it as current. The
;; timestamp is what the time tick reads.
(define %warm-x       (make-hash-table))   ; scope-id → the last solve's x
(define %stale-solves (make-hash-table))   ; scope-id → #t while a re-solve is due
(define %solve-at     (make-hash-table))   ; scope-id → unix seconds, hydrated from the durable row on first ask
(define %solve-vocab  (make-hash-table))   ; scope-id → the goods the last solve read stock against (engine stock-vocabulary)
(define (solve-vocabulary-of scope-id)
  "The vocabulary the scope's last plan was solved with: a confirmation reads a holding
   as that plan did. A scope not solved in this process reads the standing recipes'."
  (or (hash-ref %solve-vocab scope-id #f) (stock-vocabulary)))
;; %solve-at IN-PROCESS, but its answer for a restored scope is the durable
;; timestamp beside the durable plan — hydrated once, then cached like any
;; other read. A cold #f here used to read as "never solved" and swept the
;; whole roster on every boot; the durable row already knew better.
(define (solve-at-of scope-id)
  (or (hash-ref %solve-at scope-id #f)
      (let ((at (last-solve-at-ref scope-id)))
        (when at (hash-set! %solve-at scope-id at))
        at)))
(define (warm-x-of scope-id) (hash-ref %warm-x scope-id #f))
(define (mark-solve-stale! scope-id) (hash-set! %stale-solves scope-id #t))
(define (solve-part cached key)
  "One part of a cached solve (`last-solve-ref`'s (demand . plan)): the plan's KEY, or none."
  (or (and cached (assq-ref (cdr cached) key)) '()))
(define (planned-material scope-id)
  "The material rows of the scope's last plan: every produce, consume, pickup, dropoff
   and use it expects, each a Commitment, or none before a first solve."
  (solve-part (last-solve-ref scope-id) 'material))
(define (planned-runs scope-id)
  "The runs the scope's last plan names: ((run . recipe-process) …), each run a Process of
   its own that its relocation rows are the inputs and outputs of."
  (solve-part (last-solve-ref scope-id) 'runs))
(define (planned-rows scope-id action spec place when-iso proc)
  "The material rows of the scope's last plan that are the row ACTION SPEC at PLACE
   of PROC (at WHEN-ISO when one is named). What a confirmation may record is what
   the plan states."
  (filter (lambda (m)
            (and (equal? (format #f "~a" (row-action m)) action)
                 (equal? (row-spec m) spec)
                 (equal? (or (row-place m) "") (or place ""))       ; the wire spells an absent value ""
                 (equal? (or (row-run m) "") (or proc ""))
                 (or (not when-iso) (equal? when-iso "") (equal? (format #f "~a" (row-when m)) when-iso))))
          (planned-material scope-id)))
(define (hold-row! obs scope-id m)
  "Register the plan's row M as the commitment it is, under the plan's own row id: a
   row the plan states again moves its target and keeps what was confirmed."
  ($ obs 'register-commitment (held-commitment m scope-id)))
;; the record-flow door names one of its arguments `row-id` (the protocol declares it);
;; under that name the door reads a row's id by this one
(define planned-row-id row-id)
(define (row-left obs m)
  "What the events fulfilling plan row M have not yet met of it."
  (fulfillment-remaining ($ obs 'get-fulfillment (row-id m))))
(define (cache-solve! scope-id demand alist)
  (let* ((xrow  (assq 'x alist))
         (alist (if xrow (assq-remove! (list-copy alist) 'x) alist)))
    (when (and scope-id (list? demand))
      ;; a plan that is NOT a plan warms nothing: a certificate that refused
      ;; the point (feasible? #f — phase-I's exterior start handed back) would
      ;; start the next solve where this one could not get in, and it
      ;; stayed out (found live: steps=0, the same program solving cold in
      ;; 25 steps). The standing warm start stands until a plan replaces it.
      (when (and xrow
                 (let ((c (assq-ref alist 'certificate)))
                   (not (and (list? c) (eq? #f (assq-ref c 'feasible?))))))
        (hash-set! %warm-x scope-id (cdr xrow)))
      (let ((now (instant->unix (clock-now))))
        (hash-set! %solve-at scope-id now)
        (hash-set! %solve-vocab scope-id (stock-vocabulary))
        (hash-remove! %stale-solves scope-id)
        (last-solve-set! scope-id (cons demand alist) now))
      (plan-claims! scope-id alist)          ; the plan's claims stand as the commitments a claim fulfils
      (note-externalities! scope-id alist)   ; the burn-meter hears it too
      ;; the slack fold hears every solve that lands (set by the service)
      (when %on-solve-cached (%on-solve-cached scope-id)))
    ;; what a door replies with: the plan as it leaves the process
    (plan->rows alist)))
(define %on-solve-cached #f)


;; ── the plan's claims, minted as the commitments a claim fulfils ────────────
;; Each `claims` row of a landed plan (claimant, spec, quantity, place, period)
;; is registered on the scope's observer as a `transfer` commitment
;; (account.scm claim-commitment); the ledger records a claim event only against
;; one, for no more than remains on it. Rows the new plan no longer states are
;; retired while still open, so a stale plan's word admits nothing; a partly
;; confirmed row the plan restates keeps what was confirmed (the observer reads
;; fulfilment off the events, so a row stated again moves its target only). Outside a service (mocks, unit worlds) there is
;; no observer to mint on, and the plan's rows are read from the alist alone.
;; A row's silence is not a statement: a solve that carries no `claims` key
;; (a federated row states materials and crossings only) says nothing about
;; claims, so the standing commitments stay; a plan that states `claims '()`
;; retires them.
(define (plan-claims! scope-id alist)
  (let ((obs (%standing 'observer scope-id)))
    (when (and obs (assq 'claims alist))
      (let* ((rows (or (assq-ref alist 'claims) '()))
             (fresh (map (lambda (r)
                           (claim-commitment (row-spec r) (assq-ref r 'claimant)
                                             (row-quantity r) scope-id
                                             #:place (row-place r)
                                             #:when-iso (let ((p (assq-ref r 'period))) (and p (format #f "~a" p)))))
                         rows))
             (keep  (map commitment-id fresh)))
        (for-each (lambda (fs)
                    (let ((cid (fulfillment-state-commitment-id fs)))
                      (when (and (claim-cid-terms cid) (not (member cid keep)))
                        ($ obs 'retire-commitment cid))))
                  ($ obs 'open-fulfillments))
        ;; every row the plan states is registered: a row it restates moves the
        ;; commitment's target, and what was confirmed is read off the events, so a
        ;; restated or withdrawn-and-restated row keeps its confirmations
        (for-each (lambda (c) ($ obs 'register-commitment c)) fresh)))))

;; one scope's OWN slack cells off its cached solve — (want . place) and
;; (met . place), the per-place sums location-slacks takes the ratio of. Own
;; means the places the scope's own store holds: a scope's solve answers for
;; the demand of its whole subtree, so its cached rows also name its members'
;; places, and those places' cells are the members' to state (the parent adds
;; what its children climb with, and would otherwise hold them twice).
(define (scope-own-place-ids scope-id)
  "The ids of the places SCOPE-ID's own spatial store holds, or #f when the
service does not know the scope (nothing to filter by)."
  (let ((e (assoc scope-id (or (%standing 'roster) '()))))
    (and e (false-if-exception
            (map spatial-thing-id ($ ($ (cdr e) 'spatial-thing-store) 'all-locations))))))
(define (scope-own-slack scope-id)
  (let ((cached (last-solve-ref scope-id))
        (own (scope-own-place-ids scope-id)))
    (define (own? place) (or (not own) (member place own)))
    (if (not cached) '()
        (let ((want (make-hash-table)) (met (make-hash-table)))
          (for-each (lambda (d)
                      (when (and (list? d) (>= (length d) 4) (string? (list-ref d 1)) (own? (list-ref d 1)))
                        (let ((place (list-ref d 1)) (q (or (list-ref d 3) 0)))
                          (hash-set! want place (+ (hash-ref want place 0) q)))))
                    (car cached))
          (for-each (lambda (m)
                      (when (memq (row-action m) creating-actions)
                        (let ((place (row-place m)) (q (or (row-quantity m) 0)))
                          (when (and (string? place) (own? place))
                            (hash-set! met place (+ (hash-ref met place 0) q))))))
                    (solve-part cached 'material))
          (append (hash-map->list (lambda (p q) (cons (cons 'want p) q)) want)
                  (hash-map->list (lambda (p q) (cons (cons 'met p) q)) met))))))
(define (scope-plan-wire scope-root scope-id)
  (let ((cached (last-solve-ref scope-id)))
    (and cached
         (let ((p (plan-results->dial-plan scope-root (car cached) (cdr cached))))
           ;; stale-while-revalidating: this plan predates a decision whose
           ;; re-solve has not landed yet — shown, and said to be old
           (if (hash-ref %stale-solves scope-id #f) (acons 'stale #t p) p)))))

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

(define (scope-matter-wire scope-root scope-id)
  (let ((cached (last-solve-ref scope-id)))
    (and cached (matter-results->wire scope-root (cdr cached)))))

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

(define (scope-fragility-wire scope-root scope-id)
  (let ((cached (last-solve-ref scope-id)))
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
             (people . ,(scope-reproduction-people scope-root scope-id (cdr cached)))
             (controls . ,(let ((draw-of (lambda (spec) (hash-ref draws spec 0.0))))
                             (append (catalogue->wire *planetary-catalogue* draw-of)
                                     (rented-controls (scope-rented-goods scope-root (cdr cached)) draw-of)
                                     ;; the calamity reserves the last plan held — the tab, as wedges
                                     (reserve-controls (or (assq-ref (cdr cached) 'reserves) '()))))))))))

;; project the scope's person-agents as the fragility face reads them (POPULATION
;; shape): attributes via agent->subsistence-ctx, intake from the plan's material
;; (per-person nutrient production, spec "nutrient|pid"). #f when the scope has no
;; people, so the dial keeps its demo cohort.
(define (scope-reproduction-people scope-root scope-id solve-alist)
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
(define (location-slacks scope-id)
  (let ((cached (last-solve-ref scope-id)))
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
           out))))

;;; ── the bridge: a produced batch CARRIES its derived composition ────────────
;; The three rungs of the substance ladder joined into one path. The recipe-
;; DERIVED composition (spec-level numbers) is materialized as real substance
;; EconomicResources CONTAINED-IN the produced batch (instance-level), so the
;; observer's containment cascade draws them down whenever the batch is consumed
;; or relocated. Derivation supplies the numbers; contained-in carries them per-
;; batch; the cascade conserves them. Pure VF: the contents are ordinary resources
;; whose contained-in points at the product — no schema change, no observer change.
;;
;; Call after a product resource has been produced/seeded. `qty` is the batch
;; size in the product's own unit; the contained substances are in kg of element.
;; Returns the ((element . mass) …) it materialized. Composition is recipe-derived
;; (the store's recipes win) and falls back to *contains* only absent a recipe —
;; the same source the matter wire reads, so the lens and the stockbook agree.
(define* (materialize-composition! scope-root product-res-id spec qty #:key (location #f))
  (let* ((rs      ($ scope-root 'recipe-store))
         (obs     ($ scope-root 'observer))
         (comp    (composition-in-force (recipe-derived-contains rs) *contains*))
         (content (substance-content spec qty #:contains comp)))
    (for-each
     (lambda (p)
       (let ((el (car p)) (mass (cdr p)))
         ($ obs 'record-resource
            (make-economic-resource
             #:id (string-append product-res-id ":" el)         ; child id
             #:name (string-append el " in " product-res-id)
             #:conforms-to el                                          ; conforms-to the element
             #:accounting-quantity (make-measure mass "kg") #:onhand-quantity (make-measure mass "kg")
             #:current-location location                                    ; current-location; no virtual one
                                    ; accountable: the commons, as its batch; no custodian, stage, state
             #:contained-in product-res-id                                 ; contained-in the batch (16th field)
))))
     content)
    content))

;; the location wire for ONE scope: each place with its coords, its contained-in
;; parent (the containment forest), and its per-place demand-shortfall slack from
;; the last solve. Factored out of build-snapshot so the federation-wide overlay
;; can UNION a scope's places with its siblings' (see the scope-snapshot method).
;; Load SpatialThing EXTENTS from a SINGLE-SOURCE GeoJSON FeatureCollection into the
;; planner's *spatial-boundaries* — so any SpatialThing whose id matches a feature (a
;; bioregion, a nation, a district) carries its real polygon and it flows to the dial
;; (scope-locations->wire → OCapN → day-boot → the map). The geometry is stored as a
;; JSON STRING (opaque past day-boot's integer-only writer; the dial JSON.parses it).
;; Generic by id-match; a missing file leaves things as points. Returns the count.
(define (load-boundaries! . maybe-path)
  (catch #t
    (lambda ()
      (let* ((path (or (and (pair? maybe-path) (car maybe-path))
                       (find file-exists? '("browser/data/geo/boundaries.json"
                                            "../browser/data/geo/boundaries.json"
                                            "/srv/playnet/browser/data/geo/boundaries.json"))
                       "browser/data/geo/boundaries.json"))
             (fc    (json-string->scm (call-with-input-file path get-string-all)))
             (feats (assoc-ref fc "features"))
             (lst   (cond ((vector? feats) (vector->list feats)) ((list? feats) feats) (else '())))
             (n 0))
        (for-each (lambda (f)
                    (let* ((props (assoc-ref f "properties"))
                           (id    (and (pair? props) (assoc-ref props "id")))
                           (geom  (assoc-ref f "geometry")))
                      (when (and (string? id) geom)
                        (set-spatial-boundary! id (scm->json-string geom))
                        (set! n (+ n 1)))))
                  lst)
        n))
    (lambda _ 0)))
(load-boundaries!)   ; populate at module load; best-effort, no-op if absent



;; The fold keeps hours exact (a fraction of whole hours is an exact ratio such as
;; 4/3); the wire carries numbers the syrup encoder can write, so an exact ratio
;; leaves as an inexact number where the credit standing is read.
(define (wire-number x)
  (if (and (number? x) (exact? x) (not (integer? x))) (exact->inexact x) x))
(define* (credit->wire scope-root aid #:optional (roots (list scope-root)))
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
      (pk 'credit->wire-failed aid args)
      #f)))

(define* (build-snapshot scope-root scope-id plan-id #:optional (acting-aid #f)
                         #:key (extra-locations '()) (recipe-responses '()) (credit-roots #f))
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
         (cached  (last-solve-ref scope-id))
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
                      (append (scope-locations->wire scope-root (location-slacks scope-id))
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
      (plan . ,(scope-plan-wire scope-root scope-id))
      ;; the same solve as a SUBSTANCE-flow graph (the matter face): product
      ;; flows lifted to conserved elements via the contains relation. #f until
      ;; a solve has run. day-boot stringifies the masses → window.__matterFlow.
      (matter . ,(scope-matter-wire scope-root scope-id))
      ;; the federation's registered fragilities + their live slack (the fragility
      ;; face). #f until a solve; it reaches the app through the scope snapshot (the "fragility" topic).
      (fragility . ,(scope-fragility-wire scope-root scope-id))
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
      (credit . ,(and acting-aid (credit->wire scope-root acting-aid (or credit-roots (list scope-root)))))
      ;; the LIVED layer: every economic event the observer holds — what
      ;; actually happened, beside the plan that asked for it. Both ends of a
      ;; move ride, so the map can draw the journey.
      (events . ,(or ($ obs 'all-events) '()))
      (alerts . ,alerts)
      ;; the escalation door's reading, per floor-defending process: rung,
      ;; days-to-forcing, the branches' stretch — the dial's data
      (floors . ,(floors->wire ps)))
     ctx)))

;;; ── Process context (detail panel) ───────────────────────────────────

(define (recipe-flow->flow-alist f rs is-input?)
  (let* ((spec (recipe-flow-resource-conforms-to f))
         (rq   (recipe-flow-resource-quantity f))
         (eq   (recipe-flow-effort-quantity f))
         (m    (or rq eq)))
    `((spec . ,spec)
      (spec-name . ,(or (lookup-spec-name rs spec) spec ""))
      (qty . ,(or (measure->qty m) 1))
      (unit . ,(or (measure->unit m) ""))
      (action . ,(recipe-flow-action f))
      (is-input . ,is-input?))))

(define (recipes-conforming rs aspect-id)
  "All recipe ids that PERFORM ASPECT-ID — any recipe-process whose
   process-conforms-to matches. The structural gate a legal aspect (or spec) opens:
   which recipes it enables. Generalizes find-recipe-process-for-spec to every hit.
   Injected into (explain-claim …) as #:gated-by, keeping the provenance bridge
   decoupled from the planner."
  (if (not aspect-id) '()
      (let ((want (if (symbol? aspect-id) (symbol->string aspect-id) aspect-id)))
        (filter-map
         (lambda (r)
           (let ((rps ($ rs 'processes-for-recipe (recipe-id r))))
             (and (any (lambda (rp)
                         (equal? (recipe-process-process-conforms-to rp) want))
                       rps)
                  (recipe-id r))))
         ($ rs 'all-recipes)))))

;; The <recipe-process> PROCESS-ID stands for: a recipe-process id (e.g.
;; 'rp-meeting') directly, else a dynamic id (a performed trip, dependent demand)
;; through the <process> record the books or the registry hold and its based-on spec.
(define (resolve-recipe-process scope-root process-id)
  (let ((rs   ($ scope-root 'recipe-store))
        (obs  ($ scope-root 'observer))
        (preg ($ scope-root 'process-registry)))
    (or ($ rs 'get-recipe-process process-id)
        (let ((p (or ($ obs 'get-process process-id) ($ preg 'get process-id))))
          (and p (find-recipe-process-for-spec rs (process-based-on p)))))))

;; The specs PROCESS-ID engages without consuming — its `use` flows, the Svc|
;; capacities a socialized means lends — what the steward gate asks about.
(define (proc-use-specs scope-root process-id)
  (let ((rp (false-if-exception (resolve-recipe-process scope-root process-id))))
    (if (not rp) '()
        ;; the means a process puts in someone's hands: what it uses, and
        ;; what it carries (a pickup — the key a carrier walks to the door)
        (filter-map (lambda (f) (and (memq (recipe-flow-action f) (append occupying-actions (filter input-action? relocating-actions)))
                                     (recipe-flow-resource-conforms-to f)))
                    (car ($ ($ scope-root 'recipe-store) 'flows-for-process
                            (recipe-process-id rp)))))))

(define (build-process-context scope-root process-id)
  (let* ((rs ($ scope-root 'recipe-store))
         (rp (resolve-recipe-process scope-root process-id)))
    (cond
      ((not rp)
       `((proc . ,process-id)
         (proc-name . #f)
         (inputs . ())
         (outputs . ())
         (upstream . ())
         (downstream . ())))
      (else
       (let* ((rp-id (recipe-process-id rp))
              (flows-pair ($ rs 'flows-for-process rp-id))
              (in-flows  (car flows-pair))
              (out-flows (cdr flows-pair)))
         `((proc . ,process-id)
           (proc-name . ,(or (recipe-process-name rp) process-id))
           (inputs . ,(map (lambda (f) (recipe-flow->flow-alist f rs #t)) in-flows))
           (outputs . ,(map (lambda (f) (recipe-flow->flow-alist f rs #f)) out-flows))
           (upstream . ())
           (downstream . ())))))))

;;; ── Mutation paths ───────────────────────────────────────────────────

(define* (do-accept-assignment scope-root iid provider scope-id #:key (admit? #f))
  "Promote an intent to a commitment, register the new commitment with
   the observer so fulfillment tracking is armed, return (ok . cid).
   ADMIT? (provider proc → bool), when given, is the steward gate — the
   owners' rule over who may draw the means the work's process uses; this
   door is where every assignment path ends, so it is asked here whatever
   presented the work."
  (let ((ps  ($ scope-root 'plan-store))
        (obs ($ scope-root 'observer)))
    (catch-as-failure
      (lambda ()
        ;; a DEMAND is worked toward, never accepted shut: a consume/use
        ;; intent addressed to someone else is the scope's standing terms —
        ;; the very demand the plan runs on — and only FULFILLMENT (events)
        ;; finishes it. Stated at the door, so no presentation rule
        ;; anywhere upstream has to remember it.
        (let ((it ($ ps 'get-intent iid)))
          (when (and it (memq (intent-action it) drawing-actions)
                     (intent-receiver it)
                     (not (equal? (intent-receiver it) provider)))
            (error "a demand is worked toward, never accepted shut" iid))
          ;; an offer that names its provider is that provider's to accept
          (when (and it (intent-provider it) (not (equal? provider (intent-provider it))))
            (error "this offer names another provider" iid provider))
          (when (and it admit? (not (admit? provider (intent-input-of it))))
            (error "the means this work draws are lent under a steward rule that names others"
                   iid provider)))
        (let ((cid ($ ps 'promote-to-commitment iid
                       `((provider . ,provider)
                         (receiver . ,scope-id)))))
          (cond
            ((not cid) (failure "promote-to-commitment returned #f"))
            (else
             ;; Register the commitment's target: its fulfilment is read off the
             ;; events that name it.
             ($ obs 'register-commitment ($ ps 'get-commitment cid))
             (success cid))))))))

;; ── Willingness: the solver-offers-first labour loop ─────────────────────────
;; The convex plan offers a candidate FIELD (per need, who'd help + a fair share).
;; A person responds by marking themselves WILLING (or withdrawing → DECLINED) for a
;; given skill@cell. Willingness is over-subscribable and binds NOTHING here — it is
;; an option, not a commitment; the single hours-budget bounds materialization later.
;; State lives as `status` meta on the DETERMINISTIC offer-intent id (oi|w|skill|cell),
;; so it persists across re-solves even though the intents are re-derived each plan.
(define (willing-key worker skill cell) (string-append "oi|" worker "|" skill "|" cell))

(define* (do-express-willingness scope-root worker skill cell willing? #:optional (hours #f))
  "Stamp WORKER's willingness for SKILL at CELL. willing? = #t marks status=willing
   (the person opts in to be materializable here); #f marks status=declined (withdraw).
   HOURS = the willing hours (an upper option, not a budget bind). The next
   gated re-solve admits only status=willing workers; the bundle hour-cap bounds them."
  (let ((ps ($ scope-root 'plan-store)))
    (catch-as-failure
      (lambda ()
        ($ ps 'set-meta (willing-key worker skill cell)
           `((status        . ,(if willing? 'willing 'declined))
             (worker        . ,worker) (skill . ,skill) (cell . ,cell)
             ,@(if hours `((willing-hours . ,hours)) '())))
        (success (if willing? 'willing 'declined))))))

;; Build the *willing?* gate predicate from persisted willingness meta. Returns #f
;; (⇒ the engine's default *willing?* ≡ #t, ungated — today's behaviour, the FIELD)
;; unless someone has opted in; once any status=willing exists, the predicate admits
;; ONLY status=willing (worker skill cell) triples — the MATERIALIZATION binding.
(define (willing-predicate scope-root)
  (let ((willing (willing-tuples ($ scope-root 'plan-store))))   ; shared scan (live.scm)
    (and (pair? willing)
         (lambda (w s c) (and (member (list w s c) willing) #t)))))

;; ── Live / expected POSITION — where an agent is, per period ─────────────────
;; All three sharing modes feed the SAME thing: a place per (agent, period) that
;; overrides the static primary-location as the planner's commute origin.
;;   • manual "I'm here now"  → set period 0 once
;;   • continuous live share  → set period 0 repeatedly (a watch)
;;   • expected trajectory    → set periods 0..N
;; The client snaps raw GPS to a known place id BEFORE sending (coarse by design —
;; the planner only ever sees a named location, never exact lat/lon).

;; Snap raw lat/lon to a place — the COARSENING step. Either the client snaps
;; and calls set-position with a place, or it sends raw coords to
;; set-position-latlon and the gateway snaps here; either way only a named,
;; coarse place is stored, never the exact coordinate.
;;
;; A place counts when it carries a real coordinate (a container declared
;; without one holds #f, or 0/0 for "none"), and a fix snaps to it only when
;; it is NEAR: within SNAP-KM. Farther than that the nearest place is not
;; where you are — it is another city — so the fix names a place of its own
;; (own-position-place!) rather than borrowing a distant one.
(define snap-km 12.0)
(define label-km 25.0)

(define (located? s)
  (let ((la (spatial-thing-lat s)) (lo (spatial-thing-long s)))
    (and (number? la) (number? lo) (not (and (zero? la) (zero? lo))))))

;; kilometres between two points: planar on a cos(lat)-shrunk longitude, which
;; is exact enough at the scale of a district
(define (km-between la1 lo1 la2 lo2)
  (let* ((k  111.2)
         (dy (* k (- la1 la2)))
         (dx (* k (cos (* (/ (+ la1 la2) 2.0) (/ 3.141592653589793 180.0))) (- lo1 lo2))))
    (sqrt (+ (* dx dx) (* dy dy)))))

;; the located place among LOCS nearest (lat, lon) within WITHIN km, or #f
(define (nearest-place locs lat lon within)
  (let loop ((ls locs) (best #f) (bd within))
    (cond ((null? ls) best)
          ((located? (car ls))
           (let ((d (km-between (spatial-thing-lat (car ls)) (spatial-thing-long (car ls)) lat lon)))
             (if (<= d bd) (loop (cdr ls) (car ls) d) (loop (cdr ls) best bd))))
          (else (loop (cdr ls) best bd)))))

(define (nearest-location scope-root lat lon)
  (let ((s (nearest-place ($ ($ scope-root 'spatial-thing-store) 'all-locations) lat lon snap-km)))
    (and s (spatial-thing-id s))))

;; The place a position STANDS IN — what a person's own place is contained in,
;; so the law of that place reaches them by the tree's climb. The deepest place
;; whose outline holds the point (knowledge/jurisdiction-at.scm); a known place
;; within snap distance, when it stands under that outline or no outline holds
;; the point, is nearer still and is taken instead. #f when nothing places it:
;; the position then stands under no place, and no place's law.
(define (standing-in lat lon all-locs)
  (let* ((outline (jurisdiction-at lat lon))
         (near    (nearest-place all-locs lat lon snap-km))
         (near-id (and near (spatial-thing-id near))))
    (cond ((and near-id (or (not outline) (member outline (place-chain near-id)))) near-id)
          (else outline))))

;; No place of this scope is near: the fix becomes a place of its own, at a
;; ~1 km grid (two decimals — the coarsening), named for the nearest place ANY
;; scope knows when one is near enough to name it ("Steglitz-Zehlendorf"),
;; else by its grid point. ONE id per person (place:AID:here), re-placed as
;; they move, so the store keeps where they are and no trail.
(define (own-position-place! scope-root aid lat lon all-locs)
  (let* ((grid  (lambda (x) (/ (round (* x 100.0)) 100.0)))
         (la (grid lat)) (lo (grid lon))
         (near (nearest-place all-locs lat lon label-km))
         (name (if near
                   (or (spatial-thing-name near) (spatial-thing-id near))
                   (string-append (number->string la) ", " (number->string lo))))
         (id   (person-place-id aid "here")))
    ($ ($ scope-root 'spatial-thing-store) 'add-location
       (make-spatial-thing #:id id #:name name #:lat la #:long lo
                           #:contained-in (standing-in lat lon all-locs)))
    id))

(define (location-mode scope-root agent-id)
  "The mode AGENT-ID declared for sharing where they are — live, here or off — at
   this scope, or #f where none is declared."
  (let ((row ($ ($ scope-root 'plan-store) 'get-meta (location-share-key agent-id))))
    (and (pair? row) (assq-ref row 'mode))))

(define (sharing-refused? scope-root agent-id period place)
  "A fix for now is refused while AGENT-ID has declared they share nothing."
  (and place (eqv? period 0) (eq? (location-mode scope-root agent-id) 'off)))

(define (do-set-position scope-root agent-id period place)
  "place = a known location id (where AGENT is at PERIOD); #f clears it. A fix
   for now (period 0) is a lease and carries the instant it was sent."
  (let ((ps ($ scope-root 'plan-store)))
    (catch-as-failure
      (lambda ()
        (when (sharing-refused? scope-root agent-id period place)
          (error "location sharing is off: declare live or here to send a fix"))
        ($ ps 'set-meta (position-key agent-id period)
           (if place `((place . ,place) (agent . ,agent-id) (period . ,period) (at . ,(clock-now))) '()))
        (success (or place 'cleared))))))

;; Derive the planning HORIZON from the demand so multi-period actually runs
;; live: if the demand asks for anything beyond period 0, lay out that many daily
;; periods starting today (so the periods exist + carry real dates). An explicit
;; (horizon . (start . n)) opt always wins; single-period demand ⇒ #f (unchanged).
(define (demand-horizon demand o)
  (or (assq-ref o 'horizon)
      ;; same wire seam as demand->keyed: JSON arrays cross as vectors
      (let* ((->l (lambda (x) (if (vector? x) (vector->list x) x)))
             (maxp (fold (lambda (d a) (max a (list-ref (->l d) 2))) 0 (->l demand))))
        (and (> maxp 0) (cons (iso-date-from-epoch (now)) (+ maxp 1))))))

;; The FEDERATED plan's horizon: one dated day. Its members' labour arrives
;; off the standing pool as availability windows, and a window's hours are a
;; clock fact — 09:00–10:30 is ninety minutes of one day. A span-less period
;; has no day to meet that against, and the engine's fallback there sums the
;; window over every weekday a period might hold: measured, a 1.5 h window
;; entered the federated solve as 10.5 h and a shrunk roster bound nothing
;; (tests/doors/test-labour-fold-federation.scm). So the day is laid the
;; way plan-commune-scope lays it for an empty scope — today — and it is ONE
;; day because a member's record carries one boundary column per traded
;; good (commune->scope-record: the link key is the good), which is a day's
;; trade. An explicit (horizon . (start . n)) opt wins outright.
(define (federated-horizon o)
  (or (assq-ref o 'horizon)
      (cons (iso-date-from-epoch (now)) 1)))

;; wire-form demand (spec place period qty) → the engine's keyed form (spec#place@period . qty).
;; JSON arrays cross as VECTORS (guile-json), so a browser what-if arrives as
;; #(#(spec place t qty) …) — normalized here, at the one wire seam.
(define (demand->keyed demand)
  (define (->l x) (if (vector? x) (vector->list x) x))
  (map (lambda (d)
         (let ((d (->l d)))
           (cons (string-append (list-ref d 0) "#" (list-ref d 1) "@" (number->string (list-ref d 2)))
                 (list-ref d 3))))
       (->l demand)))

(define (agent-position-predicate scope-root)
  "Where each agent IS, per period, as one consistent TRAJECTORY — priority:
     1. live/manual override   (pos| meta; GPS 'now' or a declared future place)
     2. committed work location (their accepted work IS where they'll be)
     3. home                    (#f ⇒ the planner falls back to primary-location)
   (2) makes 'expected position' fall out of the plan itself: accepting work at a
   place puts you there for further planning, closing the plan↔position loop.
   Manual overrides win over the derivation; home is the floor. Returns #f when
   nothing pins anyone (⇒ everyone at home)."
  (let* ((ps        ($ scope-root 'plan-store))
         (overrides (make-hash-table))    ; (agent . period) → place   [live / manual]
         (committed (make-hash-table))    ; agent → place              [derived expected]
         (any #f))
    ;; 1. explicit overrides (live = period 0; manual expected = any period)
    (for-each
      (lambda (kv)
        (and (position-key? (car kv))
             (let ((place (assq-ref (cdr kv) 'place))
                   (period (assq-ref (cdr kv) 'period)))
               ;; a fix for now is a lease: it counts while it is fresh
               (when (and place (or (not (eqv? period 0)) (fix-fresh? (assq-ref (cdr kv) 'at) (clock-now))))
                 (set! any #t)
                 (hash-set! overrides (cons (assq-ref (cdr kv) 'agent)
                                            (assq-ref (cdr kv) 'period)) place)))))
      ($ ps 'all-meta))
    ;; 2. committed work locations → the derived expected trajectory. The
    ;; commitment's hasBeginning (WHEN, from the schema) maps to its period via
    ;; time->period; a worker is at their committed place IN that period.
    (for-each
      (lambda (c)
        (let ((prov (commitment-provider c)) (loc (commitment-at-location c)))
          (when (and prov loc (eq? (commitment-action c) 'work))
            (set! any #t)
            (hash-set! committed (cons prov (time->period (commitment-has-beginning c))) loc))))
      ($ ps 'all-commitments))
    (and any
         (lambda (agent period)
           (or (hash-ref overrides (cons agent period) #f)          ; override wins
               (hash-ref committed (cons agent period) #f))))))      ; else derived expected, per period

(define (do-decline-assignment scope-root iid acting-as)
  "Decline a suggested assignment. Two-step:
     1. Clear the existing suggested-provider metadata.
     2. Re-run match-work-flows for this intent's spec, with ACTING-AS
        in #:already-assigned, so the matcher proposes a different
        in-scope agent. If found, stamp the new suggestion. Otherwise
        the intent stays unmatched and surfaces in 'Needs a volunteer'.
   Returns (ok . new-provider) if a fresh match was found,
   (ok . cleared) otherwise."
  (catch-as-failure
    (lambda ()
      (let* ((ps    ($ scope-root 'plan-store))
             (obs   ($ scope-root 'observer))
             (as    ($ scope-root 'agent-store))
             (it    ($ ps 'get-intent iid)))
        (cond
          ((not it) (failure "intent not found"))
          (else
           ;; Step 1: clear existing suggestion
           ($ ps 'set-meta iid '())
           ;; Step 2: synthesize a single-element work-flow list and
           ;; re-run the matcher with the declining agent excluded.
           ;; match-work-flows only reads recipe-flow-id and
           ;; recipe-flow-resource-conforms-to from each flow.
           (let* ((spec    (intent-resource-conforms-to it))
                  (synthetic-flow
                    (make-recipe-flow #:id iid #:action 'work #:resource-conforms-to spec))
                  (scope-id (let ((scopes (row-scopes it)))   ; inScopeOf, a list (or one id on an older row)
                              (and (pair? scopes) (car scopes))))
                  (result (match-work-flows
                            (list synthetic-flow) obs as
                            #:scope-id scope-id
                            #:already-assigned (if acting-as
                                                   (list acting-as)
                                                   '())))
                  (new-provider (and (pair? result)
                                     (cdr (car result)))))
             (cond
               (new-provider
                ($ ps 'set-meta iid `((suggested-provider . ,new-provider)))
                (success new-provider))
               (else
                (success 'cleared))))))))))

;; The hours a member records are the ledger's "number up": a finite positive
;; quantity of time (counted in hours), stated by the commitment's own provider, for no more
;; than the commitment still holds. The door states these because it is where
;; the member's word becomes a work event.
(define (finite-positive? x) (and (real? x) (finite? x) (> x 0)))
(define (effort-remaining obs cmt)
  "Hours CMT still holds: its committed effort less what the observer has
   counted as fulfilling it; +inf.0 when the commitment states no effort."
  (let ((fs  ($ obs 'get-fulfillment (commitment-id cmt)))
        (eff (commitment-effort-quantity cmt)))
    (cond (fs  (max 0 (fulfillment-remaining fs)))
          (eff (measure-has-numerical-value eff))
          (else +inf.0))))
(define (do-record-effort scope-root cid provider qty unit)
  "Build a 'work <economic-event> and feed it to the observer.
   The commitment named in 'fulfills' reads this event as fulfilment."
  (let* ((ps  ($ scope-root 'plan-store))
         (obs ($ scope-root 'observer))
         (cmt ($ ps 'get-commitment cid))
         ;; what the member states, counted in hours
         (hours (and (finite-positive? qty) (time-unit? unit) (hours-in qty unit))))
    (cond
      ((not cmt) (failure "commitment not found"))
      ((not (finite-positive? qty)) (failure "hours are a finite positive number"))
      ((not (time-unit? unit)) (failure "effort is recorded in a unit of time"))
      ((and (commitment-provider cmt) (not (equal? (commitment-provider cmt) provider)))
       (failure "hours are recorded by the commitment's own provider"))
      ((commitment-finished cmt) (failure "the commitment is finished"))
      ((target-passed? hours (effort-remaining obs cmt))
       (failure (format #f "the commitment holds ~a hours; ~a recorded"
                        (effort-remaining obs cmt) hours)))
      (else
       (catch-as-failure
         (lambda ()
           (let* ((eid (generate-id "evt-"))
                  (evt (make-work-event
                         #:id eid
                         #:provider provider
                         #:effort-qty hours
                         #:effort-unit %effort-unit
                         #:fulfills cid
                         #:input-of (commitment-input-of cmt)
                         #:resource-spec (commitment-resource-conforms-to cmt)
                         ;; the commitment's own terms ride on the event: the fold
                         ;; of hours by part reads events alone (live.scm make-work-event)
                         #:at-location (commitment-at-location cmt)
                         #:has-beginning (commitment-has-beginning cmt)
                         #:has-end (commitment-has-end cmt)
                         #:in-scope-of (commitment-in-scope-of cmt))))
             ($ obs 'record-event evt)
             ;; the commitment ends fulfilled when its hours are all in, so a
             ;; finished block neither takes more hours nor reads as expired
             (let ((fs ($ obs 'get-fulfillment cid)))
               (when (and fs (fulfillment-state-finished fs))
                 (end-fulfilled! scope-root cid)))
             (success eid))))))))

;;; ── The captain's log observes (write path) ──────────────────────────
;;;
;;; A spoken log entry names things that HAPPENED — hours worked, a meal
;;; cooked, stock found or lost — and this turns one such narration into an
;;; EconomicEvent on the scope's observer. The door is deliberately narrow:
;;; the event is SELF-scoped (provider = receiver = the speaker), so nothing
;;; recorded here moves rights or custody between agents, and the action set
;;; is the observational half of the VF table. Only produce/raise mint a
;;; resource (auto-created as the speaker's own, in the event's unit); a
;;; consume/use/lower with no resource named records the fact alone — the
;;; ledger keeps the observation, indexed by agent/action/spec, and stock
;;; reconciliation stays with the paths that know which stock (drop-event,
;;; claim, record-effort).



;;; ── Leaving a thing somewhere, and taking it away (write path) ───────
;;;
;;; The two acts a shared container affords, and they are the VF pair the
;;; ActionDefinition table already names — so this records an EconomicEvent and
;;; lets the observer do the rest. `dropoff` increments what is on hand at the
;;; container's place and hands custody to the container; `pickup` decrements it
;;; and hands custody back to the taker. Both leave `primary-accountable`
;;; untouched, which is the whole difference between leaving a thing somewhere
;;; and giving it away: the person who left it still owns it and may come back.
;;;
;;; No new state, and no policy: the swap etiquette a shared box lives by ("leave
;;; one to take one") is the map face's, not the ledger's. What is enforced here
;;; is only what the ledger can know — you cannot take what is not there, and you
;;; cannot leave a thing in something that is not a container.

(define (%container-resource? root r)
  "True iff R's spec keeps what is in it in place — the flag that makes a
   container a container (and makes `recipe-hold` tile through time)."
  (let* ((spec-id (and r (economic-resource-conforms-to r)))
         (s (and spec-id ($ ($ root 'recipe-store) 'get-resource-spec spec-id))))
    (and s (resource-spec-keep-in-place? s) #t)))

(define* (do-drop-event root action container-id agent spec qty
                        #:key (unit %count-unit) (resource-id #f) (note #f)
                              (name #f) (accountable #f) (scope #f))
  "Record ACTION ('dropoff | 'pickup) of QTY of SPEC at CONTAINER-ID by AGENT.
   RESOURCE-ID names the thing moved. On a pickup it must already exist; on a
   dropoff, naming something the scope already holds MOVES that thing — its
   rights, its rail, its history all untouched — and naming nothing introduces
   one.

   ACCOUNTABLE is who holds the rights to a thing being INTRODUCED, and it is a
   declaration. Left out, the thing enters the books as the COMMONS' — the scope
   whose container it is — on the communal rail.

   That default is a position, not a technicality. A public drop point is a
   common thing; what somebody puts in it, claiming nothing, joins the commons
   rather than becoming the property of whoever last touched it. The alternative
   defaults are both worse: owned by the leaver mints private property out of
   the act of putting something down, and owned by nobody leaves a thing in the
   books that no rule can speak about. The claim is always available — say who
   holds the rights and they hold them — so this takes nothing that was not
   given.

   Returns the resource id touched."
  (let* ((obs   ($ root 'observer))
         (cont  ($ obs 'get-resource container-id))
         (place (and cont (economic-resource-current-location cont))))
    (cond
     ((not cont) (failure "no such container"))
     ((not (%container-resource? root cont)) (failure "not a container"))
     ((not (relocating-action? action)) (failure "not a leave or a take"))
     ((not (and (number? qty) (> qty 0))) (failure "quantity must be positive"))
     (else
      (catch-as-failure
       (lambda ()
         (let* ((eid (generate-id "evt-"))
                (rid (or resource-id (string-append container-id "/" eid)))
                (have (let ((r ($ obs 'get-resource rid)))
                        (and r (measure-qty (economic-resource-onhand-quantity r)))))
                (taking? (eq? action 'pickup)))
           (cond
            ((and taking? (not have)) (failure "nothing of that here"))
            ((and taking? (< have qty)) (failure "not that much here"))
            (else
             ;; Leaving something the books have never seen introduces it: an
             ;; empty identity — a name, a kind, a place — and the rights over
             ;; it, DECLARED or common by default. The event below is what puts
             ;; the quantity in it and hands the box custody. (The observer would
             ;; auto-create it too, but as the RECEIVER's — and the receiver of a
             ;; dropoff is the box, which would make every box the owner of
             ;; everything left in it.)
             (unless have
               ($ obs 'record-resource
                  (make-economic-resource
                   #:id rid #:name (or name note spec) #:tracking-identifier (fresh-label obs) #:conforms-to spec #:classified-as '()
                   #:accounting-quantity (make-measure 0.0 unit) #:onhand-quantity (make-measure 0.0 unit)
                   #:current-location place
                   #:primary-accountable (or accountable scope)             ; claimed, else the commons'
                   ;; unclaimed ⇒ it is on the commons rail, which is what being
                   ;; the commons' property means for everything downstream
                   #:distribution-mode (and (not accountable) 'communal))))
             ;; the CUSTODY act: quantity in or out, and who holds it after.
             ;;
             ;; Custody passes to the SCOPE, not to the box. `custodian-scope`
             ;; is a Scope id (schemas.scm) and a box is an EconomicResource;
             ;; putting the box there would say a thing is held by a thing, and
             ;; would make a commune's own loaf in a commune's own box read as
             ;; held under somebody else's rights (`resource-rented?`) — the
             ;; federation counting a shelf as a dependency. Which BOX it is in
             ;; is the containment event below, which is what `contained-in` is
             ;; for. So: the commons holds what is in its boxes, and taking
             ;; something out is what moves custody to you.
             ($ obs 'record-event
                (make-economic-event
                 #:id eid #:action action
                 #:resource-inventoried-as rid                              ; 5-6 the thing moved
                 #:resource-conforms-to spec                             ; 7-8 conforms-to, classified-as
                 #:provider (if taking? scope agent)            ; 9  provider
                 #:receiver (if taking? agent scope)            ; 10 receiver
                 #:resource-quantity (make-measure (exact->inexact qty) unit) #:has-point-in-time (iso-now) #:created (iso-now)           ; 13-16
                 #:at-location place #:to-location (and (not taking?) place)     ; 17-18 at-location, to-location
                   ; 19-24
                 #:note (or note "") #:in-scope-of (list scope)           ; 25-26 note, in-scope-of (a list, as VF has it)
))                          ; 27-29
             ;; …and the CONTAINMENT act: it is now inside the box, or out of it.
             ;; A take that leaves some behind does NOT empty the box — what is
             ;; left is still in there — so the separate waits for the last of it.
             ;;
             ;; Two events because they are two facts, and they come apart: a
             ;; socialized stash has the commune's custody while it sits in the
             ;; same box under the same bridge. Custody says who may hold it;
             ;; `contained-in` says what it is physically inside. `combine` and
             ;; `separate` are the schema's own pair for the second — the same
             ;; pair transport.scm uses to put a rider inside a car for the trip.
             ;;
             ;; Their quantity is ZERO on purpose: combining normally consumes an
             ;; input into a composite (onhand decrement) and separating yields
             ;; one back. Nothing is consumed or yielded by putting a loaf in a
             ;; box, so the only effect asked for here is the containment one.
             (when (or (not taking?) (<= (- have qty) 0))
              ($ obs 'record-event
                (make-economic-event
                 #:id (string-append eid (if taking? "-out" "-in"))
                 #:action (if taking? 'separate 'combine)
                 #:resource-inventoried-as rid #:to-resource-inventoried-as (and (not taking?) container-id)  ; 5-6 the thing, the box
                 #:resource-conforms-to spec
                 #:provider (if taking? scope agent)
                 #:receiver (if taking? agent scope)
                 #:resource-quantity (make-measure 0.0 unit)            ; 11-12 containment only
 #:has-point-in-time (iso-now) #:created (iso-now)
                 #:at-location place #:to-location place
                 #:note "" #:in-scope-of scope)))
             (success rid))))))))))

;;; ── ^planner-service actor ───────────────────────────────────────────
;;;
;;; Lives inside planner-vat. The scopes hashmap maps a string scope-id
;;; to the corresponding ^scope-root reference (also in planner-vat).
;;; All store calls use synchronous `$` near-call semantics.
;;;
;;; The actor has no state, so `bcom` is unused. The scopes hashmap is
;;; closed over at spawn time. Future create-scope methods would bcom
;;; to a new instance with an extended hashmap.

;; The default plan-fn: the plain planner, adapted to the (root scope-id . kw)
;; convention every plan method calls through. scope-id is ignored — it matters only
;; to the socialized plug (governance's socialized-plan-fn) that keys grants by it.
;; The scope's chemistry and law are installed by plan-scope->alist itself — the
;; one door every solve path crosses (live.scm) — so there is nothing to add here.
(define (plain-plan-fn root _scope-id . kw)
  (apply plan-scope->plan root kw))

;; Raise a skill resource for AGENT-ID — the declare-skill door's own
;; first-declaration/re-declaration logic (VF's raise, concepts/actions.md),
;; factored out so a new agent's bootstrap defaults (set-profile's first-time
;; branch, below) share the identical lifecycle rather than a second copy of
;; it: a default skill IS a declared skill, raised once here the same way the
;; RPC door raises one on request.
(define (revoke-skill! obs agent-id skill-spec-id)
  "Lower every skill resource AGENT-ID holds for SKILL-SPEC-ID to zero — the
   declared `skill:AID:spec` and the `skill-AID-labor` an offer of time seeds
   alike (the resources stay, carrying both events); → the declared id."
  (let ((now (iso-now)))
    (for-each
     (lambda (r)
       (when (equal? (economic-resource-conforms-to r) skill-spec-id)
         (let ((rid (economic-resource-id r))
               (qty (measure-has-numerical-value (economic-resource-onhand-quantity r))))
           ($ obs 'record-event
              (adjustment-event (generate-id (string-append "revoke:" rid ":" now ":")) rid skill-spec-id
                                (count-difference qty 0) %count-unit
                                #:provider agent-id #:receiver agent-id
                                #:when now #:created now #:counted 0
                                #:note "skill revoked")))))
     ($ obs 'skills-of agent-id)))
  (skill-id agent-id skill-spec-id))
;; Lower a held resource R of AGENT-ID to zero: the one record of "no longer
;; held here", whether the means was retired or the person moved on.
(define (lower-resource! obs agent-id r note)
  (let ((q (measure-has-numerical-value (economic-resource-onhand-quantity r)))
        (now (iso-now)))
    (when (> q 0)
      ($ obs 'record-event
         (make-economic-event
          #:id (generate-id (string-append "retire:" (economic-resource-id r) ":" now ":")) #:action 'lower #:resource-inventoried-as (economic-resource-id r) #:resource-conforms-to (economic-resource-conforms-to r)
          #:provider agent-id #:receiver agent-id
          #:resource-quantity (make-measure q (measure-has-unit (economic-resource-onhand-quantity r))) #:has-point-in-time now #:created now
          #:note note)))))
(define (declare-skill! root agent-id skill-spec-id)
  "AGENT-ID holds the skill SKILL-SPEC-ID at ROOT: the resource raised to held,
   and the spec declared as worked where the store has none of that id — what
   makes the resource read as a skill (formulas/actions labour-specs)."
  (let* ((obs ($ root 'observer))
         (rs  ($ root 'recipe-store))
         (rid (skill-id agent-id skill-spec-id))
         (r   ($ obs 'get-resource rid))
         (qty (and r (measure-has-numerical-value
                      (economic-resource-onhand-quantity r)))))
    (unless ($ rs 'get-resource-spec skill-spec-id)
      ($ rs 'add-resource-spec (skill-spec skill-spec-id)))
    (cond
      ;; first declaration: the resource enters with its balance
      ((not r)
       ($ obs 'record-resource
          (make-economic-resource
           #:id rid #:name (string-append agent-id " " skill-spec-id)
           #:conforms-to skill-spec-id
           #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit) #:primary-accountable agent-id)))
      ;; re-declaration after a revoke: raise it back to held
      ((<= qty 0)
       (let ((now (iso-now)))
         ($ obs 'record-event
            (adjustment-event (generate-id (string-append "declare:" rid ":" now ":")) rid skill-spec-id
                              (count-difference qty 1) %count-unit
                              #:provider agent-id #:receiver agent-id
                              #:when now #:created now #:counted 1
                              #:note "skill re-declared")))))
      ;; already held: nothing to record
    rid))

;; The service's doors, with the person-subject ones routed to the person's home.
;; (home-routed OBJECT ROUTE clause …) is `declared-methods` whose every call
;; first passes its arguments through ROUTE, (method args) → args: the one
;; site that decides which scope a person's fact is written at, so no door
;; has to, and none can forget to. Every reply leaves `finished` (wire/rows.scm):
;; a door whose reply has a table answers the page's rows, at this one site.
(define-syntax home-routed
  (syntax-rules ()
    ((_ object route clause ...)
     (let ((dispatch (declared-methods object clause ...)))
       (lambda (msg . args) (finished msg (apply dispatch msg (route msg args))))))))

(define-actor (^planner-service bcom scopes-hm #:optional (plan-fn plain-plan-fn) (earth #f) (readers '()))
  ;; a person's own scope-footprint, warmed by the write paths themselves —
  ;; never scanned to build. A reader with a warm answer here costs O(the
  ;; scopes this one person touched); a cold miss costs today's full roster
  ;; scan, same as always, and feeds this back so the next ask is warm.
  ;; *person-home-index* mirrors the `home:AID` row exactly (single-valued);
  ;; *person-touched-index* is grow-only — every scope where this AID has ever
  ;; had a work event recorded. Correctness never depends on either being
  ;; warm, only speed does; a stale or empty table just falls back.
  ;; PER-INSTANCE, not module-level like *slot-criteria*/*met-memo* above —
  ;; a person's own footprint in ONE federation must never leak into another
  ;; ^planner-service spawned in the same process (tests spawn several; a
  ;; shared table reused the same AID across two unrelated rosters and a
  ;; stale "home" from the first answered route-home in the second before
  ;; its own first write ever landed — caught by tests/doors/
  ;; test-one-citizen.scm's relationship-carrying section, which spawns a
  ;; fresh world per scenario and reuses "bob").
  (define *person-home-index* (make-hash-table))
  (define *person-touched-index* (make-hash-table))
  (define (note-touched! aid sid)
    (when (and (string? aid) (string? sid))
      (hash-set! *person-touched-index* aid
                 (lset-adjoin string=? (hash-ref *person-touched-index* aid '()) sid))))
  (define (touched-scopes aid) (hash-ref *person-touched-index* aid #f))
  ;; GOVERNANCE IS INJECTED AS READERS OF A SCOPE, NEVER IMPORTED: READERS is
  ;; one alist of (name . procedure), each optional, each the one idiom —
  ;; governance derives a fact off its stores and hands the planner a reader
  ;; of it (governance depends on the planner, never the reverse).
  ;;   world    (root sid . kw) → ((view …) (caps …) (span …) (slots …) (rented …) (care …))
  ;;            THE ONE CUSTODY VIEW: the resources a solve here may see after
  ;;            the custody projection, the socialized Svc| pools, the governed
  ;;            spans; the plain, federated and consensus solves all read it
  ;;   demand   (root sid . kw) → the tree's declared needs with the caller's
  ;;            riding on them, the horizon, the fold's terms
  ;;   stamp    (root sid world alist) → the alist with what only the projection knows
  ;;   pool     (root sid) → the socialized slot rows, live (slots-at)
  ;;   hands    (sid) → ((owner part-string portion) …), the plan-part rail's read
  ;;   standing (root sid) → what stands over the scope's recipes, an alist a
  ;;            solve reads as settings (standing-settings): `responses` and
  ;;            `observed` (governance/recipe-standing scope-standing writes
  ;;            these two); `admit?` (recipe → bool, a consensus barring a
  ;;            recipe here) and `proc-frag` are keys a reader MAY carry and
  ;;            the production reader does not — a test reader does
  ;;            (test-means-gateway), which is what keeps the two reads
  ;;   steward  (sid agent spec skills) → may this agent be assigned to work on a lent means
  ;;   knows    (owner agent) → how the owner knows them: recognition, groups, vouched (make-knows)
  ;;   debts owed settle — governance's one debt representation (economy/debts.scm)
  ;; PLAN-FN is the plain solve, (root sid . kw) → alist; every solve at a
  ;; scope goes through live.scm solve-with-readers with these readers.
  ;; Absent readers, the raw observer, the caller's demand, no stamp.
  (define (reader name) (assq-ref readers name))
  (define debts-of (reader 'debts)) (define owed-of (reader 'owed)) (define settle-of (reader 'settle))
  (define standing-of (reader 'standing)) (define may-steward-of (reader 'steward))
  (define lent-of (reader 'lent))           ; sid → what the commune is lent (economy/socialization.scm `lent-to`)
  (define knows-of (reader 'knows))
  (define pool-of (reader 'pool)) (define hands-of (reader 'hands)) (define world-of (reader 'world))
  (define contrary-of (reader 'observed))   ; sid → the rail's standing contrary readings, for the reading fold (not audit.scm's `observed-of`, which reads a person's events)

  ;; the scope's standing, read ONCE per request: a door's body runs inside
  ;; `with-scope`, which opens a memo for its dynamic extent, so the gate, the
  ;; settings and the snapshot of one request share one read of the record. A
  ;; read outside any door (a later callback, a caller with no scope wrapper)
  ;; finds no memo and reads afresh; nothing is kept from one request to the
  ;; next, so a read is as fresh as the request that asked.
  (define standing-memo (make-parameter #f))
  (define (standing root sid)
    (let* ((memo (standing-memo))
           (held (and memo (hash-get-handle memo sid))))
      (if held
          (cdr held)
          (let ((st (or (and standing-of (standing-of root sid)) '())))
            (when memo (hash-set! memo sid st))
            st))))
  (define (gather rs root sid)             ; THE door: recipes, gated by standing, holes yielding once mapped
    (gather-recipes rs #:admit? (compose-admit (assq-ref (standing root sid) 'admit?) (hole-admit rs))))
  ;; the scope's STANDING onto a plan-fn call — each recipe's response (the
  ;; curve of its own runs, read by every future at that future's stress),
  ;; the contrary observations against its map (the world as its workers
  ;; have seen it, laid over every future), and the last solve's x, each a
  ;; per-scope fact a caller's own keyword wins over.
  ;; Warm-starting rides here so EVERY solve the service runs re-centres from
  ;; where the scope stood (engine/robust.scm ignores an x whose shape no longer fits).
  ;; the world a solve at SID sees (WORLD-OF, else the raw observer): the
  ;; view, the socialized caps and the spans, with the UC allocation
  ;; (means-caps-of) merged under the caps — one reading for every solve
  (define (world-of* root sid . kw)
    (let ((w (if world-of
                 (apply world-of root sid kw)
                 `((view . ,($ ($ root 'observer) 'all-resources)) (caps . ()) (span . ())))))
      (cons (cons 'caps (append (means-caps-of root) (assq-ref w 'caps)))
            (alist-delete 'caps w))))
  ;; THE SETTINGS OF A SOLVE, AS ONE ALIST MERGED BY KEY. What the scope
  ;; stands on (its standing, its warm start, the governed dials, the voice
  ;; field's inputs, the UC allocation as caps) is one alist; the caller's
  ;; keywords are laid over it by key, so a caller's word wins by
  ;; construction and no key is looked for twice. Caps merge rather than
  ;; replace: the allocation stands under the caller's, and a caller's cap
  ;; on the same located good replaces the standing one (two pools would
  ;; add at ingest). Converted to keywords once, at the end.
  (define (merge-settings standing over)
    (let ((caps (let ((o (or (assq-ref over 'eco-caps) '())))
                  (append (filter (lambda (c) (not (assoc (car c) o))) (or (assq-ref standing 'eco-caps) '())) o))))
      (cons (cons 'eco-caps caps)
            (append (filter (lambda (kv) (not (eq? (car kv) 'eco-caps))) over)
                    (filter (lambda (kv) (and (not (eq? (car kv) 'eco-caps)) (not (assq (car kv) over)))) standing)))))
  (define (standing-settings root sid)
    (let ((st (standing root sid)))
      (append
       (filter cdr `((admit? . ,(assq-ref st 'admit?))
                     (proc-frag . ,(let ((r (assq-ref st 'proc-frag))) (and (pair? r) r)))
                     (responses . ,(let ((r (assq-ref st 'responses))) (and (pair? r) r)))
                     ;; what has been seen of the map: the reading fold's `contrary` read
                     ;; (the rail's standing observations at their cautious reading, folded
                     ;; with every other reading), the standing's own rows where no node stands
                     (observed . ,(let* ((n (node-of sid nodes-reading))
                                         (r (or (and n (false-if-exception ($ n 'contrary))) (assq-ref st 'observed))))
                                    (and (pair? r) r)))
                     (warm-x . ,(warm-x-of sid))
                     ;; the previous plan's rows: what it lands is where stock on the way counts
                     (arriving . ,(let ((r (planned-material sid))) (and (pair? r) r)))))
       `((eco-caps . ,(means-caps-of root)))
       (kw->alist (policy-kw root sid)))))
  (define (standing-kw root sid kw)
    (alist->kw (merge-settings (standing-settings root sid) (kw->alist kw))))
  ;; the voice field's inputs, a fact about the scope like the rest: τ from the
  ;; scope's governance policy (0 by default — the plan as if no stance stood),
  ;; the scope's standing pushes and hours reader off its voice node, and the
  ;; path of scopes the solve stands in (leaf first) for a part naming a scope.
  ;; the governed dials, every row read fresh from the one registry
  ;; (voice/quorum.scm): τ and the rest go to the engine as keywords;
  ;; with τ > 0 the scope's voice fold hands the field its pushes and hours
  ;; the scope roots a person's credit is read over: the roster's, walked live.
  ;; Credit is earned anywhere and spent anywhere (account.scm `claim`), and a
  ;; citizenship share is the person's once however many scopes hold an
  ;; account of theirs (the credit fold's combine), so the claim guard, the
  ;; claim's reply and the shop header all take this one reading.
  ;; NOT narrowed to the claimant's own touched scopes, unlike the readers
  ;; below — effective-balance (elastic.scm) folds every given root's cells
  ;; into ONE combine, and its svc/citizenship-share baseline is a reading of
  ;; the WHOLE federation, not of this one person: narrowing it to "ada
  ;; r:worked here" (confirmed by running tests/doors/test-credit-spend.scm
  ;; — "Insufficient global effective balance" on a correct claim) silently
  ;; starves the balance of every scope she didn't personally touch, exactly
  ;; the same class of unsoundness as the abandoned consolidate-person! skip.
  ;; AID is still taken (and ignored) so every call site keeps naming the
  ;; claimant, for whichever later reading over credit really is personal.
  (define* (credit-roots #:optional aid) (map cdr (roster-entries)))
  ;; the observers of the scopes THIS person has touched — a cold miss
  ;; (AID untouched, or #f for "no one person") falls back to every scope
  (define (person-observers aid)
    (let ((sids (and aid (touched-scopes aid))))
      (filter-map (lambda (sid) (false-if-exception ($ (roster-ref sid) 'observer)))
                  (or sids (map car (roster-entries))))))
  ;; the observers of every scope on the roster: used where the read is not
  ;; about one person (policy-kw's #:practice-peers, a solve-wide reading) —
  ;; the same fallback person-observers takes on a cold/absent AID
  (define (practice-observers) (person-observers #f))
  ;; a person's standing — their skills, their record, their away days — is kept
  ;; at their home; a visitor holds none where they are, so a read that is
  ;; about the person resolves the home first (the given root when they have none)
  (define (home-root aid root) (or (and=> (home-scope-of aid) roster-ref) root))
  (define (home-agent-of aid)
    (let ((r (home-root aid #f)))
      (and r (false-if-exception ($ ($ r 'agent-store) 'get-agent aid)))))
  ;; what the roster's observers record of a person — the events they took part
  ;; in, wherever they happened, each once by its id (planner/observation/practice.scm)
  (define (person-events aid)
    (join-by-id economic-event-id
                (map (lambda (o) (or (false-if-exception ($ o 'events-for-agent aid)) '()))
                     (person-observers aid))))
  ;; who is there to ask at SID, for a witnessing: the scope's community — its
  ;; agents, the persons homed here (one who has only stated a want holds no
  ;; agent record) and the persons who took part in an event recorded here (a
  ;; visitor's record is at their home). A person is someone some scope knows:
  ;; homed, or holding a record; a scope's own id and a machine are not.
  (define (scope-community sid)
    (let* ((root (roster-ref sid))
           (known? (lambda (aid) (and (string? aid) (or (home-scope-of aid) (home-agent-of aid)) #t))))
      (if (not root) '()
          (delete-duplicates
           (append (map agent-id (or (false-if-exception ($ ($ root 'agent-store) 'all-agents)) '()))
                   (homed-at sid)
                   (filter known?
                           (append-map (lambda (ev) (list (economic-event-provider ev) (economic-event-receiver ev)))
                                       (or (false-if-exception ($ ($ root 'observer) 'all-events)) '()))))))))
  ;; SID and every scope above it, nearest first (a cycle ends the climb)
  (define (scope-ancestry sid)
    (let loop ((s sid) (acc '()))
      (if (or (not s) (member s acc)) (reverse acc)
          (loop (hash-ref %scope-parent s #f) (cons s acc)))))
  (define (policy-kw root sid)
    (let* ((dials (policy-dials ($ root 'plan-store)))   ; a root answers its plan-store; #f reads the defaults
           (tau (let ((t (memq #:voice-tau dials))) (if (and t (number? (cadr t))) (cadr t) 0.0)))
           (vn (node-of sid nodes-voice))
           (path (scope-ancestry sid)))
      (append dials
              (list #:practice-peers practice-observers #:agent-of home-agent-of)
              (if (and vn (> tau 0.0))
                  (list #:voice-pushes ($ vn 'pushes) #:voice-hours ($ vn 'hours-of) #:scope-path path)
                  (list #:scope-path path)))))
  ;; ── THE SOLVE, OFF THE VAT ──────────────────────────────────────────────
  ;; plan-fn* is the one door every solve crosses. With a vat in hand
  ;; (set-solve-vat!, the gateway's) it is a QUEUE: each call is a job — the
  ;; gather (this vat: `$` reads of the stores), the program (a thread of its
  ;; own: ingest + solve over the engine's tables, no `$`), the landing (this
  ;; vat again: persist, and read the tables the solve set) — and the vat pumps
  ;; ONE job at a time, so the engine's tables always belong to the job that
  ;; set them and a landing reads its own solve's. Between the gather and the
  ;; landing the vat is free: a seat's roster, every snapshot, every accept
  ;; lands while a seven-minute program runs. The answer is a PROMISE of the
  ;; plan alist; on-plan continues into it. Without a vat (every test, a
  ;; REPL) the same door runs inline and answers the alist itself.
  (define %solve-vat #f)
  (define %solve-queue '())            ; ((gather-thunk . resolver) …), FIFO
  (define %solve-busy? #f)
  (define %solve-inflight (make-hash-table))   ; scope-id → #t from queue to landing
  ;; run THUNK; a raise answers (err . e) with its backtrace on the log (the
  ;; queue and the worker thread both run outside catch-as-failure), a value
  ;; answers (ok . v)
  (define (%guarded thunk)
    (catch #t
      (lambda () (with-throw-handler #t (lambda () (cons 'ok (thunk)))
                   (lambda (key . args)
                     (format (current-error-port) "[solve-queue] ~a ~a~%" key args)
                     (display-backtrace (make-stack #t) (current-error-port)))))
      (lambda (key . args) (cons 'err (cons key args)))))
  (define (%solve-in thunk k)          ; live.scm's #:solve-in, inside a pumped job only
    (call-with-values spawn-promise-values
      (lambda (p r)
        (call-with-new-thread
          (lambda ()
            ;; a Guile thread inherits its parent's dynamic state — the vat
            ;; turn's own syscaller included, which would make every Goblins
            ;; call below (and call-with-vat's re-entry) believe it is still
            ;; inside that turn. The program runs with none: it is pure, and
            ;; the landing re-enters the vat through the front door.
            (let ((res (parameterize (((@@ (goblins core) current-syscaller) #f))
                         (%guarded thunk))))
              (parameterize (((@@ (goblins core) current-syscaller) #f))
                (call-with-vat %solve-vat
                  (lambda ()
                    (with-exception-handler
                      (lambda (e) ($ r 'break e))
                      (lambda ()
                        (if (eq? (car res) 'ok)
                            ($ r 'fulfill (k (cdr res)))
                            ($ r 'break (cdr res))))
                      #:unwind? #t)))))))
        p)))
  (define (%pump-solves!)
    (unless (or %solve-busy? (null? %solve-queue))
      (let* ((job (car %solve-queue)) (r (cdr job)))
        (set! %solve-queue (cdr %solve-queue))
        (set! %solve-busy? #t)
        (let ((done (lambda () (set! %solve-busy? #f) (%pump-solves!))))
          (let ((v (%guarded (car job))))
            (cond ((eq? (car v) 'err) (done) ($ r 'break (cdr v)))
                  ((promise-refr? (cdr v))
                   (on (cdr v)
                       (lambda (al) (done) ($ r 'fulfill al))
                       #:catch (lambda (e) (done) ($ r 'break e))))
                  (else (done) ($ r 'fulfill (cdr v)))))))))
  (define (plan-fn* root sid . kw)
    (if (not %solve-vat)
        (apply solve-with-readers plan-fn readers root sid (standing-kw root sid kw))
        (call-with-values spawn-promise-values
          (lambda (p r)
            (set! %solve-queue
              (append %solve-queue
                (list (cons (lambda ()
                              (apply solve-with-readers plan-fn readers root sid
                                     (standing-kw root sid (cons* #:solve-in %solve-in kw))))
                            r))))
            (%pump-solves!)
            p))))
  ;; continue into a solve's answer — a promise from the queue, or the alist
  ;; itself inline — with K; a failure reaches CATCH (else it raises, inline,
  ;; or breaks the returned promise). The value is what K answers, or a
  ;; promise of it.
  (define* (on-plan v k #:key (catch #f))
    (if (promise-refr? v)
        (if catch (on v k #:catch catch #:promise? #t) (on v k #:promise? #t))
        (if catch
            (with-exception-handler (lambda (e) (catch e)) (lambda () (k v)) #:unwind? #t)
            (k v))))
  ;; the steward gate at a door: may AGENT be assigned to PROC in scope SID —
  ;; every `use` spec the process engages must admit them
  (define (steward-ok? root sid agent proc)
    (or (not may-steward-of) (not agent) (not proc)
        (let ((specs (proc-use-specs root proc)))
          (or (null? specs)
              (let ((skills (or (false-if-exception
                                 (agent-skills ($ (home-root agent root) 'observer) agent))
                                '())))
                (every (lambda (spec) (may-steward-of sid agent spec skills))
                       specs))))))
  (define (steward-admit root sid)          ; (agent proc → bool) for the offer and accept doors
    (and may-steward-of (lambda (agent proc) (steward-ok? root sid agent proc))))
  ;; the steward rule as a slot's criteria: for a declared means its owner lent
  ;; under a rule, read off the cached solve's steward-rules — the grant is the
  ;; rule's durable home, the in-memory sidecar its editing surface
  (define (steward-criteria sid r)
    (let* ((cached (last-solve-ref sid))
           (rules (and cached (assq-ref (cdr cached) 'steward-rules)))
           (row (and (pair? rules)
                     (find (lambda (x)
                             (and (equal? (assq-ref x 'spec) (economic-resource-conforms-to r))
                                  (equal? (assq-ref x 'owner) (economic-resource-primary-accountable r))))
                           rules))))
      (and row (assq-ref row 'criteria))))
  ;; a means slot's criteria on the wire: the sidecar when one stands, else
  ;; the steward rule its owner lent it under
  (define (means-criteria sid root r)
    (or (slot-criteria root (economic-resource-id r)) (steward-criteria sid r)))
  ;; event chats ride beside the scopes: append-only files under the same
  ;; data dir the gateway runs in; strata resolved from the plan at post time
  (define chat-reg
    ;; #:default keeps a bare `guile -L module` run writing to ./data — no
    ;; root, no /var/lib. A deployment exports PLAYNET_DATA_DIR and lands
    ;; in the same directory as every other component.
    (spawn ^chat-registry (playnet-data-dir #:default "data") '()))

  ;; The commune roster — ONE source of truth. In prod the gateway wires EARTH (the
  ;; planetary economic root, module/playnet/scope/earth.scm), so the planner reads
  ;; the same registry that makes communes durable — no shadow copy, no dual-write. When
  ;; earth is #f (unit tests), the local scopes-hm is the roster, exactly as before. Both
  ;; map scope-aid → ^scope-root; every method below goes through these three.
  (define (roster-ref id)       (if earth ($ earth 'commune id) (hashmap-ref scopes-hm id #f)))
  (define (roster-entries)      (if earth ($ earth 'all-communes)   ; ((aid . root) …)
                                    (hashmap-fold (lambda (k v a) (cons (cons k v) a)) '() scopes-hm)))
;; ONE HOME PER PERSON. A person is a citizen of the federation and a gateway
  ;; is a scope they connect through; their facts (needs, means, availability,
  ;; profile, position, skills) are written at ONE scope however they connect,
  ;; so every quantity fold above counts them once (docs/planning/
  ;; federation-identity-and-folds.md). The home is a plan-store row, `home:AID`,
  ;; at the scope where the person first wrote a fact; it is read back by
  ;; asking the roster, and the smallest scope id wins if a row ever stands at
  ;; two (the same deterministic pick the aggregating parent makes). A scope's
  ;; plan-store is persisted, so the home survives a restart with the rest.
  ;; a warm answer (*person-home-index*, kept current by adopt-home! alone —
  ;; never by set-home-row!'s tombstone leg, which would silently overwrite it
  ;; back to the scope a move just left) costs one hash lookup; a cold miss
  ;; costs today's full roster scan, same as always, and warms the index for
  ;; next time with the same smallest-scope-id tie-break
  (define (home-scope-of aid)
    (or (hash-ref *person-home-index* aid #f)
        (let* ((held (filter-map (lambda (e)
                                    (and (assq-ref (or (false-if-exception ($ ($ (cdr e) 'plan-store) 'get-meta (home-row aid))) '())
                                                   'home)
                                         (car e)))
                                  (roster-entries)))
               (found (and (pair? held) (car (sort held string<?)))))
          (when found (hash-set! *person-home-index* aid found))
          found)))
  ;; the row is a statement, not a flag: a person who moved leaves `(home . #f)`
  ;; where they were, so the move is two writes that each stand alone
  ;; the persons whose home is SID: the `home:AID` rows standing there
  (define (homed-at sid)
    (let ((root (roster-ref sid)))
      (if (not root) '()
          (filter-map (lambda (kv) (and (home-row-aid (car kv)) (pair? (cdr kv)) (assq-ref (cdr kv) 'home)
                                        (home-row-aid (car kv))))
                      (or (false-if-exception ($ ($ root 'plan-store) 'all-meta)) '())))))
  (define (set-home-row! sid aid home?)
    (let ((root (roster-ref sid)))
      (when root ($ ($ root 'plan-store) 'set-meta (home-row aid) `((home . ,home?))))))
  (define (adopt-home! sid aid)
    (set-home-row! sid aid #t)
    (hash-set! *person-home-index* aid sid))
  ;; the doors whose second argument is a person and whose subject is that
  ;; person: the dialed scope is a lens on them, and a write lands at home
  (define person-writes person-write-doors)
  (define person-reads person-read-doors)
  (define (route-home msg args)
    (let ((k (person-argument-position msg)))      ; the scope is first; the person is where the table says
      (cond
        ((not (and (or (memq msg person-writes) (memq msg person-reads))
                   (>= (length args) k) (string? (list-ref args (- k 1)))))
         args)
        (else
         (let* ((who (list-ref args (- k 1)))
                (h (home-scope-of who)))
           (cond ((and h (equal? h (car args))) args)
                 (h ;; a write that lands at the home is news to whoever watches the scope it was dialed to
                    (when (memq msg person-writes) (slots-changed! (car args)))
                    (cons h (cdr args)))
                 ;; nowhere yet: a write makes the scope it came through the home;
                 ;; a read leaves the person where they asked
                 ((memq msg person-writes) (adopt-home! (car args) who) args)
                 (else args)))))))
  ;; MOVING. What a person has written, at the scope FROM, is carried to TO and
  ;; withdrawn from FROM: the needs (the intents `need:AID:*`, with their
  ;; criteria), the means (`means:AID:*`, lowered where they were and raised
  ;; where they land), the held skills, and the agent record with its place in
  ;; the labour pool. Every step is idempotent and TO wins where it already
  ;; holds the same id, so a move interrupted is a move retried, and the same
  ;; sweep over every other scope is what gathers a person who was declared in
  ;; several before there was a home (`consolidate-person!`).
  ;; The means AID holds at scope SID that the scope is lent: a grant names the
  ;; commune that holds it and only that commune's resource view projects the
  ;; thing, so carrying one away strands the grant and the owner's signature is
  ;; what would re-issue it. A move keeps these where they are and says so.
  (define (lent-means-of aid sid)
    (let ((grants (if lent-of (or (false-if-exception (lent-of sid)) '()) '()))
          (root (roster-ref sid)))
      (if (or (null? grants) (not root))
          '()
          (filter-map
           (lambda (r)
             (and (string-prefix? (means-prefix aid) (economic-resource-id r))
                  (any (lambda (g)
                         (and (equal? (assq-ref g 'owner) aid)
                              (let ((rid (assq-ref g 'resource-id)))
                                (if rid
                                    (equal? rid (economic-resource-id r))
                                    (equal? (assq-ref g 'spec) (economic-resource-conforms-to r))))))
                       grants)
                  (economic-resource-id r)))
           ($ ($ root 'observer) 'inventory)))))
  (define (migrate-person! aid from to)
    (let ((fr (roster-ref from)) (tr (roster-ref to)))
      (if (not (and fr tr (not (equal? from to)))) 0
          (let* ((fps ($ fr 'plan-store)) (tps ($ tr 'plan-store))
                 (fobs ($ fr 'observer)) (tobs ($ tr 'observer))
                 (fas ($ fr 'agent-store)) (tas ($ tr 'agent-store))
                 (fsts ($ fr 'spatial-thing-store)) (tsts ($ tr 'spatial-thing-store))
                 (iso (iso-now)))
            ;; the needs, with their criteria
            (define (carry-needs)
              (let ((needs (filter (lambda (i) (string-prefix? (need-prefix aid) (intent-id i)))
                                   ($ fps 'all-intents))))
                (for-each (lambda (i)
                            (unless ($ tps 'get-intent (intent-id i)) ($ tps 'add-intent i))
                            (move-slot-criteria! fr tr (intent-id i))
                            ($ fps 'remove-intent (intent-id i)))
                          needs)
                (length needs)))
            ;; the means, lowered where they were and raised where they land
            (define (carry-means)
              (let ((means (filter (lambda (r) (and (string-prefix? (means-prefix aid) (economic-resource-id r))
                                                    (> (or (and=> (economic-resource-onhand-quantity r)
                                                                  measure-has-numerical-value) 0) 0)
                                                    (not (member (economic-resource-id r) (lent-means-of aid from)))))
                                   ($ fobs 'inventory))))
                (for-each (lambda (r)
                            (unless ($ tobs 'get-resource (economic-resource-id r)) ($ tobs 'record-resource r))
                            (lower-resource! fobs aid r "means moved")
                            (move-slot-criteria! fr tr (economic-resource-id r)))
                          means)
                (length means)))
            ;; the held skills, whatever id they carry
            (define (carry-skills)
              (let ((skills (skill-specs-for-agent fobs aid (scope-labour? fr))))
                (for-each (lambda (sp) (declare-skill! tr aid sp) (revoke-skill! fobs aid sp)) skills)
                (length skills)))
            ;; the places the person named: copied, since a commune keeps the
            ;; geography its citizens gave it; their own `here` and `home` are
            ;; theirs, and leave with them
            (define (carry-places)
              (let ((mine (filter (lambda (l) (string-prefix? (person-place-prefix aid) (spatial-thing-id l)))
                                  ($ fsts 'all-locations)))
                    (own? (lambda (l) (member (spatial-thing-id l)
                                              (list (person-place-id aid "here") (person-place-id aid "home"))))))
                (+ (fold (lambda (l n)
                           (if ($ tsts 'get-location (spatial-thing-id l)) n
                               (begin ($ tsts 'add-location l) (+ n 1))))
                         0 mine)
                   (begin (for-each (lambda (l) ($ fsts 'remove-location (spatial-thing-id l)))
                                    (filter own? mine))
                          0))))
            ;; the dwelling the person lives in
            (define (carry-dwelling)
              (let ((r ($ fobs 'get-resource (dwelling-id aid))))
                (if (and r (> (measure-has-numerical-value (economic-resource-onhand-quantity r)) 0))
                    (begin (unless ($ tobs 'get-resource (dwelling-id aid)) ($ tobs 'record-resource r))
                           (lower-resource! fobs aid r "dwelling moved")
                           1)
                    0)))
            ;; where the person is, now and expected
            (define (carry-positions)
              (let ((rows (filter (lambda (kv) (and (or (string-prefix? (position-prefix aid) (car kv))
                                                        (equal? (car kv) (location-share-key aid)))
                                                    (pair? (cdr kv))))
                                  ($ fps 'all-meta))))
                (for-each (lambda (kv)
                            (unless (pair? (or ($ tps 'get-meta (car kv)) '()))
                              ($ tps 'set-meta (car kv) (cdr kv)))
                            ($ fps 'set-meta (car kv) '()))
                          rows)
                (length rows)))
            ;; the relationships the person is a party to, whichever side: a
            ;; relationship is a fact between two people and follows whichever
            ;; of them moves. Carried BEFORE the agent record, whose removal
            ;; cascades them away at FROM; TO keeps a relationship it holds.
            (define (carry-relationships)
              (let ((rels (join-by-id agent-relationship-id
                                      (list ($ fas 'relationships-as-subject aid)
                                            ($ fas 'relationships-as-object aid)))))
                (fold (lambda (rel n)
                        (if ($ tas 'get-relationship (agent-relationship-id rel))
                            n
                            (begin ($ tas 'add-relationship rel) (+ n 1))))
                      0 rels)))
            ;; the agent record, with its place in the labour pool
            (define (carry-agent)
              (let ((agent ($ fas 'get-agent aid)))
                (if (not agent) 0
                    (begin
                      (unless ($ tas 'get-agent aid) ($ tas 'add-agent agent))
                      ($ tas 'update-agent aid (lambda (a) a))      ; the new scope's labour pool refolds
                      ($ fas 'remove-agent aid)                  ; the labour pool follows the removal
                      1))))
            (let ((n (+ (carry-needs) (carry-means) (carry-skills) (carry-places)
                        (carry-dwelling) (carry-positions) (carry-relationships) (carry-agent))))
              (means-changed! from) (means-changed! to)
              n)))))
  ;; everything of AID's held at a scope other than TARGET, carried to TARGET
  (define (consolidate-person! aid target)
    (fold (lambda (e n)
            (if (equal? (car e) target) n (+ n (migrate-person! aid (car e) target))))
          0 (roster-entries)))
  ;; A scope's GEOGRAPHIC path for the dial breadcrumb: the containment chain of its
  ;; deepest place (the farm), from just below the biosphere down to that place's PARENT
  ;; (region/city), excluding the biosphere root and the farm leaf itself — e.g. Berlin →
  ;; ((germany . "Germany") (berlin . "Berlin/Brandenburg")). '() when unplaced.
  (define (scope-geo-path root)
    (let ((locs (or (false-if-exception ($ ($ root 'spatial-thing-store) 'all-locations)) '())))
      (if (null? locs) '()
          (let* ((by-id (make-hash-table)))
            (for-each (lambda (l) (hash-set! by-id (spatial-thing-id l) l)) locs)
            ;; the climb is the shared one (vf/aggregation/containment.scm); what is
            ;; written here is only which part of the chain a breadcrumb wants —
            ;; the middle, from the deepest place up to but not including the
            ;; biosphere root.
            (let* ((resolve (lambda (id) (hash-ref by-id id #f)))
                   (chain-of (lambda (l) (containment-chain l #:parent-of spatial-thing-contained-in
                                                              #:resolve resolve)))
                   (depth   (lambda (l) (length (chain-of l))))
                   (deepest (fold (lambda (l best) (if (or (not best) (> (depth l) (depth best))) l best)) #f locs))
                   (as-seg  (lambda (x)
                              (list (cons 'id (spatial-thing-id x))
                                    (cons 'name (or (spatial-thing-name x) (spatial-thing-id x))))))
                   (ancestors (reverse
                               (map as-seg
                                    (take-while (lambda (x) (not (equal? (spatial-thing-id x) "biosphere")))
                                                (if deepest (chain-of deepest) '()))))))
              ;; a commune with no real geography above it — no ancestor at
              ;; all, or only biosphere itself — still gets a flat,
              ;; one-segment path naming its own place, the same "founding
              ;; commune with no geography" fallback scope.js's scopePathOf
              ;; already assumes for the breadcrumb; this is its twin for
              ;; the picker's own tree (crumb.js buildPickTree drops any
              ;; scope whose path is empty).
              (if (pair? ancestors) ancestors (list (as-seg deepest))))))))
  ;; Hang scope ID's every node under its standing parent (%standing-parent:
  ;; the declared edge where that parent aggregates here, else the UC — the
  ;; credential graph may name parents the planner doesn't aggregate, and a
  ;; projection degrades to the root rather than refusing the edge). Each
  ;; fold node is dropped at its old parent and its total delivered to the
  ;; new one (fold-node-reparent!); each descent node the same on the way
  ;; down (unfold-node-reparent!) — no rebuild, nothing to replay. The
  ;; routing tables need no touch: both splits climb %scope-parent, so
  ;; updating it IS the re-keying. Answers the parent it stands under.
  (define (rehang-scope! id)
    (let ((new-parent (%standing-parent id))
          (old (hash-ref %scope-parent id #f))
          (mine (nodes-of id)))
      (unless (or (equal? old new-parent) (not mine))   ; unwired: the edge waits for the roots
        (for-each (lambda (kind)
                    (fold-node-reparent! (kind mine) id #:from (%node-at kind old) #:to (%node-at kind new-parent)))
                  %fold-kinds)
        (for-each (lambda (kind)
                    (unfold-node-reparent! (kind mine) id #:from (%node-at kind old) #:to (%node-at kind new-parent)))
                  %descent-kinds))
      (hash-set! %scope-parent id new-parent)
      new-parent))
  ;; a parent registered after its children: every scope declared under ID
  ;; and standing elsewhere is re-hung beneath it now
  (define (rehang-children! id)
    (hash-for-each (lambda (child p)
                     (when (and (equal? p id) (not (equal? (hash-ref %scope-parent child #f) id)))
                       (rehang-scope! child)))
                   %declared-parent))

  (define (roster-add! id root) (if earth ($ earth 'add-commune! id root)
                                    (set! scopes-hm (hashmap-set scopes-hm id root)))
    (wire-scope-folds! id root))
  ;; the symmetric op: drop a throwaway/demo scope from the roster (earth's
  ;; forget-commune!, or the local scopes-hm's back-compat mirror). Does not
  ;; unwire its fold nodes — nothing in the codebase ever needs that for a
  ;; scope that dies, and a scope with real participants leaves through
  ;; governance's remove-commune (federation membership revocation) instead.
  (define (roster-forget! id) (if earth ($ earth 'forget-commune! id)
                                  (let ((root (hashmap-ref scopes-hm id #f)))
                                    (set! scopes-hm (hashmap-remove scopes-hm id))
                                    root)))
  ;; everything a registered scope stands up BESIDE its roster entry: the
  ;; fold nodes (wire-scope-labour!) and the fresh check for never-held
  ;; accepts (commitment-horizon.md) — installed here because the checker
  ;; needs both the scope root (for the trial solve) and the last solve's
  ;; demand (last-solve-ref), neither of which scope-root's own rewire can
  ;; reach. A root without a plan-store skips that wire.
  (define (wire-scope-folds! id root)
    (wire-scope-labour! id root)
    ;; warms *person-touched-index*: every event this scope ever records
    ;; names the one or two people in it, so a later credit/practice read for
    ;; them costs this scope's lookup, not the whole roster's
    (false-if-exception
     ($ ($ root 'observer) 'add-event-listener
        (lambda (event affected)
          (note-touched! (economic-event-provider event) id)
          (note-touched! (economic-event-receiver event) id))))
    (rehang-children! id)
    (let ((ps (false-if-exception ($ root 'plan-store))))
      (when ps
        (false-if-exception
         ($ ps 'set-fresh-check
            (make-fresh-check root
              #:solve (lambda kw (apply plan-fn* root id kw))   ; the readers' door, as every solve here
              #:solve-opts-thunk
              (lambda ()
                (let ((cached (last-solve-ref id)))
                  (if cached (list #:demand (car cached)) '()))))))))
    ;; ONE REPORTER over the silent-fact class — a fact standing in one layer
    ;; that another layer doesn't read stops being silent at the wiring door
    ;; (the ten nodes themselves stand by construction: wire-scope-labour!
    ;; makes the whole record or raises):
    ;; the seed-lint: a recipe's work flow whose skill NOBODY holds is
    ;; skill-absent to every solve (the empty-schedule class) — named here,
    ;; once, instead of an empty day saying it silently. A citizen's later
    ;; declare-skill fills it; this only says the seed left it empty.
    (catch #t
      (lambda ()
        (let* ((rs  ($ root 'recipe-store))
               (obs ($ root 'observer))
               (held (skill-holders obs (scope-labour? root)))
               (want (call-with-values (lambda () (gather-recipes rs))
                       (lambda (procs flows)
                         (delete-duplicates
                          (filter-map (lambda (f)
                                        (and (eq? (recipe-flow-action f) 'work)
                                             (recipe-flow-resource-conforms-to f)))
                                      flows))))))
          (for-each
           (lambda (spec)
             (when (null? (hash-ref held spec '()))
               (format (current-error-port)
                       "  [wire-scope ~a] GUARD: work skill ~s has no holder — its recipes are skill-absent until someone declares it~%"
                       id spec)))
           want)))
      (lambda _ #f)))
  ;; THE RESTART STORY, made lazy. The roster can outlive the folds: the
  ;; planner vat's rehydration brings earth's communes back while these
  ;; side tables (plain hashes) start every boot empty — so a restored
  ;; scope answered its roster lookups with every fold silently OFF
  ;; (standing-demand-node-of → #f ⇒ solves on empty demand: met 1.0,
  ;; nothing scheduled, whatever anyone declared). A scope reached through
  ;; the roster whose folds are not standing gets them stood up on the
  ;; spot; re-registration replaces pools and re-delivers totals, which is
  ;; roster-add!'s own idempotency contract. The slack node is the
  ;; sentinel: it wires unconditionally first, so one hash probe answers
  ;; "already wired" for the whole set.
  (define (ensure-scope-wired! id root)
    (unless (nodes-of id)
      (wire-scope-folds! id root)))

  ;; ── the labour fold, live: one ^labour-pool per scope, parented to the UC
  ;; root, so availability and skills climb as a standing keyed roster
  ;; (labour-fold.scm has the flow). Registration happens here because
  ;; add-scope! is the one door every scope-creation site crosses — spawn,
  ;; wire (after the root exists, so after rewire-callbacks), then seed via
  ;; the rebuild write. Re-registering an id replaces the pool and re-delivers
  ;; its total under the same key at the parent — idempotent, which is the
  ;; whole restart story (nothing here persists). Plain hash tables mutated in
  ;; place, like scopes-hm, so registration never resets actor state.
  (define %uc-labour-pool (spawn ^labour-pool (make-labour-pool) '() "uc"))
  (define %nodes (make-hash-table))              ; scope-id → <scope-nodes>, the whole record or nothing
  (define (nodes-of id) (hash-ref %nodes id #f))
  (define (node-of id kind) (and=> (nodes-of id) kind))
  (define (labour-pool-of id) (node-of id nodes-labour))
  ;; the descent beside the fold: matched commitments walk DOWN the same tree,
  ;; routed by the plan they serve (%deployment-table: plan-id → scope-id,
  ;; written where the rising proposals are read). Each scope's leaf node
  ;; lands its slice in that scope's plan-store — the roster narrows to
  ;; exactly the commitments a scope holds (descent.scm).
  (define %deployment-table (make-hash-table))
  ;; one proposal from each scope, then one more from each — the order the
  ;; union matching's greedy assignment walks, so no scope's whole slate
  ;; drains the pool before another scope's first proposal is heard
  (define (round-robin lists)
    (let ((live (filter pair? lists)))
      (if (null? live) '()
          (append (map car live) (round-robin (map cdr live))))))
  ;; the one routing rule both descents share: hand the key to whichever of
  ;; MY children covers the scope it names — the scope itself when it is a
  ;; direct child, else the ancestor (%scope-parent climb) that stands for
  ;; its subtree here. #f (nobody) keeps it in the own-part.
  (define (scope-climb-route sid child-ids)
    (let climb ((s sid))
      (and s (if (member s child-ids) s
                 (climb (hash-ref %scope-parent s #f))))))
  (define (deployment-child-of key child-ids)
    (scope-climb-route (hash-ref %deployment-table key #f) child-ids))
  (define %uc-deployment (spawn-deployment-node deployment-child-of #:id "uc"))
  ;; the means-allocation descent: allocate-means-consensus's result walks the
  ;; same tree, rows (scope-id spec cap-pair) routed by their own scope-id —
  ;; the section law and the each-scope-gets-only-its-slice attenuation come
  ;; with the node, and the landing stays correct when roots go remote.
  (define allocation-split (route-by-key car scope-climb-route))
  (define %uc-allocation
    (spawn-unfold-node allocation-split #:id "uc"
                       #:reads `((allocation . ,(lambda (own) own)))))
  ;; the federated-solve descent: each commune's post-ADMM plan walks the
  ;; same tree as rows (scope-id demand solve-alist) routed by scope-id —
  ;; the third unfold instance; each scope's leaf lands ITS row where the
  ;; overlay reads it (cache-solve!), never another scope's
  (define %uc-solve
    (spawn-unfold-node allocation-split #:id "uc"
                       #:reads `((solves . ,(lambda (own) own)))))
  ;; the demand and means folds, through the same door. Demand refolds
  ;; eagerly — the plan-store's intent listener is additive, so wiring costs
  ;; nothing anyone else owns. Means refolds from its WRITERS: the service's
  ;; own means doors (declare-means, retire-means) fire means-changed! for
  ;; the one scope they touched, so the standing total is exact at read
  ;; time and a read costs nothing. The observer's single on-event slot
  ;; belongs to the gateway's ACDC emission, so inbound custody events
  ;; reach the fold through the explicit repair verb (means-rebuild!) —
  ;; resources change rarely (means-fold.scm's own note), and a repair is
  ;; a walk, never something a read pays for.
  ;; where each scope stands in the aggregation tree: scope-id → parent
  ;; scope-id, #f meaning directly under the UC roots. The membership
  ;; projection names the edge (%declared-parent, written by move-scope!);
  ;; the tree stands under it wherever the parent is registered, and a scope
  ;; is wired under its declared parent at birth (wire-scope-labour!) or
  ;; re-hung beneath it the moment the parent registers (roster-add!), so the
  ;; tree is the projection in every order the edge and the roots arrive.
  (define %scope-parent      (make-hash-table))
  (define %declared-parent   (make-hash-table))
  (define (%standing-parent id)          ; the declared parent, when it is wired here
    (let ((p (hash-ref %declared-parent id #f)))
      (and p (nodes-of p) p)))
  (define (%node-at kind pid) (if pid (node-of pid kind) (kind %uc)))
  (define %uc-means-pool  (spawn ^means-pool '() '() "uc"))
  (define %uc-demand-node (spawn ^demand-node '() '() "uc"))
  ;; the one published handle: what the process-wide readers ask the live service
  (set! %standing-service
        (lambda (what . args)
          (case what
            ((demand-node) (node-of (car args) nodes-demand))
            ((credit-uc) %uc-credit-pool)
            ((solve-store) (and=> (roster-ref (car args)) (lambda (root) ($ root 'plan-store))))
            ((observer)    (and=> (roster-ref (car args)) (lambda (root) ($ root 'observer))))
            ((roster) (roster-entries))
            (else (error "standing-service: no such read" what)))))
  ;; the folksonomy fold — the fifth aggregate through the same door. The
  ;; lobby contributes each AID's cut to the UC root (the commons' one
  ;; aggregate today); the per-scope nodes stand ready for scope-cut reads
  ;; and are carried by move-scope! like every other fold.
  (define %uc-folksonomy (spawn ^folksonomy (make-folksonomy) '() "uc"))
  ;; the credit fold — universal credit as a standing keyed total: every
  ;; global-* read account.scm computes by polling a flat scope-root list is
  ;; a read of this root, refolded by each scope's own writers (observer and
  ;; account-store additive listeners), carried by move-scope! like the rest.
  (define %uc-credit-pool (spawn ^credit-pool '() '() "uc"))
  ;; the voice fold — producer stances over parts, weighed by validated hours
  ;; (pools/voice-fold.scm): one node per scope, anonymous cells upward.
  ;; THE RAIL IS THE ONLY STORE OF A HAND, AND THE PLANNER HOLDS NO COPY: the
  ;; fold reads HANDS-OF, the injected reader over the credential store (the
  ;; planner imports none), at every refold, each row through the hand's
  ;; constructor (parts.scm validate-hand). `hands!` is the refold the lobby
  ;; asks for when a cast lands. Absent a reader, the fold holds no hand. A
  ;; solve reads its scope's pushes and hours through standing-kw; τ = 0 (the
  ;; policy default) reads the plan as if no stance stood.
  (define %uc-voice-pool (spawn ^voice-pool '() '() "uc"))
  (define (rail-hands id)                ; ((owner part portion) …), the rail read now
    (if hands-of
        (append-map (lambda (r) (map (lambda (pp) (list (car r) (car pp) (cdr pp)))
                                     (validate-hand (list (cons (cadr r) (caddr r))))))
                    (hands-of id))
        '()))
  (define (refold-voice! id)
    ($ (node-of id nodes-voice) 'voice-changed (roster-ref id) (lambda (r) (rail-hands id)))
    (length (rail-hands id)))
  ;; the slack fold — desire per place as a standing total: every solve that
  ;; lands (cache-solve!) refolds its scope's cells, the ratio and the
  ;; geomean are reads at any node, and the overlay draws instead of folding
  (define %uc-slack (spawn ^slack-node '() '() "uc"))
  ;; the reading fold: every scope's readings rise keyed by scope, technique
  ;; and act; the UC reads what every source says of a spec, together
  (define %uc-reading-pool (spawn ^reading-pool '() '() "uc"))
  (define (refold-readings! id)
    ($ (node-of id nodes-reading) 'reading-changed (roster-ref id) id contrary-of))
  ;; the UC roots as one record: the parent of every scope declared under nothing
  (define %uc (make-scope-nodes %uc-labour-pool %uc-means-pool %uc-demand-node %uc-folksonomy
                                %uc-credit-pool %uc-slack %uc-voice-pool %uc-reading-pool
                                %uc-deployment %uc-allocation %uc-solve))
  ;; ── what a landed solve sets in motion, each effect named ────────────────
  ;; the slack fold hears the solve: this scope's node refolds its cells
  (define (refold-slack! sid)
    (let ((n (node-of sid nodes-slack)))
      (when n (<-np n 'slack-changed (scope-own-slack sid)))))
  ;; the presentation caller (commitment-horizon.md, the flow's step 2):
  ;; the solve's suggestions become directed offers, nearest-forcing-first,
  ;; carried to each person by the snapshot's proposed-to filter. Refusals
  ;; inside (max-open reached, a forcing point passed) are the policy
  ;; speaking; nothing here may fail the solve.
  ;; every after-solve effect runs guarded the same way: a failure is the
  ;; effect's own, named on stderr, never the solve's
  (define (solve-effect! sid name thunk)
    (catch #t thunk
      (lambda (k . a)
        (format (current-error-port) "  [~a ~a] ~a ~a~%" name sid k a))))
  ;; AN ACCEPT CHANGES THE PLAN — so the plan changes AT the accept: both
  ;; accept doors and the release re-solve the scope through the same
  ;; cached path every deliberate solve takes, and the after-solve effects
  ;; then re-lay the open shifts (the accepted cell not re-laid),
  ;; re-present, and refold. The next snapshot a member fetches is the
  ;; world as the decision left it — never a stale plan waiting for
  ;; someone to ask.
  ;; THE current-plan solve — no overrides, the demand fold's own world —
  ;; the one call solve-brief's no-what-if path and the accept's re-solve
  ;; share, cached so every after-solve effect fires
  (define (solve-current! root scope-id)
    (hash-set! %solve-inflight scope-id #t)
    (let ((landed (lambda () (hash-remove! %solve-inflight scope-id))))
      (on-plan (plan-fn* root scope-id
                 #:demand (demand->keyed '())
                 #:agent-position (agent-position-predicate root)
                 #:horizon (demand-horizon '() '())
                 #:backend 'native-c)
               (lambda (al) (landed) (cache-solve! scope-id '() al))
               #:catch (lambda (e)
                         (landed)
                         (format (current-error-port) "  [solve ~a] ~a~%" scope-id e)
                         #f))))
  ;; ── the TIME TICK's door: the plan keeps up with the clock ───────────────
  ;; Nothing else on the solve path runs on a timer, so a quiet scope would
  ;; serve yesterday's schedule until someone acts. One door does the whole
  ;; act, in its own order: first the RE-STAND hooks — a declaration owner
  ;; (a seed whose standing terms carry a rolling window) registers a thunk
  ;; through `re-stand!`, idempotent and cheap while its window is current —
  ;; then the walk, re-solving what has fallen behind: a cached solve older
  ;; than MAX-AGE seconds (or one restored from disk with no in-process
  ;; stamp), and every scope that has never solved at all — a scope on the
  ;; roster always holds a CURRENT plan, because "nothing to plan" is
  ;; itself an answer the wire must give (a signed-in dial otherwise keeps
  ;; showing its offline demo in the live plan's place, which is how the
  ;; gap was found). This also warms a fresh gateway's snapshots before
  ;; the first orb. Every piece runs guarded (solve-effect!): one hook's
  ;; or one scope's failure is its own. Returns how many scopes it
  ;; re-solved.
  (define %re-stand '())                  ; thunks that re-lay standing terms
  ;; ONE due scope per call — the vat-turn granularity that keeps the tick
  ;; from starving every other read. A sweep of heavy scopes in one turn
  ;; held the vat for minutes and the browser's scope-snapshot RPCs queued
  ;; behind it (found live: a signed-in dial showed no plan because its
  ;; fetch never got a turn). The GATEWAY's fiber paces the loop — calling
  ;; this until it answers #f — so between any two solves every queued
  ;; read lands. SEEN is the sweep's own memory (the sids already handled),
  ;; threaded by the caller across turns: a sweep visits each scope at most
  ;; once, which is what makes it a PASS rather than a chase (at max-age 0
  ;; a just-solved scope is immediately "due" again). The re-stand hooks
  ;; run once, at the sweep's head (SEEN empty).
  (define (resolve-one-stale! max-age seen)
    (when (null? seen)
      (for-each (lambda (h) (solve-effect! 'standing-terms 're-stand h)) %re-stand))
    (let ((due (find (lambda (entry)
                       (and (not (member (car entry) seen))
                            (not (hash-ref %solve-inflight (car entry) #f))   ; queued or running: its landing is coming
                            (let ((at     (solve-at-of (car entry)))
                                  (cached (last-solve-ref (car entry))))
                              (or (not cached)
                                  (not at) (>= (- (instant->unix (clock-now)) at) max-age)))))
                     (roster-entries))))
      (and due
           (begin (solve-effect! (car due) 'plan-tick
                    (lambda ()
                      ;; the same lazy door every service method crosses:
                      ;; a restored scope's folds stand up before its solve,
                      ;; or the tick caches a plan over an EMPTY demand fold
                      ;; (the restart story, found live a second way)
                      (ensure-scope-wired! (car due) (cdr due))
                      (solve-current! (cdr due) (car due))))
                  (car due)))))
  (define (resolve-stale-scopes! max-age)   ; the whole sweep in one call — tests, and any caller that WANTS one turn
    (let loop ((seen '()))
      (let ((sid (resolve-one-stale! max-age seen)))
        (if sid (loop (cons sid seen)) (length seen)))))
  (define (resolve-scope! scope-id root)
    ;; the cached plan is old from THIS instant — the wire says so until the
    ;; deferred solve below lands and cache-solve! clears the mark
    (mark-solve-stale! scope-id)
    ;; DEFERRED ONE TURN: the accept's bcom lands at the end of the
    ;; store's turn, and a same-turn read would re-solve the world as if
    ;; the accept had not happened (standing-accepts answered () right
    ;; after a successful promote — measured). The promise's resolution
    ;; runs after the turn, when the commitment is real to every reader.
    (on (<- ($ root 'plan-store) 'all-commitments)
        (lambda (_)
          (solve-effect! scope-id 'accept-resolve
            (lambda () (solve-current! root scope-id))))
        #:catch (lambda (e)
                  (format (current-error-port)
                          "  [accept-resolve ~a] deferred read failed: ~a~%" scope-id e))))
  (set! %on-solve-cached
        (lambda (sid)
          (refold-slack! sid)
          (let ((root (roster-ref sid))
                (cached (last-solve-ref sid)))
            (when (and root cached)
              (solve-effect! sid 'open-shifts
                (lambda () (persist-open-shifts! root cached)))
              (solve-effect! sid 'present-offers
                (lambda ()
                  (present-offers root (cdr cached)
                                  #:rank-fn (suggested-provider-rank
                                             ($ root 'plan-store))
                                  #:admit? (steward-admit root sid))))
              ;; A SOLVE MOVED THE SCOPE: its shifts, offers and schedule
              ;; are new. Every browser standing in it hears so on the
              ;; same rail a declaration rides, and refetches its day —
              ;; the plan reaches a reader the moment it lands, never at
              ;; the next reload (found live: a landed re-solve stayed
              ;; invisible until the page was opened again).
              (slots-changed! sid)))))
  ;; one scope's means changed under a door the service owns: refold that
  ;; node, and only it — the climb carries the new total up
  (define (means-changed! scope-id)
    (let ((node (node-of scope-id nodes-means))
          (root (roster-ref scope-id)))
      (when (and node root) ($ node 'capacity-changed root '())))
    (slots-changed! scope-id))
  ;; the pool's LIVE readers: a surface (the map) registers a ref per scope
  ;; through slots-watch and hears `(slots-changed scope-id)` from every
  ;; writer of the pool — the need and means doors here, and the gateway's
  ;; grant doors through the slots-changed! verb — so it refetches exactly
  ;; when the pool moved and never polls. A ref whose push fails is dropped:
  ;; a closed browser is a reader gone, not an error to keep.
  (define %slot-watchers (make-hash-table))     ; scope-id → (ref …)
  (define (slots-watch! scope-id ref)
    (let ((have (hash-ref %slot-watchers scope-id '())))
      (unless (memq ref have)
        (hash-set! %slot-watchers scope-id (cons ref have)))))
  (define (slots-unwatch! scope-id ref)
    (hash-set! %slot-watchers scope-id
               (delq ref (hash-ref %slot-watchers scope-id '()))))
  (define (slots-changed! scope-id)
    (for-each
     (lambda (ref)
       ;; a ref whose CapTP connection has died RAISES from the `<-` itself
       ;; (upstream: captp.scm new-question-finder hashq-set!s a #f table on a
       ;; closed connection — UPSTREAM-ISSUES.md #16), so the promise's
       ;; #:catch never sees it; both roads lead to the same unwatch
       (catch #t
         (lambda ()
           (on (<- ref 'slots-changed scope-id)
               (lambda (_) #f)
               #:catch (lambda _ (slots-unwatch! scope-id ref))))
         (lambda _ (slots-unwatch! scope-id ref))))
     (hash-ref %slot-watchers scope-id '())))
  ;; the repair: every node re-derives its own from its root — for events
  ;; that arrive outside the service's doors (inbound custody via the ACDC
  ;; bridge), or a boot whose increments were interrupted
  (define (means-rebuild!)
    (for-each (lambda (e) (means-changed! (car e))) (roster-entries)))
  ;; the read is a read: the standing total, summed over one spec's cells
  (define (means-fold-total spec)
    (fold (lambda (cell acc)
            (if (equal? (caar cell) spec) (+ acc (cdr cell)) acc))
          0 ($ %uc-means-pool 'cells)))
  ;; THE FOLDS AND DESCENTS AS DATA. One spec per kind, in the record's field
  ;; order: (kind . make), MAKE : parent-node → this scope's node, spawned and
  ;; wired under PARENT. Adding a kind is one entry here and one field on
  ;; <scope-nodes>; wiring, reparenting and every read walk the same list.
  (define (scope-node-specs id root)
    (let* ((obs ($ root 'observer))
           (as  ($ root 'agent-store))
           (ps  ($ root 'plan-store))
           ;; what labour is, read off the store at each ask: a skill declared after
           ;; the wiring (declare-skill! writes its spec) is labour the next refold
           (skills-fn (lambda (aid) (skill-specs-for-agent obs aid (scope-labour? root))))
           (descend (lambda (node parent) ($ parent 'add-child id node) node)))
      (list
       ;; the labour pool: agent-store on-agent → refold; skills off the observer
       (cons nodes-labour
             (lambda (parent)
               (let ((pool (spawn ^labour-pool (make-labour-pool) '() id)))
                 (wire-labour-pool! root pool #:skills-for-agent-fn skills-fn
                                    #:parent-pool-ref parent #:scope-id id)
                 ($ pool 'rebuild ($ as 'all-agents) skills-fn)
                 pool)))
       ;; the means fold: seeded now, refolded by its writers (means-changed!)
       (cons nodes-means
             (lambda (parent)
               (let ((mn (spawn ^means-pool '() '() id)))
                 (wire-means-node! root mn #:parent parent #:scope-id id) mn)))
       ;; the demand fold: every declared/retired need refolds through the
       ;; plan-store's intent listener; homes and voice resolve off the scope's own tree
       (cons nodes-demand
             (lambda (parent)
               (let ((dn (spawn ^demand-node '() '() id)))
                 (wire-demand-node! root dn #:home-of (federation-home-of root)
                                    ;; a citizen's voice is the federation's reading of them,
                                    ;; the same wherever their need sits in the tree
                                    #:voice-source %uc-credit-pool
                                    #:parent parent #:scope-id id) dn)))
       (cons nodes-folksonomy
             (lambda (parent)
               (let ((fn (spawn ^folksonomy (make-folksonomy) '() id)))
                 (wire-fold-parent! fn parent id) fn)))
       ;; the credit fold: refolds on every recorded event and account mutation
       (cons nodes-credit
             (lambda (parent)
               (let ((cn (spawn ^credit-pool '() '() id)))
                 (wire-credit-node! root cn #:parent parent #:scope-id id) cn)))
       ;; the slack fold: seeded from any cached solve, refolded as solves land
       (cons nodes-slack
             (lambda (parent)
               (let ((sl (spawn ^slack-node '() '() id)))
                 ($ sl 'slack-changed (scope-own-slack id))
                 (wire-fold-parent! sl parent id) sl)))
       ;; the voice fold: refolds on every recorded event, reading the rail's
       ;; standing hands each time — a restart and a fresh scope alike stand on
       ;; what the store holds; a cast refolds it by hand (hands!)
       (cons nodes-voice
             (lambda (parent)
               (let ((vn (spawn ^voice-pool '() '() id)))
                 (wire-voice-node! root vn #:parent parent #:scope-id id
                                   #:hands-of (lambda (r) (rail-hands id))) vn)))
       ;; the reading fold: refolds on every recorded event, reading the rail's
       ;; standing contrary observations each time; a cast refolds it by hand (observed!)
       (cons nodes-reading
             (lambda (parent)
               (let ((rn (spawn ^reading-pool '() '() id)))
                 (wire-reading-node! root rn #:parent parent #:scope-id id
                                     #:observed-of contrary-of) rn)))
       ;; the deployment descent: the leaf lands the OWN part in this scope's
       ;; plan-store — what the routing table says is this scope's (or
       ;; nobody's: unroutable waits here rather than vanishing); with
       ;; children, their slices pass through. A store-less root keeps the
       ;; routing and lands nothing.
       (cons nodes-deployment
             (lambda (parent)
               (descend (spawn-deployment-node deployment-child-of #:id id
                          #:on-update
                          (lambda (coms)
                            (when ps
                              (for-each
                               (lambda (c)
                                 (let ((dest (hash-ref %deployment-table (commitment-destination c) #f)))
                                   (when (or (not dest) (equal? dest id))
                                     ($ ps 'add-commitment c))))
                               coms))))
                        parent)))
       ;; the allocation descent: the UC's means allocation lands as this scope's standing caps
       (cons nodes-allocation
             (lambda (parent)
               (descend (spawn-unfold-node allocation-split #:id id
                          #:on-update
                          (lambda (rows)
                            (for-each (lambda (r)
                                        (let ((rt (roster-ref (car r))))
                                          (when rt (set-means-cap! rt (cadr r) (caddr r)))))
                                      rows)))
                        parent)))
       ;; the solve descent: each scope's federated row lands in its own cache
       (cons nodes-solve
             (lambda (parent)
               (descend (spawn-unfold-node allocation-split #:id id
                          #:on-update
                          (lambda (rows)
                            (for-each (lambda (r)
                                        (when (equal? (car r) id)      ; own part only
                                          (cache-solve! (car r) (cadr r) (caddr r))))
                                      rows)))
                        parent))))))
  (define (wire-scope-labour! id root)
    ;; every node hangs under the declared parent's node of its kind when
    ;; that parent is wired here, else under the UC root — the same place
    ;; move-scope! would carry it to. A root answers every store (a mock
    ;; answers #f for one it lacks); the ten nodes are made whole from the
    ;; specs, and the record is the fact that the scope is wired.
    (let ((parent (%standing-parent id)))
      (hash-set! %scope-parent id parent)
      (hash-set! %nodes id
                 (apply make-scope-nodes
                        (map (lambda (spec) ((cdr spec) (%node-at (car spec) parent)))
                             (scope-node-specs id root))))))

  ;; Helper: resolve a scope-id to its scope-root or return a failure
  ;; envelope. Used by every method below to dedupe the lookup pattern.
  (define (with-scope scope-id proc)
    (let ((root (roster-ref scope-id)))
      (if root
          (begin (ensure-scope-wired! scope-id root)
                 (parameterize ((standing-memo (or (standing-memo) (make-hash-table))))
                   (proc root)))
          (failure "scope not found"))))
;; The communes of one solve must PARTITION the economy (planner/facts/partition.scm):
  ;; a body or a resource in two programs, or a scope beside its own member, is
  ;; counted twice and the consensus converges to a different economy. What a
  ;; commune holds: the records of its stores, the bodies of its OWN labour
  ;; pool, and itself with every scope above it that is a commune of this call
  ;; (a parent that is no commune of the call is no program, and its members
  ;; are siblings, not overlapping).
  (define (communes-overlap sids)
    (held-twice
     (map (lambda (sid)
            (let ((root (roster-ref sid)) (p (labour-pool-of sid)))
              (cons sid
                    (append
                     (map (lambda (x) (cons 'scope x))
                          (filter (lambda (s) (member s sids)) (scope-ancestry sid)))
                     (if root (root-holdings root) '())
                     (if p
                         (map (lambda (e) (cons 'agent (entry-agent e)))
                              (pool-entries ($ p 'fold-own)))
                         '())))))
          sids)))
  ;; The goods a scope deals in, read off its records (planner/federation/crossing-set.scm):
  ;; what it holds, what its recipes make and consume, what its demand asks.
  ;; DEM is the scope's demand (good . qty) or #f.
  (define (scope-census sid dem)
    (let ((r (with-scope sid
               (lambda (root)
                 (call-with-values (lambda () (gather ($ root 'recipe-store) root sid))
                   (lambda (procs flows)
                     (commune-goods (or (assq-ref (world-of* root sid) 'view) '())
                                    flows
                                    (if (pair? dem)
                                        (list (spec-base (key-spec (car dem))))
                                        '()))))))))
      (if (and (pair? r) (eq? (car r) 'error)) '() r)))
  ;; a member's record for a solve across scopes: its projected view, its
  ;; standing caps and spans, its processes and flows, its labour off the
  ;; standing pool, and for each good that crosses one crossing column,
  ;; measured from the most the scope can give
  (define (scope-record-of sid goods dem hz)
    (with-scope sid
      (lambda (root)
        (let* ((as ($ root 'agent-store))
               (sts ($ root 'spatial-thing-store)) (rs ($ root 'recipe-store))
               ;; the one custody view: projected resources, standing caps, spans
               (world (world-of* root sid #:periods (iota (max 1 (cdr hz)))))
               (resources (assq-ref world 'view)))
          (call-with-values (lambda () (gather rs root sid))
            (lambda (procs flows)
              ;; labour arrives off the scope's STANDING pool — the fold the
              ;; roster maintains between solves — so skills and availability
              ;; enter the federated solve as the same keyed entries the UC reads.
              ;; The scope's OWN entries: the subtree total would count a
              ;; member scope's bodies in its parent's program as well as its own
              (commune->scope-record
                resources ($ as 'all-agents) ($ sts 'all-locations)
                procs flows
                #:id sid
                #:demand (if (pair? dem) (list dem) '())
                #:never-raw goods
                ;; the goods cross; which way is the solve's to say
                #:crossing goods
                #:eco-caps (assq-ref world 'caps) #:span-of (assq-ref world 'span)
                #:horizon hz
                #:labour-entries (and=> (labour-pool-of sid)
                                         (lambda (p) (pool-entries ($ p 'fold-own))))
                #:proc-frag (or (assq-ref (standing root sid) 'proc-frag) '()))))))))
  ;; a door over one scope that answers (ok . x) or (error . msg): the shape
  ;; every commitment-arc door has — the root handed to BODY, any raise a
  ;; failure, BODY's value the success
  (define (scoped scope-id body)
    (with-scope scope-id
      (lambda (root) (catch-as-failure (lambda () (success (body root)))))))

  ;; The federation forest: places of every OTHER registered scope that shares a
  ;; top-level spatial node with this one. A commune's tree tops out at its
  ;; federation root (a location with no contained-in); two communes seeded into
  ;; the same federation both carry that root id, so it is the natural join key —
  ;; no membership registry, no schema change. Returns the siblings' location
  ;; wires (build-snapshot unions + dedups them with the viewer's own). A scope
  ;; sharing no root with anyone gets '() and simply shows itself.
  (define (federation-sibling-locations scope-id root)
    (let* ((own      ($ ($ root 'spatial-thing-store) 'all-locations))
           (root-ids (filter-map (lambda (s)
                                   (and (not (spatial-thing-contained-in s))
                                        (spatial-thing-id s)))
                                 own)))
      (if (null? root-ids) '()
          (fold
            (lambda (entry acc)
              (let ((sid (car entry)) (sib (cdr entry)))
                (if (equal? sid scope-id) acc
                    (let ((sib-locs (or (false-if-exception ($ ($ sib 'spatial-thing-store) 'all-locations)) '())))
                      (if (any (lambda (s) (member (spatial-thing-id s) root-ids)) sib-locs)
                          (append (scope-locations->wire sib (location-slacks sid)) acc)
                          acc)))))
            '() (roster-entries)))))

  ;; First-Person gate — the gateway installs a PORTABLE personhood check
  ;; (holds a live PHC in any ecosystem) once the credential store exists.
  ;; Until then, allow, so the dial works before the store is wired.
  (define ph-ok? (lambda (_aid) #t))
  ;; WITH-SCOPE for a door only a person may use: PROC runs on the scope's root
  ;; when AID holds a personhood credential, else the door answers needs-personhood.
  (define (with-person scope-id aid proc)
    (with-scope scope-id
      (lambda (root)
        (if (ph-ok? aid) (proc root) (failure "needs-personhood")))))
  ;; the witness DOOR — governance's k-of-n work-witness ceremony, injected by
  ;; the gateway the way the personhood checker is (the planner never imports
  ;; governance; it forwards through what the composer installed):
  ;;   (open scope-aid event roster) → statement-said | #f
  ;;   (inbox aid)                   → context rows a browser may co-sign
  ;;   (standing scope-aid aid)      → per-skill witnessed-work evidence
  ;;   (outbox aid)                  → ceremonies collecting over aid's own work
  ;;   (attest said aid sig)         → 'attested | 'finalized | #f
  (define witness-door #f)
  ;; a read through the door: the key's answer, or nothing — when no door is
  ;; wired, the key is absent, or the read fails
  (define (door-read key . args)
    (or (and witness-door (assq-ref witness-door key)
             (false-if-exception (apply (assq-ref witness-door key) args)))
        '()))

  (home-routed planner route-home

    ((set-personhood-checker! p) (set! ph-ok? p) 'ok)
    ((set-witness-door! d) (set! witness-door d) 'ok)

    ;; ── the WITNESS ceremony: a work event asks its peers to co-sign ──────
    ;; OPEN spawns (or finds) the collecting ceremony over an already-recorded
    ;; event — the roster is the scope's own agents, the worker excluded by
    ;; the ceremony itself. INBOX lists what a citizen may co-sign. ATTEST
    ;; lands one signature; at quorum the single-signer provenance credential
    ;; STRENGTHENS in place to its witnessed, multisig form.
    ((witness-open scope-id aid event-id)
     (with-scope scope-id
       (lambda (root)
         (cond
           ((not witness-door) (failure "witnessing is not wired on this gateway"))
           ((not (ph-ok? aid)) (failure "needs-personhood"))
           (else
            (catch-as-failure
              (lambda ()
                (let ((ev ($ ($ root 'observer) 'get-event event-id)))
                  (if (not ev)
                      (failure "event not found")
                      (let* ((roster (scope-community scope-id))
                             (said ((assq-ref witness-door 'open) scope-id ev roster)))
                        (if said
                            (success `((said . ,said)))
                            (failure "nothing to witness — no attestable work, or no peers"))))))))))))

    ((witness-inbox scope-id aid)
     (if (not witness-door)
         (failure "witnessing is not wired on this gateway")
         (catch-as-failure
           (lambda ()
             (success `((requests . ,((assq-ref witness-door 'inbox) aid))))))))

    ((witness-attest scope-id aid said sig)
     (cond
       ((not witness-door) (failure "witnessing is not wired on this gateway"))
       ((not (ph-ok? aid)) (failure "needs-personhood"))
       (else
        (catch-as-failure
          (lambda ()
            (let ((r ((assq-ref witness-door 'attest) said aid sig)))
              (if r
                  (success `((status . ,(symbol->string r))))
                  (failure "no ceremony collecting under that statement"))))))))
    ;; the gateway registers the founding commune's economic root here,
    ;; keyed by its real scope-aid, after the UC block mints it. Mutates
    ;; scopes-hm in place (no bcom) so it doesn't reset ph-ok?.
    ((add-scope! id root) (roster-add! id root) 'ok)
    ;; a throwaway/demo scope's way out — see roster-forget!
    ((forget-scope! id) (roster-forget! id) 'ok)
    ;; the time tick (gateway fiber, or any caller): re-stand standing terms,
    ;; then re-solve what has fallen behind the clock — optional max-age in
    ;; seconds, default one hour
    ;; the vat the solve queue lands on — the gateway's own planner vat.
    ;; Handed in once at boot; from then on every solve door answers a
    ;; promise and the vat stays free while a program runs.
    ((set-solve-vat! vat) (set! %solve-vat vat) #t)
    ((resolve-stale! #:optional (max-age 3600))
     (resolve-stale-scopes! max-age))
    ;; the paced spelling: ONE due scope per turn — the scope id it solved,
    ;; or #f when the pass is complete. SEEN = the sids this sweep already
    ;; handled (a list; '() opens the sweep and runs the re-stand hooks).
    ;; The gateway fiber threads it so snapshots interleave between solves.
    ((resolve-one-stale! max-age seen) (resolve-one-stale! max-age (if (list? seen) seen '())))
    ;; a declaration owner's door onto the tick: THUNK re-lays its standing
    ;; terms (idempotent), and every resolve-stale! runs it before the walk
    ((re-stand! thunk) (set! %re-stand (cons thunk %re-stand)) 'ok)

    ;; ── refederation: one verb, two exact messages per aggregate ──
    ;; Move scope ID under NEW-PARENT (a scope-id, or #f for directly under
    ;; the UC). Each fold node is dropped at its old parent and its total
    ;; delivered to the new one (fold-node-reparent!); each descent node the
    ;; same on the way down (unfold-node-reparent!) — no rebuild, nothing to
    ;; replay. The routing tables need no touch: both splits climb
    ;; %scope-parent, so updating it IS the re-keying.
    ((move-scope! id new-parent)
     (catch-as-failure
       (lambda ()
         (hash-set! %declared-parent id new-parent)
         (let ((p (rehang-scope! id)))
           (success `((moved . ,id) (parent . ,(or p 'uc))))))))

    ;; ── the standing deployment reads — the descent's own answer ──
    ;; What the last matching round landed on a scope, without a plan-store
    ;; scan: the descent node's slice. Standing ACCEPTS stay the plan-store's
    ;; to answer (deployment-bindings reads them there): an accept arrives on
    ;; its own rail and outlives any one deployment, so the store is the
    ;; truth for bindings and the node for the round.
    ((deployment-of scope-id)
     (let ((n (node-of scope-id nodes-deployment)))
       (if n ($ n 'deployment) '())))
    ((deployed-hours-of scope-id)
     (let ((n (node-of scope-id nodes-deployment)))
       (if n ($ n 'deployed-hours) 0)))

    ;; ── the standing labour roster reads ──
    ;; labour-total answers over the UC root — every scope's availability ×
    ;; skills, one keyed pool; labour-pool hands back one scope's node for
    ;; finer reads (query/free/by-agent live on the node itself).
    ((labour-pool scope-id) (labour-pool-of scope-id))
    ((labour-total) ($ %uc-labour-pool 'pool))
    ;; SKILL/CELL+RADIUS/TIME-WINDOW fold into 'total-hours' own keyword-arg
    ;; query (pools/availability-pool.scm pool-query) — built back into that
    ;; shape here since fold-node's own dispatch takes it as a flat plist.
    ;; #:key, not #:optional — pool-total-hours (pools/availability-pool.scm
    ;; pool-query) takes these as real Guile keyword args, and so does every
    ;; existing caller of THIS door ($ svc 'labour-total-hours #:skill "x"),
    ;; a calling convention #:optional cannot match positionally.
    ((labour-total-hours #:key (skill #f) (cell #f) (radius #f) (time-window #f))
     (apply $ %uc-labour-pool 'total-hours
            (append (if skill (list #:skill skill) '())
                    (if cell (list #:cell cell) '())
                    (if radius (list #:radius radius) '())
                    (if time-window (list #:time-window time-window) '()))))
    ;; the standing demand and means reads — the other two folds' totals
    ;; the scope a person's facts are written at, whichever scope they connect
    ;; through (home-scope-of above), or #f for a person nowhere yet
    ((home-of aid) (home-scope-of aid))
    ;; a person's home moves: TO becomes the home, and everything of theirs held
    ;; anywhere else is carried there. Safe to ask again — the second asking
    ;; finds nothing left to carry. With no TO, the home they have gathers what
    ;; was declared in other scopes before there was a home.
    ((move-home aid to-scope-id)
     (catch-as-failure
       (lambda ()
         (let ((old (home-scope-of aid)))
           (unless (roster-ref to-scope-id) (error "scope not found" to-scope-id))
           (adopt-home! to-scope-id aid)
           (when (and old (not (equal? old to-scope-id))) (set-home-row! old aid #f))
           (let ((carried (consolidate-person! aid to-scope-id)))
             (success `((home . ,to-scope-id) (carried . ,carried)
                        ;; lent means stay with their grants (see `lent-means-of`)
                        (kept . ,(append-map (lambda (e) (if (equal? (car e) to-scope-id) '() (lent-means-of aid (car e))))
                                             (roster-entries))))))))))
    ((demand-total periods) ($ %uc-demand-node 'demand-for periods))
    ((means-total spec) (means-fold-total spec))
    ((means-rebuild!) (means-rebuild!) 'ok)
    ;; the pool's push rail (see slots-changed! above)
    ((slots-watch scope-id ref)   (slots-watch! scope-id ref)   'ok)
    ((slots-unwatch scope-id ref) (slots-unwatch! scope-id ref) 'ok)
    ((slots-changed! scope-id)    (slots-changed! scope-id)     'ok)
    ;; the folksonomy fold's two ends: the commons' aggregate (the lobby's
    ;; contribution + template surface) and one scope's node
    ((folksonomy-uc) %uc-folksonomy)
    ((folksonomy scope-id) (node-of scope-id nodes-folksonomy))
    ;; the credit fold's two ends: the UC root (every global-* read is a
    ;; method on it) and one scope's node
    ((credit-uc) %uc-credit-pool)
    ((credit scope-id) (node-of scope-id nodes-credit))
    ;; the voice fold's two ends, and the door the governance side hands the
    ;; hands reader through (the rail is its store); a cast refolds the scope
    ((voice-uc) %uc-voice-pool)
    ((voice scope-id) (node-of scope-id nodes-voice))
    ;; the reading fold's two ends, and the door a contrary cast refolds through
    ((readings-uc) %uc-reading-pool)
    ((readings scope-id) (node-of scope-id nodes-reading))
    ;; the face's read of the reading fold: SPEC's cells at this scope's node, every
    ;; technique, act and source apart, and the drift between counts and ledger —
    ;; plain data for the wire (docs/observation/readings-are-counts.md §1.1)
    ((scope-readings scope-id spec)
     (let ((n (node-of scope-id nodes-reading)))
       (if (not n) (failure "no such scope")
           (success (node-readings-reply n spec)))))
    ((observed! scope-id) (refold-readings! scope-id) 'ok)
    ;; the history behind the fold: what every source reported of SPEC between two
    ;; instants, off the scope's own event-sourced observer and the rail's standing
    ;; contrary observations, and what the fold would say from those readings alone
    ((readings-between scope-id spec from until)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (success (readings-between-reply ($ ($ root 'observer) 'standing-log) scope-id spec
                                              (string-or-false from) (string-or-false until)
                                              #:contrary (and contrary-of (contrary-of scope-id)))))))))
    ;; substitution as a reading: the scope's foods ranked by how far each covers
    ;; SPEC's leaves, against the floors a body states
    ((substitutes-for scope-id spec)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (call-with-values (lambda () (gather-recipes ($ root 'recipe-store)))
               (lambda (procs flows)
                 (success (map (lambda (p) `((spec . ,(car p)) (cover . ,(cdr p))))
                               (leaf-substitutes spec (scope-food-specs flows)
                                                 #:against (map sub-spec (subsistence-species-base))))))))))))
    ;; the rail's door: the standing hands of SCOPE-ID as rows ((owner part-string portion) …),
    ;; parsed here (parts.scm validate-hand) and refolded at once — what the
    ;; lobby hands over after a cast, and what the wiring seeds from HANDS-OF.
    ((hands! scope-id)
     (catch-as-failure (lambda () (success (refold-voice! scope-id)))))
    ((hands scope-id) (map (lambda (r) (list (car r) (part->string (cadr r)) (caddr r))) (rail-hands scope-id)))
    ((credit-read method . args) (apply $ %uc-credit-pool method args))
    ;; the slack fold: the commons' desire overlay as one read, or one scope's
    ((slack-uc) %uc-slack)
    ((slack scope-id) (node-of scope-id nodes-slack))
    ((slack-read method . args) (apply $ %uc-slack method args))

    ;; ── UC matching over the standing roster, landed by the descent ──
    ;; Every scope's rising proposals (purpose 'request, plan-bundle.scm)
    ;; meet the UC pool in ONE solve: the shadow prices coordinate every
    ;; scope's scale decision against the one supply, every scope's standing
    ;; accepts/holds seed the round before any assignment (so a person one
    ;; scope's accept already holds is consumed for all of them), and the
    ;; greedy walk takes the proposals round-robin across scopes — roster
    ;; position confers nothing. The flat deployment then enters the descent
    ;; at the root and each scope's plan-store receives exactly its own
    ;; commitments.
    ((match-labour!)
     (catch-as-failure
       (lambda ()
         (let ((stores (make-hash-table)))        ; proposal-id → plan-store
           (let loop ((rows (roster-entries))
                      (grouped '()) (seed '()) (tentative '()))
             (if (null? rows)
                 (let* ((result (solve-uc-matching
                                 (round-robin (reverse grouped)) #f
                                 ($ %uc-labour-pool 'pool)
                                 #:plan-store-of
                                 (lambda (p) (hash-ref stores (proposal-id p) #f))
                                 ;; the steward gate on each candidate: the
                                 ;; plan's scope (the routing table) names the
                                 ;; root whose recipes say what the intent's
                                 ;; process draws
                                 #:admit?
                                 (and may-steward-of
                                      (lambda (e wi pid)
                                        (let* ((sid (hash-ref %deployment-table pid #f))
                                               (root (and sid (roster-ref sid))))
                                          (or (not root)
                                              (steward-ok? root sid (entry-agent e)
                                                           (intent-input-of wi))))))
                                 #:seed seed #:tentative tentative))
                        (dep (or (assq-ref result 'deployment) '())))
                   (deploy! %uc-deployment dep)
                   (success
                    `((commitments . ,(length dep))
                      (hours . ,(fold (lambda (c a)
                                        (+ a (let ((m (commitment-effort-quantity c)))
                                               (if m (measure-has-numerical-value m) 0))))
                                      0 dep)))))
                 (let* ((sid  (caar rows))
                        (root (cdar rows))
                        (ps   (false-if-exception ($ root 'plan-store)))
                        (props (if ps
                                   (filter (lambda (p) (eq? (proposal-purpose p) 'request))
                                           ($ ps 'all-proposals))
                                   '())))
                   (for-each (lambda (p)
                               (let ((n (proposal-name p)))
                                 (when (and (string? n) (string-prefix? "plan:" n))
                                   (hash-set! %deployment-table (substring n 5) sid))
                                 (hash-set! stores (proposal-id p) ps)))
                             props)
                   (if (not ps)
                       (loop (cdr rows) grouped seed tentative)
                       (call-with-values (lambda () (deployment-bindings ps))
                         (lambda (s t)
                           (loop (cdr rows)
                                 (if (null? props) grouped (cons props grouped))
                                 (append s seed) (append t tentative))))))))))))

    ;; a commune's planner root, for the governance service's per-scope reads
    ;; (voice-in): the same roster the scope-list walks
    ((scope-root-ref scope-id) (roster-ref scope-id))

    ((scope-list)
     (map (lambda (e) `((id . ,(car e)) (name . ,($ (cdr e) 'name))
                        (path . ,(scope-geo-path (cdr e))))) (roster-entries)))

    ;; acting-aid (optional) → the snapshot's `proposals` are the social invites
    ;; directed at that agent. Older callers (tests) pass two args and get none.
    ((scope-snapshot scope-id plan-id #:optional (acting-aid #f))
     (with-scope scope-id
       (lambda (root)
         ;; each recipe's record as the solve takes it (scope-standing): the
         ;; face shows the very record the plan reads
         (let ((st (standing root scope-id)))
            (build-snapshot root scope-id plan-id acting-aid
                            #:extra-locations (federation-sibling-locations scope-id root)
                            #:recipe-responses (or (assq-ref st 'responses) '())
                            #:credit-roots (credit-roots acting-aid))))))

    ;; ── The legal exterior, derived LIVE — the law face's snapshot, folded
    ;;    over the activity catalogue (legal-crossings.md §§Law,Dual power) and
    ;;    over the law this planner's communes stand under: the static library
    ;;    with the rules each commune's own registry carries. Returns the JSON
    ;;    string, the shape of the bundled browser/data/snapshots/law-snapshot.json
    ;;    (which is what a seat reads; this door is the operator's).
    ;; budget optional: pass a DERIVED budget (federation-budget over the scopes'
    ;; composed strategy plans) to size the program's bundle to real leverage;
    ;; omit ⇒ the stewarded *program-budget* fallback (no live strategy scopes).
    ((legal-snapshot #:optional (budget #f))
     (let ((rules (rules-with
                   (append-map (lambda (e)
                                 (or (false-if-exception ($ ($ (cdr e) 'legal-registry) 'rules)) '()))
                               (roster-entries)))))
       (if budget
           (law-snapshot-string #:budget budget #:rules rules)
           (law-snapshot-string #:rules rules))))

    ;; ── the ValueFlows lint, as a door: what this scope would refuse ────────
    ;; RECORDS-JSON is an array of records (kind, action, spec, qty, unit, arcs);
    ;; the reply is the findings as JSON. The specs and units are the scope's
    ;; recipe store's, so a spec the scope does not know is a finding here and
    ;; a fact the app's passes quote back to a model (knowledge/vf-lint.scm).
    ;; ── the worlds a scope can start from (knowledge/presets.scm) ──
    ((presets) (preset-list))
    ((adopt-preset! scope-id preset-id)
     (scoped scope-id
       (lambda (root)
         (let ((w (adopt-preset! root preset-id scope-id)))
           `((preset . ,preset-id)
             (specs . ,(length (world-specs w))) (recipes . ,(length (world-recipes w)))
             (places . ,(length (world-spatials w))) (agents . ,(length (world-agents w)))
             (resources . ,(length (world-resources w))))))))

    ((lint-records scope-id records-json)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((rs ($ root 'recipe-store))
                    (specs ($ rs 'all-resource-specs))
                    (ids (map resource-specification-id specs))
                    (units (specs->units specs))
                    (records (let ((v (json-string->scm records-json)))
                               (cond ((vector? v) (vector->list v)) ((list? v) v) (else '())))))
               (scm->json-string (findings->wire (lint-records records #:specs ids #:units units)))))))))

    ;; ── Journeys: the map's route-and-go becomes VF records ─────────────────
    ;; A journey is one performed Process, based on the scope's mode for the way it
    ;; was made (mode = a routing costing: the baseline walk, bike and car, or a
    ;; shed's own modes), with two commitments and the two events that fulfil them:
    ;; a pickup at departure (the trip as input-of) and a dropoff on arrival (the
    ;; trip as output-of), resource-less, each of one rider. The observer's
    ;; arc-observations pairs the two by the process; the live boundary reads the
    ;; trip's manner off the mode recipe (live.scm trip-manner-of), and the
    ;; arc-time table's observed half starts learning from the federation's own
    ;; movement. PLACES are SpatialThing ids when known (then the table learns the
    ;; arc); a "geo:lat,lng" place is minted as one, and prices nothing until it
    ;; corresponds to a located place.

    ((journey-begin scope-id agent-id from-place to-place mode)
     (with-person scope-id agent-id
       (lambda (root)
         (catch-as-failure
       (lambda ()
         (let* ((obs ($ root 'observer))
                (ps  ($ root 'plan-store))
                (rs  ($ root 'recipe-store))
                (mode (if (symbol? mode) (symbol->string mode) mode))
                (now (iso-now))
                ;; the instant alone is second-precision — a double-tap
                ;; on the journey button collided two journeys onto one
                ;; cid, silently overwriting the first commitment AND
                ;; resetting its fulfillment via the unguarded
                ;; register-commitment below. The agent's running count
                ;; of jc- commitments disambiguates (record-purchase's
                ;; own fix pattern).
                (cid (string-append "jc-" agent-id "-"
                                    (number->string (instant->unix (clock-now))) "-"
                                    (number->string
                                     (length (filter (lambda (k)
                                                       (string-prefix? (string-append "jc-" agent-id "-")
                                                                       (or (commitment-id k) "")))
                                                     ($ ps 'all-commitments))))))
                (ids  (trip-ids cid))
                (pid  (car ids)) (dcid (cdr ids))
                ;; the trip is one performed Process, based on the scope's mode for the
                ;; way it was made; a costing no mode carries is classified by itself
                (mode-rp (mode-process-for-manner rs mode))
                (good (trip-good rs mode-rp))
                (process (make-process #:id pid #:name (string-append "journey by " mode) #:note "journey (map)"
                                       #:based-on (and mode-rp (recipe-process-process-conforms-to mode-rp))
                                       #:classified-as (list (string-append "manner:" mode)) #:in-scope-of (list scope-id) #:has-beginning now))
                (pickup
                 (make-commitment
                  #:id cid #:action 'pickup #:note "journey commitment (map)"
                  #:input-of pid                          ; input-of = the trip's process
 #:resource-conforms-to good #:resource-quantity (make-measure 1 %count-unit)   ; one rider, as the mode's pickup flow says
                  #:provider agent-id #:receiver agent-id
                  #:has-beginning now #:created now                ; begins now; created now
                  #:at-location from-place #:in-scope-of (list scope-id)))
                (dropoff
                 (make-commitment
                  #:id dcid #:action 'dropoff #:note "journey arrival (map)" #:output-of pid                          ; output-of = the trip's process
 #:resource-conforms-to good #:resource-quantity (make-measure 1 %count-unit)
                  #:provider agent-id #:receiver agent-id #:created now
                  #:at-location to-place #:in-scope-of (list scope-id))))
           (ensure-place! ($ root 'spatial-thing-store) from-place)
           (ensure-place! ($ root 'spatial-thing-store) to-place)
           ($ obs 'record-process process)
           ;; the journey is two commitments LIKE ANY OTHER: they live in the
           ;; plan-store (snapshots, calendars, chat strata all see them)…
           ($ ps 'add-commitment-silent pickup)
           ($ ps 'add-commitment-silent dropoff)
           ;; …and fulfillment tracking is armed on the observer —
           ;; guarded: registration RESETS a tracked state, so a replay
           ;; of an existing cid must never wipe recorded progress
           (for-each (lambda (c) (unless ($ obs 'get-fulfillment (commitment-id c))
                                   ($ obs 'register-commitment c)))
                     (list pickup dropoff))
           ($ obs 'record-event
              (make-trip-event
               #:id (string-append "ev-pu-" cid) #:action 'pickup
               #:input-of pid #:agent agent-id #:spec good
               #:beg now                       ; has-beginning = departure (it has not completed)
               #:from from-place #:fulfills cid
               #:note (string-append "journey depart by " mode)
               #:scope scope-id))
           (success `((commitment . ,cid) (arrival . ,dcid)))))))))

    ((journey-end scope-id agent-id commitment-id from-place to-place mode)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((obs ($ root 'observer))
                    (rs  ($ root 'recipe-store))
                    (mode (if (symbol? mode) (symbol->string mode) mode))
                    (ids (trip-ids commitment-id))
                    (pid (car ids)) (dcid (cdr ids))
                    (rp  (let ((spec ($ obs 'process-spec pid))) (and spec (find-recipe-process-for-spec rs spec))))
                    (now (iso-now)))
               ($ obs 'record-event
                  (make-trip-event
                   #:id (string-append "ev-do-" commitment-id) #:action 'dropoff
                   #:output-of pid #:agent agent-id #:spec (trip-good rs rp)
                   #:end now #:point now           ; has-end = arrival
                   #:from to-place #:to to-place #:fulfills dcid
                   #:note (string-append "journey arrive by " mode)
                   #:scope scope-id))
               (success `((commitment . ,commitment-id) (arrival . ,dcid)))))))))

    ;; ── Topic chats: generic store, plan-resolved strata ──────────────────
    ;; A topic is ANY string under the scope (an Intent/Commitment id is the
    ;; first use case; places, recipes, a walkie channel ride the same rail).
    ;; The author's stratum is resolved HERE — relation-of reads the plan when
    ;; the topic IS a plannable thing, and honestly says `public` otherwise —
    ;; then stamped; filtering is the client's read-side choice.

    ((chat-post scope-id topic aid body #:optional (message-kind #f))
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (success ($ chat-reg 'post
                         (string-append scope-id "/" topic) aid body
                         (or message-kind "text")
                         (relation-of root topic aid))))))))

    ((chat-history scope-id topic #:optional (since 0))
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (success (list->vector
                       ($ chat-reg 'history
                          (string-append scope-id "/" topic)
                          since))))))))

    ;; THE WAKE (docs/planning/faces/meeting-station.md, Layer 2): the last line of
    ;; each of MANY topics, in one call. The wake is an index over every live
    ;; room at once, so a round trip per room is the thing to avoid — that cost
    ;; is what would make "all rooms legible at all times" impractical.
    ;; Returns an alist topic → (author body kind t); topics with nothing said
    ;; are simply absent.
    ((chat-last scope-id topics)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (success
              (filter-map
               (lambda (topic)
                 ;; `last` reads the file's tail; the registry owns the format,
                 ;; so the wake never parses a conversation to see its newest
                 ;; line — the cost stays flat as a meeting transcribes itself.
                 (let ((last ($ chat-reg 'last (string-append scope-id "/" topic))))
                   (and last
                        (cons topic
                              (list (or (assq-ref last 'author) "")
                                    (or (assq-ref last 'body) "")
                                    (or (assq-ref last 'kind) "text")
                                    (or (assq-ref last 't) 0))))))
               ;; the wire may hand us a vector or a list
               (cond ((vector? topics) (vector->list topics))
                     ((list? topics) topics)
                     (else '())))))))))

    ((chat-watch scope-id topic cb)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             ($ chat-reg 'watch (string-append scope-id "/" topic) cb)
             (success #t))))))

    ;; Run the CONVEX planner over the scope's live state and return the implied
    ;; VF `work` commitments. demand = ((spec place period target) …); the engine
    ;; reads stock/labour/recipes/skills/hours from the observer + stores. opts is
    ;; an alist that may carry (movable . (…)) (storable . (…)) (commute-km . n).
    ((plan scope-id demand #:optional (opts '()))
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let ((o opts))
               (on-plan
                 (plan-fn* root scope-id
                   #:demand (demand->keyed demand)       ; the UC allocation rides in through standing-kw
                   #:movable (or (assq-ref o 'movable) '())
                   #:storable (or (assq-ref o 'storable) '())
                   #:whole (or (assq-ref o 'whole) '())
                   #:tau (or (assq-ref o 'tau) 0.0)
                   ;; (willing-only . #t) ⇒ the MATERIALIZATION binding: gate the
                   ;; solve to those who marked status=willing (the bundle hour-cap
                   ;; then bounds them). Default/off ⇒ the ungated candidate FIELD —
                   ;; today's behaviour, the offer over all reachable workers.
                   #:willing? (and (assq-ref o 'willing-only)
                                   (willing-predicate root))
                   #:agent-position (agent-position-predicate root)  ; live/expected positions
                   #:horizon (demand-horizon demand o)   ; derive multi-period from the demand (explicit opt wins)
                   ;; reproduction of labour-power: per-person nutrition floors + eat
                   ;; recipes over the scope's foods (live.scm). STRUCTURAL — on by
                   ;; default (a no-op unless the scope has people AND nutritious food),
                   ;; so every real commune reproduces its members automatically. Opt
                   ;; OUT with (reproduce . #f), not in.
                   #:reproduce? (not (eq? (assq-ref o 'reproduce) #f))
                   #:backend 'native-c)
                 (lambda (al) (success (cache-solve! scope-id demand al)))
                 #:catch (lambda (e) (failure (format #f "~a" e))))))))))

    ;; FEDERATION ACROSS VATS — several communes' provisioning composed through
    ;; one pull per crossing good (dual decomposition), so what one commune
    ;; lacks another supplies. Each commune keeps its own records in its own
    ;; scope; only flows and the pull cross. `boundary-good` is the INTERMEDIATE
    ;; that crosses (the input moves, each commune bakes locally — see
    ;; engine/federation-solve.scm). `communes` = ((scope-id (demand-good . qty)) …);
    ;; every commune named crosses the good, and which of them supplies and
    ;; which draws is the solve's answer, read off the sign of its flow.
    ;; Returns the met and rounds the crossing settled at and the good's pull λ.
    ;; Same-vat here (all roots near); the SAME shape goes cross-vat when roots
    ;; become remote (docs/planning/federation/FEDERATED-SOLVE.md, Rung 3).
    ;; OPTS (optional alist): `displacement-of` — a member scope-id whose
    ;; membership is to be read for what it displaces in the others
    ;; (truth-telling.md stage 4): one more
    ;; federated solve without it, its border shut, differenced on what the
    ;; others are delivered. Asked for, never run by default — it is a solve.
    ;; a member's record for a solve across scopes (scope-record-of): DEM its
    ;; demand (good . qty) or #f; OPTS as federated-plan's
    ;; the goods this scope deals in (planner/federation/crossing-set.scm) — what a
    ;; federation's crossing set is made of; DEMAND as scope-record's
    ((census scope-id #:optional (demand #f))
     (catch-as-failure (lambda () (success (scope-census scope-id demand)))))
    ((scope-record scope-id goods #:optional (demand #f) (opts '()))
     (catch-as-failure
       (lambda ()
         (let ((r (scope-record-of scope-id goods demand (federated-horizon (if (pair? opts) opts '())))))
           ;; a scope not on the roster answers with-scope's failure as it is
           (if (and (pair? r) (eq? (car r) 'error)) r (success r))))))
    ((federated-plan boundary-good communes #:optional (opts '()))
     (catch-as-failure
       (lambda ()
         (define (resources-of sid)             ; the same projected view the record was built from
           (and=> (roster-ref sid)
                  (lambda (root)
                    (false-if-exception (assq-ref (world-of* root sid) 'view)))))
         (let* ((o (if (pair? opts) opts '()))
                ;; one dated day for every member, so each roster window
                ;; meets a calendar day and enters as the hours it holds
                (hz (federated-horizon o))
                (_ (let ((bad (communes-overlap (map car communes))))
                     (when (pair? bad)
                       (error (format #f "communes overlap — ~a held by more than one program"
                                      (string-join (map (lambda (b) (format #f "~a ~a (~a)" (caar b) (cdar b)
                                                                            (string-join (cdr b) " + ")))
                                                        bad)
                                                   "; "))))))
                ;; WHAT CROSSES: the goods named, or — when none is named — every
                ;; good at least two of the communes deal in, read off their
                ;; records (federation/crossing-set.scm); nobody declares a supply
                (goods (cond ((string? boundary-good) (list boundary-good))
                             ((list? boundary-good) boundary-good)
                             (else (crossing-goods
                                    (map (lambda (c)
                                           (cons (list-ref c 0)
                                                 (scope-census (list-ref c 0)
                                                               (and (pair? (cdr c)) (list-ref c 1)))))
                                         communes)))))
                (recs (map (lambda (c)
                             (scope-record-of (list-ref c 0) goods
                                              (and (pair? (cdr c)) (list-ref c 1)) hz))
                           communes)))
           (call-with-values
               (lambda ()
                 ;; the folds feed the dual: start the consensus at the bound
                 ;; the communes' own deficit and stock already state
                 (federated-solve recs #:z0 (warm-boundary-flows recs resources-of)))
             (lambda (plans met rounds pulls)
               ;; cache each commune's FEDERATED per-location result where
               ;; location-slacks reads it → the desire overlay shows the deficit
               ;; commune draining to green as the boundary flow fills it.
               ;; the landing is the solve DESCENT: the rows enter at the
               ;; root, each scope's node receives and caches its own
               ($ %uc-solve 'set-value
                  (filter car (federated-per-scope plans recs)))
               (success `((met     . ,met)
                          (rounds  . ,rounds)
                          (pull    . ,(if (pair? goods) (hash-ref pulls (car goods) 0.0) 0.0))
                          (boundary . ,(if (string? boundary-good) boundary-good goods))
                          (pulls   . ,(map (lambda (g) (cons g (hash-ref pulls g 0.0))) goods))
                          ;; the two horns, always reported: what must cross
                          ;; and what can — so a run at its cap names a
                          ;; shortfall or a surplus nobody claimed, by quantity
                          (dilemma . ,(federated-dilemma recs resources-of))
                          ;; scopes whose declared batches / whole counts this
                          ;; solve kept relaxed — a federated plan is a relaxation
                          (relaxed . ,(federated-relaxed-scopes recs))
                          ;; crossings a scope stayed out of because it makes the
                          ;; good without bound and so has no measure to cross by
                          (unbounded . ,(append-map
                                         (lambda (r)
                                           (map (lambda (u) `((scope . ,(assq-ref r 'scope-id))
                                                              (good . ,(car u)) (column . ,(cdr u))))
                                                (or (assq-ref r 'unbounded) '())))
                                         recs))
                          ;; stage 4: λ per member scope — each good it crosses,
                          ;; its signed flow and the pull the crossing settled
                          ;; at: what one more unit of that scope's ask moves
                          ;; in the scopes across it. Pulls stand between
                          ;; scopes, persons never.
                          (scopes  . ,(federated-scope-pulls recs plans pulls))
                          ;; a crossing whose give-bound stands far above what
                          ;; crossed: the verdict's noise on its rows, in the
                          ;; good's unit, is a share of the flow worth reading
                          ,@(let ((l (loose-gives recs plans)))
                              (if (pair? l)
                                  `((loose . ,(map (lambda (r)
                                                     `((scope . ,(list-ref r 0)) (good . ,(list-ref r 1))
                                                       (gives . ,(list-ref r 2)) (crossed . ,(list-ref r 3))
                                                       (noise . ,(list-ref r 4))))
                                                   l)))
                                  '()))
                          ,@(let ((ps (assq-ref o 'displacement-of)))
                              (if ps
                                  `((scope-displacement
                                     . ((scope . ,ps)
                                        (moved . ,(federated-withdrawal-displacement
                                                   recs ps #:base (federated-result plans recs))))))
                                  '()))))))))))

    ;; THE UC GATEWAY LOOP (patchwork §5 item 1): the consensus row, run live.
    ;; COMMUNES = ((scope-id place keyed-demand) …). Each scope's world is built
    ;; from ITS OWN stores inside its closure (records-means-world — sovereignty
    ;; is the records never leaving), the bar TOTAL and the willingness CEILINGS
    ;; arrive from the caller (the governance side computes them off the means
    ;; fold and live-willingness-of — governance→planner, one direction), the
    ;; start is warm from whatever each scope held last time, and the result
    ;; LANDS: every subsequent `plan`/`solve` for these scopes carries its
    ;; allocation as a standing eco-cap until the next run moves it.
    ((means-plan spec total communes ceilings)
     (catch-as-failure
       (lambda ()
         ;; total 'auto reads the bar off the standing means fold — the input
         ;; the fold exists to supply, so no caller has to conjure it
         (let* ((total (if (eq? total 'auto) (means-fold-total spec) total))
                (scopes
                 (map (lambda (c)
                        (let ((sid (list-ref c 0)) (place (list-ref c 1))
                              (dem (list-ref c 2)))
                          (cons sid
                                (with-scope sid
                                  (lambda (root)
                                    (let ((as ($ root 'agent-store))
                                          (sts ($ root 'spatial-thing-store)) (rs ($ root 'recipe-store))
                                          (world (world-of* root sid)))   ; the one custody view
                                      (call-with-values (lambda () (gather rs root sid))
                                        (lambda (procs flows)
                                          (records-means-world
                                            (assq-ref world 'view) ($ as 'all-agents)
                                            ($ sts 'all-locations) procs flows spec place
                                            #:demand dem
                                            #:eco-caps (assq-ref world 'caps) #:span-of (assq-ref world 'span)
                                            #:proc-frag (or (assq-ref (standing root sid) 'proc-frag) '()))))))))))
                      communes))
                (prev (map (lambda (c)
                             (let ((rt (roster-ref (car c))))
                               (and rt (and=> (assoc-ref (hash-ref *means-caps* rt '()) spec) cdr))))
                           communes))
                (init (and (every number? prev) prev)))
           (call-with-values
               (lambda () (allocate-means-consensus scopes spec total
                                                    #:ceilings ceilings
                                                    #:init init))
             (lambda (allocs duals rounds)
               ;; the landing is the allocation DESCENT: one value enters at
               ;; the root, each scope's node receives its row and applies it.
               ;; The key is period-free (`Svc|spec#place`): the engine lays
               ;; it on every period a later solve declares.
               ($ %uc-allocation 'set-value
                  (map (lambda (c)
                         (let ((sid (list-ref c 0)) (place (list-ref c 1)))
                           (list sid spec
                                 (cons (lg (svc-good spec) place)
                                       (assoc-ref allocs sid)))))
                       communes))
               (success `((allocations . ,allocs)
                          (duals       . ,duals)
                          (rounds      . ,rounds)
                          (spec        . ,spec)
                          (total       . ,total)))))))))

    ;; NON-BINDING what-if / read — the conversational verb (the orb, the NL
    ;; interface, docs/planning/faces/nl-interface.md). One uniform OVERRIDES alist of
    ;; plan-scope inputs, merged over the scope's LIVE state, computed but NEVER
    ;; persisted. The current plan is (solve scope-id '()); a scenario overrides
    ;; (demand …)/(eco-caps …)/(reserve …)/(tau …). Returns the full result —
    ;; met, work, material, prices (the duals λ = the "why"), social (L, free
    ;; time f), candidates, and the duality-gap certificate — every
    ;; conversational read is a field of it. Binding lives only in MATERIALIZE
    ;; (separate, behind governance), so `solve` is safe to hand to anyone.
    ((solve scope-id overrides)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let ((o (if (pair? overrides) overrides '())))
               (on-plan
                 (plan-fn* root scope-id
                   #:demand     (demand->keyed (or (assq-ref o 'demand) '()))
                   #:eco-caps   (or (assq-ref o 'eco-caps) '())   ; the UC allocation stands under it (standing-kw)
                   #:reserve    (or (assq-ref o 'reserve) '())
                   #:movable    (or (assq-ref o 'movable) '())
                   #:storable   (or (assq-ref o 'storable) '())
                   #:whole      (or (assq-ref o 'whole) '())
                   #:tau        (or (assq-ref o 'tau) 0.0)
                   #:willing?   (and (assq-ref o 'willing-only) (willing-predicate root))
                   #:agent-position (agent-position-predicate root)
                   #:horizon    (demand-horizon (or (assq-ref o 'demand) '()) o)
                   #:backend 'native-c)
                 (lambda (al) (success (cache-solve! scope-id (or (assq-ref o 'demand) '()) al)))
                 #:catch (lambda (e) (failure (format #f "~a" e))))))))))

    ;; NON-BINDING provenance read: trace a prose CLAIM to what this scope's convex
    ;; solve produced. The bridge (playnet lang provenance) stays decoupled; here we
    ;; inject the live plan (its rents μ) and recipe store. A legal aspect is
    ;; STRUCTURAL — it reports which recipes it gates, not a slack — so `numbers` is
    ;; empty for a legal claim and populated for a commodity one. The `#` in a
    ;; claim's tag (grounds: REF#ID) is what names the id we join on. See
    ;; docs/planning/provenance-bridge.md.
    ((explain scope-id claim)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((rs   ($ root 'recipe-store))
                    (sym  (if (string? claim) (string->symbol claim) claim)))
               ;; pure-Scheme backend: explain is a read/debug path, no FFI dep
               (on-plan (plan-fn* root scope-id #:backend 'native)
                 (lambda (plan)
                   (success
                     (explain-claim sym plan
                       #:pull-of (make-pull-of plan)
                       #:gated-by (lambda (aspect) (recipes-conforming rs aspect)))))
                 #:catch (lambda (e) (failure (format #f "~a" e))))))))))

    ;; Wire-safe COMPACT summary for the browser orb: satisfaction, the social
    ;; ledger (L, free time), the loudest pulls (the duals λ), and the
    ;; near-optimality certificate — every number stringified (the dial's JSON
    ;; writer emits integers only). The orb NARRATES this; it never redraws the
    ;; dial, so there is no PLAN-shape mapping. NON-BINDING; (solve-brief id '())
    ;; is the current plan, (solve-brief id ((demand . …))) a what-if.
    ((solve-brief scope-id overrides)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             ;; overrides: a JSON string (browser orb) or an alist (Scheme) →
             ;; symbol-keyed plan-scope inputs. Parsing + prose live in (playnet
             ;; planner brief) — pure, so they unit-test without a vat/scope.
             (let ((o (parse-overrides overrides)))
               (on-plan
                 (plan-fn* root scope-id
                   #:demand     (demand->keyed (or (assq-ref o 'demand) '()))
                   #:eco-caps   (or (assq-ref o 'eco-caps) '())
                   #:reserve    (or (assq-ref o 'reserve) '())
                   #:tau        (or (assq-ref o 'tau) 0.0)
                   #:agent-position (agent-position-predicate root)
                   #:horizon    (demand-horizon (or (assq-ref o 'demand) '()) o)
                   #:backend 'native-c)
                 (lambda (full)
                   ;; No demand override means the orb asked for the CURRENT plan,
                   ;; not a what-if — and the current plan is exactly what the
                   ;; snapshot's plan/schedule wires serve, so it lands in the
                   ;; same cache the `solve` verb fills. A what-if stays unstored.
                   (unless (pair? (or (assq-ref o 'demand) '()))
                     (cache-solve! scope-id '() full))
                   (success (plan-brief->string full)))
                 #:catch (lambda (e) (failure (format #f "~a" e))))))))))

    ;; Materialize: run the willing-only plan AND persist its assignments as
    ;; stored suggested intents (mi|worker|skill|cell + suggested-provider meta),
    ;; so they surface in the next scope-snapshot under "Awaiting your acceptance"
    ;; — closing the offer→willingness→materialize→accept loop without a manual
    ;; bridge. Returns the plan alist plus (materialized . N).
    ((materialize scope-id demand #:optional (opts '()))
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let ((o opts))
               (on-plan
                 (plan-fn* root scope-id
                   #:demand (demand->keyed demand)
                   #:movable (or (assq-ref o 'movable) '())
                   #:storable (or (assq-ref o 'storable) '())
                   #:whole (or (assq-ref o 'whole) '())
                   #:tau (or (assq-ref o 'tau) 0.0)
                   #:willing? (willing-predicate root)   ; always the materialization binding
                   #:agent-position (agent-position-predicate root)
                   #:horizon (demand-horizon demand o)
                   #:backend 'native-c)
                 (lambda (al)
                   (let ((n (persist-materialized! root (assq-ref al 'work)
                                                   #:plan-id (or (assq-ref o 'plan-id) "plan-materialized"))))
                     (success (cons (cons 'materialized n) (cache-solve! scope-id demand al)))))
                 #:catch (lambda (e) (failure (format #f "~a" e))))))))))

    ;; The confirmation mile: a person sees a prefilled commitment (from `plan`)
    ;; and says "this happened". wc = that commitment alist (optionally edited);
    ;; we record the fulfilling `work` EconomicEvent and the observer folds it.
    ((fulfill-work scope-id wc)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (success `((event-id . ,(record-work-done root wc))
                        (fulfills . ,(row-id wc)))))))))

    ;; Enact a plan's MATERIAL flows — "it all happened as planned": record the
    ;; produce/consume/pickup/dropoff/use events the observer folds, moving stock. plan is the
    ;; alist from `plan` (only its (material …) is used).
    ((enact scope-id plan)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             ;; the rows enacted are the plan's own, found by id: a row the last plan
             ;; does not state waits unrecorded, and its quantity is the plan's, not the client's
             (let* ((stated  (let ((h (make-hash-table)))
                               (for-each (lambda (m) (hash-set! h (row-id m) m)) (planned-material scope-id))
                               h))
                    (asked   (or (assq-ref plan 'material) '()))
                    (mine    (filter-map (lambda (m) (hash-ref stated (row-id m) #f)) asked))
                    (strange (filter (lambda (m) (not (hash-ref stated (row-id m) #f))) asked))
                    (r       (begin (for-each (lambda (m) (hold-row! ($ root 'observer) scope-id m)) mine)
                                    (enact-rows root mine #:vocabulary (solve-vocabulary-of scope-id)
                                                #:runs (planned-runs scope-id)))))
               (success `((events . ,(car r))
                          (unmet . ,(append (map (lambda (m) (cons (row-id m) "the plan states no such row")) strange)
                                            (map (lambda (u) (cons (car u) (format #f "~a" (cdr u)))) (cdr r))))))))))))

    ;; ONE material row observed — the per-row browser door onto the same
    ;; confirmation mile enact walks wholesale. The row is found among the rows
    ;; the last plan states, by its own id (ROW-ID, which the schedule carries) or,
    ;; for a caller that has none, by its coordinates (action, spec, place, when,
    ;; process). Each plan row is a commitment under
    ;; the plan's own row id, so this door and enact name one commitment per row
    ;; and FulfillmentState governs partials as it does for work: QTY is spread
    ;; over the matching rows' remainders in plan order (a numbered event each),
    ;; a finished row answers `already` instead of double-moving stock, and more
    ;; than the rows hold is refused here, where the member's word becomes an
    ;; event. TOTAL rides the wire and decides nothing: the row is the plan's. The
    ;; flow is dated at the row's planned slot, or at its confirmation when the slot
    ;; is still ahead (live.scm planned-stamp). The two rows of a relocation chain
    ;; through the cargo's own lot: a dropoff lands what its pickup carried, and
    ;; is refused before that. NOTE rides the
    ;; wire and decides nothing: the row is the plan's.
    ;; NB the clock argument is named when-iso, never `when`: a method
    ;; parameter named `when` lexically shadows the macro.
    ((record-flow scope-id action spec qty total place when-iso proc note #:optional (row-id #f))
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (if (not (memq (string->symbol action)                    ; the actions a material row carries: a flow, a relocation, an occupation
                            (append *flow-actions* relocating-actions occupying-actions)))
                 (failure (string-append "unknown flow action: " action))
                 (let* ((obs  ($ root 'observer))
                        (rows (if (and (string? row-id) (not (string-null? row-id)))
                                  (filter (lambda (m) (equal? (planned-row-id m) row-id)) (planned-material scope-id))
                                  (planned-rows scope-id action spec place when-iso proc))))
                   (when (null? rows)
                     (error "the plan holds no such row; confirm what the plan states" action spec place))
                   (for-each (lambda (m) (hold-row! obs scope-id m)) rows)
                   (let* ((open (filter (lambda (m) (> (row-left obs m) (reach-slack (row-quantity m)))) rows))
                          (room (fold + 0 (map (lambda (m) (row-left obs m)) open))))
                     (cond
                      ((null? open) (success `((event-id . "") (already . #t))))
                      ((target-passed? qty room)
                       (error (format #f "the row holds ~a more; ~a recorded" room qty)))
                      (else
                       (let spend ((ms open) (need qty) (first #f))
                         (if (or (null? ms) (not (target-passed? need 0)))
                             (success `((event-id . ,(or first ""))))
                             (let* ((m    (car ms))
                                    (cid  (planned-row-id m))
                                    (take (min need (row-left obs m)))
                                    (evid (string-append "ev-" cid "-"
                                                         (number->string (length (or ($ obs 'fulfilled-by cid) '()))))))
                               (record-flow-done root m
                                                 #:quantity take #:event-id evid
                                                 #:vocabulary (solve-vocabulary-of scope-id)
                                                 #:runs (planned-runs scope-id))
                               (spend (cdr ms) (- need take) (or first evid)))))))))))))))

    ;; ONE planned CLAIM confirmed — the citizen took their good. The plan
    ;; registered its `claims` row as a `transfer` commitment when it landed
    ;; (plan-claims!), and this door only ever fulfils one: the open commitment
    ;; of SPEC for CLAIMANT at PLACE (when named) with QTY still remaining. Each
    ;; call records QTY more as the account store's claim — the transfer event
    ;; that moves custody and draws the certificate — carrying `fulfills` so
    ;; FulfillmentState governs partials; a row confirmed in full answers
    ;; `already`. A claim the plan never planned is refused at the ledger: the
    ;; want is stated, and the next plan answers it. TOTAL and WHEN-ISO ride the
    ;; wire for the row's own record and decide nothing here. The pool resource
    ;; is whichever holds the spec on this rail with enough on hand; the cost is
    ;; the good's crystallized SNLT, the same number the plan tallied.
    ((record-claim scope-id claimant spec qty total place when-iso)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((obs  ($ root 'observer))
                    (fs   (open-claim-for obs spec claimant #:place place #:at-least qty))
                    (cid  (and fs (fulfillment-state-commitment-id fs)))
                    ;; the row stood and is confirmed in full: nothing open, a finished one on the books
                    (done (and (not fs)
                               (any (lambda (f)
                                      (let ((t (claim-cid-terms (fulfillment-state-commitment-id f))))
                                        (and t (fulfillment-state-finished f)
                                             (equal? (car t) spec) (equal? (cadr t) claimant)
                                             (or (not place) (equal? (caddr t) place)))))
                                    ($ obs 'all-fulfillments)))))
               (unless (or fs done)
                 (error (format #f "the plan holds no claim of ~a for ~a; state the want and the plan answers" spec claimant)))
               (if done
                   (success `((event-id . "") (already . #t)))
                   (let* ((pool (filter (lambda (r)
                                          (and (equal? spec (economic-resource-conforms-to r))
                                               (resource-individually-claimable? r ($ root 'recipe-store))
                                               (not (equal? claimant (economic-resource-primary-accountable r)))
                                               (let ((oh (economic-resource-onhand-quantity r)))
                                                 (and oh (>= (measure-has-numerical-value oh) qty)))))
                                        ($ obs 'inventory)))
                          (r    (if (pair? pool) (car pool)
                                    (error (format #f "the pool holds no ~a for ~a to claim" spec claimant))))
                          (snlt (crystallized-snlt-for-spec ($ root 'recipe-store) spec))
                          (cost (if (and (number? snlt) (finite? snlt)) (* qty snlt)
                                    (error "the good has no recipe to price it by" spec))))
                     ($ ($ root 'account-store) 'claim (economic-resource-id r) qty claimant cost (credit-roots claimant)
                        #f place when-iso cid)
                     (success `((event-id . ,(let ((evs (or ($ obs 'fulfilled-by cid) '())))   ; newest first
                                               (if (pair? evs) (economic-event-id (car evs)) "")))
                                (fulfills . ,cid)
                                (claimed . ,cost)
                                (balance . ,(wire-number ($ obs 'credit-balance claimant)))))))))))))

    ((inventory-snapshot scope-id plan-id)
     (with-scope scope-id
       (lambda (root)
         (with-expected root (planned-material scope-id)
                        (build-inventory-snapshot root scope-id plan-id)
                        (clock-now)))))

    ((resource-detail scope-id resource-id)
     (with-scope scope-id
       (lambda (root) (build-resource-detail root resource-id))))

    ((process-context scope-id process-id)
     (with-scope scope-id
       (lambda (root) (build-process-context root process-id))))

    ((accept-assignment scope-id intent-id acting-as)
     (with-person scope-id acting-as
       (lambda (root)
         (let ((r (do-accept-assignment root intent-id acting-as scope-id
                                        #:admit? (steward-admit root scope-id))))
           (when (and (pair? r) (eq? (car r) 'ok))
             (resolve-scope! scope-id root))   ; the accept re-plans the scope
           r))))

    ((decline-assignment scope-id intent-id acting-as)
     (with-scope scope-id
       (lambda (root) (do-decline-assignment root intent-id acting-as))))

    ;; The solver-offers-first loop: respond to a candidate-field offer by marking
    ;; willing (opt in to be materializable for skill@cell) or withdrawing it. Over-
    ;; subscribable; binds nothing here. A subsequent `plan` with (willing-only . #t)
    ;; materializes the feasible optimum over the willing, bounded by each hours-budget.
    ((express-willingness scope-id worker skill cell willing? #:optional (hours #f))
     (with-person scope-id worker
       (lambda (root)
         (do-express-willingness root worker skill cell willing? hours))))

    ;; Needs-based materialization for the live calendar: assign willing workers
    ;; to the scope's OPEN needs (the "race") so they surface under "Awaiting
    ;; your acceptance". The browser calls this right after express-willingness,
    ;; so marking willing immediately materializes. Returns (materialized . N).
    ((materialize-willing scope-id)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda () (success `((materialized . ,(materialize-willing! root)))))))))

    ;; Live/expected position: where AGENT is at PERIOD (period 0 = now). The
    ;; planner uses it as the commute origin, overriding the static home. place
    ;; is a known location id (client snaps GPS to nearest place first). All
    ;; three sharing modes call this — manual/continuous on period 0, expected
    ;; on future periods. place=#f clears.
    ((set-position scope-id agent-id period place)
     (with-scope scope-id
       (lambda (root) (do-set-position root agent-id period place))))

    ;; Raw-GPS variant: snap lat/lon to the nearest known location, store only
    ;; that place. For clients that send coordinates (gateway does the coarsening).
    ((set-position-latlon scope-id agent-id period lat lon)
     (with-scope scope-id
       (lambda (root)
         (if (sharing-refused? root agent-id period #t)
             (failure "location sharing is off: declare live or here to send a fix")   ; refused before a place is made for the fix
             (do-set-position root agent-id period
               (or (nearest-location root lat lon)
                   (own-position-place! root agent-id lat lon
                     (append-map (lambda (e) (or (false-if-exception ($ ($ (cdr e) 'spatial-thing-store) 'all-locations)) '()))
                                 (roster-entries)))))))))

    ;; Whether this person shares where they are: live (a watched fix), here (one
    ;; fix) or off. Stated once, at the home, so every device of theirs reads the
    ;; same; off ends the fix that stands.
    ((set-location-sharing scope-id aid mode)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let ((m (and (string? mode) (string->symbol mode)))
                   (ps ($ root 'plan-store)))
               (unless (memq m location-modes)
                 (error "location sharing is live, here or off" mode))
               ($ ps 'set-meta (location-share-key aid) `((mode . ,m) (at . ,(clock-now))))
               (when (eq? m 'off) ($ ps 'set-meta (position-key aid 0) '()))
               (success m)))))))
    ((location-sharing scope-id aid)
     (with-scope scope-id
       (lambda (root) (catch-as-failure (lambda () (success (or (location-mode root aid) 'undeclared)))))))

    ;; A NEW PLACE, named by a citizen — free-association's LocationEditor
    ;; "Specific" address, on VF: a <spatial-thing> in the scope's store,
    ;; deterministic id (place:AID:slug ⇒ naming it again re-places it),
    ;; coordinates optional (0/0 = none). Returns the id, so a slot's WHERE
    ;; can point at it the moment it exists.
    ;; a state is a form (docs/observation/physics.md §2–3): the scope declares
    ;; BASE warmed by DELTA-T kelvin with SPECIFIC-HEAT kJ/(kg·K), held in ENCLOSURE
    ;; (a keep-in-place spec) of conductance UA kW/K over MASS kg; the store gains
    ;; the form, its stated row, the base's zero, and the relaxation recipe
    ((thermal-form! scope-id base specific-heat delta-t enclosure #:optional (ua #f) (mass #f))
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (success (declare-thermal-form! ($ root 'recipe-store) base specific-heat delta-t enclosure
                                             #:ua ua #:mass mass)))))))
    ;; PARENT names the place this one is inside: a room in a site, a shelf in
    ;; a room. The child's id is its parent's with its own name after a slash,
    ;; so two rooms each have a "shelf 1", and a child that states no position
    ;; stands at its parent's.
    ((declare-place scope-id agent-id name lat lon #:optional (address #f) (parent #f))
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((sts  ($ root 'spatial-thing-store))
                    (slug (string-map (lambda (c) (if (or (char-alphabetic? c) (char-numeric? c)) (char-downcase c) #\-))
                                      (string-trim-both (or name ""))))
                    (pid  (string-or-false parent))
                    (par  (and pid ($ sts 'get-location pid)))
                    (id   (if pid
                              (string-append pid "/" slug)
                              (person-place-id agent-id slug)))
                    (has? (and (number? lat) (number? lon) (not (and (zero? lat) (zero? lon)))))
                    (addr (string-or-false address)))
               (when (string-null? slug) (error "a place needs a name"))
               (when (and pid (not par)) (error "no such place to be inside"))
               ($ sts 'add-location
                  (make-spatial-thing #:id id #:name (string-trim-both name)
                                      #:lat (if has? lat (and par (spatial-thing-lat par)))
                                      #:long (if has? lon (and par (spatial-thing-long par)))
                                      #:mappable-address (or addr (and par (spatial-thing-mappable-address par)))
                                      #:contained-in pid))
               (success `((id . ,id)))))))))

    ;; Whether COMMITMENT-ID is a count the plan asked of AGENT-ID and still
    ;; stands: what a photo read draws on in place of the week's allotment.
    ((count-commitment-of scope-id agent-id commitment-id)
     (with-scope scope-id
       (lambda (root)
         (let ((c ($ ($ root 'plan-store) 'get-commitment commitment-id)))
           (success (and c
                         (count-process? (commitment-input-of c))
                         (equal? agent-id (commitment-provider c))
                         (not (commitment-finished c))
                         #t))))))

    ;; The schedule of counts: every target the inventory shows, soonest due
    ;; first, with the interval the plan's reliance and the ledger's drift
    ;; give it (counting.scm).
    ((count-schedule scope-id #:optional (regime #f))
     (with-scope scope-id
       (lambda (root)
         (count-schedule-reply root scope-id (node-of scope-id nodes-reading) regime))))

    ;; Lay the counts that are due as offers (count-door.scm lay-counts).
    ((plan-counts scope-id agent-id #:optional (regime #f) (counter #f) (at-most #f))
     (with-person scope-id agent-id
       (lambda (root)
         (catch-as-failure
          (lambda ()
            (success (lay-counts root scope-id agent-id (scope-members root scope-id)
                                 (node-of scope-id nodes-reading) regime counter at-most
                                 (instant->unix (clock-now)))))))))

    ;; The counts of one stock, newest first: each adjustment a count landed, who
    ;; counted, by what technique, and the picture it names. What a member reads
    ;; to contest a count (governance contest-work); a contested and voided count
    ;; is gone from it, since it reads the standing events.
    ;; The scope as its member's device holds it: its goods, places, people, standing
    ;; needs and the observer's books, as one text (replica.scm). What a device
    ;; seeds its copy from on taking a seat, and again after it flushes.
    ((scope-replica scope-id agent-id)
     (with-person scope-id agent-id
       (lambda (root)
         (catch-as-failure
          (lambda () (success (replica->text (scope->replica root))))))))

    ((count-history scope-id agent-id resource-id #:optional (limit #f))
     (with-scope scope-id
       (lambda (root) (count-history-reply root agent-id resource-id limit))))

    ;; The code a stock is known by, for its label: given on the first asking,
    ;; the same on every asking after.
    ((label-stock scope-id agent-id resource-id)
     (with-person scope-id agent-id
       (lambda (root) (label-stock-reply root scope-id agent-id resource-id))))

    ;; What a label names: the thing, where it is, and what is in it.
    ((read-label scope-id agent-id code)
     (with-person scope-id agent-id
       (lambda (root) (read-label-reply root code))))

    ;; Settlement: draw earned credit to receive an individually-claimable good.
    ;; The account-store validates the draw against the elastic effective-balance
    ;; (rejecting over-draw), records the transfer event — which, when the scope is
    ;; credentialed, the on-event hook attests as a claim ACDC — and decrements
    ;; claimed-capacity. Single-scope here; federation-wide draw is the multi-scope
    ;; extension. Returns the new balance.
    ;; labor-cost #f ⇒ derive it here: qty × SNLT_crystallized of the
    ;; resource's spec — the same measure that values the pool K, so a claim
    ;; costs exactly what the good cost society (the browser never prices
    ;; Leaving a thing in a shared container, and taking one out. ACTION is
    ;; "dropoff" | "pickup"; the observer reads every effect off the VF
    ;; ActionDefinition, so this method holds no rules of its own beyond what
    ;; the ledger can check. OPTS: (resource-id [note [accountable]]).
    ;;
    ;; RESOURCE-ID names the thing moved — a pickup must name one, and a dropoff
    ;; that names one MOVES it, rights and rail intact. ACCOUNTABLE is a claim of
    ;; rights over a thing being introduced, and it is only ever a declaration:
    ;; left out, the thing enters the books owned by nobody, because putting
    ;; something down is not how anyone comes to own it.
    ((drop-event scope-id action container-id agent spec qty unit #:optional (resource-id #f) (note #f) (accountable #f))
     (with-person scope-id agent
       (lambda (root)
         (do-drop-event root (if (equal? action "pickup") 'pickup 'dropoff)
                        container-id agent spec qty
                        #:scope scope-id         ; whose commons this box is
                        #:unit (if (and (string? unit) (not (string-null? unit))) unit %count-unit)
                        #:resource-id (string-or-false resource-id)
                        #:note (string-or-false note)
                        #:accountable (string-or-false accountable)))))

    ;; its own claim). OPTS: (at-location [when]) — where the good should
    ;; reach the citizen and when they want it, recorded on the transfer.
    ((claim scope-id resource-id qty claimant labor-cost #:optional (where #f) (deliver-at #f))
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             ;; the CLAIMANT states which good and how many; the price is the
             ;; good's crystallized labour, derived here. LABOR-COST stays in the
             ;; door's signature for callers that still send it and is not read:
             ;; a cost the client states could be zero or negative.
             (unless (finite-positive? qty)
               (error "a claim is for a finite positive quantity" qty))
             (let* ((cost (let* ((r (or ($ ($ root 'observer) 'get-resource resource-id)
                                        (error "Resource not found" resource-id)))
                                 (snlt (crystallized-snlt-for-spec
                                         ($ root 'recipe-store)
                                         (economic-resource-conforms-to r))))
                            (unless (and (number? snlt) (finite? snlt))
                              (error "Resource spec has no recipe to price it by"
                                     resource-id))
                            (* qty snlt))))
               ;; SOLVENCY: a claim draws on what the pool HOLDS. The ledger's
               ;; decrement has no floor of its own, so the stock is checked
               ;; here — the observer's on-hand (what the events say is there),
               ;; and, for a pool with a live reading (the XMR wallet's
               ;; unlocked balance, resized by the poller), that reading too:
               ;; a claim the wallet could not pay out is refused at the door.
               (let* ((obs  ($ root 'observer))
                      (r    (or ($ obs 'get-resource resource-id)
                                (error "Resource not found" resource-id)))
                      (oh   (economic-resource-onhand-quantity r))
                      (have (if oh (measure-has-numerical-value oh) 0))
                      ;; a live reading counts once one has been taken (total > 0):
                      ;; a freshly spawned gauge at zero is no reading yet
                      (live (let* ((lr (catch #t (lambda () ($ root 'live-registry)) (lambda _ #f)))
                                   (l  (and lr ($ lr 'get resource-id))))
                              (and l (> ($ l 'total) 0) l)))
                      (avail (if live ($ live 'available) have)))
                 (when (> qty have)
                   (error (format #f "the pool holds ~a; ~a asked" have qty)))
                 (when (and live (> qty avail))
                   (error (format #f "the wallet can pay out ~a right now; ~a asked" avail qty)))
                 ;; THE PLAN'S WORD: the shop's "get" confirms what the plan holds
                 ;; for this citizen — the open claim commitment of the good's spec
                 ;; for them (plan-claims!) with QTY still remaining. A good the
                 ;; plan did not set aside for them is refused; the want is stated
                 ;; and the next plan answers. WHERE is where the good is to reach
                 ;; them, recorded on the transfer; the row is found by spec alone.
                 (let* ((spec (economic-resource-conforms-to r))
                        (fs   (or (open-claim-for obs spec claimant #:at-least qty)
                                  (error (format #f "the plan holds no claim of ~a for ~a; state the want and the plan answers"
                                                 spec claimant)))))
                   ($ ($ root 'account-store) 'claim resource-id qty claimant cost (credit-roots claimant)
                      #f                                       ; level
                      where deliver-at (fulfillment-state-commitment-id fs))))
               (success `((claimed . ,cost)
                          (balance . ,(wire-number ($ ($ root 'observer) 'credit-balance claimant)))
                          (credit . ,(credit->wire root claimant (credit-roots claimant)))))))))))

    ;; Read: a person's credit standing in this scope — gross (validated work)
    ;; minus claimed (individually-claimable draws). The UI shows it as purchasing
    ;; power; it equals reconstruct-credit-balance over the scope's ACDC set.
    ((credit-balance scope-id agent-id)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (success `((balance . ,(wire-number ($ ($ root 'observer) 'credit-balance agent-id))))))))))

    ((record-effort scope-id commitment-id acting-as qty unit)
     (with-scope scope-id
       (lambda (root) (do-record-effort root commitment-id acting-as qty unit))))

    ;; The captain's log observes: a spoken entry's suggested event, recorded
    ;; SELF-scoped on the observer (see do-log-observe for the door's width).
    ;; NOTE carries the entry's own line; WHEN the narrated time (ISO, "" = now).
    ((log-observe scope-id agent-id action spec qty unit note when-iso)
     (with-person scope-id agent-id
       (lambda (root)
         (do-log-observe root scope-id agent-id action spec qty unit
                         #:note (string-or-false note)
                         #:when-iso (and (string? when-iso)
                                         (not (string-null? when-iso))
                                         when-iso)))))

    ;; A count of a stock the books hold: the difference lands as a raise or
    ;; lower on that stock, with the technique, the place, the instant and
    ;; the evidence hash on the event (see do-count-stock). An empty string
    ;; leaves an optional field unstated. A count that moves the stock leaves
    ;; the plan standing on an old figure, so the plan is marked stale: its
    ;; wire says so until the next solve lands.
    ((count-stock scope-id agent-id resource-id counted unit
                  #:optional (technique #f) (place #f) (when-iso #f)
                             (fulfills #f) (evidence #f) (note #f))
     (with-person scope-id agent-id
       (lambda (root)
         (let ((landed (do-count-stock root scope-id agent-id resource-id counted (string-or-false unit)
                                       #:technique (string-or-false technique) #:place (string-or-false place)
                                       #:when-iso (string-or-false when-iso) #:fulfills (string-or-false fulfills)
                                       #:evidence (string-or-false evidence) #:note (string-or-false note)
                                       #:rows (planned-material scope-id))))
           (when (and (pair? landed) (eq? (car landed) 'ok)
                      (let ((delta (assq-ref (cdr landed) 'delta)))
                        (and (number? delta) (not (zero? delta)))))
             (mark-solve-stale! scope-id))
           landed))))

    ;; the member's id arrives as `aid` — naming it agent-id would shadow the
    ;; record accessor the updater calls (the silent-degrade class the live
    ;; first-citizen probe catalogued)
    ((set-availability scope-id aid availability-window)
     (with-scope scope-id
       (lambda (root)
         (let ((as ($ root 'agent-store)))
           ($ as 'update-agent aid
              (lambda (old)
                (copy-agent old #:availability-window availability-window)))
           `(ok . ,aid)))))

    ;; the member's own PROFILE — the typed tags the subsistence context and the
    ;; diet read (sex: age: pregnant: lactating: region: labour-hours: standard:
    ;; diet: allergy: excludes:, and the bare legacy words). JSON is an array of
    ;; tag strings; every profile tag the record held is replaced by them, every
    ;; other classification stays. UPSERT, as availability is: stating who you
    ;; are is the moment you become a person here.
    ((set-profile scope-id aid json)
     (with-scope scope-id
       (lambda (root)
         (let* ((tags (let ((v (false-if-exception (json-string->scm json))))
                        (if (vector? v) (filter string? (vector->list v)) '())))
                (as ($ root 'agent-store))
                (with-tags (lambda (old) (append (remove profile-tag? (or old '())) tags))))
           (or ($ as 'update-agent aid
                  (lambda (old)
                    (copy-agent old #:classified-as (with-tags (agent-classified-as old)))))
               (begin
                 ($ as 'add-agent
                    (make-agent #:id aid #:type 'person #:name aid #:classified-as (with-tags '())))
                 ;; a new body starts with the same two everyone has — walking
                 ;; and cycling — declared here exactly as declare-skill would
                 ;; raise them on request, not assumed some other way: the one
                 ;; default a fresh profile gets, same as every other skill a
                 ;; member may later revoke if it doesn't hold for them.
                 (declare-skill! root aid "walk")
                 (declare-skill! root aid "cycle")
                 #t))
           `(ok . ,tags)))))
    ;; the member's registered HOME — the agent record's primary-location, the
    ;; floor every position rule falls back to (live.scm agent-cell: live fix →
    ;; committed work → declared future → home). PLACE is a place the scope
    ;; already knows; "" with LAT/LON declares (or re-places) the member's own
    ;; `place:AID:home` and uses that, so a home needs no place anyone else
    ;; named. UPSERT, as set-profile is. Replies (ok (place . id)).
    ;; the member's id arrives as `aid`: naming it agent-id would shadow the
    ;; record accessor the updater calls (see set-availability)
    ((set-home scope-id aid place lat lon)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((sts ($ root 'spatial-thing-store))
                    (as ($ root 'agent-store))
                    (given (string-or-false place))
                    (has? (and (number? lat) (number? lon) (not (and (zero? lat) (zero? lon)))))
                    (id (cond (given
                               (unless (false-if-exception ($ sts 'get-location given))
                                 (error "no such place in this scope" given))
                               given)
                              (has?
                               (let ((id (person-place-id aid "home")))
                                 ($ sts 'add-location
                                    (make-spatial-thing #:id id #:name (string-append "home of " aid) #:lat lat #:long lon
                                                        #:contained-in (standing-in lat lon ($ sts 'all-locations))))
                                 id))
                              (else (error "a home needs a known place or coordinates")))))
               (or ($ as 'update-agent aid
                      (lambda (old)
                        (copy-agent old #:primary-location id)))
                   ($ as 'add-agent
                      (make-agent #:id aid #:type 'person #:name aid #:primary-location id
                                  #:classified-as '())))
               (success `((place . ,id)))))))))
    ;; declare-dwelling: the dwelling this AID lives in, as the housing closure
    ;; reads it (knowledge/housing-substance.scm resource->dwelling-unit): one
    ;; owned resource `dwelling:AID` of spec-dwelling standing at PLACE — the
    ;; AID's registered home when "" — measured by its tags. `area-m2:` and
    ;; `rooms:` are the whole dwelling's, shared by the `beds:` it houses a
    ;; night; `warmth-winter-degc:` and `warmth-summer-degc:` what it is kept
    ;; at in each season — the three gradients its nights deliver. A RENTED
    ;; dwelling is held under split custody: the tenant custodies it, the
    ;; landlord is primary-accountable, so schemas.scm's resource-rented? reads
    ;; it and the fragility wheel shows the eviction risk as it does any
    ;; loaned-in means (rented-fragility.md). `attests:<gate>` is what an inspection of it would
    ;; certify, `certified` that the certificate stands, `rent-eur-night:` its
    ;; own rent where a landlord is paid (the unit's price, else the rent
    ;; recipe's), `tenure:` own|rent|lodged — custody, never a row of the
    ;; vector (docs/rights.md), kept so a bed lent out of a rented flat is
    ;; known to be a lease question. Re-declaring replaces the tags; a
    ;; measurement that is not a positive number is refused.
    ((declare-dwelling scope-id aid place area rooms warmth-winter warmth-summer beds attests-json certified rent tenure)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((obs  ($ root 'observer))
                    (as   ($ root 'agent-store))
                    (sts  ($ root 'spatial-thing-store))
                    (given (string-or-false place))
                    (home (and=> ($ as 'get-agent aid) agent-primary-location))
                    (loc  (or given home (error "a dwelling stands at a place: name one, or register a home first")))
                    (m    (lambda (what x) (if (and (real? x) (> x 0)) (number->string (exact->inexact x))
                                               (error "a dwelling states a positive" what x))))
                    (n    (if (and (number? beds) (> beds 0)) beds 1))
                    (gates (filter housing-gate? (cats-json->list attests-json)))
                    (tags (append (list (string-append "area-m2:" (m "floor area" area))
                                        (string-append "rooms:" (m "room count" rooms))
                                        (string-append "warmth-winter-degc:" (m "winter warmth" warmth-winter))
                                        (string-append "warmth-summer-degc:" (m "summer warmth" warmth-summer))
                                        (string-append "beds:" (number->string n)))
                                  (map (lambda (g) (string-append "attests:" g)) gates)
                                  (if (and certified (pair? gates)) '("certified") '())
                                  (if (and (number? rent) (> rent 0))
                                      (list (string-append "rent-eur-night:" (number->string rent))) '())
                                  (if (and (string? tenure) (member tenure '("own" "rent" "lodged")))
                                      (list (string-append "tenure:" tenure)) '())))
                    (rid  (dwelling-id aid))
                    (rented? (equal? tenure "rent")))
               (unless (false-if-exception ($ sts 'get-location loc))
                 (error "no such place in this scope" loc))
               ($ obs 'record-resource
                  (make-economic-resource
                   #:id rid #:name (string-append aid "'s dwelling") #:image "🏠"
                   #:conforms-to "spec-dwelling" #:classified-as tags
                   #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit)
                   #:current-location loc
                   #:primary-accountable (if rented? (string-append "landlord:" aid) aid)   ; primary-accountable: who can recall it
                   #:custodian-scope (if rented? aid #f)                                 ; custodian-scope: who holds it meanwhile
))
               (success `((resource . ,rid) (place . ,loc) (tags . ,tags)))))))))
    ;; Dial availability: JSON is an array of {start:"HH:MM", end:"HH:MM",
    ;; days:[name…]} — one arc per object. Each becomes a day-schedule (its
    ;; weekday-set + time-range); they union into the agent's availability
    ;; window. Empty array clears the window (back to unconstrained). The dial
    ;; sends this through HANDLERS.setAvailability; we parse it here (the
    ;; browser spine has no JSON reader), same as solve-brief's overrides.
    ((set-availability-ranges scope-id aid json)
     (with-scope scope-id
       (lambda (root)
         (let* ((window (arcs-json->window json))
                (as ($ root 'agent-store)))
           ;; UPSERT: offering your time IS the moment you become an agent
           ;; here — a browser-born AID has no prior record, and an update
           ;; that returns #f for it would silently drop the offer (the
           ;; solve then plans over 0 available hours forever).
           (or ($ as 'update-agent aid
                  (lambda (old)
                    (copy-agent old #:availability-window window)))
               (begin
                 ($ as 'add-agent
                    (make-agent #:id aid #:type 'person #:name aid #:classified-as '()
                                #:availability-window window))
                 ;; generic labour comes with the person: a skill is a
                 ;; resource conforming to its spec (agents-with-skill groups
                 ;; by primary-accountable), and spec-labor is the one every
                 ;; person can work — without it a first citizen's offered
                 ;; hours count for nothing the plan can schedule.
                 ;; …and the spec says it is worked (its effort unit), which is
                 ;; what makes the resource read as a skill at all
                 ;; (declare-skill!'s own step, for the generic)
                 (unless ($ ($ root 'recipe-store) 'get-resource-spec generic-labour-spec-id)
                   ($ ($ root 'recipe-store) 'add-resource-spec generic-labour-spec))
                 ($ ($ root 'observer) 'record-resource
                    (make-economic-resource
                     #:id (generic-skill-id aid)
                     #:name (string-append aid " " generic-labour-spec-id)
                     #:conforms-to generic-labour-spec-id
                     #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit) #:primary-accountable aid))))
           `(ok . ,aid)))))

    ;; Social invite (non-work). The inviter creates an Intent (action='use,
    ;; name=human label, event time on has-beginning/has-end, provider=inviter,
    ;; receiver=invitee) wrapped in a directed Proposal (proposed-to=[invitee]).
    ;; The invitee sees it under their snapshot's `proposals` (build-snapshot
    ;; filters by proposed-to) and accepts via accept-invite. Reuses the VF
    ;; proposal machinery; no schema change. The proposal's own temporal window is
    ;; left #f (always acceptable) — validate-proposal-acceptance! compares it to
    ;; (instant->unix (clock-now)) as a STRING, which would misbehave against an ISO datetime.
    ((invite-contact scope-id inviter invitee label t0-iso t1-iso)
     (with-person scope-id inviter
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((ps  ($ root 'plan-store))
                    ;; scope-wide bare epoch-seconds collided: two invites
                    ;; from DIFFERENT people in one second silently
                    ;; overwrote each other (add-intent/add-proposal are
                    ;; hashmap-set) and the first invitee never saw
                    ;; theirs. The inviter + their own running count
                    ;; disambiguates — the record-purchase pattern.
                    (iid (string-append "inv-" inviter ":"
                                        (number->string (instant->unix (clock-now))) ":"
                                        (number->string
                                         (length (filter (lambda (i)
                                                           (string-prefix? (string-append "inv-" inviter ":")
                                                                           (or (intent-id i) "")))
                                                         ($ ps 'all-intents))))))
                    (pid (string-append "prop-" iid))
                    (lbl (if (and (string? label) (not (string=? label ""))) label "event"))
                    ;; VF: an Intent is one-sided — provider=inviter only; the
                    ;; invitee rides in the proposal's proposed-to and fills the
                    ;; receiver slot at accept (counterparty), avoiding the
                    ;; "Intent cannot have both provider and receiver" constraint.
                    (intent (make-intent #:id iid #:action 'use #:name lbl       ; id action name note image
                       ; input/output/res-inv/res-conf/res-class
                          ; resource/effort/available/minimum qty
                              #:provider inviter                           ; provider receiver(open)
                              #:has-beginning t0-iso #:has-end t1-iso                  ; has-beginning has-end has-point due
                          ; at-location stage state planned-within
 #:in-scope-of (list scope-id)))           ; satisfies in-scope-of finished avail-window
                    (proposal (make-proposal #:id pid #:name lbl #:created (now) ; id name note has-beg has-end unit-based created
                                #:purpose 'offer #:in-scope-of (list scope-id)          ; purpose eligible-location in-scope-of
                                #:publishes (list iid) #:proposed-to (list invitee))))    ; publishes reciprocal proposed-to
               ($ ps 'add-intent intent)
               ($ ps 'add-proposal proposal)
               (success `((proposal . ,pid) (invitee . ,invitee)))))))))

    ;; The invitee accepts a social invite → promotes the event intent to a
    ;; commitment for both. accepting-agent-id is whitelist-validated against the
    ;; proposal's proposed-to (validate-proposal-acceptance!).
    ((accept-invite scope-id agent-id proposal-id)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             ;; counterparty fills the intent's open receiver slot with the
             ;; accepting agent → the event becomes a commitment inviter→invitee.
             ($ ($ root 'plan-store) 'accept-proposal proposal-id
                (list (cons 'receiver agent-id))
                (list (cons 'accepting-agent-id agent-id)))
             (success `((accepted . ,proposal-id))))))))

    ;; ── the offer loop's two doors (commitment-horizon.md: the bounded rung) ──
    ;; A work offer is a DIRECTED proposal with an acceptance window: the
    ;; invitee sees it under their snapshot's `proposals` (the proposed-to
    ;; filter invite-contact already rides), the solve holds its column
    ;; while they decide (live.scm's offer loop), and the horizon gate
    ;; stands at the accept as at every accept.
    ((offer-work scope-id agent-id proc hours when-iso place skill #:optional (until #f))
     (scoped scope-id
       (lambda (root)
         (let ()
           `((proposal . ,(offer-work root
                            `((input-of . ,proc) (effort . ,hours)
                              (when . ,(string-or-false when-iso)) (at-location . ,(string-or-false place))
                              (conforms-to . ,(string-or-false skill))
                              (until . ,(string-or-false until)))
                            agent-id)))))))

    ;; the presentation caller: the LAST solve's work rows walked
    ;; nearest-forcing-first, each deployment suggestion turned into a
    ;; directed offer (live.scm present-offers — ranking pluggable there;
    ;; this door carries the default policy). Self-serve stays open.
    ((present-offers scope-id)
     (scoped scope-id
       (lambda (root)
         (let ((cached (last-solve-ref scope-id)))
           (unless cached
             (error "present-offers: no solve stands for this scope — plan first"))
           `((proposals . ,(present-offers root (cdr cached))))))))

    ;; κ against the lapse and release rates, one window, one clock — the
    ;; empirical read the renegotiation-cadence conjecture has to pass
    ((commitment-drift scope-id #:optional (window-days 7.0) (at #f))
     (scoped scope-id
       (lambda (root)
         (commitment-drift ($ root 'plan-store)
                           #:window-days (if (number? window-days) window-days 7.0)
                           #:at (and (number? at) at)))))

    ;; the regret diagnostic at the accept door: the standing accepts
    ;; priced against the pins-freed counterfactual of the last solve's
    ;; own demand (live.scm accept-regret) — the number a person weighs
    ;; before locking in more. Two solves; an explicit ask, never ambient.
    ((accept-regret scope-id)
     (scoped scope-id
       (lambda (root)
         ;; the standing solve's demand when one stands, else the scope's own
         ;; declared demand (the base of the pair is a solve either way)
         (accept-regret root #:demand (let ((cached (last-solve-ref scope-id))) (if cached (car cached) '()))
                        #:solve (lambda kw (apply plan-fn* root scope-id kw))))))

    ;; what voice displaces, as a total (externality voice-displacement): the standing
    ;; field against the same program at τ = 0, on the last solve's demand,
    ;; both through this scope's one door — the number beside the marginal
    ;; the solve's own alist carries under `voice`. An explicit ask, two solves.
    ((voice-displacement scope-id)
     (scoped scope-id
       (lambda (root)
         (let ((cached (last-solve-ref scope-id)))
           (let* ((tau (governance-policy ($ root 'plan-store) 'voice-tau))
                  (solve-at (settled-solves (lambda kw (apply plan-fn* root scope-id kw))
                                            (list #:demand (if cached (car cached) '()))
                                            `((,tau . (#:voice-tau ,tau)) (0.0 . (#:voice-tau 0.0)))))
                  (met-of (lambda (r) (or (assq-ref r 'met) 0.0))))
             `((tau . ,tau)
               (hours-at-tau . ,(plan-hours (solve-at tau)))
               (hours-at-zero . ,(plan-hours (solve-at 0.0)))
               (moved-hours . ,(voice-displacement solve-at plan-hours tau))
               (moved-met . ,(voice-displacement solve-at met-of tau))
               (parts . ,(let ((v (assq-ref (solve-at tau) 'voice))) (if v (or (assq-ref v 'parts) '()) '())))))))))

    ;; the accepting worker is the PROVIDER (an invite's mirror image, where
    ;; the invitee fills receiver); the scope receives the work
    ((accept-work-offer scope-id agent-id proposal-id)
     (scoped scope-id
       (lambda (root)
         ($ ($ root 'plan-store) 'accept-proposal proposal-id
            (list (cons 'provider agent-id) (cons 'receiver scope-id))
            (list (cons 'accepting-agent-id agent-id)))
         (resolve-scope! scope-id root)             ; the accept re-plans the scope
         `((accepted . ,proposal-id)))))

    ;; the decided rung's withdrawal — retire-need's mirror at the
    ;; commitment layer: the provider releases their own accept, the pin
    ;; drops at the next solve, the satisfied intent reopens as a
    ;; standing declaration (planning.scm release-commitment)
    ((release-commitment scope-id agent-id cid)
     (scoped scope-id
       (lambda (root)
         ($ ($ root 'plan-store) 'release-commitment cid agent-id (instant->unix (clock-now)))
         (resolve-scope! scope-id root)             ; the freed slot re-enters the plan NOW
         `((released . ,cid)))))

    ;; ── skills: an EconomicResource per (agent, skill), moved by EVENTS ──
    ;; The declare/revoke pair is VF's raise/lower (concepts/actions.md):
    ;; a self-declared skill is labour-power formed OUTSIDE the recorded
    ;; economy, so entering it is exactly raise's "beginning balance" case —
    ;; the recorded formation of skills (training, practiced hours) is the
    ;; earned-skills ledger, a different door. Every skill reader takes
    ;; on-hand > 0 as "held", so the events are the whole lifecycle and the
    ;; resource + its history remain across it. A skill lives in the
    ;; observer, so the agent-store's on-agent rail — the labour fold's
    ;; refold trigger — stays quiet on a skill write; the identity re-update
    ;; of the agent record fires it (agents.scm update-agent), and the
    ;; scope's ^labour-pool refolds the new skill set.
    ((declare-skill scope-id agent-id skill-spec-id)
     (with-scope scope-id
       (lambda (root)
         (let ((rid (declare-skill! root agent-id skill-spec-id)))
           ($ ($ root 'agent-store) 'update-agent agent-id (lambda (a) a))
           `(ok . ,rid)))))

    ;; the citizen's own held skills — the roster's reading (on-hand > 0)
    ((my-skills scope-id agent-id)
     (with-scope scope-id
       (lambda (root)
         (success `((skills . ,(skill-specs-for-agent ($ root 'observer)
                                                      agent-id (scope-labour? root))))))))

    ;; raise's inverse: withdrawing the self-declaration lowers the on-hand
    ;; to zero. The resource stays, carrying both events.
    ((revoke-skill scope-id agent-id skill-spec-id)
     (with-scope scope-id
       (lambda (root)
         (let ((rid (revoke-skill! ($ root 'observer) agent-id skill-spec-id)))
           ($ ($ root 'agent-store) 'update-agent agent-id (lambda (a) a))
           `(ok . ,rid)))))

    ;; skill-standing: what the agent has DECLARED, beside what the record
    ;; shows for it — one row per skill that is held or practiced, in the one
    ;; measure every reader of a skill already uses, HOURS:
    ;;   held           on the roster (declare-skill)
    ;;   hours          validated hours — the observer's practiced-hours, the
    ;;                  same recipient-side gate the credit ledger folds, so
    ;;                  Σ hours here is the agent's validated gross
    ;;   competence     where the skill stands today: the record folded through
    ;;                  the skill's own law (skill-law.scm — idle time wears it,
    ;;                  satisfied practice renews it; no law, the ledger itself)
    ;;   events / witnessed / attesters / witnessed-hours
    ;;                  the work-event credentials behind it: how many, how
    ;;                  many reached a witness quorum, co-signed by how many
    ;;                  distinct people, over how many hours
    ;;   pending        ceremonies still collecting: ((count . n) (quorum . k)) …
    ;; A declared skill with no work behind it stands as the citizen's word alone.
    ((skill-standing scope-id agent-id)
     (with-scope scope-id
       (lambda (root)
         (let* ((obs     ($ root 'observer))
                (held    (skill-specs-for-agent obs agent-id (scope-labour? root)))
                (practice (practice-view-of obs (person-observers agent-id)))
                (hours   (practice-view-hours practice agent-id))
                (social  (door-read 'standing scope-id agent-id (map car (roster-entries))))
                (pending (door-read 'outbox agent-id))
                (specs   (or (false-if-exception ($ ($ root 'recipe-store) 'all-resource-specs)) '()))
                (law-of  (lambda (skill)
                           (let ((sp (find (lambda (x) (equal? (resource-specification-id x) skill)) specs)))
                             (and sp (skill-law-of (resource-specification-resource-classified-as sp))))))
                (now     (iso-now))
                (skills  (delete-duplicates (append held (map car hours) (map car social)))))
           (success
            `((standing
               . ,(map (lambda (skill)
                         (let ((ev (or (assoc-ref social skill) '())))
                           `((skill . ,skill)
                             (held . ,(and (member skill held) #t))
                             (hours . ,(or (assoc-ref hours skill) 0))
                             (competence . ,(competence-fold (practice-view-dated practice agent-id skill)
                                                             (law-of skill) #:today now))
                             (events . ,(or (assq-ref ev 'events) 0))
                             (witnessed . ,(or (assq-ref ev 'witnessed) 0))
                             (attesters . ,(or (assq-ref ev 'attesters) 0))
                             (witnessed-hours . ,(or (assq-ref ev 'witnessed-hours) 0))
                             (pending
                              . ,(filter-map
                                  (lambda (r)
                                    (and (equal? (assq-ref r 'skill) skill)
                                         `((count . ,(assq-ref r 'count))
                                           (quorum . ,(assq-ref r 'quorum)))))
                                  pending)))))
                       skills))))))))

    ;; declare-means: self-declare a MEANS OF PRODUCTION you own — the ownership
    ;; a socialization grant needs to project capacity. Seeds an owned
    ;; EconomicResource (primary-accountable = AGENT-ID, conforms-to = SPEC) into
    ;; SCOPE-ID's observer, the sibling of declare-skill for productive means.
    ;; Ownership is self-asserted here; the assertion's credential form is the
    ;; ownership attestation (governance own-means legs) — once one stands over
    ;; a resource, the socialization gates hear only it (%grant-over? +
    ;; title-permits?) and the federation auditor's ownership-coherent? check
    ;; flags a field that contradicts it. A socialize grant only projects if
    ;; issuer == this owner, in field and title alike.
    ;; ── slots: capacity + need as ONE expression (free-association port) ──
    ;; A slot is quantity + unit + place + a recurring time pattern (the
    ;; arcs wire → <availability-window>). A CAPACITY slot is an owned
    ;; <economic-resource> (deterministic id ⇒ re-declaring IS editing);
    ;; a NEED slot is an <intent> with receiver = the citizen — the same
    ;; window field, so matching/feasibility and the labour pools read
    ;; both sides with the machinery that already exists. No new fields:
    ;; note rides note, the emoji rides image, the pattern rides
    ;; availability-window, bounds ride has-beginning/has-end.
    ((declare-means scope-id agent-id spec qty unit location
                    #:optional (arcs-json #f) (note #f) (emoji #f) (name #f) (cats-json #f) (criteria-json #f))
     (with-scope scope-id
       (lambda (root)
         (declare-means-reply root agent-id spec qty unit location
                              arcs-json note emoji name cats-json (criteria-json->alist criteria-json)
                              #:changed! (lambda () (means-changed! scope-id))))))

    ;; ── Payouts: "send N XMR of mine to ⟨address⟩" ───────────────────────
    ;; A member's monero is a CLAIM on the commons' wallet (the shop's claim
    ;; path moves `res-xmr-main` into `res-xmr-main-<aid>` against earned
    ;; credit). A payout is the member's standing INTENT to have the commons
    ;; send some of that claim on-chain to a destination they name — a VF
    ;; `transfer` intent under the reserved prefix "payout:", provider = the
    ;; member, the external address as its at-location, kept in the plan-store so it
    ;; persists with the scope and shows in their slots. No member key is
    ;; ever involved: the wallet is the commons' and its ^wallet-policy is
    ;; the only thing that spends. The runner (monero/payout.scm) reads
    ;; `due-payouts`, moves the coins under the policy, and calls
    ;; `settle-payout` (a VF transfer event out of the member's claim, txid
    ;; on the record) or `fail-payout` (the claim stays whole).
    ((request-payout scope-id agent-id store address xmr due note)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((ps   ($ root 'plan-store))
                    (obs  ($ root 'observer))
                    (rs   ($ root 'recipe-store))
                    (addr (and (string? address) (string-trim-both address)))
                    (q    (cond ((number? xmr) xmr)
                                ((and (string? xmr) (string->number xmr)) => (lambda (n) n))
                                (else 0))))
               (unless (monero-address-plausible? addr)
                 (error "that is not a Monero address" addr))
               (unless (> q 0) (error "amount must be positive" xmr))
               (let* ((owed  (if (and owed-of store) (owed-of rs obs store scope-id agent-id) 0.0))
                      (avail (payout-available obs ps agent-id #:owed owed))
                      ;; the instant plus the member's running count — two asks
                      ;; in one second are two intents
                      (iid   (string-append "payout:" agent-id ":" (iso-now) ":"
                                            (number->string (length (payouts-of ps agent-id))))))
                 (when (> q avail)
                   (error (format #f "you hold ~a XMR claimable; ~a asked" avail q)))
                 ($ ps 'add-intent-silent
                    (make-intent
                     #:id iid #:action 'transfer #:name "send XMR" #:note (string-or-false note) #:image "🪙"
                     #:resource-inventoried-as (payout-source-id agent-id) #:resource-conforms-to %payout-spec
                     #:resource-quantity (make-measure q "XMR")
                     #:provider agent-id #:due (string-or-false due)
                     ;; the destination is a PLACE outside the commons — an
                     ;; intent names one side (VF: provider xor receiver), and
                     ;; the member is the provider; the address rides as
                     ;; at-location, read back by payout->alist
                     #:at-location (string-append "xmr:" addr) #:state "pending" #:in-scope-of '()))
                 (success `((id . ,iid) (available . ,(- avail q)))))))))))

    ;; THE CITIZEN'S ORDER BOOK — the plan's word on each of their wants.
    ;; Three states, one list: ASKED (a `need:aid:spec` consume intent the plan
    ;; has not yet answered with a row), HELD (a claim commitment the plan
    ;; registered for them, plan-claims!, with what remains on it) and TAKEN
    ;; (a row confirmed in full). Each row carries the good's crystallized
    ;; SNLT — the certificate it draws per unit — so the face prices nothing.
    ;; A want with no row says so: the plan held none this solve (the pool had
    ;; none, or the certificate could not carry it); the want stands, and the
    ;; next plan answers again.
    ((my-claims scope-id agent-id)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((obs ($ root 'observer)) (ps ($ root 'plan-store)) (rs ($ root 'recipe-store))
                    (price (lambda (spec) (let ((p (false-if-exception (crystallized-snlt-for-spec rs spec))))
                                            (and (number? p) (finite? p) p))))
                    (mval (lambda (m) (if m (measure-has-numerical-value m) 0)))
                    (rows (filter-map
                           (lambda (fs)
                             (let ((t (claim-cid-terms (fulfillment-state-commitment-id fs))))
                               (and t (equal? (cadr t) agent-id)
                                    (let ((total (mval (fulfillment-state-total-committed fs)))
                                          (done  (mval (fulfillment-state-total-fulfilled fs))))
                                      `((id . ,(fulfillment-state-commitment-id fs))
                                        (spec . ,(car t)) (name . ,(lookup-spec-name rs (car t)))
                                        (place . ,(or (caddr t) "")) (when . ,(or (cadddr t) ""))
                                        (total . ,total) (fulfilled . ,done) (remaining . ,(max 0 (- total done)))
                                        (snlt . ,(price (car t)))
                                        (state . ,(if (fulfillment-state-finished fs) "taken" "held")))))))
                           ($ obs 'all-fulfillments)))
                    (answered (map (lambda (r) (assq-ref r 'spec)) rows))
                    (prefix (need-prefix agent-id))
                    (asked (filter-map
                            (lambda (i)
                              (and (string-prefix? prefix (intent-id i))
                                   (memq (intent-action i) using-up-actions)
                                   (not (intent-finished i))
                                   (not (member (intent-resource-conforms-to i) answered))
                                   (let ((spec (intent-resource-conforms-to i)))
                                     `((id . ,(intent-id i)) (spec . ,spec) (name . ,(lookup-spec-name rs spec))
                                       (place . ,(or (intent-at-location i) "")) (when . ,(or (intent-has-beginning i) ""))
                                       (total . ,(mval (intent-resource-quantity i))) (fulfilled . 0) (remaining . 0)
                                       (snlt . ,(price spec)) (state . "asked")))))
                            ($ ps 'all-intents))))
               (success `((rows . ,(append asked rows))))))))))

    ((my-payouts scope-id agent-id store)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((obs ($ root 'observer)) (rs ($ root 'recipe-store))
                    (owed-list (if (and debts-of store) (debts-of obs store scope-id agent-id) '())))
               (success
                `((available . ,(payout-available obs ($ root 'plan-store) agent-id
                                  #:owed (if (and owed-of store) (owed-of rs obs store scope-id agent-id) 0.0)))
                  (owed . ,owed-list)
                  (payouts . ,(map payout->alist (payouts-of ($ root 'plan-store) agent-id)))))))))))

    ;; only the requester, only while pending — a sent payout is history
    ((retire-payout scope-id agent-id id)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((ps ($ root 'plan-store))
                    (i  ($ ps 'get-intent id)))
               (unless (and i (string-prefix? "payout:" id)) (error "no such payout" id))
               (unless (equal? agent-id (intent-provider i)) (error "not your payout" id))
               (unless (equal? "pending" (intent-state i)) (error "already settled" id))
               ($ ps 'remove-intent id)
               (success `((id . ,id)))))))))

    ;; the runner's read: pending payouts whose due is unset or ≤ NOW-ISO
    ((due-payouts scope-id now-iso)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (success
              (filter-map
               (lambda (i)
                 (and (equal? "pending" (intent-state i))
                      (let ((due (intent-due i)))
                        (or (not due) (string<=? due now-iso)))
                      (payout->alist i)))
               (payouts-of ($ root 'plan-store) #f))))))))

    ;; the runner's writes. SETTLE records the VF transfer out of the member's
    ;; claim (the coins left the commons' wallet; the claim shrinks by exactly
    ;; that), txid on the event and the intent. FAIL leaves the claim whole
    ;; and parks the intent with the reason — the member may retire it and
    ;; ask again.
    ((settle-payout scope-id id txid store)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((ps  ($ root 'plan-store))
                    (obs ($ root 'observer))
                    (rs  ($ root 'recipe-store))
                    (i   (or ($ ps 'get-intent id) (error "no such payout" id))))
               (unless (payout-open? (intent-state i)) (error "already settled" id))
               ;; The ledger records that the coins LEFT — to the chain, as
               ;; one opaque external holder — and never the address: the
               ;; event, its destination record and the txid note reach
               ;; every member's snapshot; the address stays on the private
               ;; payout intent (my-payouts) and the chain itself.
               (let* ((aid  (intent-provider i))
                      (m    (intent-resource-quantity i))
                      (xmr  (measure-has-numerical-value m))
                      ;; what the commons OWED is paid first, via the
                      ;; injected settle-of (economy/debts.scm settle-debts!,
                      ;; which records its own "debt-paid:" events per debt
                      ;; and revokes any fully-paid ones); the claim bears
                      ;; the rest — the ledger then shows the coins leaving
                      ;; the member's claim for the remainder
                      (left (if (and settle-of store) (settle-of rs obs store scope-id aid xmr) xmr))
                      (owed-part (- xmr left)))
                 (when (> owed-part 1e-12)
                   ($ obs 'record-event
                      (make-economic-event
                       #:id (string-append "payout-owed:" txid) #:action 'transfer
                       #:resource-inventoried-as "res-xmr-main" #:to-resource-inventoried-as "res-xmr-chain"
                       #:resource-conforms-to %payout-spec #:resource-classified-as '("currency" "external")
                       #:provider scope-id #:receiver "monero-chain"
                       #:resource-quantity (make-measure owed-part "XMR") #:has-point-in-time (iso-now) #:created (iso-now)
                       #:note (string-append "reimbursement paid on-chain, txid " txid))))
                 (when (> left 1e-12)
                   ($ obs 'record-event
                      (make-economic-event
                       #:id (string-append "payout-sent:" txid) #:action 'transfer
                       #:resource-inventoried-as (payout-source-id aid)
                       #:to-resource-inventoried-as "res-xmr-chain"
                       #:resource-conforms-to %payout-spec #:resource-classified-as '("currency" "external")
                       #:provider aid #:receiver "monero-chain"
                       #:resource-quantity (make-measure left "XMR") #:has-point-in-time (iso-now) #:created (iso-now)
                       #:note (string-append "sent on-chain, txid " txid))))
                 (payout-restate! ps i (string-append "sent:" txid) #t)
                 (success `((id . ,id) (txid . ,txid))))))))))

    ;; the runner's claim on a payout before the coins move: "pending" →
    ;; "sending", so a second tick never sends it twice. Only a pending one.
    ((begin-payout scope-id id)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((ps ($ root 'plan-store))
                    (i  (or ($ ps 'get-intent id) (error "no such payout" id))))
               (unless (equal? "pending" (intent-state i)) (error "not pending" id))
               (payout-restate! ps i "sending" #f #:began (iso-now))
               (success `((id . ,id)))))))))

    ;; the reconciler's read: payouts that began moving and were never
    ;; settled — a gateway that died mid-transfer leaves these
    ((sending-payouts scope-id)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (success
              (filter-map (lambda (i) (and (equal? "sending" (intent-state i)) (payout->alist i)))
                          (payouts-of ($ root 'plan-store) #f))))))))

    ;; the transactions that have already settled a payout: a wallet row that
    ;; paid one payout is not evidence for another
    ((settled-payout-txids scope-id)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (success
              (filter-map (lambda (i)
                            (let ((st (intent-state i)))
                              (and (string? st) (string-prefix? "sent:" st) (substring st 5))))
                          (payouts-of ($ root 'plan-store) #f))))))))

    ;; the reconciler found no matching outgoing transfer inside the grace
    ;; window: park it as UNSETTLED — still reserving the claim — for an
    ;; operator to settle (with the txid) or fail by hand. Never "failed" on
    ;; its own: the coins may have moved.
    ((unsettle-payout scope-id id reason)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((ps ($ root 'plan-store))
                    (i  (or ($ ps 'get-intent id) (error "no such payout" id))))
               (unless (equal? "sending" (intent-state i)) (error "not sending" id))
               (payout-restate! ps i (string-append "unsettled:" (if (string? reason) reason "?")) #f)
               (success `((id . ,id)))))))))

    ((fail-payout scope-id id reason)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((ps ($ root 'plan-store))
                    (i  (or ($ ps 'get-intent id) (error "no such payout" id))))
               (unless (payout-open? (intent-state i)) (error "already settled" id))
               (payout-restate! ps i (string-append "failed:" (if (string? reason) reason "?")) #t)
               (success `((id . ,id)))))))))

    ;; ── Purchases for the commons, and what the commons then owes ──────────
    ;; A member buys a thing the commons wanted with their own money and
    ;; records it: the good is RAISED into the commons (provider = the member,
    ;; the receipt on the event). What the commons then owes them back is a
    ;; DEBT (economy/debts.scm) — minted through governance's own
    ;; accept-reimbursement (governance/scope.scm),
    ;; a ^scope method, because minting a debt needs the scope's own signature;
    ;; this service only states whether the purchase fulfils a plan the commons
    ;; already committed to (PLANNED?, informational — the plan is the
    ;; authorisation the lobby checks before it calls accept-reimbursement) —
    ;; it never mints the debt itself. A donation records the raise and owes
    ;; nothing. Settlement is a payout (XMR, at the acquisition-SNLT ratio) —
    ;; see payout-available / settle-payout.
    ;;
    ;; THE RAISE BINDS to the plan records that already exist, rather than
    ;; passing #f where its VF edges belong: `fulfills` names the live
    ;; `produce` commitment for this spec (the same record the PLANNED? scan
    ;; reads — kept now, not collapsed to a boolean), `satisfies` names an
    ;; open declared NEED for it (declare-need's consume-intent), and both
    ;; are registered on the observer first (register-commitment /
    ;; register-intent state the target and keep what the events already
    ;; show) so fulfilment and satisfaction read this very event. The whole linkage
    ;; machinery is the one work and journeys already use; nothing new is
    ;; minted — a purchase corroborates the demand rail, it never duplicates
    ;; it. The event id returns to the caller so a purchase-claim can carry
    ;; it as `triggered-by` (VF Claim.triggeredBy IS an EconomicEvent id):
    ;; raise → claim → debt, one provenance chain on existing fields.
    ((record-purchase scope-id agent-id spec qty unit money-spec cost where note receipt #:optional (donation? #f))
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((obs  ($ root 'observer))
                    (ps   ($ root 'plan-store))
                    (q    (if (and (number? qty) (> qty 0)) qty 1))
                    (c    (cond ((number? cost) cost)
                                ((and (string? cost) (string->number cost)) => (lambda (n) n))
                                (else 0)))
                    (donation? (and donation? #t))
                    (u    (or (string-or-false unit) %count-unit))
                    (stamp (iso-now))
                    ;; the instant alone is second-precision (iso-now) — two
                    ;; purchases of the same spec by the same agent within one
                    ;; second collide on an identical rid, and seed-resource's
                    ;; hashmap-set silently overwrites the first purchase's
                    ;; resource entirely (verified live: the second purchase's
                    ;; note replaces the first's under the same key). The
                    ;; running count of this agent's own existing purchases of
                    ;; this spec disambiguates, the same pattern request-payout
                    ;; already uses a few hundred lines above.
                    (prior (length (filter (lambda (r) (string-prefix? (string-append "bought:" agent-id ":" spec ":")
                                                                        (economic-resource-id r)))
                                           ($ obs 'conforming-resources spec))))
                    (rid  (string-append "bought:" agent-id ":" spec ":" stamp ":" (number->string prior)))
                    (eid  (string-append "purchase:" rid))
                    (loc  (string-or-false where))
                    ;; the plan records this purchase corroborates, if any
                    (planned-c (find (lambda (k)
                                       (and (not (commitment-finished k))
                                            (same-flow? 'produce (commitment-action k))   ; an acquisition fulfils a produce
                                            (equal? spec (commitment-resource-conforms-to k))))
                                     ($ ps 'all-commitments)))
                    (need-i (find (lambda (i)
                                    (and (not (intent-finished i))
                                         (memq (intent-action i) using-up-actions)
                                         (equal? spec (intent-resource-conforms-to i))))
                                  ($ ps 'all-intents))))
               (unless (string-or-false spec) (error "what was bought?"))
               (unless (or donation? (> c 0)) (error "what did it cost?"))
               ;; arm tracking BEFORE the event lands, so this raise advances
               ;; the states; guarded — registration resets a tracked state
               (when (and planned-c (not ($ obs 'get-fulfillment (commitment-id planned-c))))
                 ($ obs 'register-commitment planned-c))
               (when (and need-i (not ($ obs 'get-satisfaction (intent-id need-i))))
                 ($ obs 'register-intent need-i))
               ;; the good, held by the commune from the moment it is recorded
               ($ obs 'record-resource
                  (make-economic-resource #:id rid #:name (or (string-or-false note) spec) #:note (string-or-false note) #:tracking-identifier (fresh-label obs)
                                          #:conforms-to spec #:classified-as '("bought") #:accounting-quantity (make-measure 0 u) #:onhand-quantity (make-measure 0 u)
                                          #:current-location loc #:primary-accountable scope-id))
               ($ obs 'record-event
                  (make-economic-event
                   #:id eid #:action 'raise #:resource-inventoried-as rid #:resource-conforms-to spec #:resource-classified-as '("bought")
                   #:provider agent-id #:receiver scope-id
                   #:resource-quantity (make-measure q u) #:has-point-in-time stamp #:created stamp #:to-location loc
                   #:fulfills (and planned-c (commitment-id planned-c))
                   #:satisfies (and need-i (intent-id need-i))
                   #:note (string-append (if donation? "donated" "bought")
                                  (if (string-or-false receipt) (string-append " · receipt " receipt) ""))))
               ;; whether the commons owes — unless it was a gift
               (if donation?
                   (success `((resource . ,rid) (event . ,eid) (owed . #f)))
                   (success `((resource . ,rid) (event . ,eid)
                              (cost . ,c) (money-spec . ,(or (string-or-false money-spec) "spec-eur"))
                              (planned? . ,(and planned-c #t))
                              (fulfills . ,(and planned-c (commitment-id planned-c)))
                              (satisfies . ,(and need-i (intent-id need-i))))))))))))

    ;; retire-means: withdraw the offer — a `lower` to zero, the record and
    ;; its history standing (readers take on-hand > 0 as offered), the
    ;; mirror of retire-need at the resource layer.
    ((retire-means scope-id agent-id spec)
     (with-scope scope-id
       (lambda (root)
         (let* ((obs ($ root 'observer))
                (rid (means-id agent-id spec))
                (r   ($ obs 'get-resource rid)))
           (when r (lower-resource! obs agent-id r "means retired"))
           (means-changed! scope-id)
           `(ok . ,rid)))))
    ;; the declaration-time read: what one unit of SPEC currently displaces
    ;; elsewhere in the plan, off the scope's LAST solve's duals (its
    ;; `good-pulls` μ — solve/externality.scm `marginal-displacement` over
    ;; provenance-trace's `make-pull-of`). Shown BEFORE a citizen states a kind
    ;; and level, so what asking moves is visible while the ask is still being
    ;; shaped. No re-solve, no identity, nothing written; a scope with no
    ;; cached solve reads nothing (read? #f) — the same silence spec-met keeps.
    ((need-displacement scope-id spec qty)
     (catch-as-failure
       (lambda ()
         (let* ((cached   (last-solve-ref scope-id))
                (pull-of (and cached (make-pull-of (cdr cached))))
                (mu       (and pull-of (pull-of spec)))
                (q        (if (and (number? qty) (> qty 0)) (exact->inexact qty) 1.0))
                ;; the burn-meter's read of the same spec: how often it was
                ;; read across the kept solves and the mean of what it
                ;; moved — the "lately" beside the live read
                (lately (and mu
                             (let ((s (find (lambda (r) (equal? (assq-ref r 'spec) spec))
                                            (assq-ref (moved-summary (externality-history-ref scope-id))
                                                      'specs))))
                               (and s `((solves . ,(assq-ref s 'solves))
                                        (mean-moved . ,(assq-ref s 'mean-moved))))))))
           ;; the HONESTY RADIUS, read off the same solve: the certificate's
           ;; strong-convexity modulus σ bounds how far ANY rewrite of a
           ;; citizen's asks can move the plan — ‖Δplan‖ ≤ 2·W·v/σ
           ;; (deviation_gain_le, InTheLarge.lean; W = one whole hand,
           ;; reported at v = 1 and scaled by the reader's voice). The same
           ;; σ, composed with the certificate's OWN residual ‖r‖ (never
           ;; zero — the solver reports an ε-KKT point, not an exact one),
           ;; bounds how far the certified plan can already sit from the
           ;; exact optimum: ‖r‖/σ (dist_from_optimum_of_curvature_gap,
           ;; InTheLarge.lean) — the honest floor beneath the radius above,
           ;; shown alongside it rather than folded silently in. The
           ;; certificate states both bounds, per solve.
           ;; L_Φ — the term map's own Lipschitz constant. The shipped cap
           ;; shape emits an owned want through a zero-labour delivery
           ;; column whose own coefficient on the good is exactly 1.0
           ;; (claim-recipes, live.scm), so the wall's whole
           ;; coefficient vector has norm 1 and L_Φ is exactly
           ;; 1/cap-scale-of(spec) — the shown radius needed no correction
           ;; at the catalogue's default scale of 1.0, and now carries the
           ;; exact one where a spec's scale is governed away from it. The
           ;; `des` shape's squared-gap term has a different, unproven
           ;; L_Φ, so the correction applies only under the cap default.
           (let* ((cert  (and cached (or (assq-ref (cdr cached) 'certificate) '())))
                  (sigma (assq-ref cert 'sigma))
                  (rnorm (assq-ref cert 'residual))
                  (lphi  (if (want-as-cap?) (/ 1.0 (cap-scale-of spec)) 1.0))
                  (honesty (and (number? sigma) (> sigma 0)
                                `((sigma . ,sigma)
                                  (l-phi . ,lphi)
                                  (radius-whole-hand . ,(/ (* 2.0 lphi *desire-w0*) sigma))
                                  ,@(if (and (number? rnorm) (>= rnorm 0))
                                        `((solve-tolerance . ,(/ rnorm sigma)))
                                        '())))))
             (success
              (if mu
                  `((read? . #t) (per-unit . ,mu)
                    (moved . ,(marginal-displacement pull-of (list (cons spec q))))
                    ,@(if lately `((lately . ,lately)) '())
                    ,@(if honesty `((honesty . ,honesty)) '()))
                  `((read? . #f)
                    ,@(if honesty `((honesty . ,honesty)) '())))))))))

    ;; the burn-meter entire: the externality display accumulated per solve
    ;; (note-externalities!, one snapshot per landing) summarized as the
    ;; scope's moved-distribution — stage 0's calibration data, and the
    ;; scope's measured VCG bill (truth-telling.md). A read of standing
    ;; metadata; nothing re-solves.
    ((externality-history scope-id)
     (catch-as-failure
       (lambda ()
         (success (moved-summary (externality-history-ref scope-id))))))

    ;; the scope ratifies SPEC as KIND — "floor" (a right), "held" (a need
    ;; never zeroed) — recorded with the ratifier's AID; "des" withdraws the
    ;; grant (a want needs none). Who may ratify is the scope's own rite; this
    ;; door names who did.
    ((ratify-kind scope-id agent-id spec kind)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((k (kind-string->symbol kind))
                    (rest (filter (lambda (g) (not (equal? (car g) spec)))
                                  (ratified-kinds-ref root))))
               (ratified-kinds-set!
                root
                (if (eq? k 'des)
                    rest
                    (cons (cons spec `((kind . ,k) (by . ,agent-id) (at . ,(iso-now))))
                          rest)))
               (success `((spec . ,spec) (kind . ,(symbol->string k))))))))))
    ;; ── stage 3: needs are facts — the audit of a ratified kind ────────────
    ;; A held or floor row is checkable ex post: what the observer saw its
    ;; citizen take of the spec since the grant, against what they declared.
    ;; Each row is examined with Becker's probability π = gain/consequence
    ;; (audit.scm): the gain the meter read for the spec, the consequence
    ;; the scope's factor K times that (opts `consequence-factor`, default
    ;; 1 ⇒ every row examined). A padded verdict withdraws the grant through
    ;; the one ratification door; every verdict is recorded beside the
    ;; grants as plan-store meta "audits", the auditor named by AID.
    ((audit-kinds scope-id agent-id #:optional (options #f))
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((o      (or options '()))
                    (k      (let ((v (assq-ref o 'consequence-factor))) (if (and (number? v) (> v 0)) v 1)))
                    (tol    (let ((v (assq-ref o 'tolerance))) (if (number? v) v 0.25)))
                    (today  (substring (iso-now) 0 10))
                    (obs    ($ root 'observer))
                    (ps     ($ root 'plan-store))
                    (grants (ratified-kinds-ref root))
                    (moved  (assq-ref (moved-summary (externality-history-ref scope-id)) 'specs))
                    (gain-of (lambda (spec)
                               (let ((r (find (lambda (r) (equal? (assq-ref r 'spec) spec)) moved)))
                                 (and r (assq-ref r 'mean-moved)))))
                    (rows   (filter (lambda (i)
                                      (and (string? (intent-id i)) (need-id? (intent-id i))
                                           (not (intent-finished i)) (intent-receiver i)
                                           (assoc (intent-resource-conforms-to i) grants)
                                           (memq (tension-kind-of (intent-resource-classified-as i)) '(held floor))))
                                    ($ ps 'all-intents)))
                    (findings
                     (filter-map
                      (lambda (i)
                        (let* ((spec (intent-resource-conforms-to i)) (who (intent-receiver i))
                               (g    (assoc-ref grants spec))
                               (gain (gain-of spec))
                               (pi   (audit-rate gain (and gain (* k gain))))
                               (m    (or (intent-resource-quantity i) (intent-effort-quantity i)))
                               (declared (or (and m (measure-has-numerical-value m)) 0)))
                          (and (< (audit-draw spec who today) pi)
                               (let* ((observed (observed-of (person-events who) spec who
                                                             #:since (assq-ref g 'at)))
                                      (verdict  (audit-verdict declared observed #:tolerance tol)))
                                 `((spec . ,spec) (who . ,who) (kind . ,(symbol->string (assq-ref g 'kind)))
                                   (declared . ,(exact->inexact declared)) (observed . ,(exact->inexact observed))
                                   (verdict . ,(symbol->string verdict)) (rate . ,pi)
                                   (by . ,agent-id) (at . ,(iso-now)))))))
                      rows)))
               ;; a padded row withdraws its grant — the same door that gave it
               (for-each (lambda (f)
                           (when (equal? (assq-ref f 'verdict) "padded")
                             (ratified-kinds-set! root (filter (lambda (g) (not (equal? (car g) (assq-ref f 'spec))))
                                                              (ratified-kinds-ref root)))))
                         findings)
               ;; the WANTS' pass — the cap rule leaves quantities nothing to
               ;; buy, so the one residue is the conduit: a citizen's own good
               ;; delivered well above what they took (pad-and-gift). Read off
               ;; the same solve the burn-meter prices and the same events the
               ;; kinds' pass reads; recorded, never acted on mechanically —
               ;; a conduit is the table's conversation, not a withdrawal.
               (let* ((cached (last-solve-ref scope-id))
                      (mat    (and cached (solve-part cached 'material)))
                      (conduits
                       (if (not (pair? mat)) '()
                           (filter-map
                            (lambda (m)
                              (let* ((g (row-spec m))
                                     (o (and (string? g) (memq (row-action m) creating-actions) (spec-owner g))))
                                (and o
                                     (let* ((spec (car o)) (who (cdr o))
                                            (delivered (abs (or (row-quantity m) 0)))
                                            (consumed  (observed-of (person-events who) spec who))
                                            (v (conduit-verdict delivered consumed #:tolerance tol)))
                                       (and (eq? v 'conduit)
                                            `((spec . ,spec) (who . ,who) (kind . "conduit")
                                              (declared . ,(exact->inexact delivered))
                                              (observed . ,(exact->inexact consumed))
                                              (verdict . "conduit") (rate . 1.0)
                                              (by . ,agent-id) (at . ,(iso-now))))))))
                            mat))))
                 (set! findings (append findings conduits)))
               ($ ps 'set-meta "audits"
                  (list (cons 'findings (append findings
                                                (or (and=> ($ ps 'get-meta "audits") (lambda (r) (assq-ref r 'findings))) '())))))
               (success `((examined . ,(length findings))
                          (padded . ,(count (lambda (f) (equal? (assq-ref f 'verdict) "padded")) findings))
                          (findings . ,findings)))))))))
    ((audits scope-id)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (success `((findings . ,(or (and=> ($ ($ root 'plan-store) 'get-meta "audits")
                                                (lambda (r) (assq-ref r 'findings)))
                                         '())))))))))
    ((ratified-kinds scope-id)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (success
              `((grants . ,(map (lambda (g)
                                  `((spec . ,(car g))
                                    (kind . ,(symbol->string (assq-ref (cdr g) 'kind)))
                                    (by . ,(assq-ref (cdr g) 'by))
                                    (at . ,(assq-ref (cdr g) 'at))))
                                (ratified-kinds-ref root))))))))))

    ;; NEED slot: an <intent> with receiver = the citizen. Deterministic id
    ;; ("need:AID:SPEC") ⇒ re-declaring IS editing (remove + add); the
    ;; window keeps a promoted intent never-finished (planning.scm), i.e. a
    ;; STANDING order — the plan provisions it; the shop's claim is only
    ;; the fallback when communal provision can't satisfy it.
    ((declare-need scope-id agent-id spec qty unit location arcs-json note emoji from until
                   #:optional (name #f) (cats-json #f) (criteria-json #f) (need-kind #f) (voice 0))
     (with-scope scope-id
       (lambda (root)
         (declare-need-reply root agent-id spec qty unit location arcs-json note emoji from until
                             name cats-json (criteria-json->alist criteria-json) need-kind voice
                             #:changed! (lambda () (slots-changed! scope-id))))))

    ;; the citizen's slots, both kinds, one wire: quantity/unit/place/note/
    ;; emoji + the arcs of the availability-window. Zero-qty means are
    ;; retired declarations and are filtered out.
    ((my-slots scope-id agent-id)
     (with-scope scope-id
       (lambda (root)
         (my-slots-reply root agent-id
                         #:met-of (met-of-scope root scope-id)
                         #:criteria-of (lambda (r) (means-criteria scope-id root r))))))

    ;; ── Our: the fold's reading at a scope ─────────────────────────────────
    ;; A need is declared once, by a person (`need:AID:SPEC`). What a scope
    ;; holds is the SUM — the ^demand-node's cells, (spec place from until
    ;; kind) → qty, with no one's name in them — and capacity the same way,
    ;; the ^means-pool's (spec . place) → unit-hours/day. This is what the share
    ;; bar's "Our Needs / Our Offers" lists: the scope's want as one fact per
    ;; cell, never the roster behind it. HOME-SCOPE-ID is where AGENT-ID's own
    ;; leaf lives, so each cell carries `mine` — the asker's share of the sum
    ;; — while every other contribution stays folded.
    ((our-slots scope-id home-scope-id agent-id)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((dn    (node-of scope-id nodes-demand))
                    (mn    (node-of scope-id nodes-means))
                    (cells (or (and dn (false-if-exception ($ dn 'cells))) '()))
                    (caps  (or (and mn (false-if-exception ($ mn 'cells))) '()))
                    ;; the asker's own needs are read where they are written: their home
                    (home  (roster-ref (or (home-scope-of agent-id) home-scope-id)))
                    (home-of (and home (federation-home-of home)))
                    (nprefix (need-prefix agent-id))
                    (mprefix (means-prefix agent-id))
                    (own-needs (if home (%needs-of-plan-store ($ home 'plan-store)) '()))
                    (mine-cells
                     (sum-cells
                      (append-map (lambda (i) (%need-cells i home-of))
                                  (filter (lambda (i) (string-prefix? nprefix (intent-id i)))
                                          own-needs))))
                    (mine-caps
                     (if home
                         (capacity-cells
                          (filter (lambda (r) (string-prefix? mprefix (economic-resource-id r)))
                                  ($ ($ home 'observer) 'all-resources)))
                         '()))
                    ;; the unit a spec is asked in, read off the leaves this
                    ;; service can see (the scope's own and the asker's home);
                    ;; a cell is a quantity, the unit is the spec's
                    (mq (lambda (m acc) (if m (acc m) #f)))
                    (units (make-hash-table))
                    (_ (for-each
                        (lambda (i)
                          (let ((u (mq (or (intent-resource-quantity i) (intent-effort-quantity i))
                                       measure-has-unit)))
                            (when u (hash-set! units (intent-resource-conforms-to i) u))))
                        (append own-needs (%needs-of-plan-store ($ root 'plan-store)))))
                    (needs
                     (filter-map
                      (lambda (c)
                        (let ((p (%demand-key-parts (car c))))
                          (and (not (list-ref p 5))          ; the Σw·q twin is a weight, not a want
                               `((spec    . ,(list-ref p 0))
                                 (where   . ,(list-ref p 1))
                                 (from    . ,(list-ref p 2))
                                 (until   . ,(list-ref p 3))
                                 (tension . ,(symbol->string (list-ref p 4)))
                                 (qty     . ,(cdr c))
                                 (unit    . ,(hash-ref units (list-ref p 0) %count-unit))
                                 (mine    . ,(or (assoc-ref mine-cells (car c)) 0))))))
                      cells))
                    (means
                     (map (lambda (c)
                            `((spec  . ,(caar c))
                              (where . ,(cdar c))
                              (qty   . ,(cdr c))
                              (unit  . "hours/day")
                              (mine  . ,(or (assoc-ref mine-caps (car c)) 0))))
                          caps)))
               (success `((needs . ,needs) (means . ,means)))))))))

    ;; retire a need slot: the intent goes away entirely (a standing order
    ;; withdrawn). Guarded by the deterministic id, so a citizen can only
    ;; retire their own.
    ((retire-need scope-id agent-id spec)
     (with-scope scope-id
       (lambda (root)
         (let ((iid (need-id agent-id spec)))
           ($ ($ root 'plan-store) 'remove-intent iid)
           (slots-changed! scope-id)
           `(ok . ,iid)))))

    ;; the SCOPE's slot pool, for the map: every citizen's standing needs (the
    ;; need markers and hull tints), and the means the commune holds by grant
    ;; — both LIVE. The needs are the plan-store's intents; the means are the
    ;; custody projection pool-of derives off the store right now, so a grant
    ;; issued a moment ago is a 🏠 a moment ago and a recalled one is gone.
    ;; What a solve alone can say — how occupied each slot came out, `drawn`
    ;; — is joined in from the last solve by id (0 for a slot no solve has
    ;; seen yet); the allocation waits for the solve, the pool never does.
    ;; A merely DECLARED private means never appears here: what the commons
    ;; sees is what stands in the commons (my-slots stays the owner's view).
    ((slots-at scope-id)
     (with-scope scope-id
       (lambda (root)
         (let ((cached (last-solve-ref scope-id)))
           (slots-at-reply root
                           #:met-of (met-of-scope root scope-id)
                           #:solved (or (and cached (assq-ref (cdr cached) 'socialized-slots)) '())
                           #:pool (and pool-of (pool-of root scope-id)))))))

    ;; the ring's read: every standing need in the scope scored against every
    ;; declared means, by classification affinity (matching/affinity.scm) over
    ;; TREE — the folksonomy template the lobby resolved through the caller's
    ;; lens, so "what matches" is read through the same cut the spine shows.
    ;; Unlike slots-at (custody: what stands IN the commons), this reads ALL
    ;; declared means: matching is introduction, not provision — it tells two
    ;; people they should talk, it moves nothing. A slot's terms are its own
    ;; cats ∪ its spec's catalog classification (cat-terms expands the legacy
    ;; slash-paths into the template's flat segment ids); the time dimension
    ;; scores over the REAL availability-windows with the machinery matching/
    ;; availability.scm already has.
    ;; the family face: a household purse split across its members' needs by
    ;; harmony ((playnet doors family solve) — the same solve the planner test
    ;; pins). NEEDS-JSON is the dial's list of {person,what,cost,want,level};
    ;; the family is the scope where the person is still known, so the rows
    ;; come back keyed per member. No AID and no scope: the purse and the needs
    ;; are the face's own statement, the solve is a fresh world.
    ;; MEMBERS-JSON, when given, is the household's own consumer voice (§The
    ;; credit identity, family-voice-of): each declared member's capacity to
    ;; labour and hours contributed this week. Absent (the pre-existing
    ;; 4-arg call) or empty, every owner reads as an equal citizen — the
    ;; solve is unchanged from before.
    ((family-split needs-json purse labour-h weighted? #:optional (members-json "[]") (per-citizen-hours 40.0))
     (catch-as-failure
       (lambda ()
         (success (family-split (family-needs-of-json needs-json) purse
                                #:weighted? weighted? #:labour-h labour-h
                                #:members (family-members-of-json members-json)
                                #:per-citizen-hours per-citizen-hours)))))
    ;; the same face asked backwards: what the week would take — euros and
    ;; hours beyond the purse and the hours on hand — for rights, then needs,
    ;; then wants held as walls (family-bills, docs/planning/socialization/three-bills.md).
    ((family-bills needs-json purse labour-h weighted? eur-per-hour #:optional (members-json "[]") (per-citizen-hours 40.0))
     (catch-as-failure
       (lambda ()
         (success (family-bills (family-needs-of-json needs-json) purse
                                #:weighted? weighted? #:labour-h labour-h #:eur-per-hour eur-per-hour
                                #:members (family-members-of-json members-json)
                                #:per-citizen-hours per-citizen-hours)))))
    ;; the same face's externality display: beside each held/des row, the euros
    ;; the OTHER members would have received had the row not been asked — the
    ;; table's instrument, shown before any mechanism charges for a declaration.
    ((family-externalities needs-json purse labour-h weighted? #:optional (members-json "[]") (per-citizen-hours 40.0))
     (catch-as-failure
       (lambda ()
         (success (family-externalities (family-needs-of-json needs-json) purse
                                        #:weighted? weighted? #:labour-h labour-h
                                        #:members (family-members-of-json members-json)
                                        #:per-citizen-hours per-citizen-hours)))))

    ((match-slots scope-id tree)
     (with-scope scope-id
       (lambda (root)
         (catch-as-failure
           (lambda ()
             (let* ((ps  ($ root 'plan-store))
                    (obs ($ root 'observer))
                    (rs  ($ root 'recipe-store))
                    (spec-cats
                     (let ((t (make-hash-table)))
                       (for-each
                        (lambda (s)
                          (hash-set! t (resource-specification-id s)
                                     (or (resource-specification-resource-classified-as s)
                                         '())))
                        (or (false-if-exception ($ rs 'all-resource-specs)) '()))
                       t))
                    (windows (make-hash-table))    ; row id → availability-window
                    (mq (lambda (m acc) (if m (acc m) #f)))
                    (row-cats (lambda (own spec)
                                (cat-terms (or own '())
                                           (hash-ref spec-cats (or spec "") '()))))
                    (needs
                     (filter-map
                      (lambda (i)
                        (and (need-id? (intent-id i))
                             (not (intent-finished i))
                             (begin
                               (hash-set! windows (intent-id i)
                                          (intent-availability-window i))
                               (cons (cons 'cats
                                           (row-cats (without-tension-terms (intent-resource-classified-as i))
                                                     (intent-resource-conforms-to i)))
                                     (need-slot-row i root #:met-of (met-of-scope root scope-id))))))
                      ($ ps 'all-intents)))
                    (means
                     (filter-map
                      (lambda (r)
                        (let ((q (or (mq (economic-resource-onhand-quantity r)
                                         measure-has-numerical-value) 0)))
                          (and (means-id? (economic-resource-id r))
                               (> q 0)
                               (begin
                                 (hash-set! windows (economic-resource-id r)
                                            (economic-resource-availability-window r))
                                 `((id    . ,(economic-resource-id r))
                                   (spec  . ,(economic-resource-conforms-to r))
                                   (name  . ,(or (economic-resource-name r)
                                                 (economic-resource-conforms-to r)))
                                   (emoji . ,(economic-resource-image r))
                                   (note  . ,(economic-resource-note r))
                                   (owner . ,(economic-resource-primary-accountable r))
                                   (qty   . ,q)
                                   (unit  . ,(or (mq (economic-resource-onhand-quantity r)
                                                     measure-has-unit) %count-unit))
                                   (where . ,(economic-resource-current-location r))
                                   (cats  . ,(row-cats (economic-resource-classified-as r)
                                                       (economic-resource-conforms-to r)))
                                   (criteria . ,(means-criteria scope-id root r))
                                   (arcs  . ,(window->arcs
                                              (economic-resource-availability-window r))))))))
                      ($ obs 'inventory)))
                    ;; both windowed → do they overlap; one unwindowed → unknown
                    ;; (0.5 abstains softly, exactly the prototype's rule)
                    (time-score
                     (lambda (n c)
                       (let ((wn (hash-ref windows (assq-ref n 'id) #f))
                             (wc (hash-ref windows (assq-ref c 'id) #f)))
                         `((time . ,(if (and wn wc)
                                        (if (catch #t
                                              (lambda ()
                                                (availability-windows-overlap? wn wc))
                                              (lambda _ #t))
                                            1.0 0)
                                        0.5))))))
                    ;; the eligibility rules, BILATERALLY: the need's rule over
                    ;; the offer's side and the offer's over the need's; a lock
                    ;; either way is a zero on the `eligible` dimension, which
                    ;; compose-scores treats as a veto. Divisibility rides the
                    ;; same veto: an offer smaller than the need's smallest
                    ;; useful piece is not a match. The context a rule reads
                    ;; about the OTHER side: who they are; how I know them
                    ;; (the `knows` reading: my contact book's groups and my
                    ;; signed vouches, the same reading the steward gate asks;
                    ;; an agent-relationship I am the subject of recognizes
                    ;; them too; unknown denies a min-recognition clause); the
                    ;; scope; the
                    ;; skills they declared; how far their place is from mine
                    ;; (both places resolved through the scope's spatial
                    ;; things; unknown when either has no coordinates).
                    (as  ($ root 'agent-store))
                    (sts ($ root 'spatial-thing-store))
                    (knows? (lambda (me other)
                              (and me other
                                   (any (lambda (r) (equal? (agent-relationship-object r) other))
                                        (or (false-if-exception ($ as 'relationships-as-subject me)) '())))))
                    (latlon (lambda (place)
                              (let ((st (and (string? place) (not (string-null? place))
                                             (false-if-exception ($ sts 'get-location place)))))
                                (and st (spatial-thing-lat st) (spatial-thing-long st)
                                     (cons (spatial-thing-lat st) (spatial-thing-long st))))))
                    (km-between (lambda (a b)
                                  (let ((p (latlon a)) (q (latlon b)))
                                    (and p q (haversine-distance (car p) (cdr p) (car q) (cdr q))))))
                    (side (lambda (me other my-place their-place)
                            (context #:aid other
                                     #:recognition (and (knows? me other) 1.0)
                                     #:knows (and knows-of me other
                                                  (false-if-exception (knows-of me other)))
                                     #:scopes (list scope-id)
                                     #:skills (and other (agent-skills obs other))
                                     #:distance-km (km-between my-place their-place))))
                    (eligible
                     (lambda (n c)
                       (let* ((cn (assq-ref n 'criteria)) (cc (assq-ref c 'criteria))
                              (need-min (criteria-ref cn 'min-atomic-size))
                              (ok (and (rule-passes? (criteria-ref cn 'filter-rule)
                                                     (side (assq-ref n 'who) (assq-ref c 'owner)
                                                           (assq-ref n 'where) (assq-ref c 'where)))
                                       (rule-passes? (criteria-ref cc 'filter-rule)
                                                     (side (assq-ref c 'owner) (assq-ref n 'who)
                                                           (assq-ref c 'where) (assq-ref n 'where)))
                                       (or (not (number? need-min))
                                           (>= (or (assq-ref c 'qty) 0) need-min)))))
                         `((eligible . ,(if ok #f 0))
                           ;; ⭐ the offer's priority for THIS need's person
                           ;; (its distribution, else its flat priority) —
                           ;; a dimension that abstains when it has no say
                           (priority . ,(priority-for cc (assq-ref n 'who)))))))
                    (matches (match-pool (chain-index tree) needs means
                                         #:threshold 0.5 #:limit 20
                                         #:extra (lambda (n c)
                                                   (append (time-score n c) (eligible n c))))))
               (success `((needs . ,needs)
                          (means . ,means)
                          (matches . ,matches)))))))))))
