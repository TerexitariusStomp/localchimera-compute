# WEAVE_TASKS.md
# Weave MVP — Sprint Task List (8 × 1 week)

> Checkboxes are per-developer tasks. Dependencies are flagged inline.
> All backend = Guile Scheme + Goblins. All frontend = Guile Hoot/WASM + SXML + JS FFI. Video = LiveKit.

---

## Sprint 1: Project scaffold + video foundation

**Goal:** Two people can join a room, see and hear each other.

### Infrastructure / DevOps
- [ ] Create `weave/` top-level directory in monorepo with `backend/`, `frontend/`, `docs/` sub-trees
- [ ] Add `weave-service.scm` Shepherd service definition under `deploy/guix/`
- [ ] Add `weave` Guix package + Shepherd service to `machines.scm`
- [ ] Provision LiveKit server on Hetzner (Docker Compose or Guix service); expose `:7880` WebRTC + `:7881` API
- [ ] Configure TLS reverse proxy (nginx) for `weave.playnet.app` → LiveKit + Guile HTTP server
- [ ] Set up GitHub Actions CI: lint Guile, run Hoot WASM build, run unit tests on push

### Backend (Guile Scheme)
- [ ] Create `module/weave/` namespace; add `(weave core)` with top-level vat spawn
- [ ] Implement `^room` actor: `create`, `join`, `leave`, `get-roster`; persist via `define-actor`
- [ ] Implement `^participant` actor: id, display-name, role (`convener`/`participant`/`observer`), room-ref
- [ ] JWT auth module: issue room-scoped tokens with role claim; verify on join
- [ ] LiveKit REST client in Guile: `create-room`, `delete-room`, `generate-token`, `list-participants`
- [ ] WebSocket relay: expose a Goblins → WebSocket bridge so frontend can `subscribe-room-events`
- [ ] Room access: only token-holder role may join; convener gets admin LiveKit grants

### Frontend (Guile Hoot/WASM)
- [ ] Create `module/weave/ui/` namespace; add `(weave ui room)`, `(weave ui controls)`, `(weave ui layout)` modules
- [ ] Write `weave.js` host file with `user_imports`: DOM bindings (element, event, document), `fetch`, WebSocket, crypto — following the `browser/repl.js` pattern exactly
- [ ] Add LiveKit JS SDK FFI bindings in `weave.js`: `livekit-connect`, `livekit-publish-track`, `livekit-mute`, `livekit-screen-share`, `livekit-disconnect`; wire LiveKit event callbacks back into WASM via exported Scheme procedures
- [ ] Auth flow component: join-link → name entry → `fetch` JWT → `livekit-connect` via FFI
- [ ] Video grid SXML component: auto-layout up to 16 tiles; mute/unmute self; toggle camera; uses DOM FFI to attach LiveKit video elements to SXML placeholders
- [ ] Screen share: start/stop via FFI; convener force-stop message sent over WebSocket relay
- [ ] Connection state actor: tracks `connecting | connected | reconnecting | failed`; renders overlay SXML on reconnect; error banner on failed join
- [ ] Leave room: `livekit-disconnect` FFI call; Goblins actor cleanup

### Testing / QA
- [ ] Manual E2E test: two browsers join same room, audio/video bidirectional
- [ ] Reconnect test: simulate network drop; verify rejoining restores video
- [ ] Screen share: share starts, remote participant sees shared screen

---

## Sprint 2: Breakout rooms

**Goal:** Host dispatches participants to breakout groups and recalls them.
**Depends on:** Sprint 1 room model, LiveKit room API, JWT auth

### Backend
- [ ] Implement `^meeting` actor: `create-meeting`, `get-state`, `set-phase`; owns list of `^breakout-room` refs
- [ ] Implement `^breakout-room` actor: room-id, roster, status (`open`/`closed`)
- [ ] `assign-breakouts!` procedure: random or manual assignment algorithm; returns room→participant map
- [ ] `dispatch-breakouts!`: move each participant to their assigned LiveKit sub-room (create sub-rooms on demand)
- [ ] `recall-all!`: move all breakout participants back to plenary room
- [ ] Work-event logging: record each `invitation`, `assignment-change`, `attendance-change` as a Goblins event on `^logger`
- [ ] HTTP/WebSocket API: `POST /meetings/:id/breakouts/dispatch`, `POST /meetings/:id/breakouts/recall`
- [ ] Host status feed: WebSocket stream of `{room_id, participant_count, status}` for all breakouts

### Frontend (Guile Hoot/WASM)
- [ ] Breakout assignment UI (host only): participant list, drag-to-group or auto-assign, room count selector
- [ ] Dispatch/Recall buttons with confirmation step
- [ ] Host overview panel: grid of breakout rooms with participant count, indicator if room is active
- [ ] Participant UX: seamless room transition (LiveKit disconnect → reconnect to new room); "Moving to breakout room N…" overlay
- [ ] Participant "Help" button: routes a signal to host indicating they need assistance

### Testing / QA
- [ ] 6-participant breakout test: dispatch 6 into 2 rooms of 3; verify audio isolation
- [ ] Recall test: recall all; verify all participants land back in plenary
- [ ] Work-event log: verify `assignment-change` event appears in `^logger` on each dispatch

---

## Sprint 3: Broadcast + prompt display system

**Goal:** Host pushes a prompt card and voice into all breakout rooms simultaneously.
**Depends on:** Sprint 2 breakout rooms, LiveKit active rooms API

### Backend
- [ ] `^broadcast-channel` actor: maintains list of active breakout room refs; `broadcast-audio!` injects audio track
- [ ] LiveKit Egress/Ingress API usage: test feasibility of injecting an audio track into multiple rooms simultaneously; document chosen approach
- [ ] `^prompt` record type: `{id, text, phase-id, audio-url?}`; stored in `^meeting`
- [ ] `deliver-prompt!`: set current prompt on meeting actor; push WebSocket event to all room subscribers
- [ ] Broadcast audio path: host WebRTC audio published to a special "broadcast" LiveKit room; server re-publishes track into each active breakout room

### Frontend (Guile Hoot/WASM)
- [ ] Prompt card component: overlay card appearing on phase start with prompt text, phase name, timer (stubbed)
- [ ] Broadcast audio indicator: subtle banner "Host is broadcasting" when host audio is active in breakout
- [ ] Convener broadcast UI: "Start broadcast" button + mic level indicator; stops when released or on phase end
- [ ] Prompt card dismiss: participants can minimize but not fully close (it reappears on new prompt)

### Testing / QA
- [ ] Broadcast latency test: measure time from host speech to audio appearing in breakout rooms; target < 500ms
- [ ] Prompt delivery test: dispatch breakouts → deliver prompt → verify card appears on all participant screens simultaneously
- [ ] Broadcast stops cleanly on recall

---

## Sprint 4: Meeting script engine + timing choreography

**Goal:** A full choreographed meeting runs start to finish automatically.
**Depends on:** Sprint 3 prompt delivery, breakout dispatch, broadcast channel

### Backend (Wisp DSL + Script Engine)
- [ ] Create `module/weave/dsl-evaluator.scm`: a restricted `evaluate` over a curated env exposing only `define-phase`, `define-meeting`, `define-program`, `use`, and arithmetic/string ops — no general Scheme I/O or actor spawning; modeled on `(playnet evaluator)`
- [ ] Implement `define-phase` macro: validates `type`, `minutes`, `rooms` (breakout only), `prompt`; produces `<phase>` record
- [ ] Implement `define-meeting` macro: validates `title`, `roles`, `phases` (resolving named refs), `outputs`, `assertions`; produces `<meeting-script>` record
- [ ] Implement `define-program` macro: validates `sessions`, `requires` dependency ordering, `completion-requires`; produces `<meeting-program>` record
- [ ] Implement `use` form: loads a named library file from `weave/library/` into the evaluator scope
- [ ] Write `weave/library/facilitation-basics.weave`: common reusable phases (`opening-checkin`, `full-group-reconvene`, `closing-reflection`)
- [ ] Write `weave/library/body-doubling.weave`: body doubling phase sequence (`focus` + `checkin` loop)
- [ ] Script validator: run as a separate pass after macro expansion; emit structured errors with line context
- [ ] `^script-engine` actor: owns current-phase index, timer state; handles `start!`, `pause!`, `advance!`, `reset!`
- [ ] Timer logic: tick every second via Shepherd heartbeat; emit `phase-tick` and `phase-complete` events
- [ ] Auto-transitions: on `phase-complete`, call `transition-to-next-phase!` which dispatches breakouts or recalls as appropriate
- [ ] Host override: `advance!` skips remaining time; `pause!` suspends the timer without changing phase

### Backend (Body Doubling)
- [ ] Define `body-doubling-script` template: intent-prompt → focus-block (25 min) → micro-checkin (5 min) → focus-block repeat
- [ ] `^body-doubling-session` actor: intent text, focus blocks, check-in prompts, session log artifact
- [ ] Cocoon mode flag on session: suppresses all non-essential UI when active
- [ ] Session log: record intent, start time, focus blocks completed, check-in responses, end time

### Frontend (Guile Hoot/WASM)
- [ ] Phase progress bar: shows current phase name + elapsed/remaining time
- [ ] Countdown timer: large visible countdown for participants; smaller for host
- [ ] Phase indicator: breadcrumb-style list of phases; current phase highlighted
- [ ] Host controls panel: Pause / Advance / End meeting buttons
- [ ] Script editor: Wisp text editor (plain `<textarea>`) with live validation feedback; shows structured errors inline; enough to author and save `.weave` files
- [ ] Body doubling UI: cocoon mode (dim all but timer), intent entry screen, check-in prompt overlay
- [ ] Template picker: select from predefined scripts on meeting creation

### Testing / QA
- [ ] Full script run: 3-phase script (plenary → breakout → debrief) runs to completion automatically
- [ ] Host pause/advance: verify timer stops and advances correctly
- [ ] Body doubling session: full flow from intent → focus → check-in → session log

---

## Sprint 5: Real-time transcription + anonymization

**Goal:** Every room is transcribed; participants control attribution.
**Depends on:** Sprint 4 phase identity (for transcript tagging)

### Backend
- [ ] Choose Deepgram (recommended) or AssemblyAI; integrate real-time streaming WebSocket STT API
- [ ] `^transcript-store` actor: append-only log of `transcript-segment` records `{id, meeting-id, room-id, phase-id, speaker-token, text, timestamp}`
- [ ] `speaker-token`: at join time, participant gets a stable token for the session; real identity → token mapping stored only in `^participant` record, accessible only to convener
- [ ] Anonymization enforcement: `^transcript-store` never receives real name — only the resolved display-name (`"Alice"` or `"Participant 3"`) passed in at write time
- [ ] Audio capture: LiveKit server-side track subscription per room → stream PCM to Deepgram; re-route on room transitions
- [ ] Transcript WebSocket feed: subscribe to `transcript-events` by meeting-id; receive segments as they arrive
- [ ] Search API: `GET /meetings/:id/transcript?phase=&room=&q=` returning matching segments
- [ ] Help-channel actor: participant signal routed to convener with room context; convener can respond via drop-in, voice, or text

### Frontend (Guile Hoot/WASM)
- [ ] Join-time attribution choice: modal on join — "Named (your name visible in transcript)" vs "Anonymous (Participant N)"
- [ ] Live transcript panel (host view): scrolling transcript with room labels, phase labels, speaker tokens
- [ ] Participant transcript panel: own segments visible; others shown as `Participant N` if anonymous
- [ ] Help button: sends help signal to convener with current room; shows "Facilitator notified" confirmation
- [ ] Convener help queue: notification badge; list of pending help requests; click to drop into that breakout

### Testing / QA
- [ ] Anonymization test: participant joins anonymous; transcript segments must show `Participant 3`, never real name; synthesized output must not contain real name
- [ ] Multi-room transcript test: 3 breakout rooms active; verify segment tagging is correct per room
- [ ] Help flow: participant signals help; convener receives notification; convener drops into room

---

## Sprint 6: Post-meeting synthesis + collective mental model

**Goal:** Meeting produces a shareable structured document.
**Depends on:** Sprint 5 transcripts, Sprint 4 phase identity and prompt text

### Backend
- [ ] `^synthesis-engine` actor: takes meeting-id; fetches all transcript segments grouped by phase+prompt; calls Claude API
- [ ] Synthesis prompt template: structure output as `{phase_id, prompt_text, themes: [], representative_quotes: [], tensions: [], agreements: [], open_questions: [], minority_views: []}` — minority views section explicitly required
- [ ] Claude API integration: streaming response; store raw LLM output + parsed structured result
- [ ] `^synthesis-document` actor: owns synthesis result, sharing settings, regeneration history
- [ ] Shareable link: generate token; `GET /synthesis/:token` returns public view
- [ ] Derivative artifact generators (all from same structured synthesis result):
  - Executive summary (markdown)
  - Synthesis map (JSON for rendering)
  - Tension map (JSON)
  - Decision + commitment map (JSON)
  - Prompt-to-output storyboard (ordered list of prompt→themes)
- [ ] Anonymization check: synthesis pipeline must receive only speaker display-names, never real-to-token mapping

### Frontend (Guile Hoot/WASM)
- [ ] Post-meeting synthesis page: trigger synthesis button (convener only); progress indicator while LLM processes
- [ ] Synthesis document view: sections per phase; themes, quotes, tensions, open questions rendered
- [ ] Share modal: copy link button; toggle public/private
- [ ] Artifact downloads: each derivative type as a button; download as JSON or markdown
- [ ] Meeting history page: list of past meetings with synthesis status badges

### Testing / QA
- [ ] End-to-end synthesis: run 3-phase scripted meeting with 4 participants; verify synthesis document covers all phases
- [ ] Minority view test: deliberately have one participant hold a dissenting view; verify synthesis document captures it in `minority_views` section
- [ ] Anonymization in synthesis: verify no real name appears in synthesis output when participant chose anonymous

---

## Sprint 7: TTS voice + voice clone for prompts

**Goal:** Prompts can be delivered by live host speech, generic TTS, or cloned host voice.
**Depends on:** Sprint 3 prompt delivery system, Sprint 4 script engine

### Backend
- [ ] ElevenLabs integration: `(elevenlabs:text-to-speech text voice-id)` → audio buffer
- [ ] Three delivery modes as an enum: `live-host`, `generic-tts`, `cloned-voice`
- [ ] `^voice-profile` actor: stores `{convener-id, consent-timestamp, recording-url, elevenlabs-voice-id}`; only accessible to the convener
- [ ] Voice clone consent flow: explicit opt-in; record consent with timestamp; revocation support
- [ ] Recording flow: 3 × 30-second recordings via browser mic → upload → send to ElevenLabs clone API
- [ ] Pre-generation: at meeting save time, generate audio for each prompt using chosen mode; store as URLs
- [ ] Delivery: on prompt phase start, broadcast-channel injects pre-generated audio file (not live TTS)
- [ ] Fallback: if cloned audio file is missing or ElevenLabs API fails, fall back to `generic-tts` silently; log fallback event
- [ ] Delete voice data: convener can delete voice profile and all generated audio at any time

### Frontend (Guile Hoot/WASM)
- [ ] Prompt delivery mode selector in meeting setup: three radio buttons with descriptions
- [ ] Voice clone onboarding: consent screen with clear explanation; recording UI (3 clips); progress indicator
- [ ] Audio preview: play generated prompt audio before meeting starts
- [ ] Prompt delivery mode indicator during meeting: small badge on prompt card showing "Voice" / "TTS" / "Live"
- [ ] Revoke voice data button in settings

### Testing / QA
- [ ] Pre-generation test: create 5-phase meeting; verify all 5 audio files generated before meeting starts
- [ ] Fallback test: delete audio file for one prompt; verify fallback to generic TTS with no error shown to participants
- [ ] Consent test: consent stored with timestamp; voice data deletion removes voice-id and audio files

---

## Sprint 8: Pre-meeting interview + AI meeting designer

**Goal:** Convener describes their goal; Weave produces a draft script.
**Depends on:** Sprint 4 script engine (generated scripts must validate against schema)

### Backend
- [ ] `^interview-session` actor: captures `{goal, participants-description, desired-outcomes, duration-preference, meeting-type-hint}`
- [ ] Meeting designer prompt: structured Claude API prompt that outputs a valid `.weave` Wisp script given interview answers; include the DSL grammar in the system prompt
- [ ] Script validator re-run on generated output via DSL evaluator: reject and re-prompt if validation fails (up to 3 retries)
- [ ] Save draft: generated script stored as `.weave` source with `status: draft`; convener edits the Wisp text before activating
- [ ] Script diff: show source-level diff between generated draft and saved edits (line-by-line, not field-by-field)

### Frontend (Guile Hoot/WASM)
- [ ] Pre-meeting interview flow: 5–7 question wizard; progress indicator; free-text + structured inputs
- [ ] Script preview: rendered view of generated phases/prompts; inline edit for each field
- [ ] Approval step: "Launch this meeting" button only appears after human review of script
- [ ] Meeting library: list of saved scripts (draft + active + archived) with template-flag for reusable ones
- [ ] Template sharing: mark a script as a template; accessible to other conveners in the org

### Testing / QA
- [ ] Full designer flow: fill out interview → generate script → edit one phase → approve → run live meeting → synthesis document produced
- [ ] Validation gate: intentionally generate a malformed script; verify validator catches it and re-prompts
- [ ] Template test: save script as template; second convener creates meeting from that template

---

## Cross-sprint / ongoing tasks

- [ ] Error monitoring: structured error events logged via `^work-logger`; surface in host UI via WebSocket relay
- [ ] Logging: structured JSON logs from all Goblins actors to a central log stream
- [ ] Rate limiting: throttle token generation and API endpoints
- [ ] Accessibility: keyboard navigation for all host controls; ARIA labels on video tiles
- [ ] Mobile-responsive layout: basic usability on tablet browsers (phones are non-goal for MVP)
- [ ] Security review: anonymization audit, JWT expiry, capability checks on all convener-only routes
- [ ] Performance: LiveKit room with 20 participants + 4 breakout rooms must not degrade video quality
