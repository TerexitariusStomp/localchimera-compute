Compile the Weave browser WASM bundle.

Run from the project root:
```
make weave/weave.wasm
```

This uses `guild compile-wasm` via `guix time-machine` to compile
`module/weave/browser.scm` (and its UI dependencies) into `weave/weave.wasm`.

Requires the Guix toolchain. Takes ~30–60 seconds on first run.
