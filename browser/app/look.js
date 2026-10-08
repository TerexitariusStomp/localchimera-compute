// app/look.ts — a picture, read into rows.
//
// The photo read is the third technique a person carries (docs/observation/
// capture.md §2, §9): a model proposes what a picture shows, row by row, and
// the person confirms or strikes each. This module is the read's two ends and
// nothing between them: what the model is asked, and what is made of its
// answer. The answer is untrusted text; `fault` says why a row does not
// conform, in words the model is asked again with, and `rowsOf` keeps the rows
// it clears. The AI can only propose: a row lands as a count or a declaration
// when a person has confirmed it, through the doors every count goes through.
//
// Pure, so the capture sheet and a unit test read an answer the same way.
import { bestMatch } from "./fuzzy.js";
import { standing } from "./count.js";
const UNITS = ["each", "kg", "g", "l", "ml", "m", "pair", "set"];
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const KINDS = ["best-before", "use-by"];
/** What the model is told to do, and the shape it answers in. */
export function lookSystem(specs) {
    return `You read one to four photographs of things kept in a store, a kitchen or a ` +
        `workshop, for an inventory. List each DISTINCT kind of thing that is clearly ` +
        `visible, with how much of it there is. Reply with EXACTLY one JSON object, no ` +
        `prose, no fences:\n` +
        `{"rows":[{"name":"<what it is, 1-4 words>","spec":"<the known spec name when ` +
        `one fits, else the name>","qty":<number>,"unit":"<${UNITS.join("|")}>",` +
        `"lot":"<a lot or batch code printed on it, or empty>",` +
        `"expires":"<a date printed on it as YYYY-MM-DD, or empty>",` +
        `"expiresKind":"<best-before|use-by, as the label says, or empty>"}]}\n` +
        (specs.length
            ? `Known specs (use these EXACT names whenever the thing is one of them): ` +
                `${JSON.stringify(specs)}\n`
            : "") +
        `Count what you can see and nothing else: things of one kind are ONE row with ` +
        `their number; a thing sold by weight or volume is its net amount in kg or l ` +
        `when a label states it, else the number of packages in "each". Several ` +
        `photographs are views of the same things: count each thing once. A date is ` +
        `"use-by" only when the label says use by or its equivalent, and "best-before" ` +
        `when it says best before. Leave lot, expires and expiresKind empty when no ` +
        `label states them. When nothing is recognisable, reply {"rows":[]}.`;
}
/** What the sheet knows of the scene, for the model to lean on. */
export function lookUser(ctx) {
    const held = ctx.held.slice(0, 40).map(h => ({ name: h.name, spec: h.spec, unit: h.unit }));
    return (ctx.place ? `where: ${ctx.place}\n` : "") +
        (ctx.container ? `the container in view: ${ctx.container}\n` : "") +
        (held.length
            ? `the ledger holds these there (use a name and unit from this list when the ` +
                `thing is one of them): ${JSON.stringify(held)}\n`
            : "") +
        `the photographs follow.`;
}
/** Why a row does not conform, as words for the model; null when it does. */
export function fault(r) {
    if (!r.name || typeof r.name !== "string" || !r.name.trim())
        return `.name must say what the thing is`;
    const q = Number(r.qty);
    if (!(Number.isFinite(q) && q >= 0))
        return `.qty must be a number, zero or more`;
    if (r.unit !== undefined && r.unit !== "" && !UNITS.includes(String(r.unit)))
        return `.unit "${r.unit}" must be one of ${UNITS.join("|")}`;
    if (r.expires && !DATE.test(String(r.expires)))
        return `.expires "${r.expires}" must be YYYY-MM-DD or empty`;
    if (r.expiresKind && !KINDS.includes(String(r.expiresKind)))
        return `.expiresKind "${r.expiresKind}" must be best-before, use-by or empty`;
    if (r.expiresKind && !r.expires)
        return `.expiresKind is stated with no date; leave both empty`;
    return null;
}
/** The answer's faults, one line each, or null when every row conforms. */
export function lookCheck(got) {
    const rows = got.rows;
    if (!Array.isArray(rows))
        return `- "rows" must be an array`;
    const faults = [];
    rows.forEach((r, i) => {
        if (!r || typeof r !== "object") {
            faults.push(`rows[${i}] must be an object`);
            return;
        }
        const f = fault(r);
        if (f)
            faults.push(`rows[${i}]${f}`);
    });
    if (rows.length > 40)
        faults.push(`at most 40 rows: one per kind of thing`);
    return faults.length ? faults.map(f => `- ${f}`).join("\n") : null;
}
// how alike two names must be for a row to be read as a count of a thing held
const ALIKE = 0.6;
/** The thing held that a row is a count of, by its spec and else by its name. */
export function matchOf(row, held) {
    const bySpec = held.find(h => h.spec && h.spec === row.spec);
    if (bySpec)
        return bySpec;
    const byName = held.find(h => h.name.toLowerCase() === row.name.toLowerCase());
    if (byName)
        return byName;
    const near = bestMatch(row.name, held.map(h => ({ name: h.name, value: h.id })), ALIKE);
    return near ? held.find(h => h.id === near.value) : undefined;
}
/**
 * The rows an answer proposes: the ones that conform, each matched against what
 * is held. Two rows that are counts of one thing held are one row, their
 * quantities summed when they are in the same unit, since a shelf photographed
 * from two sides shows its jars twice over and the model is told to count once.
 */
export function rowsOf(got, ctx, specs) {
    const raw = got && Array.isArray(got.rows) ? got.rows : [];
    const out = [];
    for (const r of raw.slice(0, 40)) {
        if (!r || typeof r !== "object" || fault(r))
            continue;
        const o = r;
        const name = String(o.name).trim().slice(0, 80);
        const spec = String(o.spec || name).trim().slice(0, 80);
        const match = matchOf({ name, spec }, ctx.held);
        const unit = String(o.unit || match?.unit || "each");
        const kind = String(o.expiresKind || "");
        const row = {
            name: match?.name ?? name, spec: match?.spec || spec, qty: Number(o.qty), unit,
            lot: String(o.lot || "").trim().slice(0, 40),
            expires: o.expires ? String(o.expires) : "",
            expiresKind: kind === "use-by" || kind === "best-before" ? kind : "",
            known: specs.includes(match?.spec || spec),
            match, unitDiffers: !!match && !!match.unit && match.unit !== unit,
        };
        const twin = match && out.find(x => x.match?.id === match.id);
        if (twin) {
            if (twin.unit === row.unit)
                twin.qty += row.qty;
            continue;
        }
        out.push(row);
    }
    return out;
}
/** A row with the figure a person typed or said in place of the model's. */
export function corrected(row, patch, held, specs) {
    const name = (patch.name ?? row.name).trim() || row.name;
    const renamed = name !== row.name;
    const spec = renamed ? name : row.spec;
    const match = renamed ? matchOf({ name, spec }, held) : row.match;
    const unit = (patch.unit ?? row.unit).trim() || row.unit;
    const qty = patch.qty !== undefined && Number.isFinite(patch.qty) && patch.qty >= 0 ? patch.qty : row.qty;
    return { ...row, name: match?.name ?? name, spec: match?.spec || spec, qty, unit, match,
        known: specs.includes(match?.spec || spec),
        unitDiffers: !!match && !!match.unit && match.unit !== unit };
}
export function markOf(row) {
    const m = row.match;
    if (!m)
        return "new";
    return row.unitDiffers ? "unsure" : standing(row.qty, m);
}
/** A row a person may land with the others in one tap: its figure is the ledger's, or inside what the plan expects. */
export const looksRight = (row) => { const k = markOf(row); return k === "agrees" || k === "within"; };
/** The row of a thing held of which the picture shows none: a count of nothing, for the person to land. */
export function zeroRow(held, specs) {
    return { name: held.name, spec: held.spec, qty: 0, unit: held.unit || "each", lot: "", expires: "", expiresKind: "",
        known: specs.includes(held.spec), match: held, unitDiffers: false };
}
/** The note a first sighting carries: that a picture showed it, and its lot and date where a label stated them. */
export function sightingNote(row) {
    const bits = ["seen in a photo"];
    if (row.lot)
        bits.push(`lot ${row.lot}`);
    if (row.expires)
        bits.push(`${row.expiresKind === "use-by" ? "use by" : row.expiresKind === "best-before" ? "best before" : "date"} ${row.expires}`);
    return bits.join(" · ");
}
/** Where a confirmed ROW lands: a count when it matches a thing held, a declaration when it does not. */
export function landingOf(row) {
    return row.match
        ? { door: "count", resource: row.match.id, qty: row.qty, unit: row.unit }
        : { door: "declare", spec: row.spec, name: row.name, qty: row.qty, unit: row.unit, note: sightingNote(row) };
}
/** The id declare-means gives a person's own stock of SPEC: means:<aid>:<spec>. */
export const meansId = (aid, spec) => `means:${aid}:${spec}`;
