// app/tabs/recipe-render.ts — rendering a recipe's flows and computed standing,
// shared between the two faces that show a recipe: the flat library
// (tabs/recipes.ts) and the graph (tabs/web.ts). One formatter for a flow chip
// and one for the barbell's triad, so the relocation-rate scaling and the
// standing badges read the same wherever a recipe is drawn — a face that skips
// importing these would have to reinvent them to differ, rather than drift by
// accident.
import { esc } from '../template.js';
import { STRESS_BAND } from '../recipe-demo-standing.js'; // the stress axis, as the engine states it
export const n1 = (x) => (x % 1 ? x.toFixed(1) : String(x));
export const isMove = (f) => f.action === "pickup" || f.action === "dropoff";
export function relocationOf(s) {
    const all = [...(s.in || []), ...(s.out || [])];
    const pu = all.find(f => f.action === "pickup") || all.find(isMove);
    return pu ? { payload: Number(pu.q) || 1, unit: pu.u || "" } : null;
}
// 0.002 h/kg·km × 40 kg = 0.08 h/km, three significant figures, no trailing zeros
export const trim = (n) => String(+n.toPrecision(3));
/** A flow chip: emoji + quantity + unit + spec, coloured by action. MOVE is the
 *  step's relocation (or null); on a relocation step every non-cargo rate is
 *  shown per km for the whole payload. */
export function flowChip(f, move = null) {
    // Number() is unary plus written out — same coercion, and it accepts the
    // undefined a flow without a quantity actually carries.
    const perKm = !!move && !isMove(f);
    const q = perKm ? trim((Number(f.q) || 0) * move.payload) : (Number(f.q) || 0), u = f.u ? esc(f.u) : "";
    const base = f.action === "work" ? `${q}${u || "h"}` : (q ? `${q}${u ? " " + u : ""}` : "");
    const qty = base && perKm ? `${base}<span class="rc-perkm">/km</span>` : base;
    return `<span class="rc-flow rc-${esc(f.action || "consume")}">`
        + `<span class="rc-emoji">${f.emoji || "•"}</span>`
        + (qty ? `<span class="rc-q">${qty}</span>` : "")
        + `<span class="rc-spec">${esc(f.spec || "")}</span></span>`;
}
// ── standing: a recipe's response, read off its runs (economy/recipe-standing.scm) ──
export const POSITION_LABEL = {
    "experimental": "🧪 experimental — every run so far was calm",
    "observed": "✓ observed — it has run under stress",
};
export const WORD_LABEL = {
    fragile: "fragile — harm that accelerates", antifragile: "antifragile — a gain that accelerates",
    robust: "robust — holds across the stress observed", proportional: "in proportion — moves with the stress, in a line",
    unobserved: "awaiting observation",
};
// A chart of what actually happened: stress delivered (x) against the value
// captured (y, 0..100%). One dot per run; the CURVE the plan reads, drawn
// through its readings and dashed where it is continued past the record; and
// the three levels the word was read off — the straight line between the
// outer two, and the gap to the middle one. Scales and lines are d3's own.
function spark(pts, curve, bend, word, beyondAt) {
    const W = 220, H = 72, P = 7;
    const x = d3.scaleLinear().domain([0, STRESS_BAND]).range([P, W - P]);
    const y = d3.scaleLinear().domain([0, 100]).range([H - P, P]).clamp(true);
    const path = d3.line().x(d => x(d.s)).y(d => y(d.c));
    const dots = pts.map(p => `<circle cx="${x(p.s).toFixed(1)}" cy="${y(p.c).toFixed(1)}" r="3"/>`).join("");
    let read = "", beyond = "", line = "", gap = "";
    if (curve.length > 1)
        read = `<path d="${path(curve)}" class="rc-spark-line" fill="none"/>`;
    const last = curve[curve.length - 1];
    if (last && last.s < STRESS_BAND)
        beyond = `<path d="${path([last, { s: STRESS_BAND, c: beyondAt }])}" class="rc-spark-line rc-spark-beyond" fill="none"/>`;
    if (bend && bend.kind) {
        // the three levels are levels of the curve: each is one of its readings
        const at = (s) => curve.find(p => p.s === s)?.c ?? 0;
        const a = { s: bend.from, c: at(bend.from) }, c = { s: bend.to, c: at(bend.to) };
        const on = a.c + (c.c - a.c) * (bend.at - a.s) / (c.s - a.s);
        line = `<path d="${path([a, c])}" class="rc-spark-chord" fill="none"/>`;
        gap = `<path d="${path([{ s: bend.at, c: on }, { s: bend.at, c: at(bend.at) }])}" class="rc-spark-gap" fill="none"/>`;
    }
    return `<svg class="rc-spark rc-cls-${esc(word)}" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" role="img" aria-label="captured value against the stressor delivered">${line}${gap}${read}${beyond}${dots}</svg>`;
}
/** One claim an event fulfilled: what was due (already scaled by what the day allowed) against what actually happened. */
function claimRow(t) {
    const intended = Number(t.intended || 0), realized = Number(t.realized || 0);
    const pct = intended > 0 ? Math.round(100 * realized / intended) : 0;
    return `<div class="rc-claim"><span class="rc-claim-spec">${esc(t.action || "")} · ${esc(t.spec || "")}</span>
    <span class="rc-claim-nums">${n1(realized)} of ${n1(intended)} claimed <span class="rc-claim-pct">(${pct}%)</span></span></div>`;
}
/** One run: its own <details>, nested — the observer log a reader opens the
 *  channel to trace, then opens the run to see exactly what it claimed and
 *  what it delivered, the two numbers `observed-capture` divided. */
function runRow(p) {
    const claims = p.claims.length ? p.claims.map(claimRow).join("")
        : `<div class="rc-claim rc-claim-none">no claim recorded for this run</div>`;
    return `<details class="rc-run">
    <summary>${p.when ? `<span class="rc-run-when">${esc(p.when)}</span> · ` : ""}stress ${n1(p.s)} · captured ${n1(p.c)}%</summary>
    <div class="rc-run-body">${claims}</div>
  </details>`;
}
const pct = (x) => `${Math.round(100 * x)}%`;
/** What the chart shows, in words: how the curve bends, over which stress, and the licensed statistic where one stands. */
function readingNote(c, curve, bend, word) {
    if (curve.length < 3)
        return `<div class="rc-fit">${curve.length} of the 3 stress levels a bend is read off — the plan reads the curve as it stands</div>`;
    const where = bend && bend.kind ? `at stress ${n1(bend.at)}, ${n1(bend.gap)} points ${bend.kind === "harm" ? "above" : "under"} the line from stress ${n1(bend.from)} to ${n1(bend.to)}` : "";
    const what = word === "fragile" ? `held, then fell faster — ${where}`
        : word === "antifragile" ? `gained faster the harder it was pressed — ${where}`
            : word === "robust" ? `holds across the stress observed${where ? ` · its loudest bend: ${where}` : ""}`
                : `moves with the stress, in proportion${where ? ` · its loudest bend: ${where}` : ""}`;
    const stat = c.confident ? ` · <span title="least squares, licensed by a witnessed claim of thin tails and a stable process">acceleration ${Number(c.accel || 0).toFixed(1)} ± ${Number(c.se || 0).toFixed(1)}</span>` : "";
    return `<div class="rc-fit">${what}${stat}</div>`;
}
/** One stressor, collapsed to its word; opened (native <details>, no JS state) it shows the runs behind it: the chart, the bend in words, and each run's own observer log, one nested disclosure deeper. */
export function channelChip(c) {
    const word = c.word || "unobserved";
    const n = Number(c.n || 0);
    const pts = (c.points || []).map(p => ({ when: p.when || "", s: Number(p.s || 0), c: Number(p.c || 0), claims: p.claims || [] }));
    const curve = (c.curve || []).map(p => ({ s: Number(p.s || 0), c: Number(p.c || 0) }));
    const bend = c.bend && c.bend.kind
        ? { kind: c.bend.kind, gap: Number(c.bend.gap || 0), from: Number(c.bend.from || 0), at: Number(c.bend.at || 0), to: Number(c.bend.to || 0) }
        : null;
    const reading = word === "fragile" || word === "antifragile"
        ? `<span class="rc-k">${word === "fragile" ? "−" : "+"}${n1(Math.round(bend?.gap || 0))} pts</span>` : "";
    // how far the record reaches on this flow: the heaviest stress it has a
    // run under (solve/recipe-response.scm curve-reach, off the wire) — what it is proven to
    const reach = Number(c.reach || 0);
    const proven = reach > 0 ? `proven to stress ${n1(reach)}` : "calm runs only";
    const runs = pts.length
        ? pts.map(runRow).join("")
        : `<div class="rc-run rc-run-none">no runs recorded on this stressor yet</div>`;
    return `<details class="rc-chan rc-cls-${esc(word)}">
    <summary title="${esc(WORD_LABEL[word] || word)}, with respect to ${esc(c.channel || "")} · ${n} run${n === 1 ? "" : "s"}${c.confident ? "" : " · no statistic attached (probability-free)"}">
      <span class="rc-chan-name">${esc(c.channel || "")}</span>${reading}<span class="rc-chan-n">${n} run${n === 1 ? "" : "s"}</span><span class="rc-chan-reach">${proven}</span>
    </summary>
    <div class="rc-chan-body">${spark(pts, curve, bend, word, Number(c.beyond ?? (curve.length ? curve[curve.length - 1].c : 0)))}${readingNote(c, curve, bend, word)}<div class="rc-chan-runs">${runs}</div></div>
  </details>`;
}
// What the recipe yields of what the weather live now allows: its curve read
// at the last day's stress — the SAME reading a future at that stress takes in
// the solve (solve/recipe-response.scm response-shocks), so this is how much the
// plan leans on it right now. The whole (1) is the honest default and earns
// no pill.
export function yieldNote(r) {
    const y = Number(r.yield ?? 1);
    if (!(y >= 0 && y < 1))
        return "";
    return `<span class="rc-yield" style="--strain:${(1 - y).toFixed(2)}" title="its own record, read at the stress live right now; every future of the plan reads the same curve at its own stress, so the plan leans on this recipe in proportion">delivers ${pct(y)} of what the weather allows, right now</span>`;
}
/** The untried margin: whether the needs an untried recipe serves stand without it. */
const MARGIN_NOTE = {
    bounded: ["needs rest on a longer record first", "another recipe for the same output has run under heavier stress: where the plan defends a need without a forecast it rests on that one first, on this one by how far its own record reaches, and runs this one wherever it adds"],
    bare: ["the need rests on it", "no recipe for its output has yet run under stress: the plan has no proven record to hold the need with"],
};
function marginNote(r) {
    const m = MARGIN_NOTE[r.margin || ""];
    return m ? `<span class="rc-margin rc-margin-${esc(r.margin || "")}" title="${esc(m[1])}">${m[0]}</span>` : "";
}
export function standingRow(r) {
    const pos = r.standing || "";
    const profile = r.profile || [];
    if (!pos && !profile.length)
        return `<div class="rc-standing rc-standing-none">not yet run in this scope — nothing to read a response from${r.margin ? ` · ${marginNote(r)}` : ""}</div>`;
    return `<div class="rc-standing">
    ${pos ? `<span class="rc-pos rc-pos-${esc(pos)}">${POSITION_LABEL[pos] || pos}</span>` : ""}
    ${marginNote(r)}
    ${yieldNote(r)}
    <span class="rc-chans">${profile.length ? profile.map(channelChip).join("") : `<span class="rc-none-chan">no stressor exposed yet</span>`}</span>
  </div>`;
}
