---
description: Metacircular Scheme evaluator for Hoot/WASM — adding forms, base bindings, browser evaluation
---

You are editing the metacircular evaluator. Hoot cannot compile Guile's `eval`, so the browser runs a Scheme interpreter written in Scheme. On native Guile, use `(eval expr module)` instead — this evaluator is only needed for Hoot/WASM.

## Key file

`module/xorg/evaluator.scm` (~236 lines)

Core function: `(evaluate expr org local-bindings)` where `org` is typically a logged-revocable proxy.

## Supported forms

| Form | Effect |
|------|--------|
| `#t`, `#f`, numbers, strings | Self-evaluating literals |
| `(quote x)` | Returns `x` unevaluated |
| `(if test then else)` | Conditional |
| `(begin body ...)` | Sequence |
| `(let ...)`, `(let* ...)`, `(letrec ...)` | Bindings |
| `(let name (...) body)` | Named let — loop |
| `(lambda (args) body)` | Closure |
| `(define name value)` | Bind in the org via `($ org 'modify! ...)` |
| `(modify! name value)` | Explicit binding mutation |
| `(rollback! index)` | Restore snapshot from log |
| `(cond ...)`, `(case ...)` | Multi-branch |
| `(and ...)`, `(or ...)` | Short-circuit boolean |
| `(when ...)`, `(unless ...)` | Conditional execution |
| `(do ...)` | Iteration |
| `(f args ...)` | Application |

## Key components

- **`default-base-bindings`** — alist of primitive procedures available in the browser: math, list ops, string ops, type predicates. Split across multiple `append` calls to avoid Hoot quasiquote expansion limits.
- **`make-io-bindings`** — IO as a capability, not ambient. The caller must provide an output port. This is passed into the evaluator, not globally available.
- **`extend-env` / `bind-params`** — environment helpers for local bindings and lambda parameter binding.

## Common editing patterns

**Add a new special form:**
Add a `match` clause to `evaluate`. Order matters — more specific patterns must come before the general application clause at the bottom.

```scheme
;; Example: adding (my-form arg)
(('my-form arg-expr)
 (let ((val (evaluate arg-expr org env)))
   ;; your logic here
   ))
```

**Add a base binding:**
Append to `default-base-bindings`. Keep quasiquote expressions small — split across multiple `append` calls if needed (Hoot limit).

```scheme
(append
  `((my-fn . ,(lambda (x) ...)))
  existing-bindings)
```

**Add IO:**
Extend `make-io-bindings` — this keeps IO as a capability, not ambient authority.

## Gotchas

- **`define` mutates org state.** It calls `($ org 'modify! name value)` — this is a Goblins actor message, not a local binding.
- **No TCO.** Each recursive `evaluate` call adds a Guile stack frame. Deep recursion in user code can blow the stack.
- **Quasiquote size limits.** Hoot's quasiquote expansion has a practical size limit. The codebase splits large binding lists across multiple `append` calls.
- **Used in both browser and server.** The evaluator is loaded by `browser/repl.scm` (Hoot/WASM) and `server/server.scm` (native Guile). Changes affect both.

## Testing

`make test-gplay` runs the evaluator test suite.

## The user's request

$ARGUMENTS
