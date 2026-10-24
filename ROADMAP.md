# Roadmap

Milestone-shaped work packages. Each is independently shippable and is
worded so grant applications can cite it verbatim as a milestone.

## Shipped

- **The commons core** — lane offers, job envelopes, dispatch claims,
  signed replayable receipts, mutual-credit folds, KERI identity,
  ocapn door protocol (139 declared doors), hoot/WASM browser seam.
- **The swarm** — `params.swarm` descriptor shards one job across claims;
  map/stage/merge over exec/store/relay/sense kinds, stripe/hop/fleet
  legs.
- **The provider bridge** — ring-3 routing to external networks
  (golem/mysterium/storj legs), local-first, PUBLIC-only, fail-closed,
  attempts ledger.
- **The governor** — member-first preemption: `policyHold` gates claims,
  `watchRun` aborts mid-run, `machine-preempt` lands honest `preempted`
  outcomes, `maxClaims` bounds lending.
- **The demand edge** — payer registry (browser / api / commune-daemon /
  hardware classes), `^demand-desk` customer books (prepaid + postpaid),
  `^payer-ledger` receivable rows.
- **The demand api** — `POST /api/demand/*` translators: OpenAI-shaped
  chat + transcription, `/fetch`, `/check`, `/loadtest`, `/prove`,
  `/render`, `/pin`, `/ocr`, S3 `PUT/GET`. Bearer = demand keyHash.
- **The NIP-90 DVM** — browser runner over vendored noble-secp256k1;
  kind-5xxx requests → postpaid `sat` intake → kind-6xxx results.
- **The mesh intake** — `machine-mesh-info`/`machine-mesh-intake`,
  LoRa-honest caps, `params.mesh.result-dest` stamping, receipt→mailbox
  delivery wake for Reticulum requesters.

## M1 — Public gateway deploy + demand API GA

A localchimera instance serving `/api/demand/*` at a public URL, behind the
existing caddy/compose stack, with an operator runbook. Acceptance: an
external client can register a demand key, credit a book (manually),
submit a chat-completion job, and read the receipt via
`machine-demand-job`.

## M2 — Billing rail: BTCPay → demand desk

BTCPay Server (already adopted, MIT) invoice → settled-webhook →
`machine-demand-credit` top-up. Acceptance: a customer paying a BTCPay
invoice sees demand-book balance rise without operator intervention;
unpaid invoices never credit.

## M3 — NIP-90 DVM productionization

Multi-relay connect with backoff, request dedup, result content in the
6xxx event body (not just the digest), optional bolt11/zap settlement
metadata verified before the ledger marks `paid`. Acceptance: a real
nostr client can post a kind-5000-range request to public relays and
receive a priced result from a browser-tab DVM.

## M4 — Mesh GA

A Reticulum-side intake client + mailbox drain tooling so an
intermittent user submits an envelope and later drains the receipt
notice. Acceptance: end-to-end job over a live Reticulum path —
submit → node executes → receipt notice waits in the destination
mailbox → requester drains it.

## M5 — Security review + packaging + docs

Threat model for the egress-fetch abuse surface (residential-IP
legitimacy, rate caps, consent receipts), external review of the
demand-API auth path, one-command deploy packaging (Guix service
already exists; polish to documented GA), and user-facing docs for
operators, lenders, and demand customers.

## Later / conditional

- Token payout rails per-member opt-in (shipped binding model; the
  treasury Safe path needs a live chain deployment to exercise).
- `commune-daemon` provider class — native-supply integrations
  (Golem/Akash/Storj-node) for members who *do* run daemons.
- Hardware-class lanes (sensor/LoRA-owned feeds) — requires the
  hardware.
