# Consolidated MVP project plan (authoritative)

This section supersedes the older sprint descriptions below. Nothing is removed, but if there is disagreement, treat this as the plan.

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

## 8-sprint plan

### Sprint 1: skeleton runtime (DSL + minimal room)

Deliverable: a shareable room link that can execute a minimal script.

- Define meeting script primitives: roles, phases, prompts, assertions, outputs.
- Establish PlayNet-native core entities (enough to represent invitations, attendance, artifacts, capabilities).
- Implement minimal room runtime: join/leave, A/V, and screensharing (start/stop, host force-stop).
- Implement baseline permissions model wired to capability primitives.

### Sprint 2: breakouts and manual invites as work

Deliverable: host can dispatch and recall groups in real time, and invitations are tracked.

- Manual invite workflow (still user-driven scheduling), but create Invitation Events and attendance state changes.
- Breakout engine: create N rooms, assign, move participants.
- Host controls: dispatch/recall, room status visibility.

### Sprint 3: prompt delivery and host broadcast

Deliverable: prompt plus host voice reaches all breakouts simultaneously.

- Prompt cards that render per phase.
- Host broadcast audio channel into all active rooms.

### Sprint 4: script engine and timing choreography (plus body doubling template)

Deliverable: a scripted meeting runs end-to-end with timers and host override.

- State machine for phases, transitions, pause/advance.
- Visible timers.
- First reusable meeting templates.
- Implement body doubling as a predefined script plus UI skin (intent prompt, focus block, micro check-ins, session log artifact).

### Sprint 5: transcription tagged to script context

Deliverable: transcripts are stored by room plus script phase/prompt with anonymization.

- Real-time transcription integration.
- Join-time attribution/anonymization.
- Tag transcripts by room, phase, prompt, and role.

### Sprint 6: synthesis artifacts (reports, not visualization layer)

Deliverable: a reproducible structured summary artifact keyed by the script contract.

- LLM synthesis grouped by phase/prompt.
- Respect anonymization.
- Optional templated report derivatives (infographic, maps) as renderings of the same structured output.

### Sprint 7: voice delivery modes where leverage is real

Deliverable: prompts can be delivered via live host, generic TTS, or consented voice clone.

- Consent and recording flow.
- Fallback strategy and reliability constraints.

### Sprint 8: script authoring workflow for Weavers and conveners

Deliverable: author, test, and refine scripts quickly, then run them.

- Script editor or structured builder.
- Validation and preview.
- Conveners can generate a first draft script from an interview, then edit.

## Post-MVP (Phase 2 and beyond)

- Capacity-aware allocation and meeting incurrence (MRP demand/supply matching)
- Visualization layer for the evolving org graph
- Friendship availability and short friendly calls (if we choose to pursue it)

# Project Overview

Weave is a facilitation programming system: a Playwright-like DSL, planner, and runtime for human meetings. Rather than treating meetings as informal calendar events, treat them as explicit units of labor that consume human capacity and should be specified, invited, run, and evaluated with care.

Core loop:

- Define meeting scripts programmatically
- Invite (manual first), while tracking each invitation as work
- Execute live choreography across virtual, IRL, or hybrid environments
- Generate structured outputs that feed future planning

## Strategic reframe: Weave as facilitation DSL + PlayNet-native coordination system

Weave should be framed as a language and runtime for human coordination.

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

### Roadmap changes

- Sprint 1: define the DSL, PlayNet-native data model, access-control primitives, and minimal room runtime.
- Sprint 2: implement manual invites, invitation-as-work event tracking, participant permissions, and breakout host control.
- Sprint 3: connect scripts to breakout orchestration, prompt delivery, and host control.
- Sprint 4: add prompt/broadcast choreography, timers, and reusable meeting-type templates.
- Sprint 5: attach transcription and attribution to script phases, roles, and outputs.
- Sprint 6: generate structured post-meeting artifacts that feed the planning system.
- Sprint 7: add voice delivery modes where they increase leverage, not as the core product claim.
- Sprint 8: build authoring tools so Weavers and conveners can write, test, and refine scripts quickly.
- Post-MVP: add capacity-aware meeting incurrence and allocation on top of the manual-invite foundation.

## April 1, 2026 App update: Three adjacency ideas (do not compromise MVP)

## 1. Pair programming and AI tool coaching (screensharing)

- Recommendation: incorporate from the beginning as a small, standard capability inside the core video room.
- Why: screensharing is table stakes for pair work, and it strengthens the existing MVP flows (host teaching, prompt walkthroughs, debugging meeting scripts).
- Minimal MVP scope: one-click screen share (and stop share) for any participant, with host ability to force-stop a share if needed. No whiteboard, no collaborative code editor, no recording.

## 2. Body doubling: focused co-work containers (intent + cocoon)

- Recommendation: include as an explicit first-class meeting type, implemented as a thin layer on top of the existing scripted meeting engine.
- Why: it is the smallest expression of Weave’s deeper value: containers in time and space that support difficult work through human co-presence, light structure, and accountability.
- Minimal MVP scope:
    - A "Body Double" room template: 2 (optionally 3) participants, camera on by default, simple audio.
    - An "Intent" prompt at the start: each person writes what they will do in the next block (private to them by default, optionally shared).
    - A timed focus block (eg 25 or 50 minutes) with a visible timer and a soft "cocoon" UI state (minimal controls, no feed distractions).
    - Optional micro check-ins: 60 seconds halfway, 2 minutes at the end ("What happened? What is next?").
    - Optional screenshare (leverages Sprint 1) for co-working and gentle coaching.
    - Output artifact: a small session log (intent, duration, end check-in) that can be shared.
- Keep out of MVP: social discovery, presence indicators, inbound calling, notifications at scale.

## 3. Friendship via short friendly calls in spare time (availability setting)

- Inspiration: https://www.science-et-vie.com/corps-et-sante/pour-lutter-contre-la-solitude-il-vaut-mieux-un-message-dun-inconnu-que-de-chatgpt-231293.html
- Recommendation: keep out of MVP. It’s a different product surface (presence, inbound call routing, notifications, social graph) and will dilute focus.
- Small seed we can safely add early: define a future "Availability" concept in the data model (off by default) so we don’t paint ourselves into a corner.

## Where this fits in the 8-sprint roadmap

- Add screensharing to Sprint 1 (video foundation) as a core room capability.
- Add body doubling as a Sprint 4 deliverable once the script engine + timers exist (implemented as a predefined script + UI skin).
- Keep "availability + short friendly calls" as post-MVP (after Sprint 8), unless we later decide Weave needs an internal "warm-up" mode for teams.

# App Design

Make this into an application prompt that we can feed it into Antigravity. Please remind it to not actually begin coding but to mark down and make an @tasks.md, @planning.md, @claude.md so that it will begin to code this application, there are too many steps and it is too complicated in order to begin right away.

## Weave — Application Prompt for Antigravity (v2)

## Overview

You are being asked to plan and architect **Weave**, a programmable video meeting platform. Think of it as Zoom with an intelligent and ubiquitous facilitator — not just a video call tool, but a structured meeting orchestration system that choreographs breakout groups, broadcasts prompts from the host into every room simultaneously, tracks time tightly, transcribes everything from all the breakout rooms, and synthesizes the output into a collective document. It’s programmable since every meeting can be defined as text.

Weave is designed for organizational change work. And all work is organizational change work. Weave will also gradually build a shared mental model of the organization, amassed one conversation at a time, but don’t build that into the initial mvp.

---

## ⚠️ IMPORTANT: DO NOT BEGIN CODING

Before writing any code, you must produce three planning documents:

- `@tasks.md` — All discrete development tasks, organized by sprint (8 sprints, 1 week each), with checkboxes.
- `@planning.md` — Architecture decisions, technology stack, data models, integration contracts, and open questions.
- `@claude.md` — Notes to your future self: conventions, resolved design decisions, pitfalls, and the conceptual model for the most complex systems.

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

## 8-Sprint Roadmap

### Sprint 1 — Project scaffold + video foundation

**Goal**: Two people can join a room and see and hear each other.

Set up the monorepo, auth system, and a bare video room using LiveKit or [Daily.co](http://daily.co/). No meeting features yet — just working real-time video with a shareable room link. Establish the project conventions, CI pipeline, and deployment target that all future sprints build on.

Key decisions to make here: video SDK choice (LiveKit for self-hosted control vs [Daily.co](http://daily.co/) for managed simplicity), frontend framework, backend language, database, and hosting. 

Deliverable: a shareable video room link that works reliably.

---

### Sprint 2 — Breakout rooms (the core disruption)

**Goal**: The host can send participants into breakout groups and recall them to plenary.

This is the heart of Weave and the first genuinely disruptive feature. Build the breakout engine: create N rooms per meeting, assign participants to rooms programmatically, and move them in and out via host controls. Breakout composition should support random assignment and manual assignment. The host stays in plenary by default and can see the status of all rooms.

This sprint should be treated as the most important sprint in the build. If breakouts work cleanly and feel effortless to operate, the product is real.

Deliverable: host dispatches participants to breakout rooms and recalls them with a single action.

---

### Sprint 3 — Broadcast + prompt display system

**Goal**: While participants are in breakouts, the host can push a prompt card and their voice into all rooms simultaneously.

Build two things that work together: (1) a broadcast audio channel where the host's voice reaches all breakout rooms at once, and (2) a prompt card that displays on every participant's screen. The host reads the prompt live from a display on their screen. This sprint completes the core disruptive loop: prompt → breakout → reconvene.

Deliverable: host speaks into all breakout rooms simultaneously with a visible prompt card on every screen.

---

### Sprint 4 — Meeting script engine + timing choreography

**Goal**: A full choreographed meeting can run from start to finish automatically.

Build a state machine that drives the meeting through a sequence of phases: plenary → prompt delivery → breakout → reconvene → debrief → repeat. Each phase has a configured duration. Countdown timers are visible to all participants. The host can pause and manually advance phases. The script is authored manually this sprint (no AI generation yet) — a simple JSON or structured config that defines the phase sequence, durations, and prompt text for each phase.

This is the load-bearing system for everything else. Design it to be robust and flexible: meetings go off-script, and the host must always be in control.

Deliverable: a pre-scripted meeting runs end-to-end with timed phases and visible countdowns.

---

### Sprint 5 — Real-time transcription + anonymization

**Goal**: Every room is transcribed in real time, and participants control their attribution.

Integrate Deepgram or AssemblyAI for real-time speech-to-text. Transcripts are stored and tagged by room, phase, and prompt context. Before joining, each participant chooses whether to appear named or anonymous in the transcript. This anonymization preference must propagate consistently through all stored data and all downstream synthesis — it is a trust feature, not a nice-to-have.

Also build in the capability for participants to speak or type messages to the facilitator directly from inside the breakout room. Their words are transcribed and sent to the facilitator. The facilitator can then respond by video drop-in, by voice, by transcribed voice, or by text to the people who sent the message. 

Deliverable: a searchable, tagged transcript is available immediately after the meeting ends, with attribution honoring each participant's preference.

---

### Sprint 6 — Post-meeting synthesis + collective mental model

**Goal**: The meeting produces a shareable document that captures what the group collectively said and thought.

Run an LLM pass over all tagged transcripts to surface themes, tensions, agreements, and open questions. Group contributions by prompt/phase. Respect anonymization in the output. Generate a shareable document the convener can distribute to the whole group or use as raw material for follow-up work. The canonical use case: a team uses Weave to design a software application, and the synthesized output is a coherent product spec.

Deliverable: an auto-generated meeting summary document, shareable by link.

Additional Deliverable: a first set of post-meeting visual artifacts generated from the same structured synthesis (templates, not bespoke design):

- Executive infographic (one page)
- Synthesis map (concept graph of themes, tensions, open questions)
- Prompt-to-output storyboard (phase-by-phase outputs)
- Tension map (polarity and disagreement representation)
- Decision and commitment map (decisions, owners, dependencies)

Acceptance criteria: each artifact is generated from a structured data contract keyed by meeting phase and prompt, respects anonymization, and is reproducible on rerun.

---

### Sprint 7 — TTS voice + voice cloning for prompt delivery

**Goal**: Prompts can be read by a generic synthesized voice or a cloned version of the host's voice.

Integrate ElevenLabs. Implement three prompt delivery modes: (1) host reads live from the prompt card, (2) a generic TTS voice reads the prompt aloud, (3) a cloned host voice reads the prompt. Voice cloning requires an explicit consent flow and a short voice recording session before the meeting. The cloned voice can speak into breakout rooms even when the host is physically absent from those rooms — this is the key power of the feature.

Risk: voice clone quality and low-latency playback into active breakout rooms are both technically non-trivial. Design a clean fallback to generic TTS if clone delivery fails.

Deliverable: all three voice modes work reliably within a live meeting.

---

### Sprint 8 — Pre-meeting interview + AI meeting designer

**Goal**: A convener can describe what they want to achieve, and Weave produces a draft meeting script.

Build a pre-meeting interview flow that asks the convener about their goals, the change they are trying to make, who should be in the room, and what a successful outcome looks like. Use an LLM to translate those answers into a draft meeting script: phase sequence, timing, prompt text for each phase, and breakout group configuration. The convener reviews and edits the draft before launching. This closes the loop on the full Weave experience: from intent to meeting to output.

The interview UI can be a simple structured form for MVP — a fully conversational LLM-driven interview is a post-MVP polish pass.

Deliverable: end-to-end Weave flow works — from pre-meeting interview to live choreographed meeting to synthesized output document.

---

## Full Product Description (for planning context)

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

- **Backlog (immediately):** add the PlayNet-native data model and access model to @[planning.md](http://planning.md) so the core system does not paint us into a corner.
- **Phase 2 (Sprints 9-12):** implement a minimal allocator that can schedule a meeting from a structured request against availability + working hours.
- **Phase 3 (Sprints 13-16):** dependent-demand recipes, capability matching, load balancing, and "summon" workflows.

### MVP slice for Phase 2 (the smallest credible version)

- User defines working hours + meeting comfort windows.
- User defines capabilities (initially self-declared).
- Meeting request form: outcome type, required capabilities, duration, earliest start, lead time.
- Allocator proposes 1-3 meeting options (people + time) based on constraints.
- Confirmation step writes calendar events and creates a Weave meeting script stub.

## Antigravity message log (sequential)

Send these messages to Antigravity in order. Mark each checkbox when complete.

- [ ]  Message 0: Reframe Weave as a facilitation programming system, analogous to Playwright for meetings. State that meetings are labor, invitations are work, the MVP starts with manual invites, and the full data model plus access control are built from PlayNet primitives.
- [ ]  Message 1: Re-read the Weave prompt and confirm you will not start coding. Your first deliverables are `@tasks.md`, `@planning.md`, `@claude.md`.
- [ ]  Message 2: Add a first-class "Body Doubling" meeting type (focused co-work container) to the plan. Define minimal MVP scope: intent prompt, timed cocoon focus block, optional screenshare, micro check-ins, and a session log artifact.
- [ ]  Message 3: Update the 8-sprint roadmap placement: screenshare in Sprint 1; body doubling implemented in Sprint 4 as a predefined script + UI skin (on top of the script engine).
- [ ]  Message 4: In `@planning.md`, add the data model additions for body doubling (SessionIntent, FocusBlock, CheckIn, SessionLog) and note what is explicitly out of scope for MVP (social discovery, presence, inbound calling, notifications).

## Document Requirements

### `@tasks.md`

Organize all tasks by sprint (Sprint 1 through Sprint 8). Within each sprint, group tasks by area (language/runtime, infrastructure, backend, frontend, integrations). Each task is a checkbox with enough specificity to hand to a developer. Flag dependencies explicitly: if Sprint 3 depends on a specific Sprint 2 API contract, name it.

### `@planning.md`

Cover:

- Final technology stack decision with rationale (especially video SDK choice)
- Meeting DSL design: grammar, AST, validation rules, assertion model, compiler/interpreter boundary, and how PlayNet expressions map to Weave execution primitives
- Data models: Meeting, Phase, Prompt, Participant, BreakoutRoom, Transcript, SynthesisDocument, BodyDoublingSession, SessionIntent, FocusBlock, CheckIn, SessionLog
- System architecture: how the script engine, video layer, broadcast system, and transcription pipeline connect
- API contracts between frontend and backend for the three most complex flows: breakout dispatch, broadcast delivery, and transcript + synthesis
- Security model: how anonymization is enforced end-to-end, voice clone consent storage, who can access what
- Risks and mitigations: broadcast latency, clone quality, transcription accuracy in noisy group calls, LLM synthesis of minority views

### `@claude.md`

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

https://github.com/LivingCodeNow/weave

#### Create an MVP of Weave

- App
    
    <aside>
    🧑🏼‍💻
    
    ## **Phase 1 — foundation & core disruption (weeks 1–4)**
    
    </aside>
    
    <aside>
    🧑🏼‍💻
    
    Week 1
    
    ## **Project scaffold + video foundation**
    
    Stand up the monorepo, auth, and a bare video room using LiveKit or Daily.co. Two people can join a room and see/hear each other. No features yet — just the plumbing.
    
    LiveKit / Daily SDK
    
    Auth
    
    Room model
    
    Deliverable: shareable video room link that works
    
    </aside>
    
    <aside>
    🧑🏼‍💻
    
    ## Week 2
    
    ## **Breakout rooms — the core disruption**
    
    Build the breakout engine: create N rooms, assign participants, move them in/out programmatically. Host controls to send people to breakouts and recall them to plenary. This is the heart of the MVP.
    
    Breakout engine
    
    Host controls
    
    Participant routing
    
    Deliverable: host can dispatch + recall groups in real time
    
    </aside>
    

## 📌 Actions & Progress

[Untitled](https://www.notion.so/334dc35545c480948112d287a5df98a2?pvs=21)

## 🔗 Related Resources

[Untitled](https://www.notion.so/334dc35545c480c4bee3c6347a03c993?pvs=21)

## 📝 Notes & Updates

- 

#### Embodied signals to organizational flows (metaphor engine)

#### S1 (Week 1): Project scaffold + video foundation

### Project Overview

Stand up the monorepo, auth, and a bare video room using LiveKit or [Daily.co](http://Daily.co). Two people can join a room and see and hear each other. No meeting features yet, just the plumbing.

### Goals & Objectives

- Validate the video SDK choice and integration path.
- Establish working authentication.
- Establish a basic room model that the rest of the product can build on.

### Timeline & Milestones

- End of week deliverable: shareable video room link that works.

### Actions & Progress

[Untitled](https://www.notion.so/334dc35545c481649766ceb7a99b7d5a?pvs=21)

### Related Resources

[Untitled](https://www.notion.so/334dc35545c48141ac9ad747d93e8ce6?pvs=21)

### Notes & Updates

- 

#### S2 (Week 2): Breakout rooms (core disruption)

### Project Overview

Build the breakout engine. Create N rooms, assign participants, and move them in and out programmatically. Host controls to send people to breakouts and recall them to plenary.

### Goals & Objectives

- Implement breakout room creation and management.
- Implement host controls for dispatch and recall.
- Implement participant routing between rooms.

### Timeline & Milestones

- End of week deliverable: host can dispatch and recall groups in real time.

### Actions & Progress

[Untitled](https://www.notion.so/334dc35545c48161a05de5e2b17c1c89?pvs=21)

### Related Resources

[Untitled](https://www.notion.so/334dc35545c4810e83f4dc94defb8055?pvs=21)

### Notes & Updates

- 

#### S3 (Week 3): Broadcast + prompt display system

### Project Overview

While participants are in breakouts, the host can broadcast audio and a visible prompt card into all rooms simultaneously. Prompt cards display on screen and host reads live.

### Goals & Objectives

- Broadcast host audio into all breakout rooms.
- Display prompt cards for all participants.
- Complete the MVP loop: prompt, breakout, reconvene.

### Timeline & Milestones

- End of week deliverable: host speaks into all breakouts with prompt on screen.

### Actions & Progress

[Untitled](https://www.notion.so/334dc35545c4811ea580ca6b9482b4b1?pvs=21)

### Related Resources

[Untitled](https://www.notion.so/334dc35545c4810cbd28eafcf973a4e8?pvs=21)

### Notes & Updates

- 

#### S4 (Week 4): Meeting script engine + timing choreography

### Project Overview

Build a state machine that drives the meeting through phases: plenary -> prompt -> breakout -> reconvene. Countdown timers visible to all. Host can pause and advance. Script is manually authored this sprint.

### Goals & Objectives

- Implement the script state machine.
- Implement countdown timers visible to participants.
- Implement robust phase transitions with host override.

### Timeline & Milestones

- End of week deliverable: a full choreographed meeting runs end-to-end.

### Actions & Progress

[Untitled](https://www.notion.so/334dc35545c481d5a331f6049a9e9b04?pvs=21)

### Related Resources

[Untitled](https://www.notion.so/334dc35545c48111ba93df6e7ca85077?pvs=21)

### Notes & Updates

- 

#### S5 (Week 5): Real-time transcription + anonymization

### Project Overview

Pipe all room audio through Deepgram or AssemblyAI. Store transcripts tagged by room, phase, and speaker. Participant chooses named or anonymous before joining. Anonymization propagates to all stored data.

### Goals & Objectives

- Integrate Deepgram or AssemblyAI for real-time transcription.
- Implement anonymization at join time.
- Tag transcripts by room, phase, and speaker.

### Timeline & Milestones

- End of week deliverable: searchable transcript available post-meeting.

### Actions & Progress

[Untitled](https://www.notion.so/334dc35545c481f59760ea0ca4c6192e?pvs=21)

### Related Resources

[Untitled](https://www.notion.so/334dc35545c481cfb2fae7c4deb44d3f?pvs=21)

### Notes & Updates

- 

#### S6 (Week 6): Post-meeting synthesis + collective mental model

### Project Overview

Run an LLM pass over all transcripts to surface themes, tensions, and agreements. Output a shareable document the convener can distribute.

### Goals & Objectives

- Generate a synthesis from transcripts.
- Produce a shareable output document.
- Cluster themes in a way that preserves minority views.

### Timeline & Milestones

- End of week deliverable: auto-generated meeting summary document.

### Actions & Progress

[Untitled](https://www.notion.so/334dc35545c4812baa18f031cb8366a1?pvs=21)

### Related Resources

[Untitled](https://www.notion.so/334dc35545c48148b42ec4d623ebc192?pvs=21)

### Notes & Updates

- 

#### S7 (Week 7): TTS voice + voice clone for prompts

### Project Overview

Integrate ElevenLabs. Three modes: host reads live, generic TTS reads, cloned host voice reads. Voice clone requires a consent flow and short recording. Cloned voice can speak into breakouts even when host is absent.

### Goals & Objectives

- Integrate ElevenLabs.
- Implement consent and recording flow.
- Implement prompt delivery modes (live, TTS, cloned).

### Timeline & Milestones

- End of week deliverable: all three voice modes working in a meeting.

### Actions & Progress

[Untitled](https://www.notion.so/334dc35545c481899b08d074e2339272?pvs=21)

### Related Resources

[Untitled](https://www.notion.so/334dc35545c481fdae3ce5f8492a2962?pvs=21)

### Notes & Updates

- 

#### S8 (Week 8): Pre-meeting interview + meeting designer

### Project Overview

LLM-driven interview that asks the convener about goals, stakeholders, and desired outcomes. Outputs a draft meeting script (phases, prompts, breakout config, timing). Convener edits before launching.

### Goals & Objectives

- Build the interview UI.
- Implement script generation from interview outputs.
- Support convener review and edit before launch.

### Timeline & Milestones

- End of week deliverable: end-to-end Weave flow from idea to meeting to output.

### Actions & Progress

[Untitled](https://www.notion.so/334dc35545c4817f9662dc40d7787ab0?pvs=21)

### Related Resources

[Untitled](https://www.notion.so/334dc35545c481969344ca3326b5156e?pvs=21)

### Notes & Updates

- 

## Sprints

[Untitled](https://www.notion.so/1ab117520047454196049f5bae35f13e?pvs=21)

## Project Resources

[Untitled](https://www.notion.so/334dc35545c4805b9a26c5b33d15f949?pvs=21)

[Backlog: Script culture + competition](https://www.notion.so/Backlog-Script-culture-competition-c1981111dd9f4403adab1b4e22c9746f?pvs=21)