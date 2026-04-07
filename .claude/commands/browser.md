---
description: Browser REPL — SXML virtual DOM, wisp/lisp toggle, FFI bindings, org management, signup flow
---

You are editing the browser interface. `browser/repl.scm` compiles via Guile Hoot to `browser/repl.wasm` and runs in the browser as a complete Scheme REPL with org management, WebSocket relay communication, and self-service signup.

## Key files

| File                              | Purpose                                                                      |
| --------------------------------- | ---------------------------------------------------------------------------- |
| `browser/repl.scm` (~2060 lines)  | Main source: FFI, SXML virtual DOM, REPL loop, org management, signup, relay |
| `browser/repl.js`                 | JS host: `Scheme.load_main` imports, key preloading, WebSocket setup         |
| `browser/reflect.js`              | Hoot JS reflection layer (do not edit unless updating Hoot)                  |
| `browser/repl.css`                | REPL styling (flex layout, dark theme)                                       |
| `browser/index.html`              | Minimal shell loading the above                                              |
| `module/playnet/autocomplete.scm` | Tab completion (Hoot-compatible)                                             |
| `module/playnet/wisp.scm`         | Wisp/S-expression transpiler (SRFI-119 indentation syntax)                   |

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

Live at: `https://interplaynetary.github.io/playnet/`

## SXML — the UI is S-expressions

The entire UI is built from SXML (S-expression HTML). Every DOM element is a list:

```scheme
"hello"                              ;; → text node
(div "hello")                        ;; → <div>hello</div>
(div (@ (class "red")) "hello")      ;; → <div class="red">hello</div>
(span (@ (click ,handler)) "go")     ;; → clickable span with Scheme lambda
(input (@ (id "x") (type "text")))   ;; → text input
```

Event handlers are Scheme procedures attached as attributes:

```scheme
(click ,(lambda (e) ...))            ;; click handler
(keydown ,(lambda (e) ...))          ;; key handler
(input ,(lambda (e) ...))            ;; input change handler
```

Conditional children use `,@` with `if`:

```scheme
,@(if show? (list `(span "visible")) '())
```

Dynamic lists use `,@` with `map`:

```scheme
,@(map (lambda (item) `(li ,item)) items)
```

Custom interactive elements can be appended to the REPL log:

```scheme
(log-append! `(div (input (@ (id "my-input")))
                   (span (@ (click ,(lambda (e)
                                      (let ((val (element-value (get-element-by-id "my-input"))))
                                        (eval! val) (refresh!)))))
                         "submit")))
```

### VDOM architecture

- `sxml->dom` converts any SXML tree to real DOM elements
- `virtual-dom-render` diffs old and new SXML trees by **position** (not key)
- `(refresh!)` re-renders the full VDOM from current state
- **Critical constraint**: variable-length lists (like log entries) must NOT be followed by fixed siblings in the same parent — separate them into sibling containers

### DOM structure

```
div.repl (flex column)
├── div#repl-log.log (flex: 1, scrollable — contains only log spans)
└── div.prompt (flex-shrink: 0, fixed at bottom — always visible)
    ├── prompt text
    ├── textarea#expression
    ├── ghost-text (conditional autocomplete)
    └── paren-indicator
```

The log and prompt are **siblings**, not nested. This ensures the VDOM differ never confuses growing log entries with the prompt elements.

## UI helpers

**Toggle forms** — `render-toggle-form` handles collapsible input forms (used by new-org, signup, join-org):

```scheme
(render-toggle-form *show?* set-show! "label" "submit"
  '(("input-id" "placeholder"))
  (lambda (vals) (do-action! (car vals))))
```

**Action buttons** — `action-button` wraps the click→action→refresh→scroll pattern:

```scheme
(action-button "label" (lambda () (do-something!)) "")         ;; plain
(action-button "label" (lambda () (do-something!)) " cp-btn-primary")  ;; highlighted
```

**Eval buttons** — `eval-button` for syntax-mode-aware command buttons:

```scheme
(eval-button "history" "(show-history)" "show-history")  ;; lisp/wisp commands
```

## Wisp syntax toggle

`module/playnet/wisp.scm` provides bidirectional wisp/S-expression transpilation:

- `wisp->sexp-string` — indentation-based input → parenthetical S-expressions
- `sexp->wisp-string` — parenthetical code → stripped outer parens for display
- `*syntax-mode*` state variable (`'lisp` or `'wisp`) persisted in localStorage
- Toggle button appears in both outer and inner mode action bars
- In wisp mode: `modify! 'x 5` instead of `(modify! 'x 5)`

## FFI bindings

FFI bindings are at the top of `repl.scm` (lines ~17-158). Format:

```scheme
(define-foreign element-value
  "element" "value"
  (ref null extern) -> (ref string))
```

| Hoot type           | Meaning                                 |
| ------------------- | --------------------------------------- |
| `(ref string)`      | Scheme string                           |
| `(ref null extern)` | Nullable external reference (DOM nodes) |
| `(ref extern)`      | Non-null external reference             |
| `i32`               | Integer (booleans via 0/1)              |
| `f64`               | Float                                   |
| `none`              | Void return                             |

The JS host side (`repl.js`) registers matching imports under the module/function namespace.

## Common editing patterns

**Add a new FFI binding:**

1. Add `define-foreign` at the top of `browser/repl.scm`
2. Add matching JS function in `browser/repl.js` under the same module namespace
3. Rebuild with `make browser/repl.wasm`

**Add a REPL command:**
Add a match clause in `handle-command` in `repl.scm` (search for existing commands like `signup!`, `export-ssh-key`).

**Add an action bar button:**
Use the `action-button` or `eval-button` helpers in `render-action-bar`.

**Add a toggle form:**
Use `render-toggle-form` — see `render-new-org-button` for the pattern.

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

## Live hacking the UI (developer REPL)

Hoot 0.8 ships an in-Wasm Scheme REPL: edit a render procedure in your editor,
re-evaluate it, call `(refresh!)`, and the browser tab redraws without a page
reload or `make`. Vat state, WebSocket connections and actor identity all
survive across edits.

Quick recipe:

1. Compile with `-g1` so the runtime module system is embedded:
   ```bash
   guild compile-wasm -g1 -L module -L docs/reference/lib-vendored \
     --bundle -o browser/repl.wasm browser/repl.scm
   ```
2. Serve via `(hoot web-server)` (already what `make serve` does) — it doubles
   as a REPL proxy, forwarding TCP traffic from clients over a WebSocket to
   the connected tab.
3. From the entry-point Scheme, start the in-Wasm REPL server:
   ```scheme
   (use-modules (hoot web-repl))
   (run-web-repl "ws://localhost:8088/repl")
   ```
4. Connect with `M-x geiser-hoot` (see `/emacs` skill) or `hoot repl`.
5. Eval a UI module, then `(refresh!)` in the REPL.

Caveats: `-g1` bloats the bundle (don't deploy it), runtime-loaded modules are
**interpreted not compiled** so hot loops are slower, and new `define-foreign`
bindings still require a full rebuild because FFI imports are linked at
compile time.

Full walkthrough including the Weave bundle: `docs/weave/LIVE_HACKING.md`.

## The user's request

$ARGUMENTS
