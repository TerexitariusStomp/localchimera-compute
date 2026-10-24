# Maelstrom Bitcoin grant — draft email

> **Status: DRAFT — send to `grants@maelstrom.fund`** (rolling,
> email-based Bitcoin FOSS grants, $5–50k typical range. Same project,
> slightly more infrastructure-framed than the Spiral draft.)

**Subject:** Bitcoin FOSS grant — localchimera: browser-native sats-earning compute (NIP-90)

Hi Maelstrom team,

Requesting a grant for **localchimera** (AGPL-3.0) — software that makes
any browser tab an accountable node that earns sats for real machine
work.

**Repository:** <https://github.com/TerexitariusStomp/localchimera-compute>
(489 commits, ~720 green test checks)

## The gap

Bitcoin's earning side is still gated: mining needs capital and
hardware, Lightning node liquidity needs locked sats, and distributed
compute networks require native installs and operator accounts. The
result: billions of idle browsers that could sell machine resources —
CPU, storage, bandwidth, presence — have no way to be paid in sats.

## What exists and works

- **Browser NIP-90 DVM**: kind-5xxx job requests over nostr relays →
  WASM execution in-tab → kind-6xxx results, priced in sats. Pure
  nostr↔Bitcoin loop; a tab plus a relay connection is the whole
  requirement.
- **Honest settlement**: postpaid intake opens zero-balance `sat`
  receivables that close only on actual payment — no self-dealing
  ledger entries.
- **Reticulum mesh intake**: the same signed job envelopes and receipts
  traverse LXMF store-and-forward for users beyond ISP reach.

## What a grant funds (~9 months part-time)

| Milestone | Deliverable |
|---|---|
| M1 | Multi-relay DVM hardening — backoff, dedup, spam resistance |
| M2 | bolt11/zap settlement → spendable BTC per job |
| M3 | Mesh intake client + mailbox drain tooling |
| M4 | Earner onboarding docs |

Requested: **$20,000** (BTC).

## Disclosures

- Nym: **TerexitariusStomp**; Colorado, USA; terexmaps@gmail.com
- Developed with an AI software agent (Devin) under human direction;
  `Generated with Devin` commit provenance is public. All funded work
  is reviewed and tested openly.
- AGPL public good — no token, no equity.
- Parallel applications pending with OpenSats/HRF/Spiral; scopes kept
  disjoint.

— TerexitariusStomp
