# playnet-compute

A commons for sharing machine resources — compute, storage, bandwidth —
between people who already trust each other, and only as far as they do.

Members publish **lane offers** (what their hardware can run, at what
reproducibility, with how much headroom), submit **jobs** as ValueFlows
intents, get dispatch claims as commitments, and settle on **signed
receipts** — metered, replayable economic events that ride the routing
rings: own devices first, then own commune, then peer communes, and only
at the outside an anonymous market that settles against a treasury Safe.

The compute vocabulary lives in [`spec/playnet-compute.md`](spec/playnet-compute.md)
(vendored from `commons-spec`) and its code in
[`module/playnet/machine/`](module/playnet/machine/): `specs.scm` carries
compute `ResourceSpecification`s (model class, lane, `reproMode ∈
exact|deterministic|none`), `receipt.scm` the `SignedReceipt` wire record
whose canonical digest is byte-identical to the poi-compute TypeScript
implementation.

## What this repo is

A **surface cut** of the playnet commons platform, not a rewrite. The
substrate a compute commons needs is kept whole: KERI identity and ACDC
credentials, scope membership and governor capabilities, the ValueFlows
record layer, the matching and solver engine, federation crossing,
mutual-credit settlement folds, the capability door protocol, the
fleet reconciler, and the browser seam (Hoot/WASM day-boot). What left
is the product surface that was not about machines: the chat-network
bridges (Matrix, Telegram), the QGIS worker, the SMS wall, the corpus
service, the dev bridge, and the benchmark/exo tooling.

History is ported — `git log` reaches back through the playnet tree.

## Layout

- `module/playnet/machine/` — compute specs + signed receipts
- `module/playnet/fleet/` — declarative host fleet: records, reconciler,
  providers, keeper
- `module/playnet/gateway/` — mesh mailbox, presence, HTTP door server
- `module/playnet/doors/` — the capability door layer (identity,
  personhood, economy, offers, service, inventory, slots, assignments)
- `module/playnet/{scope,vf,solve,federation,economy,pools}` — the
  substrate spine: membership, records, engine, crossing, settlement
- `server/` — gateway, fleet-bridge, fleet-keeper, deploy-runner
- `ui/` + `browser/` — the dial (TypeScript → committed JS; opens on the
  map, the order book, and the forum)
- `hoot/` — the browser-resident Scheme that compiles to WASM
- `deploy/` — Guix OS + service definitions for the box
- `spec/` — the compute commons specification

## Test

```
make test            # the green baseline (needs guix for TEST_ENV)
```

Individual suites run plain: `guile -L module -L tests tests/<dir>/<t>.scm`.
The UI freshness gate is `make check-ui-fresh` (TypeScript → committed JS).
