// app/palette.ts — the ONE place that maps an element's identity to a colour.
//
// Every face that draws a need / control / category asks HERE for its colour,
// instead of hard-coding one. So the same need reads the same hue everywhere (the
// desire dial's "nourishment" coral is the harmony dial's nutrient coral), and a
// whole colour THEME becomes a single swap — override the entries here (or call
// setColor / applyTheme) and the app re-hues. This is the seam a theme-picker
// will drive later.
//
// Identities are matched case/space-insensitively, by any of an element's
// aliases (id, human name, category). The desire (time) dial seeds the registry
// from its taxonomy via registerTree(); other faces resolve by the same keys.
const norm = (s) => (s == null ? "" : String(s).trim().toLowerCase());
// the canonical theme — ONE categorical colour per element identity, shared by
// every face (the desire dial's needs, the fragility dials' limits), so a colour
// theme is a single swap. Mirrors docs/social-material.typ Figure 1, where each
// limit — provisioning need OR ecological boundary — carries its own hue.
export const THEME = {
    // the desire needs (mirror the desire taxonomy's cols in main.js)
    rest: "#2c4a6e", nourishment: "#e8654f", movement: "#0e7c7b",
    learning: "#e2a512", connection: "#7a4bb0",
    // the commons' shelves beyond the five: one hue each, distinct from the five
    // and from each other in light and dark — a good wears its band's colour
    clothing: "#b5638f", furnishing: "#a67c4e", housing: "#8a6f9e", care: "#3f9d5f",
    health: "#3f9d5f", hygiene: "#4f86c6", tools: "#5c6672", energy: "#c98d0e",
    water: "#4f86c6", transport: "#0e7c7b", culture: "#7a4bb0", craft: "#a67c4e",
    communication: "#2f9089", external: "#6f7480", money: "#6f7480",
    // reproduction families
    capacity: "#c0892f", // skills / capacity (the plan's recipes)
    // the nine planetary boundaries — each its own hue (Figure 1's palette where they meet)
    "climate change": "#5c6672", // carbon / radiative forcing — slate
    "freshwater change": "#4f86c6", // blue & green water
    "biogeochemical flows": "#7f9a39", // N and P — olive
    "biosphere integrity": "#3f9d5f", // genetic & functional diversity — green
    "land-system change": "#a67c4e", // forest / land — earth brown
    "ocean acidification": "#2f9089", // aragonite — ocean teal
    "atmospheric aerosols": "#9a86b0", // AOD — haze violet
    "stratospheric ozone": "#6f9ed6", // O3 column — sky
    "novel entities": "#b5638f", // synthetics — magenta
    ecology: "#3f8f6a", // fallback for any un-grouped ecological control
    rented: "#8a6f9e", // capacity held under another's rights — revocable custody (rented channel / socialized means)
    withheld: "#a1584a", // service pooled narrower than its reach — hours withheld from where they could serve (means-withholding)
    reserve: "#5b7ba6", // the calamity stock behind a good — q^res = ι·q*, held under the want (catalogues/insurance.scm)
    "drop point": "#7a5a2e", // a container at a place: held by the box, owned by whoever left it
};
/**
 * How a thing is STANDING — the one red/amber/green scale the dial reads
 * everything against.
 *
 * These three were written as raw hexes in nine files, which is how a colour
 * with a meaning loses the meaning: the same red says "this need is unmet", "the
 * shop is shut by the time you arrive" and "this event clashes with that one",
 * and nothing said those were the same judgement until they were named.
 *
 * They are NOT theme entries. THEME above maps an element's IDENTITY to a hue
 * (nourishment is coral wherever it appears); these say how something is FARING,
 * which is orthogonal — a need keeps its identity colour while its status ink
 * moves from sound to unmet.
 */
export const STATUS = {
    sound: "#2e7d32", // met, open now, clear of clashes
    strained: "#b8860b", // short of the want, or open but not for long
    unmet: "#b04a3a", // not met, shut, clashing
};
/**
 * The credit rail's own gold.
 *
 * It shares STATUS.strained's hex today and means something else entirely —
 * what is drawn down against credit rather than what is faring poorly. Named
 * separately so a re-theme can part them without hunting for which `#b8860b`
 * meant which.
 */
export const CREDIT = "#b8860b";
/**
 * A met fraction as its status ink.
 *
 * The plan column, the plan face and the inventory each carried this exact
 * ternary. One rule, so the three surfaces cannot disagree about what counts as
 * a need in trouble.
 */
export const metCol = (m) => m > 0.66 ? STATUS.sound : m > 0.4 ? STATUS.strained : STATUS.unmet;
const REG = new Map();
function seedTheme() { Object.entries(THEME).forEach(([k, v]) => REG.set(norm(k), v)); }
seedTheme();
// register a colour for an element identity. By default the FIRST registration
// wins (so seeded theme colours aren't clobbered by a tree that repeats them);
// pass {override:true} to force.
export function setColor(key, col, { override = false } = {}) {
    const k = norm(key);
    if (!k || !col)
        return;
    if (override || !REG.has(k))
        REG.set(k, col);
}
// seed the registry from a COLOURED tree (the desire taxonomy): every node's
// colour under both its id and its human name, so later faces can resolve either.
export function registerTree(node) {
    if (!node)
        return;
    if (node.col) {
        setColor(node.id, node.col);
        setColor(node.name, node.col);
    }
    (node.children || []).forEach(registerTree);
}
// the site theme's mapping, if one is installed (app/theme.js). The registry
// keeps the PRISTINE identity colours; the theme is applied on the way out, at
// resolve time, so switching themes needs no re-registration and never loses the
// base hue a need was given.
let TINT = null;
export function retint(fn) { TINT = fn; }
// resolve a colour by any of the given aliases — first hit wins, else null so the
// caller can fall back to its own default.
export function colorFor(...aliases) {
    for (const a of aliases) {
        const c = REG.get(norm(a));
        if (c)
            return TINT ? TINT(c) : c;
    }
    return null;
}
export function hasColor(...aliases) { return colorFor(...aliases) != null; }
// swap the whole theme (or a subset) at once — the theme-picker's entry point.
export function applyTheme(theme) {
    Object.assign(THEME, theme || {});
    Object.entries(theme || {}).forEach(([k, v]) => setColor(k, v, { override: true }));
}
