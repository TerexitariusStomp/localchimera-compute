# OTF Internet Freedom Fund — Stage-1 Concept Note draft

> **Status: DRAFT for user review → submit via OTF's online system**
> Rolling, two-stage (concept note → invited proposal; ~6–8wk Stage-1
> response). Awards $10k–900k; **sweet spot $50–200k over 6–12 months**;
> individuals eligible; prioritizes first-time applicants and
> under-represented groups. Performance-based contract, USD.
>
> **Honest-fit caveat (decide before submitting):** OTF's remit is
> technology that counters *authoritarian censorship and surveillance*.
> Our fit is real but indirect — connectivity resilience + bankless
> earning rather than circumvention. The concept note below is framed on
> the strongest honest claim. If it feels like a stretch to you too,
> deprioritize behind OpenSats/HRF.

## Concept note text

**Project title:** playnet-compute — machine-resource commons for
intermittent and constrained connectivity

**What problem does it solve, and for whom?**

Communities facing connectivity disruption — throttling, shutdowns,
unaffordable last-mile access, or deliberate isolation — lose not only
communication but economic participation: cloud work requires
persistent accounts, distributed-compute earning requires installed
daemons and fiat payout rails. There is no open infrastructure that
lets such communities either *sell* their spare machine capacity or
*buy* compute they lack, without permission from platforms they cannot
trust or banks they cannot use.

**What do you propose?**

playnet-compute (AGPL-3.0, in active development, publicly versioned
at `rad:z2xjyuu4adoo1x88is8xtRz2tYwhu`) is an open machine-resource
commons designed around exactly this constraint:

- **Browser-native supply:** a browser tab is a full resource node —
  no install, no admin rights, no datacenter account. Work is
  accountable through KERI identity, signed replayable receipts, and
  mutual-credit settlement that functions without banking rails.
- **Store-and-forward demand:** jobs and receipts cross Reticulum
  mesh links via an LXMF mailbox. A requester on intermittent
  connectivity submits a compute job; the signed receipt waits in
  their mailbox until their link returns.
- **Censorship-resistant demand channels:** paid demand arrives via
  standard API surfaces and via nostr NIP-90 — relays being
  permissionless, replaceable infrastructure — settling in satoshis
  with no platform intermediary.

**Activities (12 months):**

1. Productionize the mesh demand path: Reticulum intake client,
   mailbox drain tooling, end-to-end job flow over live radio links.
2. Productionize the NIP-90 earning path: hardened multi-relay DVM,
   bolt11/zap settlement to spendable BTC.
3. Field validation with partner communities on constrained links
   *(name partners if available — materially strengthens the note)*.
4. Security review of the demand-API and mesh intake surfaces;
   abuse-model documentation for egress-fetch.

**Outcomes:** a working, openly-licensed path by which a community with
intermittent or adversarial connectivity can contribute machine
resources for income and access compute it lacks — no installation, no
central account, no banking dependency.

**Estimated budget:** **$95,000** over 12 months (within the
$50–200k ideal band): engineering ~$72k, security review ~$12k,
community/partner field costs ~$6k, documentation ~$5k.

**AI-use disclosure:** developed with an AI software agent (Devin)
under human direction, with public commit provenance.

## Submission checklist

- [ ] Submit at <https://www.opentech.fund/funds/internet-freedom-fund/>
      → concept note form (short).
- [ ] Have partner/community specifics ready for the invited Stage-2
      proposal — OTF funds deployed applicability, and "mesh demand for
      X community" beats "mesh demand in the abstract".

## Sources

- Fund: <https://www.opentech.fund/funds/internet-freedom-fund/>
