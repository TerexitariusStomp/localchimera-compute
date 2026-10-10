// app/faces.ts — the faces, and the one table that switches between them.
//
// A FACE owns the stage. The time face is the dial itself; the others are
// overlays that take the stage from it — a Sankey, a choropleth, two fragility
// wheels, a week grid, an order book, a recipe library. The sidebar is ONE
// shell at a fixed width on every face, so the stage keeps its geometry from
// tab to tab and nothing rebuilds the rail; each face only shows its own
// content group inside it.
//
// ── ONE ROW IS THE WHOLE REGISTRATION ───────────────────────────────────────
// Switching used to be a chain of twenty `isRift`/`isLaw`/`isFrag` tests, each
// naming one element, which meant a new face touched a dozen lines scattered
// through one function and an old face's chrome could be left showing by a
// branch nobody updated. The table below says what each face OWNS — its stage,
// its rail group, its own chrome, whether it is flat, and how it mounts — and
// switching is mechanical: hide everything every face owns, then show what this
// one does. A face cannot leak its chrome onto another, because the hide pass
// does not know which face it is hiding.
//
// ── FLAT FACES ──────────────────────────────────────────────────────────────
// A flat face is a diagram rather than a dial: it takes the vertical space the
// clock's below-stage chrome would use, and it wants a pixel viewBox rather
// than the dial's square one. Leaving the last flat face restores the square.
//
// ── THE MAP IS ITS OWN BRANCH ───────────────────────────────────────────────
// It is the only face that is also a MODE. Entering it establishes the time
// stage first (the map sizes itself against #dial), then puts the dial into
// earth mode with the unlensed sentinel leaf so every place and offer shows —
// reusing the same openMap the desire drill-down uses, rather than a second
// path to the same view. Leaving it tears down instantly, with no rise
// animation: a tab is not a journey.
//
// ── SHARE IS CHROME, NOT A FACE ─────────────────────────────────────────────
// The share drawer opens over whatever face is showing, from its own button; it
// has no nav button and never takes the stage. Old ?face=share and #socialize
// links still land here and open it, which is the whole of what they ever meant.

import { stage } from './stage.js';
import { settle } from './wheel.js';
import { MAP_ALL } from './offers.js';
import { drawChrome } from './chrome.js';
import { drawEvents } from './ribbons.js';
import { clearMarkers } from './markers.js';
import { askGeolocation, resetHeading } from './compass.js';
import { endNav } from './nav.js';
import { openMap, teardownMap } from './mapview.js';
import { leaveSelectArea } from './tabs/map/select-area.js';
import { L, threads, timeLayers } from './layers.js';
import { initShare } from './tabs/social/share.js';
import { closeSettings, releaseRail } from './settings.js';
import { settlePanelForFace } from './panel.js';
import { effect } from './reactive.js';
import { tabsOn, setTabsOn, DEFAULT_TABS, homeFace } from './prefs.js';
import { mapGlobe } from './tabs/social/location.js';
import { drawRift } from './tabs/matter.js';
import { drawLaw, lawSizeSvg, lawRestoreSvg, lawEnter, lawDeepLink } from './tabs/law.js';
import { fragEnter, drawFrag } from './tabs/fragility.js';
import { initGovernance } from './tabs/governance.js';
import { initEcology } from './tabs/ecology.js';
import { initShop } from './tabs/shop.js';
import { initStore } from './tabs/store.js';
import { initRecipes } from './tabs/recipes.js';
import { initWeb, refitWeb } from './tabs/web.js';
import { initCorpus } from './tabs/corpus.js';
import { initPlan } from './tabs/plan.js';
import { initLog } from './tabs/social/log.js';
import { initMatch } from './tabs/match.js';
import { initTaxonomy } from './tabs/taxonomy.js';
import { initFamily } from './tabs/family.js';
import { initOnboard } from './tabs/onboard.js';
import { bodiesEnter } from './bodies-view.js';
import { identity } from './tabs/social/id.js';

/** What a face owns, and what taking the stage means for it. */
interface Face {
  /**
   * The HTML overlay that covers the dial, by id. Its `.on` class is the
   * switch; the dial's svg hides beneath it.
   */
  overlay?: string;
  /** The sidebar group this face fills, by id. */
  rail: string;
  /** An svg layer this face draws into, shown by `display`. */
  layer?: () => d3.Selection;
  /** Chrome shown ONLY on this face, by selector. */
  chrome?: string[];
  /** A diagram rather than a dial: it takes the space below the stage. */
  flat?: boolean;
  /** Whether the map tab and the in-disc map stay reachable from here. */
  keepsMap?: boolean;
  /**
   * The rail starts SHUT here until you open it yourself — for a room that's
   * mostly read rather than worked in, so the stage gets the width instead.
   * Once you've toggled it on a face, that face remembers its own choice
   * (panel.ts), and this stops mattering for it.
   */
  railShut?: boolean;
  /** Mount or refresh, once the stage is this face's. */
  mount?: () => void;
  /**
   * Draw again at a new stage size.
   *
   * Distinct from `mount`: entering a face sets it up, resizing only re-fits
   * what is already there — `law` mounts through lawEnter (effect + init +
   * view) and re-fits with a plain redraw. A face with no `refit` sizes itself
   * in CSS and needs no telling.
   */
  refit?: () => void;
}

/** What the faces need the dial to answer. */

/**
 * The registry. `time` is first because it is the ground the others cover: it
 * has no overlay, and it is the only face that is not flat.
 */
const FACES: Record<string, Face> = {
  time: {
    rail: "timeSecs", keepsMap: true,
    chrome: ["#sigmarow", "#spendrow", "#daterow", "#turnrow", "#hintrow"],
  },
  rift: {
    rail: "riftSecs", flat: true, keepsMap: true, railShut: true,
    layer: () => L.rift,
    mount: () => { lawSizeSvg(); drawRift(); },   // a flat pixel viewBox for the Sankey
    refit: () => { lawSizeSvg(); drawRift(); },
  },
  law: {
    rail: "lawSecs", flat: true, railShut: true,
    layer: () => L.law,
    chrome: ["#lawchrome"],
    mount: lawEnter,
    refit: drawLaw,
  },
  frag: {
    rail: "fragSecs", flat: true,
    layer: () => L.frag,
    chrome: ["#fragrow"],
    mount: fragEnter,     // two wheels that size themselves to the stage
    refit: () => drawFrag(),
  },
  cal: {
    rail: "calSecs", flat: true, overlay: "calface",
    // through the window rather than an import: calendar.ts imports main.js,
    // and main.js imports this — a direct import would put a third module into
    // that cycle at evaluation time for no gain.
    mount: () => (window as Window & { drawCalendar?: () => void }).drawCalendar?.(),
  },
  forum: {
    rail: "govSecs", flat: true, overlay: "forumface", railShut: true,
    mount: () => initGovernance(d3.select("#forumstage")),   // the forum: threads, votes, voice
  },
  // ── the HTML stage-owners ─────────────────────────────────────────────────
  // Each is a `#<f>face` overlay + `#<f>Secs` rail group + `#face-<f>` nav
  // button in app.html, and mounts through its own init. The overlay covers the
  // dial entirely, so all of them hide it.
  eco:      { rail: "ecoSecs",      overlay: "ecoface",      flat: true, mount: initEcology, railShut: true },
  shop:     { rail: "shopSecs",     overlay: "shopface",     flat: true, mount: initShop, railShut: true },   // the actions live inline on the stage; the rail is a note
  store:    { rail: "storeSecs",    overlay: "storeface",    flat: true, mount: initStore, railShut: true },   // what is held: the tree on the left, the desk on the right
  recipes:  { rail: "recipesSecs",  overlay: "recipesface",  flat: true, mount: initRecipes, railShut: true },
  web:      { rail: "webSecs",      overlay: "webface",      flat: true, mount: initWeb, refit: refitWeb, railShut: true },   // the same recipes as one graph, loops kept
  corpus:   { rail: "corpusSecs",   overlay: "corpusface",   flat: true, mount: initCorpus,  railShut: true },
  plan:     { rail: "planSecs",     overlay: "planface",     flat: true, mount: initPlan, railShut: true },
  log:      { rail: "logSecs",      overlay: "logface",      flat: true, mount: initLog },
  // no #matchSecs group — CSS hides #panel outright on this face, like map's;
  // "rail" still needs a string, and one that resolves to nothing is a safe no-op
  match:    { rail: "matchSecs",    overlay: "matchface",    flat: true, mount: initMatch },
  taxonomy: { rail: "taxonomySecs", overlay: "taxonomyface", flat: true, mount: initTaxonomy },
  family:   { rail: "familySecs",   overlay: "familyface",   flat: true, mount: initFamily, railShut: true },
  // the start face: its screens lead out to other faces through this table rather than an import of it
  onboard:  { rail: "onboardSecs",  overlay: "onboardface",  flat: true, mount: () => initOnboard(setFace), railShut: true },
  // the legal bodies you steward: its overlay is made on first entry (bodies-view.ts), so the page carries no tab for it
  bodies:   { rail: "bodiesSecs",   overlay: "bodiesface",   flat: true, mount: bodiesEnter, railShut: true },
};

/** The faces that own the stage through an HTML overlay of their own. */
export const STAGE_FACES = Object.keys(FACES).filter(f => FACES[f].overlay && f !== "cal");

/** Every face's id, the map included — what the nav bar and deep links range over. */
export const FACE_IDS = [...Object.keys(FACES), "map"];

/** Was the last face flat? Leaving flat behind is what restores the square viewBox. */
let flatWasOpen = false;

// ── the map face ────────────────────────────────────────────────────────────

/**
 * Enter the map: earth mode with the unlensed leaf, so every place shows.
 *
 * The caller establishes the time stage first, because openMap sizes itself
 * against #dial. The in-map "up to the dial" chip stays hidden — here the tab
 * bar is the way out, not a chip inside the disc.
 */
function enterMapFace(): void {
  stage.mode = "earth"; stage.leaf = MAP_ALL; stage.leafK = 0;
  askGeolocation();
  openMap();
  d3.select("#mapback").style("display", "none");
}

/** Leave the map instantly — no rise animation, because a tab is not a journey. */
function exitMapFace(): void {
  leaveSelectArea();      // the area frame, if it was up, goes with the map
  teardownMap();          // the same put-away the dial uses rising out of earth
  endNav();
  clearMarkers();
  L.earth.selectAll("*").remove();
  threads.selectAll("*").remove();
  resetHeading();
  stage.mode = "dial"; stage.leaf = null; stage.leafK = -1;
  drawChrome(); drawEvents(); settle();
}

// ── switching ───────────────────────────────────────────────────────────────

/** Everything shown only on SOME face — hidden first, then the live face shows its own. */
const allChrome = (): string[] =>
  Object.values(FACES).flatMap(f => f.chrome || []);

/** Give the stage to `face`. */
export function setFace(face: string): void {
  if (face === "share") { initShare(); return; }
  // Settings is a ROOM over the faces and it owns both halves — the stage and
  // the rail. Picking a face is leaving it, so shut the door on the way: the
  // room's rail group steps aside and the face gets the rail it is about to fill.
  closeSettings(); releaseRail();
  if (stage.face === "map" && face !== "map") exitMapFace();

  if (face === "map") {
    setFace("time");               // establish the dial stage first
    stage.face = "map";
    settlePanelForFace(false);     // no FACES entry of its own to ask
    d3.select("#main").attr("data-face", "map");
    enterMapFace();
    d3.select("#face-time").classed("on", false);
    d3.select("#face-map").classed("on", true);
    paintTabs();     // the pass inside setFace("time") named the clock; this is the map
    return;
  }

  const F = FACES[face];
  stage.face = face;
  settlePanelForFace(!!F?.railShut);
  d3.select("#main").attr("data-face", face);   // mobile CSS keys off this
  const isTime = face === "time";
  const flat = !!(F && F.flat);

  // 1. put every face's own things away, without asking which face they are
  for (const [id, f] of Object.entries(FACES)) {
    d3.select(`#${f.rail}`).classed("on", id === face);
    if (f.overlay) d3.select(`#${f.overlay}`).classed("on", id === face);
    if (f.layer) f.layer().attr("display", id === face ? null : "none");
  }
  d3.select("#shareSecs").classed("on", false);   // chrome, never a face's rail
  for (const sel of allChrome()) d3.select(sel).style("display", "none");

  // 2. the time face's own layers, and the stage the overlays cover
  timeLayers().forEach(g => g.attr("display", isTime ? null : "none"));
  d3.select("#threads").style("display", isTime ? null : "none");
  d3.select("#dial").style("visibility", (F && F.overlay) ? "hidden" : null);
  d3.selectAll("#earthmap, #maptab")
    .style("display", (F && F.keepsMap) ? null : "none");
  d3.select("#under").style("display", flat ? "none" : null);
  d3.selectAll("#rhythmrow, #backchip, #gochip, #mapback, #mapfull")
    .style("display", flat ? "none" : null);

  // 3. this face's own chrome, and its mount
  for (const sel of (F && F.chrome) || [])
    d3.select(sel).style("display", sel === "#lawchrome" || sel === "#fragrow" ? "block" : null);
  if (F && F.mount) F.mount();
  else if (!flat && flatWasOpen) lawRestoreSvg();   // back to a dial: square viewBox
  flatWasOpen = flat;

  // 4. the nav bar
  for (const id of FACE_IDS) d3.select(`#face-${id}`).classed("on", id === face);
  paintTabs();
}

// ── which tabs show ─────────────────────────────────────────────────────────

/** Whether `id`'s tab is switched on in settings. */
export const tabShown = (id: string): boolean => {
  const on = tabsOn();
  return Array.isArray(on) && on.includes(id);
};

/** Switch one face's tab on or off; the strip follows through the signal. */
export function setTabShown(id: string, on: boolean): void {
  const cur = Array.isArray(tabsOn()) ? tabsOn().filter(t => typeof t === "string") : [...DEFAULT_TABS];
  setTabsOn(on ? [...new Set([...cur, id])] : cur.filter(t => t !== id));
}

/** Back to the three the strip starts with. */
export const resetTabs = (): void => setTabsOn([...DEFAULT_TABS]);

/** Every face's tab, in strip order, with the words the strip uses for it. */
export function tabCatalogue(): { id: string; label: string; emoji: string; note: string }[] {
  return [...document.querySelectorAll<HTMLElement>("#facestrip .faceopt")]
    .map(a => ({ id: a.id.replace(/^face-/, ""), label: a.dataset.label || a.id,
                 emoji: a.textContent || "", note: a.title.replace(/^[^—]*— /, "") }));
}

/**
 * Hide the tabs that are off — except the live face's own, which stays named
 * while you stand on it. A group with nothing left to show goes with its tabs;
 * the dots and the gaps are CSS over what remains, so nothing here counts them.
 */
function paintTabs(): void {
  for (const id of FACE_IDS)
    d3.select(`#face-${id}`).classed("hid", !tabShown(id) && id !== stage.face);
  for (const g of document.querySelectorAll<HTMLElement>("#facestrip .facegroup"))
    g.classList.toggle("hid", !g.querySelector(".faceopt:not(.hid)"));
  const map = document.getElementById("face-map");
  if (map) map.textContent = mapGlobe();   // the globe faces this session's own hemisphere
}

/**
 * Where a URL that names no face lands: the walk when this device remembers
 * no identity at all — nothing to sign back into, so the walk is the door —
 * else the home face from settings when it is one we have, else the first
 * tab the strip shows, else the map.
 */
export function landingFace(): string {
  if (!identity()) return "onboard";
  const home = homeFace();
  if (typeof home === "string" && FACE_IDS.includes(home)) return home;
  const first = tabCatalogue().find(t => tabShown(t.id));
  return first ? first.id : "map";
}

/**
 * The stage changed size — let the live face draw at the new one.
 *
 * BOTH resize signals land here: the window's own, and the #orbwrap observer
 * that catches a sidebar drag. They used to be two hand-kept dispatches over
 * the same three faces, and they disagreed — the observer re-fitted only the
 * fragility wheels, so dragging the rail while reading the law choropleth or
 * the matter Sankey left them at the old size.
 */
export const refitFace = (): void => FACES[stage.face]?.refit?.();

/** Wire the nav bar: one button per face, all from the one table. */
export function initFaces(): void {
  for (const id of FACE_IDS) d3.select(`#face-${id}`).on("click", () => setFace(id));
  effect(paintTabs);      // the strip follows the setting
}

// ── deep links ──────────────────────────────────────────────────────────────

/**
 * The older routes, and where they land now.
 *
 * Every one of these was a hash somebody has bookmarked or linked to, so they
 * keep working — but they are DATA rather than a stack of ifs, which is what
 * makes it possible to see at a glance that nothing is routed twice.
 */
const ALIASES: Record<string, string> = {
  matter: "rift", fragility: "frag", calendar: "cal", ecology: "eco",
  gov: "forum", governance: "forum",
  socialize: "share", social: "share",
  start: "onboard", welcome: "onboard",
};

/**
 * Which face a URL asks for, or null when it names none.
 *
 * `?face=` and the hash mean the same thing and are tried in that order. An
 * unknown name resolves to nothing rather than to a default, so the caller can
 * tell "asked for something I do not have" from "asked for nothing" — only the
 * second should fall back.
 */
export function faceFromUrl(search: string, hash: string): string | null {
  const asked = new URLSearchParams(search).get("face") || hash.replace(/^#/, "");
  if (!asked) return null;
  const face = ALIASES[asked] || asked;
  return (face === "share" || FACE_IDS.includes(face)) ? face : null;
}

/**
 * Open whatever the URL asks for, else the home face (landingFace, above).
 *
 * The calendar is the home face until you choose another in settings; ?face=
 * names any face directly, whether or not its tab shows.
 */
export function openFaceFromUrl(): void {
  const p = new URLSearchParams(location.search);
  const face = faceFromUrl(location.search, location.hash);
  if (face === "law") lawDeepLink(p.get("place"), p.get("view"));   // law owns its own
  setFace(face || landingFace());
}
