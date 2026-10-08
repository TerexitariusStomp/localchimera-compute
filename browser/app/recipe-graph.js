// app/recipe-graph.ts — the scope's recipe library, and the two ways in.
//
// A recipe declares what spec it `produces`, so a resource can be FOLLOWED
// BACK to the recipe that makes it. That one property is what turns a flat list
// into a graph, and it is why there are two indexes rather than one:
//
//   RECIPE_BY_ID    a need names its recipe — the plan's own pointer
//   RECIPE_BY_SPEC  a step's input names a spec — the bill of materials,
//                   walkable to the bottom
//
// THE SEAM: real recipes arrive serialized from ^recipe-store through the scope
// snapshot; until a scope is connected, app/demo.js's library stands in, in the
// same shape. Quantities and hours ride the wire as STRINGS, and are coerced
// once, here, so no reader downstream has to wonder.
//
// No DOM. What the library looks like is app/plan-column.js; this is what it
// IS, which is why the plan face, the recipes face and the card can all ask it
// without any of them importing a renderer.
import { seam } from './seam.js';
import { PLAN } from './core.js';
import { DEMO_RECIPES } from './demo.js';
import { emit } from './bus.js';
/** A step's headline output: the one marked primary, else the first. */
export const primOut = (s) => (s?.out || []).find(f => f.primary) || (s?.out || [])[0] || null;
/**
 * A recipe's deliverable: its declared `produces`, else its LAST step's primary
 * output. The fallback is what lets a recipe written without the declaration
 * still be found by what it makes.
 */
export const recipeOutSpec = (r) => r.produces || primOut((r.steps || [])[(r.steps || []).length - 1])?.spec;
let RECIPES = [];
/**
 * The two indexes, as STABLE OBJECTS that are emptied and refilled rather than
 * replaced. A module that imports one holds it across every library swap — an
 * ES import binding cannot be reassigned by the importer, and a face that took
 * a copy of a replaced object would go on reading the previous scope's recipes
 * without anything saying so.
 */
export const RECIPE_BY_ID = {};
export const RECIPE_BY_SPEC = {};
const emptied = (o) => {
    for (const k of Object.keys(o))
        delete o[k];
};
/** The whole library, in the order the store gave it. */
export const recipes = () => RECIPES;
/** A recipe by its own id — how a need names the recipe that fills it. */
export const recipeById = (id) => (id && RECIPE_BY_ID[id]) || null;
/** The recipe that MAKES a spec — how an input is followed down the bill. */
export const recipeForSpec = (spec) => (spec && RECIPE_BY_SPEC[spec]) || null;
/**
 * Install a library and rebuild both indexes.
 *
 * The coercion is the load-bearing part: `q` and `hours` arrive as strings from
 * the store, and a string quantity silently poisons every sum downstream (it
 * concatenates). Doing it once at the door is why nothing further in reaches
 * for a unary plus.
 */
export function setRecipes(list) {
    RECIPES = (list || []).map(r => ({
        ...r,
        steps: (r.steps || []).map(s => ({
            ...s, hours: +(s.hours ?? 0) || 0,
            in: (s.in || []).map(f => ({ ...f, q: +(f.q ?? 0) || 0 })),
            out: (s.out || []).map(f => ({ ...f, q: +(f.q ?? 0) || 0 })),
        })),
        // the barbell's computed standing: its readings ride the wire as strings
        // too, from day-boot's stringly writer — coerced here with everything else.
        profile: (r.profile || []).map(c => ({ ...c, n: +(c.n ?? 0) || 0, reach: +(c.reach ?? 0) || 0, beyond: c.beyond == null ? undefined : +c.beyond || 0, accel: +(c.accel ?? 0) || 0, se: +(c.se ?? 0) || 0,
            curve: (c.curve || []).map(p => ({ s: +(p.s ?? 0) || 0, c: +(p.c ?? 0) || 0 })),
            bend: { kind: c.bend?.kind || "", gap: +(c.bend?.gap ?? 0) || 0, from: +(c.bend?.from ?? 0) || 0,
                at: +(c.bend?.at ?? 0) || 0, to: +(c.bend?.to ?? 0) || 0 },
            points: (c.points || []).map(p => ({ when: p.when || "", s: +(p.s ?? 0) || 0, c: +(p.c ?? 0) || 0,
                claims: (p.claims || []).map(t => ({ ...t, intended: +(t.intended ?? 0) || 0, realized: +(t.realized ?? 0) || 0 })) })) })),
        // what it yields under the weather live now: 1 (the whole) where it has no record
        yield: +(r.yield ?? 1) || 1,
    }));
    emptied(RECIPE_BY_ID);
    emptied(RECIPE_BY_SPEC);
    RECIPES.forEach(r => {
        if (r.id)
            RECIPE_BY_ID[r.id] = r;
        const s = recipeOutSpec(r);
        if (s)
            RECIPE_BY_SPEC[s] = r;
    });
    setActive(RECIPES[0] || null);
    emit("recipes"); // the recipes face re-renders
}
// ── the card's trail ────────────────────────────────────────────────────────
// Following a resource down the bill pushes a back-trail, so ← walks up the way
// you came rather than to some canonical parent. Held here because it is a
// position IN THE GRAPH; what it draws is the card's business.
let activeRecipe = null;
let recipeStack = [];
/** The recipe the card is showing, or null. */
export const active = () => activeRecipe;
/**
 * The way you came, oldest first — the card's breadcrumb.
 *
 * Nulls are filtered out: the stack holds whatever was active when a descent
 * began, and that is null when the card was opened with no library loaded. A
 * breadcrumb cannot name a recipe that was not there.
 */
export const trail = () => recipeStack.filter((r) => r !== null);
/**
 * Whether there is anywhere to go BACK to — which is not the same question as
 * whether the trail has names in it. A descent begun from an empty library
 * pushes a null: you can still step back out of it, and the breadcrumb still
 * has nothing to say.
 */
export const canGoBack = () => recipeStack.length > 0;
/** Show a recipe with no trail behind it — the start of a descent. */
export function setActive(r) {
    activeRecipe = r;
    recipeStack = [];
}
/** Follow a resource down to the recipe that makes it, keeping the way back. */
export function pushRecipe(r) {
    if (!r || r === activeRecipe)
        return false;
    recipeStack.push(activeRecipe);
    activeRecipe = r;
    return true;
}
/**
 * Step back up the trail, answering whether there was one. False means the top:
 * the caller closes the card rather than showing an empty one.
 */
export function popRecipe() {
    if (!recipeStack.length)
        return false;
    activeRecipe = recipeStack.pop() ?? null;
    return true;
}
/** The selected scope's display name. */
export const scopeName = () => {
    try {
        return PLAN().scope || "the commons";
    }
    catch (_) {
        return "the commons";
    }
};
/** A recipe's display name, or "" when the id names none. */
export const recipeName = (id) => recipeById(id)?.name || "";
// ── what a recipe builder offers to pick from ───────────────────────────────
// Both faces that let a citizen write a recipe (tabs/recipes.ts, tabs/web.ts)
// hand the SAME builder (tabs/web-draft.ts) a list of goods and needs to
// suggest — read off the scope's own library, so the suggestions match what
// is really here rather than each face inventing its own guess.
/** Every spec any step of the library touches, first emoji seen wins. */
export function knownGoods() {
    const seen = new Map();
    recipes().forEach(r => (r.steps || []).forEach(s => [...(s.in || []), ...(s.out || [])].forEach(f => {
        if (f.spec && !seen.has(f.spec))
            seen.set(f.spec, f.emoji || "");
    })));
    return [...seen.entries()].map(([spec, emoji]) => ({ spec, emoji }));
}
/** Every need id the plan asks for, plus every need a recipe already claims to serve. */
export function knownNeeds() {
    return [...new Set((PLAN().needs || []).map(n => n.id)
            .concat(recipes().map(r => r.need || ""))
            .filter(Boolean))];
}
/** Load the library: the spine's, or the demo when there is none. */
export function initRecipeGraph() {
    setRecipes(seam.data.recipes && seam.data.recipes.length
        ? seam.data.recipes : DEMO_RECIPES);
}
