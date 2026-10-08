// app/tabs/fragility.ts — the FRAGILITY face: the federation's safe operating
// space as a planetary-boundaries wheel, drawn as a continuous gradient.
//
// Each fragility is a possibility-tension of the `frag` kind
// (module/playnet/planner/formulas/tension-kinds.scm): φ(s) = −w·log(s), where s is the
// normalized slack — 1 at the healthy steady-state s★, 0 at the tipping point
// (where the tension diverges). We render the real, cited catalogue from
// module/playnet/planner/knowledge/catalogues/eco.scm (browser/data/snapshots/fragility-snapshot.json,
// emitted by tools/emit-fragility-snapshot.scm); the live gateway pushes the
// same shape over the bus ("fragility").
//
// This is the CONSTRAINT DIAL of social-material.typ: "one wheel of limits, each
// an EQUAL sector" — the safe operating space read sector by sector. At rest the
// construction is rotation-invariant (angle carries nothing); every channel is
// RADIAL —
//   • radius  = transgression ρ = (current − boundary)/(riskHi − boundary),
//               squashed past the risk ring so a 6× overshoot stays on the page;
//   • colour  = a continuous green→amber→red gradient along the radius, its
//               stops placed by the −log(s) barrier so it stays green until near
//               the limit then rushes red — the fragility STEEPENING, rendered;
//   • opacity = governance weight w (how steeply the federation defends it).
// The green core is the safe operating space; the dashed ring is the tipping
// point (never crossed).
//
// Scroll folds in an OPTIONAL lens (fragWarp γ, see below): it tilts the angles
// from equal toward the plan's PULL φ′=w/s (the dual of social-means.typ) — the
// loud, near-a-tip limits opening widest. This is a reading aid layered on the
// dial, not the dial's own construction, which stays equal-sector at rest.
import { svg } from '../layers.js';
import { evs } from '../events.js';
import { PLAN } from '../core.js';
import { RECIPE_BY_ID } from '../recipe-graph.js';
import { L } from '../layers.js';
import { stage } from '../stage.js';
import type { Person } from '../nutrition.js';
import { colorFor } from '../palette.js';
import { PT, paleCol } from '../geom.js';
import { POPULATION, personNutritionWire, aggregateNutrition, capacityWire, skillMaintainTotal, band } from '../nutrition.js';
import { profileOverlay, profile } from '../profile.js';
import { signal, effect } from '../reactive.js';

import { on } from '../bus.js';
const TAU = 2 * Math.PI;
let fragLoading = false;
// THE WHEEL'S VIEW STATE, as signals: the wedge, the category ring, the mode and
// the data itself are each read by the wheel and the detail card at once, so a
// write repaints both on its own — no handler below calls drawFrag(). fragWarp
// is deliberately NOT one of these: see its note.
/**
 * The ecological catalogue and where the commons currently stands in it: one
 * control per boundary, plus the tipping elements a crossing would trip. Comes
 * live from the gateway, else from the committed snapshot.
 */
interface EcoWire {
  controls: EcoControl[];
  tippingElements?: unknown[];
  /**
   * Withheld service — hours that could serve within reach but pool narrower
   * (governance/means-fold.scm). Folded into `controls` on arrival; older
   * snapshots simply lack the field.
   */
  withholding?: EcoControl[];
  /** The commune's own people, when the gateway pushes them. */
  people?: Person[];
}

/**
 * One wedge of the wheel. Three families arrive here — reproduction NUTRITION,
 * reproduction SKILLS and the ecological COMMONS — and the wheel draws them on
 * one radial construction, which is the whole claim this face makes. So this is
 * their common surface rather than a union of the three: what a family carries
 * beyond it stays on the object and is read where that family is known.
 */
interface WheelControl {
  /** nutrient | skill | eco — which family, and so which fields below are real. */
  kind?: string;
  spec: string;
  control?: string;
  group?: string;
  unit?: string;
  /** How heavy the boundary is; scales the penalty and so the wedge's pull. */
  w?: number;
  /** Slack in (0,1]: 1 is whole, → 0 is strained. The one field every family has. */
  s: number;

  // nutrition
  intake?: number;
  rda?: number;
  ul?: number | null;
  side?: string;
  /** Population aggregate only: [min, max] across the cohort. */
  spread?: [number, number] | null;

  // skills
  runs?: number;
  willing?: number;
  needs?: string;

  // the ecological commons
  current?: number;
  boundary?: number;
  riskHi?: number;
  /** The whole rate — where the pool is disjoint from its reach; a reserve's calamity stock. */
  tip?: number;
  /** A reserve's standing level: the want plus the calamity stock. */
  target?: number;
  reach?: unknown;
  span?: unknown;
  source?: string;
  /** How far this control has faded in under the β blend. */
  betaFade?: number;
}

/** One ecological boundary's reading, as the catalogue carries it. */
interface EcoControl {
  spec: string;
  control?: string;
  group?: string;
  unit?: string;
  w?: number;
  s: number;
  [key: string]: unknown;
}

/** A clicked category, which dims everything outside it. */
interface FragCat { level: "group" | "super"; key: string | undefined }

const fragData = signal<EcoWire | null>(null);
const fragBeta = signal(1);   // individual ↔ social blend: 0 = this person, 1 = the federation
const fragSel = signal(-1);   // clicked wedge index, or -1 for none (shows the summary)
const fragCat = signal<FragCat | null>(null); // clicked category {level:"group"|"super", key} — dims non-members

// ── the angle question. social-material.typ draws TWO wheels: the CONSTRAINT DIAL
//    ("one wheel of limits, each an EQUAL sector" — radius carries the room to the
//    wall, angle carries nothing, rotation-invariant), and the HARMONY (wedges cut
//    by pull φ′=w/s, but there each wedge is a DESIRE reaching a common rim, so its
//    AREA is harmony mass). THIS face is the constraint dial, so at rest it draws
//    equal sectors — the doc-coherent state, and the one you can read all limits on
//    at once. fragWarp γ∈[0,1] is an OPTIONAL lens folded in by scroll: γ raises
//    every pull to the γ power before normalising, so γ=0 is equal standing (rest)
//    and γ→1 weights each sector by the plan's pull (the dual — the loud, near-a-
//    tip limits opening widest). Scroll to raise γ, double-click back to equal.
//    Scoped to the frag face so it never fights the time face's scroll on the svg.
let fragWarp = 0;   // 0 = equal sectors (constraint dial) · 1 = pull-weighted (the dual)

// smooth scroll: a wheel burst fires dozens of events/sec, and a full drawFrag
// rebuilds ~2k SVG nodes — so coalesce to ONE redraw per animation frame, out of
// the event handler (never a synchronous rebuild mid-scroll). drawFrag(true) also
// reuses the cached gradients and skips the legend/detail that γ never touches.
let warpRaf = 0;
let fragGradKey: string | null = null;   // signature of the per-wedge gradients; rebuilt only when it changes
const scheduleWarp = () => { if (!warpRaf) warpRaf = requestAnimationFrame(() => { warpRaf = 0; drawFrag(true); }); };

// the person's committed labour on the viewed turn — tunes their nutrition floor
// (the time face feeding the fragility face). Work events only.
const labourHours = () => (evs || []).filter(e => e.kind === "work")
  .reduce((h, e) => h + Math.max(0, (e.t1 ?? 0) - (e.t0 ?? 0)), 0);

// the whole wheel, on one radial construction, blended by β from a person to the
// federation. Three families: reproduction NUTRITION (per-individual — blends
// this person's slack toward the population GEOMETRIC MEAN, linear in log-slack,
// the barrier's own coordinate), reproduction SKILLS (federation-level, derived
// from the plan), and the ECOLOGICAL commons (shared-tip — fades IN as β→1, since
// "our tipping points" only exist at the social scale). The skill-maintenance
// labour couples back into the person's energy floor.
function activeData() {
  if (!fragData()) initFrag();                                   // the ecological commons (async)
  const plan = (typeof PLAN === "function" ? PLAN() : PLAN) || {};
  const needs = plan.needs || [], byId = RECIPE_BY_ID || {};
  const maintainH = skillMaintainTotal(needs, byId);           // production → consumption coupling
  // the commune's REAL people when the gateway pushes them (fragData().people, from
  // its person-agents + the plan's per-person intake); the demo cohort otherwise.
  // Floors/slack are still computed here (nutrition.js) — the SAME model the server
  // catalogue authors — so the dial shows the commune's actual reproduction.
  // read once: three calls to a signal in one condition is three subscriptions
  // to the same value, and only the first is load-bearing.
  const pushed = fragData();
  const basePop = (pushed && Array.isArray(pushed.people) && pushed.people.length)
    ? pushed.people : POPULATION;
  // "you" is the first person the wire names, overlaid with the profile stated
  // in settings (app/profile.ts) — the same tags the commons' floors read
  const you = { ...basePop[0], ...profileOverlay(), labour: labourHours() || profile().labourHours || basePop[0].labour };
  const pop = [you, ...basePop.slice(1)];
  const b = fragBeta();
  const mine = personNutritionWire(you, maintainH);
  const socialBy = Object.fromEntries(aggregateNutrition(pop, maintainH).controls.map(c => [c.spec, c]));
  const nutrients = mine.controls.map(c => {                   // blend, linear in log-slack
    const soc = socialBy[c.spec] || c;
    return { ...c, s: Math.exp((1 - b) * Math.log(c.s) + b * Math.log(soc.s)), spread: b > 0.02 ? soc.spread : null };
  });
  const skills = capacityWire(needs, byId);                    // federation capacity, constant
  const eco = tagEco({ controls: ((pushed && pushed.controls) || []).slice() }).controls
    .map(c => ({ ...c, betaFade: b }));                        // the commons, revealed as social
  const src = b < 0.5 ? `individual · ${mine.source}`
    : `social · ${pop.length} people (geometric-mean slack) + the ecological commons`;
  return { controls: [...nutrients, ...skills, ...eco], source: src, beta: b, individual: true };
}

// ── the frag possibility-tension, exactly as tension-kinds.scm computes it ──
const EPS = 1e-3;
const slackOf = (rho: number) => Math.max(EPS, Math.min(1, 1 - rho));   // s = 1 − ρ, clamped to (0,1]
const pull    = (s: number, w: number) => w / s;                              // |φ′(s)| = w/s (marginal labour-h)
// transgression ρ: current relative to [boundary, riskHi]; direction-agnostic
// (the denominator carries the sign). ρ<0 → inside the safe space; ρ=1 → the
// risk ring; ρ>1 → past it. Degenerate riskHi==boundary (ocean acid, novel
// entities) falls back to the transgressed flag.
// every control carries a slack s ∈ (0,1]; ρ = 1 − s is its transgression. The
// ecological wires (witness snapshot / live registry) are normalised to s at
// entry (tagEco), so the render is uniform across all fragility families.
const rhoOf = (c: WheelControl) => 1 - c.s;
// normalise an ecological wire (witness or live) to the uniform {kind, s} shape.
function tagEco(data: EcoWire): EcoWire {
  // the withheld service (means-withholding → withholding-snapshot, governance/
  // means-fold.scm): hours that could serve within reach but pool narrower.
  // Arrives as its own `withholding` array beside `controls` — folded into the
  // control list once here; older snapshots simply lack the field.
  if (data && Array.isArray(data.withholding) && data.withholding.length) {
    data.controls = (data.controls || []).concat(data.withholding);
    data.withholding = [];
  }
  (data && data.controls || []).forEach(c => {
    if (!c.kind) c.kind = "eco";
    // CEILING-only band: the safe operating space below the boundary is a flat
    // plateau (φ = 0), then risk ramps to the tipping point (riskHi). "Less draw
    // is always fine" — no floor edge. (Live wires arrive with s precomputed.)
    if (typeof c.s !== "number")
      c.s = band(c.current as number, { softHi: c.boundary as number, hardHi: c.riskHi as number });
  });
  return data;
}
// ρ → one solid severity colour: green in-band (ρ≤0) → amber → red at/past the
// wall (ρ≥1). Same green→amber→red zones as the planetary-boundaries wheel.
function fragColor(rho: number) {
  const stops: [number, [number, number, number]][] =
    [[0, [58, 157, 95]], [0.45, [143, 178, 58]], [0.75, [217, 194, 60]],
     [1, [226, 104, 31]], [1.3, [164, 30, 18]]];
  const t = Math.max(0, rho);
  for (let k = 1; k < stops.length; k++) {
    if (t <= stops[k][0] || k === stops.length - 1) {
      const [a, ca] = stops[k - 1], [b, cb] = stops[k];
      const u = Math.min(1, Math.max(0, (t - a) / (b - a)));
      const c = ca.map((v, j) => Math.round(v + (cb[j] - v) * u));
      return `rgb(${c[0]},${c[1]},${c[2]})`;
    }
  }
}
const fmt = (v: number | null | undefined) => v == null ? "" : v >= 100 ? Math.round(v).toString() : v >= 10 ? v.toFixed(0) : v.toFixed(1);

// linear interpolation over colour stops [[t,[r,g,b]],…] → "rgb(r,g,b)".
// The inferred `| undefined` is unreachable: stops is non-empty, so the loop
// reaches k === stops.length - 1, where the condition holds unconditionally.
function lerpStops(stops: [number, [number, number, number]][], t: number) {
  t = Math.max(0, Math.min(1, t));
  for (let k = 1; k < stops.length; k++) {
    if (t <= stops[k][0] || k === stops.length - 1) {
      const [a, ca] = stops[k - 1], [b, cb] = stops[k];
      const u = Math.min(1, Math.max(0, (t - a) / (b - a)));
      const c = ca.map((v, j) => Math.round(v + (cb[j] - v) * u));
      return `rgb(${c[0]},${c[1]},${c[2]})`;
    }
  }
}
// the HARMONY colour: a control's slack s∈(0,1] read as fulfilment — a warm grey
// where nothing is realized (s→0), deepening to a vivid harmony green at the
// healthy steady state (s→1, where the wedge reaches the perfect ring).
const harmonyColor = (s: number) => lerpStops(
  [[0, [206, 210, 214]], [0.4, [176, 202, 150]], [0.72, [116, 178, 108]], [1, [45, 138, 86]]], s);
// the harmony wedge's HUE: the colour the control wears in the desire dial, if it
// appears there — nutrients read as nourishment, a skill as the need it serves —
// resolved through the app-wide palette so the two dials share one colour language
// (and a theme swap re-hues both). Controls with no desire-need twin (the
// ecological commons) fall back to a category colour, then the harmony green.
function harmonyFill(c: WheelControl, s: number) {
  let col = null;
  if (c.kind === "nutrient") col = colorFor("nourishment");                     // food family, one hue
  else if (c.kind === "skill")
    col = colorFor(...String(c.needs || "").split(",").map(x => x.trim()).filter(Boolean)) || colorFor("capacity");
  else if (c.kind === "eco") col = colorFor(c.group, c.control) || colorFor("ecology");   // each boundary its own hue
  else if (c.kind === "rented") col = colorFor("rented");                        // revocable custody — one hue for the whole tenure family
  else if (c.kind === "withheld") col = colorFor("withheld");                    // pooled narrower than reach — one hue for the withheld service
  else if (c.kind === "reserve") col = colorFor("reserve");                      // the calamity stock behind a good — one hue for the reserve family
  else col = colorFor(c.control, c.spec, c.group);
  return col || harmonyColor(s);
}
// the geometric-mean slack over the visible controls — the aggregate the planner
// is maximizing (harmony = −Σφ = Σ w·log s, monotone in this mean). 1 = a perfect
// ring; lower = a ring still to be completed.
const geomeanSlack = (controls: WheelControl[]) =>
  Math.exp(controls.reduce((a: number, c: WheelControl) => a + Math.log(Math.max(EPS, c.s)), 0) / Math.max(1, controls.length));

// a control's dose-response profile along its QUANTITY axis: domain [x0,x1], the
// band edges [softLo,softHi] (either null = one-sided), the slack function s(x),
// the current value xNow, and the scale ticks to label. `social` swaps a nutrient's
// own intake for the aggregate's geomean-equivalent (deficiency-side) position.
/**
 * The slack profile behind one wedge: the quantity axis it lives on, where it
 * currently stands, and s(x) along it — so the detail can draw the BAND rather
 * than a single number, and the reader can see which way the tip lies.
 */
interface SlackProfile {
  x0: number;
  x1: number;
  softLo: number | null;
  softHi: number | null | undefined;
  unit?: string;
  /** Where it stands now. Absent when the family's own field is. */
  xNow: number | undefined;
  sAt(x: number): number;
  ticks: [number | undefined, string][];
}

function profileOf(c: WheelControl, social?: boolean): SlackProfile {
  if (c.kind === "eco") {
    const bp = { softHi: c.boundary, hardHi: c.riskHi };   // eco: both are its own fields
    return { x0: 0, x1: c.riskHi! * 1.08, softLo: null, softHi: c.boundary, unit: c.unit,
             xNow: c.current, sAt: (x: number) => band(x, bp), ticks: [[c.boundary, "safe"], [c.riskHi, "tip"]] };
  }
  if (c.kind === "withheld") {
    // reach − span: the quantity axis is the withheld rate itself — 0 where the
    // pool covers its reach, the whole rate (tip) where the pool is disjoint.
    const bp = { softHi: 0, hardHi: c.tip };  // withheld: tip is its own field
    return { x0: 0, x1: c.tip! * 1.08, softLo: null, softHi: 0, unit: c.unit,
             xNow: c.current, sAt: (x: number) => band(x, bp), ticks: [[c.tip, "whole rate"]] };
  }
  if (c.kind === "reserve") {
    // the level a plan holds of a good, against the two marks the solver used: the
    // WALL is the calamity stock (a `held` floor — never breached), the plateau the
    // target q* + q^res. The slack is the room above the reserve — the want met on
    // top of it — and it arrives precomputed, read off the solve (reserve-controls).
    const tip = c.tip!, target = c.target!;   // both written by reserve-controls (service.scm) — a reserve wedge always carries them
    const bp = { hardLo: tip, softLo: target };
    return { x0: 0, x1: target * 1.08, softLo: target, softHi: null, unit: c.unit,
             xNow: c.current, sAt: (x: number) => band(x, bp), ticks: [[tip, "reserve"], [target, "target"]] };
  }
  if (c.kind === "skill") {
    const bp = { hardLo: 0, softLo: 18 };
    return { x0: 0, x1: 24, softLo: 18, softHi: null, unit: "runs",
             xNow: c.runs || 0, sAt: (x: number) => band(x, bp), ticks: [[18, "ready"]] };
  }
  // the remaining family is nutrition, whose controls always carry an rda
  const rda = c.rda!, ul = c.ul, softHi = ul ? rda + 0.5 * (ul - rda) : null;
  const bp = { hardLo: 0.4 * rda, softLo: rda, softHi, hardHi: ul || null };
  const xNow = (!social && c.intake != null) ? c.intake
             : Math.max(0, bp.hardLo + c.s * (bp.softLo - bp.hardLo));   // aggregate: deficiency-equivalent
  return { x0: 0, x1: ul || rda * 2.4, softLo: rda, softHi, unit: c.unit,
           xNow, sAt: (x: number) => band(x, bp), ticks: ul ? [[rda, "RDA"], [ul, "UL"]] : [[rda, "RDA"]] };
}

async function initFrag() {
  if (fragData() || fragLoading) return;
  fragLoading = true;
  try {
    fragData.set(tagEco((typeof window !== "undefined" &&
         (window as Window & { __fragilityData?: EcoWire }).__fragilityData)
      || await (await fetch("data/snapshots/fragility-snapshot.json")).json()));
  } catch (e) { fragData.set({ controls: [], tippingElements: [] }); }
  fragLoading = false;
}
// the seam: the live gateway pushes the real catalogue + current state.
on("fragility", (snap: unknown) => { if (snap) fragData.set(tagEco(snap as EcoWire)); });

function drawFrag(warp = false) {
  L.frag.selectAll("*").remove();
  // FILL THE STAGE: size the SVG to the live orbwrap box so both wheels pack the
  // available space (re-measured every draw, so it reflows with the window and
  // with the detail card's height — no scroll needed). Falls back to a 2:1 box.
  const wrap = document.getElementById("orbwrap");
  let W, H;
  if (wrap && wrap.clientWidth > 20 && wrap.clientHeight > 20) {
    W = Math.round(wrap.clientWidth); H = Math.round(wrap.clientHeight);
    svg.style("width", W + "px").style("height", H + "px").style("max-width", "none")
       .style("aspect-ratio", "auto").attr("viewBox", `0 0 ${W} ${H}`).attr("preserveAspectRatio", "xMidYMid meet");
  } else {
    const vb = (svg.attr("viewBox") || "0 0 1200 600").split(/[ ,]+/).map(Number); W = vb[2]; H = vb[3];
  }

  const data = activeData();
  if (!data || !data.controls || !data.controls.length) {
    L.frag.append("text").attr("x", W / 2).attr("y", H / 2).attr("text-anchor", "middle")
      .attr("fill", "#888").attr("font-size", 9 * PT).text("reading the fragility catalogue…");
    initFrag();
    return;
  }
  // lay out only the VISIBLE controls (eco is dropped in the individual view) so
  // they spread around the FULL circle rather than leaving empty eco slots.
  // The three families are assembled by activeData() and drawn as one; this is
  // where they become the wheel's own vocabulary. WheelControl is a superset of
  // what each carries, so a read past a family's own fields is still checked.
  const controls = ((data.controls || []) as WheelControl[])
    .filter(c => (c.betaFade ?? 1) >= 0.5);
  const dir = (a: number) => [Math.sin(a), -Math.cos(a)];   // d3-arc angle (0=up, cw) → unit vector
  const arc = d3.arc();
  const clamp01 = (v: number) => Math.max(0, Math.min(1, v));
  // the per-wedge radial gradients depend on each control's SLACK PROFILE and R —
  // NOT on the angular warp γ. So they live in a PERSISTENT <defs> on the svg (it
  // survives L.frag's teardown) and are rebuilt only when their signature changes;
  // a warp redraw reuses them by id, skipping ~1k node creations per frame.
  let defs = svg.select("defs.fraggrads");
  if (defs.empty()) defs = svg.append("defs").attr("class", "fraggrads");
  const social = fragBeta() >= 0.5;

  // ── ONE dial, centred in the stage. The harmony reading is folded in: the
  //    plan's PULL sets each wedge's WIDTH, and the outer HALO grades the whole
  //    plan. Around the rim, spaced to breathe: a colour band (need identity),
  //    then the two classification rings (group, then super-group). Sized as
  //    large as the stage allows, minus the title strip and the outer rings. ──
  const topM = Math.max(28, H * 0.075);
  const labelPad = 80;                            // rim band + halo + the two thick labelled category rings
  const sideM = Math.max(64, Math.min(120, W * 0.06));
  const cx = W / 2;
  const R = Math.max(60, Math.min(W / 2 - sideM, (H - topM) / 2 - labelPad));
  const S = Math.max(0.6, Math.min(1.2, R / 215));
  const cy = topM + (H - topM) / 2;

  const title = (x: number, head: string, sub: string, col: string) => {
    L.frag.append("text").attr("x", x).attr("y", H * 0.04).attr("text-anchor", "middle")
      .attr("fill", col).attr("font-size", 15.5).attr("font-weight", 800).attr("font-family", "var(--sans)").text(head);
    L.frag.append("text").attr("x", x).attr("y", H * 0.072).attr("text-anchor", "middle")
      .attr("fill", "#8a9098").attr("font-size", 10.5).attr("font-family", "var(--sans)").text(sub);
  };
  const sub = fragWarp < 0.02
    ? "each limit an equal sector · radius = room to its wall · scroll to weight by pull"
    : `weighted by pull φ′=w/s · γ=${fragWarp.toFixed(2)} · dbl-click for equal sectors`;
  title(cx, fragWarp < 0.02 ? "the safe operating space" : "the plan, by pull", sub, "#a8455a");

  // ── geometry: at rest every limit is an EQUAL sector (the constraint dial —
  //    angle carries nothing, rotation-invariant). The optional WARP (γ=fragWarp,
  //    scrolled up from 0) raises each limit's pull φ′=w/s to the γ power before
  //    normalising, tilting the angles toward the plan's dual — γ=1 is the full
  //    pull-weighting, the loud near-a-tip limits opening widest. Sectors touch,
  //    bordered by their own need colour. ──
  const pulls = controls.map(c => (c.w || 6) / Math.max(EPS, Math.min(1, c.s)));
  const warped = pulls.map(p => Math.pow(p, fragWarp));   // γ=0 → all 1 (equal); γ=1 → pull
  const psum = warped.reduce((a, b) => a + b, 0) || 1;
  /** Each wedge with the angles the warp gave it. */
  const segs: { c: WheelControl; i: number; sa: number; ea: number; mid: number }[] = [];
  { let acc = 0; controls.forEach((c, i) => { const wdt = warped[i] / psum * TAU; segs.push({ c, i, sa: acc, ea: acc + wdt, mid: acc + wdt / 2 }); acc += wdt; }); }
  const gm = geomeanSlack(controls);
  const haloCol = fragColor(Math.min(1, Math.max(0, 1 - gm)));               // green (easy) → orange (strained)
  const border = (c: WheelControl) => d3.color(harmonyFill(c, 1)!).darker(0.5).formatHex();   // each sector's own colour line

  // ── the classification rings: contiguous runs of sectors that share a group,
  //    and above them the super-group (nourishment / capacity / ecology). The
  //    super-group colour is a PRISM union of its members' hues (screen-blended
  //    toward light) — a many-hued family recombines toward white, then splits
  //    into its spectrum on the ring below. Click a ring to focus that category. ──
  const supName = (c: WheelControl) => c.kind === "nutrient" ? "nourishment" : c.kind === "skill" ? "capacity" : c.kind === "rented" ? "rented" : c.kind === "withheld" ? "withheld" : c.kind === "reserve" ? "reserve" : "ecology";
  /** A contiguous run of sectors sharing a key, with the arc it spans. */
  type Run = { key: string | undefined; sa: number; ea: number; members: typeof segs };
  const runsOf = (keyFn: (c: WheelControl) => string | undefined) => {
    const out: Run[] = []; let cur: Run | null = null;
        segs.forEach(s => { const k = keyFn(s.c); if (!cur || cur.key !== k) { cur = { key: k, sa: s.sa, ea: s.ea, members: [s] }; out.push(cur); } else { cur.ea = s.ea; cur.members.push(s); } });
    return out; };
  const groupRuns = runsOf(c => c.group), superRuns = runsOf(supName);
  const groupCol = (r: Run) => colorFor(r.key) || harmonyFill(r.members[0].c, 1);
  const superCol = (r: Run) => colorFor(r.key) || "#8a9098";      // solid super hue (no blending)
  // read the signal once: the three calls were three subscriptions to one value.
  const inCat = (c: WheelControl) => {
    const cat = fragCat();
    return !cat || (cat.level === "group" ? c.group === cat.key : supName(c) === cat.key);
  };
  // contrasting ink for a band colour (dark band → white text, light → dark)
  const lum = (col: string) => { const c = d3.color(col)!.rgb(); return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) / 255; };
  // curved text laid CHARACTER-BY-CHARACTER along an arc at radius r, exactly as
  // the time face labels its event ribbons — flipped on the lower half so it reads
  // upright, skipped on arcs too short to hold it.
  const arcLabel = (gg: d3.Selection, r: number, sa: number, ea: number,
                    text: string | undefined, fill: string) => {
    // a run always has a key in practice — a group-less control would already
    // have thrown here, and the spread is left as it was rather than made lenient.
    const chars = [...text!], n = chars.length, amid = (sa + ea) / 2;
    const flip = Math.cos(amid) < 0;                       // lower half → upside-down, flip it
    const fs = Math.max(6, 8.5 * S);
    const dth = (fs * 0.62) / r;                           // angular pitch per char
    if (dth * n > Math.abs(ea - sa) * 0.92) return;        // won't fit → the rim colour band still names it
    const ink = lum(fill) < 0.58 ? "#ffffff" : "#20242a", halo = lum(fill) < 0.58 ? "rgba(0,0,0,.35)" : "#fff";
    chars.forEach((ch, i) => {
      const off = (i - (n - 1) / 2) * dth, a = flip ? amid - off : amid + off;
      const x = r * Math.sin(a), y = -r * Math.cos(a), rot = a * 180 / Math.PI + (flip ? 180 : 0);
      gg.append("text").attr("x", x).attr("y", y).attr("text-anchor", "middle").attr("dominant-baseline", "central")
        .attr("font-size", fs).attr("font-weight", 700).attr("font-family", "var(--sans)")
        .attr("fill", ink).attr("stroke", halo).attr("stroke-width", fs * 0.26).attr("paint-order", "stroke")
        .attr("transform", `rotate(${rot},${x},${y})`).attr("pointer-events", "none").text(ch);
    });
  };
  // a thick, solid, LABELLED classification band — same treatment as an event
  // ribbon (thickness + curved name), one ring per hierarchy level.
  const catBand = (gg: d3.Selection, r0: number, r1: number, run: Run,
                   fill: string, level: FragCat["level"]) => {
    const cat = fragCat();
    const sel = cat && cat.level === level && cat.key === run.key, op = (!cat || sel) ? 0.96 : 0.22;
    gg.append("path").attr("d", arc({ innerRadius: r0, outerRadius: r1, startAngle: run.sa + 0.006, endAngle: run.ea - 0.006, cornerRadius: 2 * S }))
      .attr("fill", fill).attr("fill-opacity", op).attr("stroke", "#fff").attr("stroke-width", 1 * S)
      .attr("cursor", "pointer").on("click", () => fragCat.set(sel ? null : { level, key: run.key }));
    if (op > 0.5) arcLabel(gg, (r0 + r1) / 2, run.sa, run.ea, run.key, fill);
  };
  const drawCategories = (cx: number, cy: number, R: number, S: number) => {
    const gg = L.frag.append("g").attr("transform", `translate(${cx},${cy})`);
    groupRuns.forEach(run => catBand(gg, R + 23 * S, R + 38 * S, run, groupCol(run)!, "group"));
    superRuns.forEach(run => catBand(gg, R + 42 * S, R + 57 * S, run, superCol(run), "super"));
  };
  const halo = (g: d3.Selection, R: number, S: number) => g.append("circle").attr("r", R + 17 * S).attr("fill", "none")
    .attr("stroke", haloCol).attr("stroke-width", 5 * S).attr("pointer-events", "none");
  const hits = (cx: number, cy: number, R: number) => {
    const hit = L.frag.append("g").attr("transform", `translate(${cx},${cy})`);
    segs.forEach(({ i, sa, ea }) => hit.append("path")
      .attr("d", arc({ innerRadius: 0, outerRadius: R * 1.02, startAngle: sa, endAngle: ea }))
      .attr("fill", "transparent").attr("cursor", "pointer")
      .on("click", () => fragSel.set(fragSel() === i ? -1 : i)));
  };

  // ── the CONSTRAINT wheel: each wedge is a control's QUANTITY axis, filled with
  //    the penalty φ as a radial gradient (green in-band, reddening toward a tip),
  //    with a level arc at the current value. ──
  function drawConstraint(cx: number, cy: number, R: number, S: number): void {
    const g = L.frag.append("g").attr("transform", `translate(${cx},${cy})`).attr("pointer-events", "none");
    // per-wedge piecewise map aligns every safe band to a common green RING
    // [rGin,rGout], so "in band" reads as one ring whatever the units.
    const rGin = 0.42 * R, rGout = 0.60 * R;
    const rAt = (p: SlackProfile, x: number) => {
      const { x0, x1, softLo, softHi } = p;
      if (softLo != null && softHi != null) {
        if (x <= softLo) return rGin * clamp01((x - x0) / (softLo - x0));
        if (x >= softHi) return rGout + (R - rGout) * clamp01((x - softHi) / (x1 - softHi));
        return rGin + (rGout - rGin) * (x - softLo) / (softHi - softLo);
      }
      if (softLo != null) {
        if (x <= softLo!) return rGin * clamp01((x - x0) / (softLo! - x0));
        return rGin + (R - rGin) * clamp01((x - softLo!) / (x1 - softLo!));
      }
      if (x <= softHi!) return rGout * clamp01((x - x0) / (softHi! - x0));
      return rGout + (R - rGout) * clamp01((x - softHi!) / (x1 - softHi!));
    };
    const xAt = (p: SlackProfile, r: number) => {
      const { x0, x1, softLo, softHi } = p;
      if (softLo != null && softHi != null) {
        if (r <= rGin) return x0 + (softLo - x0) * (r / rGin);
        if (r >= rGout) return softHi + (x1 - softHi) * ((r - rGout) / (R - rGout));
        return softLo + (softHi - softLo) * ((r - rGin) / (rGout - rGin));
      }
      if (softLo != null) {
        if (r <= rGin) return x0 + (softLo - x0) * (r / rGin);
        return softLo + (x1 - softLo) * ((r - rGin) / (R - rGin));
      }
      if (r <= rGout) return x0 + (softHi! - x0) * (r / rGout);
      return softHi! + (x1 - softHi!) * ((r - rGout) / (R - rGout));
    };
    // (re)build the gradient defs only when their inputs (slacks · social · R)
    // actually change — a pure angular warp leaves them untouched, so we skip the
    // ~1k stop-node creations and the colour maths on every scroll frame.
    const gradKey = `${social}|${Math.round(R)}|${segs.map(({ c }) => c.control + ":" + (+c.s).toFixed(4)).join("|")}`;
    const rebuildGrads = gradKey !== fragGradKey;
    if (rebuildGrads) { defs.selectAll("*").remove(); fragGradKey = gradKey; }
    /** Each wedge's tick marks, collected while the sectors draw and laid on top. */
  const markers: { i: number; p: SlackProfile; mid: number; sa: number; ea: number }[] = [];
    segs.forEach(({ c, i, sa, ea, mid }) => {
      const p = profileOf(c, social);
      const gid = `fg${i}`;
      // each wedge is a radial gradient of ITS OWN need colour — rich where the
      // constraint is SATISFIED (inside the safe band, slack high), washing pale
      // toward the walls where it is not, exactly as the desire dial pales an
      // unmet band. The rich ring IS this need's safe operating space.
      if (rebuildGrads) {
        const base = harmonyFill(c, 1);
        const grad = defs.append("radialGradient").attr("id", gid)   // centred on the wedge group's own origin
          .attr("gradientUnits", "userSpaceOnUse").attr("cx", 0).attr("cy", 0).attr("r", R);
        const M = 30;                                  // sample the slack s(x) uniformly along the radius
        for (let k = 0; k <= M; k++)
          grad.append("stop").attr("offset", `${(100 * k / M).toFixed(1)}%`)
            .attr("stop-color", paleCol(base!, Math.min(0.85, (1 - p.sAt(xAt(p, R * k / M))) * 0.9)));
      }
      g.append("path").attr("d", arc({ innerRadius: 0, outerRadius: R, startAngle: sa, endAngle: ea }))
        .attr("fill", `url(#${gid})`).attr("fill-opacity", inCat(c) ? 0.94 : 0.1)
        .attr("stroke", i === fragSel() ? "#2c3038" : border(c))
        .attr("stroke-width", (i === fragSel() ? 1.8 : 1.0) * PT).attr("pointer-events", "none");
      markers.push({ i, p, mid, sa, ea });
    });
    // a categorical colour band around the rim (spaced off the wedges) — each
    // sector tipped with its need colour, so the wheel carries its own colour key.
    segs.forEach(({ c, sa, ea }) => g.append("path")
      .attr("d", arc({ innerRadius: R + 7 * S, outerRadius: R + 13 * S, startAngle: sa, endAngle: ea }))
      .attr("fill", harmonyFill(c, 1)).attr("fill-opacity", inCat(c) ? 1 : 0.22)
      .attr("stroke", border(c)).attr("stroke-width", 0.5 * S).attr("pointer-events", "none"));
    // ── each sector NAMES ITSELF: the control's title as radial text along its own
    //    spoke, so every limit reads at a glance without a click. Reads inward from
    //    the rim, upright on both halves; a sector too thin to hold the line (when the
    //    wheel is pull-warped) skips — the rim colour band still names it. ──
    const prettyName = (c: WheelControl) => String(c.control || c.group || "").replace(/^[^|]*\|/, "").replace(/[-_]/g, " ").trim();
    segs.forEach(({ c, sa, ea, mid }) => {
      const txt = prettyName(c); if (!txt) return;
      const fs = 6.4 * S;
      if ((ea - sa) * (R * 0.9) < fs * 1.12) return;         // sector too narrow for the line
      const [mx, my] = dir(mid);
      let rot = Math.atan2(my, mx) * 180 / Math.PI;          // orient ALONG the spoke (radial)
      const flip = rot > 90 || rot < -90;                    // left/bottom would read upside-down
      if (flip) rot += 180;
      const rEnd = R * 0.98;                                  // just inside the rim, extending inward
      g.append("text")
        .attr("transform", `translate(${mx * rEnd},${my * rEnd}) rotate(${rot})`)
        .attr("text-anchor", flip ? "start" : "end").attr("dominant-baseline", "central")
        .attr("fill", "#f2f4f7").attr("fill-opacity", inCat(c) ? 0.96 : 0.22)
        .attr("stroke", "rgba(10,12,16,.62)").attr("stroke-width", fs * 0.34).attr("paint-order", "stroke")
        .attr("font-size", fs).attr("font-weight", 600).attr("font-family", "var(--sans)")
        .attr("pointer-events", "none").text(txt);
    });
    halo(g, R, S);                    // the plan's overall harmony grade
    drawCategories(cx, cy, R, S);     // the classification rings, above
    // the current level, a concentric ARC SEGMENT spanning the wedge at the
    // current value; its number rides just inside (only on wedges wide enough, or
    // the selected one, so thin high-slack slivers don't crowd). Selected wedge
    // also labels its scale ticks.
    markers.forEach(({ i, p, mid, sa, ea }) => {
      const [mx, my] = dir(mid), sel = i === fragSel(), wide = (ea - sa) >= 0.05;
      const rM = Math.max(4 * S, Math.min(R - 4 * S, rAt(p, p.xNow!)));
      const tang = Math.atan2(my, mx) * 180 / Math.PI + 90, hw = (sel ? 2.4 : 1.5) * S;
      g.append("path").attr("d", arc({ innerRadius: Math.max(0, rM - hw), outerRadius: rM + hw, startAngle: sa, endAngle: ea }))
        .attr("fill", "#1c1f24").attr("stroke", "#fff").attr("stroke-width", (sel ? 1 : 0.7) * S)
        .attr("paint-order", "stroke").attr("pointer-events", "none");
      if (wide || sel) g.append("text").attr("transform", `translate(${mx * rM},${my * rM}) rotate(${tang})`)
        .attr("text-anchor", "middle").attr("dominant-baseline", "middle").attr("dy", -4 * S)
        .attr("fill", "#1c1f24").attr("stroke", "#fff").attr("stroke-width", 2.6 * S).attr("paint-order", "stroke")
        .attr("font-size", (sel ? 10 : 8.5) * S).attr("font-weight", 700).attr("font-family", "var(--sans)").text(fmt(p.xNow));
      if (sel) p.ticks.forEach(([v, lab]: [number | undefined, string]) => {
        const rV = Math.max(4 * S, Math.min(R, rAt(p, v!)));
        g.append("text").attr("transform", `translate(${mx * rV},${my * rV}) rotate(${tang})`)
          .attr("text-anchor", "middle").attr("dominant-baseline", "middle").attr("dy", 4.5 * S)
          .attr("fill", "#555").attr("stroke", "#fff").attr("stroke-width", 2.4 * S).attr("paint-order", "stroke")
          .attr("font-size", 8 * S).attr("font-family", "var(--sans)").text(`${lab} ${fmt(v)}`);
      });
    });
    hits(cx, cy, R);
  }

  drawConstraint(cx, cy, R, S);
  // the detail card doesn't depend on the angular warp γ — skip it on a warp
  // frame so a scroll never reflows the sidebar HTML.
  if (!warp) {
    // the detail card follows the CLICKED wedge (persistent)
    if (fragSel() >= 0 && fragSel() < controls.length) {
      const c = controls[fragSel()], rho = rhoOf(c);
      drawDetail(c, rho, slackOf(rho), c.w || 1);
    } else drawDetail(null);
  }
}

// per-family hover description — how each fragility family reads its own numbers.
// Adding a family = a producer that tags {kind, control, group, w, s}, plus one
// entry here. `where` is a function of ρ (how far past the safe range it sits).
const DESCRIBE = {
  eco: (c: WheelControl) => ({
    levels: c.tip != null
      ? `draw <b>${(+c.current!).toFixed(2)} ${c.unit}</b> · precautionary tip ${(+c.tip!).toFixed(2)}`
      : `now <b>${c.current} ${c.unit}</b> · boundary ${c.boundary} · high-risk ${c.riskHi}`,
    where: (r: number) => r >= 1 ? "past the high-risk line" : r > 0 ? "in the zone of uncertainty" : "within the safe space",
  }),
  nutrient: (c: WheelControl) => ({
    levels: `intake <b>${c.intake} ${c.unit}</b> · target ${c.rda}${c.ul ? ` · upper limit ${c.ul}` : ""}`,
    where: () => c.side === "adequate" ? "in the safe range" : c.side,
  }),
  skill: (c: WheelControl) => ({
    levels: `practised <b>${c.runs}×</b> · <b>${c.willing}</b> willing · maintains ${c.needs}`,
    where: (r: number) => r > 0 ? "competence atrophying" + (c.willing! <= 1 ? " · single holder" : "") : "well maintained",
  }),
  withheld: (c: WheelControl) => ({
    levels: `withheld <b>${(+c.current!).toFixed(1)} ${c.unit}</b> · pools at <b>${c.span}</b> · could serve <b>${c.reach}</b>`,
    where: () => "the whole rate pools out of reach — span→reach, the redistribution mandate's figure",
  }),
  reserve: (c: WheelControl) => ({
    levels: `on hand <b>${(+c.current!).toFixed(1)}</b> · calamity stock ${(+c.tip!).toFixed(1)} · target ${(+c.target!).toFixed(1)}`,
    where: (r: number) => r >= 1 ? "at the reserve — the want is gone, the stock intact" : r > 0 ? "the want partly yielded; the reserve stands" : "the want met on top of the reserve",
  }),
};

// the detail panel (#fragdetail): the numbers behind the clicked wedge, and the
// pull φ′=w/s this fragility currently exerts on the plan, in labour-hours.
// rho/s/w are read only past the `!c` return, so a summary redraw passes none.
function drawDetail(c: WheelControl | null, rho = 0, s = 1, w = 0): void {
  const el = d3.select("#fragdetail");
  if (!el.node()) return;
  if (!c) { el.html(summaryHtml()); return; }
  const d = (DESCRIBE[c.kind as keyof typeof DESCRIBE] || DESCRIBE.eco)(c);
  el.html(`
    <div class="frag-h">${c.group} · <b>${c.control}</b></div>
    <div class="frag-row">${d.levels}</div>
    <div class="frag-row">transgression ρ = <b>${rho.toFixed(2)}</b> — ${d.where(rho)}</div>
    <div class="frag-row">slack s = ${s.toFixed(3)} · weight w = ${w} · pull φ′ = w/s = <b>${pull(s, w).toFixed(1)}</b> labour-h</div>
    <div class="frag-src">${c.source || ""}</div>`);
}
function summaryHtml() {
  const w = activeData(), cs = (w.controls || []) as WheelControl[], b = fragBeta();
  const nutr = cs.filter(c => c.kind === "nutrient"), skills = cs.filter(c => c.kind === "skill"),
        eco = cs.filter(c => c.kind === "eco");
  const nearN = nutr.filter(c => rhoOf(c) > 0).length, nearE = eco.filter(c => rhoOf(c) > 0).length;
  const scale = b < 0.02 ? "individual — this person" : b > 0.98 ? "social — the whole federation" : `individual ↔ social · β=${b.toFixed(2)}`;
  return `<div class="frag-h">reproduction of labour-power · <b>${scale}</b></div>
    <div class="frag-row">CONSUMPTION <b>${nearN}/${nutr.length}</b> nutrient floors nearing a tip (two-sided — a deficiency floor OR a
      toxicity ceiling) · CAPACITY <b>${skills.length}</b> skills read off the plan's recipes (atrophying without practice) ·
      the ECOLOGICAL commons <b>${nearE}/${eco.length}</b> past a boundary${b < 0.5 ? " (shown at the social scale)" : ""}.</div>
    <div class="frag-row" style="color:#888">${w.source}. Each spoke is that control's <b>quantity axis</b> (centre→rim = low→high), painted in its own
      <b>need colour</b>: rich across its <b>safe band</b> — the satisfied operating space — and paling toward the deficiency floor (inner) and the
      toxicity ceiling (outer) where it nears a wall. The <b>level arc</b> marks its current value. <b>Individual</b> = this person's own floors;
      <b>social</b> = the population <b>geometric mean</b> (worst-off-leaning) + the shared-tip ecological commons. Click a spoke for its scale. These are reference values for planning a commune's food supply — not medical advice, a diagnosis or a diet prescription.</div>
    <div class="frag-row" style="color:#888">This is the <b>constraint dial</b>: at rest each limit is an <b>equal sector</b> (angle carries nothing — read them all at once).
      <b>Scroll</b> to fold in the plan's <b>pull φ′=w/s</b> (weight over slack), tilting the angles toward the dual so the loud, near-a-tip limits
      open widest; <i>dbl-click</i> returns to equal sectors. Around the rim, the <b>colour band</b> names each need, then the two labelled
      <b>classification rings</b> — the group, then the super-group (nourishment · capacity · ecology) — <i>click a ring to focus that category</i>.
      The outer <b>halo</b> grades the whole plan — <b style="color:#2f7a5a">green</b> where it rests easily inside the walls,
      <b style="color:#b5551f">orange</b> where it strains (now mean slack <b>${Math.round(geomeanSlack(cs) * 100)}%</b>).</div>`;
}

function setMode(m: "individual" | "social"): void {   // discrete: individual (β=0) or social (β=1) — the full circle at each pole
  fragBeta.set(m === "individual" ? 0 : 1);
  fragSel.set(-1);   // the visible-control set (and index space) differs between modes
  d3.select("#frag-individual").classed("on", fragBeta() === 0);
  d3.select("#frag-social").classed("on", fragBeta() === 1);
}
export function fragEnter() {   // entered from setFace
  d3.select("#frag-individual").on("click", () => setMode("individual"));
  d3.select("#frag-social").on("click", () => setMode("social"));
  setMode(fragBeta() === 0 ? "individual" : "social");
  // scroll UP folds in the pull weighting (γ: 0 equal → 1 the dual); scroll down
  // relaxes back toward equal sectors; double-click snaps back to equal. Namespaced
  // + face-guarded so it never fights the time face's scroll on the shared svg.
  svg.on("wheel.fragwarp", e => {
    if (stage.face !== "frag") return;
    e.preventDefault();
    fragWarp = Math.max(0, Math.min(1, fragWarp - (e as WheelEvent).deltaY * 0.0011));
    scheduleWarp();   // coalesced to one redraw per frame, off the event handler
  });
  svg.on("dblclick.fragwarp", e => {
    if (stage.face !== "frag" || fragWarp <= 0) return;
    e.preventDefault(); e.stopPropagation();
    fragWarp = 0; drawFrag();
  });
  initFrag();
  startFragEffect();
  drawFrag();   // on entry: the effect only re-runs on a WRITE, and the face may
                // be re-entered with the same state it left with
}

// THE render. Registered on first entry rather than at module scope: this module
// is imported BY main.js, so its body runs while main.js's own bindings are still
// in their temporal dead zone — an effect here would read the face too early.
// fragWarp is absent on purpose: scroll mutates it dozens of times a second and
// `scheduleWarp` already coalesces that to one drawFrag(true) per frame — the
// tuned path reactive.js reserves for the hot fields.
let fragEffectOn = false;
function startFragEffect() {
  if (fragEffectOn) return;
  fragEffectOn = true;
  effect(() => {
    fragData(); fragBeta(); fragSel(); fragCat();
    if (stage.face === "frag") drawFrag();
  });
}

export { drawFrag };
