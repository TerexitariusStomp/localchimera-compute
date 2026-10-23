# Production deployment runbook

This is the browser-participation topology: Cloudflare Pages serves the
static site; a supervised gateway process terminates OCapN-over-WebSocket;
clients discover the live gateway through a dynamic `/entry-points.json`
rather than a baked Swiss number.

## Topology

```
browser tab ── https://<pages domain>/             static site
            ── https://<pages domain>/entry-points.json   baked seed
            ── https://<gateway>/entry-points.json        live doc (discoveryUrl)
            ── wss://<gateway>/ws                         OCapN channel
```

The OCapN sturdyref **cannot be stable across restarts** — the Swiss number
is process-bound (`mycapn` registers through the nonce registry without a
threaded swiss). Production therefore relies on **dynamic discovery**:

- `browser/entry-points.json` (baked at deploy) names `discoveryUrl`
  pointing at the gateway's live endpoint.
- `server/serve-static.scm` generates `/entry-points.json` per-request from
  the *current* `gateway-sref.txt` — never a stale copy.
- The page follows `discoveryUrl` first, falling back to the baked sref.

## Processes

Canonical production: Guix system via `deploy/os.scm`, Shepherd services:

| service | file | supervision |
|---------|------|-------------|
| `playnet-gateway` | `deploy/guix/playnet-gateway-service.scm` | Shepherd, respawns, `PLAYNET_DATA_DIR=/var/lib/playnet` |
| `playnet-static` | `deploy/guix/playnet-static-service.scm` | Shepherd, `respawn? #t`, binds `127.0.0.1:8080`, serves the dynamic `/entry-points.json` |
| nginx | `deploy/os.scm` | `/ws` → gateway WS, everything else → serve-static |
| `keria` | `deploy/guix/keria-service.scm` | KERIA agent the gateway delegates to |
| `playnet-watchdog` | `deploy/guix/playnet-watchdog-service.scm` | health |

Dev-equivalent (this container): `server/gateway.scm` +
`server/serve-static.scm #:host 0.0.0.0` behind
`tools/dev/ws-mux.mjs` + a `cloudflared` quick tunnel. The mux rewrites
`wss://…/ws` to the gateway listener; prod nginx passes `/ws` through
unchanged — same public contract.

The gateway **deletes `gateway-sref.txt` and `gateway-ret-sref.txt` at
startup** before loading modules — a restarting gateway can never leak its
dead identity through the discovery doc (serve-static returns the
retryable/missing-sref condition until the new one lands).

## Environment

| var | default | meaning |
|-----|---------|---------|
| `PLAYNET_DATA_DIR` | `/var/lib/playnet` | KELs, srefs, registry state — must be a persistent volume |
| `PLAYNET_SEED_DEMO` | unset | seeds the demo commune on boot (dev/e2e only) |
| `KERIA_URL` | `http://127.0.0.1:3901` | KERIA agent endpoint the gateway delegates to |
| `PLAYNET_WS_HOST` / `PLAYNET_WS_PORT` | `0.0.0.0` / `9090` | OCapN listener |
| `PLAYNET_STATIC_HOST` / `_PORT` | `127.0.0.1` / `9091` | discovery + oobi HTTP |
| `PLAYNET_PUBLIC_WS_URL` | — | `wss://` URL baked into the emitted sref |
| `PLAYNET_HTTP_DOOR_PORT` | `9091`-adjacent | door endpoints (`/api/mcp`, `/api/session/`, …) |

## Deploy steps

1. Build artifacts: `make` (builds `browser/day-boot.wasm`)
   (requires the hoot toolchain — see "Artifacts" below). Re-run
   `tools/wasm/patch-reflect-mime.sh` after **any** wasm rebuild — each
   hoot bundle rewrites `reflect.js` back to the nodejs-detect variant.
2. `wrangler pages deploy browser/` (the local gate runs
   trufflehog/trivy/semgrep first).
3. Start the gateway + serve-static under supervision with
   `PLAYNET_DATA_DIR` on a persistent volume.
4. Point the public `wss://<gateway>/ws` at the mux/nginx path that
   forwards to the gateway's WS listener — **no path rewrite**: the
   production nginx stanza (`deploy/os.scm`) passes `/ws` through as-is.
5. Write `browser/entry-points.json` with `discoveryUrl =
   https://<gateway>/entry-points.json` and redeploy.

## Restart behavior

- Gateway restart → new Swiss number → `gateway-sref.txt` rewritten →
  live `/entry-points.json` serves the fresh sref. Baked copies on Pages
  go stale but are never authoritative.
- Verified: gateway bounced mid-suite, the node page re-discovered
  through `discoveryUrl` without redeploying.

## Failure modes

| symptom | cause | recovery |
|---------|-------|----------|
| `err:sign in first` after signup | signup raced the spine connect | wait for `status: connected` (probe-lib does this) |
| discovery 503/empty | gateway booting, sref not yet written | retry — the client backoff handles it |
| `err:refused` on a machine call | session door missing from `(playnet doors protocol)` | `check-declared-heads!` — drift gate |
| `table index out of bounds` at boot | a quoted registry list over ~150 entries (hoot bundle limit) | split the list — see `day-boot.scm` machine* boundary |
| OCapN handshake hang | sref's `wsUrl` doesn't reach a live listener | check `PLAYNET_PUBLIC_WS_URL` + mux wiring |

## Artifacts

| file | status |
|------|--------|
| `browser/day-boot.wasm` | required — built via hoot 0.9.0 + 4 flonum patches + `hoot-src` shims |
| `browser/rns_wasm.js` + `rns_wasm_bg.wasm` | built + shipped — crate is the Radicle satellite `rad:z4PbxPfxbFVEjY3nZp8k61NabfH9C` (pin in `deploy/satellites.scm`), checked out at `rns-wasm/` (gitignored). Canonical build `deploy/scripts/build-rns-wasm.sh` (guix); on a plain rustup box: `cargo build --release --target wasm32-unknown-unknown` then `wasm-bindgen` at the Cargo.lock version (0.2.117 — `cargo install wasm-bindgen-cli --version 0.2.117 --locked`) with `--target web --no-typescript`

## Test matrix

| suite | invocation | expected |
|-------|-----------|----------|
| e2e scenarios (in-vat) | `make test-e2e-scenarios` | lifecycle 24 + disputes 13 + kinds 17 + exit-paths 12 + substrate 21 green |
| coverage gate | `make check-e2e-coverage` | no new gaps |
| machine suites | `make test-machine` (tests/machine/) | 237 green |
| browser legs | `make test-browser` | 15 suites green — executor, store, relay, sense/bundle/policy, sig, substrate |
| real WebRTC lab | serve `browser/` and open `/relay-lab.html` | real RTCPeerConnection pair negotiates over the signal-log shape and crosses 64 KiB — verifies the channel leg on real ICE+SCTP (loopback); NAT traversal between networks stays a documented gap |
| licenses + budget | `make check-licenses check-custom-budget` | allowlisted; ≤ baseline |
| SBOM | `make sbom` | `sbom.json`, CycloneDX 1.5 |

## Secrets

Never commit KERIA passcodes, tunnel tokens, or EOAs. Supply via env or
the secret manager; the wrangler deploy gate and pre-push gitleaks gate
enforce this (see `~/Documents/docker/AGENTS.md`).
