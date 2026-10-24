# Spiral grant — draft email

> **Status: DRAFT — send to `grants@spiral.xyz`** (rolling, email-based;
> they fund individual devs working on FOSS Bitcoin — portfolio includes
> BTCPay, BDK/LDK tooling, watchtowers. Our fit: a pure nostr↔Bitcoin
> earning loop, AGPL, no token, no ICO.)

**Subject:** Grant proposal — localchimera: earning sats from a browser tab (NIP-90 paid compute)

Hi Spiral team,

I'm applying for a Spiral grant to continue work on **localchimera** —
free and open-source software (AGPL-3.0) that turns a browser tab into an
accountable, payable compute node.

**Repository:** <https://github.com/TerexitariusStomp/localchimera-compute>
(489 commits, ~720 green test checks, active development)

## What it does for Bitcoin

Every way to earn Bitcoin for machine resources today requires
installing a native daemon, holding a datacenter or DePIN account, and
living where payout rails reach. localchimera removes all three:

- A **NIP-90 data vending machine** runs entirely in-browser —
  kind-5xxx job requests come in over public nostr relays, execute in a
  WASM sandbox, and return kind-6xxx results priced in sats. No
  install, no account, no permission.
- Settlement is honest: jobs open a zero-balance `sat` receivable that
  closes only when payment actually lands — the books never pretend
  work was paid for when it wasn't.
- For users without reliable internet, the same signed envelopes cross
  a Reticulum/LXMF mesh — receipts wait in a store-and-forward mailbox
  until the radio comes back.

This is the missing supply side for sats-denominated machine work:
anyone with a phone or laptop browser can sell compute, storage,
bandwidth, and sensing — paid in Bitcoin, self-custodied, uncensorable.

## What the grant funds (~9 months part-time)

| Milestone | Deliverable |
|---|---|
| M1 | Hardened multi-relay browser DVM — backoff, dedup, spam resistance |
| M2 | bolt11/zap settlement — sat receivables become spendable BTC per completed job |
| M3 | Mesh intake client + mailbox drain for low-connectivity users |
| M4 | Onboarding docs for non-technical earners |

Requested: **$25,000** (BTC), open to whatever amount fits the program.

## Disclosures

- Nym: **TerexitariusStomp**; Colorado, USA; terexmaps@gmail.com
- This codebase is developed with an AI software agent (Devin) under my
  direction; commits carry `Generated with Devin` provenance — public
  and verifiable in the repo. All funded work is reviewed and tested in
  the open.
- No token, no equity ask, no entity — an AGPL public good.
- I've also applied to OpenSats and HRF BDF for adjacent milestones;
  happy to keep scopes disjoint however you prefer.

Thanks for reading — happy to jump on a call or answer anything.

— TerexitariusStomp
