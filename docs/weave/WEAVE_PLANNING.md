# WEAVE_PLANNING.md
# Weave Architecture, Technology Stack, and Data Models

---

## 1. Technology Stack — Final Decisions

### Video infrastructure: LiveKit (self-hosted)

**Decision:** LiveKit, deployed on the existing Hetzner server.

**Rationale over Daily.co:**
- Programmatic room creation and participant management via REST/WebSocket API — required for breakout dispatch
- Self-hosted = no per-minute billing at demo/early-customer scale; runs alongside existing Guix services
- LiveKit's server SDK supports audio track injection into rooms — the mechanism needed for broadcast
- OSS (Apache 2): we can fork/patch if an edge case bites us during build
- Daily.co's breakout rooms are higher-level but opaque; LiveKit gives us the primitives to build exactly what we need

**Broadcast feasibility (critical to confirm in Sprint 3):**
LiveKit allows a server process to create an "egress participant" that publishes audio into a room. The broadcast pattern is:
1. Host publishes audio to a special `plenary` room as normal
2. Server subscribes to that track via LiveKit's server-side API
3. Server republishes the decoded audio into each active breakout room as a synthetic participant track
This requires LiveKit ≥ v1.7 (has `PublishData` and server-side track publish). Confirm API exists before committing.

### Backend language: Guile Scheme + Spritely Goblins

All server-side logic is native PlayNet. Meeting state machines, participant records, transcript stores, synthesis triggers, and script engines are all Goblins actors.

The Weave backend exposes:
- An HTTP API (via Guile's `(web server)`) for REST endpoints
- A WebSocket relay (extending the existing relay architecture) for real-time events

### Frontend: Guile Hoot / WASM + SXML virtual DOM

The browser client is Guile Scheme compiled to WebAssembly via Guile Hoot — the same pattern used throughout PlayNet. There is no JavaScript framework; the UI is pure Scheme.

**Architecture:**
- Scheme source lives in `module/weave/ui/` and compiles to a `.wasm` bundle served as a static file
- A thin JS host file (`weave.js`) provides `user_imports` — FFI bindings that expose browser APIs (DOM, WebRTC, WebSocket, crypto) to Scheme via `define-foreign`
- UI components are pure functions returning SXML trees, consumed by the virtual-DOM renderer (same pattern as `(playnet ui components)`)
- LiveKit's JavaScript client SDK is loaded in the page; Scheme calls it through FFI bindings defined in `weave.js`
- State is managed by Goblins actors running inside the WASM vat (same vat pattern as `browser/repl.scm`)

**LiveKit FFI strategy:**
The LiveKit JS SDK (`@livekit/client`) is bundled alongside the WASM. Scheme calls into it via `define-foreign` wrappers: `livekit-connect`, `livekit-publish-track`, `livekit-subscribe-track`, `livekit-disconnect`. Callbacks from LiveKit events (participant joined, track published, etc.) are registered from JS and call back into Scheme via exported WASM functions, following the same pattern as the existing crypto and WebSocket FFI bindings.

**Talks to the backend via:**
- REST/HTTP for meeting CRUD, auth, artifact generation (via Hoot's `fetch` FFI binding)
- WebSocket for real-time events (phase transitions, prompt delivery, transcript segments, participant join/leave) — same relay pattern as existing PlayNet WebSocket usage

### Transcription: Deepgram

Deepgram Nova-2 model via their real-time WebSocket streaming API.

**Rationale over AssemblyAI:**
- Lower end-to-end latency (~200ms vs ~400ms) — matters for live meeting display
- Simpler streaming protocol
- Per-minute pricing comparable; self-managed streaming gives us more control

Audio flow: LiveKit server-side track subscription → PCM audio stream → Deepgram WebSocket → tagged transcript segments → `^transcript-store`

### Voice cloning: ElevenLabs

ElevenLabs Professional Voice Clone API. Pre-generate all prompt audio at meeting-save time. Never synthesize live (avoids latency and quality variance during meetings).

### Synthesis: Claude API (claude-opus-4-6 or claude-sonnet-4-6)

Post-meeting synthesis over all transcript segments. Structured output via Claude's tool-use / JSON mode. Minority views require explicit protection in the prompt design.

### Auth: JWT

Room-scoped JWTs. The same user can convene one meeting and participate in another — role is a claim on the token, not on the account. Tokens expire after 24h or when the meeting ends.

---

## 2. Meeting DSL Design

### Philosophy: scripts are PlayNet recipes, authored in Wisp

Meeting scripts are **PlayNet recipes** — they specify what roles are required, what process must run, and what artifact must be produced. They are first-class data in the system of record, not configuration files.

Scripts are authored in **Wisp** — a whitespace-significant dialect of Scheme that removes most parentheses. Wisp uses indentation to express structure, making it readable by non-programmers while remaining fully programmable: you can define reusable components, compose them, and build entire curricula from shared building blocks.

The Weave script evaluator runs Wisp source inside a restricted, capability-governed environment. `define-phase`, `define-meeting`, and `define-program` are macros that validate their arguments and produce PlayNet-native records. There is no arbitrary code execution — only the vocabulary the DSL exposes.

---

### Level 1: A single phase (reusable building block)

A phase is a named, timed, typed unit of facilitation. Define it once; use it in any meeting.

```wisp
define-phase opening-checkin
  type    plenary
  minutes 5
  prompt  "Welcome everyone. One word for how you're arriving today?"

define-phase small-group-diverge
  type    breakout
  minutes 20
  rooms   3
  prompt  "In your group: what is the single biggest obstacle to our goal?"

define-phase full-group-reconvene
  type    plenary
  minutes 10
  prompt  "Each group shares their obstacle. We listen for patterns."
```

Rules for phases:
- `type` is one of: `plenary`, `breakout`, `debrief`, `focus`, `checkin`
- `minutes` must be a positive integer
- `rooms` is only valid on `breakout` phases; defaults to 3 if omitted
- `prompt` is the human-readable instruction shown on screen and optionally delivered by voice

---

### Level 2: A meeting recipe

A meeting is a named sequence of phases with role requirements and an output contract. It is the PlayNet recipe for one labor session.

```wisp
define-meeting strategic-alignment
  title       "Strategic Alignment Session"
  description "Surface obstacles and commit to actions as a full team."
  minutes     90
  roles
    convener     1
    participants 4 to 12
    observer     optional
  delivery    generic-tts

  phases
    opening-checkin
    small-group-diverge
    full-group-reconvene
    breakout "Solve" 20 :rooms 3
      "Design one concrete action your group will take this week."
    plenary "Commit" 15
      "Each group proposes their action. Together we select three and assign owners."

  outputs
    synthesis-document  required
    commitment-map      required
    executive-summary   optional

  assertions
    min-participants 4
    required-role    convener
```

Inline phases (like `breakout "Solve" 20`) are syntactic sugar — they expand identically to a `define-phase` block. Named phase refs (like `opening-checkin`) are looked up in the current scope.

---

### Level 3: A program (multi-meeting curriculum)

A program sequences multiple meeting recipes into a coherent arc of labor, spread across time. This is the unit you use for onboarding courses, change management initiatives, or any work that spans multiple sessions.

```wisp
define-program new-manager-foundations
  title       "New Manager Foundations"
  description "A four-session arc for managers in their first 90 days."

  sessions
    session "Role Clarity"
      meeting  role-clarity-meeting
      after    0 days

    session "Team Norms"
      meeting  team-norms-meeting
      after    7 days
      requires "Role Clarity"

    session "1-on-1 Practice"
      meeting  one-on-one-practice
      after    21 days
      requires "Team Norms"

    session "Retrospective"
      meeting  strategic-alignment
      after    42 days
      requires "1-on-1 Practice"

  completion-requires
    all-sessions-attended
    artifact new-manager-report
```

- `after N days` is a scheduling hint, not a hard constraint. Manual scheduling remains the MVP default.
- `requires` names a preceding session whose outputs must exist before this session can launch.
- `completion-requires` defines what must be true for the program to be marked complete.
- Programs can reference any meeting recipe — including ones from the standard library.

---

### Level 4: A standard library (shipped with Weave)

Weavers can `use` shared libraries of phases and meeting recipes, similar to importing modules.

```wisp
use weave/library/facilitation-basics
use weave/library/body-doubling

define-meeting sprint-retrospective
  title   "Sprint Retrospective"
  minutes 60
  roles
    convener     1
    participants 3 to 8

  phases
    opening-checkin          ; from facilitation-basics
    breakout "What worked?" 15 :rooms 2
      "Name two things from this sprint that worked well."
    breakout "What didn't?" 15 :rooms 2
      "Name one thing that got in the way or slowed us down."
    full-group-reconvene     ; from facilitation-basics
    plenary "Commit" 10
      "We select two improvements to carry into next sprint."

  outputs
    retro-action-items  required
    synthesis-document  optional
```

---

### How the DSL compiles

Wisp source is evaluated by the Weave script evaluator — a restricted Guile environment that only exposes the DSL vocabulary (`define-phase`, `define-meeting`, `define-program`, `use`, and a small set of arithmetic and string operations). The macros validate their arguments at read time and produce validated `<meeting-script>` and `<meeting-program>` records. If validation fails, the evaluator returns a structured error before any record is created.

There is no arbitrary execution. The `phases`, `sessions`, `outputs`, and `assertions` forms are declarative. Once evaluated, the resulting records are handed to the script engine and stored in the PlayNet system of record like any other recipe.

**Compiler boundary:**
```
.weave file (Wisp source)
  → Wisp reader → S-expressions
  → Weave evaluator (restricted env) → validated records
  → ^script-engine (interpreter) → live meeting execution
```

---

### Validation rules

A `define-meeting` is valid when:
- All phases have `type` ∈ `{plenary, breakout, debrief, focus, checkin}`
- All phases have `minutes` > 0
- Breakout phases have `rooms` ≥ 2
- All named phase refs resolve in the current scope
- All `outputs` reference known artifact types
- All `assertions` use known assertion keywords

A `define-program` is valid when:
- All `session` blocks reference a defined meeting
- `requires` names reference sessions defined earlier in the same program
- `after N days` values are non-negative integers

---

### How VF concepts map to Weave execution

| VF type | Weave realization |
|---|---|
| `<agent>` type=`person` | Every human in the system — facilitator, participant, observer |
| `<agent>` type=`organization` | The meeting assembly (short-lived); also the parent org |
| `<agent-relationship-role>` | "facilitates", "participates-in", "observes" |
| `<agent-relationship>` | Person ↔ meeting-org binding that carries their role |
| `<process-specification>` | Meeting type ("Strategic Alignment"); phase type ("Breakout Phase") |
| `<recipe>` | The `.weave` script — template for producing a meeting's outputs |
| `<recipe-process>` | Phase template (type, duration, sequence-group) |
| `<recipe-flow>` | What conceptually flows between phases |
| `<process>` | A live meeting instance or a phase execution |
| `<economic-event>` action=`work` | One participant's time contributed to one phase |
| `<economic-event>` action=`deliver-service` | The facilitation service delivered by the convener |
| `<economic-event>` action=`produce` | Synthesis document or session log produced at end |
| `<intent>` action=`work` | An invitation to attend — unilateral, before acceptance |
| `<commitment>` action=`work` | Accepted attendance commitment — bilateral |
| `<intent>` action=`work` (output) | An action item decided during the meeting, not yet assigned |
| `<commitment>` action=`work` (output) | An assigned, agreed action item with a due date |
| `<proposal>` | A set of commitments arising from the meeting offered for agreement |
| `<economic-resource>` | Synthesis document, session log — output artifacts |
| `<resource-specification>` | "SynthesisDocument", "SessionLog", "CommitmentMap" — artifact types |
| `<recipe-group>` | `define-program` — a curriculum of meeting recipes |
| `<plan>` | A scheduled run of a program with concrete dates and agents |

---

## 3. Data Models

Weave's data model has two layers:

**VF layer (canonical, in the PlayNet store):** Agents, relationships, processes, events, recipes, intents, commitments, and artifacts. These are `<agent>`, `<process>`, `<economic-event>`, etc. from `planner/lib/schemas.scm`. Weave creates and reads these using the existing `^agent-store`, `^observer`, `^recipe-store`, and `^plan-store` actors.

**Weave operational layer (facilitation mechanics, in Weave actors):** Prompt card content, breakout room routing, transcript segments, timer state, voice delivery mode, and anonymization preference. These reference VF record IDs but are not expressible in pure VF. Stored in Weave-specific Goblins actors.

---

### VF Layer: People and Roles

Every human is an `<agent>` with `type = person`. No custom participant record.

```scheme
;; A person in the system — created once, referenced across many meetings
(make-agent
  (id "agent-alice-uuid")
  (type 'person)
  (name "Alice Okonkwo")
  (availability-window <her-schedule>)
  ...)
```

Roles within a meeting are `<agent-relationship-role>` records, defined once and reused:

```scheme
;; Three meeting roles — defined globally, reused across all meetings
(make-agent-relationship-role (id "role-facilitates") (label "facilitates") (inverse-label "is-facilitated-by") ...)
(make-agent-relationship-role (id "role-participates") (label "participates-in") (inverse-label "has-participant") ...)
(make-agent-relationship-role (id "role-observes") (label "observes") (inverse-label "is-observed-by") ...)
```

A person's membership in a meeting is an `<agent-relationship>`:

```scheme
;; Alice facilitates this meeting
(make-agent-relationship
  (id "rel-uuid")
  (subject "agent-alice-uuid")       ; the person
  (object "agent-meeting-org-uuid")  ; the meeting assembly (see below)
  (relationship "role-facilitates")
  (in-scope-of "agent-parent-org-uuid"))
```

---

### VF Layer: The Meeting Assembly (short-lived Organization)

A meeting needs to be an `<agent>` of `type = organization` — the social container — because `<agent-relationship>` requires both sides to be agents. The meeting assembly is created when the meeting is scheduled and closed after the synthesis is complete.

```scheme
;; The meeting assembly — a temporary organization
(make-agent
  (id "agent-meeting-org-uuid")
  (type 'organization)
  (name "Strategic Alignment — 2026-04-10")
  (note "Temporary assembly for one meeting session")
  ...)
```

This is distinct from the parent organization (the company or team). The meeting-org is `in-scope-of` the parent org.

---

### VF Layer: The Meeting as a Process

The meeting's economic activity is a `<process>`. The meeting assembly is the social container; the process is the transformation.

```scheme
;; The meeting process — transforms inputs (time, attention) into outputs (synthesis, commitments)
(make-process
  (id "proc-meeting-uuid")
  (name "Strategic Alignment — 2026-04-10")
  (based-on "proc-spec-strategic-alignment")  ; ProcessSpecification for this meeting type
  (in-scope-of (list "agent-meeting-org-uuid" "agent-parent-org-uuid"))
  (has-beginning "2026-04-10T14:00:00Z")
  (has-end "2026-04-10T15:30:00Z")
  (finished #f))
```

Meeting type is a `<process-specification>`:

```scheme
(make-process-specification
  (id "proc-spec-strategic-alignment")
  (name "Strategic Alignment Session")
  ...)
```

---

### VF Layer: Phases as Processes

Each phase execution is also a `<process>`, linked to the meeting by being `planned-within` the same plan or by sharing the `in-scope-of` agent. Phase type is its own `<process-specification>`:

```scheme
;; Phase type specs — defined once, reused across all meetings
(make-process-specification (id "proc-spec-plenary") (name "Plenary Phase") ...)
(make-process-specification (id "proc-spec-breakout") (name "Breakout Phase") ...)
(make-process-specification (id "proc-spec-debrief") (name "Debrief Phase") ...)

;; One phase execution
(make-process
  (id "proc-phase-2-uuid")
  (name "Diverge — Breakout")
  (based-on "proc-spec-breakout")
  (in-scope-of (list "agent-meeting-org-uuid"))
  (has-beginning "2026-04-10T14:15:00Z")
  (has-end "2026-04-10T14:35:00Z")
  (finished #f))
```

---

### VF Layer: Participant Time as Economic Events

Each participant's presence in each phase is an `<economic-event>` with action `work`:

```scheme
;; Alice contributes 20 minutes of attention to the breakout phase
(make-economic-event
  (id "event-alice-phase2-uuid")
  (action 'work)
  (provider "agent-alice-uuid")          ; Alice gives her time
  (receiver "agent-meeting-org-uuid")    ; the assembly receives it
  (effort-quantity (make-measure 20 "minutes"))
  (input-of "proc-phase-2-uuid")         ; input to the breakout phase process
  (has-beginning "2026-04-10T14:15:00Z")
  (has-end "2026-04-10T14:35:00Z")
  ...)
```

The convener's facilitation is `deliver-service` rather than `work`, because facilitation is a service delivered to the group:

```scheme
(make-economic-event
  (action 'deliver-service)
  (provider "agent-alice-uuid")
  (receiver "agent-meeting-org-uuid")
  (input-of "proc-meeting-uuid")
  ...)
```

---

### VF Layer: The Meeting Script as a Recipe

The `.weave` script evaluates to VF knowledge-layer records. A `define-meeting` produces a `<recipe>` plus a set of `<recipe-process>` and `<recipe-flow>` records:

```scheme
;; The recipe — the template for this meeting type
(make-recipe
  (id "recipe-strategic-alignment-uuid")
  (name "Strategic Alignment Session")
  (primary-output "res-spec-synthesis-document")   ; ResourceSpecification for SynthesisDocument
  (recipe-processes (list "rp-opening" "rp-diverge" "rp-reconvene" "rp-solve" "rp-commit")))

;; One recipe-process per phase
(make-recipe-process
  (id "rp-diverge")
  (name "Diverge — Breakout")
  (process-conforms-to "proc-spec-breakout")
  (has-duration (make-duration 20 'minutes))
  (sequence-group 2))  ; ordering within the recipe

;; What flows between phases (the "output" of one phase is the "input" framing of the next)
(make-recipe-flow
  (id "rf-diverge-to-reconvene")
  (action 'cite)                              ; knowledge/context flows, not consumed
  (resource-conforms-to "res-spec-group-output")
  (recipe-output-of "rp-diverge")
  (recipe-input-of "rp-reconvene"))
```

---

### VF Layer: Invitations as Intents and Commitments

An invitation to attend a meeting is an `<intent>`:

```scheme
;; Intent: Bob is being asked to contribute 90 minutes to the meeting
(make-intent
  (id "intent-invite-bob-uuid")
  (action 'work)
  (provider "agent-bob-uuid")            ; Bob would provide the work
  (receiver "agent-meeting-org-uuid")
  (effort-quantity (make-measure 90 "minutes"))
  (input-of "proc-meeting-uuid")
  (due "2026-04-10T14:00:00Z")
  (in-scope-of (list "agent-parent-org-uuid")))
```

When Bob accepts, the intent is promoted to a `<commitment>` (using the existing `promote-to-commitment` in `^plan-store`).

---

### VF Layer: Outputs — Action Items and Synthesis

**Action items** arising in the meeting are `<intent>` records (unilateral, not yet assigned) that become `<commitment>` records when assigned. Both are `output-of` the meeting process:

```scheme
;; An action item decided during the meeting
(make-intent
  (id "intent-action-item-uuid")
  (action 'work)
  (name "Prepare updated roadmap slide")
  (provider "agent-bob-uuid")            ; Bob volunteered
  (receiver "agent-parent-org-uuid")
  (output-of "proc-meeting-uuid")        ; emerged from this meeting
  (due "2026-04-17T09:00:00Z"))
```

A set of action items can be wrapped in a `<proposal>` for group agreement.

**The synthesis document** is an `<economic-resource>` conforming to a `<resource-specification>`, produced by an `<economic-event>` of action `produce`:

```scheme
;; The synthesis document resource-specification (defined once)
(make-resource-specification
  (id "res-spec-synthesis-document")
  (name "Meeting Synthesis Document")
  ...)

;; The synthesis produced at the end of this meeting
(make-economic-resource
  (id "res-synthesis-this-meeting-uuid")
  (conforms-to "res-spec-synthesis-document")
  (name "Strategic Alignment — 2026-04-10 — Synthesis"))

;; The production event
(make-economic-event
  (action 'produce)
  (provider "agent-alice-uuid")          ; convener/facilitator produced it
  (receiver "agent-parent-org-uuid")     ; org receives the artifact
  (resource-inventoried-as "res-synthesis-this-meeting-uuid")
  (output-of "proc-meeting-uuid"))
```

---

### VF Layer: Programs as RecipeGroups and Plans

A `define-program` produces:
- A `<recipe-group>` that references the constituent meeting recipes
- When a program is scheduled, a `<plan>` is created containing `<commitment>` records for each session

---

### Weave Operational Layer (non-VF, Weave actors only)

These records live in Weave's own Goblins actors, referenced by VF IDs. They are not VF types.

**`<weave-phase-config>`** — facilitation mechanics for a recipe-process:
```scheme
(make-weave-phase-config
  (recipe-process-id "rp-diverge")   ; links to VF RecipeProcess
  (prompt-text "In your group: what is the single biggest obstacle?")
  (audio-url #f)                     ; null until pre-generated
  (delivery-mode 'generic-tts)
  (breakout-room-count 3)
  (assignment 'random))
```

**`<weave-session-state>`** — live execution state for the script engine:
```scheme
(make-weave-session-state
  (process-id "proc-meeting-uuid")   ; links to VF Process
  (current-phase-index 1)
  (timer-remaining-seconds 847)
  (status 'running)                  ; running | paused | ended
  (livekit-room-name "meeting-abc"))
```

**`<transcript-segment>`** — Weave-specific, not a VF type:
```scheme
(make-transcript-segment
  (process-id "proc-phase-2-uuid")   ; links to VF Process for the phase
  (speaker-display-name "Participant 3")  ; resolved display-name only
  (text "I think the obstacle is...")
  (timestamp-ms 1744300800000)
  (confidence 0.94))
```

**`<weave-attribution>`** — anonymization preference, the only place real identity and display-name coexist:
```scheme
(make-weave-attribution
  (agent-id "agent-bob-uuid")           ; VF Agent ID — the real identity
  (meeting-org-id "agent-meeting-org-uuid")
  (display-name "Participant 3")        ; resolved at join time
  (attribution-mode 'anonymous)
  (livekit-identity "participant-3-livekit-token-string"))
```

The `<weave-attribution>` record is the anonymization boundary. Everything that leaves this record carries only `display-name`, never `agent-id`.

---

### Canonical VF mapping table

| Weave concept | VF type | VF action / field |
|---|---|---|
| Person | `<agent>` type=`person` | — |
| Facilitator role | `<agent-relationship-role>` | label="facilitates" |
| Participant role | `<agent-relationship-role>` | label="participates-in" |
| Observer role | `<agent-relationship-role>` | label="observes" |
| Person in meeting | `<agent-relationship>` | subject=person, object=meeting-org |
| Meeting assembly (social) | `<agent>` type=`organization` | short-lived |
| Meeting activity | `<process>` | based-on=meeting-type ProcessSpec |
| Meeting type | `<process-specification>` | name="Strategic Alignment" |
| Phase execution | `<process>` | based-on=phase-type ProcessSpec |
| Phase type | `<process-specification>` | name="Breakout Phase" |
| Meeting script | `<recipe>` | primary-output=SynthesisDoc ResourceSpec |
| Phase template | `<recipe-process>` | has-duration, sequence-group |
| Phase knowledge flow | `<recipe-flow>` | action=`cite` |
| Participant time | `<economic-event>` | action=`work`, input-of=phase-process |
| Facilitation service | `<economic-event>` | action=`deliver-service` |
| Invitation | `<intent>` | action=`work`, input-of=meeting-process |
| Accepted attendance | `<commitment>` | satisfies=invitation-intent |
| Action item (decided) | `<intent>` | action=`work`, output-of=meeting-process |
| Action item (assigned) | `<commitment>` | satisfies=action-intent, due=deadline |
| Action set for agreement | `<proposal>` | publishes list of commitments |
| Synthesis document | `<economic-resource>` + `<economic-event>` action=`produce` | output-of=meeting-process |
| Program / curriculum | `<recipe-group>` | groups meeting recipes |
| Scheduled program | `<plan>` | contains session commitments |

---

## 4. System Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Browser: Guile Hoot / WASM                                      │
│  weave.wasm  — Scheme UI + Goblins actors compiled to WASM       │
│  weave.js    — thin JS host: FFI user_imports + LiveKit SDK      │
│  LiveKit JS SDK (bundled) — WebRTC video/audio via FFI           │
│  WebSocket (via FFI) — Weave real-time events from relay         │
│  fetch (via FFI) — REST calls: meeting CRUD, auth, artifacts     │
└────────────────────┬─────────────────────────────────────────────┘
                     │ HTTPS + WSS
┌────────────────────▼─────────────────────────────────────────────┐
│  Weave Backend (Guile Scheme, Goblins vat)                       │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  ^meeting-manager    — create, list, route to ^meeting  │    │
│  │  ^meeting            — state machine, phase index       │    │
│  │  ^script-engine      — timer, auto-transitions          │    │
│  │  ^breakout-manager   — room assignment, dispatch/recall │    │
│  │  ^broadcast-channel  — audio injection coordination     │    │
│  │  ^transcript-store   — append-only segment log          │    │
│  │  ^synthesis-engine   — calls Claude API post-meeting    │    │
│  │  ^voice-profile      — ElevenLabs integration + consent │    │
│  │  ^participant        — identity + anonymization mapping │    │
│  │  ^work-logger        — records invitations, events      │    │
│  └───────────────────────────┬─────────────────────────────┘    │
│                              │                                   │
│  HTTP server (web module)    │ WebSocket relay                   │
│  LiveKit REST client         │ (extends existing relay.scm)      │
│  Deepgram WS client          │                                   │
│  Claude API client           │                                   │
│  ElevenLabs REST client      │                                   │
└──────────────────────────────┼───────────────────────────────────┘
                               │
┌──────────────────────────────▼───────────────────────────────────┐
│  LiveKit server (self-hosted, Hetzner)                           │
│  WebRTC rooms, participant management, track publishing          │
└──────────────────────────────────────────────────────────────────┘
```

### Script engine, video layer, broadcast, and transcription — connections

```
Script engine
  │── phase-start event ──► broadcast-channel (deliver prompt audio)
  │── phase-start event ──► WebSocket relay (notify all clients: show prompt card)
  │── breakout-phase ──────► breakout-manager (dispatch participants to rooms)
  │── phase-complete event ► breakout-manager (recall) or next phase start

Broadcast channel
  │── host audio ──► LiveKit "host-broadcast" room
  │── server track subscription ──► inject into each active breakout LiveKit room

Transcription pipeline
  │── LiveKit server-side track subscribe (per room)
  │── PCM audio stream ──► Deepgram WebSocket
  │── transcript segment ──► ^transcript-store (with room-id, phase-id, speaker-display-name)
  │── transcript segment ──► WebSocket relay (live display to host)
```

---

## 5. API Contracts — Three Critical Flows

### Flow A: Breakout dispatch

**Frontend → Backend**
```
POST /api/meetings/:meeting-id/phases/:phase-id/dispatch
Authorization: Bearer <convener-jwt>

{
  "assignment": "random",     // or "manual"
  "room_count": 3,
  "overrides": {              // optional, for manual assignment
    "participant-id-1": "room-1",
    "participant-id-2": "room-2"
  }
}
```

**Backend processing:**
1. Verify JWT is convener role
2. Validate meeting is in `running` state, current phase is `breakout` type
3. `assign-breakouts!` → map of room→participants
4. For each room: `livekit-create-room` if not exists
5. For each participant: `livekit-move-participant` to their assigned room
6. Update `^breakout-room` actors; emit `breakouts-dispatched` event to WebSocket relay
7. Return room assignments

**WebSocket event pushed to all clients:**
```json
{
  "type": "breakouts-dispatched",
  "rooms": [
    {"room_id": "room-1", "label": "Room 1", "participants": ["display-name-a", "display-name-b", "display-name-c"]}
  ]
}
```

**Frontend on receive:**
- Participant sees "Moving to Room 1…" overlay
- LiveKit SDK disconnects from plenary room; reconnects to `room-1` room with new token
- Host sees overview panel update

### Flow B: Broadcast delivery

**Frontend → Backend**
```
POST /api/meetings/:meeting-id/broadcast/start
Authorization: Bearer <convener-jwt>
// No body — host audio comes via LiveKit WebRTC
```

**Backend processing:**
1. Verify JWT is convener
2. `^broadcast-channel 'start-broadcast!` → subscribe to host's audio track in plenary room
3. For each active breakout room: publish broadcast audio as a synthetic participant
4. WebSocket event: `broadcast-started` with phase context

**On audio frame available (server-side, per-frame):**
- Server process reads PCM from LiveKit track subscription
- Re-publishes to each breakout room via LiveKit's server-side publish API

**Stop broadcast:**
```
POST /api/meetings/:meeting-id/broadcast/stop
```
Unpublish synthetic tracks from all breakout rooms; emit `broadcast-stopped` event.

**WebSocket event to clients:**
```json
{"type": "broadcast-started", "phase_id": "phase-2"}
{"type": "broadcast-stopped"}
```

### Flow C: Transcript + synthesis

**Transcript segment (server-internal, WebSocket push to host):**
```json
{
  "type": "transcript-segment",
  "segment": {
    "id": "uuid",
    "room_id": "room-1",
    "phase_id": "phase-2",
    "speaker": "Participant 3",
    "text": "I think the main obstacle is...",
    "timestamp_ms": 1234567890,
    "confidence": 0.94
  }
}
```

**Synthesis trigger:**
```
POST /api/meetings/:meeting-id/synthesis
Authorization: Bearer <convener-jwt>
```

Response: `202 Accepted` with `synthesis_id`. Poll `GET /api/synthesis/:id` for status, or subscribe to WebSocket `synthesis-complete` event.

**Synthesis result:**
```json
{
  "id": "uuid",
  "status": "complete",
  "phases": [
    {
      "phase_id": "phase-2",
      "prompt_text": "What is the single biggest obstacle?",
      "themes": ["Resource constraints", "Communication gaps"],
      "representative_quotes": [
        {"text": "I think the main obstacle is...", "speaker": "Participant 3"}
      ],
      "tensions": ["Group A sees resource as the issue; Group B sees communication"],
      "agreements": ["Everyone agrees the timeline is unrealistic"],
      "open_questions": ["Who owns the decision?"],
      "minority_views": ["One participant argued the obstacle is actually leadership clarity"]
    }
  ]
}
```

---

## 6. Security Model

### Anonymization enforcement (end-to-end contract)

The real identity → display name resolution happens exactly once: when the participant joins, `^participant` stores `account-id` + `attribution-mode`. The `display-name` is computed then and stored. From that point forward:

- `^transcript-store` receives only `display-name` (never `account-id`)
- `^synthesis-engine` queries transcripts by `meeting-id`; receives only `display-name`
- All synthesis artifacts contain only `display-name`
- The `account-id` field is accessible only via `^participant` with a convener-capability facet

**Never allowed:**
- Storing `{account-id, anonymous-token}` in the same transcript record
- Passing `account-id` to Deepgram, Claude, or ElevenLabs
- Joining by account across meetings without explicit re-consent

### Voice clone consent storage

`^voice-profile` stores:
- `convener-id` (account ref)
- `consent-timestamp` (UTC ISO-8601, when consent was granted)
- `consent-text` (verbatim text shown at consent time)
- `elevenlabs-voice-id` (opaque string)
- `generated-audio-refs` (list of `{phase-id, url}`)

Consent is required before `elevenlabs-voice-id` is created. Revocation:
1. Sets `elevenlabs-voice-id` to `null`
2. Calls ElevenLabs delete-voice API
3. Deletes all generated audio files
4. Logs revocation event in `^work-logger`

### Who can access what (capability model)

| Operation | Convener | Participant | Observer |
|---|---|---|---|
| Start/pause/advance meeting | ✓ | ✗ | ✗ |
| Dispatch/recall breakouts | ✓ | ✗ | ✗ |
| Broadcast audio | ✓ | ✗ | ✗ |
| View all transcripts (with attribution) | ✓ | Own only | ✗ |
| Trigger synthesis | ✓ | ✗ | ✗ |
| Share synthesis document | ✓ | ✗ | ✗ |
| See real names of anonymous participants | ✗ | ✗ | ✗ |
| Drop into breakout room | ✓ | ✗ | ✗ |
| View meeting | ✓ | ✓ | ✓ |

Implemented via PlayNet `^facet` attenuation: each role gets a facet that only exposes the methods that role is allowed to call.

---

## 7. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Broadcast latency > 1s in breakout rooms | Medium | High | Pre-generate audio for scripted prompts (Sprint 7); live broadcast is best-effort with lag warning |
| LiveKit server-side track publish API insufficient | Medium | Critical | Spike in Sprint 3 week 1; if blocked, fall back to re-routing participants through a shared "broadcast room" temporarily |
| Voice clone quality poor on diverse accents | Medium | Medium | Fallback to generic TTS in Sprint 7; test with actual host recording early |
| Deepgram accuracy in group calls with background noise | High | Medium | Enable noise suppression in LiveKit before sending to Deepgram; use `diarization` for per-speaker segmentation; accept 85%+ accuracy as MVP threshold |
| LLM synthesis flattens minority views | High | High | Explicit minority_views section in synthesis prompt with directive to protect dissenting views; test with planted dissenting voice |
| Anonymization leak through synthesis context | Medium | Critical | Synthesis prompt must not include any room roster or speaker mapping; only pass transcript segments with display-names |
| Hetzner server overloaded during live demo | Low | High | LiveKit can be horizontal-scaled; Guile vat is single-threaded but each meeting can be in its own vat; monitor memory during Sprint 1 |
| Consent and voice data storage legal exposure | Medium | High | Consent timestamp + verbatim text stored; ElevenLabs ToS requires consent; add explicit delete flow |

---

## 8. Open Questions (to resolve before or during build)

1. **LiveKit server-side track publish:** Does LiveKit's Go SDK support publishing an audio track from a server process into a room? Must confirm this is the broadcast mechanism before Sprint 3.

2. **PlayNet persistence:** Which persistence environment handles `^meeting` and `^transcript-store`? Blobstore? SQLite with Guile bindings? Decision affects Sprint 2.

3. **Deepgram per-room streaming:** LiveKit server-side subscription gives us separate audio streams per room. Deepgram has a 100 concurrent streams limit on some plans — check pricing tier needed for 6+ concurrent breakout rooms.

4. **Hoot + LiveKit SDK bundling:** Verify `@livekit/client` can be bundled alongside the WASM host file. The SDK must be loaded before `Scheme.load_main` so its objects are available as `user_imports`. Confirm the LiveKit JS SDK works when loaded this way (no SSR, pure browser).

5. **ElevenLabs Professional Voice Clone minimum recording:** API requires 30+ seconds of audio for a usable clone. 3×30s flow is the minimum; test quality before committing to this UX in Sprint 7.
