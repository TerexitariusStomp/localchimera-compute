Compile the Weave browser WASM bundle.

Run from the project root:
```
make weave/weave.wasm
```

This uses `guild compile-wasm` via `guix time-machine` to compile
`module/weave/browser.scm` (and its UI dependencies under `module/weave/ui/`)
into `weave/weave.wasm`. The `-L docs/reference/lib-vendored` arg pulls in the
WASM-compatible Goblins/fibers sources — the system `guile-goblins` package
can't be linked into a Hoot wasm bundle directly.

Requires the Guix toolchain. Takes ~30–60 seconds on first run.

The DOM FFI bindings shared between `module/weave/browser.scm` and
`module/weave/ui/join.scm` live in `module/weave/ui/ffi.scm` so that Hoot's
library-group linker doesn't reject cross-module top-level references. If
you add a new FFI binding that's needed from a UI module, put it in that
shared module.

## Live-hacking build (Hoot 0.8 REPL)

For an iteration loop where you re-evaluate UI procedures into the running
browser tab without recompiling, use the dev targets:

```bash
make serve-dev    # browser/repl bundle, served on http://127.0.0.1:8080
make weave-dev    # weave UI bundle, served on http://127.0.0.1:8082
```

These build `-g2` bundles into `browser/.dev/` and `weave/.dev/` respectively
(both gitignored), and start `(hoot web-server)` with the REPL relay on
`127.0.0.1:37146`. Connect from Emacs with `M-x connect-to-hoot`
(`emacs-geiser-hoot` package), or from the CLI with `hoot repl --connect`.

Full setup, including the Makefile concatenation trick that wraps
`(hoot web-repl)` around the prod entry point, the SSH-tunnel workflow for
the Hetzner VM, and caveats, is in `docs/weave/LIVE_HACKING.md`.

**Don't deploy `-g2` builds** — the REPL bundle is ~56 MB.
