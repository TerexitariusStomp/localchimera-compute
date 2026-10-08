// app/template.ts — a tagged-template renderer: escaped by default, keyed lists.
//
// The other half of what a framework like Svelte gives us (app/reactive.js is
// the first half), with no build step and no dependency. Panels declare their
// markup as one expression and hand it to render()/list(); the escaping and the
// DOM bookkeeping happen here, once, instead of per file.
//
//   render("#invledger", html`<b>${n}</b> kinds on hand`)
//   list("#inventory", rows, r => r.name, r => html`<li>…</li>`)
//
// Three properties the hand-rolled `.html(" … " + x + " … ")` pattern leaves to
// each author's memory:
//
//   ESCAPED BY DEFAULT — every ${…} is HTML-escaped on the way in, so live wire
//     data (resource names, place names, chat text) can't carry markup into the
//     page. Markup you MEAN passes through by being an html`` fragment itself
//     (they nest and compose), or by raw() when it arrives pre-built.
//
//   HANDLERS ARE FUNCTIONS — `onclick=${fn}` binds fn with addEventListener. The
//     attribute never reaches the document, so nothing is parsed as script and
//     the closure keeps its scope.
//
//   LISTS ARE KEYED — list() reuses the row element whose key came back, so a
//     redraw that changes one row leaves the other rows' nodes alone: hover,
//     focus, scroll anchoring and CSS transitions survive it.
//
// Attribute values interpolate INSIDE QUOTES: class="${cls}", not class=${cls}.
// Quoting is what makes escaping sufficient — an unquoted value ends at the
// first space, and no amount of escaping fixes that.
//
// This complements d3 rather than replacing it: d3 keeps the dial's SVG and the
// hot rAF loops, where the join and its data binding are the right tool. Panels
// are where the join is bookkeeping, and this is for panels.
import { themedMarkup } from './theme.js';
import { esc } from './esc.js';
import { effect } from './reactive.js';
// the one escape every panel shares (esc.ts), exported here because a few call
// sites still assemble strings by hand.
export { esc };
const FRAGMENT = Symbol("template-fragment");
const isFragment = (v) => !!v && v[FRAGMENT] === true;
// html`…` → a fragment: the literal strings, plus the values still unescaped so
// nesting can tell an inner fragment from a string that merely looks like markup.
export function html(strings, ...values) { return { [FRAGMENT]: true, strings, values }; }
// raw(s) → markup that passes through unescaped. For html the dial itself built
// (an SVG sprite, a snippet from another panel) — never for anything off a wire.
export const raw = (s) => ({ [FRAGMENT]: true, strings: [String(s ?? "")], values: [] });
// a value in content position: fragments recurse, arrays concatenate, nullish
// and booleans vanish (so `${cond && html`…`}` reads as a conditional), and
// everything else is text to escape.
function fill(value, handlers) {
    if (value == null || value === false || value === true)
        return "";
    if (Array.isArray(value))
        return value.map(v => fill(v, handlers)).join("");
    if (isFragment(value))
        return expand(value, handlers);
    return esc(value);
}
// `onclick=${fn}` — the trailing text of the chunk just written, when the value
// is a function. The event name is whatever follows `on`.
const HANDLER_SLOT = /(^|[\s"'>/])on([a-zA-Z]+)=$/;
// a fragment → its html string, collecting handlers as markers along the way.
function expand({ strings, values }, handlers) {
    let out = "";
    for (let i = 0; i < strings.length; i++) {
        out += strings[i];
        if (i >= values.length)
            continue;
        const value = values[i];
        const slot = typeof value === "function" && HANDLER_SLOT.exec(out);
        if (slot) {
            // drop the `onclick=` already written and leave a marker in its place, so
            // the document never carries an inline handler attribute.
            out = out.slice(0, slot.index + slot[1].length)
                + `data-ev${handlers.length}=""`;
            handlers.push({ type: slot[2].toLowerCase(), fn: value });
            continue;
        }
        out += fill(value, handlers);
    }
    return out;
}
// a fragment → detached nodes with their handlers bound, plus the html string it
// came from (list() compares those strings to decide what it can leave alone).
//
// The markup goes through themedMarkup() on the way in, the same pass theme.js
// gives d3's .html() (theme.js:paintThrough) — a colour written inline here maps
// through the theme in force exactly as one written through a d3 selection does.
//
// <template> is the parser because it holds any content — a bare <li> or <tr>
// survives here, where a <div>'s innerHTML would drop it.
function build(content) {
    const handlers = [];
    const markup = themedMarkup(expand(isFragment(content) ? content : html `${content}`, handlers));
    const holder = document.createElement("template");
    holder.innerHTML = markup;
    handlers.forEach((h, i) => {
        holder.content.querySelectorAll(`[data-ev${i}]`).forEach(node => {
            node.removeAttribute(`data-ev${i}`);
            node.addEventListener(h.type, h.fn);
        });
    });
    return { nodes: [...holder.content.childNodes], markup };
}
const resolve = (target) => typeof target === "string" ? document.querySelector(target) : target;
// render(target, content) — the element's children become `content`. Returns the
// element, or null when the target isn't in the page (a panel whose section the
// shell doesn't carry draws into nothing rather than throwing).
export function render(target, content) {
    const el = resolve(target);
    if (!el)
        return null;
    el.replaceChildren(...build(content).nodes);
    return el;
}
// panel(draw, className) — one persistent element for the life of the page,
// with its own effect rendering it fresh on every signal `draw` reads. The
// shape a Fragment-producing block (this module's own idiom, not d3) takes
// wherever it is mounted outside the normal render() tree it was built for —
// a settings room's "custom" row, the account sheet, the onboarding walk —
// so one implementation serves every place it is shown, memoized: the first
// caller for a given block builds it, and every caller after gets the same
// element back.
export function panel(draw, className = "panel") {
    let el = null;
    return () => {
        if (!el) {
            const e = document.createElement("div");
            e.className = className;
            el = e;
            effect(() => render(e, draw()));
        }
        return el;
    };
}
// list(target, items, keyOf, renderItem) — `items` become the element's children
// in order, each rendered by renderItem into its own root element. A key whose
// markup is unchanged since the last draw keeps its existing node untouched.
//
// Every item is rendered to a string each draw (that's how "unchanged" is known)
// and the saving is in the DOM, which is the expensive half. Rows that come and
// go are created and dropped; rows that stay, stay.
//
// The key is the row's identity, so a handler may close over anything the key
// determines: a reused node keeps the closure from the draw that made it, and
// that draw saw this same key.
export function list(target, items, keyOf, renderItem) {
    const el = resolve(target);
    if (!el)
        return null;
    const previous = el.__keyedRows || new Map();
    const current = new Map();
    const wanted = [];
    items.forEach((item, i) => {
        const key = String(keyOf(item, i));
        const built = build(renderItem(item, i));
        const was = previous.get(key);
        const node = was && was.markup === built.markup
            ? was.node
            : built.nodes.find(n => n.nodeType === Node.ELEMENT_NODE) || built.nodes[0];
        if (!node)
            return;
        current.set(key, { node, markup: built.markup });
        wanted.push(node);
    });
    // drop the nodes this draw doesn't carry forward: keys that went away, AND
    // keys that stayed but changed — a changed row gets a fresh node, so the one
    // it replaces leaves with it. (Keying alone doesn't retire it: the key is
    // still present, just holding different markup.)
    for (const [key, row] of previous) {
        const kept = current.get(key);
        if ((!kept || kept.node !== row.node) && row.node.parentNode === el)
            el.removeChild(row.node);
    }
    // place each node at its index; slots below i are settled, so the node sitting
    // at i is either ours already or one that belongs further down.
    wanted.forEach((node, i) => {
        const here = el.childNodes[i];
        if (here !== node)
            el.insertBefore(node, here || null);
    });
    el.__keyedRows = current;
    return el;
}
