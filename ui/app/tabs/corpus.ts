// app/tabs/corpus.ts — the "corpus" face: the FEDERATION's shared corpus,
// searched directly (docs/planning/faces/corpus-guile-native.md §4a) — every
// domain under docs/corpus/, not scoped to any one commune's recipes. The
// `recipes` face shows how THIS scope makes what it makes; this face is
// the source literature that justifies those recipes, browsable on its
// own terms.
//
// One search box, hybrid-ranked (BM25 + dense, entirely in Guile — the
// gateway's `corpus-search` door, module/playnet/gateway/corpus-service.scm).
// A domain filter narrows to one corpus; left on "all", results merge
// across every built domain by their own fusion score.
//
// The omnibar's own "search" verb (app/utter.ts) lands here too: a typed
// or spoken question ("what fixes nitrogen in soil") sets PENDING-QUERY
// and opens this face — setPendingQuery below is that one door, so the
// omnibar never needs to know this face's internal DOM.

import { seam } from '../seam.js';
import { esc } from '../template.js';
import { withTimeout } from '../voice/audio.js';

let pendingQuery: string | null = null;
let pendingDomain = "";

/** The omnibar's door: queue a query (and optionally a domain) for this
 *  face to run the moment it mounts or is already open. */
export function setPendingQuery(query: string, domain = ""): void {
  pendingQuery = query;
  pendingDomain = domain;
  if (mounted) runSearch(query, domain);
}

interface Hit {
  domain: string; text: string; heading: string; source: string;
  title: string; author: string; score: number;
}
interface Reply { hits?: Hit[]; error?: string; domains?: string[] }

const state = { query: "", domain: "", busy: false, error: "", hits: [] as Hit[], domains: [] as string[] };

function hitCard(h: Hit): string {
  const snippet = h.text.length > 420 ? h.text.slice(0, 420).trim() + "…" : h.text;
  return `<div class="cp-hit">
    <div class="cp-hit-h"><span class="cp-hit-domain">${esc(h.domain)}</span>
      <span class="cp-hit-title">${esc(h.title || h.source)}</span>
      ${h.author ? `<span class="cp-hit-author">${esc(h.author)}</span>` : ""}
      ${h.heading ? `<span class="cp-hit-heading">§ ${esc(h.heading)}</span>` : ""}</div>
    <div class="cp-hit-text">${esc(snippet)}</div>
  </div>`;
}

let searchGen = 0;
async function runSearch(query: string, domain: string): Promise<void> {
  const gen = ++searchGen;
  state.query = query; state.domain = domain; state.busy = true; state.error = ""; state.hits = [];
  render();
  const H = seam.handlers;
  if (!H || !H.corpusSearch) {
    if (gen !== searchGen) return;
    state.busy = false; state.error = "offline — the gateway isn't reachable"; render(); return;
  }
  try {
    // deploy/UPSTREAM-ISSUES.md #14: a query larger than any prior one sent
    // on this same gateway connection can hang forever with no error — a
    // real transport bug, not a slow search. Bounding it turns a silent
    // hang into a visible "search failed" the citizen can retry.
    const raw = await withTimeout(H.corpusSearch(domain, query, 10), 10000, "corpus search");
    // a newer runSearch may have started (and already rendered its own
    // state.query) while this one's gateway round-trip was still in
    // flight — writing this reply now would show the new query text next
    // to this older, unrelated reply's hits (verified live: search "A"
    // slower than a follow-up "B" leaves the box reading "B" but the
    // results reading "result for A"). Only the most recent call may write.
    if (gen !== searchGen) return;
    const reply: Reply = typeof raw === "string" ? JSON.parse(raw) : (raw as Reply) || {};
    state.hits = reply.hits || [];
    state.error = reply.error || "";
  } catch (_) {
    if (gen !== searchGen) return;
    state.error = "search failed";
  }
  if (gen !== searchGen) return;
  state.busy = false;
  render();
}

async function loadDomains(): Promise<void> {
  const H = seam.handlers;
  if (!H || !H.corpusDomains) return;
  try {
    const raw = await H.corpusDomains();
    const reply: Reply = typeof raw === "string" ? JSON.parse(raw) : (raw as Reply) || {};
    state.domains = reply.domains || [];
    // NOT render(): this resolves on its own async timer, independent of
    // any user action, and render()'s full innerHTML rebuild would reset
    // #cp-q's value to the (still-empty) state.query — silently erasing
    // whatever the citizen has typed in the gap before this reply lands
    // (verified live: type a query, let a slow domains reply arrive, watch
    // the box go blank). Rebuilding just the select's own options leaves
    // the input — and whatever's mid-typing in it — untouched.
    const select = document.getElementById("cp-domain") as HTMLSelectElement | null;
    if (select) select.innerHTML = domainOptionsHtml();
  } catch (_) { /* the domain list is a nicety — search still works without it */ }
}

function domainOptionsHtml(): string {
  return ["", ...state.domains].map(d =>
    `<option value="${esc(d)}" ${d === state.domain ? "selected" : ""}>${d ? esc(d) : "all domains"}</option>`).join("");
}

function render(): void {
  const stage = document.getElementById("corpusstage");
  if (stage) {
    stage.innerHTML = `<div class="cp">
      <div class="cp-top"><h3>the federation's corpus</h3>
        <div class="cp-sub">Every source text under the commons' knowledge base, searched directly —
          not scoped to one commune's drawn-from recipes. Hybrid-ranked (keyword + meaning), entirely
          on this gateway, no cloud model involved.</div></div>
      <div class="cp-bar">
        <input id="cp-q" class="cp-input" type="text" placeholder="what fixes nitrogen in soil…" value="${esc(state.query)}">
        <select id="cp-domain" class="cp-domain">${domainOptionsHtml()}</select>
        <button id="cp-go" class="cp-go">search</button>
      </div>
      ${state.busy ? `<div class="cp-status">searching…</div>` : ""}
      ${state.error ? `<div class="cp-status cp-error">${esc(state.error)}</div>` : ""}
      ${!state.busy && !state.error && state.query && !state.hits.length
        ? `<div class="cp-status">nothing found for "${esc(state.query)}"</div>` : ""}
      <div class="cp-hits">${state.hits.map(hitCard).join("")}</div>
    </div>`;
    const go = () => { const q = (document.getElementById("cp-q") as HTMLInputElement)?.value.trim();
                       const d = (document.getElementById("cp-domain") as HTMLSelectElement)?.value || "";
                       if (q) runSearch(q, d); };
    document.getElementById("cp-go")?.addEventListener("click", go);
    document.getElementById("cp-q")?.addEventListener("keydown", e => { if ((e as KeyboardEvent).key === "Enter") go(); });
  }
  const panel = document.getElementById("corpuspanel");
  if (panel) {
    panel.innerHTML = `<div class="cp-panel">
      <div class="cp-panel-h">the shared library</div>
      <div class="cp-panel-note">Hybrid search — BM25 keyword match fused with a dense semantic
        embedding by reciprocal rank — over every domain the federation has brought in
        (permaculture, forestry, water, fisheries, anaerobic digestion, …). One question can
        surface a passage across all of them, or you can narrow to one.</div>
    </div>`;
  }
}

let mounted = false;
export function initCorpus(): void {
  mounted = true;
  loadDomains();
  if (pendingQuery) { runSearch(pendingQuery, pendingDomain); pendingQuery = null; }
  else render();
}
