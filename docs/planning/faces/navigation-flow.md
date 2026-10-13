# Navigation flow — directions, preview, turn-by-turn

_Scoped 2026-10-13. Source: five Google Maps screens (bicycle preview, navigating, navigating with the drawer up, navigating with the drawer holding the step list) set against the playnet map face with its pull-up sheet. Companion to [transport-modes-and-observation](../books/transport-modes-and-observation.md), which owns what a journey means to the ledger; this document owns what a journey looks like and how it moves._

A journey on the map has three postures — **preview**, **navigating**, and **navigating with the drawer up** — and one surface carries all three: the pull-up sheet that already rises over the map. Each posture reshapes the sheet, the map camera and the floating chrome together. This document lists every element of that flow, says which part is built, and sets the stages that build the rest.

Words used throughout: **sheet** is `.share-sheet` (the bottom drawer); **bar** is the floating omnibar capsule; **banner** is the maneuver strip at the top of the map while navigating; **detent** is a height the sheet rests at.

---

## 1. What stands today

### 1.1 Where it lives

The route code is one family in `ui/app/route/`, each module with one job, and one device-position source beside it. The rest is what the family stands on.

| Module | Job |
|---|---|
| `ui/app/route/data.ts` | The one reader of `/route`'s reply: the polyline, a trip as `Route`s (the chosen way and its alternatives, with street names, spoken forms, transit legs), the request a mode asks with, a short-lived shared cache. Also THE table of modes — costing, label, glyph — and the UI-word → costing boundary (`costingOf`). |
| `ui/app/route/facts.ts` | What a route says, in words, pure: durations and distances (`fmtMinutes`, `fmtDistance`), the headline, the lines a transit route rides, the arrival clock (`arrivalClock`), ⇅ (`swapEnds`), and the trip the REPL page's Scheme side takes (`replTrip`). |
| `ui/app/route/lines.ts` | A route on the map: the one place its lines are drawn — the chosen way, its alternatives, what is behind you, a ride's dotted walks, the bearing thread. One source, one set of layers, mounted style-ready like `journeys.ts`. |
| `ui/app/route/preview.ts` | The ways to a place before you set out: the from/to card, the sheet view (owner `"route"`), the mode tabs, the time pills, the camera frame, Start. |
| `ui/app/route/nav.ts` | The wayfinder: a journey under way — its record, the ledger's `journeyBegin` / `journeyEnd`, and the orchestration of what reads it. |
| `ui/app/route/shape.ts` | The geometry of a route's shape, pure: its runs by mode, where you are ON it (`snapToRoute`, `progress`), a point along it, the box that holds every way, where a time pill sits. |
| `ui/app/route/banner.ts`, `sheet.ts`, `steps.ts`, `follow.ts`, `drive-sim.ts` | The journey's face: the card's words, the sheet with its drawer, the turn-by-turn list, the camera, the rehearsed drive. |
| `ui/app/position.ts` | Where you are, from ONE source: a watch, a one-shot ask, the map's locate button or a rehearsed drive all end in `report`, which moves `USER` and tells every observer (the you-marker among them). |

What the family stands on:

| Piece | Home |
|---|---|
| Entry: `↦ directions` in the selected-place card | `ui/app/tabs/map/mapsearch.ts` → `openRoutePreview` |
| Entry: `↦ go` chip on the places list | `browser/app.html` `#gochip`, wired in `initNav` → `NavHost.directions` |
| Route proxy | `handle-route` and `route-request-json` (`server/serve-static.scm`): `from`, `to`, `via`, `profile`, `alternates`, `depart` / `arrive`, `lang`, `units`; relays Valhalla verbatim, `{}` on any failure |
| Turn card | `#navcard` (`browser/app.html`), its own palette in every theme |
| Place search | `placesNear` (`ui/app/tabs/map/atlas.ts`): the commons' rows and OpenStreetMap's, nearest first — the search list and the preview's two fields read through it |
| Sheet | `openSheetView` / `closeSheetView` / `sheetHeight` / `sheetHolds` (`ui/app/tabs/social/share.ts`) with `{ full, fit, sticky }`; CSS-class detents (`browser/app.html`) |
| Heading | `ui/app/compass.ts` (`deviceHeading`, `needleTap`, 2° deadband); it rotates the map on touch devices only |
| Ledger | the `journey` door, called from `nav.ts` |
| Mode set in the planner | pedestrian · bicycle · auto · bus · multimodal (`module/playnet/solve/routing.scm`) — the engine speaks all five |
| The REPL page | `browser/repl.js` reads Valhalla through `route/data.js` and `route/facts.js` too; its own map drawing (`drawRoute`) is the REPL's alone |

### 1.2 What the five screens show that the map face still lacks

1. A navigating camera: heading-up, tilted, offset so the road ahead has the room. Today the camera frames the route once and never moves again.
2. A top banner with a *Then* chip, a bottom ETA bar, and a set of round buttons at the map's edge. Today one small card carries everything.
3. The sheet changing character with the posture: the ETA bar at a low detent while navigating, then the actions and the step list.

### 1.3 What stage R0 settled

- **The card's palette.** `#navcard` painted a dark surface from `--t-0a101a-rgb` with `--t-ffffff` text. The theme layer (`ui/app/theme.ts`) remaps neutrals by lightness, so under `night` the surface computed to a light grey-blue with near-black text. Navigation chrome now states its own palette — a dark teal surface and white text that every theme leaves alone — the way the Google banner holds its colour in both of its themes.
- **The card's place.** It sat at `bottom: 64px`, `z-index: 6`, under `#sharebar` (`z-index: 30`). Over the map it now floats at the top, `z-index: 35`; the bar and sheet own the bottom edge, and the ETA bar belongs *in* the sheet (§3.2).
- **The mode glyph.** The cycle handler re-routed through `startNav()` and `host.selectedPlace()`, which a journey begun from the search panel does not have. It now re-routes `nav.dest`.
- **The fallback line.** With no engine the card said "no route data" while the stroke looked like a route. The fallback is a bearing: thin, dashed, no casing, with the crow-flight distance.
- **No engine in this checkout.** `.valhalla/` is absent and nothing listens on `:8002`, so every `/route` here answers `{}`; the first screenshot was the fallback path. The route flow is developed against a synthetic engine (§7) and confirmed against a built one.

---

## 2. The Google Maps flow, state by state

Each table lists an element, where it sits, what it shows, and what it does. "Ours" names the home in this codebase; **built** / **new** says whether it exists.

### 2.0 S0 · Place

The map shows a place; the sheet shows its card (name, kinds, location, availability) and a row of actions. Ours: `mapsearch.ts` `drawMarker` — **built**. The `↦ directions` button there becomes the single entry to S1.

### 2.1 S1 · Preview (screen: bicycle)

| Element | Position and look | Behaviour |
|---|---|---|
| **From/to card** | Floating at the top, white rounded rectangle, two rows joined by a dotted vertical connector. Row 1: blue dot + "Your location" in blue. Row 2: red pin + the destination. | Each row is a text field. Tapping a row opens place search (the map's own search panel). Origin defaults to live location. |
| ⋮ (card, right of row 1) | Overflow | Add stop, route options (later). |
| ⇅ (card, right of row 2) | Swap | Exchanges origin and destination and re-routes. A "Your location" origin that swaps to the destination is a legal end: the new origin is the old place. |
| Layers button | Round, under the card at the right edge | Map type and overlays: here a theme/basemap switch (later). |
| **Route lines** | Selected route: deep blue, wide, white casing, origin dot and destination pin. Alternatives: pale blue, same width, drawn beneath. Part of a route that a mode treats specially is recoloured (green for a bike lane). | Tapping an alternative selects it; the sheet summary follows. |
| **Time pills** | On each route, at its widest separation from the others. Selected: filled dark blue, `7 min` + `Best route`. Others: white, `9 min`, `7 min · More bike lanes`. | A pill is the route's tap target. |
| Locate button | Round, bottom-right of the map, just above the sheet | Recentres on you. Ours: the GeolocateControl (**built**, `mapview.ts:329`), lifted by `--barh`. |
| **Sheet header** | Grip, then a title row: mode name (`Bicycle`), tune button, share button, ✕. | ✕ returns to S0 and removes the route. Tune opens route options. |
| **Mode tabs** | One horizontal strip: transit `27 min`, walk `30 min`, bicycle `7 min`, ride-share `6 min`, with an underline on the selected one. The strip scrolls; entries with no route show a dash. | Selecting a tab re-selects the route set. Each tab is its own request. |
| Mode chips | Under the tabs: `Your bike`, `Voi`, `Lime` | Sub-modes of the selected tab (later). |
| **Summary** | Large `7 min (2.2 km)`; one line of facts: `24% bike lanes · Mostly flat`. | Facts come from the route's own data (§4.3). |
| **Actions** | Primary pill `▲ Start`; secondary pill `Add stops`. | Start enters S2. Add stops opens the `via` flow (later). |
| **Camera** | The whole route fits between the top card and the sheet. | `fitBounds` with `padding {top: card height + 16, bottom: sheetHeight() + 16, left/right: 24}`. |

### 2.2 S2 · Navigating (screen: navigating, map full)

| Element | Position and look | Behaviour |
|---|---|---|
| **Banner** | Top edge, full width minus a margin, dark teal, rounded. Left: a large maneuver arrow. Right: distance to the maneuver in large type (`400 m`) and the street name (`Treptower Str.`) in larger type beneath. | Updates every fix. The distance counts down; the instruction advances at the maneuver. |
| **Then chip** | Hangs from the banner's lower-left corner, same colour, narrower: `Then ↰`. | Shows the maneuver after next, only when it follows closely (about 150 m, or 10 s at current speed). |
| **Camera** | Map rotated so travel points up; pitched about 55°; the user arrow sits in the lower third; zoom follows speed (closer when slow, wider when fast). | A fix eases the camera (about 1 s). A drag by the user pauses following. |
| **User arrow** | Blue chevron with a soft halo; the halo grows when the fix is poor. | Replaces the pulsing dot while navigating. |
| **Route line** | Saturated blue with white casing; the part behind you is hidden or dimmed. | Progress masks the line by `nav.at`. |
| **Alternative pills** | `Similar ETA`, `2 min slower` on the alternatives | Tapping one offers to switch (later). |
| **Map buttons** | Right edge, stacked round buttons, top to bottom: compass (recentre/orient), search along route, sound, route overview. | Compass: tap re-follows. Sound: cycles muted / alerts / all. Overview: zooms to the remaining route and returns after a few seconds. |
| **Speed chip** | Bottom-left, round, `-- km/h` while there is no fix | Shows speed (limit data is not available; §2.5). |
| **Report pill** | Bottom-right | Hands to the contest/capture door (later). |
| **Status pill** | Centre, `Searching for GPS…` | Shown until the first fix, and again when fixes stop. |
| **ETA bar** | The sheet at its lowest detent. Left ✕ (round, outlined); centre: grip, `7 min` (large, green when on time), `2.2 km · 17:05`; right: an assistant button. | ✕ ends the journey. The centre is a tap target that raises the sheet. |

### 2.3 S3 · Navigating, drawer up (screen: actions)

The sheet rises to about half the screen; the map keeps the top strip and the banner stays above it. The header (`✕ · 7 min / 2.2 km · 17:05 · assistant`) stays pinned.

| Row | Behaviour |
|---|---|
| Add a report | Hands to the contest/capture door (later) |
| Share trip progress | Shares a live link of the journey (later; ties to the ledger's `journey` door) |
| Search along route | Opens place search biased to the route corridor (later) |
| Directions | Expands the step list (S3b) |
| Show satellite map | Toggle: basemap ↔ satellite (n/a until a satellite basemap exists; `project_basemap_osm_pmtiles`) |
| Settings | Navigation settings: voice, units, avoid-lists (later) |

### 2.4 S3b · Step list (screen: directions)

The sheet at its tallest; the map shows as a thin strip under the banner. Header pinned.

| Element | Behaviour |
|---|---|
| **Current step** | First row, larger: `In 400 meters` / `Turn right onto Treptower Str.`, arrow glyph at the left. |
| **Distance dividers** | Between steps: a thin rule with the distance (`240 m`) at its left. |
| **Step rows** | Arrow glyph · instruction; a warning chip when the step carries one (`Restricted usage road`). |
| **Destination row** | Last row: destination glyph, name, address, and a note (`Destination will be on the right`). |
| Tap a row | Re-centres the map on that maneuver for a moment (later). |

### 2.5 Behaviours beyond the five screens

Each is tagged **v1** (built by R5), **later**, or **n/a**.

| Behaviour | Tag | Note |
|---|---|---|
| Off-route detection and reroute from the present position | v1 (R5) | Distance to the polyline beyond a threshold for N consecutive fixes → re-request from `USER`. The old line is replaced; the banner says `Rerouting…` while the request runs. |
| Recentre after a pan | v1 (R3) | Following resumes after about 10 s of no touch, or on the compass button. |
| Arrival | v1 (R3) | Within about 30 m of the destination: banner `You have arrived`, side of the street if known; ETA bar offers `Done`; `journeyEnd` fires. |
| Live ETA | v1 (R3) | Remaining time = remaining route time × (recent speed ÷ route's modelled speed), clamped; arrival clock from `clockOf`. |
| Screen wake-lock while navigating | v1 (R3) | `navigator.wakeLock`; released on end. |
| Day/night map | v1 | Handled by the theme layer on `playnet:theme`; the banner holds its own palette (§1.3). |
| Transit legs | v1 (R5) | Walk · ride · walk, with line badge, headsign, stops count, board/alight times from `transit_info`; arrival-time requests use `date_time`. |
| Add stops / via | later | The proxy already takes `via=lat,lng;lat,lng`. |
| Switch to an alternative mid-trip | later | Needs alternatives kept alive after Start. |
| Voice guidance | later (R6) | On-device `speechSynthesis` first (`project_ai_at_the_seat`); mute control in the map buttons. |
| Share trip progress | later | The journey commitment id is the natural share key. |
| Report | later | Maps to the contest door; a map-pinned note rather than a crowd-sourced incident feed. |
| Search along route | later | Corridor-biased place search. |
| Speed limits, lane guidance, live traffic, incident feeds | n/a | No data source. The speed chip shows speed only. |
| Offline routing | n/a here | The engine is self-hosted; offline tile packs exist for the basemap only. |

---

## 3. The map onto our system

### 3.1 The state machine

```
idle ──pick place──▶ place ──directions──▶ preview ──start──▶ navigating ──arrive/✕──▶ idle
                       ▲                      │                  │  ▲
                       └──────────✕───────────┘                  ▼  │
                                                          drawer: bar · actions · steps
```

One record holds it: `{posture, origin, dest, modes: Map<costing, Route[]>, mode, routeIx, at, follow, drawer}`. Postures are exclusive; the drawer is a sub-state of `navigating`. Today's `nav: Journey | null` (`nav.ts:153`) is the `navigating` row of this record; the new fields replace its globals (`navProfile`, `navWatch`, `navHome`).

### 3.2 The sheet carries every posture

The sheet is the drawer. It owns one view per posture and the route flow takes the owner name `"route"` (`openSheetView("route", el, gone, full, fit)`, `share.ts:476`).

| Posture | Sheet content | Detent |
|---|---|---|
| place | the place card (owner `"map"`) | fit-to-content (`data-fit`), as today |
| preview | header + mode tabs + summary + actions | fit-to-content |
| navigating, bar | ETA bar only | **new**: *peek* — the grip plus one ETA row |
| navigating, actions | ETA header + action rows | the existing view height (`min(56dvh, 580px)`) |
| navigating, steps | ETA header + step list | `.full`, below the banner |

Required sheet changes:
- A **peek** detent: height of grip + ETA row, with the bar *hidden* during navigation (the bar's search chrome is not part of a drive; Google's bottom edge holds the ETA row alone). The sheet already floats above `--barh`; peek sets a data attribute that zeroes `--barh` for the duration.
- `wireSheet` (`share.ts:524`) picks among *peek / mid / full* by drag distance and fling velocity (it already picks between content-height and full with `FLING = 0.45 px/ms`); the dismiss branch is disabled while navigating, because ✕ is the only exit.
- The sheet publishes its height through `sheetHeight()`; the map pads its camera with it so the user arrow stays visible above the sheet at every detent.

### 3.3 Chrome

| Element | Home | Notes |
|---|---|---|
| From/to card, banner, Then chip | new elements inside the map container (`#maptab`), absolutely positioned, `z-index` 35 (above the share bar's 30, below the 40+ menus) | top inset `max(10px, env(safe-area-inset-top))`; the card and the banner are one slot, since they never show together |
| Map buttons, speed chip, Report pill, status pill | the same container, `z-index` 8 | the map controls (zoom, compass, fullscreen, locate) hide while navigating: the compass moves into the button column |
| Colours | banner: a fixed dark teal with white text (not theme tokens); from/to card and sheet: `--t-*` tokens like the rest of the sheet | see §1.3 |
| Type | banner distance 28–32 px, street 22–26 px; ETA minutes 28 px | thumb-and-glance sizes; the existing `--sans` |

### 3.4 Camera

`ui/app/maplibre.d.ts` types only `{center, zoom, duration}` for `easeTo` and `{center, zoom}` for `jumpTo`; it needs `bearing`, `pitch` and `padding` on both, plus `setPitch`, `getPitch`, `getBearing`, `setPadding`, `rotateTo`. The vendored compass control already calls `easeTo({bearing: 0, pitch: 0})` (`browser/vendor/mapbox-controls.js:88`), so the engine supports them.

- **Follow**: `easeTo({center: you, bearing: heading, pitch: 55, zoom: z(speed), padding: {bottom: sheetHeight() + 24, top: bannerHeight}, duration: 900})` per fix.
- **Heading**: GPS `coords.heading` while moving (speed above about 1 m/s); `deviceHeading()` when still; the route bearing at `nav.at` when neither exists.
- **Preview**: `fitBounds` of the selected route plus alternatives with the paddings in §2.1; pitch 0, bearing 0.
- **Leaving**: ✕ / arrival eases to pitch 0, bearing 0 at the destination.
- Unfollowing: `dragstart` / `rotatestart` sets `follow = false`; the compass button (or 10 s idle) sets it back.

### 3.5 Mode tabs

A tab per costing — `multimodal` (transit), `pedestrian`, `bicycle`, `auto` — each its own `/route` request issued in parallel when the preview opens, cached by `(origin, dest, costing, minute)`. A tab shows `…` while its request is in flight, a minute count when it answers, and a dash when it answers `{}`. The first tab to answer *and* match the last used mode is selected; a stored last-used mode lives with the other UI preferences. The `journey` door already takes the costing name, so the ledger sees whichever mode started.

### 3.6 Reuse

The family (§1.1) is the vocabulary: R3 and R4 add modules to `ui/app/route/` and read through what is there — `data.ts` for routes and modes, `facts.ts` for words and shapes, `lines.ts` for drawing, `position.ts` for fixes (a rehearsed drive is `feed` on that one stream), `placesNear` for names, `openSheetView` / `sheetHeight` for the drawer, `NAV_GLYPH`, `fmtDistance`, `clockOf`, `havKm`, `bearingDeg`, `ARROW8`, `deviceHeading` and the `journey` door. Nothing in R3 reads a geolocation or draws a route line by another road.

---

## 4. Data and server

### 4.1 The route request

`handle-route` reads `from`, `to`, `via`, `profile`. It takes, each optional and each passed to Valhalla in the hand-built JSON (`valhalla-request-json` stays number-and-string-only):

| Param | Valhalla field | Use |
|---|---|---|
| `alternates=N` | `alternates` | up to N extra routes; S1 draws them |
| `depart=ISO` / `arrive=ISO` | `date_time {type 1 / 2, value}` | transit schedules; also "leave at" for other modes (later) |
| `lang=xx` | `directions_options.language` | instruction language |
| `units=` | `directions_options.units` | kilometres by default; miles on request |

The costing sanitiser (`valhalla-costing`) already lets `multimodal` through.

### 4.2 The route shape

`Route` widens to carry what the screens show: per-maneuver `streets: string[]`, `length`, `time`, `verbal` (pre-transition and post-transition), `roundabout_exit`, `travel_mode`, `transit` (`{line, headsign, color, stops, departs, arrives}`), `sign` (exit info), `warnings` (e.g. restricted-usage). A trip carries `legs[]`; a route has `summary {length, time, has_toll, has_ferry}`; alternates arrive as `alternates[]` each with a `trip`. Everything is read defensively: a missing field renders as absent, never as zero.

### 4.3 Route facts

The summary line (`24% bike lanes · Mostly flat`) comes from the route itself: bike share from the edge `cycle_lane` attribute when `trace_attributes` is available (`/trace_route` already relays; a `trace_attributes` relay is the same shape), climb from `elevation` when the tiles carry heights. Where the engine cannot say, the line shows only distance and time. Facts are never invented.

### 4.4 Transit

Valhalla's transit comes from GTFS tiles. `tools/dev/valhalla-local.sh` currently ingests one feed (Sofia), so the SF and Berlin atlas answers `multimodal` with a pedestrian-only route. Transit tabs therefore appear only where the engine returns a transit leg: a request whose reply holds no `travel_mode: "transit"` shows a dash. Stage R5 adds the SF and Berlin feeds to the fetch step.

### 4.5 Degradation

| Engine answer | Tab | Map | Sheet |
|---|---|---|---|
| route | minutes | route line | summary + Start |
| `{}` for the selected mode | dash | a bearing arrow and crow distance | `No route to here by <mode>`; Start disabled; the other tabs stay live |
| `{}` for all modes | all dashes | bearing arrow | `Routing is unavailable here`; a compass-only **Go** that behaves like today's fallback card |

---

## 5. Stages

Each stage ends with `make ui-check`, `make ui`, a UX probe, and `make shot`.

- **R0 · Settle the present** _(built 2026-10-13)_. The banner-palette rule for `#navcard`; the mode-cycle re-routes `nav.dest`; the fallback is drawn as a bearing, not a route. Probe: `tests/ux/navcard-ux.mjs`.
- **R1 · Route data** _(built 2026-10-13)_. The widened `Route` and its one reader (`ui/app/route/data.ts`); proxy params (`alternates`, `depart`, `arrive`, `lang`, `units`); parallel per-mode fetch with a cache; a `/route` stub and a synthetic Valhalla fixture for tests (`tests/ux/route-stub.mjs`, `tests/browser/route-fixture.mjs`).
- **R2 · Preview** _(built 2026-10-13)_. Owner `"route"` in the sheet, `sticky` so a tap on the map picks a way and does not put the sheet away; the from/to card (origin = you until you say otherwise, either end a field that offers the commons' places and OpenStreetMap's, ⇅); mode tabs, each filling as its answer lands, the chosen mode remembered (`pn.map.route.mode`); the chosen way heavy and its alternatives pale, a time pill on each; the camera frames every way between card and sheet; Start. `↦ directions` and `#gochip` both open the preview (`ui/app/route/preview.ts`, pure parts in `ui/app/route/facts.ts`). A journey sets out from where you are, so with another origin Start reads *Start from my location*; with no engine the sheet says so and offers *Go by compass*. The ⋮ menu, the route-options and share buttons and *Add stops* wait for R6. Probe: `tests/ux/route-preview-ux.mjs`, with software WebGL so the page has a real map.
- **R3 · Navigating** _(built 2026-10-13)_. The journey under way on the map face, as one family: `banner.ts` (the card over the map is the maneuver banner — arrow, distance in large type, street — with a *Then* chip when the next turn follows within 150 m), `eta.ts` (the sheet's lowest rest, `peek`: ✕, minutes left, `2.2 km · 17:05`, Done on arrival; the share bar steps aside and reaches nothing), `follow.ts` (heading-up camera tipped 55°, you seated at 68% of the frame, zoom by pace; a hand on the map lets go and it returns after 10 s or on the recentre button; the overview button frames what is left), `drive-sim.ts` (`?simdrive=<factor>` feeds fixes along the way through the one position source). Progress is `snapToRoute` + `progress` in `facts.ts`: where you are ON the way (fractional, with how far off it), time left from the maneuvers' own times. The way behind you is drawn dimmed; the map's controls give way to the camera's two buttons (the attribution stays); the screen is held awake; arrival gives the camera back and offers Done. The compass leaves the map's bearing to the journey while it holds the camera (`cameraHeld`). On the disc the card is as it was. Probes: `tests/ux/route-nav-ux.mjs` (feeds fixes along the stub route; the camera is read as the page has it), `tests/browser/route-nav-test.mjs`, and the `snap`/`progress` cases in `route-facts-test.mjs`.
- **R4 · Drawer** _(built 2026-10-13)_. The journey's sheet (`ui/app/route/sheet.ts`, replacing the ETA-only `eta.ts`) has three rests — **peek** (the row), **mid** (a menu), **full** (the way turn by turn, standing below the banner so the banner stays in view and the grip in reach) — and a swipe up or down, a tap on the grip, or Esc steps through them; the sheet only carries the gesture (`Stepped` in `share.ts`), the view moves itself. The menu is the account sheet's own row builder (`ui/app/sheet-rows.ts`): **Directions ›**, **Travel by ›** (a page of the four modes; choosing one routes the same destination again), **Show the whole way** (lowers the drawer and frames what is left), **End navigation**. The step list (`steps.ts`) runs from the turn ahead to the door: the engine's own sentence and an arrow per row, *In 400 m* on the first, a chip for a toll, gate, rough ground or ferry on the stretch after a turn, the distance to the next turn between rows, the destination last with *Destination will be on the right* (`side_of_street`); it follows you as you go. **Not in R4:** Report, Share trip progress, Search along route, Show satellite map and Settings — each wants a door or a data source that does not exist yet (R6). Probes: `tests/ux/route-nav-ux.mjs` (the rests, the list live, back, the mode page re-routing, swipe, tap, Esc), `tests/browser/route-steps-test.mjs`.
- **R5 · Reroute and transit.** Off-route detection and reroute; transit legs; SF and Berlin GTFS feeds in the engine's fetch step.
- **R6 · Voice and extras (later).** Speech, mute, share trip progress, report, search along route, add stops, mid-trip alternate switching.

---

## 6. Open threads

- **Where the origin field gets its places.** The map's search panel serves destinations; a second, origin-typed use of the same panel should not start a second search stack.
- **Peek and the bar.** The bar steps aside while navigating (§3.2), so voice search is not reachable from the map then. Whether a button in the camera's column brings it back is a question for R4.
- **Transit in the demo.** Until feeds exist for the demo atlas, the transit tab shows a dash. R5 settles feeds.
- **The place card on a phone.** Its actions (`↦ directions`, `save`) stand after the location and availability sections, so on a phone the card is taller than the sheet's room and *directions* sits under the bar until scrolled to. Google puts the one primary action beside the title; the same here would make the way in one tap on any screen.
- **The notice banner takes the footer's last rows.** `#demo-banner` is prepended to `<body>` in flow above a full-height `#main`, so the share bar (`position: absolute; inset: 0` in it) ends 21 px below the screen — the ETA bar's second line is clipped while the notice shows. The same offset is why `share-sheet-ux`, `share-bar-ux` and `face-dock-ux` already fail at the commit before this arc.
- **Heading source on a still phone.** The compass supplies the heading only while it is switched on (`needleTap`); a journey could switch it on at Start where the device has one.

## 7. Verification

- A stub for `/route` (request interception in the UX harness) returning a recorded Valhalla trip, with alternates, for each of `pedestrian`, `bicycle`, `auto`, and a recorded `multimodal` trip.
- `tests/ux/route-flow-ux.mjs`, after `tests/ux/share-sheet-ux.mjs`: from `↦ directions` to preview (tab ETAs, selected route, Start enabled) to navigating (banner text, Then chip, ETA bar, sheet at peek, map buttons present, bar hidden) to drawer up (action rows) to steps (row count equals maneuver count) to ✕ (map restored). Headless chromium has no WebGL, so the probe asserts DOM and camera *options* (via a recorded `easeTo` spy), not tiles.
- Geolocation fed by puppeteer `setGeolocation` stepping along the stub's polyline; the banner distance must fall monotonically and the instruction advance at each maneuver.
- Contrast probe on banner and ETA bar under `day`, `night`, `sepia`, `ink`.
- `make check-ui-fresh` so the committed `browser/*.js` match the sources.
- Against a built engine: `tools/dev/valhalla-local.sh route FROM TO <costing>`, then the same flow in a real browser.

## 8. Non-goals

Live traffic, lane guidance, speed limits and incident feeds have no data source here. The map face does not become a general-purpose navigation product: a journey is a commitment in the ledger (`journeyBegin` / `journeyEnd`) and navigation is how its walker is carried through it.
