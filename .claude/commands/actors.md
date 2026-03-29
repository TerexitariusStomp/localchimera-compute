---
description: xorg governance actors — ^org, ^logger, proxy pairs, Heart of Spritely patterns
---

You are editing the governance kernel. These actors implement Heart of Spritely patterns (sections 3.2.2 and 3.3.4) as direct Goblins mappings. On native Guile, these patterns are optional — you can write them inline. On Hoot/WASM, they are the compiled foundation.

## Key files

| File | Contents |
|------|----------|
| `module/xorg/actors.scm` (96 lines) | `^org`, `^logger`, `spawn-logged-revocable-proxy-pair`, persistence env |
| `module/xorg/repl.scm` (124 lines) | `make-open-org`, `make-governed-org`, `enter!` (Hoot convenience factories) |

## Actor reference

### `^org` — pure state
```scheme
(define-actor (^org bcom bindings)
  (methods
   [(lookup name) (assq-ref bindings name)]
   [(modify! name value) (bcom (^org bcom (cons (cons name value) bindings)))]
   [(snapshot) bindings]
   [(restore! snapshot) (bcom (^org bcom snapshot))]))
```
State is an alist. Mutation is `bcom` — the actor becomes a new version of itself. Supports `#:portrait`/`#:restore` for Goblins persistence.

### `^logger` — accountability
Uses `^cell` for an append-only log. Each entry records: user identity, method called, arguments, org snapshot at time of call. Methods: `append-to-log`, `get-log`, `get-log-for`.

### `spawn-logged-revocable-proxy-pair` — identity
Wraps any object in a proxy that logs every call and can be revoked. Returns `(values proxy revoked?-cell)`. The proxy IS the identity — revoking the cell kills access.

## Governance = composition

| Need | Goblins provides | Pattern |
|------|-----------------|---------|
| State | `bcom` | `^org` uses `bcom` to become new bindings |
| Accountability | `^cell` + wrapping | `^logger` accumulates entries; proxy logs before forwarding |
| Attenuation | `^facet` | Expose only `lookup`/`snapshot` for read-only view |
| Revocation | `^cell` flip | Set the revocation cell to `#t` — proxy is dead |
| Identity | Actor refs | Unforgeable; the ref IS the identity |

Do not build validators, signing, or endorsement at this layer. Governance is compositional wrapping, not built-in logic.

## Common editing patterns

- **Add a method to `^org`:** Add to the `(methods ...)` block. Update the persistence portrait if the method affects state. Update `filter-serializable-bindings` if needed.
- **Add a new actor:** Use `define-actor`. Add to `org-env` persistence environment. Export from module.
- **Add a factory:** See `make-governed-org` in `repl.scm` — it wires `^org` + `^logger` + proxy pairs + `^facet` together and returns all refs.

## Testing

`make test-governed` runs `tests/test-governed-org.scm`.

## The user's request

$ARGUMENTS
