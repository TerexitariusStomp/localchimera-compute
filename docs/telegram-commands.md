# Telegram Commands Reference

Everything a Telegram user can do in the playnet system, how the system processes each command, and what comes back.

---

## Scope Commands (ValueFlows Planning)

### `/inventory [spec-id]`

Check what resources exist in the scope, optionally filtered by type.

```
User:   /inventory
System: Queries ^observer 'enriched-inventory
        Returns all resources with onhand quantities.

Response:
  tomatoes: 50 kg
  flour: 200 kg
  bread: 12 loaves
  oven-hours: 8 hrs
```

```
User:   /inventory tomatoes
System: Queries ^observer 'inventory-for-spec "tomatoes"
        Filters to matching resource specification only.

Response:
  tomatoes: 50 kg
```

```
User:   /inventory wheat
System: (no resources match)

Response:
  Inventory is empty.
```

---

### `/resources`

List every economic resource with its ID, name, quantity, and location.

```
User:   /resources
System: Queries ^observer 'all-resources
        Returns full resource records.

Response:
  res-tomato-1: tomatoes 50 kg garden-plot-A
  res-flour-1: flour 200 kg pantry
  res-bread-1: bread 12 loaves kitchen
  res-oven-1: oven-hours 8 hrs bakery
```

```
User:   /resources
System: (nothing recorded yet)

Response:
  No resources recorded.
```

---

### `/events`

Show the 20 most recent economic events (produce, consume, transfer, etc.).

```
User:   /events
System: Queries ^observer 'all-events, takes up to 20.
        Each event shows: ID, action, resource spec, quantity.

Response:
  evt-041: produce spec:bread qty:12
  evt-040: consume spec:flour qty:5
  evt-039: consume spec:yeast qty:0.1
  evt-038: transfer spec:tomatoes qty:20
  evt-037: produce spec:tomatoes qty:30
```

```
User:   /events
System: (no events yet)

Response:
  No events recorded.
```

---

### `/alerts [kind]`

Show execution alerts from monitors. Optionally filter by kind: `buffer-status`, `material-sync`, `adu-shift`.

```
User:   /alerts
System: Queries ^alert-store 'all-alerts
        Formats by alert kind.

Response:
  [2026-04-06T10:30] spec:flour zone:yellow onhand:45
  [2026-04-06T09:15] spec:tomatoes ADU rising 12%
  [2026-04-05T18:00] spec:yeast shortage:0.5
```

```
User:   /alerts buffer-status
System: Queries ^alert-store 'of-kind 'buffer-status
        Only returns buffer zone alerts.

Response:
  [2026-04-06T10:30] spec:flour zone:yellow onhand:45
```

```
User:   /alerts
System: (no alerts)

Response:
  No alerts.
```

---

### `/status`

High-level health overview: total resource count and alert breakdown.

```
User:   /status
System: Counts resources from ^observer, counts and groups alerts by kind.

Response:
  Resources: 4
  Alerts: 3 total (buffer-status: 1, adu-shift: 1, material-sync: 1)
```

```
User:   /status
System: (fresh scope, nothing recorded)

Response:
  Resources: 0
  Alerts: 0 total
```

---

### `/plan <intents|commitments>`

Query the plan store for recorded intents or commitments.

```
User:   /plan intents
System: Queries ^plan-store 'all-intents

Response:
  3 intents recorded.
```

```
User:   /plan commitments
System: Queries ^plan-store 'all-commitments

Response:
  5 commitments recorded.
```

```
User:   /plan
System: (no subcommand given)

Response:
  Usage: /plan <intents|commitments>
```

```
User:   /plan processes
System: (unknown query type)

Response:
  Unknown plan query: processes. Try: intents, commitments
```

---

### `/buffer`

Show DDMRP buffer zone status for each resource spec (green/yellow/red thresholds).

```
User:   /buffer
System: Queries ^buffer-zone-store 'all-zones
        Shows threshold levels per spec.

Response:
  spec:flour: green=200 yellow=100 red=30
  spec:tomatoes: green=80 yellow=40 red=10
  spec:yeast: green=5 yellow=2 red=0.5
```

```
User:   /buffer
System: (no zones configured)

Response:
  No buffer zones configured.
```

---

## Governance Commands (Org)

### `/eval <expression>`

Evaluate a Scheme expression in the org's environment. The org is a metacircular evaluator — its bindings are both program state and governance rules.

```
User:   /eval (+ 1 2)
System: Sends expression to ^org 'evaluate
        Evaluates in the org's binding environment.

Response:
  3
```

```
User:   /eval (lookup 'harvest-quota)
System: Resolves binding from org state.

Response:
  50
```

```
User:   /eval (map car (bindings))
System: Lists all binding names.

Response:
  (harvest-quota daily-ration member-list)
```

```
User:   /eval
System: (no expression given)

Response:
  Usage: /eval <expression>
```

---

### `/define <name> <value-expression>`

Set or update a binding in the org. The value expression is evaluated first, then bound to the name.

```
User:   /define harvest-quota 75
System: Evaluates 75, then calls ^org 'modify! 'harvest-quota 75
        Records who made the change.

Response:
  Defined harvest-quota
```

```
User:   /define daily-bread (* 12 7)
System: Evaluates (* 12 7) = 84, binds to daily-bread.

Response:
  Defined daily-bread
```

```
User:   /define
System: (no arguments)

Response:
  Usage: /define <name> <value-expression>
```

```
User:   /define 42 "oops"
System: (name is not a symbol)

Response:
  Error: 42 is not a valid binding name
```

---

## Meta Commands

### `/help`

List all available commands with brief descriptions.

```
User:   /help
System: Returns hardcoded help text.

Response:
  Available commands:
    /inventory [spec-id]  — Show resource inventory
    /alerts [kind]        — Show execution alerts
    /resources            — List all resources
    /events               — Recent event history
    /status               — Scope health overview
    /eval <expr>          — Evaluate Scheme expression
    /define <name> <expr> — Set a binding
    /plan <query>         — Plan store queries
    /buffer               — Buffer zone status
    /help                 — This message
```

---

### Unknown commands

Any unrecognized `/command` falls through to the error handler.

```
User:   /frobnicate
System: Handler lookup returns #f.

Response:
  Unknown command: frobnicate. Try /help
```

---

## Gateway-Level Actions (via relay, not slash commands)

These happen over the WebSocket relay or OCapN gateway. A Telegram bridge daemon translates between Telegram chat and the relay protocol, so these are available to Telegram users through the bridge rather than direct `/commands`.

### Signup

Register a new account on the system.

```
Flow:   User sends signup details via Telegram bot onboarding
        → Bridge sends (signup "alice" "alice@example.com" "ssh-ed25519 AAAA...")
        → ^signup-agent 'register! validates and provisions via guix home reconfigure
        → Unix user created, SSH key installed
        ← (signup-ok) or (signup-error "username taken")
```

### Voice Transcription

Send a voice message to be transcribed.

```
Flow:   User sends voice note in Telegram
        → Bridge base64-encodes the audio
        → (transcribe "base64-audio-data...")
        → ^key-pool selects healthy Gemini key (round-robin)
        → POST to Gemini Flash /v1/audio endpoint
        ← Transcript text returned to chat
```

### Natural Language → Scheme

Convert a natural language instruction into a Scheme S-expression.

```
Flow:   User types a plain-English message (no / prefix)
        → Bridge sends (express "move 20 kg of tomatoes from garden to kitchen")
        → ^key-pool selects healthy Gemini key
        → Prompt: "Convert to ValueFlows S-expression..."
        ← (transfer 'tomatoes 20 'kg #:from "garden" #:to "kitchen")
        → Returned to user for confirmation/execution
```

### Presence

See who else is online.

```
Flow:   Bridge sends (who)
        → ^presence 'online-users
        ← ((alice bob charlie))
        → Formatted as user list in chat
```

### Peer-to-Peer Messaging

Send a message to another user (queued if they're offline).

```
Flow:   Bridge sends (to "bob-pubkey" '(message "hey, bread's ready"))
        → Relay looks up bob's session
        → If online: forwarded immediately
        → If offline: queued in ^mailbox, delivered on reconnect
```

### Terminal Access

Open a shell session through the chat interface.

```
Flow:   (term-open) → PTY spawned as provisioned Unix user
        (term-data "ls -la\n") → written to PTY stdin
        ← (term-data "total 42\ndrwxr-x...") streamed back
        (term-close) → PTY killed, session cleaned up
```

---

## System-Initiated Messages (Push Notifications)

These are not commands — they're messages the system sends to the user proactively via `^output-sink` → `^telegram-adapter`.

### Buffer Zone Alerts

```
System → User:
  ⚠ Buffer alert: flour entered YELLOW zone
  Onhand: 45 kg | Yellow threshold: 100 kg
  Consider restocking.
```

### ADU Shift Notifications

```
System → User:
  📊 Average Daily Usage shift detected
  tomatoes: ADU rising 12%
  Buffer zones may need recalibration.
```

### Material Sync Warnings

```
System → User:
  🔴 Material shortage: yeast
  Shortage: 0.5 kg below red threshold
  Immediate action needed.
```

### Commitment Fulfillment

```
System → User:
  ✓ Commitment fulfilled: produce bread x100
  Plan plan-001 complete.
  All processes settled.
```

---

## Processing Pipeline Summary

Every Telegram command follows this path:

```
Telegram Chat
  → telegram-bridge daemon (long-poll / webhook)
  → ^telegram-adapter 'parse-command
     strips /, handles @botname suffix
  → ^channel 'handle-input
  → ^scope-backend 'handle
  → ^command-dispatch 'dispatch
     looks up handler in hashmap
  → handler calls ^observer / ^plan-store / ^org / ^alert-store
  → response string returned
  → ^output-sink 'print
  → ^telegram-adapter 'send-message
     POST /sendMessage via ^key-pool (Telegram Bot API)
  → Telegram Chat
```
