# Live Hacking the UI in the Browser

How to drive the Weave / REPL WASM bundles from a live Scheme REPL — edit a UI
procedure in your editor, evaluate it, and watch the running browser tab
re-render without a recompile or page reload.

This relies on the live-coding pieces that landed in **Hoot 0.8.0**:

| Module                | Side                 | Purpose                                                                                                                                                                                                                                                                                          |
| --------------------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `(hoot web-server)`   | host (regular Guile) | Static-file dev server **plus** REPL relay. Listens on TCP for REPL clients (Geiser, telnet, `hoot repl --connect`), forwards them over a single WebSocket to the connected browser tab.                                                                                                         |
| `(hoot web-repl)`     | guest (in-WASM)      | Library compiled into the wasm binary. `run-web-repl` dials the dev server's `/repl` WebSocket, spawns a `(make-repl)` per connected client, multiplexes over the channel. Sets `current-module-loader` so runtime `use-modules` calls fetch source via `/repl/load/<modname>` and interpret it. |
| `(hoot repl)`         | host                 | Convenience commands for inspecting/dumping wasm modules from a normal Guile REPL. **Not** the in-wasm REPL — easy to confuse.                                                                                                                                                                   |
| `geiser-hoot` (Emacs) | host                 | Geiser flavour for Hoot. Provides `M-x connect-to-hoot` (TCP connect to a running relay) and `M-x run-hoot` (NodeJS-hosted REPL, no browser).                                                                                                                                                    |

## Status in this repo

We pin a patched Hoot 0.8.0 (`HOOT_FIXED` in `Makefile`,
`deploy/packages/hoot-fix.scm`), so all of the above are **available**.
The patch only fixes the `mutable-bytevector?` regression in
`hoot/backend.scm` — it doesn't touch the REPL stack.

Two live-hacking targets are wired up:

1. **`make serve-dev`** — builds `browser/.dev/repl.wasm` (the in-page Guile
   playground) with `-g2` and serves it via `(hoot web-server) serve` from
   `browser/.dev/` on the upstream defaults: HTTP `127.0.0.1:8080`, REPL
   relay `127.0.0.1:37146`.
2. **`make weave-dev`** — builds `weave/.dev/weave.wasm` (the Weave meeting
   UI) with `-g2` and runs `server/weave-dev.scm`. That binary uses `(hoot
web-server) serve` with a custom router (shared with prod via `(weave
routes)`), serving `weave/.dev/` on `127.0.0.1:8082` and the REPL relay
   on `127.0.0.1:37146`.

   The DOM FFI bindings the UI modules need (`prevent-default!`,
   `get-element-by-id`, `element-value`, `set-element-value!`) live in
   `module/weave/ui/ffi.scm` so that both `module/weave/browser.scm` and
   `module/weave/ui/join.scm` can import them — without that module Hoot
   0.8.0's library-group linker rejects the cross-module top-level
   reference.

The optional Hoot deps `guile-fibers` and `guile-websocket` must be in the
shell at build/run time, otherwise `(hoot web-server)` is not built. They
are pulled in transitively by `guile-hoot` itself, so `make weave-dev` /
`make serve-dev` work with no extra arguments.

## Build with the right debug flag

Live hacking requires the runtime module system to be embedded in the wasm
binary, **and** mutable definitions if you want to redefine bindings (you
do — that's the whole point):

| Flag  | Effect                      | When to use                                |
| ----- | --------------------------- | ------------------------------------------ |
| `-g0` | none                        | production                                 |
| `-g1` | `names` + `runtime-modules` | live REPL, but bindings cannot be replaced |
| `-g2` | adds `mutable-defs`         | live REPL **with** redefinition            |

Both `make serve-dev` and `make weave-dev` already use `-g2`. Don't ship
`-g2` builds — they're several times larger and dial localhost on startup.

Dev artifacts live in `browser/.dev/` and `weave/.dev/` (both gitignored)
so the dev wasm never overwrites the prod `browser/repl.wasm` /
`weave/weave.wasm` that GitHub Pages serves. Each dev directory holds
symlinks to non-wasm assets (HTML/JS/CSS) plus the `-g2` wasm and the
Makefile-generated concatenation source `*-live.scm`.

### How the concatenation works

The dev wrapper files (`browser/repl-dev.scm`,
`module/weave/browser-dev.scm`) are **tail fragments** — they only contain
a `(run-web-repl)` call (and an optional `parameterize` of
`current-repl-server`). The Makefile produces the actual compilation input
by:

1. Cloning the prod entry point and injecting `(hoot web-repl)` into its
   top-level `(use-modules ...)` form via `sed`. Hoot's library-group
   compiler requires `use-modules` to be the **first and only** top-level
   imports form, so we can't just prepend a second one.
2. Appending the dev tail.

The result starts the prod entry point's full init flow (FFI bindings,
`(refresh!)`, `register-callbacks!`, OCapN bootstrap, …), then hands
control to `run-web-repl` which dials the dev server's WebSocket.

We can't `(include "...")` the prod source from a separate wrapper because
Hoot's library-group compiler forbids top-level `include` clauses.

## Connecting from your editor

### Local laptop workflow (option A)

```bash
make serve-dev          # builds browser/.dev/repl.wasm and starts the relay
```

Then in Emacs (with `geiser-hoot` installed via MELPA or
`guix install emacs-geiser-hoot`):

```
M-x connect-to-hoot
host: 127.0.0.1
port: 37146
```

Open a browser tab to `http://127.0.0.1:8080/` (the dev server prints the
URL on startup). The wasm boots, runs the REPL bundle's init, then
`run-web-repl` dials the relay. Your `M-x connect-to-hoot` REPL is now
talking to that browser tab.

The iteration cycle:

1. Edit a Scheme module under `module/`.
2. From Emacs: `C-c C-k` (or `C-x C-e` for a single form) — geiser sends
   the change over the relay.
3. Trigger a re-render. Both bundles expose `(refresh!)`; calling it from
   the REPL re-runs the SXML render with the new procedure definitions:
   ```scheme
   (refresh!)
   ```
4. The DOM updates. No page reload, no wasm recompile. Actor state, vat
   identity, WebSocket connections, in-flight promises — all preserved.

For SXML diffs to behave, remember the constraint from
`.claude/commands/browser.md`: **variable-length lists must not share a
parent with fixed siblings**. The VDOM differ matches by position, not key.

### Remote VM workflow (option B)

The Hetzner VM (`machines.scm` → `playnet@…`) has the live-hacking
toolchain installed via Guix and a manual-start `weave-dev` shepherd
service defined in `deploy/guix/weave-dev-service.scm`.

```bash
# From your laptop — open the tunnels and start the dev service.
ssh -L 8082:127.0.0.1:8082 \
    -L 37146:127.0.0.1:37146 \
    playnet@playnet.host \
  'sudo herd start weave-dev'

# In Emacs (still local):
M-x connect-to-hoot RET 127.0.0.1 RET 37146 RET

# In your browser (still local):
http://127.0.0.1:8082/weave.html
```

The wasm in the browser tab is being served by the VM through the tunnel,
runs in your local browser, and dials back to the VM's relay (also through
the tunnel) which forwards into your local Emacs over the loopback port.

Stop the dev session with:

```bash
ssh playnet@playnet.host 'sudo herd stop weave-dev'
```

`weave-dev` is `auto-start? #f` — it never runs unattended. The prod
`weave-service` (port 8081) is a separate vat and stays untouched.

### `hoot repl --connect` CLI alternative

If you don't want Emacs in the loop, the `hoot` CLI binary (from the
`guile-hoot` package) talks to the same relay:

```bash
hoot repl --connect    # connects to localhost:37146 by default
```

Useful for sanity-checking expressions without booting Geiser.

## Auto-reload on save

The manual `C-c C-k` + `(refresh!)` dance from the previous section is
fine, but we also ship two ways to do it for you whenever a file is
saved. They're additive — pick whichever fits your editor.

### Option A — Emacs save hook

`deploy/scripts/init.el` (the elisp file deployed to the playnet user
on the Hetzner VM, also fine to drop into a local `~/.emacs.d/init.el`)
defines `playnet/live-reload-on-save` and adds it to `after-save-hook`.
On every save of a Scheme buffer under a configured root (default
`module/`), it:

1. Tries to use the active Geiser-Hoot REPL — if you're connected via
   `M-x connect-to-hoot`, it sends `geiser-eval-buffer` and then
   `(catch #t (lambda () (refresh!)) (lambda _ #f))` to your REPL.
   This is the fast path: a single round trip, no subprocess.
2. If no Geiser connection is up, falls back to spawning
   `tools/live-reload.scm` (the same script the inotify watcher uses).
   So `C-x C-s` always does *something* useful, even if you're editing
   without an attached REPL.

The hook is gated on `playnet-live-reload-enabled` (default `t`) and
`playnet-live-reload-roots` (default `("module/")`). To extend coverage
to other subtrees, set the variable in your local init:

```elisp
(setq playnet-live-reload-roots '("module/" "server/"))
```

### Option B — inotify watcher (any editor)

For Vim, VS Code, Helix, or any other editor — or for editing files via
SSHFS on the VM — there's `tools/live-watch.sh`, an `inotifywait` loop
that does the same job from outside the editor. It calls
`tools/live-reload.scm` on every `close_write` event, which is the
event every editor I know of fires after an atomic save.

Locally, run it via the `make` target so you don't have to install
`inotify-tools`:

```bash
# Terminal 1 — dev server + REPL relay
make weave-dev    # or `make serve-dev` for the browser/repl bundle

# Terminal 2 — auto-reload
make live-watch
```

That command wraps the script in `guix shell inotify-tools coreutils bash`
and watches `module/` by default. Override with `ARGS=`:

```bash
make live-watch ARGS="server module/playnet"
```

On the Hetzner VM the same loop runs as a manual-start shepherd
service:

```bash
sudo herd start weave-dev      # (already documented above)
sudo herd start live-watch     # inotify loop, watches /home/playnet/dev-checkout/module
…
sudo herd stop  live-watch
sudo herd stop  weave-dev
```

See `deploy/guix/live-watch-service.scm` for the full configuration
(host, port, watch paths are all overridable in `machines.scm`).

### How `tools/live-reload.scm` works

The script is intentionally generic — it doesn't know about Weave or
the playnet REPL specifically. Given a saved file path it:

1. **Computes the module name from the path.** A small route table
   maps repo-relative path prefixes to module-name roots: by default,
   `module/X/Y.scm` → `(X Y)`. Add a row to `%routes` in
   `tools/live-reload.scm` to support a new subtree.
2. **Reads the file body and strips the `(define-module …)` form**,
   replacing it with whitespace of equal length so error line numbers
   stay accurate. (The REPL parser would otherwise try to *re-define*
   the module, which Hoot's library-group machinery rejects for an
   already-loaded module.)
3. **Connects to the REPL relay** at `127.0.0.1:37146` (overridable
   via `PLAYNET_REPL_HOST` / `PLAYNET_REPL_PORT`).
4. **Sends `,m (the modname)`** so subsequent `(define …)` forms are
   evaluated in that module's namespace. With `-g2` (`mutable-defs`)
   they replace the existing bindings, just like the manual
   `geiser-eval-buffer` flow.
5. **Sends the file body** as one chunk.
6. **Switches back to `(guile-user)` and calls `(refresh!)`** wrapped
   in a `catch` so a missing `refresh!` (the entry point hasn't booted
   yet, you connected too early) doesn't surface as an error.
7. **Closes the connection.** Each save is one short-lived REPL
   session; multiple concurrent live-watchers are fine because the
   relay multiplexes them.

If the relay greets the connection with `No control WebSocket`, that
just means no browser tab is attached yet — the script logs a friendly
warning and exits 0 so the editor save doesn't see an error.

## Caveats and gotchas

- **Interpreted, not compiled.** Modules loaded at runtime via the HTTP
  loader run in the Hoot interpreter. Hot loops will be slower than the
  compiled wasm path. Don't benchmark inside a live REPL.
- **No `eval` in the language layer.** Hoot still can't compile Guile's
  `eval`. The metacircular evaluator in `module/playnet/gplay.scm` is
  unaffected and is what end-users see in the in-page REPL — the live REPL
  described here is a **developer** tool that runs in parallel.
- **Macros.** The runtime expander in `(hoot web-repl)` uses Hoot's
  R7RS-ish macros. It's more capable than the AOT path but still limited;
  prefer procedural abstractions when you can.
- **`define-foreign` is build-time.** New FFI bindings still require a
  full rebuild — they get linked into the wasm import section and can't
  be added from the live REPL.
- **State you mutate from the REPL persists.** That's the whole point,
  but it also means a half-finished experiment can leave the tab in a
  weird state. `(refresh!)` from a clean module re-import usually fixes
  it.
- **Bundle size with `-g2`.** ~56 MB for the browser/repl bundle and ~44
  MB for the weave bundle as of 2026-04. Don't deploy.

## Upstream references

- Hoot 0.8.0 release notes (Spritely blog).
- `(hoot repl)`, `(hoot web-server)`, `(hoot web-repl)`, `(web request)`,
  `(web response)`, `(web socket)` modules in the upstream Hoot tree
  (`/gnu/store/…-guile-hoot-0.8.0/{module,lib}/hoot/`).
- `hoot-slides` repo — example of extending `(hoot web-server)` with a
  user-supplied request router.
- `geiser-hoot` — Emacs Geiser flavour for the Hoot REPL,
  `https://codeberg.org/spritely/geiser-hoot`.
