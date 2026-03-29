---
description: Server relay — WebSocket message routing, signup agent, user provisioning pipeline
---

You are editing the WebSocket relay that routes signed S-expressions between browser clients by public key, queues messages for offline recipients, and handles self-service account registration.

## Key files

| File | Purpose |
|------|---------|
| `server/relay.scm` (170 lines) | WebSocket server, message routing, signup handler |
| `server/signup-agent.scm` (160 lines) | `^signup-agent` Goblins actor, HAMT persistence, input validation |
| `deploy/guix/provision-user.scm` | Enrollment script: appends to users.scm, sends welcome email |
| `deploy/guix/users.scm` | Dynamic user registry (managed by provision-user.scm) |

## Wire protocol

| Message | Direction | Effect |
|---------|-----------|--------|
| `(register-keys (pk1 pk2 ...))` | Client → Relay | Bind public keys to this WebSocket session |
| `(to target-pk payload)` | Client → Relay | Route message to target (or queue if offline) |
| `(from sender-pk payload)` | Relay → Client | Forwarded message from sender |
| `(signup username email ssh-pubkey)` | Client → Relay | Account registration request |
| `(signup-ok)` | Relay → Client | Registration succeeded |
| `(signup-error reason)` | Relay → Client | Registration failed |

## Signup pipeline

```
Browser: (signup! "alice" "alice@example.com")
  → WebSocket sends: (signup "alice" "alice@example.com" "<ed25519-pubkey>")
  → relay.scm matches (signup ...) handler
  → with-vat *signup-vat* ($ *signup-agent* 'register! ...)
  → validates username (^[a-z][a-z0-9-]{0,30}$), email, SSH key format
  → calls: guile -s provision-user.scm --user alice --key "..." --email "..."
  → provision-user.scm appends to users.scm, sends welcome email
  → reply: (signup-ok) or (signup-error "reason")
  → THEN: guix deploy to actually create the Linux account
```

## ^signup-agent methods

| Method | Returns |
|--------|---------|
| `(register! username email ssh-pubkey)` | `'ok` or `(list 'error "reason")` |
| `(members)` | List of `(username email registered-at)` |
| `(member? username)` | `#t` / `#f` |
| `(get-member username)` | Full member record or `#f` |
| `(member-count)` | Integer |

Members are stored in an immutable HAMT hashmap and survive relay restarts via Goblins `#:portrait`/`#:restore`.

## Common editing patterns

**Add a new message type:**
Add a match clause to `process-message` in `relay.scm`:
```scheme
(('my-message (? string? arg))
 (log! "  my-message: ~a\n" arg)
 ;; handle it
 )
```

**Modify validation:**
Edit `valid-username?`, `valid-ssh-key?`, `valid-email?` in `signup-agent.scm`.

## Running

```bash
guile -L module server/relay.scm [port]  # default: 9090
```

The relay uses `guile-websocket` (`(web socket server)`) with a thread-per-client model.

## The user's request

$ARGUMENTS
