// the desire-and-satisfaction dial (figure 3 of docs/social-time.typ),
// grown into an instrument: needs are nested — select one and its band
// expands to fill the whole dial, its children becoming the bands, the
// parent level remaining as a thin ring around the circle. Events ride
// the rim and the calendar beside it; both select each other.
//
// τ-time features (docs/tau-time.typ), with their ValueFlows reading
// (module/playnet/vf/schemas.scm):
//   needs   = standing Intents; their bump curves are smooth temporal
//             expressions (AvailabilityWindow/TimeRange, made continuous)
//   events  = EconomicEvents (action ∈ the 19 VF actions); `serves` is
//             the `satisfies` edge to the Intent it answers
//   rhythm  = per-harmonic resultants R̄_k of a need's share curve (§4-5):
//             peaked spectrum → scheduled provision, flat → standing
//             capacity; anticipation lead = τ∕4k, the quarter-period law
//             (§8), drawn as hollow "begin" marks before each peak
//   chords  = storage as phase displacement (§9): work events' hours
//             travelling around the turn to the desire-peak they satisfy
//   spirals = decay r = R·ρ^(Δ∕24) (§10): equal angles, equal fractions —
//             what one turn of storage costs milk, bread, grain
// pure geometry & math primitives — see app/geom.js
// FIRST, and the order is the point: imports are hoisted and evaluated in
// source order, so the diagnostic ring installs itself while this module's
// own graph is still loading — before any module below it can throw
// (app/diag.js). A call placed among these imports would run after all of
// them and catch nothing.
import './diag.js';
// the seam first: its push forwarders must exist before the spine can call one
import './seam.js';
// a storage write the device refuses is said once, on a card
import './storage-notice.js';
// what this deployment has actually organized so far, said once, as a ribbon
import './demo-banner.js';
// the dial's geometry: sample count, and nothing else main still needs
import { n } from './geom.js';
// pure calendar constants & date/duration formatting — see app/timefmt.js
// shared MUTABLE dial state (S.turnH/S.nowAbs/S.root/… reassigned across modules)
import { S } from './state.js';
// reactive core (signals + effects) — see app/reactive.js. Used for the
// event/plan panels; NOT for the hot per-frame dial state in S.
import { effect } from './reactive.js';
// the shared ground (app/core.js): state and constants every face reads. Held
// there so a face can import them without importing the dial — see core.js.
import { day, markDayChanged, EXT, USER, pcoord, PLACES } from './core.js';
// the day's events and the window they are read through (app/events.js).
import {} from './events.js';
// which of the day's sources are showing — the calendars' checkboxes reach every
// paint site through `pick`, so a hidden source leaves dial, grid, map and panel
// together (app/calendars.js)
import { calsRev } from './calendars.js';
import { facetsRev } from './facets.js';
// The theme maps colours as they enter the DOM by PATCHING d3's attr/style/html
// on import — so this is a side-effect import, and it has to happen before
// anything paints. Nothing is named from it here.
import './theme.js';
// the dial's SPINE: the taxonomy joined to the desire signal, coloured, indexed,
// and rebuilt whenever the planner pushes a new one
import { initSpine, desireFromNeeds } from './spine.js';
// individual ⇄ social: the σ road, what dissolves along it, and the social ring
// of toil that condenses in its place
import { initSigma } from './sigma.js';
// ── the turn's phase arithmetic → app/turn.js ──────────────────────────────
import { turnPos } from './turn.js';
// ── the event ribbons → app/ribbons.js ─────────────────────────────────────
import { initRibbons, drawEvents, selectedEv, selectEvent } from './ribbons.js';
import { reassert, openHereFromUrl } from './gohere.js';
// ── the priority bar → app/pribar.js ───────────────────────────────────────
import { initPriBar, priClear } from './pribar.js';
// ── the hand, and the scrub that walks time → app/hand.js ──────────────────
import { initHand, drawHand, handNow, scrubWin, isScrubbing, homeHand } from './hand.js';
// ── the named turns → app/scales.js ────────────────────────────────────────
import { SCALES, turnSym } from './scales.js';
// ── the rim, and the marks that say what a turn is → app/chrome.js ─────────
import { initChrome, drawChrome, updateChromeTargets } from './chrome.js';
// ── the earth, revealed → app/earth.js ─────────────────────────────────────
import { revealEarth, exitEarth } from './earth.js';
// ── the scale of the turn → app/turnscale.js ───────────────────────────────
import { initTurnScale, setTurn, syncScaleIdx } from './turnscale.js';
// ── the faces → app/faces.js ───────────────────────────────────────────────
import { initFaces, setFace, openFaceFromUrl, refitFace } from './faces.js';
// ── the wheel, and the τ-time readings drawn on it ──────────────────────────
import { initWheel, settle, zoomIn, zoomOut, previewChildren } from './wheel.js';
import { showRhythm, drawChords, drawSpirals } from './rhythm.js';
// ── the day's lists, the selected event's card, and the five answers ────────
import { drawCal } from './day/respond.js';
// your own time: the availability ring and the personal-events ring, over the
// one machine in app/ring.js — and the NET availability the planner is told
import { initMyTime, deselectRings, newEventNow, syncAvailability } from './day/mytime.js';
// the inbound seam: the planner's snapshot becomes the dial's day
import { initIngest } from './ingest.js';
// the planet beneath the bands: the orthographic globe centred on you, its two
// coastline resolutions, and the scale it hands over to the satellite at
import { mountGlobe, drawGlobe, landReady, S0, sFinal } from './globe.js';
// how the dial is ARRANGED right now — which face, dial or earth, what the
// earth is lensed through, where the hand stands. Six modules read these, so
// they are a shared record rather than six host members forwarding the same
// four facts (app/stage.js).
import { stage, onMapFace, mapUp } from './stage.js';
// the bearing dial: pointer arcs to what the disc cannot show, and the walking
// isochrones inside it (app/threads.js)
import { initThreads, drawEarthArcs, drawThreads, bearingTo } from './threads.js';
// the satellite fabric: the instance, its two framings, and the one observer
import { initMapView, openMap, theMap as map, sizeMap, fitMarkersAroundUser, WALK_ZOOM, moveUserMarker } from './mapview.js';
// the circle that map takes when you zoom into a place from the dial
import { disc, mapR, mapRadiusPx } from './disc.js';
// the phone as a compass, and knowing where you are
import { initCompass } from './compass.js';
// the containment forest the overlay nests and tints (app/regions.js)
import { initRegions, refreshContainers } from './regions.js';
// raising your hand for work: one id for the same slot seen four ways
import { initWillingness, isWilling } from './willingness.js';
// where a classification is met — the list, the card, and what each rail affords
import { initPlaces, showPlacesPanel, selectPlace, selectedPlace, renderPlaceCard, refreshTags } from './places.js';
// the sun at your latitude on this day, and the sky it paints around the rim
// the scope's recipe library and its two indexes — a recipe declares what it
// PRODUCES, which is what turns a flat list into a walkable graph
import { initRecipeGraph, setRecipes, recipes as scopeRecipes } from './recipe-graph.js';
// the plan column: the ledger, the need list, and the recipe card it drills into
import { initPlanColumn, closeRecipeCard } from './plan-column.js';
// one renderer for everything on the map — places, offers, drop points and the
// pool, clustered in world pixels so a pan never re-renders (app/markers.js)
import { initMarkers, renderMarkers } from './markers.js';
// the editable ring of arcs (app/ring.js): one machine, drawn twice — plus the
// hours it is drawn in and the interval algebra net availability rests on
import { initRings } from './ring.js';
// the offer field (app/offers.js): every offer with a place, tiered by how it
// relates to you, and the two questions the rim and the map both ask of it
import { seedMapAll } from './offers.js';
// the ground under the map: OpenStreetMap from this origin, styled through the
// theme (app/basemap.js)
// which commune the whole UI reads (app/scope.js), and the header breadcrumb
// that shows it beside the taxonomy focus (app/crumb.js)
import { scopeSig, scopesSig, recallScope } from './scope.js';
import { initCrumb, drawCrumb } from './crumb.js';
// the playnet scroll and the keep inside it (app/scroll.js) — a paper popup
// over whatever face is up, touching no dial state at all
import { initScroll, openScroll } from './scroll.js';
// the orb: hold-to-speak, on-device transcription, the gateway's AI, and the
// dial serialized as the context it thinks inside (app/orb.js)
import { initOrb } from './voice/orb.js';
// the dial as a small JSON for thin renderers — widgets, watch faces, e-ink
// (app/projection.js)
import { initProjection } from './projection.js';
// the commons' own wayfinder (app/route/nav.js): /route → the local Valhalla engine,
// one turn at a time on a card, degrading to a compass beyond the atlas
import { initNav, endNav, navigating, placeAt, cameraHeld } from './route/nav.js';
import { openRoutePreview } from './route/preview.js';
// the offline side of the seam: the demo spine, its desire signal, the recipe
// library, the per-commune plans and the bioregional clusters — every one in the
// SAME SHAPE the live wire sends (app/demo.js)
import { TAXONOMY as TAXONOMY_DEMO, DEMO_DESIRE as DESIRE_DEMO, OPEN, DEMO_RECIPES, DEMO_RECIPES_DE, DEMO_NEEDS_CA, DEMO_NEEDS_DE, DEMO_SCOPE_PLAN } from './demo.js';
// the desire tree read as BAND GEOMETRY (app/bands.js): σ and the two stamping
// passes it flattens toward, the cumulative edges layout() hands the renderer,
// and the harmonics that read a band's share curve back as rhythm.
import { stampMeans, stampEnvelopes, layout } from './bands.js';
// ── the canvas → app/layers.js ─────────────────────────────────────────────
// The svg, every layer on it in z-order, the rim, and the viewBox that breathes
// with the dial. Seven modules draw into those layers and read them there.
import { svg, L } from './layers.js';
import { updateDateRow } from './daterow.js';
// ---------------------------------------------------------------- data
// each need: a priority curve (base + wrapped gaussian bumps) and a
// satisfaction curve — and children, which subdivide ITS share of the
// hour with curves of their own.
//
// THE SEAM: when the dial runs with its capability spine (day-boot.js +
// day-boot.wasm — gateway CapTP, KERI login, lobby transcribe/ai), real
// data and handlers arrive via seam.data / seam.handlers.
// day-boot MUTATES these objects in place after the wasm connects, so we
// capture the OBJECTS (late-arriving handlers are seen at call time).
// ── The taxonomy: the dial's spine ───────────────────────────────────────
// Each node is a CLASSIFICATION TERM — ValueFlows `resourceClassifiedAs`
// (schemas.scm) — addressed by a stable `id` (its taxonomy path) and shown
// by `label`. The real taxonomy arrives via EXT.taxonomy; app/demo.js holds
// the standalone tree that stands in, and the signal over it.
const TAXONOMY = EXT.taxonomy || TAXONOMY_DEMO;
// The desire signal over that spine: per-classification phase curve and
// met/quality curve, keyed by taxonomy `id`. Structure stays SEPARATE from
// signal on both sides of the seam, so either can be swapped alone.
const DEMO_DESIRE = EXT.desire || DESIRE_DEMO;
// Join taxonomy + desire-signal into the working tree the dial renders. Each
// node keeps its classification `id`; `name` is the label the renderer uses;
// the curve is pulled from the signal table (a gentle default where absent,
// so an unseen classification still renders).
// The taxonomy and the desire signal are JOINED into the working tree by
// app/spine.js — which also colours it, indexes it, and rebuilds it whenever
// the planner pushes a new one.
initSpine({
    afterRebuild: () => {
        if (stage.mode !== "dial") {
            stage.mode = "dial";
            stage.leaf = null;
        }
        stage.focus = S.root;
        selectedEv.set(null);
        stage.cums = layout(S.root.children || []);
        settle();
    },
    // a re-shaped tree, same root: keep where you are and redraw it
    redraw: () => { stage.cums = layout(stage.focus.children || []); settle(); },
}, TAXONOMY, DEMO_DESIRE);
// events in ValueFlows terms (module/playnet/vf/schemas.scm):
// each is an EconomicEvent — `action` from the 19 VF actions; `serves`
// names the standing Intent (a need below) it `satisfies`. Work events
// are crystallised hours travelling forward around the turn: the chord
// from production-phase to the desire-peak they answer.
// each event also happens SOMEWHERE (`at`, an offset from you, like the
// places): in earth mode the day's events re-organize around the circle
// work-intents you are ELIGIBLE for but not (yet) offered to you — the
// planner's FIELD OF ELIGIBILITY. The planner (live.scm / plan-scope)
// matches an agent to a work-intent when three things hold: skill
// CONFORMANCE (you hold the required skill directly, or the components of
// some `satisfied-by` clause at ≥ its validated hours — effective-skills);
// availability WINDOW intersect (your offered hours meet the demand's); and
// ------------------------------------------------------------- contacts
// KERI contacts (module/playnet/ui/contacts.scm): an alias bound to an AID,
// ── The rails a classification's economic resources sit on ───────────────
// A priority over a classification (the dial) is REALISED at a place, in a
// window of the turn: the temporal coordinate of the spatial thing. The demo's
// hours are in app/demo.js; anything unlisted is open the whole turn.
for (const ps of Object.values(PLACES))
    for (const p of ps)
        p.open = OPEN[p.name] || [[0, 24]];
// the unlensed "map" tab's sentinel leaf aggregates every place (app/offers.js);
// seeded here, once the places above are fully formed
seedMapAll();
// compass bearing you → there, degrees clockwise from north: in earth
// mode this replaces the hour as the dial's angular coordinate
// isOpenAt / WALK_KMH — the machine-readable side of `when`, and the map's
// radial unit — live with the places they describe (app/places.js)
// σ (individual ⇄ social) and the phase-averages it flattens toward: the
// pass that stamps them, and the band geometry that reads them back, are
// app/bands.js. Stamped here because this is where the tree is built.
stampMeans(S.root);
// ------------------------------------------------ the scale of the turn
// one turn of the dial = ONE PERIOD, and the period is pinchable: an
// hour, a day, a week, a year. Desire lives on the torus day × week ×
// year; each rhythm becomes visible at its own scale and is averaged
// away above it (240 samples of a year cannot carry the day-pulse, so
// the day-pulse hands over to its mean — no aliasing, only structure).
// ── the date above the clock → app/daterow.js ──────────────────────────────
// Which window the dial is showing, named in that scale's own units, and the
// picker that moves it. The hand asks for the repaint; the module owns the rest.
// the weekly and seasonal envelopes a term inherits down the spine, and how
// much of each pulse survives at this scale — app/bands.js
stampEnvelopes(S.root);
// -------------------------------------------------------------- canvas
// the view extent breathes with the dial: rim + context rings + chrome +
// two event lanes must always fit — nothing is ever clipped
// ── the canvas → app/layers.js ─────────────────────────────────────────────
// The svg, every layer on it in z-order, the rim, and the viewBox that breathes
// with the dial. Seven modules draw into those layers and read them there.
// ── the two editable rings: availability (blue) + personal events (yellow) ──
// One machine, two instances — draw/drag/resize/select, a recurrence day-picker
// and a this-day/every-day delete prompt, differing only in config. The machine
// is app/ring.js; what follows is the pair of configs that shape it, and the
// planner seam it saves through.
//
// EDITS ARE OFFERED IN THE SETTLED DAY VIEW ONLY: off the day scale, or
// mid-scrub, or mid-morph, the geometry is not stable, so an arc dragged now
// would mean something else by the time you let go.
initRings({
    steady: () => stage.mode === "dial" && Math.abs(S.turnH - 24) < 0.5 && !isScrubbing() &&
        (typeof S.morphU === "undefined" || S.morphU >= 1),
    storageKey: () => {
        try {
            const h = idHint && idHint();
            return (h && h.aid) || null;
        }
        catch (_) {
            return null;
        }
    },
    sync: syncAvailability,
});
// availability ring (light-blue) — always recurring; no title, no commit.
// The two rings and everything about them — the configs, the net-availability
// push, the hydrate, and the exclusive selection — are app/mytime.js.
initMyTime({
    redrawRibbons: () => drawEvents(),
    redrawCard: () => drawCal(),
    clearEventCard: () => selectedEv.set(null),
});
svg.on("click.ringsel", deselectRings);
// "+ new" in the calendar header → a fresh own event at ~now, opened for editing
d3.select("#newevent").on("click", (e) => { if (e)
    e.stopPropagation(); newEventNow(); });
// ---------------------------------------------------------------- state
// The dial's ARRANGEMENT — which node it is showing and that node's live
// layout — is app/stage.js, where the hand, the bar, the reveal and a rescale
// all read it without being handed it. Seeded here, once the tree exists.
stage.focus = S.root;
stage.cums = layout(S.root.children || []);
// ── the wheel → app/wheel.js, and its temporal readings → app/rhythm.js ──
// The bands and every way of moving through them; the rhythm glyph, the chords
// and the decay spirals. Both are handed their layers and own everything else.
// A childless band has no finer subdivision in time, so its answer is a WHERE.
// That is the dial's arrangement talking, not the wheel's drawing — which is
// why the wheel asks rather than importing the reveal.
initWheel({ onLeaf: revealEarth });
// ── the plan column → app/plan-column.js, over app/recipe-graph.js ────────
// The scope's recipe LIBRARY and its two indexes (by id, by output spec) are
// the graph; the ledger, the need list and the recipe card that drills out of
// it are the column. Split because the plan face and the recipes face want the
// graph and not the drawing.
initRecipeGraph();
initPlanColumn();
// ── the rim and its marks → app/chrome.js ──────────────────────────────────
initChrome({ afterResize: () => { if (mapUp())
        sizeMap(); } });
// ── the hand → app/hand.js ─────────────────────────────────────────────────
// The hand, the scrub that walks time with it, and the radian construction.
// The dial answers only what follows the viewed instant without being it: the
// date header above the clock, and the decay spirals.
initHand({
    afterMove: (now) => { updateDateRow(); drawSpirals(now); },
});
// the time-view as a SPECTRUM: the hand reading the band-shares at this
// instant IS a distribution over needs — and the dial's rim marks
// (D∕2, D∕3, D∕4 …) are the overtone series. the spectrum hands the
// ambient engine exactly that: the hour, the social blend σ, the
// current period, and the live need-shares (name · colour · share)
// where the hand crosses. ambient.js turns the shares into the
// partials of one tone — the day's needs become its harmonics.
provideSpectrum(() => {
    const t = stage.hand;
    const hi = Math.max(0, Math.min(n, Math.round(t / 24 * n)));
    const cs = (stage.cums[hi] && stage.cums[hi].cum) || [];
    const bands = (stage.focus.children || []).map((d, k) => ({
        id: d.id, name: d.name, col: d.col,
        share: Math.max(0, (cs[k + 1] ?? 0) - (cs[k] ?? 0)),
    }));
    return { t, sigma: S.sigma, turn: turnSym(), turnH: S.turnH, bands };
});
// ── the priority bar → app/pribar.js ───────────────────────────────────────
// The bar owns the stack, the hold-to-look gesture and where a tap goes. The
// dial answers what only it knows: where the focus is, and what each kind of
// jump actually does to the wheel.
initPriBar({
    preview: (d, k) => { if (d.children)
        previewChildren(d, k); showRhythm(d, k); },
    clearPreview: () => L.prev.selectAll("*").remove(),
    // a lateral or ancestor jump: a branch becomes the focus, a leaf reveals its
    // earth, and tapping where you already are goes all the way out to the root.
    goto: (node) => {
        if (!node || stage.zooming)
            return;
        priClear();
        if (node === stage.focus) {
            if (stage.focus === S.root)
                return;
            stage.focus = S.root;
            stage.cums = layout(S.root.children || []);
            settle();
            return;
        }
        if (!node.children) {
            const par = node.parent, k = (par.children || []).indexOf(node);
            if (stage.focus !== par) {
                stage.focus = par;
                stage.cums = layout(stage.focus.children || []);
            }
            settle();
            revealEarth(node, k);
            return;
        }
        stage.focus = node;
        stage.cums = layout(stage.focus.children || []);
        settle();
    },
    open: (k) => {
        const d = (stage.focus.children || [])[k];
        if (!d || stage.mode !== "dial" || stage.zooming)
            return;
        priClear();
        if (d.children)
            zoomIn(d, k);
        else
            revealEarth(d, k);
    },
    reveal: revealEarth,
    exit: (after) => exitEarth(after),
});
// ── the earth, revealed → app/earth.js ─────────────────────────────────────
// The planet is drawn ALL ALONG, under the bands (app/globe.js). Revealing the
// earth does not build it; it fades the pigment off what was already there,
// which is why the reveal reads as an uncovering rather than a transition.
mountGlobe(L.globe, L.defs);
// ── the satellite fabric → app/mapview.js ─────────────────────────────────
// The map instance and the ONE observer that re-welds it. Where it sits is a
// framing: the DISC (app/disc.js) and the map FACE's rectangle (app/mapface.js)
// own separate elements and never share one, which is why a switch between
// them rebuilds the instance and carries the camera across.
initMapView({
    restage: () => drawThreads(),
    // a sidebar drag reshapes the stage without a window resize, so the live face
    // re-fits from here too — through the same table entry, so the two signals
    // cannot disagree about which faces answer them
    otherFaceReflow: refitFace,
});
// the day's offers, in space — three tiers, each at its own `at`, so the
// outer-arc bearing and the map marker are the same point:
//   day      — your day's events (what you're doing)        solid dot
//   offered   — proposals directed at you (awaiting yes)     hollow ring
//   open      — work-intents you're ELIGIBLE for, not yet    dashed ring
//                offered; click to OFFER WILLINGNESS
// coloured by kind (work = blue, free = gold). A separate marker array from
// the leaf's places, so place selection indexing stays intact.
// fitMarkersAroundUser — framing the map around you — is in app/mapview.js
// which offers belong to this lens and this turn — the offer field the rim and
// the map both read, in app/offers.js
// ── Markers, clustered → app/markers.js ─────────────────────────────────
// One renderer for places, offers, drop points and the pool. What it needs from
// the dial is below and nothing else; `placeEl` moved with it, since the render
// is the only thing that fills it.
initMarkers({
    map: map,
    selectedPlace: () => selectedPlace(),
    selectPlace: i => selectPlace(i),
    selectedEv: () => selectedEv.peek(),
    selectEvent: ev => selectEvent(ev),
    isWilling,
    afterRender: () => { if (stage.mode === "earth")
        drawEarthArcs(); }, // off-view fades
});
// ── places, by proximity → app/places.js, over app/willingness.js ─────────
// The list and the card that speaks for the selected one. Willingness is its own
// leaf below it, because the map's dots, the rim's proposals and this card are
// three renderings of one work-intent and must agree about its name.
initWillingness({
    lensId: () => stage.leaf ? stage.leaf.id : null,
    // every surface keyed off the `offered` set: the list's tags, the open card,
    // a selected event's card, and the map's offer markers
    afterToggle: () => {
        refreshTags();
        if (selectedPlace() >= 0)
            renderPlaceCard();
        else if (selectedEv.peek())
            drawCal();
        if (map())
            renderMarkers();
    },
});
initPlaces({
    bearingTo: p => bearingTo(p),
    markersChanged: () => { if (map())
        renderMarkers(); },
    arcsChanged: () => drawEarthArcs(),
    frame: p => {
        const m = map();
        if (!m || !stage.leaf)
            return;
        if (p) {
            const q = pcoord(p);
            m.flyTo({ center: [q.lng, q.lat], zoom: 14.5, duration: 700 });
        }
        else
            fitMarkersAroundUser();
    },
    restage: () => { if (mapUp()) {
        sizeMap();
        drawThreads();
    } },
    quietCard: () => drawCal(),
    endJourney: () => { if (navigating())
        endNav(); },
});
// ------------------------------------------------- directions, watch-glance
// the wayfinder itself is app/route/nav.js; what it needs from the dial's current
// arrangement is the NavHost below, and nothing else.
initNav({
    map: map,
    mapRpx: () => mapRadiusPx(),
    // the card lives in flow under the dial, so showing or hiding it reshapes
    // the stage and the map disc must be re-welded to it
    restage: () => { if (mapUp()) {
        sizeMap();
        drawThreads();
    } },
    selectedPlace: () => stage.leaf ? placeAt(stage.leaf.id, selectedPlace()) : null,
    directions: (dest, name) => openRoutePreview(dest, name),
});
// you are the centre: geolocation, asked once, recenters everything
// you are the centre: geolocation, asked once — app/compass.js
// ── the bearing dial (earth mode) → app/threads.js ────────────────────────
// In earth mode the dial's angle means the COMPASS BEARING from where you
// stand. The pointer arcs are absences — a place has one only while its marker
// is off the disc — and the isochrones are true walking distances, measured
// through the projection rather than assumed.
initThreads({ discR: mapR });
// ------------------------------------------ the phone as a compass (the needle)
// device orientation, where granted: your heading becomes the top of the
// dial — turn on your heel and the events and places wheel around you,
// each arc standing in the true direction of the thing it names.
// the phone as a compass, and where you are → app/compass.js
initCompass({
    // the phone turns the map — unless a journey holds the camera, which turns it itself (app/route/follow.ts)
    setBearing: deg => { const m = map(); if (m && !cameraHeld())
        m.setBearing(deg); },
    redrawBearings: () => { drawEarthArcs(); drawEvents(); drawChrome(); },
    // GPS arrived: glide to it (a hard jump reads as a teleport), re-bake the
    // demo fabric around you once, and re-sort the places list by the new
    // distances. openMap() re-fits the camera around the (now-correct) user, so
    // gohere reasserts the reader's own destination on top — otherwise the
    // generic re-fit silently wins the race and the camera lands somewhere the
    // reader never asked for.
    arrived: () => {
        if (!mapUp())
            return;
        const m = map();
        if (m) {
            m.easeTo({ center: [USER.lng, USER.lat], zoom: WALK_ZOOM, duration: 1400 });
            moveUserMarker();
            openMap(); // the framing it already stands in
            reassert();
        }
        if (stage.leaf)
            showPlacesPanel(stage.leaf);
    },
});
// the map full screen (⛶) → app/mapview.js
d3.select("#backchip").on("click", () => exitEarth());
d3.select("#mapback").on("click", () => exitEarth());
window.addEventListener("keydown", e => {
    // an Escape the bar's sheet already answered (closing a menu, the inventory, a result list) is spent
    // The map FACE has no dial to rise back to — the tab bar is the way out — so there Escape belongs to the
    // sheet and nothing else.
    if (e.key === "Escape" && !e.defaultPrevented && !onMapFace()) {
        if (stage.mode === "earth")
            exitEarth();
        else
            zoomOut();
    }
});
// the window resize and the stage's own reflow both re-weld the map disc; one
// observer in app/mapview.js does it, rather than the two that lived here.
// ── the event ribbons → app/ribbons.js ─────────────────────────────────────
// The rim's arcs, their lanes, the in-place edit and the selection signal every
// view follows. The dial answers only what it alone knows: where the rim is,
// what the hand has erased, and what else repaints when a ribbon is edited.
initRibbons({
    scrubWin,
    wiping: isScrubbing,
    afterEdit: drawCal,
});
// ── the day's lists, the card, and the five answers → app/respond.js ──────
// ── contacts book panel → app/tabs/contacts.js
import { initInventory } from './tabs/inventory.js';
import { openCaptureCode, initCapture } from './capture.js';
import { connectIn } from './connect-link.js';
import { propose } from './connect.js';
import { initCalendar } from './tabs/calendar.js';
// ── the event/network chat sheet + walkie-talkie → app/tabs/chat.js
import { initChat } from './tabs/social/chat.js';
import { mountRoomDoor, networkTopic } from './voice/room.js';
import { initLiveDock } from './voice/dock.js';
import { initRoomChips } from './voice/roomchip.js';
// Selecting is a write, not a broadcast (app/ribbons.js owns it). The panels,
// the rim, the week grid and the map each read `selectedEv` in their own effect
// and follow it — none of them is named at the write.
// ── scope, and the header that shows it ─────────────────────────────────────
// WHICH commune you are in is app/scope.js — a reactive signal the whole UI
// subscribes to, with the seam's scope accessor over it. HOW the header draws it is
// app/crumb.js: the wordmark, the scope path, the ＋ picker, and the taxonomy
// focus below the root. The focus chain is the dial's own, so it arrives
// already resolved to what each segment says and what tapping it does.
initCrumb({
    focusChain: () => {
        const tax = [];
        for (let x = stage.focus; x && x !== S.root; x = x.parent)
            tax.unshift(x);
        if (mapUp() && stage.leaf)
            tax.push(stage.leaf);
        return tax.map((nd, i) => ({
            name: nd.name,
            go: i === tax.length - 1 ? null : () => {
                if (stage.zooming)
                    return;
                if (stage.mode === "earth")
                    exitEarth(() => { if (nd !== stage.focus)
                        jumpTo(nd); });
                else if (onMapFace()) {
                    setFace("time");
                    jumpTo(nd);
                } // the dial is a face away
                else
                    jumpTo(nd);
            },
        }));
    },
    closeRecipeCard: () => closeRecipeCard(),
});
// ── the playnet scroll (paper popup: about + code + chat) ────────────────────
// and the KEEP inside it — the two ways to keep the server running. Neither
// touches dial state, so both live in app/scroll.js and the wordmark opens the
// scroll by importing one function.
initScroll();
function jumpTo(anc) {
    if (stage.focus.parent === anc) {
        zoomOut();
        return;
    }
    while (stage.focus.parent && stage.focus.parent !== anc)
        stage.focus = stage.focus.parent;
    stage.cums = layout(stage.focus.children || []);
    zoomOut();
}
// a gated action came back needs-personhood → point the user at verification
// ── individual ⇄ social (σ) → app/sigma.js ────────────────────────────────
// What dissolves as σ leaves "you" — your events, proposals and chords — and
// what condenses in the very lane they occupied: the blend of work and free
// time across everyone, hour by hour.
initSigma({
    personal: () => [L.events, L.chords, L.spiral],
    relayout: () => { if (!stage.zooming) {
        stage.cums = layout(stage.focus.children || []);
        settle();
    } },
});
d3.select("#chords").on("change", drawChords);
d3.select("#overlay").on("change", function () {
    const on = this.checked;
    containers.setVisible(on);
    if (on)
        refreshContainers();
});
d3.select("#spirals").on("change", () => drawSpirals(stage.hand));
d3.select("#rosebox").on("change", function () {
    const on = this.checked;
    d3.select("#rhythmrow").style("display", on ? "block" : "none");
});
// the header's ⚙ is the door into settings, on every face — the box of dial views
// lives in there now (adopted, not copied), beside every other knob the site has.
// The same button shuts it again: it reads lit (.on) while settings are open.
d3.select("#setbtn").on("click", () => (settingsOpen.peek() ? closeSettings() : openSettings()));
// the header's 📜 is the door into the scroll (about + links + the spec
// download) — the wordmark itself no longer opens it (crumb.ts), so this is
// the scroll's one way in.
d3.select("#scrollbtn").on("click", () => openScroll());
let timer = null;
d3.select("#live").on("change", function () {
    homeHand(); // re-home the hand on any live flip
    if (this.checked) {
        const tick = () => {
            const d = new Date();
            const y0 = new Date(d.getFullYear(), 0, 1);
            S.nowAbs = (d.getTime() - y0.getTime()) / 3600000; // absolute hours into the year
            drawHand(handNow());
            if (isScrubbing())
                drawEvents(); // a tick mid-scrub keeps the window true
        };
        tick();
        timer = setInterval(tick, 10000);
    }
    else {
        if (timer)
            clearInterval(timer);
        timer = null;
        S.nowAbs = 155 * 24 + 6.0;
        drawHand(turnPos());
    }
});
// live by default: the dial opens on the actual now (the checkbox ships
// checked; this fires the same path as a user toggle)
d3.select("#live").dispatch("change");
// The dial views are settings, and a setting that forgets itself is a lie: keep
// them per device. They stay plain inputs the dial reads by id — this is one
// small layer of memory over the SAME nodes, not a second source of truth, so
// restoring is just setting the box and firing the change every handler above
// already listens for.
const VIEW_TOGGLES = ["live", "chords", "spirals", "radian", "rosebox", "overlay"];
{
    const KEY = K.dialViews;
    const saved = readJSON(KEY, {});
    for (const id of VIEW_TOGGLES) {
        const el = document.getElementById(id);
        if (!el)
            continue;
        if (typeof saved[id] === "boolean" && saved[id] !== el.checked) {
            el.checked = saved[id];
            d3.select(el).dispatch("change");
        }
        el.addEventListener("change", () => {
            saved[id] = el.checked;
            writeJSON(KEY, saved);
        });
    }
}
// ── the scale of the turn → app/turnscale.js ───────────────────────────────
// Pinch, scroll, or click a name: the turn rescales and the desires redraw as
// desire over THAT period. The dial answers only what it owns — the layout, and
// whether something else is already animating.
initTurnScale();
// ------------------------------------------------------------------ boot
// deep links: ?focus=nourishment opens zoomed into that need;
// ?turn=hour|day|week|year (or a number of hours) sets the turn's scale
{
    const tw = new URLSearchParams(location.search).get("turn");
    if (tw) {
        const named = SCALES.find(s => s.label === `one ${tw}`);
        const h = named ? named.h : parseFloat(tw);
        if (h > 0) {
            setTurn(h); // clamps and re-lays-out
            syncScaleIdx(); // land the strip on whichever name this turn is nearest
        }
    }
    const want = new URLSearchParams(location.search).get("focus");
    if (want) {
        const find = (nd) => nd.name === want ? nd : (nd.children || []).map(find).find(Boolean);
        const hit = find(S.root);
        if (hit && hit.children) {
            stage.focus = hit;
            stage.cums = layout(stage.focus.children || []);
        }
        else if (hit) { // a leaf: open straight onto the earth
            stage.focus = hit.parent;
            stage.cums = layout(stage.focus.children || []);
            const k = (stage.focus.children || []).indexOf(hit);
            if (new URLSearchParams(location.search).has("instant")) {
                // skip the fall: land directly on the satellite (debug/dev)
                stage.mode = "earth";
                stage.leaf = hit;
                stage.leafK = k;
                landReady.then(() => {
                    for (const grp of [L.bands, L.seams, L.hand, L.centre, L.spiral])
                        grp.attr("opacity", 0);
                    drawGlobe(sFinal(), 0, 1, true);
                    openMap(disc);
                    drawCrumb();
                    showPlacesPanel(hit);
                });
            }
            else
                setTimeout(() => revealEarth(hit, k), 400);
        }
    }
}
updateChromeTargets();
settle();
drawCal();
initInventory(); // seeds the stock + starts the inventory / shopping effects
// a label's link opens on the thing it names: ?label=<code> (app/capture.ts)
{
    const label = new URLSearchParams(location.search).get("label");
    if (label)
        openCaptureCode(label);
}
// a person's link opens on their card in Contacts: ?connect=<identifier> (app/connect.ts)
{
    const link = connectIn(location.href);
    if (link)
        propose(link);
}
initChat(); // starts the reactive #evchat effect
// initCalendar() is wired LOWER — after `stage.face` is initialized — because its
// effect reads stage.face on its first (synchronous) run.
// the day's views track the `day` notifier: after any commit/decline/release/
// reconsider or a fresh snapshot (markDayChanged), the calendar + proposals
// panel always redraws, and the rim events + provision chords redraw when the
// dial face is showing (and not mid-zoom). Adding a new day-dependent view is
// just another effect here — the actions don't need to know about it.
effect(() => { day(); drawCal(); }); // reads selectedEv() through evCls
// the map reflects the selection too — its own effect, so the dial's event code
// no longer reaches across into map rendering to keep the markers honest.
effect(() => { selectedEv(); if (mapUp() && map())
    renderMarkers(); });
effect(() => { day(); selectedEv(); if (!stage.zooming && stage.mode === "dial")
    drawEvents(); });
effect(() => { day(); if (!stage.zooming && stage.mode === "dial")
    drawChords(); });
// the rhythm corner wakes with the heaviest band's pulse (hover/tap any
// band to retune it)
{
    let bi = 0, bm = -1;
    for (let j = 0; j < (stage.focus.children || []).length; j++) {
        let m = 0;
        for (let i = 0; i < n; i++)
            m += stage.cums[i].cum[j + 1] - stage.cums[i].cum[j];
        if (m > bm) {
            bm = m;
            bi = j;
        }
    }
    const band = (stage.focus.children || [])[bi];
    if (band)
        showRhythm(band, bi);
}
// ── identity: the door into the plan → app/tabs/id.js
import { idHint } from './tabs/social/id.js';
// ── THE SEAM, inbound → app/ingest.js ─────────────────────────────────────
// Everything the commune knows enters the dial through one function, in named
// passes: commitments become the calendar, intents become proposals and the
// ELIGIBLE field, and the planner's own classifications become the spine.
// Every pass is guarded on the wire carrying something — an empty snapshot
// leaves the day you had rather than blanking it.
initIngest({
    clearSelection: () => selectedEv.set(null),
});
// The live spine — indexDescendants, publishSpine, the desire signal and the
// taxonomy push — is app/spine.js, beside the buildRoot that makes the tree.
// the communes under the UC (the gateway's scopes push). A switcher
// when you belong to more than one; picking it re-fetches that commune's day.
// Personhood carries across all of them (the any-ecosystem fold).
// the commune roster → the scopes signal; the header breadcrumb (drawCrumb, run in a
// reactive effect) rebuilds from it. The old flat #communerow chip strip is retired.
on("scopes", (scopes) => {
    scopesSig.set(Array.isArray(scopes) ? scopes : []);
    recallScope(); // the device's remembered commune wins over the roster's first
    const row = document.getElementById("communerow");
    if (row)
        row.style.display = "none";
});
// REACTIVE: redraw the header breadcrumb whenever the scope or the roster changes.
effect(() => { scopeSig(); scopesSig(); drawCrumb(); });
// ── OFFLINE DEMO: per-scope plans ────────────────────────────────────────────
// The plans themselves are in app/demo.js; this is the pour. LIVE (scopesSig
// populated) it never runs — the gateway snapshot ingest drives the real
// per-scope solve, and this only fills the gap when running offline.
function applyDemoScope(sid) {
    const cfg = DEMO_SCOPE_PLAN[sid];
    if (!cfg)
        return; // unknown commune → keep the current demo
    const de = cfg.region === "de";
    setRecipes(de ? DEMO_RECIPES_DE : DEMO_RECIPES); // that scope's recipe topology drives the stages
    const needs = (de ? DEMO_NEEDS_DE : DEMO_NEEDS_CA)
        .map(n => ({ ...n, met: (cfg.met && cfg.met[n.id] != null) ? cfg.met[n.id] : n.met }));
    emit("plan", {
        scope: cfg.scope, coverage: cfg.coverage,
        labourH: needs.reduce((s, n) => s + (+n.labourH || 0), 0),
        produced: de ? [{ spec: "bread", q: 18, u: "each", emoji: "🍞" }]
            : [{ spec: "meal", q: 48, u: "each", emoji: "🍲" }, { spec: "vegetables", q: 60, u: "kg", emoji: "🥬" }],
        needs,
    });
    const sig = desireFromNeeds(needs);
    if (sig)
        emit("desire", sig); // reshape the wheel too
}
// OFFLINE ONLY: swap in the per-scope demo plan when the commune changes. Live → no-op.
effect(() => {
    const sid = scopeSig();
    if ((scopesSig() || []).length)
        return; // connected: the gateway ingest owns the plan
    if (sid)
        applyDemoScope(sid);
});
// debug: ?globe=<scale-multiple> draws the bare globe over the dial
{
    const gm = new URLSearchParams(location.search).get("globe");
    if (gm)
        landReady.then(() => {
            stage.leaf = S.root.children[1].children[0]; // meals, for place dots
            L.bands.attr("opacity", 0);
            L.seams.attr("opacity", 0);
            L.hand.attr("opacity", 0);
            drawGlobe(S0 * (+gm || 1), 1, +gm > 100 ? 1 : 0, true);
        });
}
// ------------------------------------------------ the orb listens (🎙️)
// hold the mic beneath the orb and speak; the words are transcribed on-device
// and the TEXT alone rides the seam to the gateway's AI (app/orb.js). What it
// needs from the dial is the arrangement it should think inside.
// the header's door to the commune's channel (app.html's #top writes the button)
const netDoor = document.getElementById("netbtn");
if (netDoor)
    mountRoomDoor(netDoor, networkTopic);
initLiveDock(); // the call's own controls, on every face, while you are in one
initRoomChips(); // any element with data-room is a door to that room
initOrb({
    tauHour: () => stage.hand,
    focusPath: () => {
        const p = [];
        for (let x = stage.focus; x; x = x.parent)
            p.unshift(x === S.root ? "all needs" : x.name);
        return p;
    },
    // the leaf ONLY while the earth face is actually up: it decides both what
    // the orb calls the view and whether that leaf's places travel along
    earthLeaf: () => mapUp() ? stage.leaf : null,
    recipes: () => scopeRecipes(),
});
// ------------------------------------------- the projection, outward
// the dial's state as a small JSON for THIN RENDERERS — home-screen widgets,
// watch faces, e-ink: surfaces that can fill a polygon but cannot run d3
// (app/projection.js, docs/dev/clock-projection.md)
initProjection();
// ════════════════════════════════════════════════════════════════════════
// THE MATTER FACE — the material-metabolism turn, in pure ValueFlows. A solve's
// substance flows ARE produce/consume events over substance EconomicResources:
// `produce` raises a resource (process → resource), `consume` lowers it
// (resource → process). So the graph is the native VF shape — processes and
// resources — and the RIFT is just the ENVIRONMENT's resources (soil, air,
// water) whose quantity DRIFTS: soil nitrogen falling, atmospheric carbon
// rising. A balanced stock = the loop closed; a drifting stock = the rift, made
// literal and per-nutrient. Pick a substance to isolate it. Read-only LENS — the
// demo {substances, nodes, links} below stands in for S.matterFlow.
// After observablehq.com/@tomshanley/sankey-circular.
// ════════════════════════════════════════════════════════════════════════
// which face owns the stage is stage.face (app/stage.js)
// ── the RIFT face: ecological substance-flow Sankey → app/tabs/matter.js
// A side-effect import: app/faces.js names its entry and its re-fit.
import './tabs/matter.js';
// ── the nested-container desire overlay (earth face) → app/tabs/containers.js
import * as containers from './tabs/map/containers.js';
// ── the containment forest the map draws → app/regions.js ─────────────────
// Real published extents (data/geo/boundaries.json), and containment DERIVED
// from geography rather than asserted: a scope is contained-in the deepest
// region whose polygon holds it. Three different trees meet on that map and the
// module says which is which.
initRegions({ hasMap: () => !!map() });
// ════════════════════════════════════════════════════════════════════════
// THE LAW FACE — the jurisdiction federation, the legal exterior DERIVED.
// Same SVG, a geographic projection instead of a dial. One ACTIVITY (free
// food distribution) is folded over every jurisdiction's guarded demands;
// the map paints each place by the LIGHTEST compliant pathway's burden, and
// drilling a state reveals the real member communes operating there and the
// recipe each runs. Data is data/snapshots/law-snapshot.json, the output of
// the REAL fold (tools/emit/emit-law-snapshot.scm); the legal-snapshot door that
// would refresh it live is the operator's, and a seat never holds it.
// ════════════════════════════════════════════════════════════════════════
// ── the fragility face: the federation's safe operating space ───────────────
// A side-effect import: app/faces.js names both its entry and its re-fit.
import './tabs/fragility.js';
// ── the law / burden-choropleth face → app/tabs/law.js
// A side-effect import: app/faces.js names its entry, its re-fit and its links.
import './tabs/law.js';
// ── the governance decision-inbox face → app/tabs/governance.js
import {} from './tabs/governance.js';
// ── the ecology face → app/tabs/ecology.js (the commons' ecological agents + speak)
import {} from './tabs/ecology.js';
import {} from './tabs/recipes.js';
// the legal bodies model: reads your bodies on every seat taken (settings › legal bodies, ?face=bodies)
import {} from './bodies.js';
import {} from './tabs/plan.js';
// the log face: the captain's log — voice-first entries that suggest contacts
// and observable VF events
import {} from './tabs/social/log.js';
import {} from './tabs/match.js';
import {} from './tabs/taxonomy.js';
// the shop face: the citizen's live order book — claims against earned credit
import {} from './tabs/shop.js';
// the share BAR: needs & offers as universal layout chrome — a footer drawer
// at the stage's foot, present on every face (the slots port, promoted)
import { initShareBar } from './tabs/social/share.js';
import { initIdDock } from './id-dock.js';
import { initAccount } from './account.js';
import { initFaceDock } from './face-dock.js';
// the feedback lane: free-form testimony about the interface itself, pooled
// server-side for synthesis into issues — mounts beside the share bar's mic
import { initFeedback } from './feedback.js';
import { initSettings, openSettings, closeSettings, settingsOpen } from './settings.js';
import { registerAllSettings } from './settings-sections.js';
import { initCalRail } from './tabs/calrail.js';
import { readJSON, writeJSON } from './store.js';
import { on, emit } from './bus.js';
import { provideSpectrum } from './spectrum.js';
import { K } from "./keys.js";
// ── the faces, and the table that switches them → app/faces.js ─────────────
initFaces();
initShareBar(); // the share bar is layout chrome — built at boot, on every face
initIdDock(); // …the identity door sits at the pill's left end, ahead of the mic
initFaceDock(); // …the faces, the scope and the focus trail sit in the bar; the header is gone
initAccount(); // …and its tap opens the account sheet: settings, theme, about, the channel, the notices
initCapture(); // …the camera button rides in its row, ahead of the feedback lane
initFeedback(); // …and the feedback lane rides in its row, after it exists
// settings: the registry renders on demand, but the sections must be registered at
// boot so the door has something behind it whichever face you open it from.
registerAllSettings();
initSettings();
d3.select("#openshop").on("click", () => setFace("shop")); // the time-face shopping section's door in
d3.select("#openstore").on("click", () => setFace("store")); // …and the inventory section's, to the store
// The dial's paint is imperative by design (reactive.js: the hot per-frame fields
// stay hand-drawn), so ONE effect bridges the two worlds: it subscribes to the
// calendars' and the facets' notifiers and asks for the same repaint a new
// planner snapshot asks for. Nothing that toggles a calendar or a facet has to
// know it needs to redraw anything.
{
    let first = true;
    effect(() => { calsRev(); facetsRev(); if (first) {
        first = false;
        return;
    } markDayChanged(); });
}
initCalRail(); // the calendar face's rail: the month, the calendars, the clocks, the people
initCalendar(); // now that stage.face is initialized: wire the week-grid face to
// the same `day` signal + shared events (its effect reads stage.face)
// responsive flat faces: the window's own resize, debounced. Which face is live
// and how it re-fits are the face table's to say (app/faces.js `refit`).
{
    let rz;
    window.addEventListener("resize", () => { clearTimeout(rz); rz = setTimeout(refitFace, 120); });
}
{
    const _sc = new URLSearchParams(location.search).get("scope");
    if (_sc)
        scopeSig.set(_sc); // deep-link to a commune (reactive; offline → demo plan)
    openFaceFromUrl(); // ?face= / #hash, else the map
    openHereFromUrl();
} // ?doy= at once; ?ev= once ingest names it
// the theme (app/theme.js) maps colours on their way into the DOM, so the CSS
// re-hues by itself but ALREADY-PAINTED nodes keep the old theme's values until
// something repaints them. A theme pick is rare and user-driven, so just repaint
// everything: the dial (settle), the face that owns the stage (setFace rebuilds
// the flat faces), and the reactive panels (markDayChanged). The map re-hues
// its own ground (app/mapview.js listens too).
document.addEventListener("playnet:theme", () => {
    if (stage.mode !== "dial")
        return; // on the map: nothing of ours is painted
    settle();
    if (stage.face !== "time" && stage.face !== "map")
        setFace(stage.face);
    markDayChanged();
});
// exported to app/tabs/* subsystems (benign import cycle; used at call time)
