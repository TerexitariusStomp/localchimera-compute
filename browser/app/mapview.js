// app/mapview.ts — the satellite fabric: the map instance, and where it sits.
//
// ── CONTAINER OWNERSHIP, AND WHY IT IS THE WHOLE DESIGN ─────────────────────
// The map TAB owns #maptab; the DISC owns #earthmap. They are never shared.
// Each face's sizer writes only its OWN element, so a stale call fired
// mid-transition — a resize observer, a face-switch race — lands on the other
// face's hidden container and corrupts nothing. That is the fix for the
// squeezed-stage bug, and it is why a face switch REBUILDS the maplibre
// instance rather than moving it: the instance binds to its owner's element,
// and the camera rides across in lastCam.
//
// ── TWO GEOMETRIES, ONE MAP ─────────────────────────────────────────────────
// On the MAP face the satellite is a plain RECTANGLE filling the stage: no
// dial, no circle, and the disc-geometry overlays (threads, isochrones, the
// bearing annulus) mean nothing there, so they are skipped rather than hidden.
// Reached by zooming INTO a place from the time dial it is a circular disc
// welded to the dial's centre — same instance, same tiles, different framing.
// `dialFace === "map"` is the whole of the difference.
import { S } from './state.js';
import { effect } from './reactive.js';
import { devMode } from './prefs.js';
import { R, U } from './geom.js';
import { USER, PLACES } from './core.js';
import { mapStyle, rethemeBasemap } from './basemap.js';
import { installOsmProtocol } from './map-packs.js';
import { clearMarkers } from './markers.js';
import { relevantOffers, MAP_ALL_ID } from './offers.js';
import { stage, onEarth, onMapFace } from './stage.js';
import { L } from './layers.js';
import { renderMarkers } from './markers.js';
import { mountJourneys } from './journeys.js';
import { mountLabels, rethemeLabels } from './tabs/map/labels.js';
import { refreshContainers } from './regions.js';
import { drawChrome } from './chrome.js';
import { drawEvents } from './ribbons.js';
import { drawEarthArcs, drawThreads } from './threads.js';
import { compassLive, compassCapable, deviceHeading, needleTap, syncCompassUi } from './compass.js';
import { initMiniMonth } from './tabs/calrail.js';
import * as containers from './tabs/map/containers.js';
import * as dropoff from './tabs/map/dropoff.js';
import * as pool from './tabs/map/pool.js';
import * as mapsearch from './tabs/map/mapsearch.js';
import { placeAt } from './tabs/map/osm-places.js';
import { bakeMapAnchor, MAP_ANCHOR } from './tabs/map/atlas.js';
import { mountDeck } from './tabs/map/deck.js';
let host;
let map = null;
let userMarker = null;
/** The fullscreen toggle's own button — set by FullscreenControl.onAdd, read
 *  by setMapFull to reflect its "on" state, the same "-active" pattern the
 *  vendored controls use. */
let fullscreenBtn = null;
/** The camera, carried across a face switch's rebuild. */
let lastCam = null;
/**
 * The satellite fills the whole circle, as the bands did — so the disc's radius
 * IS the dial's. Exported because the threads clip and measure against it, and
 * two constants that must agree are one constant.
 */
const mapFrac = 1.0;
export const mapR = () => R * mapFrac;
/** Set by sizeEarthMap: the live pixels-per-dial-unit, and the disc's radius. */
let pxPerUnit = 1, mapRpx = 1;
let mapFullscreen = false;
/** The element THIS face owns. Never the other one's. */
export const MAP_EL = () => onMapFace() ? "maptab" : "earthmap";
const mapSel = () => d3.select("#" + MAP_EL());
/** The map instance, or null before one is built (and offline, where none is). */
export const theMap = () => map;
/** The disc's radius in pixels — what the route framing pads by. */
export const mapRadiusPx = () => mapRpx;
/** Screen pixels per dial unit, for anything measured on the map and drawn on the dial. */
export const pxPerDialUnit = () => pxPerUnit;
/** Whether the satellite has left the disc and filled the viewport. */
export const isFullscreen = () => mapFullscreen;
/** Move the you-marker, when there is one. */
export const moveUserMarker = () => {
    if (userMarker)
        userMarker.setLngLat([USER.lng, USER.lat]);
};
/**
 * Map pixels → dial viewBox coordinates. The disc's top-left sits at
 * (w∕2 − mapRpx, h∕2 − mapRpx) of the stage, and the dial's origin at its
 * centre — so a marker's screen position becomes a point the annulus can reach.
 */
export const mapToDial = (px) => [(px.x - mapRpx) / pxPerUnit, (px.y - mapRpx) / pxPerUnit];
/** Re-measure and re-place the map and the chrome that rides its rim. */
export function sizeEarthMap() {
    const wrap = document.getElementById("orbwrap");
    if (!wrap)
        return;
    const wr = wrap.getBoundingClientRect();
    // THE MAP TAB fills the whole stage as a RECTANGLE — no dial, no circle.
    if (onMapFace()) {
        d3.select("#maptab")
            .style("left", "0px").style("top", "0px")
            .style("width", `${wr.width}px`).style("height", `${wr.height}px`);
        d3.select("#threads").style("left", "0px").style("top", "0px")
            .attr("width", wr.width).attr("height", wr.height);
        d3.select("#gochip").style("left", "16px").style("transform", "none").style("bottom", "16px");
        // no dial to go "up" to — the tab bar is the way out
        d3.select("#mapback").style("display", "none");
        if (map)
            map.resize();
        return;
    }
    const sv = document.getElementById("dial");
    if (!sv)
        return;
    const sr = sv.getBoundingClientRect();
    const x0 = sr.left - wr.left, y0 = sr.top - wr.top; // svg offset in wrap
    const w = sr.width, h = sr.height;
    pxPerUnit = Math.min(w, h) / (2 * S.VE * U); // track the live viewBox extent
    mapRpx = mapR() * U * pxPerUnit;
    d3.select("#earthmap")
        .style("left", `${x0 + w / 2 - mapRpx}px`).style("top", `${y0 + h / 2 - mapRpx}px`)
        .style("width", `${2 * mapRpx}px`).style("height", `${2 * mapRpx}px`);
    d3.select("#threads")
        .style("left", `${x0}px`).style("top", `${y0}px`)
        .attr("width", w).attr("height", h);
    // back + go ride the disc's lower edge, centred
    d3.select("#backchip").style("bottom", `${wr.height - (y0 + h / 2 + mapRpx) + 12}px`);
    d3.select("#gochip").style("bottom", `${wr.height - (y0 + h / 2 + mapRpx) + 44}px`);
    // the way-up button rides just inside the map's top rim, centred
    d3.select("#mapback")
        .style("left", `${x0 + w / 2}px`)
        .style("top", `${y0 + h / 2 - mapRpx + 12}px`);
    // (the fullscreen toggle and the compass are not here: both live in the
    // native maplibre control stack, which rides the map's own container corner
    // regardless of which face put the map up)
    if (map)
        map.resize();
}
/** The map opens at walking distance: a few blocks around you, street names readable. */
export const WALK_ZOOM = 16;
function mkMap() {
    installOsmProtocol(); // the style's osm:// source: kept packs first, then the gateway
    const m = new maplibregl.Map({
        container: MAP_EL(),
        style: mapStyle(),
        center: lastCam ? lastCam.center : [USER.lng, USER.lat],
        zoom: lastCam ? lastCam.zoom : WALK_ZOOM,
        attributionControl: true, antialias: true,
        fadeDuration: 0, // a name is there or it is not — no fade behind the ground's labels
    });
    m.on("error", e => console.warn("[map]", e));
    // the dial's overlays take their source and layer as soon as the style's JSON
    // is parsed, so a name arriving later is one setData away from the screen
    containers.mount(m);
    mountJourneys(m);
    mountLabels(m);
    const ue = document.createElement("div");
    ue.className = "user-marker";
    ue.title = "you";
    userMarker = new maplibregl.Marker({ element: ue, anchor: "center" })
        .setLngLat([USER.lng, USER.lat]).addTo(m);
    map = m;
}
// a theme pick re-hues the ground in place (the dial's own overlays are drawn
// through the theme already; see main.ts's playnet:theme handler for the rest)
document.addEventListener("playnet:theme", () => { if (map) {
    rethemeBasemap(map);
    rethemeLabels();
    renderMarkers();
} });
/**
 * Ensure a map bound to THIS face's element.
 *
 * A no-op where maplibre is absent or WebGL unavailable — the caller then shows
 * the dark map surface rather than a void, and every data surface (the search
 * panel, the mini-month, the pool) still works, because those are about data
 * and not about tiles.
 */
export function initMap() {
    if (map && map.getContainer().id !== MAP_EL()) {
        // the OTHER face's instance: carry the camera, rebuild on ours
        lastCam = { center: map.getCenter(), zoom: map.getZoom() };
        clearMarkers();
        map.remove();
        map = null;
        userMarker = null;
    }
    if (map || typeof maplibregl === "undefined")
        return;
    try {
        mkMap();
    }
    catch (e) {
        console.warn("[map]", e);
        map = null;
    }
}
/**
 * Frame the map around YOU, so the markers read as space rather than a blob: a
 * box symmetric about USER keeps you at the centre — the dial's bearing origin —
 * while the zoom fits your places and offers. Geo-pinned, so each marker holds
 * the SAME spot at every scale; zooming only changes how much you see.
 */
export function fitMarkersAroundUser() {
    const leaf = stage.leaf;
    if (!map || !leaf)
        return;
    // the unlensed map opens at walking distance around you; what lies further
    // out reads as a rim pointer, which is what the pointer arcs are for
    if (leaf.id === MAP_ALL_ID) {
        map.jumpTo({ center: [MAP_ANCHOR.lng, MAP_ANCHOR.lat], zoom: WALK_ZOOM });
        return;
    }
    let mLat = 0.006, mLng = 0.006; // a floor, so one marker cannot over-zoom
    const grow = (at) => {
        if (at) {
            mLat = Math.max(mLat, Math.abs(at.dLat));
            mLng = Math.max(mLng, Math.abs(at.dLng));
        }
    };
    (PLACES[leaf.id] || []).forEach(grow); // a place IS {dLat, dLng, …}
    relevantOffers(leaf.id).forEach(o => grow(o.at));
    // A single lens frames its own few places.
    // MAP_ANCHOR, not live USER: the markers this frames are themselves placed
    // relative to the anchor (atlas.ts), so the frame has to agree with them.
    map.fitBounds([[MAP_ANCHOR.lng - mLng * 1.3, MAP_ANCHOR.lat - mLat * 1.3],
        [MAP_ANCHOR.lng + mLng * 1.3, MAP_ANCHOR.lat + mLat * 1.3]], { bearing: map.getBearing(), padding: 8, duration: 0, maxZoom: 16 });
}
/**
 * The satellite leaves the disc and fills the viewport.
 *
 * The disc's own overlay chrome — arcs, threads — belongs to the circular
 * framing, so it steps aside while the map stands alone and returns on the way
 * back. Refused unless there is a map and the earth is up: there is nothing to
 * make fullscreen otherwise.
 */
export function setMapFull(on) {
    if (on && (!map || !onEarth()))
        return;
    mapFullscreen = on;
    d3.select("#orbwrap").classed("mapfull", on);
    mapSel().classed("full", on);
    fullscreenBtn?.classList.toggle("on", on);
    d3.select("#dial").style("display", on ? "none" : null);
    d3.select("#threads").style("display", on ? "none" : null);
    // sizeEarthMap() ends with its own map.resize() (both its branches do) —
    // calling resize() again right after was a second, redundant WebGL
    // viewport reallocation on every EXIT, which is what read as a glitch/
    // flash rather than a clean single resize. Only the ENTER path still
    // needs its own explicit resize: sizeEarthMap() doesn't run there at all
    // (the disc's own geometry is irrelevant once the map fills the screen).
    if (!on) {
        sizeEarthMap();
        host.restage();
    }
    else if (map)
        map.resize();
}
/** Show the map's own surface, whether or not tiles could be had. */
export const showMapSurface = () => { mapSel().classed("on", true); };
/**
 * Wire the map's sizing to everything that can reshape the stage.
 *
 * ONE observer on #orbwrap, not two. The stage gives up height to whatever else
 * the column holds — chiefly the share bar, which grows when its inventory
 * drawer opens — and a card appearing, the orb answering or the nav card
 * arriving all do the same thing. Watching the BOX rather than enumerating the
 * causes is why none of those has to know the map exists.
 */
export function initMapView(h) {
    host = h;
    const wrap = document.getElementById("orbwrap");
    if (wrap && window.ResizeObserver) {
        let rq = 0;
        new ResizeObserver(() => {
            if (onEarth()) {
                if (mapFullscreen)
                    return; // it owns the viewport; nothing to re-weld
                cancelAnimationFrame(rq);
                rq = requestAnimationFrame(() => { sizeEarthMap(); host.restage(); });
            }
            else
                host.otherFaceReflow();
        }).observe(wrap);
    }
    window.addEventListener("resize", () => {
        if (onEarth()) {
            sizeEarthMap();
            host.restage();
        }
    });
}
/**
 * Bring up the map in the disc, at whatever leaf the stage names.
 *
 * The order here is the design. The mini-month and the search panel mount
 * BEFORE the no-WebGL bail, because both are about DATA — which day you are
 * looking at, and what you are filtering for — not about tiles. A browser with
 * no WebGL still gets its day picker and its search; flyTo simply no-ops.
 *
 * Everything past the bail needs a live map: the camera, the markers, the
 * overlays that ride them, and the re-reading of the dial as a BEARING dial —
 * compass chrome, events at their true directions, places stitched
 * marker-to-arc across the annulus.
 */
/**
 * "Fill the screen with the map" — app-specific (it calls setMapFull, not a
 * reusable library behaviour), so it lives here rather than in the vendored
 * mapbox-controls.js, but shaped the same as every control there: one button,
 * riding the native maplibre corner stack instead of a separately-positioned
 * custom orb the way #mapfull used to be.
 */
class FullscreenControl {
    container;
    onAdd() {
        this.container = document.createElement("div");
        this.container.className = "maplibregl-ctrl maplibregl-ctrl-group";
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = "map-fullscreen-toggle";
        btn.title = "fill the screen with the map";
        btn.textContent = "⛶";
        btn.addEventListener("click", () => setMapFull(!mapFullscreen));
        this.container.appendChild(btn);
        fullscreenBtn = btn;
        return this.container;
    }
    onRemove() {
        this.container.remove();
        fullscreenBtn = null;
    }
}
export function openMap() {
    sizeEarthMap();
    d3.select("#mapback").style("display", "block"); // the in-map way up
    d3.select("#mapcal").style("display", "block");
    // moving the viewed day re-filters every time-clipped marker — offers by the
    // turn window, pool slots by their own — so the picker hands back a re-render
    initMiniMonth(document.getElementById("mapcal"), () => { if (map && onEarth())
        renderMarkers(); });
    if (onMapFace()) {
        mapsearch.mountMapSearch();
        mapsearch.bindFilter(() => { if (map && onEarth())
            renderMarkers(); });
    }
    initMap();
    if (!map) { // offline: the dark map surface, not a void
        if (onMapFace())
            showMapSurface();
        d3.select("#backchip").style("display", "none"); // the stack handles back
        return;
    }
    const m = map;
    // the viewport recentres on USER and the map's own anchor freezes to that
    // SAME USER, in the same tick — the one atomic moment they're allowed to
    // move together (see MAP_ANCHOR's own comment in atlas.ts)
    bakeMapAnchor();
    m.jumpTo({ center: [USER.lng, USER.lat], zoom: WALK_ZOOM });
    moveUserMarker();
    fitMarkersAroundUser(); // frame FIRST, so the clustering reads the right zoom
    renderMarkers();
    bindMapMarkers(m);
    // zoom/compass/inspect (vendor/mapbox-controls.js) + the fullscreen toggle
    // (this file's own FullscreenControl) + the deck.gl mount point
    // (app/tabs/map/deck.ts) — once per map instance, the same discipline as
    // _markersBound/_threadsBound above.
    if (!m._controlsBound) {
        m._controlsBound = true;
        // The whole stack rides the map's bottom-right, clear of the search
        // panel at the top-left/top. Maplibre stacks bottom-corner controls
        // newest-first, so they are added bottom-up: the column reads zoom,
        // compass, inspect, fullscreen, locate from the top, as it always did.
        const CORNER = "bottom-right";
        // maplibre's own "centre on me" — native, no vendoring needed. Every fix
        // it reports (the first click, and again on each update while tracking)
        // updates USER and re-bakes MAP_ANCHOR + redraws in the SAME tick as the
        // button's own recentre, so this can't reintroduce the anchor-drift bug
        // MAP_ANCHOR exists to prevent.
        m.addControl(new maplibregl.GeolocateControl({ trackUserLocation: true, showAccuracyCircle: true }), CORNER);
        m.on("geolocate", e => {
            USER.lat = e.coords.latitude;
            USER.lng = e.coords.longitude;
            bakeMapAnchor();
            moveUserMarker();
            renderMarkers();
        });
        m.addControl(new FullscreenControl(), CORNER);
        // the layer inspector is a debugging tool: it stays out of sight until
        // dev mode (settings → developer) asks for it, and stops listening when
        // dev mode goes off again
        const inspect = new MapboxControls.InspectControl();
        m.addControl(inspect, CORNER);
        effect(() => {
            const dev = devMode();
            inspect.container.style.display = dev ? "" : "none";
            if (!dev && inspect.isActive)
                inspect.deactivate();
        });
        // instant: true — always visible, not just once rotated. The upstream
        // default hides it at bearing 0, which is a fine idea for a map that's
        // ALREADY got a discoverable way to rotate; ours doesn't have one, so a
        // hidden-until-rotated reset button is a button nobody would ever find.
        // the needle is the one compass: north-up on a tap, and on a phone the tap
        // turns heading-up on and off (compass.ts) — lit while it is on
        m.addControl(new MapboxControls.CompassControl({
            instant: true, title: compassCapable() ? "Compass — north up; again to follow your phone's heading" : "Compass — north up",
            onClick: needleTap,
        }), CORNER);
        syncCompassUi();
        m.addControl(new MapboxControls.ZoomControl(), CORNER);
        mountDeck(m);
    }
    containers.mount(m); // the nested-container desire overlay
    mountJourneys(m); // the move arcs, derived from the same offer set
    mountLabels(m); // the markers' names, drawn by the map in the ground's register
    refreshContainers();
    if (onMapFace()) {
        // the drop points ride the same markers, so their card hands back a restyle
        dropoff.mountDrops({ map: m, refresh: renderMarkers, select: containers.setSelected });
        pool.mountPool({ refresh: renderMarkers });
    }
    showMapSurface();
    d3.select("#backchip").style("display", "none");
    L.rings.transition().duration(600).attr("opacity", 0)
        .on("end", () => { if (onEarth())
        L.rings.attr("pointer-events", "none"); });
    if (compassLive())
        m.setBearing(deviceHeading());
    drawChrome();
    drawEvents();
    drawEarthArcs();
}
/**
 * The chrome the map raises: chips inside the disc, and the panels beside it.
 *
 * A SET, named once, because it was being written out three times — twice as a
 * hide list and once as a loop over ids — and the three had already drifted
 * apart. Every one of these is raised by `openMap` above (or by the surface
 * that owns it: the places panel, the go chip), so the list to put away is the
 * list to bring up, and it lives beside it.
 */
const MAP_CHROME = ["#mapback", "#gochip",
    "#backchip", "#placesSec", "#mapcal"];
/**
 * Put the map's own chrome away, and unmount the surfaces that ride on it.
 *
 * Both ways out of the map end here — the tab bar leaving the map FACE, and the
 * dial rising back out of earth mode — so they cannot disagree about what the
 * map left behind. Each unmounted surface belongs to whoever put it up, so this
 * asks them all rather than reaching into any of them.
 */
export function teardownMap() {
    if (isFullscreen())
        setMapFull(false); // collapse the screen back into the disc
    dropoff.unmountDrops();
    pool.unmountPool();
    mapsearch.unmountMapSearch();
    containers.setSelected(null);
    for (const sel of MAP_CHROME)
        d3.select(sel).style("display", "none");
    d3.select("#earthmap").classed("on", false);
    d3.select("#maptab").classed("on", false).classed("full", false);
}
/**
 * Bind the map's two re-render triggers, once per instance.
 *
 * NOTHING re-renders during a gesture. A pan moves the existing markers —
 * maplibre's own job, free and perfectly smooth — and the grouping is
 * world-anchored, so only a ZOOM can change it. Regrouped exactly once, when
 * the gesture settles. The threads are the exception: they are welded to the
 * disc rather than to the world, so they follow every frame of a move.
 */
function bindMapMarkers(m) {
    if (!m._markersBound) {
        m.on("zoomend", renderMarkers);
        m._markersBound = true;
    }
    // a tap on one of OpenStreetMap's places (the basemap's own labels) opens
    // it in the panel as a row of the map's own — the dial's markers stop their
    // click before the map sees it, so this fires only on the ground
    if (!m._placesBound) {
        m.on("click", e => { if (!onMapFace())
            return; const r = placeAt(m, e.point); if (r)
            mapsearch.showOnPanel(r); });
        m._placesBound = true;
    }
    // a dropped pin: right-click, or press-and-hold on touch (maplibre raises
    // contextmenu for both) — a bare spot opens in the panel, ready to save
    if (!m._spotBound) {
        m.on("contextmenu", e => { if (onMapFace())
            mapsearch.showSpot(e.lngLat.lat, e.lngLat.lng); });
        m._spotBound = true;
    }
    if (!m._threadsBound) {
        m.on("move", drawThreads);
        m._threadsBound = true;
    }
}
