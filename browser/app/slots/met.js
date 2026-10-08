// app/slots/met.ts — how a need is met: communal first, credit as fallback,
// then the gap.
//
// free-association's allocations panel lists the providers of a need in two
// tiers (⚡ priority-flow · 🌊 surplus-flow) — recognition tiers of a
// peer-to-peer allocation. Here a need is a STANDING ORDER the plan tries to
// meet, so the tiers are the three ways it can be met, in the order the
// commons prefers them:
//
//   communal  what the last solve PROVISIONS — the plan's own `met` fraction
//             for the need's spec (dial state PLAN.needs)
//   credit    what is individually CLAIMABLE at a place, drawn against your
//             credit through the shop — the inventory rows whose distribution
//             mode is claimable and whose spec is the need's
//   gap       what neither covers — the part that wants a contribution
//             (a shift on a recipe that makes it) or a proposal
//
// One reading per slot. The communal fraction comes on the row itself when the
// wire has it (need-slot-row `met`, the last solve's provision of the spec);
// the plan in the page is the fallback (the demo, or a row from before a solve).
import { EXT, PLAN } from '../core.js';
import { idHint } from '../tabs/social/id.js';
import { num } from '../count.js';
export function metOf(slot) {
    const want = Math.max(0, num(slot.qty));
    const plan = PLAN && PLAN();
    // the plan's need row for this slot: by spec first; else by the slot's cats
    // (the classify pass files a slot under the same term ids the plan keys its
    // needs by); else by name — the demo rails meet the demo plan that way
    const low = String(slot.name || "").toLowerCase();
    const cats = new Set([...(slot.cats || []), ...(slot.cats || []).map(c => c.split("/").pop() || c)]);
    // A want stated for oneself is delivered on the citizen's OWN good, and
    // the plan's row for it carries `for` (the owner) with id "spec~aid"
    // (service.scm plan-results->dial-plan) — so MY row comes first, then the
    // scope's own row for the spec, never another citizen's.
    const me = (idHint() || {}).aid || "";
    const need = plan && ((me && (plan.needs || []).find(n => n.for === me && n.id === `${slot.spec}~${me}`))
        || (plan.needs || []).find(n => !n.for && n.id === slot.spec)
        || (plan.needs || []).find(n => cats.has(n.id) || cats.has(n.id.split("/").pop() || n.id))
        || (plan.needs || []).find(n => low && String(n.label || "").toLowerCase() === low));
    const own = slot.met != null && isFinite(Number(slot.met)) ? Number(slot.met) : null;
    const cf = Math.max(0, Math.min(1, own != null ? own : need ? num(need.met) : 0));
    const communal = { qty: cf * want, frac: cf,
        via: need && need.recipeId ? String(need.recipeId) : null };
    const inv = EXT.inventory;
    const sources = ((inv && inv.resources) || [])
        .filter(r => (r["distribution-mode"] || "") === "claimable"
        && ((r["conforms-to"] || r.spec || "") === slot.spec)
        && num(r.onhand) > 0)
        .map(r => ({ rid: String(r.id || ""),
        at: String(r["current-location"] || r.where || r.location || "the commons"),
        onhand: num(r.onhand), unit: String(r.unit || slot.unit || "") }));
    const claimable = sources.reduce((a, s) => a + s.onhand, 0);
    const left = Math.max(0, want - communal.qty);
    const cq = Math.min(left, claimable);
    const credit = { qty: cq, frac: want ? cq / want : 0, sources };
    const gq = Math.max(0, want - communal.qty - cq);
    return { want, unit: slot.unit || "", communal, credit,
        gap: { qty: gq, frac: want ? gq / want : 0 },
        any: communal.qty > 0 || sources.length > 0 };
}
