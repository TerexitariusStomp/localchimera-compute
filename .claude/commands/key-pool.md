---
description: Key pool — Goblins actor-based API key management, round-robin coordination, health tracking
---

You are editing the key pool — a capability-secure API key management system built on Goblins actors. Callers get a `^key-pool` ref and can make requests, but never see raw key strings. Each `^api-key` actor seals its own key material and HTTP client in its closure.

## Key file

`key-pool/key-pool.scm` (~466 lines)

## Actor reference

### `^api-key` — seals one raw key
- Holds: key string, private HTTP client, health state
- Methods: `request` (makes API call), `health`, `status`
- The raw key never leaves the actor's closure

### `^key-pool` — round-robin coordinator
- Holds: vector of `^api-key` refs, rotation index
- Methods: `request` (picks next healthy key), `pool-status`, `health-report`
- Tracks: success/failure counts, rate limits, cost, credits

### `<key-state>` record
Tracks per-key health: success count, failure count, last error, rate-limit detection, cost accumulation, donor info.

## Common editing patterns

**Add a new API provider:**
Modify the HTTP request construction in `^api-key`. Currently hardcoded to OpenRouter's API format.

**Add health detection:**
Extend the response parsing in the success/failure handlers within `^api-key`.

**Add a new pool strategy:**
Modify the round-robin selection logic in `^key-pool` (e.g., weighted selection, least-recently-used).

## Convenience constructor

```scheme
(make-key-pool "key1,key2,key3")  ;; comma-separated key string
```

## Gotchas

- **Server-only.** Depends on `(web client)`, `(json)`, SRFI-9, SRFI-19 — cannot run in Hoot/WASM.
- **Currently OpenRouter-specific.** The HTTP client, headers, and response parsing assume OpenRouter's API.

## The user's request

$ARGUMENTS
