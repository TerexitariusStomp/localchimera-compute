# OCapN Netlayer for Reticulum

_Architecture for running Goblins actors over Reticulum mesh networks._

---

## Why Reticulum

Reticulum is a cryptography-based networking stack that works over any
transport: TCP, UDP, LoRa radio, serial, I2P, packet radio. It provides:

- **No source addresses** — destinations are cryptographic hashes
- **Encryption by default** — all links use Curve25519 + ephemeral keys
- **Transport-agnostic** — same protocol over internet, radio, serial wire
- **Self-sovereign identity** — portable addresses, no central authority
- **Works at 5 bits/second** — designed for extreme conditions

Combined with Goblins OCapN, this means: **Goblins actors reachable over
LoRa radio, mesh networks, serial links** — not just TCP/internet.

## Architecture

```
┌────────────────────────────────────────────────────┐
│  Goblins Actors (^org, ^logger, proxies, etc.)     │
│  ↕ OCapN CapTP (capability transport protocol)     │
├────────────────────────────────────────────────────┤
│  ^reticulum-netlayer (Guile Scheme)                │
│  Translates OCapN messages ↔ Reticulum Channel     │
├────────────────────────────────────────────────────┤
│  rnsd (Reticulum daemon — Python)                  │
│  Manages interfaces, routing, link establishment   │
├────────────────────────────────────────────────────┤
│  Transport interfaces:                             │
│  TCP | UDP | LoRa | Serial | I2P | Pipe | ...      │
└────────────────────────────────────────────────────┘
```

### Layer 1: rnsd (Reticulum daemon)

The Reticulum daemon runs as a Shepherd service on the Guix server.
It handles all transport interfaces, routing, and link management.

External programs connect to `rnsd` via a shared instance. When a
Reticulum instance is created with `RNS.Reticulum()`, it connects
to the running daemon if one exists, or becomes the daemon if not.

**Guix service definition:**

```scheme
(shepherd-service
 (provision '(rnsd))
 (requirement '(networking))
 (start #~(make-forkexec-constructor
           (list #$(file-append python-reticulum "/bin/rnsd")
                 "-v")
           #:log-file "/var/log/rnsd.log"))
 (stop #~(make-kill-destructor)))
```

**Configuration** (`/etc/reticulum/config`):

```ini
[reticulum]
  enable_transport = True
  share_instance = True
  shared_instance_port = 37428

[interfaces]
  [[Default Interface]]
    type = AutoInterface
    enabled = True

  [[TCP Server]]
    type = TCPServerInterface
    enabled = True
    listen_ip = 0.0.0.0
    listen_port = 4965
```

### Layer 2: Python bridge process

A small Python process acts as the bridge between Goblins (Guile) and
Reticulum (Python). It communicates with the Guile side over a Unix
domain socket using a simple message protocol.

```python
#!/usr/bin/env python3
"""reticulum-bridge.py — Bridge between Goblins OCapN and Reticulum"""

import RNS
import socket
import struct
import threading

class ReticulumBridge:
    def __init__(self, guile_socket_path, app_name="goblins"):
        self.reticulum = RNS.Reticulum()
        self.identity = RNS.Identity()
        self.app_name = app_name
        self.links = {}  # peer_hash -> RNS.Link
        self.guile_sock = self._connect_guile(guile_socket_path)

        # Create destination for incoming links
        self.destination = RNS.Destination(
            self.identity, RNS.Destination.IN, RNS.Destination.SINGLE,
            app_name, "ocapn")
        self.destination.set_link_established_callback(self._on_link)
        self.destination.accepts_links(True)

    def _connect_guile(self, path):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(path)
        return sock

    def _on_link(self, link):
        """Called when a remote peer establishes a link."""
        channel = link.get_channel()
        channel.register_message_type(OCapNMessage)
        channel.add_message_handler(self._on_message)
        peer_hash = link.get_remote_identity().hash.hex()
        self.links[peer_hash] = link
        # Notify Guile of new connection
        self._send_to_guile(('new-connection', peer_hash))

    def _on_message(self, message):
        """Forward Reticulum message to Guile."""
        self._send_to_guile(('message', message.peer_hash, message.data))
        return True

    def connect_to(self, destination_hash):
        """Initiate a link to a remote peer."""
        # Resolve destination from network
        if RNS.Transport.has_path(bytes.fromhex(destination_hash)):
            dest = RNS.Destination.recall(bytes.fromhex(destination_hash))
            link = RNS.Link(dest, established_callback=self._on_link)
            return link
        else:
            RNS.Transport.request_path(bytes.fromhex(destination_hash))
            return None  # path discovery in progress

    def send_message(self, peer_hash, data):
        """Send OCapN message over Reticulum link."""
        link = self.links.get(peer_hash)
        if link and link.status == RNS.Link.ACTIVE:
            channel = link.get_channel()
            msg = OCapNMessage()
            msg.data = data
            msg.peer_hash = peer_hash
            channel.send(msg)

class OCapNMessage(RNS.MessageBase):
    MSGTYPE = 0x0CAP  # OCapN message type
    def __init__(self):
        self.data = b""
        self.peer_hash = ""
    def pack(self):
        return self.data
    def unpack(self, raw):
        self.data = raw
```

### Layer 3: ^reticulum-netlayer (Guile/Goblins)

The Goblins netlayer actor speaks to the Python bridge over a Unix
domain socket. It implements the standard netlayer interface that
`spawn-mycapn` expects.

```scheme
(define-module (goblins ocapn netlayer reticulum)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins actor-lib io)
  #:use-module (goblins ocapn ids)
  #:use-module (ice-9 match)
  #:export (^reticulum-netlayer reticulum-netlayer-env))

(define (^reticulum-netlayer _bcom bridge-socket-path identity-hash)
  "Create a Reticulum netlayer.
   bridge-socket-path: Unix socket to the Python bridge process.
   identity-hash: Our Reticulum destination hash (hex string)."

  (define our-location
    (make-ocapn-peer 'reticulum identity-hash #f))

  ;; IO actor for the bridge socket
  (define bridge-io ...)  ;; ^io wrapping the Unix socket

  (define* (^netlayer bcom #:optional conn-establisher)
    (methods
     [(netlayer-name) 'reticulum]

     [(self-location? loc)
      (same-peer-location? our-location loc)]

     [(our-location) our-location]

     [(setup conn-establisher)
      ;; Start listening for new connections from the bridge
      ;; When bridge sends 'new-connection', create ^message-io
      ;; and call conn-establisher
      (bcom (^netlayer bcom conn-establisher))]

     [(halt)
      ;; Signal bridge to shut down
      ...]

     [(connect-to remote-peer)
      ;; Ask bridge to establish a Reticulum link
      ;; Returns promise that resolves when link is established
      (match remote-peer
        (($ <ocapn-peer> 'reticulum dest-hash _)
         ;; Send connect request to bridge
         ;; Bridge calls RNS.Link(destination)
         ;; On success, creates ^message-io and calls conn-establisher
         ...))]))

  (spawn ^netlayer))
```

### Message flow

```
Goblins actor                     Remote Goblins actor
     |                                    |
     | ($ remote-ref 'modify! 'x 1)      |
     v                                    |
  OCapN CapTP                             |
     | Syrup-encode message               |
     v                                    |
  ^reticulum-netlayer                     |
     | write to bridge socket             |
     v                                    |
  Python bridge                           |
     | OCapNMessage over Channel          |
     v                                    |
  Reticulum Link                   Reticulum Link
     | Curve25519 encrypted        | decrypt
     | routed over LoRa/TCP/...    |
     v                             v
                              Python bridge
                                   |
                              ^reticulum-netlayer
                                   |
                              OCapN CapTP
                                   |
                              Remote actor
```

### Sturdyref format

```
ocapn://reticulum:<destination-hash>/s/<swiss-num>
```

Example:
```
ocapn://reticulum:a7f3b2c1d4e5f6.../s/nGxw4_p6s91IF-R5r6MMYsZzoByODX46MV7AWTApX5s
```

## Guix packaging

### Reticulum

Reticulum is a Python package. Guix definition:

```scheme
(define-public python-reticulum
  (package
    (name "python-reticulum")
    (version "0.8.4")
    (source (origin
              (method url-fetch)
              (uri (pypi-uri "rns" version))
              (sha256 (base32 "..."))))
    (build-system pyproject-build-system)
    (propagated-inputs (list python-cryptography python-netifaces))
    (home-page "https://reticulum.network/")
    (synopsis "Cryptography-based networking stack")
    (description "Reticulum is a networking stack for building
local and wide-area networks using any available transport.")
    (license license:expat)))
```

### Bridge service

```scheme
(shepherd-service
 (provision '(reticulum-bridge))
 (requirement '(rnsd))
 (start #~(make-forkexec-constructor
           (list #$(file-append python-3 "/bin/python3")
                 "/etc/reticulum/bridge.py"
                 "--socket" "/var/run/reticulum-bridge.sock")
           #:log-file "/var/log/reticulum-bridge.log"))
 (stop #~(make-kill-destructor)))
```

## What this enables

With a Reticulum netlayer, Goblins actors become reachable over:

| Transport | Range | Bandwidth | Use case |
|---|---|---|---|
| TCP/UDP | Global (internet) | Unlimited | Standard server-to-server |
| LoRa radio | 1-20km (line of sight) | ~1-50 kbps | Field devices, rural |
| Serial | Direct wire | Variable | Embedded systems |
| I2P | Global (anonymous) | ~100 kbps | Censorship resistance |
| Packet radio | 10-100km | ~1-10 kbps | Emergency, off-grid |
| Pipe | Same machine | Unlimited | Testing, IPC |

The same `($ remote-ref 'modify! 'deploy "cap")` call works regardless
of whether the message travels over fiber optic or LoRa radio. OCapN
abstracts the transport. Reticulum handles the routing.

## Implementation sequence

1. **Package Reticulum for Guix** (python-reticulum, rnsd service)
2. **Write the Python bridge** (reticulum-bridge.py — ~200 lines)
3. **Write the Guile netlayer** (^reticulum-netlayer — ~150 lines)
4. **Wire into Guix services** (rnsd + bridge as Shepherd services)
5. **Test**: two Goblins vats communicating over TCP via Reticulum
6. **Test**: same over LoRa (requires RNode hardware)

## Open questions

- **Message size**: Reticulum MTU is 500 bytes. OCapN messages can be
  larger. Need fragmentation at the bridge level or in ^message-io.
- **Path discovery latency**: Reticulum path resolution can take seconds.
  OCapN's promise pipelining helps here — messages queue until the path
  is established.
- **Persistence**: Reticulum Identity keys need persisting. Can use
  Goblins' persistence env for the netlayer actor, and file storage
  for the Python-side Identity.
- **Announcing**: How do Goblins sturdyrefs map to Reticulum Destination
  announces? The bridge could auto-announce when an object is registered.
