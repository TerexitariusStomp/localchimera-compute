# MACHINE-MANIFEST — the strip contract

This repo becomes a machine-resources product: a browser tab is an accountable
compute/storage/bandwidth node for its commune. Everything not reachable from
that seed is deleted (git history preserves it; no attic).

Seed: `{machine registry+doors, KERI identity ceremony, lend/node faces,
settlement legs, gateway, OCapN seam}`.

## Keep — whole dirs

`compute/` (→ `machine/`), `keri/`, `keys/`, `crypto/`, `identity/`,
`personhood/`, `credentials/`, `economy/`, `pools/` (credit-fold machinery —
folds are generic), `matching/`, `federation/`, `gateway/`, `protocol/`,
`wire/`, `utils/`, `indexes/`, `tools/`, `test/` (harness; suites pruned),
`monero/` (settlement rail), `bridge/` (ring-3 codec/signal), `fleet/`
(machine provisioning), `delegates.scm` (machine legs only — edit inside).

## Keep — entangled substrate (importer surgery costs more than it saves)

`scope/` (except `live.scm`), `vf/`, `observation/`, `algorithms/`
(credit-fold→elastic), `plan/` (scope/root→horizon-gate), `ddmrp/`
(scope/root), `execution/` (scope/root), `solve/` (observer→formulas chain),
`legal/` (23 importers through credentials), `social/` (relationship-kinds
is in the browser wasm), `org/` (boot factories), `ai/` (llm-service +
binding-verifiers), `execution/`.

`knowledge/` keep-partial (verified: vf/economy/scope import exactly these):
catalogues `{conformance, diets, eco, housing, housing-substance, insurance,
rest, subsistence, substances, thermal}`, dsl `{shorthand, world}`,
`law/context-pack`, recipes `{infrastructure, store, transport}`,
worlds `{bioregions, sheds}` (+ doon-valley if shocks pulls it).
Strip: `data/` (9.2M — agronomy/bioclim…), `worlds/berlin-*`, rest of
`law/`, `recipes/`, `catalogues/`, `skills/`, `dsl/` extras.

Surgical follow-up backlog, not this pass: sever `scope/root` from
ddmrp/plan/execution, `observer` from vf-formulas, `credit-fold` from
algorithms — then the planning tier unsticks and this manifest gets a v2.

## Keep — partial

- `boot/`: gateway (slimmed), ocapn, lobby (slimmed — drop folksonomy/notify
  wires), governance (slimmed — drop contests/voice/domain doors), identity,
  keria, site, restore, communes, federation, uc, personhood, credentials,
  grants, mesh, repl, ai (llm-service), monero, **signup** (the KEL-witness
  agent — identity ceremony needs it), **audits** (federation auditors).
  **strip**: bodies, demo-stage, earth, mailbox (person mail), notify,
  planner, scope, prelude (replace w/ machine seed).
- `doors/`: compute→machine, protocol (slimmed ~206→~45), identity, lobby,
  governance, delegation, personhood, economy, federation, http, mcp (keep —
  the machine surface MCP-exposes).
  **strip**: assignments, bodies, body, contests, count-door, counts, effort,
  family/, inventory, journeys, offers, page-scope, planner/, plan-wire,
  position, record-flow, record-rows, service/, service, skills, slots,
  voice, PARITY leftovers of stripped doors.
- `voice/`: strip whole (dispute sortition is self-contained in
  `compute/dispute.scm` — verified: no voice imports there).
- `scope/`: strip `live.scm` only (scope.wasm backend).

## Strip — whole dirs

`comms/` (0 external importers), `calendar/` (1), `interface/` (3),
`push/` (2), `ui/` (2), `mqtt/` (3), `folksonomy/` (5 — after lobby slim),
`notify/` (11 — after lobby/gateway slim), `knowledge/data/` (9.2M:
agronomy, bioclim…), `knowledge/worlds/berlin-*`, `knowledge/law/` (except
imports vf-formulas need — verified below), `knowledge/recipes/`,
`knowledge/catalogues/` (except imports), `knowledge/dsl/`,
`knowledge/skills/`, `monero/policy.scm` (unreachable),
`solve/refresh-priors.scm`, `ai/{conform,corpus-search,onnx-embed,wordpiece}`.

Pending verification before delete: exact knowledge/vf-formulas import
closure (catalogues+worlds needed by `vf/formulas/shocks.scm` et al.).

## Strip — product surface

- `browser/app/*.js`: ~150 faces → keep the node set (lend, identity,
  storage-health, seam machinery, outbox/idb/keystore, install/pwa,
  attention toast machinery). New `browser/node.html`.
- `browser/boards/`, `browser/app/map-*`, `pmtiles`, demo/capture/contest.
- `hoot/repl.scm` + `browser/repl.js` + `repl.wasm` (page dropped; operator
  console = gateway REPL socket, already exists).
- `hoot/scope-worker.scm` + `browser/scope.wasm` + scope face.
- `hoot/family-worker.scm`, probe `.scm` files for stripped domains.
- `hoot/day-boot.scm`: 367 `handle-*`s → ~60 (identity + machine + seam).
- `server/serve-static.scm`: keep (serves node.html + discovery); drop
  app-shell asset routes the strip orphans.
- `tests/`: non-machine suites (map/nutrition/family/calendar/social/plan…).
- `deploy/`: policies/services for stripped domains (litellm stays —
  inference leg; OPA door policies → machine.rego only).

## Named casualties (confirmed in plan review)

`scope.wasm` planning face, `repl` page, voice ballots, knowledge corpus
data, federated-planning tier (entangled-keep for now, surgical v2), all
commons-domain faces.

## Rename contract (Phase 0, before strip)

`compute-*` → `machine-*` wire names; `naoms-compute-receipt/v1` digest
domain PINNED (spec §3 interop with hive-bridge golden vectors).
