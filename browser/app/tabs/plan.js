// app/tabs/plan.ts — the "plan" face: the SELECTED SCOPE's solve as a time-phased FLOW.
//
//   INDEPENDENT SUPPLY │  stage 1 │ stage 2 │ … │ stage N │ INDEPENDENT DEMAND
//     (fixed, left)    │      the plan, scrolling → time       │  (fixed, right)
//     raw material,    │  each stage RUNS processes and emits  │  the needs /
//     means, labour  ──┼─▶ DEPENDENT supply, which folds back ──┼──▶ finals it
//                      │   as input for the next stage's runs  │     must satisfy
//
// ONE pipeline, two sources. A PRODUCTION is {id, spec, specId, name, q, u, period,
// in:[{spec,id,q,action}]} — a process that ran, its output, and what it drew in.
//   • LIVE    — plan.flow IS the productions array: the solver's ACTUAL flows (the LP's
//               chosen allocation, so a good made two ways shows twice; real qty + periods).
//   • OFFLINE — no solve, so reconstructFlow() synthesises the SAME array from the scope's
//               recipe topology (the plausible DAG).
// Either way modelFromFlow() turns productions → the render model: topological stages (a good
// can't be made until its inputs exist), independent-supply lanes, and dependent-supply
// fold-back. Scope-reactive: the "plan" push → "planRender" re-renders on a switch.
import { isCreating, isLabour, isOccupying, isUsingUp, onhandSign } from "../actions-catalogue.js";
import { esc } from '../template.js';
import { EXT } from '../core.js';
import { goToMapPlace, goToCalendarTime, hereOfInstant } from '../gohere.js';
import { locationOptions } from '../slots/model.js';
import { readStr, writeStr } from '../store.js';
import { nameOf } from '../contact-book.js';
import { metCol } from '../palette.js';
import { on } from '../bus.js';
import { PLAN } from '../core.js';
import { recipeById, recipes as scopeRecipes } from '../recipe-graph.js';
import { roomChip, roomAbout } from '../voice/roomchip.js';
import { K } from "../keys.js";
const plan = () => PLAN();
/**
 * A need's `for` carries the aid whose good it is (a want stated for oneself,
 * delivered on the citizen's own good) — resolved to a display alias so six
 * citizens' "salad" rows read as six citizens, not six duplicates. Same
 * lookup every face uses (contact-book.ts nameOf): the book's alias, else a short aid.
 */
const whoName = nameOf;
/**
 * The discrete layer's verdict as one header stat. A certified tree is a global
 * optimum over every configuration; an exhausted node budget leaves a gap, and
 * the stat says how much. Recourse columns a two-stage solve kept continuous
 * ride in the title, so a whole count that stayed a rate is never mistaken
 * for a decided one.
 */
function decidedStat(d) {
    if (!d)
        return "";
    const keys = Number(d.keys) || 0, nodes = Number(d.nodes) || 0, budget = Number(d.budget) || 0;
    const relaxed = Array.isArray(d.recourseRelaxed) ? d.recourseRelaxed.map(String) : [];
    const certified = !!d.certified;
    const configs = keys > 0 ? ` over ${keys < 20 ? 2 ** keys : "2^" + keys} configs` : "";
    // uncertified: the budget bound — say how many of it were spent, and the gap left
    const spent = certified || !budget ? `${nodes} node${nodes === 1 ? "" : "s"}` : `${nodes} of ${budget} nodes`;
    // an infinite gap is a budget spent before any whole plan was found: the plan shown is the relaxation
    const g = Number(d.gap);
    const gap = certified ? "" : Number.isFinite(g) ? ` · gap ≤ ${(g || 0).toFixed(3)}` : " · no whole plan yet";
    const title = (certified ? "the branch-and-bound exhausted its tree: every configuration was solved or provably beaten"
        : `the node budget (${budget}) ran out before the tree was exhausted; the gap is the best open bound — a scope may set its own budget`)
        + (relaxed.length ? ` · recourse kept continuous: ${esc(relaxed.join(", "))}` : "");
    return `<span class="fl-decided ${certified ? "is-certified" : ""}" title="${title}">◆ ${certified ? "certified" : "decided"}${configs} · ${spent}${gap}</span>`;
}
/** Where each mover stands, band by band: "tractor-7 → north@0 · south@1". */
function placementLine(p) {
    if (!p)
        return "";
    const rows = Object.entries(p).map(([who, cells]) => {
        const at = Object.entries(cells || {})
            .filter(([, v]) => (Number(v) || 0) > 1e-6)
            .sort(([a], [b]) => a.localeCompare(b))
            .map(([c, v]) => (Number(v) >= 0.999 ? esc(c) : `${esc(c)} (${Number(v).toFixed(2)})`)); // a fraction means the relaxation, not a place
        return `<span class="fl-place-row"><b>${esc(who)}</b> → ${at.join(" · ") || "nowhere"}</span>`;
    });
    return rows.length ? `<div class="fl-place" title="where each person or means the plan moves stands, per cell — a whole presence is a place, a fraction is the relaxation's spread">${rows.join("")}</div>` : "";
}
const n1 = (x) => { const v = Number(x) || 0; return v % 1 ? v.toFixed(1) : String(v); };
const primOut = (s) => (s.out || []).find(f => f.primary) || (s.out || [])[0] || null;
function outSpecOf(rcp) {
    if (!rcp)
        return "";
    if (rcp.produces)
        return rcp.produces;
    const steps = rcp.steps || [];
    const p = primOut(steps[steps.length - 1] || {});
    return (p && p.spec) || "";
}
// spec → emoji, from the scope's recipe flows (the live flow wire carries no emoji).
function specEmojiMap() {
    const m = {};
    (scopeRecipes() || []).forEach(r => {
        if (r.produces && r.emoji && !m[r.produces])
            m[r.produces] = r.emoji;
        (r.steps || []).forEach(s => [...(s.in || []), ...(s.out || [])].forEach(f => {
            if (f.spec && f.emoji && !m[f.spec])
                m[f.spec] = f.emoji;
        }));
    });
    return m;
}
// ── OFFLINE: reconstruct the productions array from recipe topology ──
// spec → the step that makes it; a step that TRANSFORMS a consumed input beats an
// acquisition stub (a step with no consumed input), so the real production chain wins.
const consumesGood = (s) => (s.in || []).some(f => !isOccupying(f.action) && !isLabour(f.action));
function buildStepIndex(recipes) {
    const idx = {};
    recipes.forEach(r => (r.steps || []).forEach(s => {
        const p = primOut(s);
        if (!p || !p.spec)
            return;
        const hasIn = consumesGood(s), cur = idx[p.spec];
        if (!cur || (hasIn && !cur._hasIn))
            idx[p.spec] = { step: s, recipe: r, _hasIn: hasIn };
    }));
    return idx;
}
function reconstructFlow(needs, recipes) {
    const idx = buildStepIndex(recipes);
    const prods = [], seen = new Set();
    function visit(spec, guard) {
        if (seen.has(spec) || guard.has(spec) || !idx[spec])
            return;
        seen.add(spec);
        const prov = idx[spec], g2 = new Set(guard);
        g2.add(spec);
        const ins = (prov.step.in || []).map(f => {
            const action = isLabour(f.action) ? "work" : isOccupying(f.action) ? "use" : "consume";
            const fs = f.spec || "";
            if (action === "consume" && idx[fs])
                visit(fs, g2); // verb-meant: the lane this input was just sorted into
            return { spec: fs, id: fs, q: Number(f.q) || 0, action };
        });
        prods.push({ id: spec, spec, specId: spec, name: prov.step.name || prov.recipe.name, q: 0, u: "", period: "", in: ins });
    }
    needs.forEach(nd => {
        const rcp = nd.recipeId ? recipeById(nd.recipeId) : null;
        if (!rcp)
            return;
        const os = outSpecOf(rcp);
        if (os)
            visit(os, new Set());
    });
    return prods;
}
// ── the ONE builder: productions[] → the render model ──
function modelFromFlow(prods, p, needs, demandSpecs, live) {
    const em = specEmojiMap();
    const emoji = (id) => em[id] || "•";
    const producedBy = {};
    prods.forEach(pr => (producedBy[pr.specId] = producedBy[pr.specId] || []).push(pr));
    const producedSet = new Set(Object.keys(producedBy));
    // topological stage: a production is 1 + the deepest of its produced inputs; raw/means/labour = 0.
    const specStage = {}, prodStage = {};
    function stageSpec(specId, guard) {
        if (specId in specStage)
            return specStage[specId];
        specStage[specId] = 1; // tentative — breaks cycles
        let mx = 0;
        (producedBy[specId] || []).forEach(pr => { const s = stageProd(pr, guard); if (s > mx)
            mx = s; });
        return (specStage[specId] = mx || 1);
    }
    function stageProd(pr, guard) {
        if (pr.id in prodStage)
            return prodStage[pr.id];
        if (guard.has(pr.id))
            return 1;
        const g2 = new Set(guard);
        g2.add(pr.id);
        let mx = 0;
        (pr.in || []).forEach(f => {
            if (isUsingUp(f.action) && producedSet.has(f.id)) {
                const s = stageSpec(f.id, g2);
                if (s > mx)
                    mx = s;
            }
        });
        return (prodStage[pr.id] = mx + 1);
    }
    prods.forEach(pr => stageProd(pr, new Set()));
    // independent-supply lanes: consumed goods with no producer (raw), means (use), labour (work).
    const raw = {}, means = {};
    let labourTotal = 0;
    prods.forEach(pr => (pr.in || []).forEach(f => {
        if (isLabour(f.action))
            labourTotal += Number(f.q) || 0;
        else if (isOccupying(f.action)) {
            if (!means[f.id])
                means[f.id] = { spec: f.spec, emoji: emoji(f.id) };
        }
        else if (isUsingUp(f.action) && !producedSet.has(f.id)) {
            const e = raw[f.id] || { spec: f.spec, emoji: emoji(f.id), q: 0 };
            e.q += Number(f.q) || 0;
            raw[f.id] = e;
        }
    }));
    const nodes = prods.map(pr => ({
        key: pr.id, spec: pr.spec, emoji: emoji(pr.specId), via: pr.name,
        stage: prodStage[pr.id] || 1, period: pr.period || "", final: demandSpecs.has(pr.specId),
        q: Number(pr.q) || 0, u: pr.u || "",
        inputs: (pr.in || []).map((f) => ({
            kind: isLabour(f.action) ? "work" : isOccupying(f.action) ? "use" : producedSet.has(f.id) ? "dep" : "raw",
            spec: f.spec, emoji: isLabour(f.action) ? "🧑‍🏭" : emoji(f.id), q: Number(f.q) || 0,
        })),
    }));
    const maxStage = Math.max(1, ...nodes.map(n => n.stage));
    const cols = [];
    for (let s = 1; s <= maxStage; s++) {
        const goods = nodes.filter(n => n.stage === s).sort((a, b) => a.spec.localeCompare(b.spec));
        cols.push({ stage: s, goods, labour: goods.reduce((a, n) => a + n.inputs.filter(i => i.kind === "work").reduce((b, i) => b + (Number(i.q) || 0), 0), 0) });
    }
    return {
        meta: { scope: p.scope, coverage: p.coverage ?? undefined, feasible: p.feasible, discrete: p.discrete, placement: p.placement, stale: !!p.stale,
            labourTotal, stages: cols.length, live },
        supply: { raw: Object.values(raw).sort((a, b) => a.spec.localeCompare(b.spec)),
            means: Object.values(means).sort((a, b) => a.spec.localeCompare(b.spec)), labourTotal },
        demand: needs, cols,
    };
}
function buildModel() {
    const p = plan(), needs = p.needs || [];
    const live = Array.isArray(p.flow) && p.flow.length > 0;
    // `live` IS the Array.isArray check on p.flow, one line up
    const prods = live ? p.flow : reconstructFlow(needs, scopeRecipes());
    // a "final" is a produced good that meets demand. Live: need.id IS the spec. Offline: the
    // need's recipe deliverable. (Same set, expressed against each source's id scheme.)
    const demandSpecs = new Set(live
        ? needs.map(n => n.id)
        : needs.map(n => { const r = n.recipeId ? recipeById(n.recipeId) : null; return r ? outSpecOf(r) : ""; }).filter(Boolean));
    return modelFromFlow(prods, p, needs, demandSpecs, live);
}
// a produced-good input → a coloured provenance chip. dep points LEFT (◂) to the stage that
// made it (dependent supply folded back); the rest are the independent-supply lanes.
function inChip(i) {
    if (i.kind === "work")
        return `<span class="fl-chip c-work">${i.emoji || "🧑‍🏭"} ${n1(i.q)}h</span>`;
    if (i.kind === "use")
        return `<span class="fl-chip c-use">${i.emoji || "🛠️"} ${esc(i.spec)}</span>`;
    if (i.kind === "dep")
        return `<span class="fl-chip c-dep"><span class="fl-arrow">◂</span> ${i.emoji || "•"} ${esc(i.spec)}${i.q ? ` <b>${n1(i.q)}</b>` : ""}</span>`;
    return `<span class="fl-chip c-raw">${i.emoji || "•"} ${i.q ? n1(i.q) + " " : ""}${esc(i.spec)}</span>`;
}
function goodCard(n) {
    const ins = (n.inputs || []).map(inChip).join("");
    return `<div class="fl-good ${n.final ? "fl-final" : ""}">
    <div class="fl-g-h"><span class="fl-g-emoji">${n.emoji}</span>
      <span class="fl-g-name">${esc(n.spec)}</span>
      ${n.final ? `<span class="fl-g-final">demand</span>` : ""}
      ${n.period ? `<span class="fl-g-period">t${esc(n.period)}</span>` : ""}</div>
    <div class="fl-g-via">← ${esc(n.via)}${n.q ? ` · <b>${n1(n.q)}</b>${n.u ? " " + esc(n.u) : ""}` : ""}</div>
    <div class="fl-ins">${ins || `<span class="fl-col-empty">no inputs</span>`}</div>
  </div>`;
}
function render() {
    const M = buildModel();
    const { meta, supply, demand, cols } = M;
    const cov = meta.coverage != null ? Math.round((+meta.coverage) * 100)
        : (demand.length ? Math.round(demand.reduce((s, n) => s + (+n.met || 0), 0) / demand.length * 100) : 0);
    const stage = document.getElementById("planstage");
    if (stage) {
        const hasPlan = cols.some(c => c.goods.length);
        const supplyEl = `<aside class="fl-flank fl-supply">
      <div class="fl-flank-h">independent supply</div>
      <div class="fl-flank-sub">what the plan draws on but does not itself make — raw material, means, labour.</div>
      ${supply.raw.map(r => `<div class="fl-item"><span class="fl-emoji">${r.emoji}</span>
        <b>${esc(r.spec)}</b>${r.q ? `<span class="fl-q">${n1(r.q)}</span>` : ""}</div>`).join("")}
      ${supply.means.map(m => `<div class="fl-item fl-means"><span class="fl-emoji">${m.emoji}</span>
        <b>${esc(m.spec)}</b><span class="fl-q">means</span></div>`).join("")}
      ${supply.labourTotal ? `<div class="fl-item fl-labour"><span class="fl-emoji">🧑‍🏭</span>
        <b>labour</b><span class="fl-q">${n1(supply.labourTotal)}h total</span></div>` : ""}
      ${(!supply.raw.length && !supply.means.length && !supply.labourTotal) ? `<div class="fl-col-empty">—</div>` : ""}
    </aside>`;
        const track = hasPlan ? `<div class="fl-track">${cols.map(c => `<div class="fl-col">
        <div class="fl-col-h"><span class="fl-col-t">stage ${c.stage}</span>
          <span class="fl-col-n">${c.goods.length} made</span>
          ${c.labour ? `<span class="fl-col-lab">${n1(c.labour)}h</span>` : ""}</div>
        ${c.goods.length ? c.goods.map(goodCard).join("") : `<div class="fl-col-empty">nothing made this stage</div>`}
      </div>`).join("")}</div>`
            : `<div class="fl-track"><div class="fl-empty">No plan with a recipe topology for this scope yet.</div></div>`;
        const demandEl = `<aside class="fl-flank fl-demand">
      <div class="fl-flank-h">independent demand</div>
      <div class="fl-flank-sub">the needs the plan exists to satisfy — pulled from the right.</div>
      ${demand.map(nd => {
            const met = +nd.met || 0;
            return `<div class="fl-item">
        <span class="fl-emoji">${nd.emoji || "•"}</span><b>${esc(nd.label || nd.id || "")}</b>
        ${nd.for ? `<span class="fl-who" title="this citizen's own want">${esc(whoName(nd.for))}</span>` : ""}
        <span class="fl-met" style="color:${metCol(met)}">${Math.round(met * 100)}%</span>
        ${nd.want != null && +nd.want ? `<span class="fl-want">want ${n1(nd.want)}${nd.runs ? ` · ${n1(nd.runs)} runs` : ""}</span>` : ""}
      </div>`;
        }).join("") || `<div class="fl-col-empty">—</div>`}
    </aside>`;
        stage.innerHTML = `<div class="fl">
      <div class="fl-head"><h3>plan · flow</h3>
        <span class="fl-stat"><b>${cov}%</b> of demand met</span>
        <span class="fl-stat"><b>${n1(supply.labourTotal)} h</b> labour</span>
        <span class="fl-stat">${cols.length} stage${cols.length === 1 ? "" : "s"}</span>
        <span class="fl-src ${meta.live ? "is-live" : ""}">${meta.live ? "● live solve" : "○ reconstructed"}</span>${meta.stale ? `<span class="fl-src">⟳ re-solving…</span>` : ""}
        ${meta.feasible === "no" ? `<span class="fl-infeasible" title="the solve breached limits it was given — these quantities draw stock nobody has, so they describe provisioning that cannot happen">⚠ infeasible — not a plan</span>` : ""}
        ${decidedStat(meta.discrete)}
        <span class="fl-hint">supply enters left · scroll → through production time · demand pulls right</span>
      </div>
      ${placementLine(meta.placement)}
      <div class="fl-body">${supplyEl}${track}${demandEl}</div>
      ${meta.live ? scheduleBoard(plan().schedule) : ""}
    </div>`;
        // the board folds on its header, and stays folded (or open) across renders
        const sb = stage.querySelector(".sb");
        if (sb) {
            const head = sb.querySelector(".sb-head");
            if (head)
                head.onclick = (ev) => {
                    if (ev.target.closest(".sb-sub"))
                        return;
                    sb.classList.toggle("is-closed");
                    writeStr(SB_OPEN_KEY, sb.classList.contains("is-closed") ? "0" : "1");
                };
        }
        // the board's headers are gestures into the one navigation door: a date
        // opens the calendar on that day, a place opens the map there — viewed
        // from that day (gohere moves the turn window before the camera)
        stage.querySelectorAll(".sb-date").forEach(el => {
            el.onclick = () => goToCalendarTime(hereOfInstant(el.dataset.day || ""));
        });
        stage.querySelectorAll(".sb-pname").forEach(el => {
            el.onclick = () => {
                const p = el.dataset.place || "";
                const l = locationOptions(EXT).find(x => x.id === p || x.name === p);
                goToMapPlace({ ...hereOfInstant(el.dataset.day || ""),
                    ...(l && l.lat != null ? { lat: l.lat, lng: l.lng } : {}) });
            };
        });
    }
    const panel = document.getElementById("planpanel");
    if (panel) {
        panel.innerHTML = `<div class="pl-panelw">
      <div class="pl-panel-h">the flow</div>
      <div class="pl-panel-stat"><b>${cov}%</b> met · <b>${n1(supply.labourTotal)} h</b> labour · <b>${cols.length}</b> stages</div>
      <div class="pl-panel-room">${roomChip(roomAbout("plan"), "talk this plan over")}</div>
      <div class="pl-panel-note">${meta.live
            ? `The solver's <b>actual</b> production decomposition for <b>${esc(meta.scope || "this scope")}</b> — real
           per-process flows, the LP's chosen allocation (a good made two ways shows twice), true periods.`
            : `Reconstructed from <b>${esc(meta.scope || "this scope")}</b>'s recipe topology (no live solve). Independent
           supply enters left; each stage turns it into dependent supply; the finals meet demand on the right.`}
        Scroll the middle to move through production time. Re-solves on scope switch.</div>
      <div class="pg-legend">
        <span><span class="pg-sw pg-t-raw">raw</span> independent supply — external material</span>
        <span><span class="pg-sw pg-t-use">means</span> a tool / land the stage uses</span>
        <span><span class="pg-sw pg-t-work">labour</span> living labour, in hours</span>
        <span><span class="pg-sw pg-t-dep">◂ dep</span> dependent supply — a good made an earlier stage</span>
      </div>
    </div>`;
    }
}
// ── the schedule board: the plan's SPACE-TIME coordinates, as they are ───────
// Groups the solve's commitments by real day × place. Hauls collapse to one
// row at the origin with an arrow to the destination (the pair is the same
// process, same moment, both ends conserved); a produce whose process worked
// an EARLIER day is an arrival — a run longer than its band landing. Clock
// moments show when bands are finer than a day.
const SB_OPEN_KEY = K.planScheduleOpen;
function scheduleBoard(sched) {
    if (!sched)
        return "";
    // a row is shown at one decimal, so a commitment that rounds to 0.0 is
    // noise on the board (the calendar and the event cards still carry it)
    if (!sched)
        return "";
    const work = sched.filter(r => r.action === "work" && (Number(r.effort) || 0) >= 0.05);
    const mat = sched.filter(r => r.action !== "work" && (Number(r.qty) || 0) >= 0.05);
    if (!work.length && !mat.length)
        return "";
    // the planner names the place and the person; the id stands where it names none
    const placeOf = (r) => r.placeName || r.at || "";
    const specOf = (r) => r.specName || r.spec || "";
    const day = (w) => (w || "").slice(0, 10);
    const clock = (w) => (w || "").includes("T") ? ((w || "").split("T")[1] || "").slice(0, 5) : "";
    const procDay = {};
    work.forEach(w => {
        const d = day(w.when);
        if (w.proc && d && (!procDay[w.proc] || d < procDay[w.proc]))
            procDay[w.proc] = d;
    });
    const rows = [];
    // a haul is one line, from the pickup's place to the one its dropoff lands
    // it (`to`, the planner's pairing of the two rows of one run); the dropoff
    // row itself is the arrival and stays off the board
    const hauled = new Set();
    mat.forEach(m => {
        if (m.action === "pickup" && m.to)
            hauled.add(`${m.proc ?? ""}|${m.spec ?? ""}`);
    });
    mat.forEach(m => {
        const d = day(m.when);
        if (m.action === "pickup" && m.to) {
            rows.push({ day: d, place: placeOf(m), kind: "haul",
                html: `<b>${n1(m.qty)}</b> ${esc(specOf(m))} <span class="sb-arrow">→ ${esc(m.toName || m.to)}</span>` });
            return;
        }
        if (m.action === "dropoff" && hauled.has(`${m.proc ?? ""}|${m.spec ?? ""}`))
            return;
        const arrives = onhandSign(m.action ?? "") === 1;
        const lands = isCreating(m.action ?? "") && m.proc && procDay[m.proc] && procDay[m.proc] < d;
        const boarded = m.proc ? procDay[m.proc] : "";
        rows.push({ day: d, place: placeOf(m), kind: m.action,
            html: `${arrives ? "▲" : "▼"} <b>${n1(m.qty)}</b> ${esc(specOf(m))}`
                + (lands ? ` <span class="sb-lands" title="a run longer than its day: inputs boarded ${esc(boarded)}, the output lands here">lands</span>` : "") });
    });
    // ONE line per (person, skill, span, place, day): the solve emits a work
    // cell per recipe process, and a festival's twelve district acts share one
    // gardener and one 09:00–17:00 band — a person reads "8 h of gardening
    // (12 acts)", never twelve parallel slivers. The acts themselves stay
    // individually navigable on the calendar and the event cards.
    const wsum = new Map();
    work.forEach(w => {
        const c = clock(w.when);
        const who = w.providerName || w.provider || "";
        const k = `${who}|${w.spec ?? ""}|${day(w.when)}|${c}|${placeOf(w)}`;
        const g = wsum.get(k);
        if (g) {
            g.h += Number(w.effort) || 0;
            g.n += 1;
        }
        else
            wsum.set(k, { who, skill: specOf(w), day: day(w.when), place: placeOf(w), clock: c, h: Number(w.effort) || 0, n: 1 });
    });
    wsum.forEach(g => {
        rows.push({ day: g.day, place: g.place, kind: "work",
            html: `<b>${esc(g.who)}</b> ${esc(g.skill)} <span class="sb-hrs">${n1(g.h)} h</span>`
                + (g.n > 1 ? ` <span class="sb-dim">${g.n} acts</span>` : "")
                + (g.clock && g.clock !== "00:00" ? ` <span class="sb-dim">${g.clock}</span>` : "") });
    });
    const days = [...new Set(rows.map(r => r.day))].sort();
    const places = [...new Set(rows.map(r => r.place))].sort();
    const ord = { work: 0, consume: 1, produce: 2, haul: 3, carry: 4 };
    const closed = readStr(SB_OPEN_KEY) === "0";
    return `<div class="sb${closed ? " is-closed" : ""}">
    <div class="sb-head" title="fold the board away, or open it"><span class="sb-fold">▾</span>schedule · who, what, where, when
      <span class="sb-dim">${rows.length} rows · ${days.length} day${days.length === 1 ? "" : "s"} · ${places.length} place${places.length === 1 ? "" : "s"}</span>
      <span class="sb-sub">every row a commitment at its own space-time cell — hauls at both ends, long runs at their arrival</span></div>
    <div class="sb-days">${days.map(d => `<div class="sb-day"><div class="sb-date" data-day="${esc(d)}">${esc(d)}</div>
      ${places.map(p => {
        const rs = rows.filter(r => r.day === d && r.place === p)
            .sort((a, b) => (ord[a.kind ?? ""] ?? 9) - (ord[b.kind ?? ""] ?? 9));
        return rs.length ? `<div class="sb-place"><div class="sb-pname" data-day="${esc(d)}" data-place="${esc(p)}">${esc(p)}</div>
          ${rs.map(r => `<div class="sb-row sb-${r.kind}">${r.html}</div>`).join("")}</div>` : "";
    }).join("")}</div>`).join("")}</div></div>`;
}
export function initPlan() {
    on("planRender", render);
    render();
}
