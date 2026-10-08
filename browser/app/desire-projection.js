// app/desire-projection.ts — the desire→spend projection, shared.
//
// One home for the pieces both the shop face and the dial's spend wheel
// need, so neither reinvents the other and no main⇄tabs import cycle
// forms: the phase-curve evaluator (bumpSum), the category denylist
// (mirrored server-side by folksonomy/graph.scm %non-category-prefixes),
// the spine lookups (termNode/termOf over S.root/S.desc), the claimable
// catalog reader (live wire or the demo seed), and the weight
// normalization behind playnet.typ's order-book projection
//     Q(r) = K·v_cons · ŵ(r) / SNLT_cryst(r).
// Imports only state.js at runtime — safe for main.js AND tabs/*.js alike. The
// other two imports are `import type`, which emits nothing.
import { S } from './state.js';
// the need's phase curve: base + wrapped gaussian bumps over the turn
export const bumpSum = (base, bumps, t) => {
    let w = base;
    for (const [peak, width, amp] of bumps || []) {
        let dc = Math.abs(t - peak);
        dc = Math.min(dc, 24 - dc);
        w += amp * Math.exp(-(dc / width) * (dc / width));
    }
    return w;
};
// EXCLUDE non-category tags that still ride in classifiedAs in the (being-
// retired) relational/DDMRP layer — control-plane (tag:plan:), config
// (tag:buffer:), the allergen-free requirement, and the already-promoted
// distribution/container/role flags.
export const NON_CATEGORY = /^(tag:plan:|tag:buffer:|vf:allergen-free:)/;
export const isCategory = (c) => c && !NON_CATEGORY.test(c) &&
    !["communal", "individually-claimable", "individual claimable",
        "stationary", "isPrimary"].includes(c);
// the term's node on the dial's spine (S.root — buildRoot output, with
// means()-stamped _meanW, tintTree hues, live labels, parent pointers)
export function termNode(tid, node = S.root) {
    if (!node || tid == null)
        return null;
    if (node.id === tid)
        return node;
    for (const c of node.children || []) {
        const r = termNode(tid, c);
        if (r)
            return r;
    }
    return null;
}
// a spec's categories → the term it shelves under: the shared denylist,
// then the SAME descendant index the work-intent `serves` match uses
export function termOf(cats) {
    const cs = (cats || []).filter((c) => typeof c === "string" && Boolean(isCategory(c)));
    if (S.desc)
        for (const c of cs)
            for (const [tid, set] of S.desc)
                if (set.has(c))
                    return tid;
    const c = cs[0] || "";
    return c.split("/")[0] || "other";
}
// the demo's claimable catalogue and what its ledger holds are the demo world's (demo/world.ts)
import { DEMO_SPECS } from './demo/world.js';
export { DEMO_SPECS, DEMO_RESOURCES, DEMO_KEPT_BY_SPEC, demoHeld } from './demo/world.js';
// the claimable items — live wire when the snapshot carries an inventory,
// the demo seed otherwise. Each item: { id (spec), term }.
export function claimableItems(ext) {
    const inv = (ext && ext.inventory) || undefined;
    if (inv && Array.isArray(inv.resources) && inv.resources.length) {
        const specs = {};
        (inv.specs || []).forEach(s => { specs[s.id] = s; });
        const seen = new Set(), items = [];
        for (const r of inv.resources) {
            if ((r["distribution-mode"] || "") !== "individual-claimable")
                continue;
            const sid = r["conforms-to"] || r.spec || "";
            if (!sid || seen.has(sid))
                continue;
            seen.add(sid);
            items.push({ id: sid, term: termOf(Array.from((specs[sid] || {}).categories || [])) });
        }
        return items;
    }
    return DEMO_SPECS.map(s => ({ id: s.id, term: termOf(s.cats) }));
}
// ŵ: the normalized priority weight per claimable spec — the term's mean
// desire weight (the dial's own _meanW) shared equally among the term's
// claimable specs, unit-sum over the whole pool. THE normalization the
// shop's projectDesire and the dial's spend wheel must agree on.
export function normalizedSpecWeights(items) {
    const perTerm = new Map();
    for (const it of items)
        perTerm.set(it.term, (perTerm.get(it.term) || 0) + 1);
    // perTerm was just counted from these same items, so every term has an entry —
    // an `|| 1` fallback here would invent arithmetic for a case that cannot arise.
    const raw = items.map(it => Math.max(0.02, termNode(it.term)?._meanW || 0.12) / perTerm.get(it.term));
    const tot = raw.reduce((a, b) => a + b, 0) || 1;
    const w = new Map();
    items.forEach((it, i) => w.set(it.id, raw[i] / tot));
    return w;
}
// the spend MASS each of the dial's current bands carries: the share of
// drawable credit flowing to claimable goods within that band's subtree.
// Terms outside the spine (not yet in the commune's cut) carry no band to
// swell — they surface in the shop's unexpressed group instead.
export function spendMassByTerm(children, ext) {
    const items = claimableItems(ext);
    const w = normalizedSpecWeights(items);
    const mass = new Map();
    for (const it of items) {
        for (let p = termNode(it.term); p; p = p.parent)
            if (children.includes(p)) {
                mass.set(p, (mass.get(p) || 0) + (w.get(it.id) || 0));
                break;
            }
    }
    return mass;
}
