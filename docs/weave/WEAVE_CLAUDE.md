# WEAVE_CLAUDE.md
# Notes to Future Claude: Conventions, Decisions, Pitfalls, Mental Models

---

## Project conventions

### File structure

```
module/weave/
  core.scm              — top-level vat spawn, service entry point
  meeting.scm           — ^meeting, ^meeting-manager actors
  script-engine.scm     — ^script-engine, phase transitions, timer
  breakout.scm          — ^breakout-manager, ^breakout-room actors
  broadcast.scm         — ^broadcast-channel actor
  transcript.scm        — ^transcript-store, segment tagging
  synthesis.scm         — ^synthesis-engine, Claude API client
  voice.scm             — ^voice-profile, ElevenLabs client
  participant.scm       — ^participant actor, anonymization logic
  auth.scm              — JWT issue/verify, role claim encoding
  livekit.scm           — Guile HTTP client for LiveKit REST API
  deepgram.scm          — Guile WebSocket client for Deepgram STT
  work-logger.scm       — ^work-logger, work event types
  ui/
    room.scm            — video grid SXML components
    controls.scm        — host control panel SXML
    prompt.scm          — prompt card overlay SXML
    transcript.scm      — live transcript panel SXML
    breakout-panel.scm  — host breakout overview SXML
    synthesis.scm       — post-meeting synthesis view SXML
    body-doubling.scm   — cocoon mode + intent/check-in SXML

weave/
  weave.js              — JS host: user_imports FFI + LiveKit SDK wiring
  weave.html            — HTML shell: loads weave.js + weave.wasm
  weave.css             — base styles (no framework; Zoom-derived layout)
```

### Naming conventions

- Actors: `^thing` prefix (e.g., `^meeting`, `^script-engine`) — same as all PlayNet
- Records: `<thing>` with `make-thing`, `thing?`, `thing-field` accessors
- UI components: `render-thing` returning SXML (e.g., `render-video-grid`, `render-prompt-card`)
- FFI procedures: `livekit-*` prefix for LiveKit bindings, `dom-*` for DOM, `ws-*` for WebSocket
- Work events: symbols — `'invitation`, `'assignment-change`, `'attendance-change`, `'phase-complete`
- HTTP handlers: `handle-thing` (e.g., `handle-dispatch-breakouts`, `handle-synthesis-trigger`)

### API patterns

All HTTP handlers follow:
```scheme
(define (handle-foo request body)
  (let* ((token (extract-jwt request))
         (claims (verify-jwt token))   ; throws on invalid
         (meeting ($ meeting-manager 'get-meeting (assoc-ref claims 'meeting-id))))
    (require-role claims 'convener)    ; throws on wrong role
    ...
    (respond-json result-alist)))
```

WebSocket messages are alists serialized to JSON:
```scheme
'((type . "phase-started") (phase-id . "phase-2") (label . "Diverge"))
```

### Error handling

- Actor methods: use `(error "message" irritants...)` for impossible states; callers catch with `(with-exception-handler ...)`
- HTTP handlers: catch known errors (wrong role, meeting not found) and return structured JSON error responses; let unexpected errors propagate to the HTTP server's top-level handler which logs and returns 500
- FFI calls — **IMPORTANT:** JS exceptions thrown inside async JS functions **cannot** be caught by Scheme's `with-exception-handler` or `guard`. Hoot's Scheme call stack and the JS/Wasm exception systems are distinct and do not interoperate. Do not wrap `%livekit-connect` etc. in `guard` expecting it to help.

**Two patterns for JS/Scheme error handling:**

1. **Synchronous FFI** (fetch, XHR): JS returns a sentinel string on failure.
   Convention: `"ERR:HTTP-<status>"`, `"ERR:NET"`, `"ERR:PARSE"`. Scheme checks `(string-prefix? "ERR:" result)`.

2. **Async FFI** (LiveKit connect/enable/share): JS wraps in `try/catch` and calls `_callbacks.onError(source, message)`. Scheme's `on-livekit-error` receives the error and updates UI state. Never trust that an async call succeeded — only the callback confirms it.

---

## Debugging workflow

Hoot/WASM debugging is fundamentally different from JS debugging. There are no source maps from compiled WASM back to `.scm` files. When you see a stack trace in the browser console, it points to `reflect.js` internal machinery, not to your Scheme source. Here is the workflow that works:

### Primary debug environment: the Guile REPL

Develop and test module logic outside the browser first. Hoot includes an embedded WASM VM that runs inside Guile.

```
guile -L module -L path/to/hoot
(use-modules (hoot compile) (hoot vm))

; Compile a single expression and run it in the embedded VM:
(run-in-vm (compile-to-vm '(+ 1 2)))

; To trap a Wasm error and open an inspector:
(wasm-catch (run-in-vm (compile-to-vm '(my-broken-thing))))
```

Inside `wasm-catch` you can inspect the WASM stack, examine locals, and step through instructions.

### Browser: use DevTools Wasm panel

The `--emit-names` flag (already in the Makefile) writes a name section into `weave.wasm`. In Chrome/Firefox DevTools:
- Open Sources → find `weave.wasm` in the file tree
- Breakpoints, stepping, and stack traces work in the WASM disassembly view
- Function names will be human-readable (e.g. `render_join_screen`) rather than `func[42]`

Filter the console by `[weave]` — all Scheme-side `console-log` calls and all JS-side Weave logging are prefixed with it.

### Scheme-side logging

```scheme
(console-log "entering do-join!")
(console-warn (string-append "unexpected resp: " resp-str))
(console-error "livekit-connect returned ERR")
(debug-log "screen" (symbol->string *screen*))   ; label: value
```

These call directly into `console.log/warn/error` via FFI. Use them freely — the `[weave]` prefix distinguishes them from LiveKit's own verbose logging.

### When a fetch call fails

All synchronous XHR calls return `"ERR:..."` sentinels on failure (never throw). After any `%fetch-json` call, check:

```scheme
(let ((resp (%fetch-json url body)))
  (if (string-prefix? "ERR:" resp)
      (begin
        (console-error (string-append "fetch failed: " resp))
        ...)
      (... parse resp ...)))
```

The specific error code (`ERR:HTTP-404`, `ERR:NET`) is visible in the browser console even without the Scheme check.

### When an async LiveKit call fails

Errors from async LiveKit operations arrive via `on-livekit-error(source, message)` — not via Scheme exceptions. If LiveKit is behaving unexpectedly, look for `[weave] LiveKit error [...]` lines in the console. The `source` field tells you which JS function threw.

---

## The facilitation DSL mental model

### The three levels of the DSL

The Weave DSL has three composable levels. Each level is a PlayNet recipe:

1. **`define-phase`** — a named, reusable unit of facilitation time (type + duration + prompt). The atom.
2. **`define-meeting`** — a sequence of phases with role requirements and an output contract. One labor session.
3. **`define-program`** — a sequence of meetings spread across time, with dependency ordering. A curriculum or initiative.

This mirrors the way Playwright is organized: reusable helpers → test cases → test suites. A Weave program is an executable specification of an organizational change initiative.

### What a Phase is

A phase is a typed, timed, named stage of a meeting. It has exactly one type:
- `plenary` — everyone together in the main room
- `breakout` — participants are in sub-rooms; host can broadcast in; has a `rooms` count
- `debrief` — everyone back together to share; same as plenary structurally, distinct semantically
- `focus` — silent work period (used in body doubling)
- `checkin` — brief structured check-in, usually 2–5 min; no breakout

A phase is **not** a UI state. It is a unit of facilitation labor with a defined duration, a prompt to deliver, and an expected output. The script engine drives the phase; the UI renders it.

Named phases defined with `define-phase` are reusable across meetings. Inline phases (defined inside a `phases` block) are one-off and anonymous. Both produce identical internal records.

### How meeting incurrence works

A meeting is incurred from a `define-meeting` recipe. When evaluated, the recipe produces VF records in the PlayNet store. A concrete meeting instance is created by instantiating those records into live `<process>`, `<agent-relationship>`, and `<intent>` records. The Weave script engine holds the operational execution state (timer, phase index, LiveKit room names) separately in `<weave-session-state>`.

The incurrence model maps to VF:
- `define-phase` = produces a `<recipe-process>` + a `<process-specification>` for the phase type
- `define-meeting` = produces a `<recipe>` with `<recipe-process>` and `<recipe-flow>` records
- `define-program` = produces a `<recipe-group>`
- Meeting assembly = `<agent>` type=`organization` (the social container)
- Meeting activity = `<process>` based-on the meeting's `<process-specification>`
- Phase execution = `<process>` based-on the phase's `<process-specification>`
- Invitation = `<intent>` action=`work`, promoted to `<commitment>` on acceptance
- Participant time = `<economic-event>` action=`work`, input-of the phase process
- Synthesis = `<economic-resource>` produced via `<economic-event>` action=`produce`
- Action items = `<intent>` (unilateral) → `<commitment>` (agreed) → fulfilled by future `<economic-event>`

### Why the meeting is both an organization and a process

The meeting needs to be BOTH:
- An `<agent>` type=`organization` (the "meeting assembly") — because `<agent-relationship>` requires both sides to be agents. Without this, you cannot record that "Alice facilitates this meeting" as a VF relationship.
- A `<process>` — because that is where economic events attach (`input-of`, `output-of`). The process is the transformation activity; the organization is the social fact.

These two are distinct VF records with different IDs. The process's `in-scope-of` references the organization agent. They are created together when a meeting is scheduled and both are closed/finalized together.

### The script evaluator is restricted

The DSL evaluator (`module/weave/dsl-evaluator.scm`) is a capability-governed environment. It exposes only: `define-phase`, `define-meeting`, `define-program`, `use`, and arithmetic/string primitives. It does **not** expose general Scheme — no I/O, no actor spawning, no `eval`. This is deliberate: scripts authored by non-programmers or external users must not be able to do arbitrary computation.

The evaluator is the same pattern as PlayNet's metacircular evaluator in `(playnet evaluator)` — a restricted `evaluate` over a curated set of base bindings.

### Assertions

Script assertions (e.g., `min-participants 4`) are validated at launch time, not during the meeting. If assertions fail, the meeting cannot start. Add new assertion types in `script-engine.scm` under `validate-assertions`.

---

## The script engine conceptual model

### State machine

The script engine is a linear state machine. States:
```
created → open → running ⇄ paused → ended
```

The phase sequence is a vector. `current-phase-index` is an integer. `advance!` increments the index; `reset!` sets it to 0.

### Transitions

On `phase-complete` (timer fires) or `advance!` (host manual):
1. Emit `phase-ended` event with outgoing phase-id
2. Increment `current-phase-index`
3. If no next phase → emit `meeting-ended`; set status to `ended`
4. Else → call `on-phase-start!` for new phase:
   - If `breakout` type: call `^breakout-manager 'dispatch-breakouts!`
   - If `plenary`/`debrief` type: call `^breakout-manager 'recall-all!` (no-op if already in plenary)
   - Emit `phase-started` event with new phase data
   - Start timer for new phase duration

### Host override

`pause!` suspends the timer. The phase does not change. `advance!` during pause advances regardless of remaining time. These are the only two overrides. The host cannot rewind.

### Timer implementation

The timer is a Goblins actor (`^timer`) that receives a `tick!` message every second from a Shepherd service. It counts down from `duration-seconds`. On zero, it sends `phase-complete!` to the script engine. Using an actor (not a thread sleep loop) means the timer survives vat restarts correctly.

---

## The anonymization contract

**The single rule:** The mapping from real identity to display-name lives only in `^participant`. Nothing else ever holds both.

**Exactly where the mapping lives:**
- `^participant` record: `account-id` field (real) + `display-name` field (resolved at join time)
- That's it. No other record type has both.

**Where it must never appear:**
- `^transcript-store` segments: only `display-name` (never `account-id`)
- Synthesis prompts sent to Claude API: only `display-name`
- `^synthesis-document` output: only `display-name`
- Any HTTP response that is not a convener-scoped endpoint
- Deepgram transcription responses (we tag segments after they arrive using the already-resolved display-name)

**How to enforce:**
The `record-segment!` procedure in `transcript.scm` takes `display-name` as a string, not a participant ref. The caller (the transcription pipeline) must resolve the display-name before calling `record-segment!`. The transcript store has no access to `^participant` actors.

**Testing the contract:**
Before Sprint 5 ships: write a test that creates an anonymous participant, runs a meeting, generates synthesis, and asserts that no string matching the participant's real name appears anywhere in the transcript store or synthesis document.

---

## The broadcast architecture decision

### Why this approach

The host's audio must reach all active breakout rooms simultaneously without the host joining each room individually. The chosen approach:

1. Host publishes audio to the main plenary LiveKit room (normal WebRTC)
2. A server-side Guile process subscribes to the host's audio track via LiveKit's server SDK
3. The server re-publishes that audio into each active breakout room as a synthetic participant named `"Host (broadcast)"`

This is a server-mediated fan-out, not a LiveKit-native feature. **Why:** LiveKit does not natively support cross-room audio forwarding. The server subscription→republish pattern is how LiveKit's own egress/recording system works, so the API surface is well-tested.

### What could go wrong

- **Latency:** Each hop (host → LiveKit → Guile → LiveKit → breakout participant) adds ~100-200ms. Total expected: 300-500ms. Acceptable for speech, but we cannot guarantee lip-sync. The broadcast is audio-only for this reason.
- **Track count:** Each active breakout room gets one synthetic track. With 8 breakout rooms, the server holds 8 outbound tracks. This is within LiveKit's limits but must be measured.
- **Disconnect handling:** If the server process crashes, synthetic tracks disappear. `^broadcast-channel` must detect this and re-publish on reconnect. Add a health-check ping.

### Pre-generated audio (Sprint 7)

For scripted prompts with voice delivery, audio is pre-generated at meeting-save time via ElevenLabs and stored as URL-referenced files. At broadcast time the server fetches the file and injects it as a track — no live TTS latency during the meeting.

**Why not live TTS:**
ElevenLabs latency for streaming TTS is 500ms–2s depending on text length. In a live meeting, this delay would be perceptible and disruptive. Pre-generation moves all latency to design time.

---

## Voice clone consent storage and pre-generation strategy

### Consent flow (Sprint 7)

The consent screen must show:
1. What voice cloning means (ElevenLabs creates a model from your recordings)
2. Where the model is stored (ElevenLabs servers, referenced by voice-id in PlayNet)
3. How to revoke (deletes the ElevenLabs model and all generated audio)

The consent timestamp and verbatim consent text are stored in `^voice-profile`. Never truncate or summarize the consent text — it may matter legally.

### Pre-generation flow

At meeting save time:
```
for each phase with prompt-text and delivery-mode = cloned-voice:
  1. Call ElevenLabs TTS API with voice-id + prompt-text
  2. Store returned audio as a file (URL on Hetzner or object storage)
  3. Set phase.audio-url to the stored URL
  4. If ElevenLabs call fails → log error; leave audio-url null
```

At phase delivery time:
```
if phase.audio-url is non-null → broadcast the pre-generated file
else if delivery-mode = cloned-voice → fall back to generic-tts silently; log fallback
else if delivery-mode = generic-tts → call ElevenLabs with a generic voice-id (no consent needed)
else → live host reads the prompt (no audio injection)
```

### Sprint 7 fallback plan

If cloned voice delivery proves unreliable (quality too poor, ElevenLabs API unstable, consent UX too complex for MVP):
- Disable `cloned-voice` mode from the UI; keep the code path for post-MVP
- Ship Sprint 7 with only `generic-tts` and `live-host` modes
- This is an acceptable MVP because the disruptive core is the meeting choreography, not the voice quality

---

## The synthesis prompt design

### Why minority views need explicit protection

LLMs tend to summarize by consensus. In a group synthesis, if 4 people say X and 1 person says Y, the LLM will often drop Y entirely or mention it as "some participants felt...". This is exactly backwards for organizational change work: the minority view is often the signal that matters most.

### Synthesis prompt structure

The synthesis prompt must include this directive explicitly:
```
"minority_views" is a required field. It must capture any perspective that fewer than
half of speakers endorsed, verbatim or as close as possible. If only one person said
something, it belongs here. Do not drop minority views into "tensions" or omit them.
A missing minority_views field is a synthesis failure.
```

### One synthesis call per phase

Do not batch all transcript segments into a single synthesis call. Call Claude once per phase, passing only the segments from that phase. This:
- Keeps context size manageable
- Produces per-phase structure that maps to the script's phase sequence
- Allows partial synthesis if one phase's call fails

### Anonymization in synthesis

The synthesis prompt must not include the room roster, participant list, or any identity mapping. Only pass transcript segments as `{speaker: display-name, text: "..."}`. The LLM should never be able to reconstruct who is who.

---

## Body doubling conventions

### What body doubling is

A body doubling session is a meeting type where two or more people work silently in parallel. The presence of others increases focus. Weave's body doubling script:
1. Intent capture: each participant states what they plan to work on (30–60 seconds)
2. Focus block: 25-minute silent work period; cocoon mode UI
3. Micro check-in: 5 minutes to share progress (optional, prompted)
4. Repeat focus block if desired

### Cocoon mode UX rules

When `cocoon-mode?` is `#t` on a session:
- Video tiles are dimmed to 20% opacity
- All UI chrome except the timer is hidden
- No prompt cards, no chat, no controls visible
- Timer counts down in the center of the screen
- A single "I need a break" button is the only interactive element

Cocoon mode is the opposite of the normal meeting UI. Do not apply normal meeting layout rules when `cocoon-mode?` is set.

### What constitutes a successful session log

A `<session-log>` artifact from a body doubling session is considered complete when it contains:
- At least one `<session-intent>` with non-empty text
- At least one `<focus-block>` with both `start-time` and `end-time`
- A session `end-time`

Check-ins are optional. A session where the participant left before the first check-in is still a valid session log if the focus block completed.

---

## Hoot / WASM frontend patterns

### How to add a new LiveKit FFI binding

1. In `weave.js`, add to the `livekit` object in `user_imports`:
   ```js
   livekit: {
     connect(url, token) { /* returns room object */ },
     publishMicTrack(room) { /* ... */ },
     myNewBinding(room, arg) { return room.doSomething(arg); }
   }
   ```
2. In the Scheme module that needs it, declare with `define-foreign`:
   ```scheme
   (define-foreign livekit-my-new-binding
     "livekit" "myNewBinding"
     (ref null extern) (ref string) -> (ref null extern))
   ```
3. The first argument to `define-foreign` is the Scheme name; the second and third are the `user_imports` path.

### Video tile attachment

LiveKit produces HTML `<video>` and `<audio>` DOM elements. Scheme cannot directly hold DOM element refs as SXML — they must be attached to the DOM via FFI after the SXML render pass. The pattern:

1. SXML renders a `<div id="tile-{participant-id}">` placeholder
2. After DOM patch, JS callback fires when a track is available
3. JS callback calls an exported Scheme procedure `weave_attach_track(participantId, trackElement)`
4. Scheme procedure uses `get-element-by-id` FFI to find the placeholder and `append-child` FFI to attach the track element

Never try to embed DOM video elements as SXML nodes — they are opaque extern refs, not SXML.

### Actor-per-participant in the browser

Each participant's connection state, video track subscription, and UI state is managed by a Goblins actor spawned in the WASM vat. This mirrors the server-side `^participant` actor but is purely UI-facing. When a LiveKit event fires (participant joined, track published, disconnected), the JS callback resolves to the participant's actor ref and sends it a message.

This keeps all mutable state inside actors, not scattered across JS variables — consistent with PlayNet conventions.
