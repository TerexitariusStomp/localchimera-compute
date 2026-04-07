# Weave Object Model — ValueFlows Mapping

Weave's data model has two layers:

- **VF canonical layer** — standard PlayNet/ValueFlows records from `planner/lib/schemas.scm`, stored in `^agent-store`, `^recipe-store`, `^plan-store`.
- **Weave operational layer** — facilitation-specific state (room routing, transcript, timers, prompt delivery) stored in Weave Goblins actors. References VF IDs but is not expressible in pure VF.

---

## People and Roles

| Weave concept | VF type | Key fields |
|---|---|---|
| Any human (participant, facilitator, observer) | `<agent>` `type=person` | `id`, `name`, `availability-window` |
| Meeting role ("facilitates", "participates-in", "observes") | `<agent-relationship-role>` | `label`, `inverse-label` |
| Person's membership in a meeting | `<agent-relationship>` | `subject=person-id`, `object=meeting-org-id`, `relationship=role-id` |

Roles are global singletons (defined once, reused across all meetings). Membership bindings are per-meeting-instance.

---

## The Meeting: Two Records, One Reality

A meeting requires **two VF records** because VF separates social containers (agents) from economic activity (processes):

| Weave concept | VF type | Purpose |
|---|---|---|
| Meeting assembly (social container for memberships) | `<agent>` `type=organization` | `<agent-relationship>` requires both sides to be agents — you cannot hang "Alice facilitates this meeting" off a process |
| Meeting activity (economic transformation) | `<process>` | Tracks inputs (time, attention), outputs (synthesis, commitments), duration, and scope |

```
Meeting instance
  ├── agent-meeting-org-uuid    (<agent> type=organization)  ← social anchor for agent-relationships
  └── proc-meeting-uuid         (<process>)                  ← economic anchor for events and flows
```

Meeting type is a `<process-specification>` (e.g., "Strategic Alignment Session") — defined once, many instances.

---

## Phases

Each phase execution is a child `<process>` scoped to the meeting-org:

| Weave concept | VF type | Notes |
|---|---|---|
| Phase type ("Plenary Phase", "Breakout Phase") | `<process-specification>` | Defined once globally |
| One phase execution | `<process>` | `based-on=phase-spec-id`, `in-scope-of=[meeting-org-id]`, bounded by `has-beginning`/`has-end` |

---

## Participant Time and Facilitation

| Weave concept | VF type | `action` |
|---|---|---|
| One participant's time in one phase | `<economic-event>` | `work` — `provider=person`, `receiver=meeting-org`, `input-of=phase-proc` |
| Convener's facilitation service | `<economic-event>` | `deliver-service` — provider delivers to the assembly |

---

## Meeting Scripts

`.weave` files are Wisp DSL that compile to VF recipe records:

| Wisp form | VF type | Notes |
|---|---|---|
| `define-phase` | `<recipe-process>` | `process-conforms-to=phase-spec`, `has-duration`, `sequence-group` |
| Phase-to-phase flow | `<recipe-flow>` | `action=cite` (knowledge flows, not consumed); links `recipe-output-of` → `recipe-input-of` |
| `define-meeting` | `<recipe>` | `primary-output=res-spec-id`, `recipe-processes=[rp-ids]` |
| `define-program` | `<recipe-group>` | Curriculum of meeting recipes with sequencing constraints |
| Scheduled run of a program | `<plan>` | Concrete agents, dates, scope |

---

## Invitations and Commitments

| Weave concept | VF type | `action` | State |
|---|---|---|---|
| Invitation to attend a meeting | `<intent>` | `work` | Unilateral — before acceptance |
| Accepted attendance | `<commitment>` | `work` | Bilateral — promoted from intent via `promote-to-commitment` |
| Action item surfaced in meeting | `<intent>` | `work` | `output-of=meeting-proc` — unassigned |
| Assigned action item with owner | `<commitment>` | `work` | `output-of=meeting-proc`, `provider=assignee` |
| Action items offered as a bundle | `<proposal>` | — | Wraps a set of commitments |

---

## Meeting Outputs

| Weave concept | VF type | `action` |
|---|---|---|
| Output artifact type ("SynthesisDocument", "SessionLog") | `<resource-specification>` | — |
| Produced synthesis document or session log | `<economic-resource>` | — |
| The production event | `<economic-event>` | `produce` — `output-of=meeting-proc` |

---

## Operational Layer (Weave-only, not VF)

These records exist in Weave Goblins actors. They reference VF IDs but cannot be expressed in canonical VF:

| Record | Actor | Purpose |
|---|---|---|
| `<weave-phase-config>` | `^script-engine` | Prompt card text, voice delivery mode, rooms count, timer state |
| `<weave-session-state>` | `^meeting` | Current phase index, breakout room assignments, lifecycle status |
| `<transcript-segment>` | `^transcript-store` | Speaker identity (VF agent-id), text, timestamp, phase reference |
| `<weave-attribution>` | `^meeting` | Anonymization boundary: the only record holding both `agent-id` and `display-name` together |

---

## Breakout Rooms (Sprint 2)

Breakout rooms are `<agent>` type=`organization` (sub-assemblies) with their own `<process>` (the breakout activity) and `<agent-relationship>` records assigning participants to them.

| Weave concept | VF type |
|---|---|
| Breakout sub-assembly | `<agent>` `type=organization` scoped under the meeting-org |
| Participant assignment to breakout | `<agent-relationship>` `object=breakout-org-id` |
| Breakout activity | `<process>` `based-on=proc-spec-breakout`, `in-scope-of=[breakout-org-id]` |
| Help signal from participant | `<intent>` `action=work`, flagged as unaddressed need |

At the Weave operational layer, room routing and LiveKit room IDs are held in `^meeting` actor state, not in VF records.

---

## Summary: Weave → VF Type Map

```
Person              →  <agent> type=person
Meeting assembly    →  <agent> type=organization  (short-lived)
Parent org          →  <agent> type=organization  (persistent)
Breakout assembly   →  <agent> type=organization  (ephemeral sub-assembly)
Role definition     →  <agent-relationship-role>
Meeting membership  →  <agent-relationship>
Breakout assignment →  <agent-relationship>

Meeting type        →  <process-specification>
Phase type          →  <process-specification>
Meeting execution   →  <process>
Phase execution     →  <process>
Breakout execution  →  <process>

Phase template      →  <recipe-process>
Phase-to-phase link →  <recipe-flow>
Meeting template    →  <recipe>   (compiled from .weave DSL)
Program/curriculum  →  <recipe-group>
Scheduled run       →  <plan>

Participant time     →  <economic-event> action=work
Facilitation service →  <economic-event> action=deliver-service
Artifact production  →  <economic-event> action=produce

Invitation           →  <intent>     action=work
Accepted attendance  →  <commitment> action=work
Action item (open)   →  <intent>     action=work  output-of=meeting-proc
Action item (owned)  →  <commitment> action=work  output-of=meeting-proc
Commitment bundle    →  <proposal>

Artifact type        →  <resource-specification>
Artifact instance    →  <economic-resource>
```
