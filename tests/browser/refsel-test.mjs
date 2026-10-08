// tests/browser/refsel-test.mjs — the feedback lane's element references.
//
// Someone points at a piece of the interface, says what they mean about it,
// and the reference travels: into a JSON body, past a maintainer's eye, and
// back through querySelector to flash the element while they are still on
// the page. app/refsel.js is the pure half of that — a tree in, a selector
// and a label out — so its rules are checkable without a browser.
//
// The claim worth holding is the REFUSAL. A class or id CSS cannot address
// (a colon, a slash, a leading digit) spliced into a selector makes
// querySelector THROW, and the throw lands inside the chip's click handler
// — one exotic class name anywhere on the page and pointing at it takes the
// lane down. refsel drops what it cannot address instead.
//
// Run: node tests/browser/refsel-test.mjs

import { selectorFor, labelFor, withinFor } from '../../browser/app/refsel.js';

import { harness } from './assert.mjs';
const { check, done } = harness();
const eq = (label, got, want) =>
  check(label, got === want, got === want ? "" : `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);

// A tree double: exactly the members refsel reads (see its ElementLike).
const el = (tag, { id = "", cls = [], text = "", kids = [], layer = null } = {}) => {
  const node = {
    tagName: tag.toUpperCase(), id, textContent: text,
    classList: { length: cls.length, item: i => cls[i] ?? null },
    parentElement: null, children: kids,
    getAttribute: name => (name === "data-layer" ? layer : null),
  };
  for (const k of kids) k.parentElement = node;
  return node;
};
const leaf = (t, o) => el(t, o);

// ── an id anchors and stops the climb ────────────────────────────────

{
  const target = leaf("button", { id: "sbmic" });
  const root = el("div", { cls: ["outer"], kids: [el("div", { kids: [target] })] });
  eq("an id anchors the selector and stops the climb",
     selectorFor(target, null), "#sbmic");
  check("the ancestors above an id contribute nothing",
        !selectorFor(target, null).includes("div"));
  eq("an ancestor's id anchors the chain",
     selectorFor(root.children[0].children[0], null), "#sbmic");
}

// ── tag.class chains, capped ─────────────────────────────────────────

{
  const target = leaf("span", { cls: ["fb-chip", "on", "extra"] });
  const parent = el("div", { cls: ["fb-chips"], kids: [target] });
  const root = el("div", { id: "fbpanel", kids: [parent] });
  eq("classes cap at two", selectorFor(target, root),
     "div.fb-chips > span.fb-chip.on");
  eq("the stop element is excluded", selectorFor(parent, root), "div.fb-chips");
}

// ── :nth-of-type only when the tag repeats ───────────────────────────

{
  const a = leaf("li", { cls: ["row"] });
  const b = leaf("li", { cls: ["row"] });
  const only = leaf("p", {});
  const ul = el("ul", { id: "list", kids: [a, b, only] });
  eq("a repeated tag takes its nth-of-type",
     selectorFor(b, null), "#list > li.row:nth-of-type(2)");
  eq("the first of a repeated tag is nth-of-type(1)",
     selectorFor(a, null), "#list > li.row:nth-of-type(1)");
  eq("a tag alone among its siblings takes no nth-of-type",
     selectorFor(only, null), "#list > p");
}

// ── the hop cap ──────────────────────────────────────────────────────

{
  let node = leaf("i", {});
  const target = node;
  for (let i = 0; i < 12; i++) node = el("div", { kids: [node] });
  const sel = selectorFor(target, null);
  eq("the chain caps at six hops", sel.split(" > ").length, 6);
  check("a capped chain is relative, so it carries no root anchor",
        !sel.startsWith("#"));
}

// ── refusal: names CSS cannot address ────────────────────────────────

{
  const weird = leaf("div", { cls: ["w-1/2", "hover:bg", "ok-name"] });
  const root = el("main", { id: "main", kids: [weird] });
  const sel = selectorFor(weird, null);
  eq("unaddressable classes are dropped, addressable ones kept",
     sel, "#main > div.ok-name");
  check("no slash survives into a selector", !sel.includes("/"));
  check("the only colon a selector may carry is :nth-of-type",
        sel.replace(/:nth-of-type\(\d+\)/g, "").indexOf(":") === -1);
}

{
  const digitId = leaf("div", { id: "3d-map", cls: ["globe"] });
  const root = el("main", { id: "main", kids: [digitId] });
  const sel = selectorFor(digitId, null);
  check("an id CSS cannot address is not spliced in", !sel.includes("3d-map"));
  eq("…and the element still gets a usable selector", sel, "#main > div.globe");
}

{
  const allBad = leaf("div", { cls: ["1bad", "w/2"] });
  eq("an element with nothing addressable yields a bare tag",
     selectorFor(allBad, null), "div");
}

// Every selector this module produces must be one querySelector accepts.
// Node has no DOM, so assert the property the throw would come from: the
// output holds only characters CSS reads as structure.
{
  const cases = [
    leaf("span", { cls: ["a:b", "c/d"] }),
    leaf("div", { id: "9lives" }),
    leaf("p", { cls: ["-ok", "_also"] }),
  ];
  const bad = cases
    .map(c => selectorFor(el("div", { id: "root", kids: [c] }).children[0], null))
    .filter(s => !/^[#A-Za-z0-9_.>:()\s-]*$/.test(s));
  check("no selector carries a character querySelector would reject",
        bad.length === 0, bad.join(", "));
}

// ── labels are for people ────────────────────────────────────────────

eq("a label names by id when there is one",
   labelFor(leaf("button", { id: "fbbtn", cls: ["x"] })), "#fbbtn");
eq("…else by tag.class", labelFor(leaf("button", { cls: ["share-add"] })), "button.share-add");
eq("…else by tag alone", labelFor(leaf("svg", {})), "svg");
// The text is what the person actually SAW, so a named element carries both.
eq("a named element carries its visible text too",
   labelFor(leaf("span", { cls: ["scopepill-l"], text: "demo" })), "span.scopepill-l “demo”");
eq("an id carries its text too",
   labelFor(leaf("button", { id: "fbbtn", text: "send" })), "#fbbtn “send”");
eq("an unnamed element is known by its text", labelFor(leaf("button", { text: "send" })), "button “send”");
eq("a long text is elided", labelFor(leaf("div", { text: "a very long piece of interface text" })),
   "div “a very long piece …”");
eq("whitespace in a label collapses", labelFor(leaf("div", { text: "  two\n  words " })),
   "div “two words”");
// A label is prose, not a selector — it may hold what a selector refuses.
eq("a label keeps a name CSS cannot address", labelFor(leaf("div", { cls: ["w-1/2"] })), "div.w-1/2");

// ── the dial's svg layers name themselves (layers.ts stamps data-layer) ──
//
// Without this the wheel is twenty anonymous <g>s and a reference into it can
// only count: "#dial > g:nth-of-type(18) > path:nth-of-type(9)" says nothing
// about which module drew the thing being complained about.

{
  const target = leaf("path", {});
  const inner = el("g", { cls: ["clickable"], kids: [target] });
  const layer = el("g", { layer: "frag", kids: [inner] });
  const root = el("svg", { id: "dial", kids: [layer] });
  const sel = selectorFor(target, null);
  eq("a layer addresses itself by name, not by position",
     sel, '#dial > g[data-layer="frag"] > g.clickable > path');
  check("no positional counting survives where a layer is named",
        !sel.includes("nth-of-type"));
  eq("a layer's own label reads as its name", labelFor(layer), "g[frag]");
}

// ── within: what to grep for when the element itself is anonymous ────

{
  const target = leaf("path", {});
  const inner = el("g", { cls: ["clickable"], kids: [target] });
  const layer = el("g", { layer: "frag", kids: [inner] });
  el("svg", { id: "dial", kids: [layer] });
  eq("an anonymous element reports the nearest thing that IS named",
     withinFor(target, null), "g.clickable");
}

{
  // nothing between the path and its layer says anything: the climb has to
  // pass the anonymous groups d3 nests to reach the name that helps
  const target = leaf("path", {});
  const layer = el("g", { layer: "frag",
                          kids: [el("g", { kids: [el("g", { kids: [target] })] })] });
  el("svg", { id: "dial", kids: [layer] });
  eq("…climbing past unnamed ancestors to reach it",
     withinFor(target, null), 'g[data-layer="frag"]');
}

{
  const named = leaf("div", { cls: ["shop-card"] });
  el("div", { id: "shopface", kids: [named] });
  eq("an element that names itself needs no within", withinFor(named, null), "");
}

{
  const lonely = leaf("path", {});
  el("g", { kids: [el("g", { kids: [lonely] })] });
  eq("nothing named anywhere above reports nothing, rather than guessing",
     withinFor(lonely, null), "");
}

done();
