# Playnet Live Sequence Chart

## Participants

```
Client          Gateway          Interface        Scope            Planner          Observer
(Telegram/      (^lobby          (^channel        (^scope-root     (relational      (^observer
 Browser/        ^presence        ^cmd-dispatch    ^scope-backend)   solver            5-phase
 Terminal)       ^mailbox)        ^output-sink)                      algorithms)       fold)
```

---

## 1. Connection & Authentication

```
Client              Gateway             Signup Agent
  |                    |                     |
  |---[WebSocket]----->|                     |
  |   enliven          |                     |
  |   sturdyref        |                     |
  |<---^lobby ref------|                     |
  |                    |                     |
  |---(signup          |                     |
  |    "alice"         |                     |
  |    "a@b.com"       |                     |
  |    "ssh-ed25519")->|                     |
  |                    |---register!-------->|
  |                    |                     |--guix home
  |                    |                     |  reconfigure
  |                    |                     |  (provision user)
  |                    |<------'ok-----------|
  |<------'ok----------|                     |
```

## 2. Telegram Command Flow

```
Telegram            Telegram          Command          Scope            Observer
User                Adapter           Dispatch         Backend
  |                    |                 |                |                 |
  |--"/inventory       |                 |                |                 |
  |   tomatoes"------->|                 |                |                 |
  |                    |                 |                |                 |
  |              parse-command           |                |                 |
  |              -> ("inventory"         |                |                 |
  |                  "tomatoes")         |                |                 |
  |                    |                 |                |                 |
  |                    |---handle------->|                |                 |
  |                    |   user-id       |                |                 |
  |                    |   "inventory"   |                |                 |
  |                    |   "tomatoes"    |                |                 |
  |                    |                 |                |                 |
  |                    |                 |---query------->|                 |
  |                    |                 |  'inventory-   |                 |
  |                    |                 |   for-spec     |                 |
  |                    |                 |                |---inventory---->|
  |                    |                 |                |   for-spec      |
  |                    |                 |                |   "tomatoes"    |
  |                    |                 |                |                 |
  |                    |                 |                |<--((res-1       |
  |                    |                 |                |     50 kg       |
  |                    |                 |                |     garden))----|
  |                    |                 |                |                 |
  |                    |                 |<---resources---|                 |
  |                    |<---formatted----|                |                 |
  |                    |    text         |                |                 |
  |                    |                 |                |                 |
  |              ^output-sink            |                |                 |
  |              -> send-message         |                |                 |
  |              via key-pool            |                |                 |
  |              (Telegram API)          |                |                 |
  |                    |                 |                |                 |
  |<--"Inventory:      |                 |                |                 |
  |    tomatoes:       |                 |                |                 |
  |    50 kg @ garden" |                 |                |                 |
```

## 3. Recording an Economic Event (Observation)

```
Execution           Scope            Observer              Monitors         Output
Engine              Backend          (5-phase fold)                         Sink
  |                    |                 |                     |              |
  |---execute-with---->|                 |                     |              |
  |   event            |                 |                     |              |
  |   (produce         |                 |                     |              |
  |    "tomatoes"      |                 |                     |              |
  |    50 kg           |                 |                     |              |
  |    agent:farm)     |                 |                     |              |
  |                    |                 |                     |              |
  |                    |---record------->|                     |              |
  |                    |   event         |                     |              |
  |                    |                 |                     |              |
  |                    |          1. phase-append-event        |              |
  |                    |             (prepend to log)          |              |
  |                    |                 |                     |              |
  |                    |          2. phase-index-event         |              |
  |                    |             (by-resource,             |              |
  |                    |              by-process,              |              |
  |                    |              by-agent)                |              |
  |                    |                 |                     |              |
  |                    |          3. phase-apply-effects       |              |
  |                    |             (update resource          |              |
  |                    |              quantity/rights)         |              |
  |                    |                 |                     |              |
  |                    |          4. phase-implied-transfer    |              |
  |                    |             (cross-agent rights       |              |
  |                    |              if applicable)           |              |
  |                    |                 |                     |              |
  |                    |          5. phase-track               |              |
  |                    |             (fulfillment/             |              |
  |                    |              satisfaction             |              |
  |                    |              settlement)              |              |
  |                    |                 |                     |              |
  |                    |                 |---check monitors--->|              |
  |                    |                 |   (buffer status,   |              |
  |                    |                 |    ADU shift,       |              |
  |                    |                 |    threshold)       |              |
  |                    |                 |                     |              |
  |                    |                 |   [if triggered]    |              |
  |                    |                 |                     |              |
  |                    |                 |<--alert!------------|              |
  |                    |                 |   (buffer-yellow    |              |
  |                    |                 |    "tomatoes"       |              |
  |                    |                 |    below-threshold) |              |
  |                    |                 |                     |              |
  |                    |                 |-----^tee-alert-store------------>|
  |                    |                 |     (store + push)               |
  |                    |                 |                                  |
  |                    |<--affected------|                     |            |
  |                    |   resources     |                     |            |
  |                    |                 |                     |            |
  |<--result-----------|                 |                     |     Client |
  |                    |                 |                     |       <----|
  |                    |                 |                     |    "Alert: |
  |                    |                 |                     |  tomatoes  |
  |                    |                 |                     |  buffer    |
  |                    |                 |                     |  yellow"   |
```

## 4. Relational Planning (Demand Resolution)

```
User/               Scope            Planner              Observer         Plan
Command             Backend          (miniKanren           (facts           Store
                                      + CLP(FD))           source)
  |                    |                 |                     |              |
  |---"plan:           |                 |                     |              |
  |  produce 100       |                 |                     |              |
  |  bread loaves"---->|                 |                     |              |
  |                    |                 |                     |              |
  |                    |---create------->|                     |              |
  |                    |   intent        |                     |              |
  |                    |   (produce      |                     |              |
  |                    |    bread 100)   |                     |              |
  |                    |                 |                     |              |
  |                    |            1. Lift VF facts           |              |
  |                    |                 |---query inventory-->|              |
  |                    |                 |   resources, specs  |              |
  |                    |                 |<--facts-------------|              |
  |                    |                 |   (inventory        |              |
  |                    |                 |    "flour" 200 kg)  |              |
  |                    |                 |   (inventory        |              |
  |                    |                 |    "yeast" 5 kg)    |              |
  |                    |                 |                     |              |
  |                    |            2. demand-relation         |              |
  |                    |               (unfold what's needed:  |              |
  |                    |                flour, yeast, labor,   |              |
  |                    |                oven-time)             |              |
  |                    |                 |                     |              |
  |                    |            3. dependent-demand BFS    |              |
  |                    |               (do we have flour?      |              |
  |                    |                need to mill wheat?)   |              |
  |                    |                 |                     |              |
  |                    |            4. CLP(FD) allocation      |              |
  |                    |               (buffer-aware solve:    |              |
  |                    |                assign quantities,     |              |
  |                    |                respect capacity)      |              |
  |                    |                 |                     |              |
  |                    |            5. Generate commitments    |              |
  |                    |                 |                     |              |
  |                    |                 |---store plan--------|------------>|
  |                    |                 |   + commitments     |              |
  |                    |                 |                     |              |
  |                    |<---plan---------|                     |              |
  |                    |    (3 processes:|                     |              |
  |                    |     mill wheat, |                     |              |
  |                    |     mix dough,  |                     |              |
  |                    |     bake bread) |                     |              |
  |                    |                 |                     |              |
  |<---"Plan ready:    |                 |                     |              |
  |  1. Mill 50kg      |                 |                     |              |
  |     wheat->flour   |                 |                     |              |
  |  2. Mix dough      |                 |                     |              |
  |     (flour+yeast)  |                 |                     |              |
  |  3. Bake 100       |                 |                     |              |
  |     loaves"        |                 |                     |              |
```

## 5. Plan Execution & Fulfillment

```
User                Scope            Execution         Observer          Alert
                    Backend          Engine            (5-phase)         Store
  |                    |                 |                 |                |
  |---"execute         |                 |                 |                |
  |    plan-001"------>|                 |                 |                |
  |                    |                 |                 |                |
  |              for each commitment:    |                 |                |
  |                    |                 |                 |                |
  |                    |---execute-with->|                 |                |
  |                    |   capacity:     |                 |                |
  |                    |   (oven-1       |                 |                |
  |                    |    4 hrs)       |                 |                |
  |                    |                 |                 |                |
  |                    |           reserve capacity        |                |
  |                    |           (dynamic-wind           |                |
  |                    |            cleanup)               |                |
  |                    |                 |                 |                |
  |                    |                 |---record------->|                |
  |                    |                 |   (consume      |                |
  |                    |                 |    flour 50kg)  |                |
  |                    |                 |                 |                |
  |                    |                 |---record------->|                |
  |                    |                 |   (produce      |                |
  |                    |                 |    bread 100)   |                |
  |                    |                 |                 |                |
  |                    |                 |          phase-track:            |
  |                    |                 |          commitment             |
  |                    |                 |          fulfilled!             |
  |                    |                 |                 |                |
  |                    |                 |           release capacity      |
  |                    |                 |                 |                |
  |                    |                 |                 |---alert------->|
  |                    |                 |                 |  "commitment   |
  |                    |                 |                 |   fulfilled:   |
  |                    |                 |                 |   bread x100"  |
  |                    |                 |                 |                |
  |                    |<---result-------|                 |                |
  |                    |                 |                 |                |
  |<---"Plan complete: |                 |                 |                |
  |  100 bread loaves  |                 |                 |                |
  |  produced.         |                 |                 |                |
  |  Flour: -50kg      |                 |                 |                |
  |  Oven: released"   |                 |                 |                |
```

## 6. Cross-Cutting: Key Pool & External APIs

```
Any Service         Key Pool          External API
(transcribe,        (^key-pool         (Gemini, OpenRouter,
 express,            round-robin)       Telegram)
 telegram)
  |                    |                    |
  |---request--------->|                    |
  |   "/v1/audio"      |                    |
  |   {audio: b64}     |                    |
  |                    |                    |
  |              select healthy key         |
  |              (round-robin +             |
  |               health check)             |
  |                    |                    |
  |                    |---POST------------>|
  |                    |   Authorization:   |
  |                    |   Bearer <key>     |
  |                    |                    |
  |                    |<---JSON response---|
  |                    |                    |
  |<---result----------|                    |
```

## Actor Topology (Vat Layout)

```
+--[ocapn vat]------------------------------------------+
|  ^websocket-netlayer   ^mycapn   (^reticulum-netlayer) |
+--------------------------------------------------------+
         |  sturdyref
         v
+--[gateway vat]----------------------------------------+
|  ^lobby                                                |
|    +-- ^presence          (online tracking)            |
|    +-- ^mailbox-manager   (offline queue)              |
|    +-- ^transcription-svc (audio->text)                |
|    +-- ^express-svc       (NL->Scheme)                 |
|    +-- ^terminal-svc      (PTY bridge)                 |
+--------------------------------------------------------+
         |  delegates
         v
+--[interface layer]------------------------------------+
|  ^channel         ^command-dispatch                    |
|  ^scope-backend   ^output-sink   ^tee-alert-store     |
|  ^telegram-adapter  (per transport)                    |
+--------------------------------------------------------+
         |  dispatches
         v
+--[scope vat]------------------------------------------+
|  ^scope-root                                           |
|    +-- ^observer        (event fold, 5 phases)         |
|    +-- ^alert-store     (append-only)                  |
|    +-- ^planner         (relational solver)            |
|    +-- ^process-registry                               |
|    +-- ^knowledge-store (miniKanren queries)            |
|    +-- ^live-registry   (infra capacity)               |
+--------------------------------------------------------+
         |
         v
+--[signup vat]---------+  +--[key-pool vat]------------+
|  ^signup-agent        |  |  ^key-pool                  |
|  (provision users)    |  |    +-- ^api-key (per key)   |
+------------------------+  |  (round-robin + health)    |
                            +----------------------------+
```
