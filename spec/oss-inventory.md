# OSS Inventory — playnet-compute

Per Appendix C of `playnet-compute.md`: before any module is written, name the
OSS that covers it or record why none does. This file is that record, plus the
custom-code budget and how it's measured.

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

## Tier 1 — the focus (custom residue lives here)

Machine resources are the product; ~12k lines of custom code concentrate here.

| Function | OSS adopted | License | Custom residue |
|---|---|---|---|
| Browser executor | **Wasimoff** webprovider + broker | MIT | envelope↔task adapter |
| Server execution + replay | **wasmCloud** + Wasmtime | Apache-2.0 | claim↔component adapter |
| Claim lifecycle/deadlines | **Temporal** | MIT | workflow glue |
| Ring-3 orchestration | **Bacalhau** + **Golem yagna** (supplier) | Apache-2.0 / GPL-3.0 | envelope adapters + §8 privacy gate |
| Inference lanes | **llama.cpp / ollama** + **LiteLLM** ⚠ | MIT | key-pool adapter |
| TEE evidence tier | **dcap-qvl / Intel DCAP / NVIDIA NRAS** | Apache-2.0 / BSD-3 | fills `verify-quote` seam |
| Fleet provisioning | **OpenTofu** + providers | MPL-2.0 | reconciler adapter |
| Treasury | **Safe + protocol-kit** | LGPL-3.0 / MIT | settlement adapter |
| Transport | **iroh / libp2p / arti** (+Reticulum opt-in ⚠) | MIT/Apache-2.0 | netlayer glue |
| Canonical JSON | **RFC 8785 JCS impl** | MIT | — |
| Job envelope / receipt / repro-spec | — **custom** | AGPL-3.0 (ours) | ~1.5k — the spec's contract |
| `^compute-registry` + dispatch lifecycle | — **custom** | ours | ~1.5k — commons-dispatch semantics |
| Compute governance doors | — **custom** | ours | ~2.5k — capability-door model |
| Seam/door machinery | — **custom** (over Goblins, Apache-2.0) | ours | ~4k — the ocapn substrate contract |
| Dispatch matcher (lane+class+headroom) | — **custom** | ours | ~0.3k |
| Lend/borrow/fleet/identity faces | — **custom** | ours | ~2.5k — hand-built focus UX |
| Specs, vectors, personhood adapter | — **custom** + BrightID/PoH attestations ⚠ | ours | ~1.5k |

## Tier 2 — the delegation layer (functionality kept, maintenance delegated)

| Function | OSS host | License | Our residue |
|---|---|---|---|
| Planning (`solve/`, `plan/`, `matching/`, `algorithms/`) | **OR-Tools CP-SAT** (alt: SCIP, HiGHS) | Apache-2.0 / MIT | constraint-model builder ~1k |
| VF accounting (`vf/`, `observation/`, `scope/`, `pools/`) | **hREA** ⚠ CAL substrate | Apache-2.0 | event adapter ~0.5k |
| Mutual credit + federation (`economy/`, `federation/`) | **Credit Commons cc-node** + ActivityPub | GPL-3.0 | ledger adapter ~0.5k |
| Ballots/sortition (`voice/`) | **Decidim** (sortitions component) | AGPL-3.0 | governance adapter ~0.3k |
| Identity (`keri/`, `keys/`, `credentials/`) | **keria + signify-ts** | Apache-2.0 | binding-ACDC adapter ~0.5k |
| Knowledge corpus (`knowledge/`) | corpus stays **data**; queries → **Apache Jena** | Apache-2.0 | SPARQL adapter ~0.3k |
| Inventory (`ddmrp/`) | **Odoo OCA ddmrp** / ERPNext | LGPL-3.0 / GPL-3.0 | ERP adapter ~0.3k |
| Org/social/folksonomy | **hREA agents + ActivityPub** | Apache-2.0 | ~0.3k |
| Domain doors (~15k) | authorization → **Cedar/OPA**; bodies → **Temporal** | Apache-2.0 / MIT | policies ~2k |
| Calendar | **Radicale + FullCalendar** | GPL-3.0 / MIT | ~0.1k |
| Push/notify | **ntfy / UnifiedPush** | Apache-2.0 | ~0.1k |
| Broker (`mqtt/`) | **mosquitto** | EPL-2.0 | ~0.1k |
| Edge (`gateway/`) | **nginx / Caddy** | BSD-2 / Apache-2.0 | ~0.1k |
| Indexes | **SQLite / LMDB** | public domain / OpenLDAP | ~0 |
| Secret sharing | **shamir SSS** ⚠ verify | MPL-2.0 | ~0 |
| XMR flows (`monero/`) | **wallet-rpc + BTCPay** | BSD-3 / MIT | ~0.2k |
| i18n/query | **i18next / datascript** | MIT / EPL-1.0 | ~0.1k |
| Non-focus UI | **refine / react-admin / Appsmith** + MapLibre/H3/FullCalendar | MIT / Apache-2.0 | ~1k |
| Legal registry | ledger adapter + policy checks | — | ~0.5k |
| Dev/issue tooling | **Radicle heartwood** | MIT/Apache-2.0 | ~0 |
| OS/deploy | **Guix + Shepherd** | GPL-3.0 | service defs |
| Backups | **restic** | BSD-2 | ~0 |

## Already adopted (in use today)

| Component | License | Where |
|---|---|---|
| Spritely Goblins | Apache-2.0 | actor/ocap substrate |
| Guile / Hoot | LGPL-3.0 | Scheme + WASM toolchain |
| keria + signify-ts | Apache-2.0 | keria-service, browser KERI |
| monerod + wallet-rpc | BSD-3 | fleet payments |
| nginx | BSD-2 | edge |
| tor | BSD-3 | onion transport |
| MapLibre GL + H3 | BSD-3 / Apache-2.0 | map faces |
| Radicle heartwood | MIT/Apache-2.0 | repo + CI |
| Guix System + Shepherd | GPL-3.0 | deploy |

## Honest residue estimate

Tier 1 ~12k + Tier 2 ~8k ≈ **20k custom vs ≥400k adopted ≈ 4.5%** — under
budget with all functionality kept. The last points are the hardest; the
ratchet gate makes the direction enforceable regardless.

## Adoption order

P1 focus spine (replay, did:key, lend loop, ring-3) → P2 compute execution
(Wasimoff, wasmCloud, Temporal, LiteLLM, dcap-qvl, OpenTofu) → P3 economy
(hREA, cc-node, Safe) → P4 identity/governance (keria, Decidim, Cedar/OPA) →
P5 domains (OR-Tools, Jena, Odoo OCA, ActivityPub, Radicale, ntfy) → P6 UI
recompose → P7 SBOM + proof.

**Rule:** no adapter lands without semantic-parity tests against the code it
replaces. Functionality kept is proven, not asserted.
