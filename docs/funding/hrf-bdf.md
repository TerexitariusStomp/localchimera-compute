# HRF Bitcoin Development Fund — draft application

> **Status: DRAFT for user review → submit at
> <https://hrf.org/program/financial-freedom/bitcoin-development-fund/>**
> Rolling, year-round. Individuals eligible. Grants paid in BTC;
> recent rounds averaged ~$10–50k/grant across 16–26 projects per
> round. Their lanes: censorship-resistant communications, self-custody,
> payment integrations, education for people under authoritarian
> regimes.

## Framing

HRF funds tools that keep people transacting and communicating under
repression. localchimera's contribution: **machine resources earnable
over rails that cannot be shut off or permissioned** — nostr identity
(NIP-90 paid jobs), sats settlement, and a Reticulum mesh path that
works where there is no ISP relationship at all. A community that can
earn sats for spare compute — with a browser tab, no install, no
datacenter account, no KYC'd cloud — holds a financial-freedom tool.

## Application text

**Project:** localchimera — censorship-resistant earning via
browser-native paid compute (NIP-90) and mesh demand

**The problem.** Distributed-compute earning today requires installing
proprietary or native daemons, holding accounts with cloud or DePIN
operators, and residing where fiat payout rails reach. People under
authoritarian regimes — precisely those who most need uncensorable
income — are excluded on every axis: no install rights, no cloud
accounts, no payout access.

**What exists.** localchimera (AGPL-3.0, 489 commits, ~720 green
test checks, <https://github.com/TerexitariusStomp/localchimera-compute>) makes a browser tab
an accountable compute node. Paid demand enters over NIP-90 (nostr):
kind-5xxx requests execute in-browser and return kind-6xxx results
priced in sats — a pure nostr↔Bitcoin earning loop needing only a tab
and a relay connection. For users off the internet entirely, the same
envelopes cross a Reticulum mesh: `machine-mesh-intake` stamps an LXMF
result-destination, and the signed receipt — cryptographic proof of
completed work — waits in the requester's mailbox until their radio
comes back. Settlement is honest: receivables book in `sat` and are
marked paid only when sats actually land.

**What this grant funds.** Productionizing the earning path for the
users HRF serves: hardening the browser DVM against hostile relays and
spam job floods, completing bolt11/zap settlement so sat receivables
become spendable BTC, and shipping the mesh intake client + mailbox
drain tooling so low-connectivity users can participate end-to-end.

**Budget:** **$35,000 USD** (BTC) over ~9 months part-time.

| Milestone | Deliverable | Amount |
|---|---|---|
| M1 | Hardened multi-relay DVM (backoff, dedup, spam resistance) | $10k |
| M2 | bolt11/zap settlement → spendable BTC per completed job | $10k |
| M3 | Mesh intake client + mailbox drain for offline requesters | $10k |
| M4 | Docs + onboarding for non-technical users | $5k |

**Sustainability.** Mutual credit and demand-side revenue keep the
commons running without ongoing HRF support; the software is AGPL and
publicly developed.

**AI-use disclosure:** developed with an AI software agent (Devin)
under human direction; commits carry `Generated with Devin`
provenance, and all funded work is reviewed and tested in the open.

### Submission checklist

- [ ] Form at the BDF page → "Submit your proposal" (brief description
      first; they follow up for detail).
- [ ] BTC address ready.
- [ ] Expect follow-up questions on the freedom-use case specifics —
      name real communities/users if you have them (strengthens
      enormously; HRF funds deployed impact).

## Sources

- BDF: <https://hrf.org/program/financial-freedom/bitcoin-development-fund/>
- Recent rounds: <https://hrf.org/latest/hrf-grants-500m-satoshis-to-16-freedom-tech-projects-worldwide/>
