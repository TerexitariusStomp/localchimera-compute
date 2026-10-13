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
  #:use-module (playnet solve federation-solve)
  #:use-module ((playnet utils host) #:select (hash-get-handle))
  #:use-module (playnet doors planner records)
  #:use-module (playnet doors planner solving)
  #:use-module (playnet doors planner standing)
  #:use-module (playnet doors planner work)
  #:use-module (playnet doors planner person)
  #:use-module (playnet doors planner slots)
  #:use-module (playnet doors planner roster)
  #:use-module (playnet doors planner money)
  #:use-module (playnet doors planner chat)
  #:use-module (playnet doors planner ctx)
  #:use-module (playnet doors planner solve-cache)
  #:use-module ((playnet economy debts) #:select (%payout-spec))
  #:use-module ((playnet doors assignments) #:select (do-accept-assignment do-decline-assignment do-express-willingness willing-predicate))
  #:use-module ((playnet doors effort) #:select (do-drop-event do-record-effort finite-positive?))
  #:use-module ((playnet doors journeys) #:select (ensure-place! trip-good trip-ids))
  #:use-module ((playnet doors plan-wire) #:select (build-snapshot location-slacks plan-results->dial-plan scope-credit->wire scope-members skill-holders solve-part wire-number))
  #:use-module ((playnet doors position) #:select (agent-position-predicate demand->keyed demand-horizon do-set-position federated-horizon location-mode nearest-location own-position-place! sharing-refused? solve-keywords standing-in))
  #:use-module ((playnet doors skills) #:select (declare-skill! lower-resource! revoke-skill!))
  #:use-module ((playnet economy payouts) #:select (payouts-upgrade!))
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
  #:use-module ((playnet scope policy) #:select (governance-policy policy-dials))   ; the governed dials, one registry
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
  #:use-module ((playnet protocol dispatch) #:select (declared-methods* fragment-heads fragment-dispatch))
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
  #:use-module ((playnet solve keywords) #:select (caps-under pick-keywords))   ; the caller's caps over the world's; a kind's keywords
  #:use-module ((playnet solve engine) #:select (key-spec spec-owner spec-base *desire-w0* want-as-cap? cap-scale-of))
  #:use-module ((playnet solve ingest) #:select (owned-spec stock-vocabulary resource-window-hours))   ; the one key split; a citizen's own good; one whole hand; the shipped shape + its per-spec reference scale
  #:use-module (playnet scope live)   ; plan-scope->alist (the convex planner over the live scope)
  #:use-module ((playnet knowledge catalogues subsistence) #:select (sub-spec subsistence-species-base))   ; the floors a substitute is read against
  #:use-module ((playnet utils common) #:select (string-or-false take-up-to))
  #:use-module ((playnet utils store-utils) #:select (generate-id))
  #:use-module ((playnet observation evidence) #:select (evidence-hash? evidence-tag tags-evidence))
  #:use-module (playnet doors offers) ; the commitment arc's doors: offer-work, present-offers, accept-regret, the fresh check, commitment-drift
  #:use-module ((playnet vf formulas skill-law) #:select (skill-law-of competence-fold))   ; a skill's law off its spec, folded over the record
  #:use-module (playnet vf formulas counting)   ; the planned count: cadence, regime, process grammar
  #:use-module ((playnet plan accepts) #:select (floors->wire ->epoch deployment-bindings))  ; the dial's data: floors on the snapshot; the one clock coercion; standing accepts/holds as matching seeds
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
  #:export (plain-plan-fn ^planner-service
            standing-demand-node-of standing-credit-uc scope-of-place spec-of-resource
            materialize-composition!)
  #:re-export (scope-composition recipe-derived-contains)
  #:use-module ((playnet scope snapshot) #:select (scope-locations->wire dedup-locations))
  #:use-module (playnet doors slots)
  #:use-module ((playnet scope replica) #:select (scope->replica replica->text))
  #:use-module ((playnet observation log-observe) #:select (%log-actions do-log-observe)))   ; an observation of one's own doing   ; a scope's books, copied to its member's device   ; what people ask for and offer: the slot doors' own bodies   ; a scope's places, as a snapshot carries them
(use-modules ((playnet observation account) #:select (spec-claimable? resource-individually-claimable?   ; the rail, read off the recipes
                                                              claim-commitment open-claim-for fulfillment-remaining))   ; the plan's claim, the one word a claim door honours
             ((playnet vf facts rail) #:select (spec-rail)))   ; live in live.scm, at the solve door

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
(use-modules (playnet knowledge worlds bioregions))
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

(define (standing-credit-uc)
  "The federation's standing ^credit-pool (the UC root's), or #f: the pool a
citizen's voice is read against."
  (%standing 'credit-uc))

(define (standing-demand-node-of aid)
  "The standing ^demand-node the live ^planner-service keeps for AID, or #f.
demand-of / demand-cells-of read such a node directly — the drop-in for a
scope walk wherever a solve wants the scope's declared needs."
  (%standing 'demand-node aid))

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
(load-boundaries!)

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

;; The service's doors, with the person-subject ones routed to the person's home.
(define-actor (^planner-service bcom scopes-hm #:optional (plan-fn plain-plan-fn) (earth #f) (readers '()))
  ;; THE CONTEXT: what the door fragments share, by name (doors/planner/ctx.scm);
  ;; the cells a setter door writes start at their defaults, the helpers are
  ;; handed over below once they exist. THE CACHE: this service's last plan per
  ;; scope and what warms and qualifies it (doors/planner/solve-cache.scm),
  ;; reading each scope's own stores through the roster.
  (define ctx (make-planner-ctx))
  (with-planner-ctx ctx
  (define cache
     (make-solve-cache
       #:store-of      (lambda (sid) (and=> (roster-ref sid) (lambda (root) ($ root 'plan-store))))
       #:observer-of   (lambda (sid) (and=> (roster-ref sid) (lambda (root) ($ root 'observer))))
       ;; the ids of the places a scope's own spatial store holds, or #f when
       ;; the roster does not know it (nothing to filter by)
       #:own-places-of (lambda (sid)
                         (and=> (roster-ref sid)
                                (lambda (root)
                                  (false-if-exception
                                   (map spatial-thing-id ($ ($ root 'spatial-thing-store) 'all-locations))))))))
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
  (define (gather rs root sid)             ; THE door: recipes, gated by the standing's admit? (holes yielding once mapped)
    (gather-recipes rs #:admit? (solve-standing-admit? (solve-standing-of root sid))))
  ;; the scope's STANDING onto a plan-fn call — each recipe's response (the
  ;; curve of its own runs, read by every future at that future's stress),
  ;; the contrary observations against its map (the world as its workers
  ;; have seen it, laid over every future), and the last solve's x, each a
  ;; per-scope fact a caller's own keyword wins over.
  ;; Warm-starting rides here so EVERY solve the service runs re-centres from
  ;; where the scope stood (solve/robust.scm ignores an x whose shape no longer fits).
  ;; the world a solve at SID sees (WORLD-OF, else the raw observer): the
  ;; view, the socialized caps and the spans, with the UC allocation
  ;; (means-caps-of cache) merged under the caps — one reading for every solve
  (define (world-of* root sid . kw)
    (let* ((w (if world-of
                  (apply world-of root sid kw)
                  `((view . ,($ ($ root 'observer) 'all-resources)) (caps . ()) (span . ()))))
           ;; the lots on their way, counted where the last plan's open dropoff
           ;; lands them (scope/live.scm arriving-lots): laid on the view once,
           ;; so every path reads cargo in motion as stock at its destination
           (view (arriving-lots ($ root 'observer) (or (planned-material cache sid) '())
                                (or (assq-ref w 'view) '()))))
      ;; the allocation stands under the world's own caps (solve/keywords.scm
      ;; caps-under): a located good both name is the world's
      (cons* (cons 'view view)
             (cons 'caps (caps-under (or (assq-ref w 'caps) '()) (means-caps-of cache root)))
             (alist-delete 'caps (alist-delete 'view w)))))
  ;; the readers every solve here reads through: the roster's, with the world
  ;; read as world-of* — ONE place lays the UC allocation under the world's caps,
  ;; on the plain path as on the federated and the means paths
  (define readers*
    (cons (cons 'world world-of*) (alist-delete 'world readers)))
  ;; THE SETTINGS OF A SOLVE, AS ONE ALIST MERGED BY KEY. What the scope
  ;; stands on (its standing, its warm start, the decided discrete state, the
  ;; governed dials, the voice field's inputs, where its people are) is one
  ;; alist; the caller's keywords are laid over it by key, so a caller's word
  ;; wins by construction and no key is looked for twice. The caps are the
  ;; world's (world-of*), laid under the caller's in solve-with-readers.
  ;; Converted to keywords once, at the end.
  (define (merge-settings standing over)
    (append over (filter (lambda (kv) (not (assq (car kv) over))) standing)))
  ;; THE STANDING A SOLVE IS GIVEN, read once per request (the standing memo's
  ;; extent) into one record (doors/planner/ctx.scm solve-standing): the scope's
  ;; standing, what has been seen of the map, the last solve's x and rows, the UC
  ;; allocation as caps, the governed dials, the voice field, the roster's readers.
  ;; The plain solve lays it under the caller's keywords (standing->settings,
  ;; merge-settings); the federated record and the means consensus read the
  ;; fields they take; the gate reads its admit?. One reading for every path.
  (define (solve-standing-of root sid)
    (let* ((memo (standing-memo))
           (key (cons 'solve-standing sid))
           (held (and memo (hash-get-handle memo key))))
      (if held
          (cdr held)
          (let* ((st (standing root sid))
                 (dials (policy-dials ($ root 'plan-store)))   ; a root answers its plan-store; #f reads the defaults
                 (tau (let ((t (memq #:voice-tau dials))) (if (and t (number? (cadr t))) (cadr t) 0.0)))
                 (vn (node-of sid nodes-voice))
                 (voice? (and vn (> tau 0.0)))
                 (rec (make-solve-standing
                       ;; THE admit gate, composed once: the standing's own word
                       ;; (a consensus barring a recipe here) and the holes the
                       ;; scope's own recipes already fill — every path gathers under it
                       #:admit? (compose-admit (assq-ref st 'admit?) (hole-admit ($ root 'recipe-store)))
                       #:proc-frag (let ((r (assq-ref st 'proc-frag))) (if (pair? r) r '()))
                       #:responses (let ((r (assq-ref st 'responses))) (if (pair? r) r '()))
                       ;; what has been seen of the map: the reading fold's `contrary` read
                       ;; (the rail's standing observations at their cautious reading, folded
                       ;; with every other reading), the standing's own rows where no node stands
                       #:observed (let* ((n (node-of sid nodes-reading))
                                         (r (or (and n (false-if-exception ($ n 'contrary))) (assq-ref st 'observed))))
                                    (if (pair? r) r '()))
                       #:warm-x (warm-x-of cache sid)
                       #:decided (decided-of cache sid)
                       ;; where the scope's people are, per period: the one trajectory every
                       ;; solve here prices against (doors/position.scm)
                       #:agent-position (agent-position-predicate root)
                       #:dials dials
                       #:voice-pushes (and voice? ($ vn 'pushes))
                       #:voice-hours (and voice? ($ vn 'hours-of))
                       #:scope-path (scope-ancestry sid)
                       #:practice-peers practice-observers
                       #:agent-of home-agent-of)))
            (when memo (hash-set! memo key rec))
            rec))))
  (define (standing-settings root sid) (standing->settings (solve-standing-of root sid)))
  (define (standing-kw root sid kw)
    (alist->kw (merge-settings (standing-settings root sid) (kw->alist kw))))
  ;; the voice field's inputs, a fact about the scope like the rest: τ from the
  ;; scope's governance policy (0 by default — the plan as if no stance stood),
  ;; the scope's standing pushes and hours reader off its voice node, and the
  ;; path of scopes the solve stands in (leaf first) for a part naming a scope.
  ;; the governed dials, every row read fresh from the one registry
  ;; (scope/policy.scm): τ and the rest go to the engine as keywords;
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
                (call-with-vat solve-vat
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
    (if (not solve-vat)
        (apply solve-with-readers plan-fn readers* root sid (standing-kw root sid kw))
        (call-with-values spawn-promise-values
          (lambda (p r)
            (set! %solve-queue
              (append %solve-queue
                (list (cons (lambda ()
                              (apply solve-with-readers plan-fn readers* root sid
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
    (let* ((cached (last-solve-ref cache sid))
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
                  (map cdr %fold-kinds))
        (for-each (lambda (kind)
                    (unfold-node-reparent! (kind mine) id #:from (%node-at kind old) #:to (%node-at kind new-parent)))
                  (map cdr %descent-kinds)))
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
  ;; demand (last-solve-ref cache), neither of which scope-root's own rewire can
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
        ;; a store written before the payout records: its words read into them once
        (false-if-exception (payouts-upgrade! ps #:at (current-time)))
        (false-if-exception
         ($ ps 'set-fresh-check
            (make-fresh-check root
              #:solve (lambda kw (apply plan-fn* root id kw))   ; the readers' door, as every solve here
              #:solve-opts-thunk
              (lambda ()
                (let ((cached (last-solve-ref cache id)))
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
  ;; overlay reads it (cache-solve! cache), never another scope's
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
            ((cache) cache)
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
  ;; lands (cache-solve! cache) refolds its scope's cells, the ratio and the
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
      (when n (<-np n 'slack-changed (scope-own-slack cache sid)))))
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
      ;; the doors' own keywords off an empty option alist (doors/position.scm
      ;; solve-keywords): the one spelling of a solve's inputs
      (on-plan (apply plan-fn* root scope-id (solve-keywords root '()))
               (lambda (al) (landed) (cache-solve! cache scope-id '() al))
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
      (for-each (lambda (h) (solve-effect! 'standing-terms 're-stand h)) re-stand))
    (let ((due (find (lambda (entry)
                       (and (not (member (car entry) seen))
                            (not (hash-ref %solve-inflight (car entry) #f))   ; queued or running: its landing is coming
                            (let ((at     (solve-at-of cache (car entry)))
                                  (cached (last-solve-ref cache (car entry))))
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
    (mark-solve-stale! cache scope-id)
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
  (set-solve-cache-on-cached! cache
        (lambda (sid)
          (refold-slack! sid)
          (let ((root (roster-ref sid))
                (cached (last-solve-ref cache sid)))
            (when (and root cached)
              ;; the plan that lands for a scope declared under nothing is the
              ;; plan that stands: its f is the one credit and voice read. A
              ;; child's plan covers its own roster alone, and a question
              ;; (a what-if) never lands, so neither moves it.
              (unless (hash-ref %scope-parent sid #f)
                (solve-effect! sid 'free-time
                  (lambda () (publish-plan-free-time! (cdr cached)))))
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
                 ($ sl 'slack-changed (scope-own-slack cache id))
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
                                          (when rt (set-means-cap! cache rt (cadr r) (caddr r)))))
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
                                          (cache-solve! cache (car r) (cadr r) (caddr r))))
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
  ;; THE SCOPE'S PROGRAM, as the plain solve assembles it (scope/live.scm
  ;; scope-world) under the roster's readers and the standing: the one world
  ;; the federated record and the means consensus take their records from.
  ;; The demand is the caller's (a crossing good, a means' keyed demand), so
  ;; the demand reader stands aside; every other reader reads as for a plain solve.
  (define (scope-program-of root sid . kw)
    (apply solve-with-readers (lambda (root sid . kw) (apply scope-world root kw))
           (alist-delete 'demand readers*) root sid (standing-kw root sid kw)))
  (define (scope-record-of sid goods dem hz)
    (with-scope sid
      (lambda (root)
        (let* (;; the walls are the caller's: a commune's reproduction crosses
               ;; when its caller lays the floors (#:repro-floors, federation-
               ;; solve.scm REPRODUCTION ACROSS THE BOUNDARY), so the program
               ;; stands without the plain solve's eat recipes and their bands
               (p (scope-program-of root sid #:demand (if (pair? dem) (list dem) '())
                                    #:never-raw goods #:horizon hz #:reproduce? #f))
               (world (scope-program-world p)))
          ;; labour arrives off the scope's STANDING pool — the fold the
          ;; roster maintains between solves — so skills and availability
          ;; enter the federated solve as the same keyed entries the UC reads.
          ;; The scope's OWN entries: the subtree total would count a
          ;; member scope's bodies in its parent's program as well as its own
          (commune->scope-record
            (scope-program-resources p) (scope-program-agents p) (scope-program-spatials p)
            (scope-program-procs p) (scope-program-flows p)
            #:id sid
            #:demand (assq-ref world 'demand)
            #:never-raw (assq-ref world 'never-raw)
            ;; the goods cross; which way is the solve's to say
            #:crossing goods
            #:eco-caps (assq-ref world 'eco-caps) #:span-of (assq-ref world 'span-of)
            #:horizon hz
            #:labour-entries (and=> (labour-pool-of sid)
                                     (lambda (p) (pool-entries ($ p 'fold-own))))
            #:proc-frag (assq-ref world 'proc-frag)
            ;; the governed dials, as the plain solve lays them after ingest
            #:settings (pick-keywords (alist->kw world) '(setting)))))))
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
                          (append (scope-locations->wire sib (location-slacks (last-solve-ref cache sid))) acc)
                          acc)))))
            '() (roster-entries)))))

  ;; First-Person gate — the gateway installs a PORTABLE personhood check
  ;; (holds a live PHC in any ecosystem) once the credential store exists.
  ;; Until then, allow, so the dial works before the store is wired.
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
  ;; a read through the door: the key's answer, or nothing — when no door is
  ;; wired, the key is absent, or the read fails
  (define (door-read key . args)
    (or (and witness-door (assq-ref witness-door key)
             (false-if-exception (apply (assq-ref witness-door key) args)))
        '()))

  (planner-ctx-install! ctx
    cache roster-ref roster-entries roster-add! roster-forget! with-scope with-person
    scoped door-read home-scope-of adopt-home! set-home-row! person-events
    person-observers standing solve-standing-of world-of* gather plan-fn* on-plan resolve-scope!
    resolve-one-stale! resolve-stale-scopes! node-of labour-pool-of rehang-scope!
    slots-changed! slots-watch! slots-unwatch! means-changed! means-rebuild!
    means-fold-total steward-admit steward-ok? means-criteria scope-community
    communes-overlap scope-census scope-record-of scope-program-of federation-sibling-locations
    credit-roots refold-voice! refold-readings! rail-hands debts-of owed-of settle-of
    may-steward-of lent-of knows-of pool-of contrary-of)
  (set-planner-ctx-uc! ctx %uc)
  (set-planner-ctx-declared-parent! ctx %declared-parent)
  (set-planner-ctx-deployment-table! ctx %deployment-table)

  ;; THE COMPOSITION. A person's own doors (vf/facts/person-facts.scm) are the
  ;; person fragment, and only that fragment is routed to the home before
  ;; dispatch; the lists and the fragment's heads are held equal at the spawn,
  ;; so a door cannot be a person's own in one and not the other. The
  ;; heads-drift check runs once over every fragment's heads (declared-methods*),
  ;; and every reply leaves as the rows the page reads (finished).
  (define person-fragment (planner-person-doors ctx))
  (define (routed f)
    (cons (fragment-heads f)
          (lambda (msg . args) (apply (fragment-dispatch f) msg (route-home msg args)))))
  (let ((heads (map car (fragment-heads person-fragment)))
        (listed (append person-writes person-reads)))
    (unless (and (every (lambda (h) (memq h listed)) heads)
                 (every (lambda (l) (memq l heads)) listed))
      (error "planner: the person fragment and person-facts' door lists differ"
             (lset-xor eq? heads listed))))
  (let ((dispatch (declared-methods* planner
                    ((routed person-fragment)
                     (planner-chat-doors ctx) (planner-money-doors ctx) (planner-roster-doors ctx)
                     (planner-slots-doors ctx) (planner-work-doors ctx) (planner-records-doors ctx)
                     (planner-standing-doors ctx) (planner-solving-doors ctx)))))
    (lambda (msg . args) (finished msg (apply dispatch msg args))))))
