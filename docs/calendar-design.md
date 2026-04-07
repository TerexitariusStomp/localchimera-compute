# playnet Calendar — Design Document

## Vision

A calendar that is native to economic coordination. Not a personal productivity tool bolted onto a planner — a shared temporal surface where **work intents become commitments become observable effort**, and where people express when they're available to participate in collective processes.

The calendar merges multiple observers' views (each person = a color), connects to universal calendar formats (iCalendar/CalDAV, Google Calendar), and — critically — surfaces the full ValueFlows process context when you click on a work commitment: what process it belongs to, what inputs it consumes, what outputs it produces, and who else is committed to the same process.

---

## What You See

### Week Grid

A Notion-style week view. Days as columns, hours as rows. Events as colored blocks positioned by time, sized by duration. Overlapping events sit side-by-side within a day column.

Each event block shows:
- **Title** (bold, truncated)
- **Time range** (9:00 AM - 10:30 AM)
- **Location** (if any)
- **Person** (name, color-coded)
- **Status indicator** — circle icon: open (intent), half-filled (committed), filled (fulfilled)
- **Source badge** — "VF" pill for ValueFlows-sourced events vs plain calendar events

Above the grid:
- **Navigation**: prev/next week, today button, month/year label
- **Person legend**: colored dots with names, click to toggle visibility (merge/unmerge observers)
- **View toggles**: week / day (future: month)

Below/beside the grid:
- **Availability panel**: green dashed overlays on the grid showing when each person is available
- **All-day events strip**: full-width bars above the hourly grid for multi-day or untimed items (like Notion's top strip showing "Become a Compassionate Systems Master Practitioner")

### Event Detail Panel

Clicking an event opens a detail panel (right sidebar or modal). Two modes:

**Plain event:**
- Title, time, date, duration
- All-day toggle, time zone, repeat rule
- Participants list
- Location (text, video link, phone)
- Conferencing link
- Description / notes
- Source calendar (colored dot + name)
- Busy/Free status
- Reminders (10min before, 2min before)
- Linked docs (Notion-style: attached pages/links)

**Work intent / commitment (VF-sourced):**

Everything above, plus a **Process Context Panel**:

```
┌─────────────────────────────────────────────┐
│ Process: thresh                             │
│ Based on: ThreshingSpec                     │
│ Status: ○ planned  ● in-progress  ◉ done   │
├─────────────────────────────────────────────┤
│ INPUTS                                      │
│  ▸ wheat-raw    600 kg   (consume)          │
│  ▸ labor        16 hr    (work) ← YOU       │
│                                             │
│ OUTPUTS                                     │
│  ▸ wheat        500 kg   (produce)          │
├─────────────────────────────────────────────┤
│ OTHER COMMITMENTS IN THIS PROCESS           │
│  ▸ alice  8 hr  Mon 9-5   ◐ 4hr fulfilled  │
│  ▸ bob    8 hr  Tue 9-5   ○ not started     │
├─────────────────────────────────────────────┤
│ UPSTREAM (what feeds this)                  │
│  ▸ harvest → wheat-raw (600 kg available)   │
│                                             │
│ DOWNSTREAM (what this feeds)                │
│  ▸ wheat → grind (commune-mill needs 200kg) │
└─────────────────────────────────────────────┘
```

This is the same network diagram data from `scope-detail-panel` / `scope-network-diagram` in the federation view, but rendered inline with the calendar event. Clicking a process card navigates to the federation view focused on that scope.

### Availability Expression

People express their available time through:

1. **Weekly pattern**: recurring availability (Mon-Fri 9-5, Sat 10-2)
   - Maps directly to VF `AvailabilityWindow` → `DaySchedule` → `TimeRange`
   - Rendered as green dashed overlays on the week grid
   - Editable: click the overlay to adjust start/end, drag edges

2. **Specific overrides**: "I'm unavailable Thursday afternoon"
   - Maps to VF `SpecificDateWindow`
   - Red strikethrough overlay on the specific hours

3. **Booking windows**: "You can book 30min with me, 1 day minimum notice, 60 day max"
   - Maps to scheduling link configuration
   - Shown in the right panel when viewing a person's calendar

Availability is per-person and stored as VF temporal expressions in org bindings:
```scheme
(modify! 'my:availability
  (make-availability-window
    #f  ;; no month-level schedule
    #f  ;; no week-level schedule  
    (list (make-day-schedule '(monday tuesday wednesday thursday friday)
                            (list (make-time-range "09:00" "17:00"))))
    #f))
```

### Multi-Person Merge (Observer Fusion)

Each person's events render in their assigned color. The person legend toggles visibility:
- All visible = merged calendar (see conflicts, find mutual free time)
- One visible = individual calendar
- Color palette: 10 distinct colors cycling deterministically by person ID

When multiple calendars are merged, overlapping events stack side-by-side (column layout), and availability overlays blend (intersection = mutual free time highlighted).

---

## Data Model

### Event (calendar-native)

```scheme
((id . "evt-42")
 (title . "Planning sync")
 (date . "2026-04-06")
 (start-hour . 9) (start-min . 0)
 (end-hour . 10) (end-min . 30)
 (all-day . #f)
 (person . "alice")
 (location . "Room A")
 (conferencing . "https://meet.example.com/abc")
 (participants . ("alice" "bob" "carol"))
 (description . "Weekly planning sync for commune-grain")
 (color . "#63b3ed")
 (source . event)            ;; 'event | 'intent | 'commitment
 (status . open)             ;; 'open | 'committed | 'fulfilled
 (busy . #t)                 ;; busy/free for scheduling
 (reminders . (10 2))        ;; minutes before
 (repeat . #f)               ;; RRULE string or #f
 (calendar-id . "personal")  ;; which calendar source
 (linked-docs . ())          ;; list of (title . url) pairs
 ;; VF fields (present when source is 'intent or 'commitment)
 (vf-process-id . #f)
 (vf-action . #f)            ;; 'work, 'consume, 'produce, etc.
 (vf-resource-spec . #f)     ;; "labor", "wheat-raw", etc.
 (vf-effort-qty . #f)        ;; number (hours)
 (vf-effort-unit . #f)       ;; "hr"
 (vf-scope . #f)             ;; "commune-grain"
 (vf-intent-id . #f)
 (vf-commitment-id . #f)
 (vf-fulfilled-qty . #f))    ;; hours already recorded
```

### Person

```scheme
((id . "alice")
 (name . "Alice")
 (color . "#63b3ed")
 (visible . #t)
 (calendar-sources . ("personal" "google:abd3721@gmail.com"))
 (availability . <availability-window>)   ;; VF temporal expression
 (specific-overrides . ()))               ;; list of SpecificDateWindow
```

### Calendar Source

```scheme
((id . "google:abd3721@gmail.com")
 (type . google)              ;; 'local | 'google | 'caldav | 'ical-url
 (name . "Andrew Davis - Personal")
 (color . "#4285f4")
 (sync-url . "https://...")   ;; CalDAV endpoint or iCal URL
 (sync-token . "...")         ;; for incremental sync
 (last-sync . 1743724800000)  ;; epoch-ms
 (read-only . #f))
```

---

## Interoperability

### iCalendar (RFC 5545)

The universal calendar exchange format. Every calendar system speaks it.

**Export (playnet → world):**
- Each event serializes to a VEVENT component
- VF metadata goes into X-properties:
  ```
  BEGIN:VEVENT
  UID:evt-42@playnet
  DTSTART:20260406T090000Z
  DTEND:20260406T103000Z
  SUMMARY:Planning sync
  LOCATION:Room A
  DESCRIPTION:Weekly planning sync for commune-grain
  ATTENDEE;CN=Alice:mailto:alice@example.com
  ATTENDEE;CN=Bob:mailto:bob@example.com
  X-PLAYNET-VF-PROCESS:thresh
  X-PLAYNET-VF-ACTION:work
  X-PLAYNET-VF-SCOPE:commune-grain
  X-PLAYNET-VF-EFFORT:8;UNIT=hr
  END:VEVENT
  ```
- Availability exports as VFREEBUSY components
- Recurring events use RRULE

**Import (world → playnet):**
- Parse VEVENT → calendar event alist
- Map DTSTART/DTEND → start-hour/min, end-hour/min
- Map ATTENDEE → participants
- Map RRULE → repeat field
- Ignore X-properties from other systems gracefully
- VTIMEZONE handling: convert to UTC internally, display in local time

### CalDAV (RFC 4791)

Protocol for syncing calendars over HTTP. Used by Google Calendar, Apple Calendar, Fastmail, Nextcloud, etc.

**Sync flow:**
1. User provides CalDAV endpoint URL + credentials (or OAuth token for Google)
2. playnet issues `PROPFIND` to discover calendars
3. For each calendar: `REPORT calendar-query` with time range filter
4. Parse multiget response → list of VEVENT iCalendar blobs
5. Convert each to playnet event alist
6. Incremental sync via `sync-token` (only fetch changes since last sync)

**Write-back:**
- Creating/editing events in playnet generates `PUT` requests with iCalendar body
- Deleting events generates `DELETE` requests
- Conflict resolution: last-write-wins with etag checking

### Google Calendar API

For users who authenticate with Google:

1. OAuth2 flow (browser redirect → token)
2. `GET /calendars` → list of calendar sources
3. `GET /events?timeMin=...&timeMax=...` → events in range
4. Events API response maps cleanly to our event alist
5. Push notifications via webhook for real-time sync (future)

**Implementation path:** The server-side Guile relay (`deploy/web/socket/server.scm`) handles the OAuth flow and API calls. The browser client communicates via OCapN messages to the relay, which proxies Google Calendar API. This avoids CORS issues and keeps OAuth tokens server-side.

### OCapN Calendar Federation

For playnet-to-playnet calendar sharing between orgs:

1. Org A defines availability in bindings: `(modify! 'alice:availability <window>)`
2. Org A exposes a read-only calendar capability:
   ```scheme
   (modify! 'public:calendar
     (lambda (from-date to-date)
       ;; Return events + availability in date range
       ...))
   ```
3. Org B obtains capability via OCapN handshake
4. Org B calls `($ org-a-calendar from-date to-date)` → list of events
5. Events rendered in Org B's calendar view with Org A's person color

This is the **capability-based alternative to CalDAV** — no URLs, no credentials, just actor references. The org controls exactly what's visible.

---

## Work Intents → Calendar Commitments

### The Flow

```
Recipe (template)
  └─ RecipeFlow: action=work, effort=16hr, resource=labor
       │
       ▼
Intent (desire)
  "commune-grain wants 16hr threshing labor"
  └─ Displayed in calendar as ghost/dashed event block
       │
       ▼  (agent accepts, placed on calendar)
Commitment (promise)
  "alice commits 8hr Mon 9-5, bob commits 8hr Tue 9-5"
  └─ Displayed as solid event block with VF badge
       │
       ▼  (work happens, effort recorded)
EconomicEvent (fact)
  "alice worked 4hr Mon 9-1pm on thresh"
  └─ Progress bar on event block: 4/8 hr fulfilled
```

### Interaction: Scheduling Work

1. **Sidebar: unscheduled intents**
   - List of work intents from the current org's planner
   - Each shows: process name, resource spec, effort needed, due date
   - Filtered by: assigned to me, unassigned, all

2. **Click intent → click time slot** (two-click scheduling)
   - Select an intent from the sidebar
   - Click an hour cell on the calendar grid
   - Modal pre-fills: title from process name, person from intent provider, duration from effort qty
   - Save creates a Commitment (VF) + calendar event

3. **Drag intent → time slot** (future: requires mousedown/mousemove/mouseup FFI)
   - Drag from sidebar to grid
   - Drop creates commitment at that time

4. **Click scheduled commitment → process panel**
   - Opens the detail panel showing full process context
   - See upstream/downstream, other workers, progress
   - Record effort: "I worked 4 hours on this" → creates EconomicEvent

---

## Architecture

### Module Structure

```
module/playnet/ui/calendar.scm     — Pure SXML rendering (exists)
module/playnet/ui/calendar-detail.scm — Process context panel (new)
module/playnet/calendar/ical.scm   — iCalendar parser/serializer (new)
module/playnet/calendar/sync.scm   — CalDAV/Google sync logic (new, server-side)
browser/repl.scm                   — State management, event handlers (exists)
browser/calendar.css               — Styles (exists)
deploy/web/socket/server.scm       — OAuth proxy, CalDAV relay (modify)
```

### State in browser/repl.scm

```scheme
;; Core calendar state
*cal-week-start*           ;; epoch-ms of displayed week's Monday
*cal-events*               ;; list of event alists (all sources merged)
*cal-people*               ;; list of person alists
*cal-availability*         ;; list of availability slot alists
*cal-sources*              ;; list of calendar source alists

;; UI state
*cal-editing-event*        ;; event being edited (modal open)
*cal-selected-event*       ;; event selected (detail panel open)
*cal-editing-avail*        ;; availability editor open
*cal-sidebar-mode*         ;; 'people | 'intents | 'sources
*cal-unscheduled-intents*  ;; work intents from planner not yet scheduled
*cal-selected-intent*      ;; intent being placed on calendar

;; Sync state
*cal-sync-status*          ;; 'idle | 'syncing | 'error
*cal-last-sync*            ;; epoch-ms
```

### VF Integration Points

**Reading intents from the org:**
```scheme
;; In render-calendar-view, when inside an org:
(when (eq? *mode* 'inner)
  (let* ((bindings ($ *org* 'bindings))
         (intents (filter (lambda (b)
                           (and (pair? (cdr b))
                                (eq? (alist-ref (cdr b) 'action) 'work)))
                         bindings)))
    (set! *cal-unscheduled-intents* intents)))
```

**Process context lookup:**
When clicking a VF-sourced event, look up:
1. Process by `vf-process-id` → get process name, status
2. All commitments with same `input-of` or `output-of` → other workers
3. Resource specs → what's consumed/produced
4. Upstream/downstream processes → supply chain context

This reuses the same data structures already rendered by `scope-network-diagram` in `ui/network.scm`.

### Persistence

**Local events:** localStorage via existing `ls-set-item`/`ls-get-item` with pipe-delimited serialization (already implemented).

**VF events:** Derived from org bindings on each render. Not separately persisted — the org's Goblins persistence store is the source of truth.

**External calendar events:** Cached in localStorage with sync-token for incremental refresh. Source of truth is the remote CalDAV/Google server.

---

## Phases

### Phase 1: Calendar MVP (done)
- Week grid, event blocks, overlap handling
- Click-to-create with modal editor (title, person, location, description, time pickers)
- Multi-person colors + legend toggle
- Per-person colored availability overlays
- localStorage persistence (backward-compatible serialization)
- Sample data on first load (including VF commitment events)

### Phase 2: Rich Event Detail (done)
- Event detail panel (right sidebar with full info + close/edit/delete)
- Description field in editor
- All-day events strip above the hourly grid
- Current time indicator (red line with dot)
- Today column + header highlight (green circle on date number)
- Capacity bar (committed / available hours with utilization %)
- Functional availability editor with dropdowns
- Status indicators on event blocks (○ open, ◐ committed, ● fulfilled)
- VF badges on commitment/intent events
- Hover expand on events
- Auto-scroll to 8 AM on tab entry
- Event text wrapping (2-line on tall events, compact mode on short)

### Phase 3: VF Process Context (done)
- Process context panel on VF events (breadcrumb, progress bar, other workers)
- VF sample data with threshing commitments across workers
- Status tracking (open/committed/fulfilled)

### Phase 3b: VF Intent Scheduling (done)
- Unscheduled intents sidebar (extracted from federation commitment data)
- Two-click scheduling: select intent → click time slot → pre-filled VF commitment
- 3-click lifecycle: ghost (open) → committed (shaded) → fulfilled (solid) → loop
- iCalendar export (.ics download with VF X-properties)

### Phase 3c: VF deeper (done)
- Effort recording from calendar ("I worked N hours" → real `EconomicEvent` via `^observer 'record-event`, advancing `fulfillment-state`)
- Scope / plan / acting-as selectors (URL hash sync)
- Sidebar split: "Awaiting your acceptance" / "Needs a volunteer" / "Others' pending"
- Ghost intents on the grid at planned times (dashed VF style)
- Suggested-provider badges from skill-matching metadata
- Accept → `($ plan-store 'promote-to-commitment …)` → `($ observer 'register-commitment …)`
- Decline → `($ plan-store 'set-meta iid '())` (clears suggestion)

### Phase 3d: Real planner integration (done)
- `^planner-service` actor in `server/planner-service.scm`, hosted in its own `planner-vat` inside `server/gateway.scm`
- Browser holds `*planner-cap*` from `(<- *lobby* 'planner)`; all calendar reads + writes go through it
- Server-side `seed-meeting-scope!` populates one demo scope (org:meeting) at boot via `dependent-demand`
- `scope-snapshot` is a single round-trip that joins plan-store records with observer fulfilment-state
- Memory persistence (re-seeded each boot)
- Trust-the-client identity (`acting-as` recorded as the EconomicEvent provider verbatim)

### Phase 3e: Remaining (deferred)
- File-backed persistence (one-line swap from `make-memory-store` to `make-file-store`)
- Per-user planner caps tied to authenticated identity via signup-agent
- Push updates via `^user-inbox` so multi-user concurrent edits propagate
- `process-context` upstream/downstream from recipe topology walking
- "Volunteer" button on unmatched intents
- "+ New plan" button calling `instantiate-recipe`
- Decline → re-run `match-work-flows` with declining agent in `#:already-assigned` to compute a fresh suggestion

### Phase 4: Calendar Interop
- iCalendar import (parse .ics files)
- CalDAV sync (via server relay)
- Google Calendar OAuth integration (via server relay)
- Calendar source management UI (add/remove/configure sources)

### Phase 5: OCapN Calendar Federation
- Expose calendar as org capability
- Subscribe to remote org calendars via OCapN
- Mutual availability computation (find free slots across merged calendars)
- Scheduling links: generate OCapN-addressable booking capabilities
- Push notifications on calendar changes (via OCapN messages)

### Phase 6: Advanced Scheduling
- Drag-and-drop intents onto calendar (mousedown/move/up FFI)
- Recurring event rules (RRULE-compatible)
- Conflict detection and resolution
- Auto-scheduling suggestions (find optimal time for N participants)
- Time zone support (VTIMEZONE, display conversion)
