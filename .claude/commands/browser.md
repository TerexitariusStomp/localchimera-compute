---
description: Browser REPL — repl.scm compiled to WASM, FFI bindings, virtual DOM, signup flow
---

You are editing the browser interface. `browser/repl.scm` compiles via Guile Hoot to `browser/repl.wasm` and runs in the browser as a complete Scheme REPL with org management, WebSocket relay communication, and self-service signup.

## Key files

| File | Purpose |
|------|---------|
| `browser/repl.scm` (~1878 lines) | Main source: FFI, virtual DOM, REPL loop, org management, signup, relay |
| `browser/repl.js` | JS host: `Scheme.load_main` imports, key preloading, WebSocket setup |
| `browser/reflect.js` | Hoot JS reflection layer (do not edit unless updating Hoot) |
| `browser/repl.css` | REPL styling |
| `browser/index.html` | Minimal shell loading the above |
| `module/xorg/autocomplete.scm` | Tab completion (Hoot-compatible) |

## Build

```bash
make browser/repl.wasm   # compile only
make serve               # compile + serve at http://localhost:8088
```

Or directly:
```bash
guild compile-wasm -L module -L docs/reference/lib-vendored --bundle -o browser/repl.wasm browser/repl.scm
```

## How changes propagate

```
Edit browser/*.scm → make browser/repl.wasm → git push main → GitHub Pages deploys browser/
```

Live at: `https://interplaynetary.github.io/xorg/`

## FFI bindings

FFI bindings are at the top of `repl.scm` (lines ~17-158). Format:

```scheme
(define-foreign element-value
  "element" "value"
  (ref null extern) -> (ref string))
```

| Hoot type | Meaning |
|-----------|---------|
| `(ref string)` | Scheme string |
| `(ref null extern)` | Nullable external reference (DOM nodes) |
| `(ref extern)` | Non-null external reference |
| `i32` | Integer (booleans via 0/1) |
| `f64` | Float |
| `none` | Void return |

The JS host side (`repl.js`) registers matching imports under the module/function namespace.

## Common editing patterns

**Add a new FFI binding:**
1. Add `define-foreign` at the top of `browser/repl.scm`
2. Add matching JS function in `browser/repl.js` under the same module namespace
3. Rebuild with `make browser/repl.wasm`

**Add a REPL command:**
Add a match clause in the command processing section of `repl.scm` (search for existing commands like `signup!`, `export-ssh-key`).

**The signup flow:**
`(signup! "user" "email")` → WebSocket → relay → `^signup-agent` → `provision-user.scm` → `users.scm` → requires `guix deploy` to activate the account.

## Hoot limitations

- **No `eval`** — use the metacircular evaluator (see `/evaluator` skill)
- **Missing string procedures** — `%starts-with?`, `%ends-with?`, `%trim` are custom replacements
- **Quasiquote size limits** — split large forms across multiple `append` calls
- **No `syntax-case`/`syntax-rules`** — use procedural abstractions
- **No mutable strings** — `string-set!` unavailable
- **Single bundle** — everything compiles to one WASM file

See `/hoot-docs` skill for full Hoot reference.

## The user's request

$ARGUMENTS
