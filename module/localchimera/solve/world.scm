;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/solve/world.scm — the world the solve is given: one context, a value in hand.
;;;
;;; Every table the engine reads while it builds a program is a field of ONE
;;; `define-context` (localchimera protocol context), and each field stands at top
;;; level under its own name: `*places*` reads the world in hand, `(set!
;;; *places* …)` writes it, in this module and in every module that imports
;;; the name. The engine (solve/engine.scm) fills the fields through its door,
;;; `declare-world!`, which answers the world it declared; the ingest reads
;;; records into it; the solve reads it.
;;;
;;; The world in hand is the dynamic extent's, held in the fluid `%world`:
;;; `(current-world)` is the value, `(call-with-world w thunk)` runs the thunk
;;; with W in hand and leaves the caller's world standing, `reset-world!` puts
;;; a fresh instance in hand, every default evaluated again, so a table is a
;;; new table, the initial values written once. A solve that runs in its own extent leaves no
;;; world behind, and a holder of one world may run another inside it; `copy-world`
;;; is a value of its own, every table copied, so a holder may ingest once and
;;; solve a variation inside a copy (federation-solve `records-means-world`).
;;;
;;; Stated this way, a module that writes a world table never assigns a binding
;;; it imported, which Hoot refuses (the browser's family and scope workers
;;; compile the solve whole) and Guile would let diverge in silence; the lint
;;; `tools/lint/check-imported-set.scm` holds that line for both builds.
;;;
;;; What is NOT here: the engine's settings and memos (`*emp-rho*`, the
;;; tolerances, the `%…-index` memos, the parameters), which a fresh world
;;; leaves standing.

(define-module (localchimera solve world)
  #:use-module (localchimera protocol context)
  #:export (%world make-world copy-world world? reset-world! current-world call-with-world *certificates* *templates*
            *flow-period-factor* *avail-factor* *places* *periods* *cells* *period-days* *period-spans* *spatial-things*
            *movable* *storable* *tau* *hold* *neighbours* *stationary*
            *demand* *A* *acquire* *promote* *acquire-cost-of* *acquired-keys*
            *cap* *init* *latlon* *alt* *frag-cap* *frag-budget*
            *eco-couple* *couplings* *stock-frag-w* *frag-prior* *frag-spec* *band*
            *frag-container* *frag-within* *container-pools* *contained* *span-of* *never-raw*
            *raws* *mbq-procs* *config* *reserve* *desire-weight* *workers*
            *proc-skill* *emp-mode* *worker-pref* *willing?* *commute-km* *tau-commute*
            *arc-hours* *commute-manner* *material-manner* *commute-hours* *runs* *manner-pace*
            *period-class-of* *supplier-bundles* *resource-suppliers* *riders* *mobile-people?* *mode-recipes*
            *roster-labour?* *inert-caps* *borne-hours* *skill-spec* *trainable* *competence-p0*
            *composition* *spec-units* *mbq-relaxed* *whole-procs* *proc-tags* *proc-frag*
            *requires* *why-not* *legal-frag* *col-bounds* *col-fixed* *ride-info*
            *scope-path* *col-terms* *col-ell* *voice-tau* *voice-pushes* *voice-hours*
            *voice-stances* *budgeted-floors* *stock-price* *stretch* *stretch-floor* *locate-key*
            *mobile-means* *contents* *stands-in* *means-lot* *disposable*))

(define-context world #:fluid %world
  ;; ── the recipes: what this world can do ──
  ;; the compiled recipes of the problem in hand (solve/compile.scm compile-recipe;
  ;; ingest-records! lays them, declare-world! takes them by #:templates), the
  ;; templates the located program tiles over the cells. A field, so a fresh world
  ;; holds none and a world in hand holds its own: declared without them, a world
  ;; reads NO template rather than the last solve's.
  (*templates* '())

  ;; ── the shape: places, periods, cells; what moves, what stays, what it costs ──

  ;; the per-flow factor a branch (solve/robust.scm) or a site puts on a column's
  ;; flows, consulted as (action proc-id spec t place): the PLACE is the tiled
  ;; column's own, so a shock may name a located act — one district's harvest
  ;; lost — while the recipe stays the one location-agnostic template VF means
  ;; it to be. Identity outside a branch.
  (*flow-period-factor* (lambda (action proc-id spec t place) 1.0))

  ;; a branch's RAW-SUPPLY view, the same seam one level down: consulted only
  ;; where a cap becomes a form CONSTANT (build-located), never where pruning
  ;; reads reachability — so an avail shock reshapes what a branch may draw
  ;; without ever reshaping which columns exist. Identity outside a branch.
  (*avail-factor* (lambda (located-good) 1.0))

  (*places* '()) (*periods* '(0)) (*cells* '())
  ;; the calendar: what a period is on the clock (solve/periods.scm reads and
  ;; lays these) — period → weekday symbols, period → (start-iso . end-iso)
  (*period-days* (make-hash-table)) (*period-spans* (make-hash-table))

  (*spatial-things* '())   ; the containment tree, as ingested — read by `within` fragilities

  (*movable* '()) (*storable* '()) (*tau* 0.0) (*hold* 0.0)   ; τ = 0 by default: a declared-movable good carries free between neighbours, logistics abstracted by choice; a scope that wants the haul felt sets τ (hours per unit per km)

  (*neighbours* (make-hash-table))   ; place -> (adjacent-place …): the transport NETWORK. Spatial moves run only along declared edges, so transport is O(P·degree) not O(P²). A place with NO entry is connected to ALL (the default — legacy fully-connected behaviour with nothing declared).

  (*stationary* '())   ; specs whose ResourceSpecification.keepInPlace is set (warehouse/silo/shelf …) — an explicit FIELD, not a classifiedAs tag, and NOT an absolute "unmovable". It only says: USING this thing as a container keeps its contents in place (a through-TIME move = storage), whereas using a vehicle moves them through SPACE. Nothing is truly immovable — relocating the warehouse ITSELF is just a different recipe in which the warehouse is the cargo. Default: every spec is mobile; the arc (space vs time) is DERIVED from the container the recipe uses, never marked on the recipe.

  (*demand* (make-hash-table)) (*A* (make-hash-table))

  ;; ── the bill: what the plan may bring in, and the tier it holds ─────────────

  ;; *acquire* names what the plan MAY bring in from outside the scope, and its
  ;; price in hours per unit: ((selector . hours) …). A selector is a spec, a
  ;; skill, "labour" (every labour row), or #t (every drawn row). Each drawn row
  ;; something sells gets one ACQUIRE column — +1 on the row, priced in the
  ;; labour form — so the solve buys exactly what the walls it holds require and
  ;; nothing else. *promote* names the tier held as a wall — 'rights (the floors
  ;; alone; held margins and wants dropped), 'needs (held margins at their ease
  ;; as walls too; wants dropped), 'wants (every want at its ask as a wall too) —
  ;; so a tier's bill is exactly that tier, and a cheap want is never bought under
  ;; the rights bill. 'none holds nothing at all — no floor poured, no margin, no
  ;; want — and is the RESIDUE the bills are read against: a barrier solve sits a
  ;; little inside every wall, so even a program with nothing to hold buys a
  ;; little; what the walls made it buy is the difference (bill-net).
  ;; #f is the ordinary solve: floors hard, the rest soft.
  ;; The report reads the acquire columns back as a BILL,
  ;; and `plan-bills` runs the three tiers. Ecological walls take no acquire
  ;; column unless named: what nature bounds is what the bill cannot buy.
  (*acquire* '())

  (*promote* #f)

  (*acquire-cost-of* (make-hash-table))   ; acquire column key → hours per unit

  (*acquired-keys* (make-hash-table))     ; located row → #t when an acquire column feeds it

  ;; ── stocks, caps and limits: the walls a good is held inside ─────────────────

  (*cap* (make-hash-table)) (*init* (make-hash-table)) (*latlon* (make-hash-table))

  (*alt* (make-hash-table))          ; place → altitude, metres, from the SpatialThing that states one

  (*frag-cap* (make-hash-table))   ; located-good -> (lo hi alpha w): a FRAGILITY barrier (frag) instead of a hard cap — tip placed precautionarily inside the science range [lo,hi] at quantile_alpha, felt before the limit (fixed weight w), never crossed. See docs/planning/solve/possibility-tensions-unified.md.

  (*frag-budget* (make-hash-table))   ; bare spec -> (lo hi alpha w): a CUMULATIVE fragility budget — ONE barrier on the spec's TOTAL draw summed across periods/places (the Time coordinate, "max is a no-op" case). vs *frag-cap*, which is per-period.

  (*eco-couple* (make-hash-table))    ; k-spec -> ((j-spec . c) …): the cascade matrix C (drawing agent j stresses agent k by c). A frag-capped agent reads its EFFECTIVE pressure p = (I−C)^{-1}·draw (the Space coordinate). ρ(C) < 1. Kept its own global (not in *couplings* below): a barrier-bounded spec is EXEMPT from the ordinary ≥0 balance entirely (barrier-bounded?, emit-frag!), a role no other coupling carries — folding it into the generic registry would either give every future coupling that exemption by accident or need an exception rule forever.

  ;; *couplings*: name (a symbol) -> a coupling hash (k-good -> ((j-good . c) …)), the
  ;; SAME cascade as *eco-couple* for goods whose balance stays ORDINARY — a coupled
  ;; good still gets its usual mk-bar/mk-frag, only the COEFFICIENTS feeding it are
  ;; propagated first. One registry for however many such couplings a solve carries;
  ;; register-coupling! is the one door in, coupled-coeffs (build-located) the one
  ;; door out. Two today (nutrient bioavailability, skill cross-training); a third
  ;; costs this registry a new NAME, never new engine code.
  (*couplings* (make-hash-table))

  (*stock-frag-w* (make-hash-table))   ; spec -> w: a limit carried as a STOCK whose ≥0 balance is a
  ;; FRAGILITY rather than an ordinary bar. The two differ only in weight (see §1: frag is "like bar but
  ;; FELT AT THE OPTIMUM"), and a limit needs BOTH properties at once — a level that falls and rises, and a
  ;; fixed governance weight so the plan eases off before the wall. Carrying it as a stock alone would
  ;; silently swap the fixed weight for the swept one and ride the boundary to its edge.

  (*frag-prior* (make-hash-table))    ; located-good | spec -> the OBSERVED draw already committed toward the tip (the Time "memory", read from the observer each solve). The barrier baseline becomes s_tip − prior, so the plan's draw is INCREMENTAL from where we already are; past degradation is already baked in. Default 0 (fresh).

  (*frag-spec* (make-hash-table))      ; bare spec -> (lo hi alpha w): a per-period fragility applied at EVERY cell the spec is drawn (a planetary-boundary RATE — vs *frag-cap*, one located-good, and *frag-budget*, the horizon sum).

  (*band* (make-hash-table))   ; located-good -> (floor ceiling w): a REPRODUCTION BAND — the two walls a good's level is held between, and the weight the walls are felt at. Walls are read on the level AS IT STANDS after the pour (apply-repro-bands! takes every floor's need off the on-hand first, so a want counts above it).

  (*frag-container* (make-hash-table))  ; container -> (lo hi alpha w): a fragility on an ECOLOGICAL CONTAINER (Amazon, a watershed) — its barrier reads draws on everything contained-in it. The containment hierarchy IS the cascade, for free.

  ;; The COMMONS scale: named specs summed over every cell AT OR UNDER a place in
  ;; the containment tree. `*frag-container*` reads its contents at the container's
  ;; OWN cell, so two farms inside one watershed drawing `water#farm-a@t` and
  ;; `water#farm-b@t` are invisible to a barrier on the shed — measured, not
  ;; supposed. This table is what lets the shed feel the sum, which is what
  ;; localchimera.typ §bioregion asks of custody: the over-draw is felt by exactly the
  ;; scope that can ease it. Keyed container -> (profile specs window).
  (*frag-within* (make-hash-table))

  (*container-pools* '())  ; suppliers ingest DERIVED from containment: a means held at a
  ;; container place serves everywhere under it, out of ONE pool per period. Collected during
  ;; ingest-stock! and appended to *resource-suppliers* after the caller's own (ingest-located!),
  ;; because a shared bar is the only form that says "spendable here OR there, bounded in total" —
  ;; a per-cell *cap* can only repeat the number at each place, which is that much capacity again.

  (*contained* (make-hash-table))       ; container -> (spec …): which specs are contained-in each container (built at ingest from EconomicResource.contained-in). A contained resource's PLACE is where the chain finally says it is (resource-place walks it).

  ;; SPAN is governed, LOCATION is fact (docs/planning/federation/patchwork-scopes-containment.md
  ;; §2.3): where a means sits is the world's answer; how far its service pools is an
  ;; allocation decision. *span-of* carries that decision — resource-id → the place its
  ;; pool is constituted at — and the pool-builder reads it in place of the holding
  ;; place. Absent ⇒ the holding place, the exact behaviour spans always had. The
  ;; resource's own location is never touched: a lathe can sit in the workshop and
  ;; serve the town, and reach − span stays a readable withholding figure. Governance
  ;; fills this from scope-signed span declarations; the planner only reads it.
  (*span-of* (make-hash-table))         ; resource-id -> place-id: the declared span of its service pool

  (*never-raw* (make-hash-table))   ; specs that are ALWAYS goods (money, credit) — never a FREE raw: with no producer and no stock their balance is 0, so the chain dies cleanly (no eco-cap workaround)

  ;; FAIL-CLOSED default: a good is a GOOD (balanced ≥0 — must be produced or in
  ;; stock) UNLESS it is a STRUCTURAL pool (Lab|/Svc|, generated by the planner) or
  ;; the scope explicitly lists its spec in *raws* as a genuine ambient/imported
  ;; leaf. So an unmodelled input no longer conjures itself for free — it dies,
  ;; loudly, like a missing recipe. A stocked leaf is bounded either way (its stock
  ;; routes to *init* as a good, or to *cap* as a raw); only an UNstocked, unproduced,
  ;; unlisted spec changes behaviour (free → dead), which is exactly the footgun.
  ;; *raws* is NOT a grab-bag of "things we don't model". A free raw is an
  ;; EXTERNALITY — a good drawn with no producer, no stock, no labour, no barrier:
  ;; the free appropriation of nature the metabolic-rift accounting exists to CLOSE.
  ;; So it is reserved for genuinely BOUNDLESS ambient flows (sunlight, rainfall) that
  ;; no reproduction bounds. Anything finite — soil, forest, an aquifer, a CO₂ sink —
  ;; is NOT a raw: it is a stock (drawn + regenerated, stocks.scm) or a barrier-bounded
  ;; draw (a fragility), both of which the plan accounts for. Kept rare, and surfaced
  ;; by RAW-LINT so every externality is a conscious choice, never a silent default.
  (*raws* (make-hash-table))        ; spec -> #t : the boundless-ambient-flow allow-list

  ;; ── acts: batches, the configuration, the low-priority tranche, the weight of a want ─

  ;; (material loss is no longer a per-good rail: transit-loss / spoilage are a `consume` on the HAUL /
  ;;  STORE recipe — sized by the recipe, like wear is a consume of a durable's condition. See store-recipe.)
  ;; WEAR → MAINTENANCE needs no special state.  A durable's CONDITION is a stock GOOD (Cond|durable):
  ;; per-recipe wear is a `consume` flow (its quantity = the manner — high for a searing bake, low for a
  ;; gentle one), maintenance a `produce` flow.  `Cond|durable` made *storable* carries the health forward;
  ;; its onhand (a `use`d durable's level bounds the labour drawn) is just the good's starting *init*.
  (*mbq-procs* (make-hash-table)) (*config* 'all)

  (*reserve* (make-hash-table))  ; located-good -> (extra-target . weight): the low-priority tranche

  ;; PRIORITY of a desire — its weight w_d in the harmony objective Σ w_d g_d² (the
  ;; squared-gap penalty). A higher weight is filled first and shed last: this is what
  ;; lets the plan "under-serve cake to serve medicine". *desire-weight* maps a located
  ;; good → its w_d; build-located reads it, defaulting to the standard *desire-w0* when a
  ;; good is absent (so an unprioritised plan is uniform — every want equally loud). The
  ;; canonical level→weight policy is geometric: w_d = β^ℓ_d with β⁹ ≈ 1000, so a level-9
  ;; want weighs ~1000× a level-0 one. The engine only consumes the WEIGHTS; producing
  ;; them from governed priority LEVELS (the eventual UI/governance feed) is the caller's
  ;; job — priority-weight (tension-kinds.scm) is the one place that mapping lives.
  (*desire-weight* (make-hash-table))   ; located-good -> w_d (absent ⇒ *desire-w0*)

  ;; ── people: the roster, its skills, who is willing ──────────────────────────

  ;; When *workers* is set, labour stops being a fungible per-cell cap and becomes a
  ;; GOOD `Lab|skill|cell`: each worker SUPPLIES it (a column producing it, capped by
  ;; their hours, with a convex EMP congestion cost ρ·(util²) — utilization-normalised
  ;; so it equalises the FRACTION of offered time each worker gives, scale-free and
  ;; bounded by ρ, never trading against demand; see build-located); each process
  ;; CONSUMES it for its skill. Skill = the incidence
  ;; (a process runs at a cell only where a worker of its skill is present); EMP =
  ;; the qc term; "who works which slot" = the worker-column levels. Empty ⇒ the
  ;; aggregate *A* path (the demos) is unchanged.
  ;; *workers* entry = (id skills cell hours): an agent holding (possibly several)
  ;; skill ERs — VF: a skill is an EconomicResource conformsTo a skill ResourceSpec,
  ;; primaryAccountable = the agent (observer 'skills-of). A MULTI-skilled agent has
  ;; ONE time budget deployed across whichever skill they work, so each skill gets a
  ;; supply column but they all draw on one shared hours cap, and EMP is on the
  ;; agent's TOTAL load.
  (*workers* '())

  (*proc-skill* (make-hash-table)) ; proc-id -> skill: OPTIONAL override of the recipe's work-flow resourceConformsTo

  (*emp-mode* 'total)

  (*worker-pref* (make-hash-table)) ; (worker-id . skill) -> π̂ : skill-time preference (− eager, + reluctant, 0 neutral)

  ;; WILLINGNESS GATE: (worker-id skill cell) -> bool. Default #t (every reachable worker is a
  ;; candidate — today's behaviour). The solver-offers-first loop runs TWO solves of the SAME
  ;; program: an UNGATED one (this returns #t everywhere) yields the EMP-fair candidate FIELD = the
  ;; offer; a GATED one (only status=willing) yields the budget-bounded MATERIALIZED assignment.
  ;; It only decides which w|id|skill|cell columns may carry flow — the single bundle hour-cap then
  ;; bounds materialization, EMP spreads it fairly, *worker-pref* tilts within the willing set.
  (*willing?* (lambda (worker skill cell) #t))

  ;; ── travel: commute, the arc table, manners and paces ─────────────────────────

  (*commute-km* 0.0)             ; how far a worker may COMMUTE to work (0 ⇒ home cell only)

  (*tau-commute* 0.0)            ; commute cost per km (penalises distant work in the free-time term)

  ;; "from-place|to-place|manner" → HOURS, poured by ingest-travel-times! from the
  ;; merged table (Valhalla matrix priors ⊕ observed-trip EWMA — see solve/routing.scm).
  ;; Every spatial call site reads it through `arc-hours`, falling back to its
  ;; existing rate×haversine when the key is absent — so an EMPTY table reproduces
  ;; today's numbers exactly, and a populated one swaps geometry for the road
  ;; network without touching any other coefficient. Manners are Valhalla
  ;; costings ("pedestrian" "bicycle" "auto" "bus" "multimodal").
  (*arc-hours* (make-hash-table))

  (*commute-manner* "pedestrian")  ; manner of the worker commute (sites: reachability, hrs-coeff)

  (*material-manner* "auto")       ; manner of bare τ·km material moves

  (*commute-hours* #f)             ; opt-in TIME reachability gate (#f ⇒ the km gate, today's behaviour)

  ;; The runs a plan's relocations are: run id → the recipe process (or mode) it is an instance of,
  ;; #f when no recipe stands behind it. A plan's material rows name a run as their process, and a
  ;; confirmation reads what the run is an instance of from here. Filled by plan->material.
  (*runs* (make-hash-table))

  (*manner-pace* '())              ; manner → typical hours/km, the median of the table's (hours . km)
                                          ; entries (ingest-travel-times!), for GENERIC transport recipes'
                                          ; time-like flows (a travel mode states its own pace — mrec-pace);
                                          ; empty ⇒ those recipes stay geometric (parity)

  (*period-class-of* (lambda (t) #f))  ; period → period-class ("wd-am"…) or #f. When a class
                                          ; names the departure period, classed table keys
                                          ; ("from|to|manner|class": rush-hour transit ≠ 3am) are
                                          ; preferred over the manner-wide entry. Default #f ⇒ the
                                          ; 4th key segment stays dormant — parity.

  ;; ── suppliers, riders and modes ───────────────────────────────────────────

  (*supplier-bundles* '())         ; per SUPPLIER: (id budget place ((col-key cell coeff) …) labour?) — built in build-columns; a supplier is a worker (labour? #t, budget = hours) OR a means (labour? #f, budget = the service it renders)

  ;; `budget` is a BUDGET in the exact sense (utils/capacity.scm): one Σ bar over every
  ;; entry, so it is fungible across whatever cells they cover. With entries in one cell
  ;; that is indistinguishable from a ceiling there; with entries spanning cells it is
  ;; the thing a plain `*cap*` cannot express — spendable HERE or THERE, bounded in total.
  ;; A substitutable MEANS as a supplier: (id closure-specs cell|cells capacity durable?).  It
  ;; offers the CONFORMANCE CLOSURE of its spec (already closed live-side, exactly as a
  ;; worker's `skills` field is), capped by ONE shared capacity — the instrument twin of
  ;; the worker bundle.  durable? routes the good: a durable is `use`d and supplies the
  ;; per-period SERVICE `Svc|spec`; a stock is `consume`d and supplies the bare `spec`.
  ;; A non-substitutable means has a singleton closure ⇒ one supply column ⇒ the solve is
  ;; byte-identical to a plain eco-cap; only declared substitutes change anything.
  (*resource-suppliers* '())

  ;; A rider's PRESENCE is a unit good Pres|w, init=1 at their base at the FIRST period;
  ;; it CARRIES forward by free "stay" columns (so relocate-AND-stay falls out) and is
  ;; relocated spatially by a RIDE. Labour is supplied where present (supply ≤
  ;; hours·presence, gate); presence ≥ 0 ("can't send out more than you have") is auto
  ;; from the goods machinery. A ride picks a travel MODE — walking, biking, a car-ride —
  ;; each a transport recipe with its own vehicle (a `use`), driver (a `work`) and
  ;; transit time, and each ASKING A SKILL of the mover (walking needs "walk"; someone who
  ;; cannot walk simply lacks it, so the plan must route them a vehicle). Guarded by *riders*+*mode-recipes*.
  (*riders* '())      ; (id base (skill …) hours [kind]) — mobile, presence-gated workers; the 3rd element is ONE list — the skills they work with and the skills their travel modes ask (e.g. "walk") share it, read by the SAME bare-membership rule (skilled-worker-at?, mode-ok?); hours = a number or ((period . hours) …), see rider-hours; kind = 'means marks a mobile means (mover-kind), omitted for a person/cargo rider

  ;; Does this shed read its PEOPLE as movers? Off by default: handing every
  ;; person's location to the optimiser is a real modelling choice, not a detail of
  ;; declaring travel modes, and a scope may want modes for its FREIGHT recipes
  ;; while keeping its roster where it stands. Set through the manners bag,
  ;; (mobile-people . #t), beside the modes it needs.
  ;;
  ;; PRESENCE IS DECIDED, NOT ROUNDED. `Pres|w` is a unit good in a convex program,
  ;; so its relaxation is "she is spread": measured on two places, one courier and a
  ;; haul needing her skill, the relaxation put her half in each place and the two
  ;; directions of the haul cancelled in the delivery balance — net delivered 0.00 at
  ;; every walking pace, because the wash is symmetric in cost too. Price does not
  ;; fix a wash; integrality does, and the engine states it in three physical facts:
  ;;
  ;;   · a mover's RIDES ARE WHOLE — `ride.<id>.<mode>` compiles as a whole-count act
  ;;     (mover-ride-templates), so the discrete layer decides each move on its tree,
  ;;     with the certificate that licenses it (§7);
  ;;   · a mover LEAVES A CELL ONLY FROM THE PRESENCE THE BAND FOUND THERE — what it
  ;;     started with, stayed into, or arrived from an earlier band (rider-forms,
  ;;     departures ≤ presence-before). This closes the same-band circulation, a flat
  ;;     direction the barrier would otherwise wander along; a longer journey spans
  ;;     bands (the band dial);
  ;;   · a mover IS ALWAYS SOMEWHERE — its presence over the cells of a band is at
  ;;     least one, from the second band on (the first holds it by construction), so
  ;;     no fraction of a person lapses or lingers between bands.
  ;;
  ;; The gate and that count read presence DURING the band — the level before its
  ;; end-of-band stay-out (pres-during-coeffs) — since a person at a cell all day and
  ;; there again tomorrow is fully present today. What remains a modelling choice is
  ;; the scope's: reading its people as movers at all (mobile-people), and its
  ;; means (a durable classified "mobile" — means->movers!). Both are bounded by
  ;; movers × cells, which is small for a commune and is the honest scope limit:
  ;; this is mobility for a scope with a roster, not for a national plan.
  (*mobile-people?* #f)

  ;; The travel modes of a scope: each an ordinary TRANSPORT RECIPE, held as
  ;; (recipe-process flows). A recipe is a mode by its shape — it carries a
  ;; `work` flow resolved from its own pickup flow: the work of the one being
  ;; moved. That flow says who may travel this way (its skill, which the mover
  ;; bears; the moved spec itself when anyone may) and how fast (its hours per
  ;; km, the mover's own time on the way). The vehicle and a driver are plain
  ;; `use` and `work` flows with per-km quantities, and the router's costing is
  ;; the process's "manner:<costing>" classification. ingest-records! finds the
  ;; modes among the scope's recipes; a bare fixture hands them to
  ;; declare-world! (recipes/transport.scm's mode-recipe builds one).
  (*mode-recipes* '())

  ;; THE WORLD IS PEOPLED — somebody stands somewhere in it (declare-workers!), so
  ;; its labour is theirs, however many of them have hours. Set even when the
  ;; roster of hours comes out EMPTY, and that is the point: with labour routed through Lab|skill|cell GOODS, a skill nobody
  ;; supplies is an unsourced input, and the prune removes every column that
  ;; needs it — the one rule that already stops a recipe whose soil nobody has.
  ;; Read off the roster's length instead, an empty roster (a Mon–Fri crew planned
  ;; on a Saturday) fell back to the aggregate per-cell
  ;; cap, where a cell with no entry carries no bar at all: a day's bread baked
  ;; with nobody at work, and no work emitted to show for it.
  (*roster-labour?* #f)

  (*inert-caps* '())    ; the last ingest's caps that name a good no recipe touches (ingest-located!)

  (*borne-hours* (make-hash-table))  ; (mover-id . Svc|spec) → ((period . hours) …): the capacity of what a mover BEARS — the saw in a carried toolbox

  ;; ── skills as they stand and grow ─────────────────────────────────────────

  ;; A skill is borne by a PERSON, not stored as a good. Its lifecycle parameters
  ;; live on the skill's ResourceSpecification: it DECAYS if unused, REGENERATES by
  ;; participation (practising it in a work intent), and is GROWN by explicit
  ;; training (labour-power development). Per (worker w, skill d, period t) we carry
  ;; a competence level L_{w,d,t}; the worker may DELIVER at most L hours of d, and
  ;;     L_t ≤ (1−decay)·L_{t−1} + regen·practice_{t−1} + yield·Σ train_{→t}
  ;; with L_0 ≤ endowment. Training consumes a MENTOR's hours of the skill (it
  ;; competes in the Lab|skill balance) plus the trainee's time. So the pull λ on a
  ;; scarce skill funds its own training; because L persists in the person, one
  ;; training serves every later period, idle periods decay it, practice renews it.
  (*skill-spec* (make-hash-table))      ; skill -> #(decay regen yield lag teacher trainee endow refresh)

  (*trainable* '())                      ; (worker skill from-period mentor-skill) … who may be trained

  ;; Where a worker's competence STANDS as the horizon opens — the record's own
  ;; figure (the observer's practice folded through this same law, live.scm), in
  ;; place of the skill's endowment. Per (worker, skill); a fresh world holds none.
  (*competence-p0* (make-hash-table))

  ;; ── composition and units ─────────────────────────────────────────────────

  ;; social-material.typ: "Two ways of growing the same crop are two recipes, hence two
  ;; compositions: the variable-composition problem is met at the recipe level, each
  ;; recipe carrying its own composition." So a key may name a spec, or a spec IN a
  ;; process — one table, one accessor, the narrower key winning:
  ;;
  ;;   "carrot"                    what a carrot is, by default
  ;;   ("rp-grow" . "carrot")      what a carrot GROWN THIS WAY is
  ;;
  ;; WHICH KEY APPLIES WHERE is the whole of the mixture question, and the rule is
  ;; asymmetric on purpose:
  ;;
  ;;   a process's OWN OUTPUTS read its per-recipe row. This recipe made this batch, so
  ;;   this recipe says what the batch is.
  ;;
  ;;   its INPUTS read the spec-level row. A consumer draws from a POOL that may hold
  ;;   output from several recipes, and the pool's per-unit composition is a ratio of
  ;;   the plan's own levels — bilinear, and the pooling problem, which is not convex.
  ;;   Reading inputs at the spec level is the sound RELAXATION of it: element totals
  ;;   still balance, so matter is never conjured, and what is given up is per-unit
  ;;   exactness about a mixture. Where that exactness matters, separate the batches
  ;;   (`qualified-good` stage/state, or a lot) and each becomes its own spec with its
  ;;   own row — the exact answer, in the machinery that already exists.
  (*composition* (make-hash-table))   ; spec | (proc . spec) -> ((element . mass-fraction) …), passed in as POLICY: the engine holds no chemistry, and the recursive closure through `contains` is taken caller-side (catalogues/substances.scm `closed-composition`). Empty ⇒ element closure is off and the solve is byte-identical.

  ;; The unit each spec counts in, ((spec . unit)) as a table: a material row states its quantity in it.
  (*spec-units* (make-hash-table))

  ;; ── the discrete declarations ─────────────────────────────────────────────

  ;; MBQ is stored PER PROCESS, but branch-and-bound decides PER COLUMN — one mill
  ;; may run in one cell and not another. `*mbq-relaxed*` holds the column keys
  ;; whose floor is currently dropped (a FREE node in the search): `mbq-of` then
  ;; reads #f for them, which `col-on?` already treats as "present, unconstrained".
  ;; So one hash gives the third state the search needs without touching either.
  (*mbq-relaxed* (make-hash-table))

  ;; The relaxation may run 0.5 of an act. At population scale that is the right
  ;; object — a district performs 12.5 appendectomies a week and the fraction is a
  ;; RATE — and it stops meaning anything when a period holds about one unit. So
  ;; refining periods makes fractionality more acute, and the two pull against each
  ;; other; this is the answer for the few acts that are genuinely countable.
  ;;
  ;; Declared per PROCESS and decided per COLUMN, exactly as MBQ is: one theatre
  ;; may run three times in one cell and twice in another.
  ;;
  ;; This is the SECOND kind of discreteness in the engine, not a second engine.
  ;; MBQ splits a column 0 | ≥L; a whole count splits it ≤⌊v⌋ | ≥⌈v⌉ and may split
  ;; the same column again. One tree, one certificate, two kinds of cut.
  (*whole-procs* (make-hash-table))

  ;; the folksonomy tags each act carries (processClassifiedAs, compile.scm
  ;; proc-tags): read onto its columns as the `tag` term, so a part naming a
  ;; tag covers every column of every act under it — a chain of recipes named
  ;; as one way (voice-follows-work.md "A chain of recipes is a mapped way").
  (*proc-tags* (make-hash-table))

  ;; Every fragility above is read on a GOOD (a cell, a spec, a container, a
  ;; place), and a good that some column PRODUCES is never barriered — its ≥0
  ;; balance is its accounting (good-index: `made` ⇒ good, never raw). So nothing
  ;; in the good-keyed grid can price how much a RECIPE runs: its output is made
  ;; by it, its labour is made by the worker's supply column, and both fall on
  ;; the `made` side of that split by construction. This is the extent the grid
  ;; lacks — the act itself — and it is read where `*whole-procs*` and
  ;; `*mbq-procs*` already read per-act declarations: off the `p|proc|…` column
  ;; keys. The form is the SAME `frag` every other wall is: per period, with
  ;; x_p the activity of every column of the act in that period,
  ;;
  ;;     s = tip − Σ x_p,   φ(s) = −w·log s        (mk-frag tip ((ci . −1) …) w)
  ;;
  ;; tip = quantile_α[lo,hi] of the profile, w its fixed governance weight —
  ;; `(lo hi alpha w)`, the one profile shape: a caller that holds an act
  ;; near a wall hands its profile in (plan-scope #:proc-frag), and the act
  ;; commands less of the commons as it nears the wall, continuously.
  (*proc-frag* (make-hash-table))   ; proc-id -> (lo hi alpha w): a per-period fragility on the act's own level

  ;; ── the law: what an act needs here, why a column is not there, the legal wall ─

  ;;; WHAT AN ACT NEEDS, here. The requirements and the absences are ONE object at
  ;;; two bindings, and building the second without the first was backwards: a card
  ;;; that can only say "you cannot do this" is less use than one that says what the
  ;;; work is made of and marks what you are missing inside it.
  ;;;
  ;;;   requirement : (kind name qty unit met?)
  ;;;     consume  a material it uses up      use   a means it occupies
  ;;;     work     labour, and the competence it must be done by
  ;;;     obtain-entity / obtain-person / pay / tell   what the law asks HERE
  ;;;
  ;;; The material half comes off the recipe and is place-free — twenty cubic
  ;;; metres of timber is twenty anywhere. The legal half is place-BOUND, which is
  ;;; why this is keyed by column and not by process: what you must hold to do a
  ;;; thing depends entirely on where you stand, and a recipe cannot know it.
  ;;;
  ;;; met? is #t, #f, or 'unknown — never guessed. The engine knows about
  ;;; competences and licences (`skilled-worker-at?`) and about a permit's custody
  ;;; (the bill's `unheld`); a material's reachability it knows only per template,
  ;;; so every material of an unreachable one is marked #f together and no finer.
  (*requires* (make-hash-table))

  ;;; WHY a column is not there. Keyed by column, valued (reason . detail) —
  ;;; `(licence-not-held "Permis de conduire")`, `(raw-unreachable)`. The card's
  ;;; question "why can I not do this?" is then a lookup rather than seven
  ;;; re-derivations, and a licence is one entry rather than a special path.
  (*why-not* (make-hash-table))

  ;;; A prohibition the law is sure of removes the column: an impossibility, not
  ;;; something to trade off. One the pack is only UNCERTAIN of is different — it
  ;;; is a possibility-tension, and `frag` is already its shape: the log barrier
  ;;; that diverges at a tip never crossed and PERSISTS at the optimum, so the
  ;;; federation eases off before the limit rather than pricing its way through.
  ;;;
  ;;; It is also the truer model. Legal exposure is convex, not linear: one small
  ;;; unpermitted structure is unlikely to be noticed, a hundred is certain, and a
  ;;; flat per-unit cost says the hundredth is no worse than the first.
  ;;;
  ;;; Keyed by COLUMN, because a prohibition is per (act, cell) — zone N forbids
  ;;; building THERE. `*proc-frag*` groups an act's columns by period and sums over
  ;;; places, which would cap the act commune-wide instead.
  (*legal-frag* (make-hash-table))   ; column key -> (lo hi alpha w)

  ;; ── the search's own marks on a column ─────────────────────────────────────

  ;; The search's own bounds on a column: key -> (lo . hi), either end #f for open.
  ;; These are TENSIONS OF THE METHOD — scaffolding the search erected to cut off a
  ;; fractional value — so they are emitted through `mk-method` and never reach a
  ;; certificate. A branch is not a limit the world has.
  (*col-bounds* (make-hash-table))

  ;; A bound can only be APPROACHED: `−t·log(s)` diverges at s = 0, so the iterate
  ;; is pushed off the very bound it should rest on — asked for x ≥ 3 on a program
  ;; whose relaxed optimum is 2.4999, the solve returns 3.2938, and the box [3,3]
  ;; has no interior at all and reads as infeasible. No barrier will ever hold an
  ;; integer.
  ;;
  ;; So a decided count stops being a variable. It becomes a FACT, and facts live
  ;; in `const`: the column leaves the program and every form it touched keeps its
  ;; contribution as coeff·n. There is nothing left to sit on, which is the point —
  ;; a bound is approached, a constant simply IS.
  ;;
  ;; This is the engine's own idiom, not a new one. §7 already substitutes at zero:
  ;; "ON keeps its floor, FREE drops it, rest ABSENT" — an off column is not
  ;; constrained to zero, it is gone. This says the same thing at n.
  (*col-fixed* (make-hash-table))

  ;; ── one assembly's marks ──────────────────────────────────────────────────

  ;; Every instantiated ride's origin — pid → (mode . rider) — recorded at the
  ;; moment the template is born, so the tiling (tpl-manner, tpl-pace), the
  ;; budget (rides-in) and the key test (ride-key?) read the MODE ITSELF through
  ;; its own accessors. Empty in a fresh world, filled again wherever the templates
  ;; are built (build-columns per build; the ingest pass that registers
  ;; whole-procs).
  (*ride-info* (make-hash-table))

  ;; The path of scopes the solve stands in (leaf first), set by the door that
  ;; solves for a scope; #f for a bare engine run. A part naming a scope covers a
  ;; column when that scope is on the path — the column belongs to the solving
  ;; scope and to every scope containing it.
  (*scope-path* #f)

  (*col-terms* #f)                  ; vector, index = column index, built once per assembly

  (*col-ell*   #f)                  ; vector, ℓ_j: hours of labour per unit of column j, whichever path carries it

  ;; ── voice ─────────────────────────────────────────────────────────────────

  ;; Set by the door that solves for a scope (plan-from-records #:voice-tau
  ;; #:voice-pushes #:voice-hours), empty in a fresh world. τ = 0 is today: the field
  ;; adds nothing and labform is the identical list. Distinct from *tau*, the
  ;; transport cost per km, and *tau-commute*.
  (*voice-tau* 0.0)                 ; 0 ≤ τ < 1, governed: how far a stance may re-weigh an hour

  (*voice-pushes* '())              ; ((part . push) …), push ∈ [−1, 1], the scope fold's one number per part

  (*voice-hours* #f)                ; part → validated hours in its cell (the fold's reader), or #f

  (*voice-stances* #f)              ; vector of the stances the last assembly read, for the report

  ;; ── the budgeted floors and the stock price ────────────────────────────────

  ;; A floor F on a located good g, held against the loss of ANY Γ of the places
  ;; that supply it, without a future per place and without a probability for
  ;; one. The robust counterpart (Bertsimas & Sim 2004):
  ;;   Σ_d y_d − Γ·z − Σ_d p_d ≥ F,   z + p_d ≥ y_d  (∀ d),   z, p_d ≥ 0
  ;; whose dual is the max over |S| ≤ Γ of the supply lost, so the wall holds
  ;; under the worst Γ-set. y_d is what place d ITSELF contributes to g's cell:
  ;; bounded by the inflow that arrives from d AND by what d produces or holds
  ;; of the good by then — a unit hauled through d was not d's, and a wall that
  ;; counted it would be met by circulating one harvest (measured on the two-
  ;; field fixture: 242 kg of hauls from 1 kg of land, and a floor no place
  ;; could carry read as held). Laid entirely in the column/good machinery —
  ;; the balance rows the engine emits for any good ARE the constraint
  ;; families — with synthetic goods per floor and per source:
  ;;   bud|g          the budget, opening at −F; fed by every y_d, drawn by z (Γ) and each p_d
  ;;   cov|g|d        the cover: z + p_d − y_d ≥ 0
  ;;   in|g|d         the inflow from d: fed by every column bringing g to the cell from d, drawn by y_d
  ;;   own|g|d        d's own supply: fed by g's producers at d up to the floor's period, plus d's stock; drawn by y_d
  ;; and the columns y_d, z, p_d as zero-labour columns. The good's own
  ;; conservation stays a plain ≥ 0: F lives in the budget row, whose dual is
  ;; the price of the budget.
  (*budgeted-floors* '())               ; ((located-good F Γ) …), as #:budgeted-floors gave them (located at build via *locate-key*)

  ;; κ·labour prunes wasted work, and a unit of anything weighs the labour congealed
  ;; in it. Where the plan MAKES the good, the column that makes it carries that
  ;; labour. Where the plan only DRAWS it — a purse, a soil bank, a stock nothing
  ;; here remakes — the drawing column carries it, in the same labour form, at the
  ;; good's crystallized SNLT (*stock-price*, hours per unit: the value rollup over
  ;; the recipe that acquires it — localchimera.typ "Credits and external liquidity": a
  ;; euro's one internal price is the social cost of its acquisition). So the solve
  ;; rents exactly the nights the free beds leave unhoused, and makes what is
  ;; asked; a costless draw is a direction the objective cannot feel, and the
  ;; barrier method settles it mid-face.
  ;;
  ;; A stock NO recipe anywhere acquires has no labour basis (the rollup answers
  ;; +inf: unreachable). Its draw weighs its SHARE of the standing stock, a whole
  ;; stock drawn down weighing *stock-draw-hours* — a governed number that orders
  ;; the plan where the rollup is silent. The barrier's residue past what is asked
  ;; runs as t/(κ·cost), t the path floor (solver.scm *kern-tmin*).
  ;;
  ;; Read by NET spec: a carry or a move (−1 here, +1 there) weighs nothing, a lossy
  ;; one weighs its loss. A barrier-bounded draw is weighed by its fragility, once;
  ;; a structural pool (Lab|, Svc|, credit|) renews and weighs nothing.
  (*stock-price* (make-hash-table))      ; spec → crystallized SNLT, hours per unit

  ;; ── what ingest lays: stretches, located keys, the means and their lots ────

  ;; Located inputs are keyed `good#place@t`, and refining moves every position: a
  ;; caller's "@2" meaning day 2 lands in the middle of day 1. Re-pointing it at
  ;; one of the new pieces is not a translation — "400 units on day 2" says nothing
  ;; about WHEN inside day 2, so any choice of piece, or any split across pieces,
  ;; answers a question nobody asked.
  ;;
  ;; What the caller said is about the STRETCH, so it stays one form over the
  ;; stretch: the balance summed across its pieces. That is not an approximation of
  ;; the coarse reading, it IS the coarse reading — the temporal arcs INSIDE the
  ;; stretch appear once negative and once positive and cancel, leaving exactly
  ;; what carried in, what was made, what was drawn, and what carried out. Refining
  ;; then adds resolution where it belongs, on the supply side, and changes nothing
  ;; about what was asked for.
  (*stretch* (make-hash-table))     ; located-good → the goods its stretch spans

  ;; a bare reproduction floor on a STRETCH (a floor stated for a day the clock
  ;; refined into bands) lives here, not in *init*: the day's balance must reach
  ;; it, while each band's own stock conservation stays untouched. A span-less
  ;; or unrefined world never fills this table — its floors pour into *init* as
  ;; they always did.
  (*stretch-floor* (make-hash-table))  ; located-good (stretch representative) → floor

  ;; see ingest-located!'s tail — set per ingest, identity until then
  (*locate-key* (lambda (k) k))

  (*mobile-means* '())               ; ((resource spec place q measure serves?) …)

  (*contents* '())                   ; ((resource spec place q measure) …): the means standing IN something, at its place

  (*stands-in* (make-hash-table))    ; resource id → the id of what it stands in

  (*means-lot* (make-hash-table))    ; mover id → (spec . count): the lot a means mover is

  ;; THE CERTIFICATE AS A STOCK THE SOLVE RESPECTS: ((aid . hours) …), each
  ;; citizen's drawable credit this solve (#:certificates). Every claim column
  ;; draws credit|aid; the bundle laid over them (build-columns, beside the
  ;; workers' hour budgets) bounds the sum at the hours — so a plan's claims are
  ;; affordable by construction, and the ledger's balance check at the event is
  ;; a race guard, never the rule. A need never meets this wall: reproduction
  ;; draws the commons' food directly (live.scm eat), the common satisfaction of
  ;; needs, and a claim column stands only where a want is stated. Unstated ⇒
  ;; no bundle, credit drawn and tallied as before.
  (*certificates* '())

  (*disposable* '())                   ; ((agent-id . hours) …): each person's disposable time over the periods, set once per build; its sum is the people's N·T when rest is reserved
)
