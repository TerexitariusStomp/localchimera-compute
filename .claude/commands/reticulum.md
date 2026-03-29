---
description: Reticulum mesh networking — OCapN netlayer, Python bridge, LoRa/serial/I2P/TCP transport
---

You are editing the mesh networking layer. Reticulum makes Goblins actors reachable over any transport it supports — TCP, LoRa radio, serial links, I2P, packet radio. The same OCapN sturdyref works regardless of how the message travels. An actor on a LoRa node in a field can hold a capability ref to an actor on the Hetzner server.

## Architecture

```
Goblins actors ←→ OCapN CapTP
       |
^reticulum-netlayer (Guile, extends ^base-port-netlayer)
       |  Unix domain sockets
reticulum-bridge.py (Python, byte shuttle)
       |  Reticulum Channel (Curve25519 encrypted, reliable)
Reticulum Link ←→ any transport
```

## Transport capabilities

| Transport | Range | Use case |
|-----------|-------|----------|
| TCP/UDP | Global | Standard server-to-server |
| LoRa | 1-20km | Field, rural, off-grid sensing |
| Serial | Direct wire | Embedded devices |
| I2P | Global | Anonymous networking |
| Packet radio | 10-100km | Emergency / amateur radio |

## Key files

| File | Purpose |
|------|---------|
| `module/goblins/ocapn/netlayer/reticulum.scm` | Guile netlayer (extends `^base-port-netlayer`) |
| `server/reticulum-bridge.py` | Python bridge daemon — byte shuttle between Unix sockets and Reticulum |
| `deploy/guix/reticulum-service.scm` | Shepherd service definitions for rnsd and bridge |
| `deploy/guix/reticulum-manifest.scm` | Guix manifest for Python RNS dependencies |
| `deploy/guix/python-rns.scm` | Guix package definition for python-rns |
| `docs/RETICULUM-NETLAYER.md` | Full architecture documentation |

## Usage from Guile

```scheme
(use-modules (goblins) (goblins ocapn captp)
             (goblins ocapn netlayer reticulum))
(define vat (spawn-vat))
(with-vat vat
  (define netlayer (spawn ^reticulum-netlayer
                          #:control-path "/tmp/ret-bridge.sock"))
  (define mycapn (spawn-mycapn netlayer))
  (define sref ($ mycapn 'register my-actor 'reticulum))
  ;; => ocapn://...reticulum/s/...
  )
```

## Common editing patterns

**Modify the bridge protocol:** Edit control socket commands in BOTH `reticulum.scm` (Guile) and `reticulum-bridge.py` (Python). They must stay in sync.

**Add a transport:** Configure in `/etc/reticulum/config` (INI format on the server). No code changes needed — Reticulum auto-discovers transports.

**Modify the netlayer:** The Guile side follows Goblins' libp2p netlayer pattern. Read `^base-port-netlayer` in Goblins source for the interface contract.

## Gotchas

- The bridge is Python, not Scheme. It exists because Reticulum's library is Python-only.
- Raw byte shuttle — no length prefix, no framing beyond what Reticulum provides.
- `python-rns` is a custom Guix package (`deploy/guix/python-rns.scm`) built from GitHub source.

## The user's request

$ARGUMENTS
