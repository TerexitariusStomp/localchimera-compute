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

OPEN: which party issues the binding ACDC — the scope, or the person's own
KE?

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
  (`{unit: tokens|seconds, amount}`) is its quantity, `repro` its committed
  replay parameters.
- The receipt digest is byte-identical to `naoms-compute-receipt/v1`:
  `sha256("naoms-compute-receipt/v1" || 0x00 || canonicalJSON(fields))`.
  Lender signs first, coordinator/scope countersigns. Golden vectors are shared
  with `packages/hive-bridge` tests so all commons verify one format.
- `SubmitOutcome` ∈ `accepted|preempted`; `preempted` is a recorded fact, no
  pay, no miss — the job requeues to the outer ring.

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

## Appendix B — open questions for the playnet authors

1. Code license for playnet itself (proposal lands AGPL-3.0 with PR-0).
2. JS inference inside a browser worker, or must compute be hoot-compiled
   Scheme?
3. `API_PROVIDER=generic` acceptable for non-enclave workloads (first contact)?
4. `rep` as a separate credit-fold `kind` — agreed?
5. Who issues AID↔did:key binding ACDCs (§1 OPEN)?
6. hREA interop: protocol-level VF compatibility or deliberately independent?

## Appendix C — inventory rule

Before any module is written, name the OSS that covers it or record why none
does. Verified licenses and the <5% custom-code budget live in
`oss-inventory.md` (megaplan, mirrored here once PR-0 lands).
