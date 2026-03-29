# Peer Discovery over OCapN

_How browser and mesh peers find each other in the playnet commons._

---

## Overview

Peers do not discover each other directly. All peers connect to a
single **gateway server**, which tracks presence and introduces peers
for direct messaging. This is intentional: the gateway is the trust
root in a capability-security model. You can only reach what you have
been explicitly granted a reference to.

```
Browser A ──WebSocket──┐                    ┌── Browser B
                       ├── Gateway ────────┤
LoRa node ──Reticulum──┘   (^lobby,        └── Browser C
                             ^presence,
                             signaling)
                                 │
                        After signaling:
                     Browser A ←─WebRTC─→ Browser B
                                (direct P2P)
```

## Transports

| Peer type   | Transport                 | Netlayer                      | Data path              |
| ----------- | ------------------------- | ----------------------------- | ---------------------- |
| Browser     | WebSocket (port 9090)     | `^websocket-netlayer`         | Via gateway            |
| Browser P2P | WebRTC DataChannel        | (Phase 2: `^webrtc-netlayer`) | Direct, DTLS-encrypted |
| Mesh device | Reticulum (LoRa/serial/…) | `^reticulum-netlayer`         | Via Python bridge      |

Browser clients bootstrap over **WebSocket**. After discovering each
other through the gateway's `^presence` actor, browsers can upgrade to
**WebRTC DataChannel** connections for direct peer-to-peer messaging
with DTLS encryption. The gateway relays only signaling (SDP
offers/answers, ICE candidates) — application data flows directly
between peers.

Mesh devices connect through the Reticulum netlayer via a Python bridge
process (see `docs/RETICULUM-NETLAYER.md`).

## Bootstrap: the sturdyref

The gateway generates a stable cryptographic identity (designator key)
persisted at `$PLAYNET_DATA_DIR/designator-key.scm`. On startup it
registers a `^lobby` actor with OCapN and publishes the resulting
**sturdyref** — a capability URI that encodes the gateway's identity
and a swiss number for the lobby.

Sturdyref format:

```
ocapn://<designator>.websocket/s/<swiss-num>?url=ws://<host>:<port>
ocapn://reticulum:<dest-hash>/s/<swiss-num>
```

The sturdyref is written to `$PLAYNET_DATA_DIR/gateway-sref.txt` and
logged to stderr so it can be distributed out-of-band (web page, QR
code, URL parameter, etc.).

## Browser connection flow

1. **Obtain the sturdyref.**
   The browser reads the `?gateway=` URL parameter, falling back to a
   default sturdyref compiled into `browser/repl.scm`.

2. **Create an OCapN vat + WebSocket netlayer.**

   ```scheme
   (set! *ocapn-vat* (spawn-vat #:name "ocapn"))
   (define ws-netlayer
     (with-vat *ocapn-vat* (spawn ^websocket-netlayer)))
   (define mycapn
     (with-vat *ocapn-vat* (spawn-mycapn ws-netlayer)))
   ```

3. **Enliven the sturdyref** to get a live `^lobby` reference.

   ```scheme
   (on (<- mycapn 'enliven (string->ocapn-id *gateway-sref*))
       (lambda (lobby-ref)
         (set! *lobby* lobby-ref)
         (set! *connected?* #t)))
   ```

4. **Announce presence** with a display name and inbox actor.

   ```scheme
   (<- *lobby* 'announce *current-org-name* *user-inbox*)
   ```

   The gateway's `^presence` actor stores the mapping
   `display-name -> inbox-ref`, broadcasts the updated user list to
   all connected peers, and returns the current list to the caller.

5. **Introduce peers** for direct messaging.

   ```scheme
   (<- *lobby* 'introduce "other-user")
   ;; => inbox-ref or #f
   ```

   Once a peer has another peer's inbox ref, messages flow directly
   via OCapN — `(<-np inbox-ref 'new-message ...)`.

## WebRTC peer-to-peer upgrade

After connecting to the gateway, browsers can establish direct WebRTC
DataChannel connections. The gateway acts as the **signaling server**
— it relays SDP offers/answers and ICE candidates, but never touches
application data.

### Signaling flow

```
Browser A                    Gateway                    Browser B
    │                          │                            │
    ├─ signal(B, offer, sdp) ──┤                            │
    │                          ├── webrtc-signal(A, offer) ─┤
    │                          │                            │
    │                          ├── webrtc-signal(B, answer)─┤
    ├─ signal(A, answer, sdp)──┤                            │
    │                          │                            │
    ├─ signal(B, ice, cand) ───┤──→                         │
    │                     ←────┤── signal(A, ice, cand) ────┤
    │                          │                            │
    ╞══════════ WebRTC DataChannel (direct, DTLS) ══════════╡
```

### Glare resolution

When both peers try to connect simultaneously, the peer whose display
name is lexicographically greater is always the offerer. If a peer
receives an offer but has already initiated one and is the "greater"
name, it ignores the incoming offer.

### ICE/STUN/TURN

The gateway provides ICE server configuration via `(<- lobby 'ice-servers)`.
Currently uses a public Google STUN server (`stun:stun.l.google.com:19302`).
A self-hosted TURN server (coturn) can be added for symmetric NAT fallback.

### Browser API

```scheme
;; Initiate a WebRTC connection (called after presence discovery)
(establish-webrtc! "other-user")

;; Send data over an open DataChannel
(webrtc-send! "other-user" data)

;; Disconnect
(webrtc-disconnect! "other-user")
```

## Reticulum mesh peers

Mesh peers follow the same logical flow but over Reticulum transport.
The Python bridge handles path discovery:

```python
if RNS.Transport.has_path(dest_hash):
    dest = RNS.Destination.recall(dest_hash)
    link = RNS.Link(dest)
else:
    RNS.Transport.request_path(dest_hash)  # async discovery
```

Once the Reticulum link is established, the bridge proxies OCapN
messages over an encrypted channel. See `docs/RETICULUM-NETLAYER.md`
for the full architecture.

## What is intentionally absent

- **No DHT or broadcast discovery** — peers cannot find each other
  without the gateway introducing them.
- **No service registry** — one gateway per deployment, one sturdyref.
- **No peer-to-peer bootstrap** — the gateway is always the first hop.

This follows the object-capability principle of **no ambient
authority**: a peer must possess a capability (sturdyref) to reach the
gateway, and the gateway must explicitly grant further capabilities
(inbox refs) for peers to communicate. WebRTC upgrades this model by
removing the gateway from the data path once peers have been introduced.

## Key files

| File                                                | Role                                                      |
| --------------------------------------------------- | --------------------------------------------------------- |
| `server/gateway.scm`                                | Gateway server — identity, lobby, sturdyref               |
| `module/playnet/gateway/presence.scm`               | Presence tracking, peer introduction, signaling relay     |
| `module/playnet/gateway/lobby.scm`                  | Lobby actor — service dispatch + `signal` / `ice-servers` |
| `browser/repl.scm` (§ OCapN gateway connection)     | Browser-side connect + announce                           |
| `browser/repl.scm` (§ WebRTC connection management) | WebRTC offer/answer/ICE handling                          |
| `browser/repl.js` (`webRTC` namespace)              | WebRTC FFI bindings for Hoot                              |
| `module/goblins/ocapn/netlayer/reticulum.scm`       | Reticulum netlayer actor                                  |
| `deploy/guix/playnet-gateway-service.scm`           | Shepherd service definition                               |
