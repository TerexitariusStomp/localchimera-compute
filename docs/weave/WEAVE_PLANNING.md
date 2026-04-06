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

### Grammar (JSON/EDN, not a custom language)

The meeting script is a data format, not a programming language. Weavers author scripts as JSON (or EDN for Guile-native authoring). The script engine interprets them.

```json
{
  "id": "uuid",
  "title": "Strategic Planning Session",
  "version": "1.0",
  "delivery_mode": "generic-tts",
  "phases": [
    {
      "id": "phase-1",
      "type": "plenary",
      "label": "Opening",
      "duration_seconds": 300,
      "prompt_text": "Welcome. In the next 90 minutes we will...",
      "audio_url": null
    },
    {
      "id": "phase-2",
      "type": "breakout",
      "label": "Diverge",
      "duration_seconds": 900,
      "prompt_text": "In your group: what is the single biggest obstacle?",
      "audio_url": null,
      "breakout_config": {
        "room_count": 3,
        "assignment": "random",
        "participants_per_room": null
      }
    },
    {
      "id": "phase-3",
      "type": "debrief",
      "label": "Converge",
      "duration_seconds": 600,
      "prompt_text": "Each group shares their top obstacle. Facilitator synthesizes.",
      "audio_url": null
    }
  ],
  "assertions": [
    {"type": "min-participants", "value": 4},
    {"type": "required-role", "role": "convener"}
  ],
  "output_contract": {
    "required_artifact": "synthesis-document",
    "sections": ["themes", "tensions", "open_questions"]
  }
}
```

### Validation rules

A script is valid when:
- All phases have `type` ∈ `{plenary, breakout, debrief, body-doubling-focus, body-doubling-checkin}`
- All phases have `duration_seconds` > 0
- Breakout phases have a valid `breakout_config`
- Assertions reference known assertion types
- At least one phase exists

### Compiler/interpreter boundary

There is no compilation step. The JSON is loaded, validated, and handed to `^script-engine`. The script engine is a pure interpreter: it reads the phase sequence, maintains current-phase index, and emits events.

### How PlayNet expressions map to Weave execution primitives

| PlayNet concept | Weave realization |
|---|---|
| Agent | Participant (convener/participant/observer) |
| Capability | Role-scoped JWT + `^facet` limiting operations |
| Economic event | Work event (invitation, attendance, phase completion) |
| Commitment | Meeting attendance, artifact delivery |
| Artifact | Transcript, synthesis document, session log |
| Recipe | Meeting script (what to produce + how) |
| Process | Script engine run (one execution of a meeting) |

---

## 3. Data Models

### Meeting

```scheme
;; Goblins actor state
(define-record-type <meeting>
  (make-meeting id title script status created-by participants phases current-phase-index timer-state)
  meeting?
  (id meeting-id)
  (title meeting-title)
  (script meeting-script)              ; validated meeting-script record
  (status meeting-status)              ; created | open | running | paused | ended
  (created-by meeting-created-by)      ; participant-id of convener
  (participants meeting-participants)  ; hash-table: participant-id → ^participant ref
  (phases meeting-phases)              ; vector of phase records (from script)
  (current-phase-index meeting-current-phase-index)
  (timer-state meeting-timer-state))   ; running | paused | null
```

### Phase

```scheme
(define-record-type <phase>
  (make-phase id type label duration-seconds prompt-text audio-url breakout-config)
  phase?
  (id phase-id)
  (type phase-type)                    ; plenary | breakout | debrief
  (label phase-label)
  (duration-seconds phase-duration-seconds)
  (prompt-text phase-prompt-text)
  (audio-url phase-audio-url)          ; null until pre-generated
  (breakout-config phase-breakout-config)) ; null for non-breakout phases
```

### Participant

```scheme
(define-record-type <participant>
  (make-participant id account-id display-name attribution-mode role meeting-id livekit-identity)
  participant?
  (id participant-id)
  (account-id participant-account-id)          ; real account ref (stored only here)
  (display-name participant-display-name)      ; "Alice" or "Participant 3"
  (attribution-mode participant-attribution-mode) ; named | anonymous
  (role participant-role)                      ; convener | participant | observer
  (meeting-id participant-meeting-id)
  (livekit-identity participant-livekit-identity)) ; stable string used in LiveKit tokens
```

**Anonymization contract:** `account-id` is stored only in `^participant`. Everything downstream (transcript segments, synthesis, artifacts) receives only `display-name`. The mapping `account-id → display-name` is never written outside `^participant`. Convener can look up `account-id` given the meeting context; synthesis pipeline cannot.

### BreakoutRoom

```scheme
(define-record-type <breakout-room>
  (make-breakout-room id meeting-id phase-id label livekit-room-name roster status)
  breakout-room?
  (id breakout-room-id)
  (meeting-id breakout-room-meeting-id)
  (phase-id breakout-room-phase-id)
  (label breakout-room-label)           ; "Room 1", "Room 2", etc.
  (livekit-room-name breakout-room-livekit-room-name)
  (roster breakout-room-roster)         ; list of participant-ids
  (status breakout-room-status))        ; open | closed
```

### TranscriptSegment

```scheme
(define-record-type <transcript-segment>
  (make-transcript-segment id meeting-id room-id phase-id speaker-display-name text timestamp-ms confidence)
  transcript-segment?
  (id segment-id)
  (meeting-id segment-meeting-id)
  (room-id segment-room-id)            ; livekit-room-name or "plenary"
  (phase-id segment-phase-id)
  (speaker-display-name segment-speaker-display-name) ; "Alice" or "Participant 3" — never real name for anonymous
  (text segment-text)
  (timestamp-ms segment-timestamp-ms)
  (confidence segment-confidence))     ; 0.0–1.0 from Deepgram
```

### SynthesisDocument

```scheme
(define-record-type <synthesis-document>
  (make-synthesis-document id meeting-id created-at phases-output share-token status)
  synthesis-document?
  (id synthesis-id)
  (meeting-id synthesis-meeting-id)
  (created-at synthesis-created-at)
  (phases-output synthesis-phases-output) ; list of <synthesis-phase> records
  (share-token synthesis-share-token)
  (status synthesis-status))           ; generating | complete | failed

(define-record-type <synthesis-phase>
  (make-synthesis-phase phase-id prompt-text themes representative-quotes tensions agreements open-questions minority-views)
  synthesis-phase?
  ...)
```

### BodyDoublingSession

```scheme
(define-record-type <body-doubling-session>
  (make-body-doubling-session id meeting-id participant-id intent focus-blocks check-ins start-time end-time cocoon-mode?)
  ...)
```

### SessionIntent / FocusBlock / CheckIn

```scheme
(define-record-type <session-intent>
  (make-session-intent id session-id text created-at) ...)

(define-record-type <focus-block>
  (make-focus-block id session-id start-time end-time completed?) ...)

(define-record-type <check-in>
  (make-check-in id session-id prompt-text response-text timestamp) ...)
```

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
