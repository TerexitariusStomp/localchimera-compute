# spec/e2e-map.md — what proves "complete", and where the debt sits

The completeness contract for this repo, made mechanical by
`tools/lint/check-e2e-coverage.py` (ratchet-style: a baseline file holds
the known gaps; the gate fails on any NEW uncovered name, and closed
names must leave the baseline).

## The three layers

| Layer | Where | What it proves | Runner |
|---|---|---|---|
| door-level scenario | `tests/e2e/*.scm` | a whole story through `declared-doors` — not one act, the chain | guile in-vat, fast |
| browser e2e | `tests/ux/*-ux.mjs` | a real tab against a real gateway + wasm | playwright via ux-full.sh |
| live-stack e2e | `tests/e2e/stack-integration.scm` + parity live legs | the adopted upstreams answer through the actual call sites | `tests/e2e/run-stack.sh` |

## The compute spine — the machine-resources focus

| Scenario | Suite | Status |
|---|---|---|
| bind → offer → submit → match → claim → accept → envelope → receipt → verify → replay → settle → payout | `tests/e2e/compute-lifecycle.scm` | this pass |
| non-delivery dispute (deadline past, no receipt → no payment) | `tests/e2e/compute-dispute-flows.scm` | this pass |
| wrong-result dispute (replay → counterHash → sortition 2-of-3 → verdict → settlement hold) | `tests/e2e/compute-dispute-flows.scm` | this pass |
| reproduced replay → dispute refused at raise (premise fails on the prover's own answer) | `tests/e2e/compute-dispute-flows.scm` | this pass |
| browser executor (js:/wasm: sandbox, cap denial, deterministic WASI, canonical digest) | `tests/browser/compute-executor-test.mjs` | this pass |
| lend face drives a tab as a compute node | `tests/ux/lend-ux.mjs` | authored; runs where repl.wasm builds |
| live adopted stack answers through call sites | `tests/e2e/stack-integration.scm` | this pass |

## Delegate seams — call-site coverage

| Seam | Call site | Parity suite | Live leg |
|---|---|---|---|
| ntfy | `interface/adapters/ntfy.scm` → notify router | `notify-ntfy.scm` | ✅ green |
| OPA | doors/compute commune acts (`#:authz` consult) | `doors-opa.scm` | ✅ green |
| Jena/SPARQL | knowledge corpus door | `knowledge-sparql.scm` | ✅ green |
| Radicale/CalDAV | calendar door | `calendar-radicale.scm` | ✅ green |
| CP-SAT | solve/solver discrete leg | `solve-cpsat.scm` | ✅ green |
| Odoo | ddmrp buffer-zones | `ddmrp-odoo.scm` | needs creds |
| cc-node | compute/settlement land | `economy-ccnode.scm` | pending service |
| Decidim | voice/ballot publish | `voice-decidim.scm` | pending service |
| LiteLLM | ai doors | `ai-litellm.scm` | pending model backend |
| ActivityPub | comms outbox | `federation-activitypub.scm` | pending server |
| Bacalhau | compute/executors | *none* | **suite missing** |
| Cedar | alternate door engine | *none* | **suite missing** |
| Temporal | compute-clock durable timers | *none* | **suite missing** |

## The debt ledger (baseline, 2026-10-22)

`tools/lint/e2e-coverage-baseline.txt` holds 128 known gaps:
- 44 declared doors with no test naming them (sync-*, list-*, my-*,
  witness-*, folksonomy-template, …)
- 81 dispatch handlers with no browser/ux test naming them
- 3 delegates with no parity suite (bacalhau, cedar, temporal)

The ratchet: the list only shrinks. A new door/handler/delegate without a
test fails the gate at commit time; closing a gap removes its line.

## What "complete" still cannot claim

- `browser/repl.wasm` is not built in this environment (hoot toolchain is
  guix-pinned); `lend-ux.mjs` runs where it can build.
- Heavy services (Odoo, Decidim, cc-node, ActivityPub, LiteLLM backends)
  are not running — their live legs skip loudly, never silently.
- Cross-gateway compute federation is out of scope: the compute registry
  is per-commune on one gateway by design.
