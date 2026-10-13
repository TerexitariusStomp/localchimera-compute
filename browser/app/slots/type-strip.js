// app/slots/type-strip.ts — the folksonomy "type" strip: the spine as a drill above the expression bar.
//
// DISABLED. Nothing imports this module: the draft panel (slots/draft.ts) has no "type" tab and the
// expression bar's name field raises no strip, so the folksonomy and the panel share no code path.
// Re-enabling is two edits — add "type" to DraftTab and TABS in draft.ts (render: typeStrip(...).render,
// reset: its .close on the panel's close), and raise it from the name field in tabs/social/share.ts.
//
// The strip reads the spine (S.root) and the catalogue of known specs, and writes through the panel's
// own seams only: the pill's fields, the draft's spec and cats, and the panel's close.
import { S } from '../state.js';
import { EXT, PLAN } from '../core.js';
import { termChain, indexDescendants } from '../spine.js';
import { knownSpecRows, knownEmoji } from './model.js';
import { mk as el } from '../dom.js';
export function typeStrip(cfg) {
    const { body, draft, close } = cfg;
    // ── type: pick a real spec, grouped by where the spine files it ──────────
    // A branch's cells are the SPECS classified under it (an inventory spec's
    // own categories, or a plan need — whose id in this taxonomy IS a term-id)
    // — the citizen names a real, declarable thing, not a category. A leaf with
    // nothing catalogued yet falls back to the bare term, so the picker still
    // seeds a new spec's cats and never goes empty.
    const pickSpec = (name, emoji, spec, cats) => {
        cfg.pill.set({ name, ...(emoji ? { emoji } : {}) });
        draft.spec = spec;
        draft.cats = cats;
        close();
        cfg.pill.focus("qty");
    };
    // the specs filed AT a node — exactly that node, not its ancestors or its
    // siblings' branches; indexDescendants makes a leaf's own set just {itself}
    const specsAt = (rows, desc, k) => {
        const under = desc.get(k.id) || new Set([k.id]);
        return rows.filter(r => r.cats.some(c => under.has(c)));
    };
    // does q match somewhere in k's own subtree — its name, a descendant
    // term's name, or a spec filed anywhere under it? The one predicate a
    // query filters EVERY level's segments through, so typing narrows the
    // SAME bars rather than swapping to a different view.
    const nameMatches = (n, q) => String(n.name || n.id).toLowerCase().includes(q)
        || (n.children || []).some(c => nameMatches(c, q));
    const subtreeMatches = (n, q, rows, desc) => nameMatches(n, q) || specsAt(rows, desc, n).some(r => r.name.toLowerCase().includes(q));
    // ── type: drill down the spine, one block per level ──────────────────────
    // Each level is a group of segments — every sibling as wide as its words
    // need, wrapping to further lines, tinted by the term's own colour (the same palette the
    // wheel already reads off S.root) — dim until picked, solid once it is. One
    // tap drills to that term's children as the row below; the row above stays,
    // so the whole path down reads as a stack, not a single swap. At a leaf
    // (nothing further to drill into) the next row is either the real specs
    // filed there, or — filed with nothing yet — one line that commits the
    // bare term itself.
    //
    // A level is a GROUP of siblings, and its label is never cut: the segments
    // wrap onto as many lines as the words need, each keeping its own width, so
    // the whole group stays one tinted block. A child level sits indented under
    // its parent with a rail in the parent's colour (`sp-child`, --row-col), so
    // "one of these siblings, and what is inside it" reads at a glance.
    //
    // A QUERY filters this SAME structure rather than replacing it: a segment
    // shows only when it (or something in its own subtree — a descendant
    // term's name, or a spec filed anywhere under it) matches. A manual drill
    // (typePath) is NOT reset by typing, so narrowing while already three
    // levels deep re-filters all three bars in place. With no manual drill yet,
    // a query auto-opens the path down through each level's SOLE match — the
    // classification "opens up below" as you type instead of sitting closed
    // until tapped — and stops auto-descending the moment a level has more
    // than one match, handing the choice back to a tap.
    let typePath = [];
    const autoPath = (spine, q, rows, desc) => {
        const path = [];
        let cur = spine;
        for (;;) {
            const kids = (cur.children || []).filter(n => subtreeMatches(n, q, rows, desc));
            if (kids.length !== 1)
                break;
            path.push(kids[0]);
            cur = kids[0];
        }
        return path;
    };
    const renderTypeDrill = (q) => {
        const spine = S.root;
        const em = knownEmoji(EXT, PLAN);
        const desc = indexDescendants(spine);
        const rows = knownSpecRows(EXT, PLAN);
        const path = typePath.length ? typePath : (q ? autoPath(spine, q, rows, desc) : []);
        let shown = 0;
        // a row of siblings, under PARENT (none at the top): indented and railed
        // in the parent's colour when it is a child level
        const groupOf = (row, depth, parent) => {
            row.style.setProperty("--depth", String(Math.min(depth, 4)));
            if (parent) {
                row.classList.add("sp-child");
                row.style.setProperty("--row-col", parent.col || "#9a9384");
            }
        };
        const segRow = (all, depth, parent) => {
            const items = q ? all.filter(n => subtreeMatches(n, q, rows, desc)) : all;
            if (!items.length)
                return;
            const row = el("div", "sp-segrow");
            groupOf(row, depth, parent);
            for (const n of items) {
                const active = path[depth] === n;
                const seg = el("a", "sp-seg" + (active ? " on" : ""), n.name || n.id);
                seg.style.setProperty("--seg-col", n.col || "#9a9384");
                seg.addEventListener("click", () => {
                    typePath = active ? path.slice(0, depth) : path.slice(0, depth).concat(n);
                    renderBody();
                });
                row.appendChild(seg);
                shown++;
            }
            body.appendChild(row);
        };
        // the top level is the strip's first row and stays while a term under it
        // is open — lit on that term, so the strip reads as one filter from the
        // top down; a second tap on the lit term steps back up, as at any level
        segRow(spine.children || [], 0);
        path.forEach((n, i) => segRow(n.children || [], i + 1, n));
        const deepest = path[path.length - 1];
        if (deepest && !(deepest.children && deepest.children.length)) {
            const specs = specsAt(rows, desc, deepest).filter(r => !q || r.name.toLowerCase().includes(q));
            if (specs.length) {
                const row = el("div", "sp-segrow sp-segrow-specs");
                groupOf(row, path.length, deepest);
                for (const r of specs) {
                    const e = r.emoji || em.get(r.id) || em.get(r.name.toLowerCase()) || "";
                    const seg = el("a", "sp-seg sp-seg-spec", (e ? e + " " : "") + r.name);
                    seg.addEventListener("click", () => pickSpec(r.name, e, r.id, r.cats));
                    row.appendChild(seg);
                    shown++;
                }
                body.appendChild(row);
            }
            else if (!q) {
                const ghost = el("div", "sp-ghost", `nothing filed under “${deepest.name || deepest.id}” yet — `);
                const commit = el("a", "sp-seg-commit", `use it as a new spec`);
                commit.addEventListener("click", () => pickSpec(deepest.name || deepest.id, em.get(deepest.id) || "", null, termChain(deepest)));
                ghost.appendChild(commit);
                body.appendChild(ghost);
                shown++;
            }
        }
        if (!shown)
            body.appendChild(el("div", "sp-ghost", cfg.canDeclare && !cfg.canDeclare()
                ? "nothing in the taxonomy says this"
                : "nothing in the taxonomy says this — ➕ declares it as a new term"));
    };
    // re-render just the type body without touching the panel's open/closed
    // state or the other tabs — a drill click (or a keystroke) never leaves it
    const renderBody = () => { body.replaceChildren(); renderType(); };
    const renderType = () => {
        const q = cfg.pill.get().name.trim().toLowerCase();
        const spine = S.root;
        if (!spine || !(spine.children || []).length) {
            body.appendChild(el("div", "sp-ghost", "no taxonomy yet — the name you type declares as-is"));
            return;
        }
        renderTypeDrill(q);
    };
    return { render: renderType, reset: () => { typePath = []; } };
}
