# Replay policy — what "authoritative" means when the job can't be re-run byte-for-byte

PoI replay is the dispute oracle (spec §5). But an oracle that demands the
same bytes from a nondeterministic job is an oracle that always condemns
the honest lender. This document is the verdict on that gap.

## The three modes and what each is worth

| mode | the claim | what replay answers |
|---|---|---|
| `exact` | "same input, same bytes" | `reproduced` only when the re-run's output hash equals the receipt's. The strongest evidence — for `wasm:` images under the deterministic WASI shim (seeded `random_get`, pinned clock, stdin=input, stdout=output) it is *free* correctness: WASM is deterministic modulo host functions, and the shim removes the nondeterminism. |
| `deterministic` | "same input, seed, decoding — same result" | `reproduced` when the re-run under the pinned seed/decoding matches. Covers seeded inference, quantized models, anything the lender could have made reproducible but did not pin in the receipt. |
| `none` | "no replay promised" | **evidence only.** The replay door answers `unverifiable` — never `reproduced`, never `mismatch`. The mode is the job's own declaration that hash-equality is not the test. |

## The nondeterminism verdict

**A `none` job is never convicted by replay, and never exonerated by it.** The
verdict that lands in the dispute is the *evidence the challenge carries*:

- the receipt digest and the attestation hash — what the lender claimed;
- the meter — seconds/tokens, the size of the claimed work;
- the counter-hash — `no-executor`/`unverifiable` when no re-run exists.

For a nondeterministic job (LLM output without pinned seed+decoding,
network-touching work, entropy-drawn results) the dispute's sortition review
weighs what remains: the meter's plausibility, the envelope's declared
capabilities, the lender's standing (`HonestyReport` history), and any
canary evidence the commune's policed lanes produce. That is a *reviewer's
judgment*, not a prover's bit — and it is the honest limit: a job that
declares `none` is a job that accepts its disputes are decided by review,
not by replay.

## What the lender signs up for, per mode

| | `exact`/`deterministic` | `none` |
|---|---|---|
| wrong-result dispute | replay decides; mismatch loses | review decides on the evidence |
| strong claim | yes — provable | no — declared unprovable |
| required for payout | yes where the job's class demands it | allowed, but the job's lane marks it |

The registry already carries this: `lane-offer-repro-mode` is a promise the
lender's whole lane makes. A commune that wants provable compute runs lanes
that require `exact` or `deterministic`; a `none` lane is an offer the
borrower takes knowing review — not replay — is the arbiter.

## The canary line that is NOT a mode

`canary` tasks (seeded jobs with known answers, submitted by the hive
itself) are the proactive complement: they make a lane's honesty *measured*
rather than asserted, and they work on `none` lanes too — the canary's
answer is known, so nondeterminism is not an excuse. A lender that flunks
canaries is a lender whose `none` declarations stop mattering.
