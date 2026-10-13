// app/route/lines.ts — a route on the map: the ONE place its lines are drawn.
//
// The preview draws every way (the chosen one heavy, its alternatives pale); the
// wayfinder draws the chosen way with what is behind you dimmed; with no way at
// all a thin bearing thread stands in. All three are one source and one set of
// layers, mounted the way the dial's other overlays are (app/journeys.ts): once
// per map instance, when the style can take them (app/tabs/map/ready.ts), and
// found again if the instance is rebuilt.
//
//   kind      drawn as
//   alt       an alternative: pale, under the chosen way
//   done      the part you have been along: grey, no casing
//   sel       the chosen way: deep blue on a white casing
//   walk      the chosen way where a multimodal trip goes on foot: the same blue, dotted
//   bearing   no way at all: a thin dashed thread between two points
//
// `lineFeatures` is the pure half — a spec in, GeoJSON out — so what is drawn can be
// stated in a test without a map.

import type { Point } from '../geom.js';
import type { Route } from './data.js';
import { segments } from './facts.js';
import { styleReady, onStyleReady } from '../tabs/map/ready.js';

/** What to draw. Each part is optional; the empty spec draws nothing. */
export interface LineSpec {
  /** Every way: the chosen one at `pick`, the rest its alternatives. */
  ways?: readonly Route[];
  pick?: number;
  /** How far along the chosen way you are, as an index into its shape; what is behind is drawn `done`. */
  at?: number;
  /** No way at all: the two points a bearing thread joins. */
  bearing?: readonly [Point, Point];
}

const line = (kind: string, coords: Point[]): maplibregl.Feature =>
  ({ type: "Feature", properties: { kind }, geometry: { type: "LineString", coordinates: coords } });

/** The spec as the features the layers read. Pure. */
export function lineFeatures(spec: LineSpec): maplibregl.Feature[] {
  const out: maplibregl.Feature[] = [];
  (spec.ways || []).forEach((r, i) => {
    if (i !== (spec.pick ?? 0)) { if (r.coords.length > 1) out.push(line("alt", r.coords)); return; }
    const at = Math.max(0, Math.min(spec.at ?? 0, r.coords.length - 1));
    if (at > 0) out.push(line("done", r.coords.slice(0, at + 1)));
    for (const s of segments(r)) {
      const end = s.begin + s.coords.length - 1;
      if (end <= at) continue;                                  // all behind you
      const ahead = s.coords.slice(Math.max(0, at - s.begin));  // what is left of it
      out.push(line(r.costing === "multimodal" && s.mode === "pedestrian" ? "walk" : "sel", ahead));
    }
  });
  if (spec.bearing) out.push(line("bearing", [...spec.bearing]));
  return out;
}

// ── the layers ──────────────────────────────────────────────────────────────

const SRC = "route";
const BLUE = "#1a47c8";
const is = (...kinds: string[]): maplibregl.Expression =>
  kinds.length === 1 ? ["==", ["get", "kind"], kinds[0]] : ["any", ...kinds.map(k => ["==", ["get", "kind"], k])];
const ROUND = { "line-cap": "round", "line-join": "round" } as const;

/** Bottom to top: what is drawn later lies over what is drawn first. */
const LAYERS: maplibregl.LayerSpec[] = [
  { id: "route-alt-casing", type: "line", source: SRC, filter: is("alt"), layout: ROUND,
    paint: { "line-color": "#ffffff", "line-width": 8, "line-opacity": 0.75 } },
  { id: "route-alt", type: "line", source: SRC, filter: is("alt"), layout: ROUND,
    paint: { "line-color": "#8fb0ee", "line-width": 5 } },
  { id: "route-done", type: "line", source: SRC, filter: is("done"), layout: ROUND,
    paint: { "line-color": "#9aa5b8", "line-width": 5, "line-opacity": 0.9 } },
  { id: "route-sel-casing", type: "line", source: SRC, filter: is("sel", "walk"), layout: ROUND,
    paint: { "line-color": "#ffffff", "line-width": 10, "line-opacity": 0.95 } },
  { id: "route-sel", type: "line", source: SRC, filter: is("sel"), layout: ROUND,
    paint: { "line-color": BLUE, "line-width": 6 } },
  { id: "route-walk", type: "line", source: SRC, filter: is("walk"), layout: ROUND,
    paint: { "line-color": BLUE, "line-width": 5, "line-dasharray": [0.1, 1.8] } },
  // no way at all: a bearing, not a route — thin, dashed, no casing
  { id: "route-bearing", type: "line", source: SRC, filter: is("bearing"), layout: { "line-cap": "round" },
    paint: { "line-color": BLUE, "line-width": 2, "line-dasharray": [0.5, 1.8] } },
];

const empty = (): maplibregl.FeatureCollection => ({ type: "FeatureCollection", features: [] });

/** The latest ask, so a style that is not ready yet draws what is wanted when it is, not what was. */
let want: { map: maplibregl.Map; spec: LineSpec } | null = null;

function apply(map: maplibregl.Map, spec: LineSpec): void {
  if (!map.getSource(SRC)) {                       // a rebuilt map instance has none: mount again
    map.addSource(SRC, { type: "geojson", data: empty() });
    for (const l of LAYERS) map.addLayer(l);
  }
  map.getSource(SRC)!.setData({ type: "FeatureCollection", features: lineFeatures(spec) });
}

/** Draw `spec` on `map` — now, or the moment its style can take it. Replaces whatever was drawn. */
export function paintLines(map: maplibregl.Map, spec: LineSpec): void {
  want = { map, spec };
  if (styleReady(map)) apply(map, spec);
  else onStyleReady(map, () => { if (want?.map === map) apply(map, want.spec); });
}

/** Draw nothing. The layers stay mounted, as the journeys' do; their source holds no features. */
export function clearLines(map: maplibregl.Map | null): void {
  if (map) paintLines(map, {});
}
