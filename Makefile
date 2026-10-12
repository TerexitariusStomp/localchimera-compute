all: browser/repl.wasm browser/day-boot.wasm

# The wasm toolchain's identity stamp (rule and rationale at HOOT_TOOLCHAIN_ID).
# A rule's prerequisites expand where the rule is READ, so the name is defined
# here, above every wasm rule.
HOOT_TOOLCHAIN_STAMP = .hoot-toolchain

# ── The day dial ─────────────────────────────────────────────────────────────
# A SEPARATE app, deliberately apart from the repl: browser/app.html is
# CANONICAL — edited in place, served as-is, no build step, no coupling to
# repl.scm. Its vendored libs (d3, topojson, land-*.json, inter fonts)
# live beside it in browser/. (It began as docs/social-time-dial.html and
# was copied over by make; that indirection ate live edits — gone now.)

# The dial's capability spine: a SLIM Hoot program — gateway CapTP,
# KERI unlock/authenticate, lobby transcribe + ai-complete — loaded by
# day-boot.js into the same page. No UI, no tabs: app.html is the shell.
# Transitive (playnet …) import closure of hoot/day-boot.scm; see the
# note on REPL_WASM_DEPS and `make check-wasm-deps`.
DAY_BOOT_WASM_DEPS = \
                     module/playnet/utils/records.scm \
                     module/playnet/social/relationship-kinds.scm \
                     module/playnet/keri/reticulum-binding.scm \
                     module/playnet/utils/host.scm \
                     module/playnet/utils/hex.scm \
                     module/playnet/crypto/recovery-share.scm \
                     module/playnet/crypto/shamir.scm \
                     module/playnet/keri/cesr.scm \
                     module/playnet/keri/crypto-primitives-browser.scm \
                     module/playnet/keri/crypto-primitives.scm \
                     module/playnet/keri/said-portable.scm \
                     module/playnet/keri/signify-portable.scm \
                     module/playnet/identity/kel.scm \
                     module/playnet/doors/family/wire.scm \
                     module/playnet/wire/rows.scm \
                     module/playnet/wire/snapshot.scm \
                     module/playnet/utils/json-portable.scm

browser/day-boot.wasm: hoot/day-boot.scm $(DAY_BOOT_WASM_DEPS) $(HOOT_TOOLCHAIN_STAMP)
	$(HOOT_BUILD_DEV) \
	  guild compile-wasm -L module -L $(FIBERS_LOAD_PATH) \
	    -L $(GOBLINS_LOAD_PATH) \
	    --bundle -o browser/day-boot.wasm hoot/day-boot.scm
	./tools/dev/patch-reflect-mime.sh

# ── The planner under Hoot ───────────────────────────────────────────────────
# `guild compile-wasm` builds a whole program and refuses a module that may be
# redefined from outside. The engine and the calendar are declarative, their
# caller-written state in context cells (the note above define-module in
# module/playnet/solve/engine.scm), so the household bundle builds from the
# tree's own files; $(HOOT_SRC) holds the probe bundles.
HOOT_SRC = .hoot-src
# live.scm is `#:declarative? #f` (it loads the engine at module init), and a
# whole scope reaches it: a copy with the flag turned on is built only for the
# scope's own targets, under a directory of its own, searched first (a later
# -L is searched first), so the household build never reads it.
HOOT_SCOPE_SRC = .hoot-src/scope
$(HOOT_SCOPE_SRC)/playnet/scope/live.scm: module/playnet/scope/live.scm
	@mkdir -p $(dir $@)
	sed 's/^  #:declarative? #f/  #:declarative? #t/' $< > $@
	@grep -q '^  #:declarative? #t' $@ || { echo "live.scm: no '#:declarative? #f' line to turn on"; rm -f $@; exit 1; }

# Goblins and fibers come from their own pinned prefixes: the toolchain
# profile's whole site directory would also expose Hoot's host-side modules
# (hoot/primitives.scm is `#:declarative? #f`), which the library-group linker
# refuses to load as a wasm library.
HOOT_PLANNER_ARGS = -L module -L $(GOBLINS_LOAD_PATH) -L $(FIBERS_LOAD_PATH)

.PHONY: check-hoot-planner hoot-probe-family hoot-probe-admm hoot-probe-async
check-hoot-planner:
	@mkdir -p $(HOOT_SRC)
	$(HOOT_BUILD_DEV) bash -c 'guild compile-wasm $(HOOT_PLANNER_ARGS) -o $(HOOT_SRC)/family-probe.wasm hoot/family-probe.scm'

# runs the probe under node; the wasm imports goblins' crypto, which a solve never calls
hoot-probe-family: check-hoot-planner
	node tools/test/run-wasm.cjs $(HOOT_SRC)/family-probe.wasm
# A whole scope for the page: a scope root with its observer and stores, the demo
# neighbourhood seeded into it, a count through the count door (hoot/scope-probe.scm).
# Every module it reaches states its imports in its define-module
# (tools/edit/hoist-use-modules.py --check) and keeps host-only calls behind cond-expand.
.PHONY: check-hoot-scope hoot-probe-scope
check-hoot-scope: $(HOOT_SCOPE_SRC)/playnet/scope/live.scm
	$(HOOT_BUILD_DEV) bash -c 'guild compile-wasm $(HOOT_PLANNER_ARGS) -L $(HOOT_SCOPE_SRC) -o $(HOOT_SRC)/scope-probe.wasm hoot/scope-probe.scm'
hoot-probe-scope: check-hoot-scope
	node tools/test/run-wasm.cjs $(HOOT_SRC)/scope-probe.wasm

# the federated solve (solve-decomposed) through the browser build: each scope on the reference core
hoot-probe-admm:
	@mkdir -p $(HOOT_SRC)
	$(HOOT_BUILD_DEV) bash -c 'guild compile-wasm $(HOOT_PLANNER_ARGS) -o $(HOOT_SRC)/admm-probe.wasm hoot/admm-probe.scm'
	node tools/test/run-wasm.cjs $(HOOT_SRC)/admm-probe.wasm

# the coordinator-free solve: peers over a simulated network, each on the reference core
hoot-probe-async:
	@mkdir -p $(HOOT_SRC)
	$(HOOT_BUILD_DEV) bash -c 'guild compile-wasm $(HOOT_PLANNER_ARGS) -o $(HOOT_SRC)/async-probe.wasm hoot/async-probe.scm'
	node tools/test/run-wasm.cjs $(HOOT_SRC)/async-probe.wasm

# ── The household's solve on the device ─────────────────────────────────────
# browser/family.wasm is the planner's family solve for the browser, run in
# browser/family-worker.js so the ledger never leaves the page. A gitignored
# build product like day-boot.wasm; the box builds its own on deploy.
# Transitive (playnet …) import closure of hoot/family-worker.scm; see
# `make check-wasm-deps`.
FAMILY_WASM_DEPS = \
                 module/playnet/protocol/context.scm \
                 module/playnet/utils/host.scm \
                    module/playnet/vf/beyond/scenario.scm \
                    module/playnet/vf/beyond/schedules.scm \
                    module/playnet/vf/formulas/actions.scm \
                    module/playnet/vf/formulas/flows.scm \
                    module/playnet/observation/states.scm \
                    module/playnet/solve/admm-link.scm \
                    module/playnet/vf/facts/agent-tags.scm \
                    module/playnet/vf/facts/boundary.scm \
                    module/playnet/vf/formulas/cadence.scm \
                    module/playnet/vf/formulas/fragility.scm \
                    module/playnet/vf/facts/agent-time.scm \
                    module/playnet/vf/aggregation/containment.scm \
                    module/playnet/vf/aggregation/fold-node.scm \
                    module/playnet/vf/aggregation/scope-tree.scm \
                    module/playnet/algorithms/propagation.scm \
                    module/playnet/algorithms/rollup.scm \
                    module/playnet/algorithms/rollup/common.scm \
                    module/playnet/algorithms/rollup/fixpoint.scm \
                    module/playnet/algorithms/rollup/relative-snlt.scm \
                    module/playnet/knowledge/worlds/bioregions.scm \
                    module/playnet/solve/compile.scm \
                    module/playnet/solve/emphasis.scm \
                    module/playnet/solve/engine.scm \
                    module/playnet/solve/world.scm \
                    module/playnet/solve/externality.scm \
                    module/playnet/doors/family/local.scm \
                    module/playnet/doors/family/wire.scm \
                    module/playnet/doors/family/solve.scm \
                    module/playnet/solve/federation-oracle.scm \
                    module/playnet/solve/federation-solve.scm \
                    module/playnet/solve/ingest.scm \
                    module/playnet/knowledge/data/fdc-sr-legacy.scm \
                    module/playnet/knowledge/catalogues/food-sources.scm \
                    module/playnet/knowledge/catalogues/housing.scm \
                    module/playnet/knowledge/recipes/household.scm \
                    module/playnet/knowledge/dsl/shorthand.scm \
                    module/playnet/knowledge/catalogues/subsistence.scm \
                    module/playnet/knowledge/catalogues/substances.scm \
                    module/playnet/vf/facts/located.scm \
                    module/playnet/vf/facts/availability.scm \
                    module/playnet/observation/account.scm \
                    module/playnet/algorithms/elastic.scm \
                    module/playnet/vf/facts/parts.scm \
                    module/playnet/vf/formulas/periods.scm \
                    module/playnet/vf/formulas/propagate.scm \
                    module/playnet/vf/facts/rail.scm \
                    module/playnet/vf/facts/barred-specs.scm \
                    module/playnet/solve/recipe-response.scm \
                    module/playnet/solve/robust.scm \
                    module/playnet/solve/plan.scm \
                    module/playnet/solve/records.scm \
                    module/playnet/solve/report.scm \
                    module/playnet/solve/decomposed.scm \
                    module/playnet/solve/discrete.scm \
                    module/playnet/vf/schemas.scm \
                    module/playnet/vf/formulas/shocks.scm \
                    module/playnet/solve/solver.scm \
                    module/playnet/vf/formulas/stocks.scm \
                    module/playnet/utils/store-utils.scm \
                    module/playnet/vf/formulas/tension-kinds.scm \
                    module/playnet/vf/formulas/capacity.scm \
                    module/playnet/vf/serdes.scm \
                    module/playnet/vf/facts/tension-terms.scm \
                    module/playnet/solve/voice-field.scm \
                    module/playnet/utils/alist.scm \
                    module/playnet/utils/catch.scm \
                    module/playnet/utils/clock.scm \
                    module/playnet/utils/hashmap.scm \
                    module/playnet/utils/json-portable.scm \
                    module/playnet/utils/keywords.scm \
                    module/playnet/utils/records.scm \
                    module/playnet/utils/keyed-id.scm \
                    module/playnet/utils/units.scm \
                    module/playnet/wire/rows.scm

browser/family.wasm: hoot/family-worker.scm $(FAMILY_WASM_DEPS) $(HOOT_TOOLCHAIN_STAMP)
	$(HOOT_BUILD_DEV) bash -c 'guild compile-wasm $(HOOT_PLANNER_ARGS) -o browser/family.wasm hoot/family-worker.scm'

# boots browser/family.wasm under node, through the page's own boot module, and
# asks it the demo week: the same answer the planner test measured
.PHONY: check-family-worker
check-family-worker: browser/family.wasm
	node tools/test/check-family-worker.cjs

# ── A scope on the device ───────────────────────────────────────────────────
# browser/scope.wasm is a whole scope for the page (hoot/scope-worker.scm over
# (playnet doors page-scope)): the demo neighbourhood's books and a person's
# own, answering the doors a gateway answers, run in browser/scope-worker.js. A
# gitignored build product like family.wasm.
# Transitive (playnet …) import closure of hoot/scope-worker.scm; see
# `make check-wasm-deps`.
SCOPE_WASM_DEPS = \
                 module/playnet/legal/body-roles.scm \
                 module/playnet/plan/rotation.scm \
                 module/playnet/utils/lei.scm \
                 module/playnet/utils/operator.scm \
                 module/playnet/algorithms/correlation.scm \
                 module/playnet/algorithms/option-composition.scm \
                 module/playnet/algorithms/option-premium.scm \
                 module/playnet/doors/record-rows.scm \
                 module/playnet/folksonomy/graph.scm \
                 module/playnet/knowledge/dsl/findings.scm \
                 module/playnet/legal/adapters.scm \
                 module/playnet/legal/bodies.scm \
                 module/playnet/protocol/context.scm \
                 module/playnet/utils/host.scm \
                   module/playnet/scope/ballot-store.scm \
                   module/playnet/scope/demand-registry.scm \
                   module/playnet/keri/acdc.scm \
                   module/playnet/keri/cesr.scm \
                   module/playnet/keri/crypto-primitives.scm \
                   module/playnet/keri/said-portable.scm \
                   module/playnet/keri/said.scm \
                   module/playnet/vf/beyond/lot.scm \
                   module/playnet/vf/beyond/scenario.scm \
                   module/playnet/vf/beyond/schedules.scm \
                   module/playnet/vf/formulas/actions.scm \
                   module/playnet/vf/formulas/flows.scm \
                   module/playnet/observation/states.scm \
                   module/playnet/plan/accepts.scm \
                   module/playnet/solve/admm-link.scm \
                   module/playnet/vf/facts/agent-tags.scm \
                   module/playnet/vf/facts/boundary.scm \
                   module/playnet/vf/formulas/cadence.scm \
                   module/playnet/vf/formulas/fragility.scm \
                   module/playnet/vf/facts/agent-time.scm \
                   module/playnet/scope/agents.scm \
                   module/playnet/vf/aggregation/containment.scm \
                   module/playnet/vf/aggregation/fold-node.scm \
                   module/playnet/vf/aggregation/scope-tree.scm \
                   module/playnet/algorithms/propagation.scm \
                   module/playnet/algorithms/rollup.scm \
                   module/playnet/algorithms/rollup/common.scm \
                   module/playnet/algorithms/rollup/fixpoint.scm \
                   module/playnet/algorithms/rollup/relative-snlt.scm \
                   module/playnet/algorithms/signals.scm \
                   module/playnet/vf/facts/audit.scm \
                   module/playnet/knowledge/worlds/bioregions.scm \
                   module/playnet/knowledge/catalogues/compiler.scm \
                   module/playnet/solve/compile.scm \
                   module/playnet/legal/compliance.scm \
                   module/playnet/knowledge/catalogues/conformance.scm \
                   module/playnet/vf/facts/validity.scm \
                   module/playnet/doors/count-door.scm \
                   module/playnet/vf/formulas/counting.scm \
                   module/playnet/doors/counts.scm \
                   module/playnet/legal/crossings.scm \
                   module/playnet/knowledge/catalogues/eco.scm \
                   module/playnet/solve/engine.scm \
                   module/playnet/solve/world.scm \
                   module/playnet/utils/envelope.scm \
                   module/playnet/execution/alerts.scm \
                   module/playnet/solve/externality.scm \
                   module/playnet/solve/federation-oracle.scm \
                   module/playnet/solve/federation-solve.scm \
                   module/playnet/solve/ingest.scm \
                   module/playnet/plan/horizon-gate.scm \
                   module/playnet/solve/inspection.scm \
                   module/playnet/doors/inventory.scm \
                   module/playnet/knowledge/worlds/bay-area-derived.scm \
                   module/playnet/knowledge/worlds/bay-area.scm \
                   module/playnet/knowledge/worlds/berlin-derived.scm \
                   module/playnet/knowledge/worlds/berlin.scm \
                   module/playnet/ddmrp/buffer-snapshots.scm \
                   module/playnet/ddmrp/buffer-zones.scm \
                   module/playnet/ddmrp/capacity-buffers.scm \
                   module/playnet/ddmrp/records.scm \
                   module/playnet/knowledge/worlds/cascadia-derived.scm \
                   module/playnet/knowledge/worlds/cascadia.scm \
                   module/playnet/knowledge/law/context-pack.scm \
                   module/playnet/knowledge/law/pack-dir.scm \
                   module/playnet/knowledge/data/fdc-sr-legacy.scm \
                   module/playnet/knowledge/worlds/demo-neighbourhood.scm \
                   module/playnet/knowledge/catalogues/diets.scm \
                   module/playnet/knowledge/worlds/doon-derived.scm \
                   module/playnet/knowledge/worlds/doon-shed.scm \
                   module/playnet/knowledge/worlds/sheds.scm \
                   module/playnet/knowledge/worlds/doon-valley.scm \
                   module/playnet/knowledge/catalogues/food-sources.scm \
                   module/playnet/knowledge/catalogues/housing.scm \
                   module/playnet/knowledge/catalogues/housing-substance.scm \
                   module/playnet/knowledge/law/incumbent-readings.scm \
                   module/playnet/knowledge/catalogues/insurance.scm \
                   module/playnet/knowledge/law/aspects.scm \
                   module/playnet/vf/facts/places.scm \
                   module/playnet/knowledge/law/protections.scm \
                   module/playnet/knowledge/recipes/store.scm \
                   module/playnet/knowledge/recipes/dwelling.scm \
                   module/playnet/knowledge/recipes/transport.scm \
                   module/playnet/knowledge/catalogues/rest.scm \
                   module/playnet/knowledge/dsl/shorthand.scm \
                   module/playnet/scope/spatial-things.scm \
                   module/playnet/knowledge/catalogues/subsistence.scm \
                   module/playnet/knowledge/catalogues/substances.scm \
                   module/playnet/knowledge/catalogues/thermal.scm \
                   module/playnet/knowledge/dsl/world.scm \
                   module/playnet/vf/facts/labels.scm \
                   module/playnet/algorithms/deferred-acceptance.scm \
                   module/playnet/plan/assignment.scm \
                   module/playnet/legal/gate.scm \
                   module/playnet/legal/policy.scm \
                   module/playnet/legal/registry-actor.scm \
                   module/playnet/legal/registry.scm \
                   module/playnet/scope/live.scm \
                   module/playnet/vf/facts/located.scm \
                   module/playnet/vf/facts/availability.scm \
                   module/playnet/observation/account.scm \
                   module/playnet/observation/adjustment.scm \
                   module/playnet/observation/convert.scm \
                   module/playnet/algorithms/elastic.scm \
                   module/playnet/observation/evidence.scm \
                   module/playnet/observation/live-registry.scm \
                   module/playnet/observation/live-resource.scm \
                   module/playnet/observation/log-observe.scm \
                   module/playnet/observation/observer.scm \
                   module/playnet/pools/reading-fold.scm \
                   module/playnet/doors/offers.scm \
                   module/playnet/doors/page-scope.scm \
                   module/playnet/vf/facts/parts.scm \
                   module/playnet/vf/formulas/periods.scm \
                   module/playnet/vf/facts/person-facts.scm \
                   module/playnet/plan/store.scm \
                   module/playnet/observation/practice.scm \
                   module/playnet/scope/process-registry.scm \
                   module/playnet/vf/formulas/propagate.scm \
                   module/playnet/vf/facts/rail.scm \
                   module/playnet/vf/facts/barred-specs.scm \
                   module/playnet/solve/recipe-response.scm \
                   module/playnet/legal/reform.scm \
                   module/playnet/scope/replica.scm \
                   module/playnet/solve/robust.scm \
                   module/playnet/solve/plan.scm \
                   module/playnet/solve/records.scm \
                   module/playnet/solve/report.scm \
                   module/playnet/solve/decomposed.scm \
                   module/playnet/solve/discrete.scm \
                   module/playnet/solve/routing.scm \
                   module/playnet/vf/schemas.scm \
                   module/playnet/scope/root.scm \
                   module/playnet/vf/formulas/shocks.scm \
                   module/playnet/vf/formulas/skill-law.scm \
                   module/playnet/doors/slots.scm \
                   module/playnet/scope/snapshot.scm \
                   module/playnet/solve/solver.scm \
                   module/playnet/vf/formulas/stocks.scm \
                   module/playnet/utils/store-utils.scm \
                   module/playnet/vf/formulas/tension-kinds.scm \
                   module/playnet/vf/formulas/capacity.scm \
                   module/playnet/vf/serdes.scm \
                   module/playnet/vf/facts/tension-terms.scm \
                   module/playnet/solve/voice-field.scm \
                   module/playnet/utils/alist.scm \
                   module/playnet/utils/catch.scm \
                   module/playnet/utils/clock.scm \
                   module/playnet/utils/common.scm \
                   module/playnet/utils/governed-row.scm \
                   module/playnet/utils/hashmap.scm \
                   module/playnet/utils/json-portable.scm \
                   module/playnet/utils/keyed-id.scm \
                   module/playnet/utils/keywords.scm \
                   module/playnet/utils/records.scm \
                   module/playnet/utils/units.scm \
                   module/playnet/wire/replies.scm \
                   module/playnet/wire/rows.scm \
                   module/playnet/wire/snapshot.scm

browser/scope.wasm: hoot/scope-worker.scm $(SCOPE_WASM_DEPS) $(HOOT_SCOPE_SRC)/playnet/scope/live.scm $(HOOT_TOOLCHAIN_STAMP)
	$(HOOT_BUILD_DEV) bash -c 'guild compile-wasm $(HOOT_PLANNER_ARGS) -L $(HOOT_SCOPE_SRC) -o browser/scope.wasm hoot/scope-worker.scm'
# boots browser/scope.wasm under node, through the page's own boot module, and
# asks its doors what the planner service answers of the same acts
.PHONY: check-scope-worker
check-scope-worker: browser/scope.wasm
	node tools/test/check-scope-worker.cjs

# ── Git hooks (versioned, install via symlinks) ─────────────────────────────
# Hooks live under deploy/scripts/git-hooks/ so they ride in the repo.
# .git/hooks/ is per-clone and never tracked; symlinks bridge the gap.
# The guix-git-authenticate-installed pre-push/post-merge hooks live
# elsewhere and are not touched.
.PHONY: install-hooks
install-hooks:
	@for h in pre-commit prepare-commit-msg pre-push; do \
	  ln -sf "$$(pwd)/deploy/scripts/git-hooks/$$h" ".git/hooks/$$h"; \
	  echo "installed hook: $$h"; \
	done

# ── Satellite pins (deploy/satellites.scm) ──────────────────────────────────
# The core's HEAD is the only input to the deployed system: every other repo
# is consumed at the commit + nar hash pinned in deploy/satellites.scm.
# `make bump SAT=<name>` moves one pin to ../playnet-<name>'s HEAD; the
# pre-push hook runs `check-satellite-pins` so a pin that does not resolve is
# a push refused. Plan: docs/planning/identity/repo-split-and-protocol-doors.md
check-satellite-pins:
	@GUILE_AUTO_COMPILE=0 deploy/scripts/satellite-pins.scm check

bump:
	@[ -n "$(SAT)" ] || { echo "usage: make bump SAT=<name>   (names: deploy/satellites.scm)"; exit 2; }
	@GUILE_AUTO_COMPILE=0 deploy/scripts/satellite-pins.scm bump "$(SAT)"
	@echo "now: git add deploy/satellites.scm && git commit"

# Place every pinned satellite tree into this checkout (browser/radicle for
# the explorer) from the sibling clones, hash-verified. `make serve` needs it
# once for /radicle/ to answer locally; a no-op while the stamp matches.
satellites:
	@GUILE_AUTO_COMPILE=0 deploy/scripts/satellite-pins.scm place "$(CURDIR)"

# On a machine that holds the clones: each landing directory becomes a symlink
# to ../playnet-<name>, so there is one copy of every satellite file and an
# edit under browser/radicle, server/rns-bridge, … is an edit in that
# satellite's own repo. The pin still decides what ships; `make
# check-satellite-pins` says how far each clone stands past its pin, and
# `make satellites` puts the pinned copies back.
link-satellites:
	@GUILE_AUTO_COMPILE=0 deploy/scripts/satellite-pins.scm link "$(CURDIR)"

# The one command that gives every checkout of the core the same shape:
# clone each satellite beside the core when it is not there (from the mirror
# the box serves; PLAYNET_MIRROR, PLAYNET_GIT_PREFIX=torsocks to override),
# then link it in. SAT="explorer rns-bridge" limits it to those.
workspace:
	@GUILE_AUTO_COMPILE=0 deploy/scripts/satellite-pins.scm workspace "$(CURDIR)" $(SAT)

# Re-apply the self-hosting fixes to the vendored radicle-planning-boards
# app (browser/boards/) — same-origin API base, runtime-config load order,
# CSP/SRI hashes. The deploy pipeline runs this automatically on every
# deploy (deploy/scripts/radicle-ci-hook.sh); this target is for after
# manually dropping in a freshly-fetched upstream copy locally.
patch-boards:
	@GUILE_AUTO_COMPILE=0 guile -L module deploy/scripts/patch-boards-app.scm "$(CURDIR)/browser/boards"

# Carry a satellite's Radicle storage to the box over SSH (the two nodes do
# not gossip; see deploy/scripts/carry-satellite.sh). Same box/Tor convention
# as `make ship`. Run once per new satellite and after any pin bump whose
# commit the box has not seen.
carry:
	@[ -n "$(SAT)" ] || { echo "usage: make carry SAT=<name>"; exit 2; }
	@PROMOTE_TORSOCKS= PLAYNET_BOX="$${PLAYNET_BOX:-playnet-server}" \
	  bash deploy/scripts/carry-satellite.sh "$(SAT)"

# ── OpenVTC parity (docs/planning/identity/openvtc-parity.md) ────────────────────────
# Our credential/trust layer is hand-ported from OpenVTC, not vendored — so
# there's no satellite pin to gate a build, just a "how far we've read" pin
# on their commit history. `make check-openvtc-parity` fetches upstream into
# a sibling cache (../openvtc-upstream, override PLAYNET_OPENVTC_CACHE) and
# lists commits since the pin that touch credential/trust-relevant paths.
# Read-only; never moves the pin.
.PHONY: check-openvtc-parity
check-openvtc-parity:
	@bash tools/lint/openvtc-parity-check.sh

# ── KERI + OpenVTC library (docs/planning/identity/keri-openvtc-library-split.md) ────
# lint-keri-lib holds the import boundary of module/playnet/keri (First Person included);
# keri-lib-cut builds the standalone playnet-keri repository from committed
# history (local only — publishing it is a separate, deliberate step).
.PHONY: lint-keri-lib keri-lib-cut
lint-keri-lib:
	@guile --no-auto-compile -e main -s tools/lint/lint-keri-lib.scm

keri-lib-cut: lint-keri-lib
	@bash tools/dev/publish-keri-lib.sh

# Every suite the cut ships, in a PURE shell built from the library's own
# manifest — the proof that a stranger with Guix and the playnet-keri repo has
# all it takes. The same command runs from inside the cut.
KERI_LIB_ENV = guix shell --pure -m deploy/manifests/keri-lib-manifest.scm --
.PHONY: test-keri-lib
test-keri-lib: lint-keri-lib
	@tests="$$(guile --no-auto-compile -e main -s tools/lint/lint-keri-lib.scm --manifest | grep '^tests/')"; \
	$(KERI_LIB_ENV) $(OWN_CCACHE) sh -c 'fail=0; for t in '"$$(echo $$tests)"'; do \
	  if guile --no-auto-compile -q -L module $$t >/tmp/keri-lib-test.log 2>&1; \
	  then echo "ok   $$t"; else echo "FAIL $$t"; tail -5 /tmp/keri-lib-test.log; fail=1; fi; done; exit $$fail'

# Carry a contributor's commits from playnet-keri into the core: held to the
# library's paths, proven in a scratch worktree (gate + every shipped suite),
# landed under their author.  usage: make keri-lib-take RANGE=main..patch/<id>
.PHONY: keri-lib-take
keri-lib-take:
	@[ -n "$(RANGE)" ] || { echo "usage: make keri-lib-take RANGE=main..patch/<id>   (a range in ../playnet-keri)"; exit 2; }
	@bash tools/dev/keri-lib-take.sh "$(RANGE)"

# Publish a cut the way every satellite moves: cut from committed history,
# sign the tip with the key the core's commits carry (filter-repo writes
# unsigned commits; a signed tag over the tip commits to the whole history
# under it), push to Radicle, carry the storage to
# the box (the two nodes do not gossip), move the pin. Then commit
# deploy/satellites.scm and `make ship`.
.PHONY: keri-lib-publish
keri-lib-publish: keri-lib-cut
	@cd ../playnet-keri && tag="cut-$$(git -C $(CURDIR) rev-parse --short=12 HEAD)" && \
	  { git rev-parse -q --verify "refs/tags/$$tag" >/dev/null || git -c user.signingkey="$$(git -C $(CURDIR) config user.signingkey)" -c user.name="$$(git -C $(CURDIR) config user.name)" -c user.email="$$(git -C $(CURDIR) config user.email)" tag -s "$$tag" -m "playnet-keri cut from core $$(git -C $(CURDIR) rev-parse HEAD)"; } && \
	  git push rad HEAD:main keyring && git push rad "refs/tags/$$tag"
	@$(MAKE) --no-print-directory bump SAT=keri
	@$(MAKE) --no-print-directory carry SAT=keri
	@echo "now: git add deploy/satellites.scm && git commit && make ship"

# ── Laptop-side secret backups (three-tier redundancy) ──────────────────────
# Tier 1: USB    — deploy/.age-key.txt + deploy/secrets.scm.age  (working copy)
# Tier 2: laptop — ~/.playnet-secrets/playnet.age-key.txt + .secrets.scm
# Tier 3: vault  — ~/.playnet-secrets/playnet-vault.kdbx attachments
#
# `make backup-laptop` refreshes tier 2 from tier 1 (no interaction).
# `make backup-vault` updates tier 3 from tier 2 (prompts for vault pw once).
# `make backup-all` does both.
PLAYNET_HOME_SECRETS = $(HOME)/.playnet-secrets
.PHONY: backup-laptop backup-vault backup-all
backup-laptop:
	@mkdir -p "$(PLAYNET_HOME_SECRETS)"
	@chmod 700 "$(PLAYNET_HOME_SECRETS)"
	@cp -f deploy/.age-key.txt "$(PLAYNET_HOME_SECRETS)/playnet.age-key.txt"
	@chmod 600 "$(PLAYNET_HOME_SECRETS)/playnet.age-key.txt"
	@age -d -i deploy/.age-key.txt deploy/secrets.scm.age \
	  > "$(PLAYNET_HOME_SECRETS)/playnet.secrets.scm"
	@chmod 600 "$(PLAYNET_HOME_SECRETS)/playnet.secrets.scm"
	@echo "tier 2 refreshed:"
	@echo "  $(PLAYNET_HOME_SECRETS)/playnet.age-key.txt"
	@echo "  $(PLAYNET_HOME_SECRETS)/playnet.secrets.scm"

backup-vault:
	bash deploy/scripts/backup-to-vault.sh

backup-all: backup-laptop backup-vault

CHANNELS = deploy/channels.scm

# ── Bootable ISO (Path B of the confidential-VPS provider deploy story) ─────
# Builds a minimal Guix System ISO with the operator SSH key baked in.
# See deploy/playnet-iso.scm (provider-specific guide — kept in the private
# ops vault, not in the public repo).
#
#   make iso         → iso9660 image (for the provider's "Custom ISO" upload)
#   make iso-raw     → raw disk image (for providers that dd onto disk)
#
# Both targets create a stable symlink (./result-iso, ./result-iso-raw)
# that doubles as a Guix GC root — the built image survives `guix gc`
# between iterations. Cookbook §3.3 (System Image API).
.PHONY: iso iso-raw
iso:
	guix time-machine -C $(CHANNELS) -- \
	  system image --root=result-iso -t iso9660 -L deploy/guix \
	  deploy/playnet-iso.scm

iso-raw:
	guix time-machine -C $(CHANNELS) -- \
	  system image --root=result-iso-raw -t mbr-hybrid-raw -L deploy/guix \
	  deploy/playnet-iso.scm

# Build the ISO and publish it to IPFS so the VPS provider (or any provider that
# requires an HTTPS URL) can fetch from a public gateway. Writes the CID
# to deploy/iso-cid.txt for downstream consumers. CI runs this on push
# to main; commits the updated cid file back with [skip ci].
#
#   make publish-iso
#
# Requires `ipfs` (Kubo) installed and daemon running. Optional remote
# pinning service via PUBLISH_ISO_PIN_SERVICE=pinata|web3storage.
# See deploy/scripts/publish-iso.sh for full env-var docs.
.PHONY: publish-iso
publish-iso:
	bash deploy/scripts/publish-iso.sh

# Boot the ISO locally in QEMU with port-forwarded SSH (host 2222 → guest 22).
# Smoke test the operator key + installer before uploading to the provider.
# Builds the ISO first if needed. See deploy/scripts/qemu-test-iso.sh.
#
#   make qemu                # build + boot, fresh 10GB disk each time
#   KEEP_DISK=1 make qemu    # preserve the disk between runs
#
# In another terminal:
#   ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
#     root@localhost
.PHONY: qemu
qemu:
	guix shell qemu ovmf -- bash deploy/scripts/qemu-test-iso.sh

# ── Workstation → server: apply production OS via guix deploy ───────────────
# Runs from your workstation against a host that's been installed by the ISO
# (or the provider's prebuilt Guix). Pinned via channels.scm.
#
#   make deploy PROVIDER=deploy/providers/provider-1.scm
#
# Optional: DEPLOY_SSH_IDENTITY=~/.ssh/id_ed25519 (read by machines.scm).
.PHONY: deploy
deploy:
ifndef PROVIDER
	$(error PROVIDER is required, e.g. make deploy PROVIDER=deploy/providers/provider-1.scm)
endif
	PLAYNET_PROVIDER=$(PROVIDER) \
	  guix time-machine -C $(CHANNELS) -- \
	  deploy -L deploy/guix -L module deploy/machines.scm

# ── Server-side reconfigure (run ON the server, not laptop) ─────────────────
# Smaller closure delta because the server's local store already has the
# deps — only what changed in our config gets built. Preferred over `make
# deploy` from laptop, which transfers laptop↔server divergence (often
# 500 MB+ if laptop's guix is newer).
#
#   sudo PROVIDER=deploy/providers/provider-1.scm make reconfigure
#
# Prereq once: `sudo guix pull` to bound the closure delta.
#
# guix system reconfigure loads the new generation but leaves every
# already-running service on its OLD one, config changes included — Guix
# computes which running services could restart and never acts on that list
# (reference_guix_reconfigure_no_restart memory; the manual's own guix
# deploy advice says restarting is the operator's job). reconfigure-restarts.sh
# is that job, done: nginx and the radicle-configure one-shot, the two this
# box has actually needed it for.
.PHONY: reconfigure
reconfigure:
ifndef PROVIDER
	$(error PROVIDER is required, e.g. PROVIDER=deploy/providers/provider-1.scm)
endif
	PLAYNET_PROVIDER=$(PROVIDER) \
	  guix system reconfigure -L deploy/guix deploy/os.scm
	@bash deploy/scripts/reconfigure-restarts.sh

# Mint a fresh First-Person founder identity (fallback path — prefer signing
# up on the dial so the key never leaves the browser). Prints a passcode +
# AID; activate with `bash deploy/scripts/add-founder.sh <AID>`.
.PHONY: founder
founder:
	$(TEST_ENV) \
	  guile --no-auto-compile -q -L module deploy/scripts/mk-founder.scm

# ── Multi-developer flow (see CONTRIBUTING.md) ──────────────────────────────
# contributor: one-command onboarding — mint a local Radicle identity. Needs
# NO infra access. After this, `rad clone $$PLAYNET_RID --seed <seed>` (get the
# seed from a maintainer; it is intentionally not committed — opsec) then
# `rad patch open` to contribute.
.PHONY: contributor
contributor:
	@command -v rad >/dev/null || { echo "rad CLI not found — install Radicle 1.7+ (https://radicle.xyz)"; exit 1; }
	@rad auth
	@echo ""
	@echo "Identity minted. Next:"
	@echo "  export PLAYNET_RID=rad:z27dFkN28LQAsSsG3DVHcfBqYAArQ"
	@echo "  export PLAYNET_SEED='<node-id>@<seed-host>:<port>'   # ask a maintainer"
	@echo "  rad clone \$$PLAYNET_RID --seed \$$PLAYNET_SEED"
	@echo "Then: hack → make test → git commit -S → rad patch open. See CONTRIBUTING.md."

# merge-patch: DELEGATE action — promote a reviewed patch to canonical + deploy.
# Contributors never run this.  usage: make merge-patch PATCH=<patch-id>
.PHONY: merge-patch
merge-patch:
	@test -n "$(PATCH)" || { echo "usage: make merge-patch PATCH=<patch-id>"; exit 1; }
	bash deploy/scripts/merge-patch.sh $(PATCH)

# ship: DELEGATE — one command to update the board + deploy from your own main.
# Signs the current main as ops, carries the delegate ref to the box seed
# (canonical is a quorum of BOTH delegate refs — the box push alone leaves the
# Explorer frozen), advances canonical, and deploys. Uses the Tor ssh alias, no
# torsocks. Defaults to HEAD; override with SHA=<commit> and/or PLAYNET_BOX=.
.PHONY: ship
ship:
	@SECRETS="$(PLAYNET_HOME_SECRETS)/playnet.secrets.scm"; \
	OMAR=""; \
	[ -f "$$SECRETS" ] && OMAR="$$(sed -n 's/.*setenv "RAD_OMAR_PASSPHRASE" "\([^"]*\)".*/\1/p' "$$SECRETS")"; \
	if [ -z "$$OMAR" ]; then \
	  echo "note: RAD_OMAR_PASSPHRASE not set in secrets — relying on the radicle agent."; \
	  echo "      For headless/automatic canonical propagation, add it to the age secrets:"; \
	  echo "        bash deploy/scripts/secrets-decrypt.sh  # -> deploy/secrets.scm"; \
	  echo "        \$$EDITOR deploy/secrets.scm             # set (setenv \"RAD_OMAR_PASSPHRASE\" \"…\")"; \
	  echo "        bash deploy/scripts/secrets-encrypt.sh && make backup-laptop && shred -u deploy/secrets.scm"; \
	fi; \
	RAD_OMAR_PASSPHRASE="$$OMAR" PROMOTE_TORSOCKS= PLAYNET_BOX="$${PLAYNET_BOX:-playnet-server}" \
	  bash deploy/scripts/promote.sh "$(or $(SHA),$$(git rev-parse HEAD))" omar

TIME_MACHINE = guix time-machine -C $(CHANNELS) --
# The wasm toolchain: Hoot 0.9.0 of the pinned Guix commit (GUIX_CHANNEL_PIN
# below) plus the upstream fixes deploy/guix/playnet-hoot.scm carries.
# `--commit=` time-machines the guix channel alone, so the Radicle channel's
# libgit2 hang stays out of the way and every machine, the box included,
# resolves the same Hoot, Goblins, fibers and Guile. The -L path is absolute
# because `local-file` resolves the patch files against it.
HOOT_PINNED = guix time-machine --commit=$(GUIX_CHANNEL_PIN) --
HOOT_PKG = -L $(CURDIR)/deploy/guix -e '(@ (playnet-hoot) guile-hoot/playnet)'

# Every wasm bundle loads the same browser/reflect.js, which belongs to the Hoot
# that compiled the bundles: one wasm built by another Hoot cannot instantiate
# under it. A toolchain change (the Guix pin, playnet-hoot.scm, its patches) is
# therefore a rebuild-everything event that no source file records, so the stamp
# below carries it: it is rewritten only when the toolchain's identity changes,
# and every wasm rule lists it as a prerequisite.
HOOT_TOOLCHAIN_ID = $(GUIX_CHANNEL_PIN) $(shell cat deploy/guix/playnet-hoot.scm deploy/guix/patches/hoot/*.patch | sha256sum | cut -c1-16)
.PHONY: FORCE
FORCE:
$(HOOT_TOOLCHAIN_STAMP): FORCE
	@echo '$(HOOT_TOOLCHAIN_ID)' | cmp -s - $@ || echo '$(HOOT_TOOLCHAIN_ID)' > $@

# ── Two-tier runner strategy ────────────────────────────────────────────────
# The test tree runs under plain `guix shell -m dev-test-manifest.scm`
# (no time-machine) because `deploy/channels.scm` pins the `playnet` channel
# to a Radicle seed whose git HTTP bridge currently hangs `guix time-machine`'s
# libgit2 client (bare `git ls-remote` works fine — it's a guix-libgit2 bug).
# Production paths (`guix deploy`, `guix pull`, the live-hacking dev bundle)
# still use channels.scm — see deploy/manifests/*.scm headers for the
# trade-off explainer. When the seed's bridge becomes libgit2-friendly again,
# `make test-all-pinned` is the reproducibility canary that lights up.
#
#   GUILE_RUN       — vanilla server-side Guile + Goblins (REPLs, relay, server)
#                     [pinned via time-machine — production semantics]
#   GUILE_TEST      — same as GUILE_RUN; pinned. Used by test-all-pinned.
#   GUILE_TEST_DEV  — fast dev test runner; non-pinned. Used by test-all and
#                     the inner-loop test-* targets.
#   HOOT_RUN        — Hoot 0.9 + fibers + websocket (anything that imports
#                     `(hoot web-server)` / `(hoot web-repl)`) [guix-pinned]
#   HOOT_RUN_DEV    — the same environment; the dev spelling `make serve` uses.
#   HOOT_BUILD      — environment for `guild compile-wasm` (no `guile`, just the
#                     tool the wasm compiler needs) [guix-pinned]
#   HOOT_BUILD_DEV  — the same environment; the dev spelling the wasm rules use.
GUILE_RUN      = $(TIME_MACHINE) shell guile-next guile-goblins -- \
                   $(OWN_CCACHE) guile --no-auto-compile
GUILE_TEST     = $(GUILE_RUN)
# ── the one door into the test environment ──────────────────────────────────
# Every dev-manifest target goes through this, so there is a single place where
# what the suite may see is decided.
#
# --pure IS THE POINT. `guix shell` without it inherits PATH and the loader's
# search, so the environment that ran the tests was the manifest PLUS whatever
# the developer's machine happened to carry — and three separate things were
# quietly coming from the host rather than from the manifest: the C compiler
# (/usr/bin/cc, where the profile has no `cc` at all), libosqp, and GNU units.
# All three passed here and failed on CI, which is the only reason we know.
# A manifest that is not enforced is a description of an environment nobody
# runs.
#
# LC_ALL=C.UTF-8 because --pure takes the locale too and Guile then renders the
# suite's box-drawing and ✓ as `?`. C.UTF-8 is built into glibc and needs no
# locale package — glibc-locales is 972 MB, and the requirement here is UTF-8,
# not every collation on earth.
#
# OWN_CCACHE keys Guile's compiled-file cache by the guile BINARY the shell
# resolves. Two builds of one version share ~/.cache/guile/ccache/3.0-LE-8-4.7,
# and a .go one compiled kills the other ("expecting mutable bytevector",
# 117 suites red, zero regressions) — see tools/test/own-ccache.sh. Every guile
# entry point below goes through it, so the manifest's guile, the pinned
# time-machine guile and Hoot's guile-next each read only what they wrote.
OWN_CCACHE = bash tools/test/own-ccache.sh
TEST_ENV = guix shell --pure -L deploy/guix \
             -m deploy/manifests/dev-test-manifest.scm -- $(OWN_CCACHE) env LC_ALL=C.UTF-8

GUILE_TEST_DEV = $(TEST_ENV) guile --no-auto-compile

# The development scope's own tool (tools/dev/dev-plan.scm) needs `rad` on PATH
# beside the manifest's solver — NOT --pure, since `rad` lives in the host
# profile and the manifest never names it.
DEV_ENV = guix shell -L deploy/guix -m deploy/manifests/dev-test-manifest.scm -- $(OWN_CCACHE) env LC_ALL=C.UTF-8

HOOT_RUN       = $(HOOT_PINNED) shell guile-next $(HOOT_PKG) \
                   guile-goblins guile-fibers guile-websocket guile-zlib -- \
                   $(OWN_CCACHE) guile --no-auto-compile
HOOT_RUN_DEV   = $(HOOT_RUN)
HOOT_BUILD     = $(HOOT_PINNED) shell guile-next $(HOOT_PKG) guile-goblins -- $(OWN_CCACHE)
HOOT_BUILD_DEV = $(HOOT_BUILD)

# Hoot's `guild compile-wasm` resolves imports strictly from `-L` paths
# (it does NOT consult GUILE_LOAD_PATH; see hoot/scripts/compile-wasm.scm
# → library-load-path-extension). Goblins lives in the guix profile, so
# we resolve the active profile's site dir at make time and pass it via -L.
# CRITICAL: this goblins MUST match the deployed gateway's version. The
# OCapN WebSocket designator handshake changed 0.17->0.18 (designator nonce
# size + framing); a wasm built against a different goblins than the gateway
# runs is rejected at connect with "WebSocket designator verification failed"
# — every browser client silently fails. A bare `guix build guile-goblins`
# uses the build host's channel (was 0.17.0 while production ran 0.18.0 → the
# 2026-06-07 outage). PIN to the guix channel commit from deploy/channels.scm
# via a guix-only time-machine (reliable; skips the radicle playnet channel).
# Bump GUIX_CHANNEL_PIN in lockstep with deploy/channels.scm (name 'guix).
GUIX_CHANNEL_PIN = 5f42ab7d46cf22b19844521b2385a7890faf274b
GOBLINS_PREFIX = $(shell guix time-machine --commit=$(GUIX_CHANNEL_PIN) -- build guile-goblins 2>/dev/null)
GOBLINS_LOAD_PATH = $(GOBLINS_PREFIX)/share/guile/site/3.0
GOBLINS_CCACHE    = $(GOBLINS_PREFIX)/lib/guile/3.0/site-ccache

# hoot/repl.scm imports (fibers channels) and (fibers conditions), and
# compile-wasm reads imports ONLY from -L (see the note above the wasm
# rules). Resolve fibers from the same pin as goblins, for the same reason
# and by the same mechanism, so a checkout needs no local symlink farm to
# build the wasm bundles.
FIBERS_PREFIX = $(shell guix time-machine --commit=$(GUIX_CHANNEL_PIN) -- build guile-fibers 2>/dev/null)
FIBERS_LOAD_PATH = $(FIBERS_PREFIX)/share/guile/site/3.0

# Any process that talks OCapN to browser/*.wasm MUST use this same pinned
# Goblins. The wasm bundles are compiled against it; an ambient `guix shell
# guile-goblins` can resolve to a different version, and the OCapN websocket
# handshake is NOT compatible across versions — it fails as "WebSocket
# designator verification failed" in the browser and "invalid client
# verification message" in the gateway log. tests/ux/ux-full.sh and
# tools/dev/dev.sh both read these via `make -s print-goblins-path`.
.PHONY: print-goblins-path
print-goblins-path:
	@echo "$(GOBLINS_LOAD_PATH):$(GOBLINS_CCACHE)"

# Same idea for fibers, so a hand-run `guild compile-wasm` outside the
# Makefile can pass the same pinned -L the build rules use.
.PHONY: print-fibers-path
print-fibers-path:
	@echo "$(FIBERS_LOAD_PATH)"

# ── Local dev REPLs ──────────────────────────────────────────────────────────

repl:
	$(GUILE_RUN) -L module server/repl.scm

quick-repl:
	$(GUILE_RUN) -L module server/play-repl.scm

# ── Wasm builds ──────────────────────────────────────────────────────────────

# Prerequisites are the transitive (playnet …) import closure of
# hoot/repl.scm. `make check-wasm-deps` proves this list still covers
# it — a MISSING entry is the dangerous direction, because make then
# reports a stale wasm as up to date and a broken module never rebuilds.
REPL_WASM_DEPS = \
                 module/playnet/crypto/shamir.scm \
                 module/playnet/utils/records.scm \
                 module/playnet/wire/rows.scm \
                 module/playnet/keri/cesr.scm \
                 module/playnet/keri/crypto-primitives-browser.scm \
                 module/playnet/keri/crypto-primitives.scm \
                 module/playnet/keri/did.scm \
                 module/playnet/keri/reticulum-binding.scm \
                 module/playnet/utils/host.scm \
                 module/playnet/keri/signify-portable.scm \
                 module/playnet/lang/autocomplete.scm \
                 module/playnet/lang/kanren.scm \
                 module/playnet/lang/wisp.scm \
                 module/playnet/utils/endorsement.scm \
                 module/playnet/org/gplay.scm \
                 module/playnet/ui/calendar.scm \
                 module/playnet/calendar/ical.scm \
                 module/playnet/ui/clock.scm \
                 module/playnet/ui/components.scm \
                 module/playnet/ui/contacts.scm \
                 module/playnet/ui/federation-solver.scm \
                 module/playnet/ui/federation.scm \
                 module/playnet/ui/identity.scm \
                 module/playnet/ui/inventory.scm \
                 module/playnet/ui/map.scm \
                 module/playnet/ui/network.scm \
                 module/playnet/ui/priorities.scm \
                 module/playnet/ui/recipes.scm \
                 module/playnet/ui/treemap.scm \
                 module/playnet/ui/zone-format.scm \
                 module/playnet/utils/alist.scm \
                 module/playnet/utils/hex.scm \
                 module/playnet/utils/json-portable.scm

browser/repl.wasm: hoot/repl.scm $(REPL_WASM_DEPS) $(HOOT_TOOLCHAIN_STAMP)
	$(HOOT_BUILD_DEV) \
	  guild compile-wasm -L module -L $(FIBERS_LOAD_PATH) \
	    -L $(GOBLINS_LOAD_PATH) \
	    --bundle -o browser/repl.wasm hoot/repl.scm
	./tools/dev/patch-reflect-mime.sh

# `serve` just runs the server — it does NOT build anything. The wasms
# (day-boot.wasm, repl.wasm) are gitignored BUILD PRODUCTS (the box builds
# its own on deploy), so a fresh clone has none until you run `make`. Making
# serve depend on repl.wasm meant every `git` op (which bumps source mtimes)
# triggered a spurious multi-minute wasm recompile before the server would
# start, so serve only CHECKS they exist and says how to build them. Build
# explicitly when you change their sources: `make browser/repl.wasm` /
# `make browser/day-boot.wasm` (or `make` for both).
serve:
	@for w in browser/repl.wasm browser/day-boot.wasm; do \
	  [ -f $$w ] || echo "make serve: $$w is absent (build product) — the dial needs it: run \`make $$w\` (or \`make\` for both)"; \
	done
	@P="$(if $(PORT),$(PORT),8080)"; \
	if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":$$P "; then \
	  echo "make serve: port $$P is already in use — a stray server is squatting on it."; \
	  echo "  free it:  pkill -f 'run-static-server'; pkill -f 'http.server'"; \
	  echo "  or:       PORT=8081 make serve"; \
	  exit 1; \
	fi
	PLAYNET_DEV=1 PLAYNET_FIBERS=1 $(HOOT_RUN_DEV) -L . -L module \
	  -c '((@ (server serve-static) run-static-server) #:work-dir "browser" #:oobi-dir "$(if $(OOBI_DIR),$(OOBI_DIR),data/oobi-host)" #:port $(if $(PORT),$(PORT),8080))'

# Reliable headless SCREENSHOT of a local page — via Playwright + guix
# ungoogled-chromium (UNCONFINED). The snap Firefox hangs headless under
# Wayland/snap confinement from a non-login shell, so we don't use it. Needs
# `make serve` running. Writes outside the repo by default.
#   make shot                                  # the share face → ~/playnet-dev-shots/shot.png
#   make shot URL='http://127.0.0.1:8080/app.html?face=cal' OUT=/tmp/cal.png W=420 H=800
.PHONY: shot
shot:
	bash tools/dev/shot.sh "$(if $(URL),$(URL),http://127.0.0.1:8080/app.html?face=share)" \
	  "$(if $(OUT),$(OUT),$(HOME)/playnet-dev-shots/shot.png)" $(if $(W),$(W),1400) $(if $(H),$(H),900)

# The day dial, LIVE: the whole local stack in ONE command — a real gateway
# (no KERIA), the static server pointed at that gateway's own state dir, and
# the URL that joins them (?gateway=<sref> — discovery's highest-priority
# source). An already-running `make serve` is reused and left alone. State
# persists in .dev-data; identity and plan survive restarts.
#   make dev
.PHONY: dev
dev: browser/day-boot.wasm
	bash tools/dev/dev.sh

# The day dial, LIVE ON YOUR PHONE, over a throwaway .onion. A dedicated tor
# instance (own data dir, system tor untouched) maps onion:80 -> :8080, and a
# file watcher live-reloads the page. Open the printed ?dev=1 URL in Tor
# Browser / Onion Browser. Needs `make serve` running in another terminal.
#   make onion            # persistent onion (bookmarkable across restarts)
#   FRESH=1 make onion    # rotate to a brand-new onion
.PHONY: onion
onion:
	bash tools/dev/onion.sh

# ── Offline routing engine (Tier-1 Valhalla; serve-static proxies /route) ───
# Data pipeline (fetch → tzdb → calendar → config → transit → tiles) and the
# engine itself live behind tools/dev/valhalla-local.sh; see its header.
.PHONY: routing-data routing-serve routing-stop
routing-data:
	bash tools/dev/valhalla-local.sh all
routing-serve:
	bash tools/dev/valhalla-local.sh serve
routing-stop:
	bash tools/dev/valhalla-local.sh stop

# The basemap's archives: tools/emit/map-tiles.sh cuts one PMTiles file per region of
# tools/emit/regions.tsv from a Protomaps build of OpenStreetMap (a range read of
# the planet file, over Tor) into data/map/, and fetches the labels' glyphs
# into browser/assets/map/fonts/. Both are out of git; the deploy rsync ships
# the glyphs with browser/, and the box cuts its own archives.
#   make map-tiles                        every region to z15
#   REGIONS=berlin MAXZOOM=12 make map-tiles
#   MAP_DIR=/var/lib/playnet/map make map-tiles    on the box
.PHONY: map-tiles
map-tiles:
	bash tools/emit/map-tiles.sh

# test      — the FULL green baseline: every hermetic .scm test under tests/ and
#             module/**/tests/, auto-discovered (a new test file can never rot by
#             being forgotten from this Makefile), minus tests/QUARANTINE (each
#             exclusion carries its reason). Green/red is the process exit code —
#             the harness's test-summary! already exits 1 on any failure. One guix
#             shell is entered for the whole run; the runner loops guile inside it.
# test-fast  — the curated quick subset, for the tight pre-push / dev inner loop.
# ── CI's test environment, made resident ────────────────────────────────────
# `make test` enters `guix shell -m dev-test-manifest.scm`. On a machine where
# that manifest is not already in the store, the shell BUILDS it first — and on
# the box no substitute exists for blake3, so every CI run spent its whole
# budget compiling and never reached the runner. The job reported failure with
# an empty log, which read as "the tests are red" and was really "the tests
# never ran". CI had not validated a commit since the broker took over.
#
# `guix shell --root` is the fix Guix already provides: it materialises the
# environment AND registers a GC root, so the closure survives `guix gc` and
# every later shell for that manifest is a store lookup (measured on the box:
# 13 MB source build → 2.9 s).
#
# RE-RUN IT AFTER EVERY MANIFEST CHANGE. The root pins the profile it was made
# from, not the manifest, so adding a package leaves the new closure unprotected
# while the stale root still looks present and correct — which is exactly what
# happened when gcc-toolchain, osqp, units and findutils joined the manifest.
# `guix shell --root` refuses to overwrite an existing symlink, so this target
# claimed to be idempotent and errored out on its second run; the old root is
# dropped first, which is what makes the claim true.
#
#   make ci-warm                       # on the machine that runs CI
#   ssh <box> 'cd <checkout> && make ci-warm'
CI_ENV_ROOT ?= /var/lib/playnet/ci-test-env
.PHONY: ci-warm
ci-warm:
	rm -f $(CI_ENV_ROOT)
	guix shell -L deploy/guix -m deploy/manifests/dev-test-manifest.scm \
	  --root=$(CI_ENV_ROOT) -- true
	@echo "  ✓ test environment resident at $(CI_ENV_ROOT) (a GC root; gc will not collect it)"

# The same for the wasm toolchain. `guix shell` caches no profile and
# registers no root, so the first `guix gc` after a wasm build collects the
# patched Hoot and the next build compiles it again from source: ~10 minutes
# on the box, found 2026-09-23 the first time a gc actually ran there. This
# root is the same package set as HOOT_BUILD_DEV, so it pins exactly the
# closure that build resolves. The deploy hook runs it before every wasm build;
# re-run it by hand after a change to playnet-hoot.scm or the pinned Guix.
#
# `guix build --root` registers one root per output (HOOT_ENV_ROOT-0, -1, …)
# and exits cleanly. At the pinned Guix, `guix shell guile-next guile-hoot
# --root=…` registers its root and then aborts with a struct-vtable error in the
# error reporter (guile-next with guile-hoot is the trigger; either alone is
# fine, and the same command succeeds on Guix master of 2026-10-01).
HOOT_ENV_ROOT ?= /var/lib/playnet/hoot-env
.PHONY: hoot-warm
hoot-warm:
	rm -f $(HOOT_ENV_ROOT) $(HOOT_ENV_ROOT)-*
	$(HOOT_PINNED) build guile-next guile-goblins $(HOOT_PKG) \
	  --root=$(HOOT_ENV_ROOT) >/dev/null
	@echo "  ✓ wasm toolchain resident at $(HOOT_ENV_ROOT)-* (GC roots; gc will not collect them)"

# ── and kept fresh without anyone remembering ───────────────────────────────
# A GC root pins the profile it was made FROM, not the manifest, so it goes
# stale the moment a package is added — while still looking perfectly healthy.
# Nothing about a stale root is visible until `guix gc` collects the closure it
# was supposed to protect and CI is back to compiling blake3 from source.
#
# Hanging this off `make ship` was the obvious move and is the wrong one: ship
# runs on a laptop and the root lives on the box, so it would faithfully
# maintain a GC root on the machine that does not need one. The machine that
# needs it is the machine that runs the suite — so the suite maintains it, on
# whatever host it happens to be running, every time.
#
# Silent everywhere else: the guard is whether this host has a writable
# directory to put the root in. A developer's laptop has no /var/lib/playnet,
# so this is a no-op there and `make test` is unchanged.
.PHONY: ci-env
ci-env:
	@if [ -w "$$(dirname $(CI_ENV_ROOT))" ]; then \
	  $(MAKE) --no-print-directory ci-warm >/dev/null 2>&1 \
	    && echo "  ✓ test-env GC root refreshed → $$(readlink $(CI_ENV_ROOT))" \
	    || echo "  ! could not refresh the test-env GC root at $(CI_ENV_ROOT)" >&2; \
	fi

# ── the compiled hot loop ───────────────────────────────────────────────────
# planner.scm's `native-c` backend dlopens this, and it is a build artifact: the
# .c and the generated header are tracked, the .so is not. So a fresh checkout —
# CI's, or a new contributor's — has every source it needs and cannot run a
# single native-c solve until this rule fires. Make's own dependency is the
# honest place to say that; before it existed the suite passed only on a machine
# where someone had run the kernel's Makefile by hand, which is exactly the class
# of local-state accident that the stale-.go trap is made of.
#
# It builds INSIDE the test environment, not against the host's compiler, so the
# object and the Guile that loads it come from one manifest.
KERNEL_SO := module/playnet/solve/kernel/libplanner_kernel.so
KERNEL_SRC := module/playnet/solve/kernel/kernel.c \
              module/playnet/solve/kernel/kernel_kinds.h

.PHONY: kernel
kernel: $(KERNEL_SO)

$(KERNEL_SO): $(KERNEL_SRC) module/playnet/solve/kernel/Makefile
	$(TEST_ENV) \
	  make -C module/playnet/solve/kernel

.PHONY: test test-all test-fast
# `make test RED_BASELINE=file` compares the red list by name with FILE (written on
# the first run) and fails only on a test that is red and not named there.
test test-all: lint-parens lint-law lint-layers lint-verbs lint-compile freshen-ccache $(KERNEL_SO) ci-env
	$(TEST_ENV) RED_BASELINE=$(RED_BASELINE) \
	  bash tools/test/run-scm-tests.sh

# run-scm-tests.sh leaves auto-compile ON because "a stale .go is worse than a
# slow run". That holds for imports and NOT for includes: an edited fragment
# never moves its includer's mtime, so auto-compile has nothing to react to and
# the engine loads stale. This drops exactly those .go files first, restoring
# the guarantee the runner already intends. ~1.6s, outside $(TEST_ENV) since it
# only reads mtimes.
.PHONY: freshen-ccache
freshen-ccache:
	@bash tools/test/freshen-ccache.sh

test-fast: lint-parens lint-law lint-docs check-wasm-deps check-ui-fresh test-gplay test-knowledge test-notify-registry test-notify-adapters test-push-adapter \
      test-recipient-registry test-notify-router test-email-transport check-provenance test-provenance \
      test-vault test-keystore test-handler-bridge test-capabilities test-pwa lint-sw test-rest test-bytes test-keys test-attention test-push test-rpc test-store test-idb test-log-bound test-rns-identity test-containment-fold test-reactive test-room-model test-mesh-plan test-ice-servers test-units-fallback test-utter test-count test-qr test-labels test-store-tree test-stock test-photo test-look test-lend test-contest test-store-view test-held test-demo-store test-demo-world test-symbols test-reach test-queue test-allotment-ui test-fuzzy test-conform-ui test-caption-window test-refsel test-diag-redact test-offers test-ring test-sky test-runway test-partition test-regions test-nutrition test-housing-ui test-declarations test-bran-derivations \
      test-contact-binding test-body-doors test-cards test-planner-facet test-declared-dispatch test-http-door test-mcp-door test-device-doors test-vf-lint test-lint-records-door test-issue-revoke-credential test-admit-commune-door test-delegation-scope-arg test-lobby-arg-split test-websocket-fragments test-websocket-masking test-declare-arg-split test-offer-work-drift-door test-plan-materialize-opts-door test-count-stock test-count-anchor test-count-anchor-2 test-count-expected test-wire-snapshot test-observation-evidence test-labels-containers test-counting test-planned-counts test-allotment test-see-door test-contest-count test-evidence-door check-protocol check-protocol-fresh check-wire-types-fresh check-crossing-catalogue check-nutrition-fresh check-product-law-fresh check-attribution-fresh check-notice-facts-fresh check-rid-mentions test-calendar-mail check-de-fresh check-na-fresh check-law-fresh check-physics-fresh check-housing-fresh check-count-fresh check-rel-fresh check-reach-fresh check-units-fresh check-limits-fresh check-recipe-demo-fresh check-demo-fresh test-demo-neighbourhood test-adjustment test-counts check-test-wiring

# Every tracked .scm reads to EOF. ~3s over ~1070 files, so it can sit in
# front of the whole suite rather than off to the side.
#
# The compiler already rejects an unbalanced form — but only in files some
# test imports. Standalone scripts under module/ and tools/ are read by
# nothing, so a broken paren in one is invisible until someone runs it by
# hand: (playnet utils parse-unit-definitions) carried a missing close paren
# from its first commit. This is the check that sees those.
#
# Runs OUTSIDE $(TEST_ENV) on purpose — the reader is plain Guile with no
# module resolution, so the pure shell buys nothing and costs a few seconds.
.PHONY: lint-parens
lint-parens:
	@LC_ALL=C.UTF-8 guile --no-auto-compile tools/lint/lint-parens.scm

# A planning map "read off the code" is a set of claims that a name lives at a
# line of a file. Every cite in the flow map and its companions resolves
# against the tree, and the map's fold/descent tables are pinned to
# <scope-nodes>' fields, so each document's date is a reading the tree checks.
LINTED_DOCS = docs/planning/federation/federation-flow-map.md docs/planning/federation/three-trees.md \
      docs/planning/federation/patchwork-scopes-containment.md docs/planning/federation/means-pool-uc-allocation.md \
      docs/planning/federation/labour-aggregation-architecture.md docs/planning/federation/FEDERATED-SOLVE.md \
      docs/planning/federation/federation-identity-and-folds.md \
      docs/planning/socialization/temporary-socialization.md docs/planning/voice/README.md \
      docs/observation/README.md docs/observation/measure.md docs/observation/observe.md \
      docs/observation/observe-wiring.md docs/observation/capture.md docs/observation/ngsi-ld.md docs/observation/readings-are-counts.md \
      docs/observation/physics.md docs/observation/physics-register.md docs/the-plan-and-the-laws.typ
.PHONY: lint-docs
lint-docs:
	@LC_ALL=C.UTF-8 guile --no-auto-compile tools/lint/doc-cites.scm $(LINTED_DOCS)

# A rule that names a jurisdiction no pack places can never fire, and nothing at
# runtime will ever say so. Reads the packs without registering them, so it costs
# a second and needs no vat.
#
# Runs INSIDE $(TEST_ENV): loading the packs pulls in (playnet knowledge
# context-pack), which imports (goblins). A bare `guile` finds goblins only where
# the user's profile happens to carry it, so native CI (system profile only)
# failed here with "no code for module (goblins)".
# The spec's crossing table (docs/playnet.typ `crossing-catalogue`) names the
# crossings of the code's catalogue (legal/crossings.scm), each of the same kind.
.PHONY: check-crossing-catalogue
check-crossing-catalogue:
	@$(GUILE_TEST_DEV) -L module tools/lint/check-crossing-catalogue.scm

.PHONY: lint-law
lint-law:
	@$(GUILE_TEST_DEV) -L module tools/lint/lint-law-packs.scm

# Every recipe in the tree as ValueFlows the planner can run: one store, every
# seeder, (playnet knowledge dsl vf-lint) over it. Errors fail; warnings
# and info print. tools/lint/lint-recipes.scm.
.PHONY: lint-recipes
lint-recipes:
	@LC_ALL=C.UTF-8 guile --no-auto-compile -L module tools/lint/lint-recipes.scm

# Every tracked mention of the core RID (read live via `rad inspect`) or a
# satellite's (deploy/satellites.scm) — a transition checklist, not an
# enforcement gate: it only lists, never fails, since most of what it finds
# (a README clone command, a Guix channel url) is read by a human or by Guix
# itself, not by anything this repo's own env-var reading covers. The three
# places that quote the shipped attribution's own RID token (below) are the
# exception — those regenerate.
.PHONY: check-rid-mentions
check-rid-mentions:
	@tools/lint/check-rid-mentions.sh

# The RID token in LICENSE-ADDITIONAL-TERMS.md's attribution quote and the
# bare token in both HTML footers, kept to knowledge/law/product.scm's
# `attribution` notice (the same source ui/app/legal-product.ts already
# reads) — only the token, never the prose around it in each file.
.PHONY: attribution-emit check-attribution-fresh
attribution-emit:
	@LC_ALL=C.UTF-8 guile --no-auto-compile -L module tools/emit/emit-attribution-notices.scm write
check-attribution-fresh:
	@LC_ALL=C.UTF-8 guile --no-auto-compile -L module tools/emit/emit-attribution-notices.scm check

# The figures the terms and the privacy notice quote in running prose (the
# version and date, the age floor, log rotation, the breach window, the speech
# model's size, the notice period) are stated once, in the product law's
# notices (product.scm), and written into the pages where each is marked
# `data-fact`. `make notice-facts-emit` rewrites them; the check is in test-fast.
.PHONY: notice-facts-emit check-notice-facts-fresh
notice-facts-emit:
	@LC_ALL=C.UTF-8 guile --no-auto-compile -L module tools/emit/emit-notice-facts.scm write
check-notice-facts-fresh:
	@LC_ALL=C.UTF-8 guile --no-auto-compile -L module tools/emit/emit-notice-facts.scm check

# Where each file of module/playnet/ is, what reaches it, and which imports point
# up the layers (docs/planning/codebase-layout.md). tools/lint/module-layout.scm is
# the layout as data, naming the tree to come; tools/lint/module-map.scm reads every
# .scm in the tree as forms and lints each file at the rank it will stand at.
# `module-map` writes module/playnet/README.md; `lint-layers` lists the upward
# imports and any file the layout does not name, and exits 1 for any: the tree
# has no upward import, and `make test` runs the lint. The map carries importer counts,
# so `check-module-map-fresh` is for the reader, not the gate. The tool imports
# no playnet module and reads 1,600 files, so it runs compiled, under its own cache.
.PHONY: module-map check-module-map-fresh lint-layers
module-map:
	@LC_ALL=C.UTF-8 tools/test/own-ccache.sh guile tools/lint/module-map.scm --write module/playnet/README.md
check-module-map-fresh:
	@LC_ALL=C.UTF-8 EMIT_CMD="tools/test/own-ccache.sh guile" tools/lint/check-emit-fresh.sh check-module-map-fresh module/playnet/README.md module-map tools/lint/module-map.scm --write
lint-layers:
	@LC_ALL=C.UTF-8 tools/test/own-ccache.sh guile tools/lint/module-map.scm --lint

# Sites that spell actions by hand instead of reading the action table
# (tools/lint/lint-verbs.scm, beyond-valueflows.md §6.2): the count per file only falls.
.PHONY: lint-verbs
lint-verbs:
	@LC_ALL=C.UTF-8 tools/test/own-ccache.sh guile tools/lint/lint-verbs.scm

# Every live module compiled with the unbound-variable and arity warnings: a call that
# cannot run (a name no import supplies, a wrong argument count) is refused before a test
# has to reach it. tools/lint/compile-warnings.sh explains what it counts and what it sets aside.
# One such call the compiler cannot see: `(spawn …)` in a Goblins module that takes
# `spawn` from no import reaches Guile's process spawn (tools/lint/check-goblins-spawn.scm).
# And one write it accepts that Hoot refuses: a `set!` of a binding the module imported
# (tools/lint/check-imported-set.scm), which a context cell (protocol/context.scm) replaces.
.PHONY: lint-compile
lint-compile:
	@$(TEST_ENV) tools/lint/compile-warnings.sh --check
	@$(TEST_ENV) guile --no-auto-compile tools/lint/check-goblins-spawn.scm
	@$(TEST_ENV) guile --no-auto-compile -L module tools/lint/check-imported-set.scm
	@$(TEST_ENV) guile --no-auto-compile tools/lint/check-record-exports.scm

# playnet's own development, planned by the planner: every open Radicle
# issue is a want, its area a skill, its kind a recipe (module/playnet/
# planner/dev/recipes.scm). Prints the week; writes nothing,
# publishes nothing. DEV_PLAN_ARGS carries flags through, e.g.
# `make dev-plan DEV_PLAN_ARGS="--for box"`. See tools/dev/dev-plan.scm.
.PHONY: dev-plan
dev-plan:
	@$(DEV_ENV) guile -q -L module tools/dev/dev-plan.scm $(DEV_PLAN_ARGS)

# The development scope's world (an issue as a want, an area as a skill)
# and its week's plan, on a fixture scope — no `rad` needed.
test-dev-world:
	$(GUILE_TEST_DEV) -L module -L tests tests/dev/test-dev-world.scm

# The development scope's books: a plan row taken as a commitment, an
# issue solved as the work and the deliverable it fulfils.
test-dev-ledger:
	$(GUILE_TEST_DEV) -L module -L tests tests/dev/test-dev-ledger.scm

test-vf-lint:
	$(GUILE_TEST_DEV) -L module -L tests tests/scope/test-vf-lint.scm

test-lint-records-door:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-lint-records-door.scm

test-issue-revoke-credential:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-issue-revoke-credential.scm

# A federation admits a commune through a governor of its gateway.
test-admit-commune-door:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-admit-commune-door.scm

test-delegation-scope-arg:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-delegation-scope-arg.scm

test-lobby-arg-split:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-lobby-arg-split.scm

# A fragmented WebSocket message arrives whole (UPSTREAM-ISSUES #14): the
# patched (web socket frame) in module/web/socket/frame.scm, over a socket pair.
test-websocket-fragments:
	$(GUILE_TEST_DEV) -L module -L tests tests/gateway/test-websocket-fragments.scm

# A server never masks the frames it sends (RFC 6455 §5.1): the patched (web socket)
# in module/web/socket.scm, which (hoot web-server) wraps its REPL relay with.
test-websocket-masking:
	$(GUILE_TEST_DEV) -L module -L tests tests/gateway/test-websocket-masking.scm

test-declare-arg-split:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-declare-arg-split.scm

test-offer-work-drift-door:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-offer-work-drift-door.scm

test-plan-materialize-opts-door:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-plan-materialize-opts-door.scm

# A count of a stock: the difference lands on the stock, with its technique,
# place, instant and evidence; a planned count's record fulfils its commitment
# (docs/observation/capture.md §3).
test-count-stock:
	$(GUILE_TEST_DEV) -L module tests/doors/test-count-stock.scm

test-wire-snapshot:
	$(GUILE_TEST_DEV) -L module tests/doors/test-wire-snapshot.scm

# The calendar email round-trip: an iCal invitation sent by real email
# (a file-drop transport here), its METHOD:REPLY read back, the bookkeeping
# row updated, and the real accept-invite door fired — no network needed.
test-calendar-mail:
	$(GUILE_TEST_DEV) -L module tests/calendar/test-calendar-mail.scm

test-demo-neighbourhood:
	$(GUILE_TEST_DEV) -L module tests/doors/test-demo-neighbourhood.scm

test-count-anchor:
	$(GUILE_TEST_DEV) -L module tests/doors/test-count-anchor.scm

test-count-anchor-2:
	$(GUILE_TEST_DEV) -L module tests/doors/test-count-anchor-2.scm

test-count-expected:
	$(GUILE_TEST_DEV) -L module tests/doors/test-count-expected.scm

# The picture a photo read was made from rides the observation credential as a
# claim of its own: the golden SAIDs of a record with none, the tag grammar, and
# the bridge's issue (governance/credentials.scm, observation/evidence.scm).
test-observation-evidence:
	$(GUILE_TEST_DEV) -L module tests/scope/test-observation-evidence.scm

# The one constructor of a count's difference: the tolerance under which a
# count agrees, and the raise or lower that lands otherwise
# (planner/observation/adjustment.scm).
test-adjustment:
	$(GUILE_TEST_DEV) -L module tests/observation/test-adjustment.scm

test-counts:
	$(GUILE_TEST_DEV) -L module tests/doors/test-counts.scm

# Places inside places, the code a thing is known by, a container that moves
# with what is in it, and the lot's date (docs/observation/capture.md §6).
test-labels-containers:
	$(GUILE_TEST_DEV) -L module tests/doors/test-labels-containers.scm

# The planned count's cadence, regime and process grammar (planner/formulas/counting.scm),
# and the schedule, the offers, the accept and the count over the real service
# (docs/observation/capture.md §4).
test-counting:
	$(GUILE_TEST_DEV) -L module tests/vf/test-counting.scm

test-planned-counts:
	$(GUILE_TEST_DEV) -L module tests/doors/test-planned-counts.scm

# The week's unplanned photo reads, and a picture read at the seat: parts,
# bounds, the allotment spent and given back, a planned count drawing on the
# plan (docs/observation/capture.md §5, §9).
test-allotment:
	$(GUILE_TEST_DEV) -L module tests/gateway/test-allotment.scm

test-see-door:
	$(GUILE_TEST_DEV) -L module tests/doors/test-see-door.scm

# A count is contested the way work is, through the one door, and the whole
# family of the count goes with a void: adjustment, record, hours and cascade
# (doors/governance.scm contest-work, planner/formulas/counting.scm).
test-contest-count:
	$(GUILE_TEST_DEV) -L module tests/scope/test-contest-count.scm

# A counter's picture, attached to the contest of their count in parts, checked
# against its hash, held for the ballot's life and let go (gateway/evidence.scm).
test-evidence-door:
	$(GUILE_TEST_DEV) -L module tests/doors/test-evidence-door.scm

# Guard against the real rot: a test nobody runs. Asserts every
# tests/ux/*-ux.mjs has a reachable `make` target. Cheap (make -n), no browser,
# so it stays in the fast path that CI already invokes (`make test`, via
# PATCH_CI_CMD in deploy/scripts/radicle-ci-hook.sh).
.PHONY: check-test-wiring
check-test-wiring:
	@bash tools/lint/check-test-wiring.sh

# The sibling rot: a prerequisite nobody listed. Asserts each wasm entry's
# import closure is covered by its *_WASM_DEPS list, so make cannot report a
# stale bundle as up to date. Same cost profile as check-test-wiring — no
# compile, no browser — so it rides in the same fast path.
.PHONY: check-wasm-deps
check-wasm-deps:
	@bash tools/lint/check-wasm-deps.sh hoot/repl.scm     "$(REPL_WASM_DEPS)"
	@bash tools/lint/check-wasm-deps.sh hoot/day-boot.scm "$(DAY_BOOT_WASM_DEPS)"
	@bash tools/lint/check-wasm-deps.sh hoot/family-worker.scm "$(FAMILY_WASM_DEPS)"
	@bash tools/lint/check-wasm-deps.sh hoot/scope-worker.scm "$(SCOPE_WASM_DEPS)"

# ── TypeScript: ui/ → browser/ ──────────────────────────────────────────────
# Sources live OUTSIDE the document root (like hoot/ and rns-wasm/) and emit
# JavaScript INTO it. The emitted .js is COMMITTED, as reflect.js is (the
# wasm bundles are the gitignored exception — a multi-MB binary per rebuild
# is history the Tor-seeded clone can't afford; the box builds its own),
# so every consumer of browser/ — fresh clone, `make serve`, the CI
# rsync, the prod static service reading the checkout, `npm run stage` for the
# APK — sees a complete tree without a build having run. Nothing in the serve
# path learns a new step; check-ui-fresh is what keeps that honest.
#
#   make ui            emit (run after editing a .ts, then commit the .js)
#   make ui-check      types only, no emit — the fast inner check
#   make ui-watch      re-emit on save; livereload-watch.py sees the .js land
#                      and the phone reloads, so the onion loop is unchanged
#   make check-ui-fresh  the committed .js matches a fresh compile
#   make check-ui-staged the same question asked of the COMMIT (pre-commit)
UI_ENV = guix shell --pure -m deploy/manifests/ui-manifest.scm --

.PHONY: ui ui-check ui-watch check-ui-fresh check-ui-staged
ui:
	$(UI_ENV) tsc -p tsconfig.json

ui-check:
	$(UI_ENV) tsc -p tsconfig.json --noEmit

ui-watch:
	$(UI_ENV) tsc -p tsconfig.json --watch --preserveWatchOutput

# The drift a committed build product invites: edit the .ts, forget `make ui`,
# and the tree keeps serving the old code with nothing to say so. Recompiles to
# a scratch dir and diffs, rather than trusting mtimes.
check-ui-fresh:
	@$(UI_ENV) bash tools/lint/check-ui-fresh.sh

# The same check asked of the COMMIT rather than the working tree — what the
# pre-commit hook runs. Concurrent sessions share this checkout, so commits are
# path-limited; a regenerated .js can sit correct on disk and never be staged.
check-ui-staged:
	@$(UI_ENV) bash tools/lint/check-ui-fresh.sh --staged

# ── Browser test aggregates ─────────────────────────────────────────────────
# test-browser: self-contained dial suites — chromium, no gateway (~2 min).
# test-e2e:     full-stack suites — each starts a real gateway (slow).
# Kept out of `make test` so CI stays fast; run them before a release or when
# touching browser/, and see check-test-wiring above for why they must at
# least remain reachable.
.PHONY: test-browser test-e2e
test-browser: test-app-ux
test-e2e: test-keri-signup-ux test-credential-sync-ux test-recovery-ux \
          test-signup-live-ux test-room-join-live-ux test-enroll-live-ux test-cast-ux \
          test-device-live-ux test-identity-portability-live-ux test-passcode-change-live-ux \
          test-calendar-ux test-browser-ux

# The repl's general UX pass (drives index.html against a live gateway).
.PHONY: test-browser-ux
test-browser-ux: browser/repl.wasm
	bash tests/ux/ux-full.sh tests/ux/browser-ux.mjs

# The calendar tab driven as a user would: pick a scope, share location,
# mark willingness on a need. Its own header documents this runner.
.PHONY: test-calendar-ux
test-calendar-ux: browser/repl.wasm
	bash tests/ux/ux-full.sh tests/ux/calendar-ux.mjs

# The at-rest blob cipher (browser/lib/vault.js). Plain WebCrypto, no DOM, so
# node exercises the real code rather than a reimplementation.
test-vault:
	node tests/browser/vault-test.mjs

# The IndexedDB keystore + legacy migration (browser/lib/keystore.js). Real
# WebCrypto Ed25519 with in-memory localStorage/IndexedDB mocks. Pins that a
# failed migration never destroys the only copy of a signing key.
test-keystore:
	node tests/browser/keystore-test.mjs

# The spine-handler ⇄ page-bridge seam as a checked claim: every handler the
# wasm registers (hoot/day-boot.scm) must have its wrapper on seam.handlers
# (browser/day-boot.js). The faces treat a missing wrapper as "offline", so an
# unbridged handler is a silent no-op live — this pins the parity.
test-handler-bridge:
	node tests/browser/handler-bridge-test.mjs

# The map's containment forest + its fold (browser/app/tabs/containers.js).
# Pure functions, so node runs the real code. Pins the line that keeps a place
# holding a box from reading as a place with nothing wrong with it, the AM–GM
# claim the geometric mean is chosen for, and point-in-polygon — which decides
# which published ecoregion boundary a leaf's contained-in is DERIVED from.
.PHONY: test-containment-fold
test-containment-fold:
	node tests/browser/containment-fold-test.mjs

# The reactive core (browser/app/reactive.js). Twenty-one modules import it and
# none could see it fail: batching, dependency RE-tracking and identity dedup are
# invisible when they hold and near-impossible to debug when they do not.
.PHONY: test-reactive
test-reactive:
	node tests/browser/reactive-test.mjs

# The room model (app/voice/room-model.ts): the live state as one union and one
# reducer, and the topic codec. Properties over every path — talk, camera and
# screen only while live, live always names its room — plus the room hop, where
# the spine's `left` for the old room lands between the ask and the answer.
.PHONY: test-room-model
test-room-model:
	node tests/browser/room-model-test.mjs

# The mesh's video budget (app/voice/mesh-plan.ts): the streams a person sends
# stay within the budget at every room size, and the ceiling is the one the
# budget gives. Plain node over the emitted module.
.PHONY: test-mesh-plan
test-mesh-plan:
	node tests/browser/mesh-plan-test.mjs

# The gateway names the ICE servers a call may use (its `ice-servers` door); the
# browser carries none. The list, its env spelling, and a source scan.
.PHONY: test-ice-servers
test-ice-servers:
	$(GUILE_TEST_DEV) -L module tests/doors/test-ice-servers.scm

# Unit conversion with and without GNU units on PATH (utils/units.scm): the box
# has none, so the program is looked for once instead of a failed fork per call.
.PHONY: test-units-fallback
test-units-fallback:
	$(GUILE_TEST_DEV) -L module tests/utils/test-units-fallback.scm

# The utterance parser (app/utter.ts): one sentence → [locus-delta] [act],
# ranked. Pure and context-injected, so node reads the same sentences the page
# does — the bangs, the faces, weekdays against a fixed clock, the residual.
.PHONY: test-utter
test-utter:
	node tests/browser/utter-test.mjs

# A count of a stock as the faces speak it (app/count.ts): the figure read out
# of what was typed or said, the gateway's reply, and the verdict's sentence.
test-count:
	node tests/browser/count-test.mjs

# The QR encoder a label is printed with (app/qr.ts), read back by a reader
# written apart from it: sizes, format bits, Reed–Solomon, every version and mask.
test-qr:
	node tests/browser/qr-test.mjs

# A label's code and the three prints (app/labels.ts).
test-labels:
	node tests/browser/labels-test.mjs

# A photograph taken on the device: how it is fitted, how it crosses the seam
# and is hashed, and the store that keeps it (app/photo.ts).
test-photo:
	node tests/browser/photo-test.mjs

# A thing on the books, read off the wire once: the row's fields, the places
# table, a lot's date, what is inside a container (app/stock.ts).
test-stock:
	node tests/browser/stock-test.mjs

# A store as it is arranged: a place's path, things inside things (app/store-tree.ts).
test-store-tree:
	node tests/browser/store-tree-test.mjs

# The store as it is arranged for its face: places, containers, stock, the
# filters, the badges, the ledger line and the order counts are worked in
# (app/store-view.ts).
test-store-view:
	node tests/browser/store-view-test.mjs

# Where a good is held, stock by stock: the join the Resources face counts
# through (app/held.ts).
test-held:
	node tests/browser/held-test.mjs

# The demo world holds together: every id its tables name exists, and the store's
# stocks sit at its places and sum to its goods' figures (app/demo/world.ts).
test-demo-world:
	node tests/browser/demo-world-test.mjs

# The offline store keeps its own books: every id it names is a stock it
# holds, every place exists, the dates hang off the day (app/demo/store.ts).
test-demo-store:
	node tests/browser/demo-store-test.mjs

# What a symbol the camera read means: a label, a product, text; and a
# barcode paired with a stock (app/symbols.ts, app/barcodes.ts).
test-symbols:
	node tests/browser/symbols-test.mjs

# A person's ways to be reached, kept on the device, and the card that carries
# some of them: what is refused, what a value opens as, how a card reads (app/reach.ts).
test-reach:
	node tests/browser/reach-test.mjs

# Photographs waiting to be read, and the sheet of several shots
# (app/queue.ts, app/photo.ts).
test-queue:
	node tests/browser/queue-test.mjs

# The week's photo reads, as a face says them (app/allotment.ts).
test-allotment-ui:
	node tests/browser/allotment-test.mjs

# The counts of a stock and the contests of them, as the sheet reads and says
# them (app/contest.ts).
test-contest:
	node tests/browser/contest-test.mjs

# A lend into the commons, as far as it is words and a door: the audience and
# its rule, who it admits, the socialize call, the kept-back, the recall (app/lend-core.ts).
test-lend:
	node tests/browser/lend-test.mjs

# A picture read into rows: what the model is asked, and what is made of its answer (app/look.ts).
test-look:
	node tests/browser/look-test.mjs

# The fuzzy-match primitive (app/fuzzy.ts) utter.ts's floor falls back to for
# a typo'd or truncated place/spec/scope name — Sørensen–Dice over bigrams,
# an overlap coefficient for containment, and tie detection so two equally-
# plausible candidates resolve to nothing rather than an arbitrary winner.
.PHONY: test-fuzzy
test-fuzzy:
	node tests/browser/fuzzy-test.mjs

# The browser's ask-for-a-shape door (app/conform.ts): read → check → re-ask
# with the reason → floor. Twin of (playnet ai conform), whose suite is
# tests/ai/test-conform.scm under `make test`. Pure, no gateway.
test-conform-ui:
	node tests/browser/conform-test.mjs

# The live-caption commit ratchet (app/voice/caption-window.ts): bounds what
# whisper re-reads each ~1.4s tick while the mic is held, so a long hold's
# per-tick cost stays flat instead of growing with how long someone speaks.
.PHONY: test-caption-window
test-caption-window:
	node tests/browser/caption-window-test.mjs

# The local Moonshine worker's first call downloads model weights from a CDN
# with no bound of its own — a stalled fetch (slow network, blocked host)
# left every awaiting call hanging forever. withTimeout (app/voice/audio.ts)
# bounds every such call so a stall surfaces as a real, visible error.
.PHONY: test-audio-timeout test-slots-model test-inline-text
test-audio-timeout:
	node tests/browser/audio-timeout-test.mjs

test-slots-model:
	node tests/browser/slots-model-test.mjs

test-inline-text:
	node tests/browser/inline-text-test.mjs

# The feedback lane lets someone point at an element and speak about it; the
# reference has to survive as text and come back through querySelector. An id
# or class CSS cannot address (a colon, a slash, a leading digit) spliced into
# a selector makes querySelector THROW inside the chip's click handler — so
# refsel drops what it cannot address, and this holds that refusal.
.PHONY: test-refsel
test-refsel:
	node tests/browser/refsel-test.mjs

# The feedback lane can attach what the page said about itself, and the dial
# logs its OCapN sturdyref on every connect — a BEARER capability. The ring
# scrubs at capture so it never holds one; this holds that scrub, and holds
# that it still leaves an ordinary error message readable.
.PHONY: test-diag-redact
test-diag-redact:
	node tests/browser/diag-redact-test.mjs

# Every --t-XXXXXX token app.html's stylesheet var()-references must also be
# declared in a :root block, or theme.js's readTokens() never learns it
# exists and the declaration that references it does nothing. Caught 16 real
# dangling tokens this way (mic-recording tint, log/share-bar chips, a
# calendar out-cell, the AI-reading pill, several borders) — none painted
# the color their own rule named.
.PHONY: test-palette-tokens
test-palette-tokens:
	node tests/browser/palette-tokens-test.mjs

# A real upstream Hoot/CapTP transport bug (deploy/UPSTREAM-ISSUES.md #14):
# a gateway RPC carrying a payload larger than any prior one on the same
# connection never gets a reply — no error, just an unbounded hang.
# transcribePcm() (app/voice/audio.ts) bounds the gateway call so a hang
# falls through to the local worker instead of blocking forever.
.PHONY: test-transcribe-fallback
test-transcribe-fallback:
	node tests/browser/transcribe-fallback-test.mjs

# lib/capabilities.js: the probes read the engine (a real V8 with a feature switched on and
# off), and the words and banner stay generic. The page-level case is tests/ux/capabilities-ux.mjs.
.PHONY: test-capabilities
test-capabilities:
	node tests/browser/capabilities-test.mjs

# app/pwa.ts: which origins are live-editing (the worker torn down, its caches
# cleared) and which caches are the worker's to clear. The Capacitor shell's
# https://localhost is a production origin. The browser-level case is
# tests/ux/sw-offline-ux.mjs.
.PHONY: test-pwa
test-pwa:
	node tests/browser/pwa-test.mjs

# The unit tests' harness is tests/browser/assert.mjs: one counter, one line
# format, one exit. rest-test holds app/rest.ts to the figures the Scheme
# rest catalogue's own test pins.
.PHONY: test-rest
test-rest:
	node tests/browser/rest-test.mjs

# app/bytes.ts: base64, base64url and hex round-trip every byte; hex refuses
# what is not hex.
.PHONY: test-bytes
test-bytes:
	node tests/browser/bytes-test.mjs

# app/keys.ts: the localStorage key table — its migration from former names,
# its naming convention, and the Scheme bundles and pre-paint script spelling
# the names as the table has them.
.PHONY: test-keys
test-keys:
	node tests/browser/keys-test.mjs

# app/attention.ts: the standing list of what is waiting on this device — a
# build to reload onto, a write the storage refused.
.PHONY: test-attention
test-attention:
	node tests/browser/attention-test.mjs

# app/push.ts: enabling asks, subscribes with the commune's key and tells the
# commune under this device's id; the commune is told again at each seating.
.PHONY: test-push
test-push:
	node tests/browser/push-test.mjs

# app/rpc.ts: a question asked of a worker always ends — answered by id, or
# rejected when the worker dies, with a fresh worker on the next ask.
.PHONY: test-rpc
test-rpc:
	node tests/browser/rpc-test.mjs

# app/store.ts: a refused localStorage write answers false and raises a fault
# (full store, blocked store); a refused read is the default.
.PHONY: test-store
test-store:
	node tests/browser/store-test.mjs

# app/idb.ts: an operation resolves on transaction COMPLETE, rejects on abort
# and error, and a schema's upgrade hears the version the device held.
.PHONY: test-idb
test-idb:
	node tests/browser/idb-test.mjs

# app/tabs/social/log-bound.ts: the newest log entries that fit a store's
# budget, measured as the gateway measures its 512 KiB cap.
.PHONY: test-log-bound
test-log-bound:
	node tests/browser/log-bound-test.mjs

# lib/rns-identity.js: the Reticulum mesh key is held sealed under the origin's
# non-extractable seal key; a key stored before sealing is sealed on first read.
.PHONY: test-rns-identity
test-rns-identity:
	node tests/browser/rns-identity-test.mjs

# browser/sw.js against the tree: every PRECACHE path and notification icon is
# a file (install is all-or-nothing over the list), and tools/emit/sw-stamp.sh
# gives one tree one stamp.
.PHONY: lint-sw
lint-sw:
	@node tools/lint/lint-sw.mjs

# The raster icons the manifest, the pages and the worker's notifications
# name, drawn from browser/assets/icons/{icon,icon-maskable}.svg. Committed;
# rerun after editing a source.
.PHONY: icons
icons:
	guix shell --pure librsvg font-dejavu fontconfig bash coreutils -- bash tools/emit/make-icons.sh

# The offer field (browser/app/offers.js). The rim and the map show ONE set,
# and this is why: both ask the same two questions of every offer. Pins the
# at-or-under rule against BOTH spine sources (flat term-ids through the
# descendant index, legacy slash paths through the prefix rule), the
# multi-valued tag that must show under either branch, and the turn window's
# real claim — that a daily routine is in a week-scale turn because it recurs
# on each of its days, not because one instance landed inside.
.PHONY: test-offers
test-offers:
	node tests/browser/offers-test.mjs

# The scope's three declarations as the cards speak them
# (browser/app/slots/declarations.js): the regime's reading, the ceiling's
# parse, the reply's reading, the sentences.
.PHONY: test-declarations
test-declarations:
	node tests/browser/declarations-test.mjs

# The editable rings (browser/app/ring.js) — the hours they are drawn in, and
# the interval algebra NET availability rests on. The end-to-end suite proves
# the wire's shape; this proves the case that produces a shape it never sees:
# a committed event strictly inside a window does not shorten it, it SPLITS it.
# An offer of hours you are not free is a commitment the solver will fill.
.PHONY: test-ring
test-ring:
	node tests/browser/ring-test.mjs

# The sun, from where you stand (browser/app/sky.js). The rim wears the day's
# own light, and the astronomy is exact rather than a plausible gradient — so
# its claims are checkable against the world: the sun rises due east at an
# equinox from EVERY latitude, midsummer in Berlin runs about sixteen and a half
# hours, and above the Arctic circle midwinter has no sunrise to report at all.
# That last one matters: answering nothing is different from answering an hour.
.PHONY: test-sky
test-sky:
	node tests/browser/sky-test.mjs

# The socialized purse over time (browser/app/runway.js). One pool stepped a
# month at a time: a flat outflow runs it dry in exactly capital/outflow
# months, an `until` stops a cost in that month and not the one before, a
# one-off lands in its month alone, and a gift between two members of the
# pool is not a movement of the pool at all. The life integral is end minus
# today; what must be earned is the depth of the lowest point.
.PHONY: test-runway
test-runway:
	node tests/browser/runway-test.mjs

# A household as a set, its members and groups as blocks (browser/app/
# partition.js). `all` is the whole, a name a singleton, "a+b" or a named
# group the block between; the icon is the rounded shape through the block's
# vertices, and the sort orders rank blocks. Pinned: who resolves to whom,
# every order's ranking, and that two vertices are a segment, never a polygon.
.PHONY: test-partition
test-partition:
	node tests/browser/partition-test.mjs

# The containment forest the map draws (browser/app/regions.js). Its claim is
# that the region drawn around a scope is the SAME object, by id, the planner
# reasons about — because containment is DERIVED from a published polygon. Two
# rules carry it and both are invisible when they hold: the DEEPEST region wins
# (a district beats its ecoregion beats its bioregion), and an asserted parent
# wins over geography only when the forest actually has it.
.PHONY: test-regions
test-regions:
	node tests/browser/regions-test.mjs

# The reproduction-of-labour-power fold (browser/app/nutrition.js). Holds the
# numbers the module states in prose — the sweat curve's anchor, the derived
# per-region rates — and the two claims its LAYER ORDER makes: geography may
# raise the species floor but never sink below it, and the historical-moral
# standard may only lift.
.PHONY: test-nutrition nutrition-emit check-nutrition-fresh
test-nutrition:
	node tests/browser/nutrition-test.mjs

# Everything hanging off the bran: determinism, domain separation, and the
# rotation-independence the encrypted backup depends on.
test-bran-derivations:
	$(GUILE_TEST_DEV) -L module -L tests tests/keri/test-bran-derivations.scm

# Contact points on ^lobby-session — the path from an address to the
# notification router, and the erasure path back off it.
test-contact-binding:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-contact-binding.scm

# the body doors: declare, stewards, the k-of-n inception signed from the seat,
# holdings, the read and admission — over a stub body service
test-body-doors:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-body-doors.scm

# Cards on ^lobby-session — how to reach one person, handed to another:
# signed by the giver, sealed to the receiver, one per pair, erased on withdrawal.
test-cards:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-cards.scm

test-planner-facet:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-planner-facet.scm

test-declared-dispatch:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-declared-dispatch.scm

test-http-door:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-http-door.scm

test-mcp-door:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-mcp-door.scm

test-device-doors:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-device-doors.scm

# The protocol declaration (module/playnet/doors/protocol.scm) names the same doors
# the code answers, with the same args; its seam names are real day-boot
# handlers; its anonymous planner doors are the facet. tools/lint/protocol-lint.scm.
check-protocol:
	$(GUILE_TEST_DEV) -L module tools/lint/protocol-lint.scm

# The emits of the declaration. browser/api/openapi.json is committed (the
# box serves it at /api/openapi.json, Swagger UI at /api/docs/); a stale
# copy is a refused push, the same gate the ui/→browser/ emit has.
protocol-emit:
	$(GUILE_TEST_DEV) -L module tools/emit/protocol-emit.scm openapi browser/api/openapi.json
	$(GUILE_TEST_DEV) -L module tools/emit/protocol-emit.scm mcp browser/api/mcp-tools.json
	$(GUILE_TEST_DEV) -L module tools/emit/protocol-emit.scm seam ui/app/seam-wire.ts

# The subsistence catalogue's tables, emitted for the browser. The catalogue
# (module/playnet/knowledge/catalogues/subsistence.scm) states every
# nutrient band once; ui/app/nutrition-catalogue.ts is its generated copy,
# committed like seam-wire.ts, and a stale copy is refused the same way.
nutrition-emit:
	$(GUILE_TEST_DEV) -L module tools/emit/nutrition-emit.scm ui/app/nutrition-catalogue.ts

# The page's row types, generated from the wire tables (module/playnet/wire/
# rows.scm registry): one interface per table, so the page's types are what
# the server states. ui/app/wire-rows.ts is committed like seam-wire.ts and a
# stale copy is refused the same way.
wire-types-emit:
	$(GUILE_TEST_DEV) -L module tools/emit/wire-types-emit.scm ui/app/wire-rows.ts
check-wire-types-fresh:
	@EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-wire-types-fresh ui/app/wire-rows.ts wire-types-emit tools/emit/wire-types-emit.scm

check-nutrition-fresh:
	@EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-nutrition-fresh ui/app/nutrition-catalogue.ts nutrition-emit tools/emit/nutrition-emit.scm

# The product's own law (knowledge/product-law.scm: its crossings, the features
# that trip them, the consent version, licence line and attribution) is the
# source; ui/app/legal-product.ts is the browser's generated copy.
.PHONY: product-law-emit check-product-law-fresh
product-law-emit:
	$(GUILE_TEST_DEV) -L module tools/emit/emit-product-law.scm ui/app/legal-product.ts

check-product-law-fresh:
	@EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-product-law-fresh ui/app/legal-product.ts product-law-emit tools/emit/emit-product-law.scm

# The law face's snapshot the same way: the legal fold (legal-registry.scm over
# the packs in docs/legal/contexts/) is the source, browser/data/snapshots/
# law-snapshot.json its generated copy — the offline fallback of the planner's
# live `legal-snapshot` — and a stale copy is refused.
.PHONY: law-snapshot check-law-fresh de-pack check-de-fresh na-packs check-na-fresh
law-snapshot:
	$(GUILE_TEST_DEV) -L module tools/emit/emit-law-snapshot.scm browser/data/snapshots/law-snapshot.json

# Germany's context pack is generated too (tools/emit/emit-de-context.scm holds its
# places, rules and words for aspects); the snapshot above folds it, so the pack
# is refreshed first when both moved.
de-pack:
	$(GUILE_TEST_DEV) -L module tools/emit/emit-de-context.scm docs/legal/contexts/de.sexp

check-de-fresh:
	@EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-de-fresh docs/legal/contexts/de.sexp de-pack tools/emit/emit-de-context.scm

# The United States, Mexico and Canada the same way: tools/emit/emit-na-context.scm
# holds each nation's places, rules, protections and words for aspects, and
# writes one pack a nation.
NA_PACKS = us mexico canada
na-packs:
	@for n in $(NA_PACKS); do \
	  $(GUILE_TEST_DEV) -L module tools/emit/emit-na-context.scm $$n docs/legal/contexts/$$n.sexp || exit 1; done

check-na-fresh:
	@ok=1; for n in $(NA_PACKS); do \
	  EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-na-fresh docs/legal/contexts/$$n.sexp na-packs tools/emit/emit-na-context.scm $$n || ok=0; \
	done; [ "$$ok" = 1 ]

check-law-fresh:
	@EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-law-fresh browser/data/snapshots/law-snapshot.json law-snapshot tools/emit/emit-law-snapshot.scm

# The physics register the same way: knowledge/substances.scm declares the
# conserved leaves, carriers, molecules and channels once; docs/observation/
# physics-register.md is their generated reading, beside the prose of physics.md.
.PHONY: physics-emit check-physics-fresh
physics-emit:
	$(GUILE_TEST_DEV) -L module tools/emit/physics-emit.scm docs/observation/physics-register.md

check-physics-fresh:
	@EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-physics-fresh docs/observation/physics-register.md physics-emit tools/emit/physics-emit.scm

# The housing standard and closure the same way: knowledge/housing-catalogue.scm
# + catalogues/housing-substance.scm state the rows and the type table once;
# ui/app/housing-catalogue.ts is the generated copy. test-housing-ui pins the
# person layer ui/app/housing.ts ports (the elder's 20 °C, the child's half
# room, the step-free gate) to the catalogue's own figures.
# ── food composition: USDA FoodData Central (SR Legacy), sliced ─────────────
# The composition rows a food spec carries are read off the pinned SR Legacy
# release (knowledge/food-sources.scm binds spec → FDC food; the slice lives in
# knowledge/data/fdc-sr-legacy.scm). `make fdc-snapshot` fetches the archive
# (6 MB, public domain), verifies its sha256 and re-slices; the repo carries the
# slice, never the dump. check-fdc-fresh re-slices from a cached archive when
# one is present and says so when none is.
FDC_RELEASE = FoodData_Central_sr_legacy_food_csv_2018-04
FDC_URL = https://fdc.nal.usda.gov/fdc-datasets/$(FDC_RELEASE).zip
FDC_SHA256 = b80817294b8850530aaedf2e515c02593b1824f763a0ff356e5c2081643e6fd0
FDC_CACHE ?= $(HOME)/.cache/playnet/fdc
FDC_SLICE = module/playnet/knowledge/data/fdc-sr-legacy.scm
.PHONY: fdc-snapshot check-fdc-fresh
$(FDC_CACHE)/$(FDC_RELEASE)/food_nutrient.csv:
	@mkdir -p $(FDC_CACHE); cd $(FDC_CACHE) && \
	  { [ -f $(FDC_RELEASE).zip ] || curl -sSL -o $(FDC_RELEASE).zip $(FDC_URL); } && \
	  echo "$(FDC_SHA256)  $(FDC_RELEASE).zip" | sha256sum -c - && \
	  unzip -o -q $(FDC_RELEASE).zip
fdc-snapshot: $(FDC_CACHE)/$(FDC_RELEASE)/food_nutrient.csv
	$(GUILE_TEST_DEV) -L module tools/emit/fdc-snapshot.scm $(FDC_CACHE)/$(FDC_RELEASE) $(FDC_SLICE)
check-fdc-fresh:
	@if [ -f $(FDC_CACHE)/$(FDC_RELEASE)/food_nutrient.csv ]; then \
	  EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-fdc-fresh $(FDC_SLICE) fdc-snapshot tools/emit/fdc-snapshot.scm $(FDC_CACHE)/$(FDC_RELEASE); \
	else echo "check-fdc-fresh: no cached release at $(FDC_CACHE) — run: make fdc-snapshot (fetches 6 MB)"; fi

.PHONY: test-housing-ui housing-emit check-housing-fresh
test-housing-ui:
	node tests/browser/housing-test.mjs

housing-emit:
	$(GUILE_TEST_DEV) -L module tools/emit/housing-emit.scm ui/app/housing-catalogue.ts

check-housing-fresh:
	@EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-housing-fresh ui/app/housing-catalogue.ts housing-emit tools/emit/housing-emit.scm

# The counting rules the page reads the same way: counting.scm (the process
# grammar, the regimes, the techniques), labels.scm (the code's alphabet) and
# adjustment.scm (the tolerance) state them once; ui/app/count-catalogue.ts is
# the generated copy that count.ts and labels.ts import.
.PHONY: count-emit check-count-fresh
count-emit:
	$(GUILE_TEST_DEV) -L module tools/emit/count-emit.scm ui/app/count-catalogue.ts

check-count-fresh:
	@EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-count-fresh ui/app/count-catalogue.ts count-emit tools/emit/count-emit.scm

# The kinds a relationship is named by — a contact's tag, a vouch's type, a
# lens, a group: social/relationship-kinds.scm states them once;
# ui/app/rel-catalogue.ts is the generated copy the page reads.
.PHONY: rel-emit check-rel-fresh
rel-emit:
	$(GUILE_TEST_DEV) -L module tools/emit/rel-emit.scm ui/app/rel-catalogue.ts

check-rel-fresh:
	@EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-rel-fresh ui/app/rel-catalogue.ts rel-emit tools/emit/rel-emit.scm

.PHONY: limits-emit check-limits-fresh
# The sizes the gateway refuses past (vf/facts/limits.scm): the page sizes what
# it sends against the generated copy, ui/app/limits-catalogue.ts.
limits-emit:
	$(GUILE_TEST_DEV) -L module tools/emit/limits-emit.scm ui/app/limits-catalogue.ts

check-limits-fresh:
	@EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-limits-fresh ui/app/limits-catalogue.ts limits-emit tools/emit/limits-emit.scm

# The kinds of way a person is reached — on their own list, told to a
# commune, put on a card: identity/reach-kinds.scm states them once;
# ui/app/reach-catalogue.ts is the generated copy the page reads.
.PHONY: reach-emit check-reach-fresh
reach-emit:
	$(GUILE_TEST_DEV) -L module tools/emit/reach-emit.scm ui/app/reach-catalogue.ts

check-reach-fresh:
	@EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-reach-fresh ui/app/reach-catalogue.ts reach-emit tools/emit/reach-emit.scm

# The units the planner writes and the questions it asks of one — utils/units.scm
# states them once; ui/app/units-catalogue.ts is the generated copy the page reads.
.PHONY: units-emit check-units-fresh
units-emit:
	$(GUILE_TEST_DEV) -L module tools/emit/units-emit.scm ui/app/units-catalogue.ts

check-units-fresh:
	@EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-units-fresh ui/app/units-catalogue.ts units-emit tools/emit/units-emit.scm

# The demo recipes' standing is read off their runs by the functions a live
# scope's is (planner/solve/recipe-response.scm, doors/record-rows.scm's recipe-response table), so
# the page holds no copy of the reading. ui/app/recipe-demo-standing.ts is
# the generated copy the demo reads.
# The offline demo, as a recording of the demo neighbourhood standing in a real
# scope (tools/emit/demo-emit.scm): what the page plays where no gateway stands.
.PHONY: demo-emit check-demo-fresh
demo-emit:
	$(GUILE_TEST_DEV) -L module tools/emit/demo-emit.scm ui/app/demo/recording.ts
check-demo-fresh:
	@EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-demo-fresh ui/app/demo/recording.ts demo-emit tools/emit/demo-emit.scm

.PHONY: recipe-demo-emit check-recipe-demo-fresh
recipe-demo-emit:
	$(GUILE_TEST_DEV) -L module tools/emit/recipe-demo-emit.scm ui/app/recipe-demo-standing.ts
check-recipe-demo-fresh:
	@EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-recipe-demo-fresh ui/app/recipe-demo-standing.ts recipe-demo-emit tools/emit/recipe-demo-emit.scm

check-protocol-fresh:
	@ok=1; for pair in openapi:browser/api/openapi.json mcp:browser/api/mcp-tools.json seam:ui/app/seam-wire.ts; do \
	  EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-protocol-fresh "$${pair#*:}" protocol-emit tools/emit/protocol-emit.scm "$${pair%%:*}" || ok=0; \
	done; [ "$$ok" = 1 ]

# Individual test conveniences — the full governance suite is run via
# `make test-governance` (defined below, shells into the harness
# script, tools/test/governance-suite.sh, which names each suite by its file;
# including the UC-kind + scope-graph tests added in this iteration).
test-scope-graph:
	$(GUILE_TEST_DEV) -L module -L tests tests/federation/test-scope-graph.scm

# The Guile-native WordPiece tokenizer (docs/planning/faces/corpus-guile-native.md
# phase 1): every case is real ground truth from HF's own tokenizer on the
# same tokenizer.json, not hand-derived.
.PHONY: test-wordpiece
test-wordpiece:
	$(GUILE_TEST_DEV) -L module -L tests tests/ai/test-wordpiece.scm

# Phase 2: guile-sqlite3 against a REAL corpus .db (permaculture, already
# built) — BLOB vector round-trip + FTS5 MATCH, before phase 4 wires a door.
.PHONY: test-corpus-sqlite-spike
test-corpus-sqlite-spike:
	$(GUILE_TEST_DEV) -L module -L tests tests/ai/test-corpus-sqlite-spike.scm

# Phase 3: the ONNX Runtime FFI kernel (module/playnet/ai/onnx-embed.scm) —
# a sentence embedding, in-process, verified against the Node pipeline's own
# output by cosine similarity. onnxruntime is a heavier, spike-specific
# dependency (not in dev-test-manifest — this is the one test that needs it,
# and it self-skips when the library or the cached model isn't present).
.PHONY: test-onnx-embed
test-onnx-embed:
	guix shell --pure -L deploy/guix coreutils guile guile-json onnxruntime -- \
	  env LC_ALL=C.UTF-8 guile --no-auto-compile -L module -L tests tests/ai/test-onnx-embed.scm

# Phase 4: hybrid (BM25 + dense) search, entirely in Guile, over the real
# built permaculture corpus — checked against a real question's real answer,
# not just "returns something".
.PHONY: test-corpus-search
test-corpus-search:
	guix shell --pure -L deploy/guix coreutils guile guile-json guile-sqlite3 onnxruntime -- \
	  env LC_ALL=C.UTF-8 guile --no-auto-compile -L module -L tests tests/ai/test-corpus-search.scm

# ^lobby's corpus-search/corpus-domains doors with NO ^corpus-service
# configured — the soft-degrade path a box with no onnxruntime/
# guile-sqlite3 actually takes. A real reply-shape bug lived here (found
# by testing this exact path, not by review): fixed, and this test is
# what would have caught it. Needs no onnxruntime/guile-sqlite3 itself —
# it never reaches ^corpus-service.
.PHONY: test-corpus-search-degrade
test-corpus-search-degrade:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-corpus-search-degrade.scm

test-universal-commune-kind:
	$(GUILE_TEST_DEV) -L module -L tests tests/federation/test-universal-commune-kind.scm

test-gplay:
	$(GUILE_TEST_DEV) -L module tests/org/test-gplay.scm

test-knowledge:
	$(GUILE_TEST_DEV) -L module tests/lang/test-knowledge.scm

# Provenance bridge: prose⇄computation graph. check-provenance fails on any
# dangling tag (the graph is a proof obligation); test-provenance runs the
# relational + trace queries. extract/render regenerate the facts and the picture.
check-provenance:
	$(GUILE_TEST_DEV) docs/_scripts/check-provenance.scm

test-provenance:
	$(GUILE_TEST_DEV) -L module tests/doors/test-provenance.scm

extract-provenance:
	$(GUILE_TEST_DEV) docs/_scripts/extract-provenance.scm --write

render-provenance:
	$(GUILE_TEST_DEV) docs/_scripts/render-provenance.scm

# docs/playnet.pdf + docs/playnet.epub — the scroll's "the latest spec"
# download links. Both are gitignored build products; CI runs the same
# script via build_docs_epub() in radicle-ci-hook.sh before every sync.
# Content-stamped, so a re-run with an unchanged .typ is a fast no-op.
.PHONY: docs-epub
docs-epub:
	deploy/scripts/build-docs-epub.sh "$(CURDIR)"












# The federated solve across a vat boundary (Rung 3 of FEDERATED-SOLVE.md):
# the boundary oracle + signed ^commune-solver actors, in-process and across
# two processes over a websocket sturdyref.
test-federation-wire: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-federation-wire.scm

test-federation-wire-procs: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-federation-wire-procs.scm

# The same solve with no coordinator and no rounds (federation/async.scm): peers
# that message each other along the links, a simulated network that reorders,
# loses and repeats, and a federation settled when it falls silent; then the
# peers as signed actors in their own vats (federation/peer.scm).
test-federation-async: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-federation-async.scm

test-federation-peer: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-federation-peer.scm

test-federation-peer-procs: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-federation-peer-procs.scm

# The planner service's record door: what a gateway's peer of the federated
# solve is built over (federation/federate.scm).
test-federation-scope-record: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/doors/test-federation-scope-record.scm

# One column for a good that crosses either way (solver.scm `offset-column`,
# `give-bound`, `detach-column`), and the direction a good crosses decided by
# the solve: the stock moved, the twin economy, goods nobody can supply.
test-crossing-column: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/solve/test-crossing-column.scm

test-federation-direction: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-federation-direction.scm

# The communes of one solve partition the economy: a scope beside its own
# member, or a body in two programs, is refused at the entry of federated-plan.
test-one-citizen: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/doors/test-one-citizen.scm

# Every planner door that takes a person is classed: it states their standing
# (routed to the home) or acts at the scope the call names.
test-person-doors: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/doors/test-person-doors.scm

# Who is there to witness work is the scope's community: its agents, the people
# homed there and the people who took part in an event recorded there.
test-witness-roster: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/doors/test-witness-roster.scm

# Credit is earned anywhere and spent anywhere: the claim guard, the claim's reply
# and the shop header read the roster's account stores, one reading.
test-credit-spend: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/doors/test-credit-spend.scm

# The audit of a ratified kind reads what a person took anywhere on the roster.
test-audit-person: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/doors/test-audit-person.scm

# A person's practice is theirs wherever they worked: competence, conformance
# hours and the profile read the join of every scope's work events by event id.
test-practice-join: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/doors/test-practice-join.scm

# Live location is a consented lease: the mode is declared at the home, a fix
# counts while fresh, off ends it and refuses the next.
test-location-lease: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/doors/test-location-lease.scm

# A person's day is offered once in the solve as in the roster: overlapping
# ranges are one stretch.
test-window-union: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/solve/test-window-union.scm

# Which goods cross is read off the records: at least two scopes deal in it.
test-crossing-set: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/doors/test-crossing-set.scm

# A body has one week: the pool counts a person once, deployment spends one budget
# across their skills, and a day offered twice is offered once.
test-labour-budget: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-labour-budget.scm

# The algebra the folds are summed under: join, sum, and which are idempotent.
test-fold-laws: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/pools/test-fold-laws.scm

# A settled crossing leaves a record: two legs per participant through the pool,
# written by the party that receives each.
test-crossing-custody: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-crossing-custody.scm

# A scope's key rotates and the wire follows: its words carry its key log, and a
# verifier reads the key in force off it.
test-federation-rotation: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-federation-rotation.scm

# The federation's spec, off its own store (federation/sturdyref-credential.scm).
test-federation-spec: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-federation-spec.scm

# The federation's desk: what a federation answers for itself, and how far a
# commune takes its word (federation/federate.scm `desk-word->spec`).
test-federation-desk: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-federation-desk.scm

# The same two-process solve with commune B on another machine (FED_REMOTE an
# ssh target holding module/ and tests/federation/ at FED_REMOTE_ROOT, with the
# KERI backend's libraries at FED_REMOTE_LIBS), both ends on the Goblins the
# channel pin ships: here under time-machine, there its own profile.
FED_REMOTE ?= playnet-server
FED_REMOTE_ROOT ?= /tmp/fed
FED_REMOTE_LIBS ?=
test-federation-peer-remote:
	guix time-machine -C $(CHANNELS) -- shell -L deploy/guix -m deploy/manifests/dev-test-manifest.scm -- \
	  bash tools/test/own-ccache.sh env LC_ALL=C.UTF-8 \
	  PLAYNET_FED_REMOTE=$(FED_REMOTE) PLAYNET_FED_REMOTE_ROOT=$(FED_REMOTE_ROOT) PLAYNET_FED_REMOTE_LIBS=$(FED_REMOTE_LIBS) \
	  guile -L module tests/federation/test-federation-peer-procs.scm

# A good several scopes supply and several draw: one pull, settled between its
# participants (crossing-step, ρ per good), held to the monolith's optimum.
test-federation-crossing: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-federation-crossing.scm

test-governed:
	$(GUILE_TEST_DEV) -L module tests/org/test-governed-org.scm

test-signatures:
	$(GUILE_TEST_DEV) -L module tests/org/test-history-signatures.scm

test-wisp:
	$(GUILE_TEST_DEV) -L module tests/lang/test-wisp.scm

test-endorsement:
	$(GUILE_TEST_DEV) -L module tests/org/test-endorsement.scm

test-output-cap:
	$(GUILE_TEST_DEV) -L module tests/org/test-output-cap.scm

test-output-port:
	$(GUILE_TEST_DEV) -L module tests/org/test-output-port.scm

test-notify-registry:
	$(GUILE_TEST_DEV) -L module tests/notify/test-notify-registry.scm

test-notify-adapters:
	$(GUILE_TEST_DEV) -L module tests/notify/test-notify-adapters.scm

# Web Push: the browser's subscription is kept parsed, a delivery addressed to
# a device reaches that device, and an expired subscription is removed by it.
test-push-adapter:
	$(GUILE_TEST_DEV) -L module tests/push/test-push-adapter.scm

test-recipient-registry:
	$(GUILE_TEST_DEV) -L module tests/notify/test-recipient-registry.scm

# Where the email adapter's mail goes: msmtp to the box's relay, run against a
# stand-in that records its arguments and its input.
test-email-transport:
	$(GUILE_TEST_DEV) -L module -L tests tests/interface/test-email-transport.scm

test-notify-router:
	$(GUILE_TEST_DEV) -L module tests/notify/test-notify-router.scm

test-persistence:
	$(GUILE_TEST_DEV) -L module tests/org/test-persistence.scm

test-planner: $(KERNEL_SO)
	$(TEST_ENV) \
	  sh tools/test/planner-suite.sh

# Arc-time table: Valhalla priors ⊕ observed EWMA → the engine's *arc-hours*.
# Pure folds, strict-parity lock, synthetic-table injection, and a guarded
# live matrix check that skips cleanly when no engine answers on :8002.
test-arc-times:
	@for t in ewma-fold arc-time-parity arc-time-injection arc-time-recipe arc-time-matrix valhalla-live; do \
	  echo "=== $$t ==="; \
	  $(TEST_ENV) \
	    guile --no-auto-compile -L module tests/*/test-$$t.scm || exit 1; \
	done

# The federation fold and its dual, the descent: one aggregator up, one router
# down, and the section law that ties them (re-folding a split's parts
# reconstructs the value).
# The voice field: the one selector (parts.scm) and the field on a solve
# (solve/voice-field.scm + the engine hook); docs/planning/voice/.
test-voice-field:
	@for t in parts voice-field-solve; do \
	  echo "=== $$t ==="; \
	  $(TEST_ENV) \
	    guile --no-auto-compile -q -L module tests/*/test-$$t.scm || exit 1; \
	done

test-fold-nodes:
	@for t in fold-node unfold-node; do \
	  echo "=== $$t ==="; \
	  $(TEST_ENV) \
	    guile --no-auto-compile -q -L module tests/*/test-$$t.scm || exit 1; \
	done

# The discrete layer: minimum batches and whole counts on §7's certified tree,
# reached through the records (recipes, plan-from-records, robust, movers), plus
# the engine-level fixtures it rests on.
test-discrete:
	@for t in whole-counts time-verification discrete-records doctor-rider-located; do \
	  echo "=== $$t ==="; \
	  $(TEST_ENV) \
	    env PLANNER_INVARIANTS=1 guile --no-auto-compile -q -L module tests/*/test-$$t.scm || exit 1; \
	done

# Provenance loop: re-run the generator on the vendored raw and confirm the
# checked-in worlds/doon-derived.scm is byte-identical — so the planner's MECHANICAL numbers
# (scenario probabilities, Ky multipliers, yields) cannot drift from their source.
# Host python3, no guix shell needed.
# each bioregion: "LABEL|COUNTRY|CROPS" — re-generate + diff its checked-in derived file.
VERIFY_DERIVED = "doon|India|rice,maize,ragi,pulses" "cascadia|United States|wheat,potato,bean,pea" "berlin|Germany|wheat,barley,potato,maize" "bay-area|United States|tomato,potato,bean,pea"
verify-derived:
	@cd module/playnet/knowledge/data && for spec in $(VERIFY_DERIVED); do \
	  label=$${spec%%|*}; rest=$${spec#*|}; country=$${rest%%|*}; crops=$${rest#*|}; \
	  guile emit-derived.scm "$$label" "$$country" "$$crops" > /tmp/$$label-derived.check && \
	  if diff -q ../worlds/$$label-derived.scm /tmp/$$label-derived.check >/dev/null; then \
	    echo "✓ $$label-derived.scm matches the vendored raw"; \
	  else \
	    echo "✗ $$label-derived.scm DRIFTED from raw — regenerate:"; \
	    echo "    guile emit-derived.scm $$label \"$$country\" $$crops > ../worlds/$$label-derived.scm"; \
	    diff ../worlds/$$label-derived.scm /tmp/$$label-derived.check; exit 1; \
	  fi; \
	done

# Ecological possibility-tensions: the fragility (frag) barrier end-to-end —
# per-good cap, per-spec rate, cumulative budget, Leontief cascade, observed
# prior, container roll-up, far-start recovery, Scheme≡C parity, and the REAL
# planetary-boundary + climate-tipping-point catalogue (eco-catalogue.scm)
# custodied by the tension-registry, driven through a solve. Gated on the
# provenance loop so a raw/derived drift fails before the solves even run.
test-tensions: verify-derived
	@for t in tension-parity \
	          frag-cap frag-spec frag-budget frag-cascade frag-budget-cascade \
	          frag-prior frag-observe frag-container frag-container2 \
	          frag-certificate frag-integration frag-farstart \
	          frag-witness frag-catalogue frag-registry-solve \
	          reproduction-diet reproduction-live subsistence-catalogue \
	          subsistence-consumption substance-expansion \
	          robust-multiscenario robust-records doon-valley-robust navdanya-farm taleb-tail antifragile-reserve endogenous-reserve deep-time-reserve \
	          regenerating-stock soil-recurrence forest-recurrence restoration-recipe limit-roster limit-migration scale-invariance representation-parity conservation store-recipe relaxation element-closure leaf-bounds climb backend-verdict-parity monitoring-cadence scenario-tree period-aware-shocks \
	          bioregion-containment doon-shed scenario-shocks bioregion-boundary-wire cascadia; do \
	  echo "=== $$t ==="; \
	  out=$$(PLANNER_RAW_LINT=1 PLANNER_INVARIANTS=1 $(TEST_ENV) \
	    guile --no-auto-compile -L module tests/*/test-$$t.scm 2>&1) \
	    || { echo "$$out"; exit 1; }; \
	  echo "$$out"; \
	  if echo "$$out" | grep -q 'RAW-LINT.*starved'; then \
	    echo "  *** $$t FAILED (RAW-LINT: a draw with no producer, stock, or barrier) ***"; exit 1; \
	  fi; \
	done

# Communications: the whole comms slice — the deterministic core (Stage 0-2 +
# entailment fence), production recipes, the live AI restyle, the publishing
# adapters (5 platforms on one sealed-bearer substrate), the one-solve derivation
# (fragility/scheduling/duals/mandate), and the platform fragility wiring. One
# load context, -L module: every test states its imports as modules now.
.PHONY: test-comms
test-comms:
	@for t in test-comms test-comms-recipes test-comms-ai test-comms-run test-demand-vf-action; do \
	  echo "=== $$t ==="; \
	  $(TEST_ENV) \
	    guile --no-auto-compile -L module tests/*/$$t.scm || exit 1; \
	done
	@for t in test-bearer-endpoint test-platforms test-instagram test-comms-publish; do \
	  echo "=== $$t ==="; \
	  $(TEST_ENV) \
	    guile --no-auto-compile -L module tests/*/$$t.scm || exit 1; \
	done
	@for t in comms-fragility comms-metabolism comms-mandate; do \
	  echo "=== $$t ==="; \
	  $(TEST_ENV) \
	    guile --no-auto-compile -L module tests/*/test-$$t.scm || exit 1; \
	done

test-governance: lint-discipline
	$(TEST_ENV) \
	  sh tools/test/governance-suite.sh

# Voice/CCF orthogonality + recomputability (Phase 5 of HARDENING.md).
# Catches discipline violations at build time, before they slip past
# review and into the system. Exit 1 on violations.
lint-discipline:
	$(TEST_ENV) \
	  guile --no-auto-compile tools/lint/lint-discipline.scm


test-netlayer:
	$(GUILE_TEST_DEV) -L module tests/gateway/test-netlayer-substitute.scm

# Pure-SXML calendar willingness UI (offer band + the detail panel's
# three-way response: willing / commit / reject). Deterministic, no vat.
.PHONY: test-calendar-willingness
test-calendar-willingness:
	$(GUILE_TEST_DEV) -L module -L tests tests/ui/test-calendar-willingness.scm

test-browser: test-calendar-willingness
	# Uses plain `guix shell -L deploy/guix -m ...` rather than
	# $(TIME_MACHINE), matching deploy/manifests/keri-test-manifest.scm.
	# The playnet channel pin can't authenticate via the Radicle HTTPS
	# gateway: Heartwood only canonicalizes the project's defaultBranch
	# (main), so `refs/heads/keyring` — required by guix's (introduction)
	# verification — isn't exposed at the top level, only as
	# refs/namespaces/<NID>/refs/heads/keyring. The dev test environments
	# accept per-host non-reproducibility in exchange for being able to
	# build at all; the deploy path (guix deploy) keeps the channel pin
	# because that's where reproducibility actually matters.
	guix shell -m deploy/manifests/browser-test-manifest.scm -- \
	  sh tests/ux/ux-test.sh

# Generic browser e2e: start a gateway (no KERIA), load the real WASM in
# headless Chromium, connect over OCapN through a /ws proxy, run a Playwright
# test. Self-contained (starts + stops the gateway). See tests/ux/README-ux-e2e.md.
#   make test-ux TEST=tests/<feature>-ux.mjs
.PHONY: test-ux
test-ux: browser/repl.wasm
	bash tests/ux/ux-full.sh $(or $(TEST),tests/ux/willingness-ux.mjs)

# ── Dial (app.html) browser tests ────────────────────────────────────────────
#
# Every tests/ux/*-ux.mjs below is SELF-CONTAINED: it starts its own static server
# and stubs the capability seam via the harness's window.__seam, so none of them needs a
# gateway. They used to run through tests/ux/ux-run.sh, which REQUIRES a gateway
# sref and aborts without one — so `make test-respond-ux` and
# `test-nav-ux` could not pass on a clean checkout. One pattern rule now
# runs them all the same (correct) way.
#
#   make test-signup-ux        identity chip: popover, one-tap, sign-in
#   make test-nav-ux           navigation home / centre-disc ascent
#   make test-respond-ux       willing / commit / decline on a proposal
#   make test-events-ux        event wedges, resize, overlapping lanes
#   make test-pribar-ux        the priority bar: stack, hold, tap routing
#   make test-hand-ux          the hand, the scrub, the wipe, 0/τ crossing
#   make test-chrome-ux        the rim's marks: hours, τ fractions, bearings
#   make test-earth-ux         the reveal: dilate, fade, fall — and back
#   make test-faces-ux         every route into every face, and the aliases
#   make test-law-ux           the law face: activity × place × way, the program by place
#   make test-deeplink-ux      ?focus=<need> — the boot links that aren't faces
#   make test-sw-offline-ux    the service worker: offline boot, one build per page, update on tap
#   make test-wheel-ux         bands, zoom, the rhythm glyph, spend mode
#   make test-availability-ux  availability windows + persistence
#   make test-recipe-ux        dial⇄recipe process-timeline toggle
#   make test-web-ux           the recipe web: folded sectors, hulls, traces, open ends
#   make test-recipeface-ux    the recipe library: computed standing, suggesting a recipe
#   make test-responsive-ux    the shell fits one screen on every device × face
#
# For the dial against a REAL gateway see test-signup-live-ux.
# NB: the per-test targets must NOT be .PHONY — GNU Make skips implicit-rule
# search for phony targets, so the pattern rule below would never fire.
DIAL_UX = bodies signup nav respond events availability recipe web recipeface walkie room settings share-bar share-sheet share-hear account-sheet face-dock feedback withholding log toast match pribar hand chrome earth faces wheel deeplink forum observe spacetime family corpus shop count labels planned-count law responsive sw-offline
.PHONY: test-app-ux
test-app-ux: $(addprefix test-,$(addsuffix -ux,$(DIAL_UX)))

# the family face solves on the device: its test needs the household's wasm too
test-family-ux: browser/family.wasm
test-device-scope-ux: browser/scope.wasm

test-%-ux: browser/day-boot.wasm
	guix shell -m deploy/manifests/browser-test-manifest.scm -- bash -c '\
	  if [ -d "$$GUIX_ENVIRONMENT/lib/node_modules" ] && [ ! -e node_modules ]; then \
	    ln -s "$$GUIX_ENVIRONMENT/lib/node_modules" node_modules; CLEAN=1; fi; \
	  export CHROMIUM_PATH="$$(command -v chromium || true)"; \
	  node tests/ux/$*-ux.mjs; rc=$$?; \
	  [ -n "$$CLEAN" ] && rm -f node_modules; exit $$rc'

# The responsive matrix under every engine guix carries — chromium (Playwright
# over CDP), icecat (WebDriver BiDi) and webkitgtk (WebDriver, MiniBrowser under
# xvfb) — all substitutes, nothing vendored, so this runs on the box exactly
# as it runs here. WebKit is what every iPhone renders with: a layout green
# only on chromium has not been shown to fit a phone.
.PHONY: test-responsive-engines-ux
test-responsive-engines-ux: browser/day-boot.wasm
	guix shell -m deploy/manifests/browser-engines-manifest.scm -- bash -c '\
	  if [ -d "$$GUIX_ENVIRONMENT/lib/node_modules" ] && [ ! -e node_modules ]; then \
	    ln -s "$$GUIX_ENVIRONMENT/lib/node_modules" node_modules; CLEAN=1; fi; \
	  export CHROMIUM_PATH="$$(command -v chromium || true)"; rc=0; \
	  for b in chromium firefox webkit; do echo "== BROWSER=$$b"; \
	    BROWSER=$$b node tests/ux/responsive-ux.mjs || rc=1; done; \
	  [ -n "$$CLEAN" ] && rm -f node_modules; exit $$rc'

# The willingness loop e2e (the worked example). Gates on WASM-load + connect.
.PHONY: test-willingness-ux
test-willingness-ux: browser/repl.wasm
	bash tests/ux/ux-full.sh tests/ux/willingness-ux.mjs

# KERI signup e2e: real repl.wasm creates an identity in Chromium, ships
# icp + OKEA endpoint replies to a live gateway, and the REAL /oobi route
# (serve-static against the gateway's oobi-host dir) must serve
# KEL + /end/role/add + /loc/scheme — what a KERIA resolver fetches.
.PHONY: test-keri-signup-ux
test-keri-signup-ux: browser/repl.wasm
	bash tests/ux/ux-full.sh tests/ux/keri-signup-ux.mjs

# The encrypted credential backup, end to end: the browser seals it, the
# gateway stores ciphertext, and the test decrypts it from the passcode
# alone. Covers the Scheme<->JS seam the unit tests cannot reach.
test-credential-sync-ux: browser/repl.wasm
	bash tests/ux/ux-full.sh tests/ux/credential-sync-ux.mjs

# New device, nothing but the passcode: wipe localStorage + IndexedDB, then
# recover the identity from bran + AID and open the gateway's encrypted
# backup. The property the whole recovery design rests on.
.PHONY: test-recovery-ux
test-recovery-ux: browser/repl.wasm
	bash tests/ux/ux-full.sh tests/ux/recovery-ux.mjs

# The DIAL's SIGNED governance cast, end-to-end (app.html → gateway). Opening a
# ballot needs a governor, and the browser's AID (SAID of an ICP that anchors a
# browser-side reticulum key) can't be cheaply pre-known — so the gateway runs
# with PLAYNET_TEST_OPEN_GOVERNANCE=1, a documented test-only flag that gates
# ONLY ballot open/close, never the cast signature check. The cast the test
# actually asserts still goes through the real cast-signed + verify path.
.PHONY: test-cast-ux
test-cast-ux: browser/day-boot.wasm browser/repl.wasm
	PLAYNET_TEST_OPEN_GOVERNANCE=1 bash tests/ux/ux-full.sh tests/ux/cast-ux.mjs

# The DIAL's signup against a real gateway (signup-ux covers the same chip
# with the seam stubbed; this proves the arguments actually reach a gateway and
# mint an identity whose KEL the /oobi route then serves).
.PHONY: test-signup-live-ux
test-signup-live-ux: browser/day-boot.wasm browser/repl.wasm
	bash tests/ux/ux-full.sh tests/ux/signup-live-ux.mjs

# A room joined through a real gateway: the spine boots with every import its wasm
# declares, the ice-servers door answers at the join, the list reaches the page
# before any peer connection, and the join runs without a Goblins exception.
.PHONY: test-room-join-live-ux
test-room-join-live-ux: browser/day-boot.wasm browser/repl.wasm
	bash tests/ux/ux-full.sh tests/ux/room-join-live-ux.mjs

# a refresh keeps you signed in under a root-authorized device key; the
# passcode stays cold (docs/planning/identity/device-keys.md)
# a severed gateway connection: on-sever drops the dead refs, the page
# reconnects with backoff, the enliven re-seats (docs/planning/faces/spine-worker.md)
.PHONY: test-reconnect-live-ux
test-reconnect-live-ux: browser/day-boot.wasm browser/repl.wasm
	bash tests/ux/ux-full.sh tests/ux/reconnect-live-ux.mjs

.PHONY: test-device-live-ux
test-device-live-ux: browser/day-boot.wasm browser/repl.wasm
	bash tests/ux/ux-full.sh tests/ux/device-live-ux.mjs

# One identity across five devices and a gateway restart: AID + passcode on a
# device that holds nothing, a device retired from another, recovery friends,
# half the browser's storage evicted, the gateway killed and started again on
# the same data, sign-out. Every assertion gates.
.PHONY: test-identity-portability-live-ux
test-identity-portability-live-ux: browser/day-boot.wasm browser/repl.wasm
	PLAYNET_SCOPES_DURABLE=1 bash tests/ux/ux-full.sh tests/ux/identity-portability-live-ux.mjs

# The passcode, changed in settings: two rotations as one act, every device
# retired and this one authorized afresh, the old passcode told so on a
# device beside it and on one that holds nothing, and a second change.
.PHONY: test-passcode-change-live-ux
test-passcode-change-live-ux: browser/day-boot.wasm browser/repl.wasm
	bash tests/ux/ux-full.sh tests/ux/passcode-change-live-ux.mjs

# The same account on Gecko (icecat) and WebKit (webkitgtk): created on one,
# signed in on the other, each kept across a reload.
.PHONY: test-identity-engines-live-ux
test-identity-engines-live-ux: browser/day-boot.wasm browser/repl.wasm
	UX_MANIFEST=deploy/manifests/browser-engines-manifest.scm bash tests/ux/ux-full.sh tests/ux/identity-engines-live-ux.mjs

# An identity made at one commune takes a seat at another, carrying its own
# KEL: two real gateways (SECOND_GATEWAY=1), each with its own oobi-host.
# The profile's skills over a real gateway: a degree stated, restated below
# zero, offered to the roster, noted — each read back through my-skill-standing,
# and kept across a reload.
.PHONY: test-skill-standing-live-ux
test-skill-standing-live-ux: browser/day-boot.wasm browser/repl.wasm
	bash tests/ux/ux-full.sh tests/ux/skill-standing-live-ux.mjs

.PHONY: test-join-live-ux
test-join-live-ux: browser/day-boot.wasm browser/repl.wasm
	SECOND_GATEWAY=1 bash tests/ux/ux-full.sh tests/ux/join-live-ux.mjs

# A vouch that travels: two real gateways polling each other's witness rail;
# Alice's signed relationship for Tia counts at commune B, whose store never
# held it, and Tia witnesses an ask at A from B with a key A never saw.
.PHONY: test-vouch-carry-live-ux
test-vouch-carry-live-ux: browser/day-boot.wasm browser/repl.wasm
	SECOND_GATEWAY=1 PLAYNET_SCOPES_DURABLE=1 PLAYNET_TEST_OPEN_GOVERNANCE=1 bash tests/ux/ux-full.sh tests/ux/vouch-carry-live-ux.mjs

# The contact row, live: two people at one gateway connect by link, witness an
# ask from its row, and walk a row through tag, vouch, mutual, withdraw, forget;
# one tells the commune an address (the code read from the mail directory) and
# gives the other a card the commune keeps as ciphertext.
.PHONY: test-contacts-live-ux
test-contacts-live-ux: browser/day-boot.wasm browser/repl.wasm
	PLAYNET_TEST_OPEN_GOVERNANCE=1 PLAYNET_MAIL_DIR=$(CURDIR)/.ux-e2e-data/mail bash tests/ux/ux-full.sh tests/ux/contacts-live-ux.mjs

# The witnessed enrollment mile against a real gateway: two browser contexts
# as two citizens — signup, recognition queue, k-of-n ceremony open, the
# witness inbox, the in-browser vouch signature, and the candidate's PHC.
.PHONY: test-enroll-live-ux
test-enroll-live-ux: browser/day-boot.wasm browser/repl.wasm
	PLAYNET_TEST_OPEN_GOVERNANCE=1 bash tests/ux/ux-full.sh tests/ux/enroll-live-ux.mjs

# ── KERI mock-based unit tests ───────────────────────────────────────────────
# Fast unit tests against an in-process mock KERIA HTTP server. Cover the
# Scheme-side wire format, dispatch, and verification logic. Do NOT exercise
# real Signify auth, KEL receipts, or witness pools — that's test-keri-
# integration's job.
test-keri-blake3:
	$(GUILE_TEST_DEV) -L module tests/keri/test-blake3.scm

test-keri-signify:
	$(GUILE_TEST_DEV) -L module tests/keri/test-signify.scm

test-keri-signify-portable:
	$(GUILE_TEST_DEV) -L module tests/keri/test-signify-portable.scm

test-keri-signup-with-icp:
	$(GUILE_TEST_DEV) -L module tests/identity/test-signup-with-icp.scm

# an identity brings its own KEL to a commune that never saw it
test-keri-signup-with-kel:
	$(GUILE_TEST_DEV) -L module tests/identity/test-signup-with-kel.scm

# a key proven is not a seat held: witnessed-only AIDs are refused a session
test-keri-lobby-seat-gate:
	$(GUILE_TEST_DEV) -L module tests/doors/test-lobby-seat-gate.scm

# PLAYNET_DISABLE_REAL_SIGNUP refuses signup/signup-with-icp/signup-with-kel/
# join, leaves witness-kel/has-seat alone — see docs/legal/gdpr-analysis.md
test-keri-signup-disabled-gate:
	$(GUILE_TEST_DEV) -L module tests/knowledge/test-signup-disabled-gate.scm

# forget-me erases every store of the gateway's own keyed by an AID, the
# AID→person link last, and leaves the key log — identity/forget.scm; a
# rotation naming no next key retires the identity for good
test-keri-forget:
	$(GUILE_TEST_DEV) -L module tests/gateway/test-forget.scm

# the key log in hand, as the browser keeps it — pure, so Guile pins it
test-identity-kel:
	$(GUILE_TEST_DEV) -L module tests/identity/test-kel-in-hand.scm

# a body's AID is the k-of-n group of its stewards' dial AIDs: the ceremony,
# the threshold reader, the rotation under the pre-rotation constraint
test-identity-body-ceremony:
	$(GUILE_TEST_DEV) -L module tests/personhood/test-body-ceremony.scm

# the body-role credential: a projection the stewards sign k of n
test-governance-body-role-credential:
	$(GUILE_TEST_DEV) -L module tests/keri/test-body-role-credential.scm

# losing your passcode is survivable when you gave pieces of it to people you
# trust — and k-1 of them learn nothing
test-recovery-share:
	$(GUILE_TEST_DEV) -L module tests/keri/test-recovery-share.scm

# AID ↔ mesh binding: advertised reticulum destination must derive from
# the icp-anchored pubkey. Authoritative ring loads the rns-wasm pkg
# under node when available.
test-keri-reticulum-binding:
	$(GUILE_TEST_DEV) -L module tests/keri/test-reticulum-binding.scm

# Mesh mailbox: ciphertext custody for offline-persona deliveries.
test-mesh-mailbox:
	$(GUILE_TEST_DEV) -L module -L tests tests/gateway/test-mesh-mailbox.scm

# LIVE mesh smoke: two rns-bridges over a local TCP hop — announce
# propagation, routed mail packet, DELIVERY on the SUBSCRIBE stream.
# Needs the cargo debug binary + node + rns-wasm pkg; skips otherwise.
test-mesh-smoke:
	timeout 120 $(GUILE_TEST_DEV) -L module -L tests tests/keri/integration/test-mesh-smoke.scm

# Browser e2e WITH a real mesh hop: persona announces through a live
# bridge pair, LXMF mail injected at the far bridge routes back and is
# decrypted in the browser. The full no-mocks round trip.
test-keri-mesh-ux: browser/repl.wasm
	bash tests/ux/ux-mesh.sh

# OKEA endpoint replies in OOBI bodies. Needs the KERI manifest (not the
# dev one): the authoritative third ring parses our served body with
# keripy itself and asserts the endpoint registers in db.locs.
test-keri-oobi-replies:
	guix shell -L deploy/guix -m deploy/manifests/keri-test-manifest.scm -- \
	  $(OWN_CCACHE) guile --no-auto-compile -L module -L . -L tests \
	  tests/identity/test-oobi-endpoint-replies.scm

test-did-keri:
	$(GUILE_TEST_DEV) -L module tests/keri/test-did-keri.scm

test-keri-signify-integration:
	$(GUILE_TEST_DEV) -L module tests/keri/test-keri-signify-integration.scm

test-keri-bridge:
	$(GUILE_TEST_DEV) -L module tests/keri/test-keri-bridge.scm

test-keri-bridge-extra:
	$(GUILE_TEST_DEV) -L module tests/keri/test-keri-bridge-extra.scm

test-keri-credentials:
	$(GUILE_TEST_DEV) -L module tests/keri/test-keri-credentials.scm

test-keri-credentials-ipex:
	$(GUILE_TEST_DEV) -L module tests/keri/test-keri-credentials-ipex.scm

test-keri-witnesses:
	$(GUILE_TEST_DEV) -L module tests/keri/test-keri-witnesses.scm

test-keri-notifications:
	$(GUILE_TEST_DEV) -L module tests/keys/test-keri-notifications.scm

test-ipex-policy:
	$(GUILE_TEST_DEV) -L module -L tests tests/keys/test-ipex-policy.scm

test-ipex-grant-handler:
	$(GUILE_TEST_DEV) -L module -L tests tests/keys/test-ipex-grant-handler.scm

test-ipex-pull-flow:
	$(GUILE_TEST_DEV) -L module -L tests tests/keys/test-ipex-pull-flow.scm

test-scope-portability:
	$(GUILE_TEST_DEV) -L module -L tests tests/utils/test-scope-portability.scm

test-scope-exchange:
	$(GUILE_TEST_DEV) -L module -L tests tests/keys/test-scope-exchange.scm

test-keria-store-pending:
	$(GUILE_TEST_DEV) -L module -L tests tests/keys/test-keria-store-pending.scm

test-pending-grants:
	$(GUILE_TEST_DEV) -L module -L tests tests/keys/test-pending-grants.scm

test-pending-grants-fiber-inheritance:
	$(GUILE_TEST_DEV) -L module -L tests tests/keys/test-pending-grants-fiber-inheritance.scm

test-observability-endpoints:
	$(GUILE_TEST_DEV) -L module -L tests -L . tests/server/test-observability-endpoints.scm

# The basemap's tile source: the PMTiles reader and the /tiles/osm routes,
# against the committed fixture (tools/emit/pmtiles-tiny.scm writes it).
test-pmtiles:
	$(GUILE_TEST_DEV) -L module -L tests -L . tests/server/test-pmtiles.scm

# The device-side reader (browser/app/pmtiles.js) against the same fixture, so
# a region kept on a phone reads exactly as the gateway reads it.
.PHONY: test-pmtiles-browser
test-pmtiles-browser:
	node tests/browser/pmtiles-test.mjs

# A region kept on the device, end to end, in a real browser: the dev server is
# started over the fixture map directory, the page downloads the fixture region
# in Range slices into IndexedDB, and the osm:// protocol answers a tile off
# the device with the gateway's tiles cut. Needs the browser-test shell
# (chromium + playwright); the server is `serve` on its own port and map dir,
# spelled out rather than recursed into ($(MAKE) in a recipe runs even under -n).
.PHONY: test-map-packs-ux
test-map-packs-ux:
	@log=$$(mktemp); \
	setsid env PLAYNET_DEV=1 PLAYNET_FIBERS=1 PLAYNET_MAP_DIR=tests/fixtures/map $(HOOT_RUN_DEV) -L . -L module \
	  -c '((@ (server serve-static) run-static-server) #:work-dir "browser" #:oobi-dir "data/oobi-host" #:port 8092)' >$$log 2>&1 & pid=$$!; \
	for i in $$(seq 1 120); do curl -sf http://127.0.0.1:8092/tiles/osm/regions.json >/dev/null && break; sleep 1; done; \
	curl -sf http://127.0.0.1:8092/tiles/osm/regions.json >/dev/null || { echo "test-map-packs-ux: the server did not come up"; cat $$log; kill -- -$$pid 2>/dev/null; exit 1; }; \
	UX_BASE=http://127.0.0.1:8092 guix shell -L deploy/guix -m deploy/manifests/browser-test-manifest.scm -- \
	  sh -c '[ -e node_modules ] || ln -s "$$GUIX_ENVIRONMENT/lib/node_modules" node_modules; export CHROMIUM_PATH=$$(command -v chromium); node tests/ux/map-packs-ux.mjs'; rc=$$?; \
	kill -- -$$pid 2>/dev/null; rm -f $$log; exit $$rc

test-playnet-scope:
	$(GUILE_TEST_DEV) -L module -L tests tests/tools/test-playnet-scope.scm

test-dev-priorities:
	$(GUILE_TEST_DEV) -L module -L tests tests/tools/test-dev-priorities.scm

test-ratification-delivery:
	$(GUILE_TEST_DEV) -L module -L tests tests/federation/test-ratification-delivery.scm

test-util-common:
	$(GUILE_TEST_DEV) -L module -L tests tests/keys/test-common.scm

test-util-keyed-id:
	$(GUILE_TEST_DEV) -L module -L tests tests/utils/test-keyed-id.scm

test-custodian-heartbeat:
	$(GUILE_TEST_DEV) -L module -L tests tests/keys/test-custodian-heartbeat.scm

test-pending-recompositions:
	$(GUILE_TEST_DEV) -L module -L tests tests/federation/test-pending-recompositions.scm

test-kel-anchoring:
	$(GUILE_TEST_DEV) -L module -L tests tests/scope/test-kel-anchoring.scm

# Deploy-time interop smoke test (curl-driven, no Node deps).
# Usage: make smoke-test GATEWAY=http://localhost:8080
smoke-test:
	@./tests/interop/smoke-test.sh $(GATEWAY)

test-keri-recovery:
	$(GUILE_TEST_DEV) -L module tests/keri/test-keri-recovery.scm

test-keri-lobby-auth:
	$(GUILE_TEST_DEV) -L module tests/doors/test-keri-lobby-auth.scm

# ── ACDC role schemas ───────────────────────────────────────────────────────
# The four playnet role-credential schemas live self-saidified in
# module/playnet/keri/schemas/. Each file's `$id` holds its own blake3-256
# SAID. `make schemas` recomputes + writes; `make test-schemas` asserts
# idempotency (CI guard against accidental edits without re-saidification).

schemas:
	$(GUILE_TEST_DEV) -L module tools/emit/saidify-schemas.scm

test-schemas:
	$(GUILE_TEST_DEV) -L module tools/emit/saidify-schemas.scm --check
	$(GUILE_TEST_DEV) -L module tests/keri/test-schemas.scm

test-keri: test-keri-blake3 test-keri-signify test-keri-signify-portable test-keri-oobi-replies test-keri-signify-integration test-keri-signup-with-icp test-keri-signup-with-kel test-keri-lobby-seat-gate test-keri-signup-disabled-gate test-keri-forget test-identity-kel test-identity-body-ceremony test-governance-body-role-credential test-recovery-share test-keri-reticulum-binding test-mesh-mailbox test-did-keri test-keri-bridge test-keri-bridge-extra test-keri-credentials test-keri-credentials-ipex test-ipex-policy test-ipex-grant-handler test-keri-witnesses test-keri-notifications test-keri-recovery test-keri-lobby-auth test-schemas

# ── SMS Wall ───────────────────────────────────────────────────────────────────
# Smoke test for the WALLS.RIP API client module
.PHONY: test-sms-wall
test-sms-wall:
	$(GUILE_TEST_DEV) -L module -L tests tests/sms/test-walls-rip.scm

# Pack the SMS wall tool as a portable Docker image
.PHONY: pack-sms-wall
pack-sms-wall:
	guix pack -f docker -C gzip -S /bin=bin -S /share=share \
	  -m deploy/manifests/sms-wall-manifest.scm \
	  --entry-point=bin/sms-verify

test-all: test-gplay test-knowledge test-kanren-goblins test-vat-federation test-federation-a test-federation-b test-plan-actor test-federation-result test-elegance-wins test-resilient-federation test-federation-tree test-federation-tree-async test-federation-ocapn test-governed test-signatures test-wisp test-endorsement test-output-cap test-output-port test-persistence test-planner test-governance test-relational test-netlayer test-browser test-keri test-sms-wall

# ── test-all-pinned ──────────────────────────────────────────────────────────
# Reproducibility canary. Same suite as test-all, but every guile invocation
# goes through `guix time-machine -C deploy/channels.scm` so the toolchain is
# bit-for-bit identical to production. Currently HANGS because of the
# Radicle/libgit2 issue described above the runner block. Keep it named: the
# day Radicle's git HTTP bridge gets along with libgit2, this lights up and
# CI can use it again. Don't delete because "nobody runs it" — that's the
# point, it's the canary, not the daily target.
test-all-pinned:
	$(GUILE_TEST) -L module tests/org/test-gplay.scm
	$(GUILE_TEST) -L module tests/lang/test-knowledge.scm
	$(GUILE_TEST) -L module tests/org/test-governed-org.scm
	$(GUILE_TEST) -L module tests/org/test-history-signatures.scm
	$(GUILE_TEST) -L module tests/lang/test-wisp.scm
	$(GUILE_TEST) -L module tests/org/test-endorsement.scm
	$(GUILE_TEST) -L module tests/org/test-persistence.scm
	$(GUILE_TEST) -L module tests/gateway/test-netlayer-substitute.scm
	$(TIME_MACHINE) shell guile-next guile-goblins -- sh tools/test/planner-suite.sh
	$(GUILE_TEST) -L module tests/keri/test-keri-bridge.scm
	$(GUILE_TEST) -L module tests/keri/test-keri-bridge-extra.scm
	$(GUILE_TEST) -L module tests/keri/test-keri-credentials.scm
	$(GUILE_TEST) -L module tests/keri/test-keri-credentials-ipex.scm
	$(GUILE_TEST) -L module tests/keri/test-keri-witnesses.scm
	$(GUILE_TEST) -L module tests/keys/test-keri-notifications.scm
	$(GUILE_TEST) -L module tests/keri/test-keri-recovery.scm
	$(GUILE_TEST) -L module tests/doors/test-keri-lobby-auth.scm

# ── Real-KERIA integration tests ─────────────────────────────────────────────
# Spins up a real `keria start` + `kli witness demo` (6 witnesses) in $TMPDIR
# and runs tests/keri/integration/test-real-keria.scm against them.
# Each test asserts on real KERI state (KEL receipts, signed OOBIs) — not on
# mock counters. See tests/keri/integration/run-integration.sh for the trap
# EXIT teardown.
#
# Deliberately NOT in test-all: building python-keria pulls ~30 Python deps
# via Guix and startup+teardown takes 15-40s. Keeps `make test-all` fast for
# the inner dev loop. Run this manually when touching the KERI bridge, the
# KERIA service definition, or upgrading python-keri / python-keria.
#
# Uses deploy/manifests/keri-test-manifest.scm (plain guix shell, no
# time-machine) because deploy/channels.scm pins the Radicle seed, which
# is currently unreachable. See the header of that manifest for details.
test-keri-integration:
	guix shell -L deploy/guix -m deploy/manifests/keri-test-manifest.scm -- \
	  sh tests/keri/integration/run-integration.sh

# Two-gateway subprocess smoke test. Spawns two real `guile -s
# server/gateway.scm` processes on disjoint ports + state dirs,
# waits for each to write gateway-sref.txt, then runs an OCapN driver
# in a THIRD process that enlivens both sturdyrefs and asserts they
# behave as remote-refr?. Guards against deploy-shape regressions
# (missing -L paths, env-var assumptions, register-race-conditions)
# that in-vat tests miss. Synthetic backend — no KERIA needed.
test-multi-gateway:
	guix shell -L deploy/guix -m deploy/manifests/keri-test-manifest.scm -- \
	  bash tests/integration/run-multi-gateway-smoke.sh

# Two gateways federated on the wire: each boots as one member of the flour
# federation (PLAYNET_SEED_FED) with a scope key of its own, publishes its
# berth; a third process admits both into a signed federation scope, serves
# the federation's desk and fold, and hands each gateway the federation's AID
# and desk; the gateways boot again on the same state, ask, join and settle;
# one restarts once federated. federation/federate.scm, end to end.
# FED_KEYS=dev: scopes without a key, signing under dev identities.
test-federation-gateways:
	guix shell -L deploy/guix -m deploy/manifests/keri-test-manifest.scm -- \
	  bash tests/integration/run-federation-gateways.sh

# Cross-gateway IPEX: full grant→admit pipeline with two mock-KERIA
# servers, scope-signed credentials, policy dispatch, pending-grants
# drain. Single-process (no subprocesses needed).
test-ipex-cross-gateway:
	guix shell -L deploy/guix -m deploy/manifests/keri-test-manifest.scm -- \
	  guile --no-auto-compile -L module -L . \
	    tests/integration/test-ipex-cross-gateway.scm

# ── Live-hacking dev bundles ─────────────────────────────────────────────────
# Dev bundles embed Hoot's runtime module system and mutable definitions
# (-fruntime-modules -fmutable-defs; -g2 adds names) so UI procedures can be
# redefined at runtime via (hoot web-repl) + Geiser. Hoot 0.9 and Hoot main
# both stop such a bundle at start-up today (UPSTREAM-ISSUES #17, #18); the
# state is in docs/dev/LIVE_HACKING.md.
#
# Dev output lives in browser/.dev/ (gitignored) so the dev bundle NEVER
# overwrites the prod browser/repl.wasm that GitHub Pages serves. The dev
# dir holds symlinks to non-wasm assets (HTML/JS/CSS/etc.) plus the dev
# wasm as a real file. DO NOT DEPLOY dev bundles — they are several times
# larger and dial the page's own origin on startup.

browser/.dev:
	mkdir -p browser/.dev

# Populate browser/.dev with symlinks to every sibling file in browser/
# EXCEPT repl.wasm, which is written directly as the dev bundle and must not
# be a symlink or the build would clobber the prod wasm. (The Hoot sources
# live in hoot/, outside the served tree, so there is nothing else to skip.)
browser/.dev/.stamp-assets: | browser/.dev
	@cd browser && for f in *; do \
	  case "$$f" in \
	    .dev|repl.wasm) ;; \
	    *) ln -sfn "../$$f" ".dev/$$f" ;; \
	  esac; \
	done
	@touch $@

# The dev wrapper file (hoot/repl-dev.scm) is a *tail fragment* — it only
# contains the (run-web-repl) call (and an optional parameterize override of
# current-repl-server). We build the
# actual compilation input by:
#
#   1. Cloning the prod entry point and injecting (hoot web-repl) into its
#      top-level (use-modules ...) form. Hoot's library-group compiler
#      requires use-modules to be the first AND ONLY top-level imports
#      form, so we can't simply prepend a second one.
#   2. Appending the dev tail.
#
# The result starts the prod entry point's full init flow (FFI, refresh!,
# register-callbacks!, OCapN bootstrap), then hands control to
# run-web-repl which dials the dev server's WebSocket relay.
#
# We can't (include …) the prod source from a separate wrapper because
# Hoot's library-group compiler forbids top-level include clauses.

browser/.dev/repl-live.scm: hoot/repl.scm hoot/repl-dev.scm \
                            | browser/.dev
	sed '0,/(use-modules /s//(use-modules (hoot web-repl) /' \
	    hoot/repl.scm > $@
	cat hoot/repl-dev.scm >> $@

browser/.dev/repl.wasm: browser/.dev/repl-live.scm \
                       module/playnet/org/gplay.scm module/playnet/lang/wisp.scm \
                       module/playnet/ui/map.scm \
                       browser/.dev/.stamp-assets $(HOOT_TOOLCHAIN_STAMP)
	$(HOOT_BUILD_DEV) \
	  guild compile-wasm -g2 -fruntime-modules -fmutable-defs -L module -L $(FIBERS_LOAD_PATH) \
	    -L $(GOBLINS_LOAD_PATH) \
	    --bundle -o browser/.dev/repl.wasm browser/.dev/repl-live.scm

# `make serve-dev` — rebuild the REPL UI dev bundle and serve it with
# (hoot web-server), which exposes /repl as the WebSocket proxy for Geiser.
# HTTP on 127.0.0.1:8080 and the editor relay on 127.0.0.1:37146, the same
# 8080 `make dev` and `make serve` use; PORT and REPL_PORT move them
# (`PORT=8090 REPL_PORT=37199 make serve-dev`).
serve-dev: browser/.dev/repl.wasm
	$(HOOT_RUN_DEV) -L module \
	  -c '((@ (hoot web-server) serve) #:work-dir "browser/.dev" #:port $(if $(PORT),$(PORT),8080) #:repl-port $(if $(REPL_PORT),$(REPL_PORT),37146))'

# `make live-watch` — auto-reload on save.
#
# Run alongside `make serve-dev`: edit a Scheme
# file under module/, this watches for the save and pushes the new
# definitions into the running browser tab via the REPL relay on
# 127.0.0.1:37146. No page reload, no rebuild.
#
# Defaults to watching ./module. Pass extra paths after `--`:
#   make live-watch ARGS="server module/playnet"
#
# Pulls inotify-tools, bash AND guile-next through guix so the script
# works from a clean checkout — the bash loop calls tools/dev/live-reload.scm
# which in turn calls /usr/bin/env guile, so guile must be on PATH inside
# the shell. The bootstrap VPS provider VM gets the same packages via the live-watch
# shepherd service.
live-watch:
	$(TIME_MACHINE) shell inotify-tools coreutils bash guile-next -- \
	  ./tools/dev/live-watch.sh $(ARGS)

# ── Wisp editor tooling ─────────────────────────────────────────────────────
# Syntax highlighting / indentation for .w (Wisp) files. Two targets, two
# editor camps — see tooling/README.md.
#
#   make wisp-ext         install the prebuilt VSCode/Antigravity extension
#                         from the committed vsix (offline, no npm needed).
#   make wisp-ext-build   rebuild that vsix from source (needs node + npx).
#   make wisp-ts          (re)generate + test the tree-sitter grammar.
#
# Emacs needs no target: `guile-wisp` is in manifest.scm, so wisp-mode is
# autoloaded inside the dev-shell Emacs. For a permanent setup use the Guix
# home service in tooling/emacs-wisp/wisp-home.scm.
WISP_VSIX = tooling/wisp-vscode/wisp-0.1.0.vsix
WISP_EDITOR ?= $(firstword $(foreach c,antigravity codium code,$(if $(shell command -v $(c) 2>/dev/null),$(c))))

# the public origin the extension's relative links resolve against: the
# upstream's unless you publish your own
PLAYNET_ORIGIN ?= https://playnet.earth
.PHONY: wisp-ext wisp-ext-build wisp-ts
wisp-ext:
	@test -n "$(WISP_EDITOR)" || { echo "No editor CLI (antigravity/codium/code) on PATH; set WISP_EDITOR=<cli>"; exit 1; }
	$(WISP_EDITOR) --install-extension $(WISP_VSIX) --force
	@echo "Installed. Reload the editor window (Developer: Reload Window)."

wisp-ext-build:
	cd tooling/wisp-vscode && npx --yes @vscode/vsce package --no-dependencies \
	  --allow-missing-repository --baseContentUrl $(PLAYNET_ORIGIN) \
	  --baseImagesUrl $(PLAYNET_ORIGIN) -o wisp-0.1.0.vsix

wisp-ts:
	cd tooling/tree-sitter-wisp && ./build.sh test

clean:
	rm -f browser/repl.wasm \
	      browser/.dev/repl.wasm browser/.dev/repl-live.scm \
	      browser/.dev/.stamp-assets

# The two-box witness harness: two processes, two state dirs, two static
# tiers, HTTP-only between them — live cross-gateway witness delivery.
.PHONY: test-witness-two-box
test-witness-two-box:
	bash tests/personhood/two-box/run-two-box.sh

# The live first-citizen journey, against a RUNNING `make dev` gateway:
# browser signup → dial Berlin → offer hours → declare a need → the solve's
# schedule lands in the calendar's wire-only source. A probe, not a suite —
# it writes durable state into .dev-data on every run.
# The truth-telling arc, every suite in one run (docs/planning/identity/truth-telling.md):
# the law (emphasis), the meter (externality), the audit, the family solve,
# the fold, the service doors, a want on the citizen's own good, the fold's
# prices between scopes, and the credit fold's persons. Kernel suites need
# libplanner_kernel (make -C module/playnet/solve/kernel).
.PHONY: test-truth-telling
test-truth-telling: $(KERNEL_SO)
	@for t in emphasis externality audit family-money-harmony federated-repro eisenberg-gale; do \
	  echo "=== $$t ==="; \
	  $(TEST_ENV) \
	    guile --no-auto-compile -L module -L tests tests/*/test-$$t.scm || exit 1; \
	done
	@for t in tests/economy/test-demand-fold.scm tests/doors/test-slots-service.scm \
	          tests/economy/test-owned-delivery.scm tests/doors/test-credit-fold.scm; do \
	  echo "=== $$t ==="; \
	  $(TEST_ENV) \
	    guile --no-auto-compile -L module -L tests $$t || exit 1; \
	done

# The truth-telling loop on the wire (make dev running): a want with a
# voice, the ratification rite, my-slots' voice readback, the burn-meter.
.PHONY: probe-emphasis
probe-emphasis:
	GATEWAY_PORT=9099 GATEWAY_SREF_FILE=.dev-data/gateway-sref.txt \
	UX_TEST_PORT=8091 guix shell -m deploy/manifests/browser-test-manifest.scm -- \
	  sh tests/ux/ux-run.sh tests/ux/emphasis-live-probe.mjs

.PHONY: probe-live-sources
probe-live-sources:
	GATEWAY_PORT=9099 GATEWAY_SREF_FILE=.dev-data/gateway-sref.txt \
	UX_TEST_PORT=8091 guix shell -m deploy/manifests/browser-test-manifest.scm -- \
	  sh tests/ux/ux-run.sh tests/ux/live-sources-probe.mjs

# The witness ceremony to QUORUM as two real browsers (two isolated contexts =
# two identities): A records work + opens, B finds it in the inbox, co-signs
# from its own key, the credential strengthens at the floor. Same live stack.
.PHONY: probe-witness-quorum
probe-witness-quorum:
	GATEWAY_PORT=9099 GATEWAY_SREF_FILE=.dev-data/gateway-sref.txt \
	UX_TEST_PORT=8092 guix shell -m deploy/manifests/browser-test-manifest.scm -- \
	  sh tests/ux/ux-run.sh tests/ux/witness-quorum-probe.mjs
