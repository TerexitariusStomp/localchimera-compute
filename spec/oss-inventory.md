# OSS Inventory — localchimera machine node

Per Appendix C of `localchimera.md`: before any module is written, name the
OSS that covers it or record why none does. This file is that record, plus the
custom-code budget and how it's measured.

The product is a **machine-resource node in a browser tab**: compute,
inference, storage and bandwidth offered and claimed under KERI identity,
metered by replayable receipts, settled by mutual credit. Everything below
serves that and nothing else — the commons surfaces (labour, food, housing,
calendars, maps, the dial UI) were stripped and appear in no row.

## The budget

**First-party code we write and maintain ≤5% of the code the deployed product
runs on.** Custom = source lines in this repo (Scheme, TS/JS, scripts),
excluding generated files, vendored code, lockfiles, and data. Adopted OSS
runs as libraries and services it names — it doesn't live in the tree, but the
tree records it here and in the SBOM.

The budget is a direction enforced as a ratchet: `make check-custom-budget`
fails if first-party lines exceed the recorded baseline, and the baseline only
moves down until it reaches 5%.

## License rules

**First-party code is AGPL-3.0-or-later** (`LICENSE` at the root; per-file
`SPDX-License-Identifier` markers; `license:agpl3+` in `guix.scm`).
Third-party files in the tree keep their own licenses — `browser/vendor/`,
`.hoot-compat/` (LGPL-3.0-or-later), `deploy/typst-packages/`, Hoot's
`browser/reflect.js` — and are excluded from the SPDX sweep.

Adopted licenses must be free and commercially usable: MIT, Apache-2.0, BSD,
MPL-2.0, LGPL, GPL, AGPL, EPL, public domain, CAL-1.0 (counsel note below).
Nothing paid, nothing source-available (no BUSL, SSPL, Elastic).

### Flagged

- **Reticulum** (Reticulum License) — permissive + field-of-use clauses (no
  AI-training datasets, no harm systems). Opt-in netlayer only, never on
  inference traffic. Spec §7 already requires this.
- **CAL-1.0** (Holochain, beneath hREA) — OSI-approved, commercially usable,
  but its autonomy clause obligates giving users their data and keys. Aligned
  with the commons; counsel note on file.
- **Terraform→OpenTofu** — Terraform is BUSL-1.1 (source-available, fails the
  bar). OpenTofu is the MPL-2.0 fork; adopt that.
- **LiteLLM** — MIT core; some key-management endpoints are Enterprise (paid).
  Verify any endpoint the key-pool needs lives in the MIT tree.
- **Bacalhau** — Apache-2.0 code, trademark reserved. Don't name builds
  "Bacalhau".
- **BrightID / Human Passport** — verify exact licenses before consuming
  attestations (GPL-family / Apache; reading attestations needs no copy).
- **hashicorp/shamir** — standalone SSS library, believed MPL-2.0; verify
  before adopting (HashiCorp relicensed products, libraries may differ).
- ✗ excluded outright: Terraform, Elastic, Mongo, Sentry (BUSL/SSPL), SaaS-only
  services, hosted APIs.

## Tier 1 — the machine product (custom residue lives here)

| Function | OSS adopted | License | Custom residue |
|---|---|---|---|
| Browser executor | **Wasimoff** webprovider + broker | MIT | `machine/adapters.scm` + `browser/app/machine-executor.js` |
| Server execution + replay | **wasmCloud** + Wasmtime | Apache-2.0 | `machine/replay.scm`, `machine/executors.scm` |
| Claim lifecycle/deadlines | **Temporal** | MIT | `delegates.scm` temporal seam + claim loop |
| Ring-3 orchestration | **Bacalhau** + **Golem yagna** (supplier) | Apache-2.0 / GPL-3.0 | `delegates.scm` bacalhau seam + spec §8 privacy gate |
| Inference lanes | **llama.cpp / ollama** + **LiteLLM** ⚠ | MIT | `delegates.scm` litellm seam + key-pool adapter |
| In-browser ML runtime | **transformers.js + ONNX Runtime Web** (vendored `browser/vendor/transformers`) | Apache-2.0 / MIT | `params.model` descriptor + executor staging only |
| Browser crypto | **noble curves/hashes** (vendored `browser/vendor/noble`) + WebCrypto | MIT / platform | — |
| Content-addressed fetch | **helia** (lazy `browser/app/helia.js` seam) | MIT / Apache-2.0 | `machine-store.js` fetch leg only |
| Swarm coordination | — **custom glue** over claims + signal shelf | ours | `machine/swarm.scm` (~90) + `browser/app/machine-swarm.js` (~200): the heavy legs are the kind runners already counted |
| Ring-3 provider legs | **Golem yagna / Mysterium node / Storj** | GPL-3.0 / AGPL-3.0 | `machine/providers.scm` (~190) + `machine-bridge-submit` door — transports injected, fail-closed |
| Member-first governor | — **custom** | ours | `browser/app/machine-governor.js` (~70) over the executor's own abort surface |
| Demand edge (payer registry, books, ledger, translators) | — **custom** | ours | `doors/payers.scm` + `doors/demand.scm` (~0.8k) — buyer wire shapes mint envelopes; books/ledger are mutual-credit rows |
| NIP-90 paid compute | **nostr NIPs** (protocol) + **noble-secp256k1** (vendored, schnorr) | public-domain / MIT | `browser/lib/nostr.js` + `browser/app/machine-dvm.js` (~0.4k) |
| Mesh demand intake | **Reticulum mailbox** (already flagged ⚠) | ours over flagged | `machine-mesh-intake` door + receipt→mailbox wake in `doors/machine.scm` |
| API surface docs | **swagger-ui** (vendored) | Apache-2.0 | — |
| TEE evidence tier | **dcap-qvl / Intel DCAP / NVIDIA NRAS** | Apache-2.0 / BSD-3 | fills `verify-quote` seam |
| Fleet provisioning | **OpenTofu** + providers | MPL-2.0 | `fleet/reconciler.scm` + provider seams |
| Treasury | **Safe + protocol-kit** | LGPL-3.0 / MIT | `machine/safe.scm`, `machine/payout.scm` |
| Transport | **iroh / libp2p / arti** (+Reticulum opt-in ⚠) | MIT/Apache-2.0 | `gateway/` netlayer glue |
| Canonical JSON | **RFC 8785 JCS impl** | MIT | — |
| Job envelope / receipt / repro-spec | — **custom** | AGPL-3.0 (ours) | `machine/envelope.scm`, `machine/receipt.scm`, `machine/specs.scm` (~350) |
| `^machine-registry` + dispatch lifecycle | — **custom** | ours | `machine/registry.scm` (546) |
| Machine doors | — **custom** | ours | `doors/machine.scm` (844) — capability-door model |
| Seam/door machinery | — **custom** (over Goblins, Apache-2.0) | ours | `protocol/` (1281) — the ocapn substrate contract |
| Dispatch matcher (lane+class+headroom) | — **custom** | ours | `machine/registry.scm` (~0.3k inside it) |
| Node page + executor JS | — **custom** | ours | `browser/node.html` + `browser/app/` + `day-boot.js` (~2k) |
| Machine specs, vectors, identity adapter | — **custom** + BrightID/PoH attestations ⚠ | ours | `machine/binding-verifiers.scm`, `machine/specs.scm` |

## Tier 2 — the delegation layer (functionality kept, maintenance delegated)

| Function | OSS host | License | Our residue |
|---|---|---|---|
| Planning (`solve/`, `plan/`, `matching/`, `algorithms/`) | **OR-Tools CP-SAT** (alt: SCIP, HiGHS) | Apache-2.0 / MIT | `delegates.scm` cpsat seam + constraint-model builder |
| VF accounting (`vf/`, `observation/`, `scope/`, `pools/`) | **hREA** ⚠ CAL substrate | Apache-2.0 | `machine/hrea.scm` (machine leg) |
| Mutual credit + federation (`economy/`, `federation/`) | **Credit Commons cc-node** + ActivityPub | GPL-3.0 | `machine/credit-commons.scm` (machine leg) |
| Ballots/sortition (`voice/`) | **Decidim** (sortitions component) | AGPL-3.0 | `delegates.scm` decidim seam + governance adapter |
| Identity (`keri/`, `keys/`, `credentials/`) | **keria + signify-ts** | Apache-2.0 | `machine/binding-verifiers.scm` + binding-ACDC adapter |
| Knowledge corpus (`knowledge/`) | corpus stays **data**; queries → **Apache Jena** | Apache-2.0 | `delegates.scm` sparql seam |
| Inventory (`ddmrp/`) | **Odoo OCA ddmrp** / ERPNext | LGPL-3.0 / GPL-3.0 | `delegates.scm` odoo seam |
| Org/social/folksonomy | **hREA agents + ActivityPub** | Apache-2.0 | `delegates.scm` ap seam |
| Domain doors | authorization → **Cedar/OPA** | Apache-2.0 | `delegates.scm` opa/cedar seams + `deploy/policies/` |
| Push/notify | **ntfy / UnifiedPush** | Apache-2.0 | `delegates.scm` ntfy seam |
| Broker (`mqtt/`) | **mosquitto** | EPL-2.0 | federation facts-sync wiring |
| Edge | **nginx / Caddy** | BSD-2 / Apache-2.0 | `deploy/os.scm` config |
| Indexes | **SQLite / LMDB** | public domain / OpenLDAP | ~0 |
| Secret sharing | **shamir SSS** ⚠ verify | MPL-2.0 | ~0 |
| XMR flows (`monero/`) | **wallet-rpc + BTCPay** | BSD-3 / MIT | `monero/wallet.scm`, `monero/policy.scm` |
| Dev/issue tooling | **Radicle heartwood** | MIT/Apache-2.0 | satellite pins, CI hook |
| OS/deploy | **Guix + Shepherd** | GPL-3.0 | `deploy/os.scm`, `deploy/guix/*.scm` |
| Backups | **restic** | BSD-2 | `deploy/scripts/backup-state.sh` |

## Already adopted (in use today)

| Component | License | Where |
|---|---|---|
| Spritely Goblins | Apache-2.0 | actor/ocap substrate |
| Guile / Hoot | LGPL-3.0 | Scheme + WASM toolchain (`browser/day-boot.wasm`) |
| keria + signify-ts | Apache-2.0 | keria-service, browser KERI |
| monerod + wallet-rpc | BSD-3 | treasury + fleet payments |
| nginx | BSD-2 | edge |
| tor | BSD-3 | onion transport |
| Radicle heartwood | MIT/Apache-2.0 | repo + CI |
| Guix System + Shepherd | GPL-3.0 | deploy |
| OPA | Apache-2.0 | door policy gates (`deploy/policies/localchimera/`) |

## Honest residue ledger (post-strip, measured)

| Area | Lines | Note |
|---|---|---|
| `machine/` | 2,107 | the product: registry, envelope, receipt, replay, dispute, settlement, payout, adapters, hrea, safe, credit-commons, binding-verifiers, specs, executors |
| `doors/` + `protocol/` | 6,644 | door decls + dispatch + seam/shapes |
| `browser/` + `ui/` | ~9,900 | node.html, day-boot.js, executor, seam glue (excl. vendor/) |
| `keri/` + `keys/` + `credentials/` + `identity/` + `personhood/` | ~16,000 | identity substrate |
| `vf/` + `observation/` + `scope/` + `pools/` + `economy/` + `ddmrp/` | ~22,400 | accounting substrate |
| `solve/` + `plan/` + `algorithms/` + `matching/` + `knowledge/` | ~45,300 | planning substrate |
| `federation/` + `voice/` | ~10,200 | federation + governance |
| `gateway/` + `boot/` + `interface/` + `notify/` + `push/` + `mqtt/` + `bridge/` | ~9,000 | edge + boot + channels |
| `monero/` + `fleet/` | ~7,200 | treasury + provisioning |
| `legal/` + `folksonomy/` + `social/` + `org/` + `ai/` + `indexes/` + rest | ~14,300 | remaining substrate |
| `server/` + `hoot/` | ~6,600 | static server, gateway entry, day-boot source |
| `tools/` + `deploy/` | ~37,600 | emit/lint/test/deploy machinery |
| `tests/` | ~98,700 | the suite |
| **total first-party** | **~250k** | `check-custom-budget` baseline |

The strip cut the tree from ~374k to ~250k first-party lines; the doors a
machine node can reach dropped from 391 to 107 and the seam from ~370 to 74
handlers. The residue above that remains non-machine is substrate the machine
lifecycle still calls — accounting, planning, identity, governance — each
with its OSS delegation named in Tier 2.

## Adoption order

P1 focus spine (replay, did:key, lend loop, ring-3) → P2 machine execution
(Wasimoff, wasmCloud, Temporal, LiteLLM, dcap-qvl, OpenTofu) → P3 economy
(hREA, cc-node, Safe) → P4 identity/governance (keria, Decidim, Cedar/OPA) →
P5 substrate (OR-Tools, Jena, Odoo OCA, ActivityPub, ntfy) → P6 SBOM + proof.

**Rule:** no adapter lands without semantic-parity tests against the code it
replaces. Functionality kept is proven, not asserted.
