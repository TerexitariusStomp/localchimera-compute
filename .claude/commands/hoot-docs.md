---
description: Reference Guile Hoot documentation for WASM compilation, FFI, and browser development
---

You have offline documentation for **Guile Hoot** (Scheme-to-WebAssembly compiler) at `docs/guile-hoot-docs/`. Hoot compiles `browser/repl.scm` into `browser/repl.wasm` — it is the bridge between Guile Scheme and the browser.

## Documentation map

| File                                                    | Contents                                                                   |
| ------------------------------------------------------- | -------------------------------------------------------------------------- |
| `docs/guile-hoot-docs/00-introduction.md`               | Project goals, Hoot's role in Scheme-to-WASM                               |
| `docs/guile-hoot-docs/01-status.md`                     | Supported/unsupported R7RS-small features                                  |
| `docs/guile-hoot-docs/02-installation.md`               | Guix-based and manual installation                                         |
| `docs/guile-hoot-docs/03-tutorial.md`                   | Basic compilation, local testing, browser deployment                       |
| `docs/guile-hoot-docs/04-compiling-to-wasm.md`          | High-level and low-level compilation tools                                 |
| `docs/guile-hoot-docs/05-toolchain-reference.md`        | Complete reference: assembler, linker, WAT parser, WASM library, datatypes |
| `docs/guile-hoot-docs/06-contributing.md`               | Issue reporting and contribution process                                   |
| `docs/guile-hoot-docs/07-license.md`                    | Apache 2.0 license                                                         |
| `docs/guile-hoot-docs/08-foreign-function-interface.md` | `define-foreign`, type signatures, host integration                        |
| `docs/guile-hoot-docs/09-javascript-reflection.md`      | JavaScript `Scheme.load_main` API                                          |
| `docs/guile-hoot-docs/10-guile-reflection.md`           | Guile-side reflection API for inspecting Hoot values                       |

## Which doc for which task

- **Writing new FFI bindings** (`define-foreign`): `08-foreign-function-interface.md`
- **Understanding WASM types / toolchain internals**: `05-toolchain-reference.md`
- **Testing compiled output**: `03-tutorial.md` and `04-compiling-to-wasm.md`
- **JavaScript host setup** (`reflect.js`, `Scheme.load_main`): `09-javascript-reflection.md`
- **What Scheme features are available in Hoot**: `01-status.md`
- **Guile-side inspection of WASM values**: `10-guile-reflection.md`

## FFI type signature reference

`browser/repl.scm` uses `define-foreign` extensively (lines 17–158). The type signatures:

```scheme
(define-foreign name
  "module" "function"
  arg-type1 arg-type2 ... -> return-type)
```

| Hoot type           | Meaning                                       |
| ------------------- | --------------------------------------------- |
| `(ref string)`      | Scheme string                                 |
| `(ref null extern)` | Nullable external reference (DOM nodes, etc.) |
| `(ref extern)`      | Non-null external reference                   |
| `i32`               | Integer (also used for booleans via 0/1)      |
| `f64`               | Float (used for scrollHeight, etc.)           |
| `none`              | Void return                                   |
| `->`                | Separates arguments from return type          |

Example from the codebase:

```scheme
(define-foreign element-value
  "element" "value"
  (ref null extern) -> (ref string))
```

The JS host side (`reflect.js`) registers matching imports under the module/function namespace.

## Build command

```bash
guild compile-wasm -L module -L docs/reference/lib-vendored --bundle -o browser/repl.wasm browser/repl.scm
```

Or via Make:

```bash
make browser/repl.wasm   # compile
make serve               # compile + serve locally
```

## Known Hoot limitations relevant to this project

1. **No `eval`** — Hoot cannot compile Guile's `eval`. The browser uses a metacircular evaluator (`(playnet gplay)` / evaluator.scm) instead.
2. **Missing string procedures** — `string-prefix?`, `string-suffix?`, `string-trim-both` are not available. The codebase defines custom replacements: `%starts-with?`, `%ends-with?`, `%trim`.
3. **Quasiquote size limits** — Large quasiquote expressions hit Hoot's expansion limit. The codebase splits `base-bindings` across multiple `append` calls. Keep individual quasiquote forms reasonably sized.
4. **No full module system** — `browser/repl.scm` is compiled as a single bundle. Imports work via `use-modules` but everything compiles to one WASM file.
5. **No `syntax-case` / `syntax-rules`** — Macro system is limited. Use procedural abstractions instead.
6. **No mutable strings** — `string-set!` is not available.

## Hoot 0.8 live-coding stack

Hoot 0.8 (we ship a patched build via `deploy/packages/hoot-fix.scm`) adds a
real Scheme REPL that runs *inside* the WebAssembly runtime, plus a dev server
that proxies REPL clients into the browser tab. This is **not** the
`(hoot repl)` debug module described in `04-compiling-to-wasm.md` — that one
is for inspecting WASM internals. The new modules are:

| Module                       | Role                                                                       |
| ---------------------------- | -------------------------------------------------------------------------- |
| `(hoot repl)` (0.8)          | Scheme read-eval-print loop running inside the Wasm runtime                |
| `(hoot web-server)`          | Dev HTTP server; doubles as REPL proxy over WebSocket. Routable.            |
| `(hoot web-repl)`            | In-Wasm REPL server — `(run-web-repl "ws://…/repl")`                       |
| `(web request)` `(web response)` `(web socket)` | Slivers of the Guile `(web …)` API, available in Wasm |

Two new optional Hoot deps power this: **guile-fibers** and **guile-websocket**.
If they're missing at build time, `(hoot web-server)` is silently not built.

To enable live hacking, compile with `-g1`:

```bash
guild compile-wasm -g1 -L module --bundle -o browser/repl.wasm browser/repl.scm
```

`-g1` embeds the runtime module system into the binary. The bundle gets
significantly larger and compilation slows down — strip the flag for production.

`current-module-loader` is a new parameter; `run-web-repl` sets it to an
HTTP-based loader that fetches `.scm` source from a special endpoint on the
dev server. **Modules loaded at runtime are interpreted, not compiled to Wasm.**

Hoot 0.8 also ships a top-level `hoot` CLI:

- `hoot repl` — REPL running under Node, no browser involved
- `hoot server` — convenience launcher for `(hoot web-server)`

For an end-to-end walkthrough including how to wire this into Weave's dev
server, see `docs/weave/LIVE_HACKING.md`. The Geiser side is documented in
`/emacs` (look for `geiser-hoot`).

## Common editing patterns

When adding a new FFI binding:

1. Add the `define-foreign` form in `browser/repl.scm` (near the top, lines 17–158)
2. Add the corresponding JS function in `browser/reflect.js` under the matching module namespace
3. Rebuild with `make browser/repl.wasm`

When editing the docs:

- Files are numbered for sequential reading; maintain the numbering convention
- Cross-reference between docs and actual `browser/repl.scm` patterns for accuracy
- Check `01-status.md` when documenting feature availability

## The user's request

$ARGUMENTS
