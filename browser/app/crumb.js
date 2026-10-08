// app/crumb.ts — the header breadcrumb, and the ＋ that jumps anywhere.
//
// Three things in one line, and they are three different trees, which is why
// the separators differ:
//
//   playnet          the wordmark, spelt across the shared spectrum — the
//                    scroll's one door
//   › earth › …      the SCOPE path: earth, region, commune. Reactive, so a
//                    switch or the roster arriving redraws it. A segment jumps
//                    to that level; earth resets to the whole commons.
//   · … ·            the TAXONOMY focus below the dial's root, plus the map
//                    leaf when the earth face is up.
//
// The crumb renders; app/scope.js decides what a scope IS. The focus chain
// arrives from the host already resolved to "what it says and what tapping it
// does", so this file never learns what a focus node is either.
import { scopeSig, scopeChain, allScopes, goToScope } from './scope.js';
import { html, render } from './template.js';
let host;
let menu = null;
function closeScopeMenu() {
    if (menu) {
        menu.remove();
        menu = null;
    }
}
/** Every scope's path, folded into one tree — shared prefixes share a node. */
function buildPickTree() {
    const roots = [];
    const byPath = new Map();
    for (const s of allScopes()) {
        if (!Array.isArray(s.path) || !s.path.length)
            continue;
        let siblings = roots, pathKey = "", node;
        for (const seg of s.path) {
            pathKey += "/" + seg.name.toLowerCase();
            node = byPath.get(pathKey);
            if (!node) {
                node = { name: seg.name, key: seg.name.toLowerCase(), children: [] };
                byPath.set(pathKey, node);
                siblings.push(node);
            }
            siblings = node.children;
        }
        if (node)
            node.scope = s.id;
    }
    const sortRec = (ns) => {
        ns.sort((a, b) => a.name.localeCompare(b.name));
        ns.forEach(n => sortRec(n.children));
    };
    sortRec(roots);
    return roots;
}
/** Whether typing `f` matches this node, or anything under it. */
function subtreeMatches(n, f) {
    return !f || n.key.includes(f) || n.children.some(c => subtreeMatches(c, f));
}
/**
 * The ＋ affordance: the whole commons as a tree — country, region, commune —
 * type to filter, click a branch to open it, click a place to go there. A
 * flat "USA › California › Oakland" line said the same thing on every row;
 * the tree says it once and lets you walk down it instead of reading it.
 */
function openScopePicker(anchorEl) {
    closeScopeMenu();
    const cur = scopeSig();
    const roots = buildPickTree();
    // earth — the whole commons — is the crumb's implicit root, not a roster
    // entry, so it doesn't fall out of allScopes(); it's a plain leaf row here,
    // above the tree, whenever you're not already there.
    if (cur !== null)
        roots.unshift({ name: "🜨 earth — the whole commons", key: "earth whole commons", children: [], scope: "" });
    // Expanded-by-default: the branch that holds where you already are, so
    // opening the picker shows your own place in the tree, not a wall of
    // collapsed countries.
    const expanded = new Set();
    (function openToCurrent(ns) {
        for (const n of ns) {
            if (n.scope === cur || openToCurrent(n.children)) {
                expanded.add(n);
                return true;
            }
        }
        return false;
    })(roots);
    const m = document.createElement("div");
    m.className = "scopepick";
    const input = document.createElement("input");
    input.className = "scopepick-in";
    input.placeholder = "go to a place…";
    input.autocomplete = "off";
    const list = document.createElement("div");
    list.className = "scopepick-list";
    m.appendChild(input);
    m.appendChild(list);
    let sel = 0, shown = [];
    const choose = (n) => {
        closeScopeMenu();
        if (n.scope === undefined || n.scope === cur)
            return;
        goToScope(n.scope);
        host.closeRecipeCard();
    };
    const flatten = (ns, depth, f, out) => {
        for (const n of ns) {
            if (!subtreeMatches(n, f))
                continue;
            out.push({ node: n, depth });
            // filtering opens every matching branch — hunting for a match through
            // manual expand/collapse would defeat the point of typing at all
            if ((f || expanded.has(n)) && n.children.length)
                flatten(n.children, depth + 1, f, out);
        }
    };
    // Rebuilt whole on every keystroke, every arrow key and every expand toggle
    // — a filtered/expanded row list holds no state a re-render would lose,
    // unlike `input` itself (which stays the one stable node, built once above).
    const redraw = () => {
        const f = input.value.toLowerCase().trim();
        shown = [];
        flatten(roots, 0, f, shown);
        if (sel >= shown.length)
            sel = Math.max(0, shown.length - 1);
        render(list, !shown.length
            ? html `<div class="scopepick-opt muted">no match</div>`
            : shown.map(({ node: n, depth }, i) => {
                const branch = n.children.length > 0;
                const open = branch && (f !== "" || expanded.has(n));
                const act = () => branch ? toggle(n) : choose(n);
                return html `<div class="scopepick-opt${branch ? " branch" : ""}${i === sel ? " sel" : ""}${n.scope === cur && n.scope !== undefined ? " on" : ""}"
             style="padding-left:${10 + depth * 16}px"
             onmouseenter=${() => {
                    // a light touch: retint the row under the pointer without
                    // rebuilding the list, so hovering along it stays smooth
                    sel = i;
                    [...list.children].forEach((c, j) => c.classList.toggle("sel", j === i));
                }} onclick=${act}>${branch ? html `<span class="scopepick-caret">${open ? "▾" : "▸"}</span>` : ""}${n.name}</div>`;
            }));
    };
    const toggle = (n) => {
        if (expanded.has(n))
            expanded.delete(n);
        else
            expanded.add(n);
        redraw();
    };
    input.oninput = () => { sel = 0; redraw(); };
    input.onkeydown = e => {
        if (e.key === "ArrowDown") {
            sel = Math.min(shown.length - 1, sel + 1);
            redraw();
            e.preventDefault();
        }
        else if (e.key === "ArrowUp") {
            sel = Math.max(0, sel - 1);
            redraw();
            e.preventDefault();
        }
        else if (e.key === "ArrowRight") {
            const n = shown[sel]?.node;
            if (n && n.children.length && !expanded.has(n))
                toggle(n);
            e.preventDefault();
        }
        else if (e.key === "ArrowLeft") {
            const n = shown[sel]?.node;
            if (n && expanded.has(n))
                toggle(n);
            e.preventDefault();
        }
        else if (e.key === "Enter") {
            const n = shown[sel]?.node;
            if (n)
                (n.children.length ? toggle(n) : choose(n));
            e.preventDefault();
        }
        else if (e.key === "Escape") {
            closeScopeMenu();
        }
    };
    document.body.appendChild(m);
    menu = m;
    const r = anchorEl.getBoundingClientRect();
    // the pill lives in the bottom bar: the picker rises above it rather than hanging below
    m.style.left = Math.max(8, Math.min(Math.round(r.left), innerWidth - 268)) + "px";
    if (r.top > innerHeight / 2)
        m.style.bottom = Math.round(innerHeight - r.top + 6) + "px";
    else
        m.style.top = Math.round(r.bottom + 6) + "px";
    redraw();
    input.focus();
    // Deferred by a tick so the very click that opened the menu does not close it.
    const onDown = (ev) => {
        if (menu && !menu.contains(ev.target)) {
            document.removeEventListener("pointerdown", onDown);
            closeScopeMenu();
        }
    };
    setTimeout(() => document.addEventListener("pointerdown", onDown), 0);
}
/** Redraw the whole crumb. Run inside an effect over the scope signals. */
export function drawCrumb() {
    const c = d3.select("#crumb").html("");
    // the SCOPE — one pill naming where you are, not the whole path down to
    // here. It stands with the clock and the pin in the bottom bar: a standpoint
    // is the same kind of choice as when and where. Tapping it opens the
    // searchable picker (keyboard-navigable, the allScopes() roster); the path
    // lives there.
    const chain = scopeChain();
    const leaf = chain[chain.length - 1];
    const atEarth = leaf.id === "earth";
    const pill = c.append("span")
        .attr("class", "scopepill")
        .attr("title", atEarth ? "the whole commons — tap to go somewhere" : "go to a place…")
        .on("click", function (e) {
        if (e)
            e.stopPropagation();
        openScopePicker(this);
    });
    pill.append("span").attr("class", "scopepill-i").text(atEarth ? "🜨" : "📍");
    pill.append("span").attr("class", "scopepill-l").text(atEarth ? "earth" : leaf.name);
    // the taxonomy / labour focus below the root: a small trail above the bar,
    // there only while there is a focus to walk back out of
    let trail = document.getElementById("focuscrumb");
    if (!trail) {
        trail = document.createElement("div");
        trail.id = "focuscrumb";
        document.body.append(trail);
    }
    const f = d3.select(trail).html("");
    const tax = host.focusChain();
    tax.forEach((nd, i) => {
        if (i)
            f.append("span").attr("class", "crumbsep").text(" › ");
        const seg = f.append("span").attr("class", nd.go ? "seg" : "seg here").text(nd.name);
        if (nd.go)
            seg.on("click", nd.go);
    });
    trail.classList.toggle("on", tax.length > 0);
}
/** Hand the crumb the dial it draws for. */
export function initCrumb(h) {
    host = h;
}
