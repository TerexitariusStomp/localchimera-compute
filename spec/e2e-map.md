# spec/e2e-map.md — what proves "complete", and where the debt sits

The completeness contract for this repo, made mechanical by
`tools/lint/check-e2e-coverage.py` (ratchet-style: a baseline file holds
the known gaps; the gate fails on any NEW uncovered name, and closed
names must leave the baseline).

## The three layers

| Layer | Where | What it proves | Runner |
|---|---|---|---|
| door-level scenario | `tests/e2e/*.scm` | a whole story through `declared-doors` — not one act, the chain | guile in-vat, fast |
| browser node leg | `tests/browser/*.mjs` | the executors, stores, relays and policies the tab runs | plain node, DOM shims |
| live-stack e2e | `tests/e2e/stack-integration.scm` + parity live legs | the adopted upstreams answer through the actual call sites | `tests/e2e/run-stack.sh` |

## The machine spine — the product's whole story

| Scenario | Suite | Status |
|---|---|---|
| bind → offer → submit → match → claim → accept → envelope → receipt → verify → replay → settle → payout | `tests/e2e/machine-lifecycle.scm` | green |
| every kind's envelope through the doors: 'store, 'relay, 'sense, 'bundle — kind + params intact, per-kind meter on the receipt | `tests/e2e/machine-kinds.scm` | green |
| non-delivery dispute (deadline past, no receipt → no payment) | `tests/e2e/machine-dispute-flows.scm` | green |
| wrong-result dispute (replay → counterHash → sortition 2-of-3 → verdict → settlement hold) | `tests/e2e/machine-dispute-flows.scm` | green |
| reproduced replay → dispute refused at raise (premise fails on the prover's own answer) | `tests/e2e/machine-dispute-flows.scm` | green |

## The node legs — what the tab itself runs

| Kind | Browser module | Suite |
|---|---|---|
| `exec` — js:/wasm: worker sandbox, cap denial, deterministic WASI, canonical digest | `browser/app/machine-executor.js` | `tests/browser/machine-executor-test.mjs` (9) |
| `store` — IDB shelf, monotonic byte-seconds, `sha256(nonce ∥ content)`, lazy helia leg | `browser/app/machine-store.js` | `tests/browser/machine-store-test.mjs` (19) |
| `relay` — fetch-cap-gated HTTP legs, DataChannel over the claim's signal log, canary probe | `browser/app/machine-relay.js` | `tests/browser/machine-relay-test.mjs` (23) |
| `sense` — platform-honest sources, unavailable-not-fabricated | `browser/app/machine-sense.js` | `tests/browser/machine-sense-test.mjs` (29) |
| `bundle` — sequential legs, per-kind meters in the digest preimage | `browser/app/machine-bundle.js` | `tests/browser/machine-sense-test.mjs` |
| lend policy — hidden tab / save-data / low battery hold the loop | `machine-executor.js` `policyHold` | `tests/browser/machine-sense-test.mjs` |

## The shelves — the registry's persistent actors

| Shelf | Suite |
|---|---|
| offers / jobs / claims / match / receipt / expiry | `tests/machine/test-registry.scm` (120) |
| wire adapters, envelopes, usage units | `tests/machine/test-adapters.scm` (14) |
| receipt digest, canonicalization, verdicts | `tests/machine/test-receipt.scm` (30) |
| storage challenges — issue/answer/verify, parties only, expiry | `tests/machine/test-challenge.scm` (53) |
| relay signals — seq'd log, parties post/read, live claims only | `tests/machine/test-signal.scm` (20) |

## Delegate seams — call-site coverage

The adopted services kept by the machine product; each has a parity suite
and a live leg where the service runs.

| Seam | Call site | Parity suite | Live leg |
|---|---|---|---|
| ntfy | `interface/adapters/ntfy.scm` → notify router | `notify-ntfy.scm` | ✅ green |
| OPA | doors/machine commune acts (`#:authz` consult) | `doors-opa.scm` | ✅ green |
| Jena/SPARQL | knowledge corpus door | `knowledge-sparql.scm` | ✅ green |
| CP-SAT | solve/solver discrete leg | `solve-cpsat.scm` | ✅ green |
| Odoo | ddmrp buffer-zones | `ddmrp-odoo.scm` | needs creds |
| cc-node | machine/settlement land | `economy-ccnode.scm` | pending service |
| Decidim | voice/ballot publish | `voice-decidim.scm` | pending service |
| LiteLLM | ai doors | `ai-litellm.scm` | pending model backend |
| ActivityPub | comms outbox | `federation-activitypub.scm` | pending server |
| Bacalhau | machine executors | *none* | **suite missing** |
| Cedar | alternate door engine | *none* | **suite missing** |
| Temporal | machine-clock durable timers | *none* | **suite missing** |

## The debt ledger (baseline)

`tools/lint/e2e-coverage-baseline.txt` holds the known gaps (151 at last
count): declared doors and dispatch handlers with no test naming them,
plus the three delegate seams with no parity suite above.

The ratchet: the list only shrinks. A new door/handler/delegate without a
test fails the gate at commit time; closing a gap removes its line.

## What "complete" still cannot claim

- `browser/day-boot.wasm` is a build product (hoot toolchain, guix-pinned);
  the JS-side seam wrappers are tested, the wasm surface builds in CI.
- A real WebRTC DataChannel between two tabs is faked pairwise in tests —
  the signal rendezvous and leg logic are proven; ICE on hostile NATs is not.
- did:key↔AID receipt signatures: `lenderSig:null` verifies as
  `unverifiable` until the binding ACDC issuer is decided (spec §1 OPEN).
- Heavy services (Odoo, Decidim, cc-node, ActivityPub, LiteLLM backends)
  are not running — their live legs skip loudly, never silently.
- Cross-gateway machine federation is out of scope: the registry is
  per-commune on one gateway by design.
