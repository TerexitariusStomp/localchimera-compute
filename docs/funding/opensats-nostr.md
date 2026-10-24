# OpenSats — nostr fund — draft application

> **Status: DRAFT for user review → submit at <https://opensats.org/apply>**
> Window: applications open the first two months of each quarter —
> **open now (Oct–Nov), closes Dec 1**. Grants USD-denominated, paid in
> BTC on-chain. Progress reports every 90 days (first-timers: 30-day
> reports for the first three months).
> **Required:** a ≤2-minute video with a *human* voice-over
> (fully-AI-generated videos get the application discarded).
> FOSS work must be "produced in the open" — frequent public commits
> (Radicle counts as a public forge; consider a GitHub mirror for
> reviewer convenience).

## The scoped ask: production NIP-90 DVM infrastructure

OpenSats funds nostr things; this is a nostr deliverable, not the whole
commons. Scope the application to what nostr users get.

### Application text

**Project name:** localchimera-dvm — browser-native NIP-90 compute supply

**What is it?**

localchimera is an open commons for machine resources where a
browser tab is an accountable node — KERI identity, signed replayable
receipts, mutual-credit settlement (AGPL-3.0, 489 commits, ~720 test
checks, `rad:z2xjyuu4adoo1x88is8xtRz2tYwhu` on Radicle). Its
`browser/app/machine-dvm.js` runner already speaks NIP-90: it watches
kind-5xxx job requests, executes them in-browser over vendored
noble-secp256k1 (pure WebCrypto — no native install for anyone), and
publishes kind-6xxx results with pricing tags. Settlement is honest:
a `sat` receivable is booked per job and marked paid only when the
requester's zap/bolt11 lands — the ledger records what was priced,
never what was hoped.

This grant productionizes that DVM: multi-relay connect with backoff
and dedup, result content embedded in 6xxx events (today the node posts
a digest + status to the claim's signal channel), bolt11/zap
verification against the payer-ledger row, and a reference deployment
any nostr user can open in a tab to start earning sats for compute.

**Why it's good for Bitcoin and nostr**

- It makes nostr a real *market* protocol: NIP-90 moves value (sats)
  for verifiable work, not just notes.
- It is the first browser-only DVM implementation: any nostr user with
  a tab becomes a supplier — the supply side stops being a
  GPU-operator club.
- Sats are the settlement asset end-to-end: demand books are
  denominated in `sat`, receivables price in sats, and payout is BTC —
  no token, no wrapped anything.
- Everything ships AGPL with frequent public commits, in the open, per
  the grant agreement.

**Budget:** **$20,000 USD** (BTC), over ~8 months part-time.

| Milestone | Deliverable | Amount |
|---|---|---|
| M1 | Multi-relay DVM client (connect/backoff/dedup), public relays wired | $6k |
| M2 | Rich results: content in 6xxx events, tag-complete NIP-90 compliance | $5k |
| M3 | Settlement: bolt11 invoice presentation + zap verification → payer-ledger `paid` | $6k |
| M4 | Reference deployment + docs: open `node.html`, earn sats | $3k |

**Existing work:** the DVM runner, nostr event codec + Schnorr
crypto (vendored noble-secp256k1, browser-clean), postpaid demand
intake with auto-opened `sat` books, and the payer ledger all exist and
are test-covered (`tests/browser/machine-dvm-test.mjs`,
`tests/e2e/machine-payers.scm` postpaid scenario).

**AI-use disclosure:** development uses an AI software agent (Devin)
under human direction; commits carry `Generated with Devin` provenance.
All funded work will be reviewed, tested, and committed openly.

**Report cadence accepted:** 30-day progress reports for the first
three months, then 90-day.

### Submission checklist for the human

- [ ] Record the ≤2-min video: show `node.html` → DVM section → a
      kind-5xxx request arriving → a 6xxx result. Human voice-over.
- [ ] Host the video somewhere link-stable (nostr.build, own site,
      YouTube unlisted).
- [ ] Paste application text into <https://opensats.org/apply> —
      select nostr fund relevance in the form.
- [ ] Have a BTC on-chain address ready for the agreement stage.

## Sources

- Apply: <https://opensats.org/apply> · FAQ: <https://opensats.org/faq/application>
- Nostr fund: <https://opensats.org/funds/nostr>
