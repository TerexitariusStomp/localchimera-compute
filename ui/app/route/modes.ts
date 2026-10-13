// app/route/modes.ts — the ways of travelling: THE table, and the words around it.
//
// A mode is the engine's name for how you go (a Valhalla costing), what it is called and what it is drawn as. The
// preview's tabs, the wayfinder's mode glyph, the journey sheet's "Travel by" page, a ride's legs and the REPL page all
// read their words and glyphs from here, so a way of travelling is named once.

/** Valhalla's costing names — the keys the UI's mode tabs ride on. */
export type Costing = "multimodal" | "pedestrian" | "bicycle" | "auto";

/** A way of travelling: the engine's name for it, and what it is called and drawn as. */
export interface ModeInfo { costing: Costing; label: string; icon: string }

/**
 * THE table of modes, in the order a preview shows its tabs (transit first, as the
 * phone's do) and the wayfinder's mode glyph cycles. The preview, the wayfinder and
 * the REPL page all read their words and glyphs from here.
 */
export const MODES: readonly ModeInfo[] = [
  { costing: "multimodal", label: "Transit", icon: "🚌" },
  { costing: "pedestrian", label: "Walk",    icon: "🚶" },
  { costing: "bicycle",    label: "Bicycle", icon: "🚲" },
  { costing: "auto",       label: "Drive",   icon: "🚗" },
];

export const ROUTE_MODES: Costing[] = MODES.map(m => m.costing);

/** What a mode is called and drawn as; undefined for a costing the UI has no tab for. */
export const modeInfo = (costing: string): ModeInfo | undefined => MODES.find(m => m.costing === costing);

/** The mode that travels each way a stretch can go: the engine's `travel_mode` → our costing. */
const COSTING_OF_TRAVEL: Record<string, Costing> = { pedestrian: "pedestrian", bicycle: "bicycle", drive: "auto", transit: "multimodal" };

/** The glyph for how a stretch is travelled — the engine's `travel_mode` — "" for one we have none for. */
export const travelIcon = (travelMode: string): string => modeInfo(COSTING_OF_TRAVEL[travelMode] ?? "")?.icon ?? "";

/**
 * UI words → Valhalla costing — the one vocabulary boundary, where the words are
 * born; the wire and the server speak costing names natively. A name already a
 * costing passes through, and no word at all is a walk.
 */
export function costingOf(word?: string | null): string {
  return ({ foot: "pedestrian", bike: "bicycle", car: "auto", scooter: "motor_scooter",
            transit: "multimodal", bus: "bus" } as Record<string, string>)[word || ""] || word || "pedestrian";
}

/** The mode a preview opens on when none has been chosen before, and the one a journey takes when asked nothing else. */
export const DEFAULT_COSTING: Costing = "pedestrian";
