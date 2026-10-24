# Funding — evidence pack and applications

Reusable facts, boilerplate, and per-program drafts. Every draft names
what the human still has to do (submit, record a video, write their own
prose where a funder bans AI-written applications).

## Project facts (verifiable)

| Fact | Value |
|---|---|
| Name | localchimera — a commons for machine resources |
| License | AGPL-3.0-or-later (all first-party code) |
| Repository | `rad:z2xjyuu4adoo1x88is8xtRz2tYwhu` on Radicle — public at <https://app.radicle.xyz/> (search the RID) |
| Commits | 489 |
| Tests | ~450 checks across 19 Scheme suites + 272 checks across 16 browser suites, all green at HEAD |
| Protocol surface | 139 declared capability doors, all covered by tests (`tools/lint/check-e2e-coverage.py`) |
| Spec | [`spec/localchimera.md`](../../spec/localchimera.md) — vocabulary, settlement, transport, honesty, privacy |
| Languages | Guile Scheme (Goblins actors, Hoot→WASM), browser ES modules |
| Identity | KERI AIDs + ACDC credentials, did:key lender bindings |
| Accounting | ValueFlows/hREA-compatible economic events |
| Mesh | Reticulum netlayer + LXMF mailbox (store-and-forward) |
| OSS posture | 61 adopted components, all allowlist-licensed; ~5% custom-residue budget enforced in CI |

## Boilerplate — reusable paragraphs

### Problem

Cloud consolidation means machine capacity is owned by a handful of
providers and rented back to everyone else. The machines people already
own — laptops, desktops, phones in browsers — sit idle, while
participating in distributed compute networks requires installing
native daemons that gatekeep who can supply. There is no commons where
an ordinary browser tab can be an accountable, paid resource node — and
no settlement layer that lets communities share machine capacity the
way they already share everything else: on trust, measured use, and
mutual credit rather than rent.

### Approach

localchimera ports the proof-of-interest resource vocabulary into a
capability-door architecture: browser tabs are nodes, every job is a
content-addressed envelope, every result is a signed replayable
receipt, and settlement is mutual credit by default with token payout
strictly opt-in at the treasury edge. Rings route demand inward-first:
own devices, then commune, then peer communes, then — for PUBLIC-class
work only — external provider networks. No native install is required
of anyone: a tab running WASM is a full participant. Demand enters
through the protocols buyers already speak (OpenAI-shaped HTTP, S3,
nostr NIP-90, Reticulum mesh), so supply and demand meet in the
middle.

### What a browser tab can and cannot do (honesty)

A tab executes JS/WASM jobs, fetches through its egress, stores to
IndexedDB, serves lightweight relay hops, and reports platform sensor
availability. It cannot run CUDA inference, seed petabytes, or promise
datacenter durability — and localchimera says so: the payer registry classes
every network honestly (browser / api / commune-daemon / hardware),
native-only providers are catalogued but never claimed, and swarm
coordination exists precisely because one tab is small. The
differentiation is accountability: receipts are signed, replayable, and
disputable; work that cannot be honestly run is refused at intake, not
faked.

### Differentiation

Against DePIN compute networks (Golem, Akash, Bacalhau): no daemon, no
token requirement, no datacenter assumption — membership is a browser
tab, settlement is mutual credit, and those networks appear as ring-3
fallback *providers*, not competitors. Against centralized API resale:
the demand edge translates standard wire shapes into commons jobs, so
buyers keep their tools while supply stays community-owned. Against
mesh projects (Reticulum, Meshtastic): localchimera is the demand side that
pays for transport — mesh requesters submit real jobs and collect real
receipts, with the mailbox as store-and-forward delivery.

## AI-provenance disclosure (read before submitting anything)

This codebase is developed with an AI software agent (Devin). Commit
messages carry `Generated with Devin` / `Co-Authored-By` provenance —
this is public and verifiable. Funder policies differ sharply:

| Funder | AI policy (verified Oct 2026) | Consequence |
|---|---|---|
| **NLnet** | GenAI policy v2.0 (Oct 20, 2026): AI may **not** write proposals; LLM use in project development confined to **read-only** | Likely **ineligible** — see `nlnet-ois-2026-11.md` before deciding |
| **Emergent Ventures** | Rejects AI-written applications (tests submissions) | Proposal must be human-written — `emergent-ventures-prep.md` is a research brief only |
| **OpenSats** | No writing ban; board favors applicants *disclosing* AI tool use; 2-min video must have human voice | Draft fileable; disclosure paragraph included |
| **HRF BDF** | No published AI policy | Draft fileable; same disclosure recommended |
| **OTF** | No published AI policy | Concept note fileable; disclosure paragraph included |
| **FUTO** | No published AI policy | Intro email fileable |
| **FFDW** | No published AI policy | Outreach email fileable |

**Do not remove the disclosure paragraphs silently** — several funders
independently verify provenance, and a concealed AI-development history
is a stronger reason for rejection than a disclosed one.

## The milestone bank

Cut from `ROADMAP.md` — applications pick the subset their funder
likes:

| # | Milestone | Suggested ask | Duration |
|---|---|---|---|
| M1 | Public gateway deploy + demand API GA | €8–10k | 8 wks |
| M2 | BTCPay → demand-desk billing rail | €6–8k | 6 wks |
| M3 | NIP-90 DVM productionization | €8–12k | 8 wks |
| M4 | Mesh GA (Reticulum intake client + drain tooling) | €8–12k | 8 wks |
| M5 | Security review + packaging + docs | €6–10k | 6 wks |

## The drafts

| File | Program | Status |
|---|---|---|
| `nlnet-ois-2026-11.md` | NLnet Restack, Nov 3 deadline | Research brief + eligibility flags — **user decision required** |
| `opensats-nostr.md` | OpenSats nostr fund | Ready for user review → submit |
| `hrf-bdf.md` | HRF Bitcoin Development Fund | Ready for user review → submit |
| `otf-iff-concept.md` | OTF Internet Freedom Fund | Stage-1 concept note, ready |
| `futo.md` | FUTO grants | Intro email, ready |
| `ffdw-outreach.md` | FFDW partnership | Outreach email, ready |
| `emergent-ventures-prep.md` | Emergent Ventures | Research brief — user writes |
| `watchlist.md` | ARIN, Gitcoin d/acc, Safe, Filecoin, Sovereign Tech, rails | Monitors + triggers |
