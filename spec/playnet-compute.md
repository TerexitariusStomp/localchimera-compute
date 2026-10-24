# playnet-compute — the compute commons specification

Status: SKELETON. Sections state what the two codebases already agree on; OPEN
markers name what the authors must still decide. A playnet patch implements a
section and cites it.

The model in one paragraph: a commune member's browser tab is a compute node.
Needs are intents; jobs are commitments; verified results are economic events;
credit for proven work folds up the scope tree like labour does. The anonymous
market — PoI's existing pool — is the outermost ring of the same routing
mechanism, never a replacement for the inner ones.

## §1 Identities

- Playnet agents are KERI AIDs; consent and capacity are ACDC credentials.
- Compute-side signer identities are `did:key` (Ed25519), per
  `naoms-compute.md` §1 — unchanged.
- `AccountLink` binds an external account to a DID: `{didKey, hiveDid|scopeAid,
  account: CAIP-10, purpose: node|payout, nonce, expiry}`, dual-signed
  (EIP-712 or EIP-191 + did:key countersignature). Either side unlinks.
- A KERI AID ↔ did:key binding is an `AccountLink` whose `account` field is
  `keri:<aid>`; issuance of the corresponding ACDC is the link event.
- One accountable identity per pool-facing bridge: `grant.subjectDid`.
- Personhood: playnet ceremonies produce witnessed-work attestations; PoI
  vouches/rep gates map onto them rather than a parallel system.

DECIDED (shipped): the binding is self-issued, dual-signed — the person's
own AID signs `account-sig` over the `keri:<aid>` AccountLink statement and
the did:key countersigns (`binding.scm`, `verify-keri-account-sig`). No
third-party issuer exists or is needed: the two keys' signatures over the
same canonical statement ARE the link. A scope may later endorse a binding
for ranking, but it is never the issuer. With it, `lenderSig` on a receipt
verifies outright: `did:key` lenders verify under the key the DID encodes,
AID lenders through the KEL/device resolver — `verified` | `unverifiable` |
`bad`, never a silent pass.

## §2 Scopes and pools

- A PoI `pool` is a playnet scope. `site:`/`project:`/`hive:` tags become scope
  attributes; `site = hive:<did>` is a scope-scoped dispatch hint.
- The PoI global pool is the UC — the scope that federates all communes for
  compute.
- Pool lifecycle (close, derate, re-activate) maps to scope graduation states.

## §3 Work vocabulary

- A `compute` `ResourceSpecification` carries: `modelClass` (task types:
  inference, fetch, storage, bandwidth, compute, jury, canary, `SWARM_INFER`),
  `lane`, `reproMode` ∈ `exact|deterministic|none`.
- A job is an `Intent` against a compute spec. Dispatch claim is a
  `Commitment`. The `SignedReceipt` is the `EconomicEvent` — `usage`
  (`{unit: tokens|seconds|bytes|byte-seconds|readings|node-hours, amount}`)
  is its quantity, `repro` its committed replay parameters.
- An envelope declares a `kind` — `exec` (image + entrypoint in a worker
  sandbox), `store` (hold `inputHash` for `ttlSeconds`; answer
  `sha256(nonce ∥ content)` retention challenges), `relay` (move bytes on
  `params.inUrl→outUrl` HTTP legs or a DataChannel negotiated over the
  claim's own signal log; `params.probe` is the canary), `sense` (emit
  platform readings on `params.intervalMs × count`), `bundle`
  (`params.legs` — sub-envelopes run in order, one level deep). Kind
  fields ride `params` — price keys are refused recursively at parse.
- The meters: `seconds`/`tokens` (exec), `bytes` (relay), `byte-seconds`
  (store retention), `readings` (sense), `seconds` (bundle — the only
  honest cross-kind sum; per-leg meters ride the digest's preimage).
- A `webgpu` cap on an exec envelope requires an adapter at run time;
  none means the run refuses — the cap is a promise, not a wish.
- The receipt digest is byte-identical to `naoms-compute-receipt/v1`:
  `sha256("naoms-compute-receipt/v1" || 0x00 || canonicalJSON(fields))`.
  Lender signs first (`lenderSig`, verified door-side per §1); the
  countersign is the borrower's `machine-accept` plus the door's own
  recording — an authenticated act, not a detached signature — so the
  wire's `borrowerSig` field rides null. Golden vectors are shared
  with `packages/hive-bridge` tests so all commons verify one format.
- `SubmitOutcome` ∈ `accepted|preempted`; `preempted` is a recorded fact, no
  pay, no miss — the job requeues to the outer ring.
- `params.swarm` marks an envelope as one shard of a task no single node
  runs: `{group, shards, shard-index, role, link?, quorum?}` — `group` is
  the borrower-opened swarm record's id (the registry shelf binds the
  shard jobs; index in its `job-ids` IS `shard-index`), `role` must fit
  the kind: `stage|map|merge` on `exec` (pipeline link, data-parallel
  slice, quorum assembly), `stripe` on `store` (one stripe per claim,
  challenged like any store claim), `hop` on `relay` (one link of a
  chained DataChannel path; `link` names the adjacent pair it joins),
  `fleet` on `sense` (a sampling fleet whose readings a merge leg
  aggregates). One job still mints one claim — the swarm is coordination
  over claims, never a billing entity; a shard's receipt is its own.
  The swarm's rendezvous is the signal shelf keyed `swarm:<id>`, member-
  gated the door's way: the borrower plus lenders holding live shard
  claims — a settled shard's holder has no more to say.

## §4 Capacity and headroom

- A node's capability set is a `LaneOffer`: model classes, lanes, and
  `headroom` — the share of capacity reserved for inner-ring work.
- Routing rings, verbatim from `naoms-compute.md` §5a: (0) own devices,
  (1) own commune, (2) friends/peer communes, (3) the anonymous market.
  Inner rings always win; the market is the same mechanism at a different
  consent level, not a rival kind of demand.
- Playnet communes and peer-scope relationships ARE rings 0–2; PoI's pool is
  ring 3. Dispatch uses playnet's affinity + feasibility matching, not a ported
  site→project→global cascade.
- Ring 3's concrete legs are **provider networks** — golem for `exec`/`bundle`,
  mysterium for `relay` egress, storj for `store` — reached through
  `machine-bridge-submit`: the borrower alone routes its own job, only a job
  submitted `ring:3` may cross (INTERNAL/SECRET never carries one), only
  while it stays `open`, and only when `match` returns no inner offer —
  **own capacity always wins; the provider is fallback, never preferred**.
  Provider calls ride injected transports and fail closed when unwired;
  the attempts ledger (`^bridge-store`) records job, network, ref and
  result hash — the rows a settlement statement's `payments` name. The
  provider sees envelope refs and caps, never credentials, never a price.

## §5 Credit and settlement

- Compute work earns a `rep` cell in the credit fold — a separate `kind`,
  displayed with visible ratios, never silently converted into labour credit.
- Rings 1–2 settle in mutual credit (folds). Ring 3 settles externally:
  `SettlementStatement` `{period, entries:[{bridgeJobId, receiptDigest,
  amount, asset:CAIP-19}], payments:[{txHash, asset, amount}], bridgeSig}` —
  one payee, the commune treasury Safe; lender asset preference is internal
  payout policy and does NOT appear in the statement.
- `economy/payouts.scm` is the rail; the Safe binding is a `purpose:payout`
  `AccountLink` on the scope's grant.
- Member distribution is **mutual credit by default, token by opt-in**:
  `settlement->member-plan` partitions each reconciled entry by whether
  the lender holds a LIVE `purpose:payout` `AccountLink` naming a chain
  account. The dual-signed binding IS the opt-in signature — entries for
  a bound lender become sends to the bound CAIP-10 (never a free-form
  address); everyone else's entries post to the commons ledger untouched.
  Token denominations (GLM, MYST, WBTT, XMR…) exist only as CAIP-19
  assets at the treasury/member edge — the node wire never prices work
  and never holds a key.
- `RateStatement` `{base, quote, rate, at, bridgeSig}` is the exchange
  reference a commune uses to price credit against an external
  denomination — a bridge attestation, signed like the statement that
  settles.
- **The demand edge** (`doors/payers.scm`): a payer registry names the
  paying networks in three honest classes — `browser` (servicable from a
  tab today: `nostr-dvm`), `api` (standard wire shapes the demand API
  translates: openai-style inference, scrape-fetch, uptime-check,
  load-test, s3-store, mcp tools), and `commune-daemon`/`hardware`
  (catalogued, not wired — native daemons and radios a tab cannot run).
  The `^demand-desk` keeps per-customer books (keyHash → `{balance,
  asset, commune}`) — prepaid for fiat-style buyers, auto-opened
  postpaid (`sat`, zero balance) for crypto-native jobs. `^payer-ledger`
  records one receivable row per funded job; `machine-payer-settle`
  marks paid only against an external ref the caller actually supplies —
  the ledger never pretends a payment it has not seen.

## §6 Honesty

- Canaries cross unmarked (task 206); a scope's governance rules must disclose
  covert testing.
- The replay prover is the machine verdict: `exact` = hash equality;
  `deterministic` = committed seed+params, per-task-type equivalence;
  `none` = structural validity only, semantic complaints go to member review.
- `HonestyReport` `{period, scopeAid, observed, expected, sig}` is reciprocal —
  a scope measures PoI exactly as PoI measures it — and is an auditor-fold
  input. Any score affecting routing is visible to the measured party and
  appealable.
- TEE attestation (playnet's sensitive-AI posture) and redundancy+canaries
  (PoI's) compose rather than merge: `TEE/` model slugs never route to pool
  workers; pool results never carry enclave claims they did not earn.
- **Member-first**: the node's owner always outranks the work it lends.
  `policyHold` gates claims before they start; the governor keeps the same
  eyes mid-run — a landing hold or a claim that left the live states
  aborts the worker and lands `machine-preempt` ('preempted, unpaid, not
  a miss, the job requeues outward). `maxClaims` bounds how much of the
  machine lending may hold at once. No abort ever mints a receipt.

## §7 Transport

- Intra-playnet: ocapn sturdyrefs on the existing gateway (mycapn WS);
  compute services are lobby doors like everything else.
- NAOMS interop: signed DIDComm over iroh, per `naoms-compute.md` — unchanged;
  no HTTP compute surface, no bearer tokens.
- Browser workers reach their scope's services through the gateway the browser
  app already uses; no new listener ports for members.
- Reticulum netlayer remains opt-in: its license bars use in creating AI
  training corpora. This network runs inference, not training — but the clause
  is recorded here so no one wires logged traffic into an eval corpus later.
- **The demand API is a payer surface, not a member surface**:
  `doors/demand.scm` translates standard buyer wire shapes at
  `POST /api/demand/*` — `/v1/chat/completions` and
  `/v1/audio/transcriptions` (OpenAI-shaped), `/fetch`, `/check`,
  `/loadtest`, `/prove`, `/render`, `/pin`, `/ocr`, plus S3 `PUT/GET` —
  into internal envelopes stamped `params.payer`. The bearer credential
  is the customer's demand `keyHash`, never a member session; intake
  debits the demand book (or books the receivable postpaid), mints the
  job, and the customer polls `machine-demand-job` scoped to its own
  key. NAOMS's "no HTTP compute surface" rule stands for members — this
  surface exists because external buyers do not hold playnet sessions.
- **NIP-90 postpaid**: the browser DVM runner
  (`browser/app/machine-dvm.js` + `browser/lib/nostr.js` on vendored
  noble-secp256k1) subscribes a commune's relays for kind-5xxx requests
  in its lanes, intakes each under `nostr-dvm` with `'postpaid` — the
  demand desk auto-opens the requester's zero-balance `sat` book on
  first sight and skips the debit — runs the job, and publishes the
  kind-6xxx result. Payment is a receivable row until the payer settles
  (zap/bolt11 metadata rides the event honestly); the ledger records
  what was priced, never what was merely hoped.
- **Mesh demand crosses mutual-credit only**: `machine-mesh-intake`
  mints a job for a Reticulum requester with `params.mesh.result-dest`
  (a 64-hex destination) stamped on the envelope — no payer row, no
  demand book. Intake refuses what cannot cross a radio: input over the
  serialized byte cap, inline image bytes (refs only), a malformed dest.
  When the job's receipt lands, the notice posts to the requester's
  mailbox destination; `drain!` is the wake for a client whose link is
  intermittent. `machine-mesh-info` answers the caps up front so a mesh
  client asks only for what crosses.

## §8 Privacy

- Classification × scope disclosure, per `naoms-compute.md` §11: PUBLIC only
  crosses to ring 3. INTERNAL and SECRET never do.
- Consumer identity, `amountWei`, market and payment tags never enter a
  compute envelope bound for a lender.
- Per-scope pseudonyms: a worker's scope-visible identity is not their
  cross-scope one.
- Full plaintext results are retained only for the dispute window; hash
  commitments survive forgetting.

## §9 Governance

- Spec changes: two signatures (one delegate per project), per DELEGATES.md.
- A scope's compute policy (rings enabled, headroom defaults, disclosure of
  canaries, payout splits) is commune governance, ratified the commune's own
  way — the spec fixes the messages, not the politics.
- UC-level compute policy (global headroom floors, market-rail terms) follows
  playnet's UC ratification.

## Appendix A — module map

| playnet kernel | compute port |
|---|---|
| scope/commune | pool |
| intent | job envelope |
| commitment | dispatch claim |
| EconomicEvent | `SignedReceipt` |
| resource/capacity live-ref | `LaneOffer` |
| `with-capacity` reserve/release | claim→execute→deadline |
| credit folds | `rep` kind; `pools/compute-fold.scm` |
| affinity + feasibility matching | dispatch |
| auditor/attestation folds | canary + prover + `HonestyReport` |
| ^lobby sturdyrefs | job-submit/result/capabilities doors |
| personhood ceremonies | witnessed-work attestations |
| (no single-node ceiling) | swarm — `params.swarm` shards over claims |
| ring-3 pool adapters | `providers.scm` + `machine-bridge-submit` |
| member's own load | governor — `watchRun` → abort → `machine-preempt` |
| paid demand / customer books | `payers.scm` — registry, `^payer-ledger`, `^demand-desk` |
| standard buyer wire shapes | `doors/demand.scm` at `POST /api/demand/*` |
| nostr paid compute | `machine-dvm.js` + `nostr.js` — kind-5xxx→6xxx, `'postpaid` intake |
| off-wifi demand | `machine-mesh-intake` → `params.mesh.result-dest` → `mesh-mailbox` wake |

## Appendix B — open questions, answered where the code already answered them

1. Code license for playnet itself — DECIDED: AGPL-3.0-or-later. The full
   text is `LICENSE` at the repository root; first-party source files carry
   `SPDX-License-Identifier: AGPL-3.0-or-later`; `guix.scm` declares
   `license:agpl3+`; vendored and emitted third-party files keep their own
   licenses (`browser/vendor/`, `.hoot-compat/`, `deploy/typst-packages/`,
   `browser/reflect.js`) per `spec/oss-inventory.md`.
2. JS inference inside a browser worker, or must compute be hoot-compiled
   Scheme? — DECIDED, shipped: the job payload is JS or wasm inside a
   sandboxed Worker (`browser/app/machine-executor.js`); the accountability
   layer — doors, receipts, digests — is Scheme. `env.image` selects per
   envelope; neither side trusts the other.
3. `API_PROVIDER=generic` for non-enclave workloads? — DECIDED for v1: no
   generic provider leg exists. Envelopes execute locally (JS/wasm, IDB
   storage, platform sensors); outbound network rides only `network: true`
   + the `fetch` cap on relay legs. A provider leg would arrive as a new
   kind, not a flag.
4. `rep` as a separate credit-fold `kind`? — DECIDED, partial: the credit
   fold's monoid is already keyed by kind (`credit-fold.scm`); machine work
   lands as `use` events today and a `rep` cell kind is a monoid addition
   when the account-store emits it. Deferred until settlement wants it.
5. Who issues AID↔did:key binding ACDCs? — DECIDED, shipped: self-issued,
   dual-signed (§1). `lenderSig` verifies.
6. hREA interop? — DECIDED at the event layer: `receipt->event` emits
   real VF `EconomicEvent`s (`use`, provider/receiver, resourceQuantity,
   fulfills/satisfies, inScopeOf) onto the scope observer — hREA's own
   vocabulary. A GraphQL bridge is deliberately out of scope for v1; the
   event model is the interop surface.
7. Do mutual credit and external token rails (GLM, MYST, WBTT, USDC…)
   coexist in the same space? — DECIDED, shipped: **credit is the
   default; token is per-member opt-in.** The options the wire already
   admitted were (a) credit-only, (b) dual-rail — CAIP-19 statements
   with txHash evidence at the treasury edge, (c) exchange-priced
   credit — rate statements as bridge attestations, (d) direct member
   token payout through the `purpose:payout` AccountLink seam. (b) is
   the shipped rails model — receipts stay asset-neutral metering
   facts; (c) lands as `RateStatement`; (d) ships opt-in, gated on the
   dual-signed `payout` binding (`settlement->member-plan`). A member
   who never binds stays entirely in credit; tokens live at the
   treasury/member edge and never enter node trust.
8. Who pays, and how does paid demand reach a tab? — DECIDED, shipped:
   **buyers speak their own wire shapes; the demand edge translates.**
   Traditional demand pays for standard APIs, not networks — so
   `doors/demand.scm` serves OpenAI-shaped inference and transcription,
   scrape-fetch, uptime checks, load tests, proving, rendering, pinning,
   OCR, and S3 store at `/api/demand/*`, each minting a real envelope.
   Crypto-native paid demand arrives as NIP-90 jobs the browser DVM
   earns directly (postpaid `sat` receivables). Daemon/hardware payer
   networks (Golem, Akash, Helium-class) stay catalogued in the payer
   registry, honestly classed `commune-daemon`/`hardware` — a browser
   cannot run them and the spec does not pretend otherwise.
9. Can a client with no WiFi — a radio on Reticulum — buy compute? —
   DECIDED, shipped: yes, on mutual credit. `machine-mesh-intake`
   carries the same envelope across the mesh link, stamps the LXMF
   result-dest, and the mailbox is the store-and-forward wake: the
   receipt notice waits in the destination's mailbox until the client
   drains it. LoRa-sized honesty applies at intake — oversize inputs
   and inline images refuse before a job ever mints.

## Appendix C — inventory rule

Before any module is written, name the OSS that covers it or record why none
does. Verified licenses and the <5% custom-code budget live in
`oss-inventory.md` (megaplan, mirrored here once PR-0 lands).
