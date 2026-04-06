
## Overview

You are being asked to plan and architect **Weave**, a programmable video meeting platform. Think of it as Zoom with an intelligent and ubiquitous facilitator — not just a video call tool, but a structured meeting orchestration system that choreographs breakout groups, broadcasts prompts from the host into every room simultaneously, tracks time tightly, transcribes everything from all the breakout rooms, and synthesizes the output into a collective document. It’s programmable since every meeting can be defined as text.

Weave is designed for organizational change work. And all work is organizational change work. Weave will also gradually build a shared mental model of the organization, amassed one conversation at a time, but don’t build that into the initial mvp.


Weave is a facilitation programming system: a Playwright-like DSL, planner, and runtime for human meetings. Rather than treating meetings as informal calendar events, treat them as explicit units of labor that consume human capacity and should be specified, invited, run, and evaluated with care.

Core loop:

- Define meeting scripts programmatically
- Invite (manual first), while tracking each invitation as work
- Execute live choreography across virtual, IRL, or hybrid environments
- Generate structured outputs that feed future planning
Weave should be framed as a language and runtime for human coordination.

---

## ⚠️ IMPORTANT: DO NOT BEGIN CODING

Before writing any code, you must produce three planning documents:

- `@WEAVE_WEAVE_TASKS.md` — All discrete development tasks, organized by sprint (8 sprints, 1 week each), with checkboxes.
- `@WEAVE_PLANNING.md` — Architecture decisions, technology stack, data models, integration contracts, and open questions.
- `@WEAVE_CLAUDE.md` — Notes to your future self: conventions, resolved design decisions, pitfalls, and the conceptual model for the most complex systems.

Do not write application code until all three documents are complete.

---

## MVP Philosophy

The goal for the 8-week build is a **working, demoable MVP** that is suitable for sale. The single most important thing Weave must do is **disrupt how meetings normally run** through programmable breakout rooms and host broadcasts. Everything else is layered on top of that. At the same time, Weave must use standard design conventions and affordances wherever possible. Base the UI primarily on Zoom.

Build in this order of priority:

1. The meeting can run: video, breakouts, host controls
2. The meeting is choreographed: prompts display, timers count down, phases transition
3. The meeting is intelligent: transcription, synthesis, voice
4. The meeting designs itself: pre-meeting interview, AI-generated script

---
## MVP definition (what success means in 8 weeks)

By end of Sprint 8, a convener can:

- create or select a facilitation script,
- manually invite people (tracked as work events),
- run a live, choreographed session with breakouts, prompts, timers, and host control,
- capture transcripts with attribution/anonymization,
- generate a structured post-meeting artifact that feeds planning.

Non-goals for MVP:
- capacity-aware auto-scheduling and allocation (post-MVP)
- org-graph visualization layer (post-MVP)
- social discovery, presence indicators, inbound calling, notifications at scale (post-MVP)

## Guiding architecture decisions (day one constraints)
- Playnet-native data model and capability-based access control are foundational, not bolt-ons.
- The meeting script model (roles, phases, prompts, assertions, outputs) is a first-class contract used by execution, transcription tagging, and synthesis.
- Video is an execution substrate. We build only the video features required to run scripts.

Here is a clean markdown compilation of the 8 sprint deliverables, in order, written to support a ground-up rebuild of Weave.[[1]](https://www.notion.so/Weave-334dc35545c4800c97d4c1390c005c26?pvs=21)

# Weave MVP Rebuild Deliverables

## Sprint 1: Project scaffold + video foundation

**Goal:** Two people can join a room and see and hear each other reliably.[[2]](https://www.notion.so/S1-Week-1-Project-scaffold-video-foundation-5f54d90e44eb4246bb13de00540a0990?pvs=21)

**Primary deliverables**

- A monorepo with baseline project conventions, CI, and deployment pipeline.
- Authentication and an initial room model.
- A shareable room link with stable join, leave, reconnect, audio, and video behavior.
- Basic screen sharing inside the room, including host force-stop.[[2]](https://www.notion.so/S1-Week-1-Project-scaffold-video-foundation-5f54d90e44eb4246bb13de00540a0990?pvs=21)[[1]](https://www.notion.so/Weave-334dc35545c4800c97d4c1390c005c26?pvs=21)

**What must exist by the end of the sprint**

- The video substrate is chosen with later breakout and broadcast requirements in mind.
- Two participants can successfully run a live room end to end.
- Core permissions and room access behavior are in place.
- The system is stable enough for breakout routing to be layered on without rework.[[2]](https://www.notion.so/S1-Week-1-Project-scaffold-video-foundation-5f54d90e44eb4246bb13de00540a0990?pvs=21)

## Sprint 2: Breakout rooms

**Goal:** The host can send participants into breakout groups and recall them to plenary.[[3]](https://www.notion.so/S2-Week-2-Breakout-rooms-core-disruption-168b4b8205a1428e9a80437d1975a199?pvs=21)

**Primary deliverables**

- Breakout room creation and lifecycle management.
- Random and manual participant assignment.
- Host controls to dispatch participants into breakout rooms and recall them with one action.
- A host-visible room status layer across all breakouts.
- Manual invitation and attendance changes tracked as work events.[[3]](https://www.notion.so/S2-Week-2-Breakout-rooms-core-disruption-168b4b8205a1428e9a80437d1975a199?pvs=21)[[1]](https://www.notion.so/Weave-334dc35545c4800c97d4c1390c005c26?pvs=21)

**What must exist by the end of the sprint**

- Breakouts feel operationally clean, fast, and understandable.
- The host can manage room movement without confusion.
- Room identity and routing are stable enough to support later broadcast and prompt delivery.[[3]](https://www.notion.so/S2-Week-2-Breakout-rooms-core-disruption-168b4b8205a1428e9a80437d1975a199?pvs=21)

## Sprint 3: Broadcast + prompt display system

**Goal:** The host can push a prompt card and voice into all breakout rooms simultaneously.[[4]](https://www.notion.so/S3-Week-3-Broadcast-prompt-display-system-0e29f654b4eb44df98c969fd3d7393ae?pvs=21)

**Primary deliverables**

- A host broadcast audio channel that reaches all active breakout rooms at once.
- Prompt cards rendered on participant screens during the relevant phase.
- A coherent facilitation surface where broadcast voice and prompt display work together.[[4]](https://www.notion.so/S3-Week-3-Broadcast-prompt-display-system-0e29f654b4eb44df98c969fd3d7393ae?pvs=21)

**What must exist by the end of the sprint**

- The core meeting loop is real: prompt, breakout, reconvene.
- The convener can shape all breakout rooms at once from plenary.
- Prompt state is explicit enough to be attached to the script engine in the next sprint.[[4]](https://www.notion.so/S3-Week-3-Broadcast-prompt-display-system-0e29f654b4eb44df98c969fd3d7393ae?pvs=21)

## Sprint 4: Meeting script engine + timing choreography

**Goal:** A full choreographed meeting can run from start to finish automatically.[[5]](https://www.notion.so/S4-Week-4-Meeting-script-engine-timing-choreography-5d3d27defb45420fba01d82a79c2350f?pvs=21)

**Primary deliverables**

- A meeting state machine covering plenary, prompt delivery, breakout, reconvene, debrief, and repeat.
- A manually authored script format with phase sequence, durations, and prompt text.
- Visible countdown timers for participants.
- Host pause and manual advance controls.
- First reusable script templates.
- Body doubling implemented as a predefined scripted meeting type with:
    - intent prompt
    - timed focus block
    - cocoon UI mode
    - optional micro check-ins
    - optional screen sharing
    - session log artifact[[5]](https://www.notion.so/S4-Week-4-Meeting-script-engine-timing-choreography-5d3d27defb45420fba01d82a79c2350f?pvs=21)[[1]](https://www.notion.so/Weave-334dc35545c4800c97d4c1390c005c26?pvs=21)

**What must exist by the end of the sprint**

- Meetings are now executable programs rather than loose sequences of UI states.
- Host override works cleanly when real meetings go off-script.
- Phase identity is explicit enough to drive transcript tagging and later synthesis.[[5]](https://www.notion.so/S4-Week-4-Meeting-script-engine-timing-choreography-5d3d27defb45420fba01d82a79c2350f?pvs=21)

## Sprint 5: Real-time transcription + anonymization

**Goal:** Every room is transcribed in real time, and participants control attribution.[[6]](https://www.notion.so/S5-Week-5-Real-time-transcription-anonymization-29a478adfacb41969ce64f0b4573e3fa?pvs=21)

**Primary deliverables**

- Real-time speech-to-text integration.
- Transcript storage tagged by room, phase, prompt, and speaker context.
- Join-time named vs anonymous attribution choice for participants.
- End-to-end anonymization enforcement across storage and downstream consumers.
- A participant-to-facilitator help channel from breakout rooms.
- Facilitator response paths via video drop-in, voice, transcribed voice, or text.[[6]](https://www.notion.so/S5-Week-5-Real-time-transcription-anonymization-29a478adfacb41969ce64f0b4573e3fa?pvs=21)[[1]](https://www.notion.so/Weave-334dc35545c4800c97d4c1390c005c26?pvs=21)

**What must exist by the end of the sprint**

- Searchable, structured transcripts are available immediately after the meeting.
- Attribution preferences are preserved faithfully.
- Transcript data is clean enough to feed synthesis without reconstruction.[[6]](https://www.notion.so/S5-Week-5-Real-time-transcription-anonymization-29a478adfacb41969ce64f0b4573e3fa?pvs=21)

## Sprint 6: Post-meeting synthesis + collective mental model

**Goal:** The meeting produces a shareable document that captures what the group collectively said and thought.[[7]](https://www.notion.so/S6-Week-6-Post-meeting-synthesis-collective-mental-model-22e84e39507741e4a125a17c6862d145?pvs=21)

**Primary deliverables**

- LLM synthesis over transcripts grouped by phase and prompt.
- Structured output covering themes, tensions, agreements, open questions, and unresolved differences.
- A shareable post-meeting summary document.
- Reproducible derivative artifacts generated from the same synthesis contract:
    - executive infographic
    - synthesis map
    - prompt-to-output storyboard
    - tension map
    - decision and commitment map[[7]](https://www.notion.so/S6-Week-6-Post-meeting-synthesis-collective-mental-model-22e84e39507741e4a125a17c6862d145?pvs=21)[[1]](https://www.notion.so/Weave-334dc35545c4800c97d4c1390c005c26?pvs=21)

**What must exist by the end of the sprint**

- Post-meeting output is structured, reproducible, and tied to the script contract.
- Anonymization survives into all artifacts.
- The system produces usable organizational intelligence, not just a transcript dump.[[7]](https://www.notion.so/S6-Week-6-Post-meeting-synthesis-collective-mental-model-22e84e39507741e4a125a17c6862d145?pvs=21)

## Sprint 7: TTS voice + voice clone for prompts

**Goal:** Prompts can be delivered by live host speech, generic TTS, or a cloned host voice.[[8]](https://www.notion.so/S7-Week-7-TTS-voice-voice-clone-for-prompts-0c6042fc6ca24578a60f0c88f2ed389f?pvs=21)

**Primary deliverables**

- ElevenLabs integration for prompt voice generation.
- Three prompt delivery modes:
    - live host reading
    - generic TTS
    - cloned host voice
- Explicit consent and short recording flow for voice cloning.
- Pre-generated cloned prompt audio for reliability.
- Fallback to generic TTS when cloned delivery is weak or unstable.[[8]](https://www.notion.so/S7-Week-7-TTS-voice-voice-clone-for-prompts-0c6042fc6ca24578a60f0c88f2ed389f?pvs=21)[[1]](https://www.notion.so/Weave-334dc35545c4800c97d4c1390c005c26?pvs=21)

**What must exist by the end of the sprint**

- Prompt delivery mode is selectable as meeting configuration.
- Voice delivery works reliably under real breakout conditions.
- Consent boundaries around voice assets are preserved.[[8]](https://www.notion.so/S7-Week-7-TTS-voice-voice-clone-for-prompts-0c6042fc6ca24578a60f0c88f2ed389f?pvs=21)

## Sprint 8: Pre-meeting interview + AI meeting designer

**Goal:** A convener can describe what they want to achieve, and Weave produces a draft meeting script.[[9]](https://www.notion.so/S8-Week-8-Pre-meeting-interview-meeting-designer-90dfb6e8872d496b96eda4d502e2d954?pvs=21)

**Primary deliverables**

- A pre-meeting interview flow that captures goals, participants, desired outcomes, and meeting intent.
- LLM-based script generation that outputs:
    - phase sequence
    - timings
    - prompts
    - breakout configuration
- Human review and editing before launch.
- A structured, operationally simple MVP designer UI.
- Full compatibility between generated scripts and the runtime, prompt, transcript, and synthesis systems.[[9]](https://www.notion.so/S8-Week-8-Pre-meeting-interview-meeting-designer-90dfb6e8872d496b96eda4d502e2d954?pvs=21)[[1]](https://www.notion.so/Weave-334dc35545c4800c97d4c1390c005c26?pvs=21)

**What must exist by the end of the sprint**

- A convener can move from intention to draft script to live meeting to synthesized artifact.
- Generated scripts validate against the runtime contract.
- The 8-week MVP is now a coherent end-to-end loop.[[9]](https://www.notion.so/S8-Week-8-Pre-meeting-interview-meeting-designer-90dfb6e8872d496b96eda4d502e2d954?pvs=21)

## End state after Sprint 8

By the end of the rebuild, Weave should support this full flow:[[1]](https://www.notion.so/Weave-334dc35545c4800c97d4c1390c005c26?pvs=21)

- A convener creates or selects a facilitation script.
- Invitations are handled manually at MVP stage, but tracked as work.
- A live meeting runs with breakouts, prompts, timers, and host control.
- Transcripts are captured with attribution or anonymization.
- A structured post-meeting artifact is generated and fed back into planning.[[1]](https://www.notion.so/Weave-334dc35545c4800c97d4c1390c005c26?pvs=21)

## Explicitly out of MVP

Keep these out of the core 8-sprint rebuild:[[1]](https://www.notion.so/Weave-334dc35545c4800c97d4c1390c005c26?pvs=21)

- Capacity-aware auto-scheduling and allocation
- Org-graph visualization layer
- Social discovery, presence indicators, inbound calling, and notification systems at scale
- Friendship and short friendly calls, aside from preserving a future-facing Availability concept in the data model[[1]](https://www.notion.so/Weave-334dc35545c4800c97d4c1390c005c26?pvs=21)

If you want, I can turn this next into a more implementation-ready version organized as:

- repo milestones
- backend deliverables
- frontend deliverables
- data model deliverables


### Product thesis

- A meeting is not a calendar artifact first. It is a unit of labor that consumes human capacity.
- An invitation is also work: inviting someone creates a claim on time, attention, and coordination capacity, so invitations must be explicitly tracked.
- Capacity allocation is not an early product priority. The MVP can begin with manual invites, while still representing invitations and attendance as work in the system of record.
- Expertise is not reliably correlated with communication skill. In ordinary meetings, the best information often stays trapped behind uneven facilitation, status dynamics, and verbal dominance.
- Weave raises the communication skill level of the whole room by embedding clear prompts, turn-taking, timeboxing, and role constraints into the format.
- The game-like structure equalizes participation, increases psychological safety, and increases information transfer from domain experts who may not be polished communicators.
- A facilitation script should make roles, phases, prompts, timings, assertions, and expected outputs explicit.
- Over time, meetings can be incurred from the role graph, coordination demand, and capacity model, but that allocator is layered on after the manual-invite MVP.
- Weavers are developers who design facilitation scripts for virtual, IRL, and hybrid meetings of humans.

### System architecture shift

- PlayNet DSL defines roles, capabilities, constraints, interaction patterns, and demand signals in Scheme/Lisp.
- The entire Weave data model is built from PlayNet primitives: agents, relationship roles, capabilities, scopes, commitments, economic events, artifacts, and validators.
- Access control is built from PlayNet capability primitives, not from a separate application ACL layered on afterward.
- Invitations, attendance, speaking rights, facilitator powers, transcript visibility, and artifact access are all represented using PlayNet-native relationships, events, and capabilities.

### Visualization layer (intentional non-goal for MVP)

- Weave meetings and their artifacts implicitly *are* the organization: each interaction updates the underlying graph of roles, relationships, agreements, commitments, and constraints.
- A future visualization layer could render that evolving structure (cell nucleus plus mitochondria metaphor: energy and coordination orbiting and regulating a core), but we will not build visualization in the MVP.
    
    ![image.png](attachment:0b69747a-fdb2-4269-add2-6737dd04dfec:image.png)
    
- MVP requirement: store the underlying structure in a queryable form (events, relationships, artifacts, attribution/anonymization) so visualization can be added later without refactoring the core data model.
- Weave interprets or compiles those definitions into concrete meetings, participant sets, timing structures, and facilitation scripts.
- The execution layer runs the meeting with prompts, breakouts, broadcasts, timers, and room transitions.
- The output layer captures transcripts, decisions, commitments, and synthesis artifacts so they can feed the planning system.

### Project plan implications

- The first load-bearing system is the meeting DSL, PlayNet-native data model, and validation model, not video polish.
- Early scheduling can remain manual invite-driven, but each invite, response, attendance change, and artifact share should be tracked as work.
- Access control must be designed from PlayNet primitives from day one, because permissions are part of the product model rather than an implementation detail.
- Every meeting type should be expressible as a reusable script template with assertions about who must attend, what must happen, and what artifact must be produced.
- Body doubling, workshops, decision meetings, and retrospectives become standard libraries built on the same runtime.



# Full Product Description (for planning context)

### What Weave does

Weave handles the complete arc of a structured organizational meeting:

**Before the meeting**: Weave interviews the convener to understand what change they are trying to make, who needs to be in the room, and what a successful outcome looks like. It uses that input to design the meeting: a sequence of timed phases, each with a prompt that frames the group's work, and breakout groups configured to the purpose.

**During the meeting**: The meeting follows its script. Phases transition automatically or on host command. When a prompt phase begins, all participants see the prompt card and hear it delivered (live, TTS, or cloned voice). Participants are dispatched to breakout groups; the host can broadcast into all rooms simultaneously; participants can also press a button to route their speech to a facilitator with questions or concerns. Timers are visible to everyone. Every room is transcribed in real time. Participants choose their attribution preference before joining.

**After the meeting**: Weave synthesizes all transcripts into a collective mental model — a structured document that surfaces what the group said, where they agreed, where they diverged, and what questions remain open. The convener can share this output with the whole group or use it as the foundation for follow-up work.

### The meeting loop (the disruptive core)

The repeating unit of a Weave meeting is:

1. **Plenary** — everyone together
2. **Prompt delivery** — host (or voice) delivers a question or invitation
3. **Breakout** — participants work in small groups; host can broadcast in
4. **Reconvene** — groups return to plenary to share or receive the next prompt

This loop can repeat multiple times in a single meeting. The tight choreography and the host's ability to reach into every room without physically being there is what makes Weave fundamentally different from Zoom.

### Roles

- **Convener**: designs and runs the meeting. Has full host controls: advance phases, pause timers, dispatch/recall breakouts, broadcast.
- **Participant**: attends the meeting, joins breakout rooms, chooses named or anonymous attribution.
- **Observer**: view-only access, no video or audio. Can see the current phase and prompt.

---

## Technical Considerations for Planning

**Video infrastructure**: LiveKit (self-hosted, more control over room routing) or [Daily.co](http://daily.co/) (managed, faster to ship). The breakout engine depends heavily on this choice — evaluate both SDKs' support for programmatic room assignment before deciding.

**Meeting script engine**: A state machine with a linear phase sequence. Each phase has a type (plenary, breakout, debrief), duration, prompt text, and breakout configuration. The host can pause and advance. Design this data model carefully — it is referenced by the timer system, the prompt display, the breakout engine, and the transcript tagger all at once.

**Broadcast system**: The host's audio must reach all active breakout rooms simultaneously without the host having to join each room. This likely requires a dedicated broadcast channel at the infrastructure level — check LiveKit/Daily SDK support for this before committing to an approach.

**Transcription**: Deepgram or AssemblyAI for real-time STT. Audio from each room is streamed separately and tagged at the transcript level with room ID, phase ID, and speaker ID (or anonymous token). Anonymization is enforced at write time — the real name is never stored alongside the anonymous token in the same record.

**Voice cloning**: ElevenLabs. The consent and recording flow must happen before the meeting. Cloned audio is pre-generated for each prompt at meeting-design time, not synthesized live — this avoids latency issues during playback. The audio file is injected into rooms as a broadcast when the prompt phase begins.

**Synthesis engine**: LLM (Claude API) processes all transcripts post-meeting, grouped by phase and prompt. Output is structured: one section per phase, with themes, representative quotes (attributed per preference), tensions, and open questions. The synthesis prompt should be designed carefully to avoid flattening minority views.

**Auth and roles**: JWT-based auth with three roles: convener, participant, observer. Role is scoped to the meeting, not the account — the same user can convene one meeting and participate in another.

**Anonymization**: Participant chooses named/anonymous at join time. Choice is stored per-meeting-participant record. All downstream systems (transcript storage, synthesis, output doc) receive only the resolved display name (real name or "Participant [N]"). The mapping from real identity to anonymous token exists only in the meeting-participant record, accessible only to the convener and never surfaced in synthesis output.

---

## PlayNet foundation + MRP scheduling layer (demand/supply matching)

### Intent

Weave should be treated as the runtime for facilitation programs, not only as a meeting app. PlayNet defines the roles, capabilities, interaction rules, data model, and access-control primitives that Weave is built from.

The MVP starts with manual invites, but invitations are still modeled as work and recorded inside the PlayNet system of record.

Weave then turns those definitions into invited sessions, participant assignments, facilitation scripts, and post-meeting artifacts by matching:

- Demand: what outcome is needed, what capabilities are required, what interaction pattern is required, and what lead-time constraints apply.
- Supply: who is available, what capacity remains, what working hours or meeting comfort constraints apply, and what capabilities are present.
- Script: which facilitation program should run, what assertions must hold, and what artifact must be produced before the work is considered complete.

### Key product primitives (PlayNet-style)

- **Capability**: a named skill or authority ("can approve budget", "knows system X", "facilitates conflict", "owns repo Y").
- **Resource**: a person (or role pool) with capabilities, calendars, working hours, load limits.
- **Recipe**: how to produce an outcome artifact. Example: "Decision" requires {facilitator, domain-owner, decider} for 45 min + 24h lead time. Each “meeting” follows a recipe.
- **Demand (work order)**: a request to produce an outcome by a target date, with constraints.
- **Allocation**: assignment of specific people and time slots to satisfy the recipe.
- **Facilitation Script**: a reusable meeting program that specifies roles, phases, prompts, breakout logic, assertions, and required outputs. These are a type of recipe.
- **Invitation Event**: a recorded work event that incurs coordination labor on the inviter and the invitee, whether scheduling is manual or automated. In PlayNet
- **Capability Facet**: the PlayNet-granted authority that determines who can invite, convene, speak, observe, view transcripts, or access artifacts.
- **Weaver**: a developer who authors, tests, and improves facilitation scripts and libraries.

### Constraints we must model explicitly

- Lead time (eg >= 24h)
- Working hours + meeting comfort windows
- Max meetings/day and max context switches/day
- Fairness / load balancing (avoid summoning the same people)
- Opt-in policy for "loneliness" / social calls vs work calls

### Safety and trust constraints (non-negotiable)

- No hidden auto-scheduling. Always explicit confirmation before calendar writes.
- People can set hard boundaries and protected time.
- Capability claims must be verified over time (reputation is earned, not asserted).

### Where this fits in the roadmap

Capacity-aware allocation is a post-MVP expansion. The MVP (Sprints 1-8) proves Weave's disruptive meeting execution loop (breakouts, broadcast, script engine, transcripts, synthesis) while using PlayNet primitives for data modeling and access control from day one.

Proposed sequencing:

- **Backlog (immediately):** add the PlayNet-native data model and access model to @[WEAVE_PLANNING.md](http://WEAVE_PLANNING.md) so the core system does not paint us into a corner.
- **Phase 2 (Sprints 9-12):** implement a minimal allocator that can schedule a meeting from a structured request against availability + working hours.
- **Phase 3 (Sprints 13-16):** dependent-demand recipes, capability matching, load balancing, and "summon" workflows.

### MVP slice for Phase 2 (the smallest credible version)

- User defines working hours + meeting comfort windows.
- User defines capabilities (initially self-declared).
- Meeting request form: outcome type, required capabilities, duration, earliest start, lead time.
- Allocator proposes 1-3 meeting options (people + time) based on constraints.
- Confirmation step writes calendar events and creates a Weave meeting script stub.

## Document Requirements

### `@WEAVE_TASKS.md`

Organize all tasks by sprint (Sprint 1 through Sprint 8). Within each sprint, group tasks by area (language/runtime, infrastructure, backend, frontend, integrations). Each task is a checkbox with enough specificity to hand to a developer. Flag dependencies explicitly: if Sprint 3 depends on a specific Sprint 2 API contract, name it.

### `@WEAVE_PLANNING.md`

Cover:

- Final technology stack decision with rationale (especially video SDK choice)
- Meeting DSL design: grammar, AST, validation rules, assertion model, compiler/interpreter boundary, and how PlayNet expressions map to Weave execution primitives
- Data models: Meeting, Phase, Prompt, Participant, BreakoutRoom, Transcript, SynthesisDocument, BodyDoublingSession, SessionIntent, FocusBlock, CheckIn, SessionLog
- System architecture: how the script engine, video layer, broadcast system, and transcription pipeline connect
- API contracts between frontend and backend for the three most complex flows: breakout dispatch, broadcast delivery, and transcript + synthesis
- Security model: how anonymization is enforced end-to-end, voice clone consent storage, who can access what
- Risks and mitigations: broadcast latency, clone quality, transcription accuracy in noisy group calls, LLM synthesis of minority views

### `@WEAVE_CLAUDE.md`

Include:

- Project conventions: file structure, naming, API patterns, error handling
- The facilitation DSL mental model: scripts, roles, assertions, meeting incurrence, and how execution feeds planning
- The script engine conceptual model: what a Phase is, how transitions work, how the host overrides automatic timing
- The anonymization contract: exactly where the real-to-anonymous mapping lives and where it must never appear
- The broadcast architecture decision (whatever you land on) and why — this will be easy to get wrong later
- Voice clone pre-generation strategy and why live synthesis is avoided
- The synthesis prompt design and why minority views need explicit protection
- Sprint 7 fallback plan if voice clone delivery proves unreliable
- Body doubling conventions: intent capture, cocoon UX rules, check-in prompts, and what constitutes a "successful" session log

