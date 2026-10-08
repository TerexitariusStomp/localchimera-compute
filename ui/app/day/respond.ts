// app/respond.ts — the day's lists, the selected event's card, and the five
// ways of answering it.
//
// Everything below the dial that speaks about an event: the day's own
// commitments, the proposals waiting on your yes, and the card that describes
// whichever one is selected — from the rim, from a list, it makes no difference.
//
// ── EVERY ANSWER IS REVERSIBLE ──────────────────────────────────────────────
// willing, commit, decline, release, reconsider. A commitment is not a one-way
// door: RELEASE un-commits, which asks the planner to clear the binding and
// re-match someone else, and the item leaves your day and goes back to being a
// proposal you can act on. RECONSIDER un-declines the same way. That is a
// design claim about what a plan IS — a standing negotiation rather than a
// schedule handed down — and it is why the actions come in pairs.
//
// ── THE ACTIONS ARE A LIST, NOT A TEMPLATE ──────────────────────────────────
// The card's buttons and their handlers read ONE array, keyed by the item's
// state. A label and the function it calls cannot drift apart, and adding a
// sixth response is a row rather than an edit in two places.
//
// ── THE OPTIMISTIC ECHO ─────────────────────────────────────────────────────
// Each action tells the planner and ALSO flips the local state. Connected, the
// refreshed snapshot brings the same answer back and the flip is confirmed;
// offline it is the whole behaviour. The seam call is fire-and-forget on
// purpose — a response that waited for the network would feel like the network.
//
// ── OTHER PEOPLE'S TEXT IS CONTENT ──────────────────────────────────────────
// A `label` and a `from` are the OTHER PARTY's words — a proposal carries the
// title and the name they chose — so every list renders them escaped, through
// the template's interpolation, never as markup.

import { evs, pending, lived, offered } from '../events.js';
import { pick } from '../calendars.js';
import { html, render, list } from '../template.js';
import type { Fragment } from '../template.js';
import { cWarm, cYea, HANDLERS, hint, markDayChanged } from '../core.js';
import { fmtClock, fmtTau, fmtDur } from '../timefmt.js';
import { evKey } from '../markers.js';
import { selectedEv, selectEvent, evCls, showEventOnMap } from '../ribbons.js';
import { availRing, eventRing, eventConflicts } from './mytime.js';
import { isWilling, offerWillingness, widOf } from '../willingness.js';
import { showChat } from '../tabs/social/chat.js';
import type { DayEvent, EventNeed } from '../seam.js';
import { STATUS } from '../palette.js';
import { plannedCount, type PlannedCount } from '../count.js';
import { openCapturePlanned } from '../capture.js';

/** One response: how it reads, what it says, and what it does. */
/** One response on offer, as either card draws it. */
export interface Action {
  /** The css class that colours it. */
  c: string;
  /** The tooltip — what accepting it actually means. */
  t: string;
  /** The label on the button. */
  l: string;
  f: () => void;
  /**
   * A RECORDING verb's adjustable amount: the default quantity (the
   * remainder), and the taker of whatever the reader dials it to. The dial's
   * detail card renders the input; a renderer that doesn't (the grid's card)
   * still has `f`, which records the default.
   */
  amt?: number;
  fa?: (qty: number) => void;
}

// ── the gate ────────────────────────────────────────────────────────────────

/**
 * The one refusal that is not an error: a provisional member cannot take part
 * yet, and saying so as an error would read as a fault of theirs.
 */
export function gateHint(r: string | null | undefined): boolean {
  if (r !== "err:needs-personhood") return false;
  hint("you're provisional — tap your name (top-right) to request recognition, " +
       "then you can take part.", "warn");
  return true;
}

// ── the five answers ────────────────────────────────────────────────────────

/**
 * Accept: a proposed Intent becomes a Commitment.
 *
 * It joins the day on the rim in full colour, with the chord to what it
 * satisfies, through the door its kind names (acceptDoor).
 */

/**
 * THE THREE KINDS OF PROPOSED THING, and the door each accepts through —
 * the one place that reading lives:
 *
 *   assignment  the solve suggested you for a work-intent
 *               → commit (accept-assignment)
 *   invite      a person proposed an event; whitelist-checked
 *               → acceptInvite (accept-proposal)
 *   offer       the presentation caller's directed work offer, with its
 *               forcing-point window — the bounded rung
 *               → acceptWorkOffer (accept-work-offer, the gated door)
 *
 * The wire says which (`offer`, `social`); everything else is an assignment.
 */
function acceptDoor(p: DayEvent) {
  return p.offer ? HANDLERS.acceptWorkOffer
       : p.social ? HANDLERS.acceptInvite : HANDLERS.commit;
}

export function commit(p: DayEvent): void {
  const h = acceptDoor(p);
  if (p.vfId && h)
    h(p.scope || "", p.vfId).then((r: string) => {
      if (r && r.startsWith("err:") && !gateHint(r)) hint(r.replace(/^err:/, ""), "error");
    });
  p.status = "committed";
  evs.push(p);
  evs.sort((a, b) => a.t0 - b.t0);
  selectedEv.set(p);
  markDayChanged();      // the panels and the rim follow the notifier
}

/**
 * Decline, which ALSO withdraws the willingness standing.
 *
 * Otherwise a gated re-solve would offer you the same thing again, and a "no"
 * that has to be repeated is not a no.
 */
export function decline(p: DayEvent): void {
  if (p.vfId && HANDLERS.decline)
    HANDLERS.decline(p.scope || "", p.vfId).then(() => {});
  if (p.spec && HANDLERS.willing)
    HANDLERS.willing(p.scope || "", p.spec, p.cell || "", false).then(() => {});
  p.status = "declined";
  if (selectedEv.peek() === p) selectedEv.set(null);
  markDayChanged();
}

/**
 * Raise your hand: join the candidate race for this need's (skill, cell).
 *
 * An option, not a bind — over-subscribable on purpose, and the chat strata
 * show where the standing is.
 */
export function willing(p: DayEvent): void {
  if (!p.spec) {
    hint("this proposal names no skill — nothing to raise a hand for", "warn");
    return;
  }
  // toggle, the same optimistic flip offerWillingness gives the OPEN tier's
  // "✋ offer willingness": the set flips FIRST so isWilling(p) answers on the
  // next paint, and the card stays exactly what it was — a proposal, not a
  // commitment — this only says whose hand is up.
  const wasWilling = isWilling(p);
  if (wasWilling) offered.delete(widOf(p)); else offered.add(widOf(p));
  if (HANDLERS.willing && p.scope) {
    HANDLERS.willing(p.scope, p.spec, p.cell || "", !wasWilling).then((r: string) => {
      const bad = !!(r && r.startsWith("err:"));
      // a refusal — the gate's or any other — puts the hand back where it was
      if (bad) { if (wasWilling) offered.add(widOf(p)); else offered.delete(widOf(p)); markDayChanged(); }
      if (gateHint(r)) return;
      hint(bad ? r.replace(/^err:/, "") : wasWilling ? "willingness withdrawn" : "willing — you're in the race",
           bad ? "error" : "success");
    });
  } else {
    // a proposal with no scope is the demo's — no commune, no race to join,
    // and the flip is the whole behaviour (the header's optimistic echo)
    hint(wasWilling ? "willingness withdrawn" : "willing — you're in the race", "success");
  }
  markDayChanged();
}

/** Un-commit: the planner re-matches, and the item leaves your day. */
export function release(p: DayEvent): void {
  if (p.vfId && HANDLERS.decline)
    HANDLERS.decline(p.scope || "", p.vfId).then(() => {});
  p.status = "proposed";
  const i = evs.indexOf(p);
  if (i >= 0) evs.splice(i, 1);
  markDayChanged();
}

/** Un-decline: back to a proposal, to be willing about or to commit anew. */
export function reconsider(p: DayEvent): void {
  p.status = "proposed";
  markDayChanged();
}

// ── the confirmation mile: a planned block records what happened ────────────
//
// Every plannable block carries its own MEANS OF OBSERVATION: the verb that
// turns it into the EconomicEvent discharging it. A committed work block
// records its effort (record-effort — fulfills the commitment, advances its
// FulfillmentState); a schedule material row records its produce/consume/move
// (record-flow — deterministic event id, so a second tap cannot double-move
// stock). The echo is optimistic: a copy lands in the LIVED list at once, and
// the refetched snapshot brings the observer's own reading back over it.

/** What a block ASKS, in its own unit: hours for work, the row's qty else. */
const askedOf = (d: DayEvent): number =>
  d.action === "work" ? ((d.effort as number) || Math.max(0.25, d.t1 - d.t0))
                      : ((d.qty as number) || 1);

/** What still remains to record of it — every verb's and amount's default. */
export const remainingOf = (d: DayEvent): number =>
  Math.max(0, askedOf(d) - ((d.done as number) || 0));

/**
 * The optimistic half: QTY of this block, as the lived record it just became.
 * The local `done` counter advances with it, and the verb retires only when
 * the whole asked amount is in — a partial leaves the remainder recordable.
 */
function echoLived(d: DayEvent, qty: number): void {
  // the block's label already names the WHAT (the skill, or "produce food");
  // the wire's own lived row carries the same, so the echo matches what the
  // next snapshot replaces it with
  lived.push({ ...d, tier: "lived", status: undefined, vfId: undefined });
  d.done = ((d.done as number) || 0) + qty;
  if ((d.done as number) >= askedOf(d)) d.recorded = true;
  markDayChanged();
}

/** Report a recording's reply: the error's own words, or the good news. */
const reported = (good: string) => (r: string): void => {
  const bad = !!(r && r.startsWith("err:"));
  hint(bad ? r.replace(/^err:/, "") : good, bad ? "error" : "success");
};

/** Record QTY hours of a committed work block (default: the remainder). */
export function recordWork(d: DayEvent, qty?: number): void {
  if (!(d.vfId && HANDLERS.recordEffort)) { hint("this block has no planner key yet", "warn"); return; }
  const q = Math.max(0.25, qty ?? remainingOf(d));
  HANDLERS.recordEffort(d.scope || "", d.vfId, String(q), "hours")
    .then(reported("recorded — the lived layer carries it now"));
  echoLived(d, q);
}

/** Record QTY of one schedule material row (default: what remains of it). */
export function recordFlow(d: DayEvent, qty?: number): void {
  if (!HANDLERS.recordFlow) { hint("no gateway to record against", "warn"); return; }
  const q = Math.max(0.01, qty ?? remainingOf(d));
  HANDLERS.recordFlow(d.scope || "", d.action || "", d.specId || d.spec || "",
                      String(q), String((d.qty as number) || 1), (d.loc && d.loc.id) || "",
                      String(d.when || ""), d.proc || "", String(d.note || ""), d.rowId || "")
    .then(reported("recorded — the stock moved as planned"));
  echoLived(d, q);
}

/**
 * A recording verb, whole: label, tooltip, the default record, and the
 * adjustable amount — one shape for both halves of the confirmation mile,
 * so the work arm and the flow arm cannot drift in what a verb carries.
 */
const recVerb = (d: DayEvent, t: string,
                 rec: (d: DayEvent, q?: number) => void): Action =>
  ({ c: "r-commit", t, l: "✓ it happened",
     f: () => rec(d), amt: remainingOf(d), fa: (q: number) => rec(d, q) });

// ── what a selected item affords ────────────────────────────────────────────

/**
 * The responses available for one item, by its state.
 *
 * Exported because the WEEK GRID offers the same five, and a second copy of
 * this ladder is a second place for "what can I do about this?" to be answered
 * differently.
 *
 * An OPEN work-intent is not addressed to you — you are merely eligible — so
 * the only move is to offer willingness, and offering it again withdraws it.
 */
/** Ask peers to co-sign a lived work event — the k-of-n trust floor. */
export function witnessWork(d: DayEvent): void {
  if (!(d.vfId && HANDLERS.witnessOpen)) { hint("no gateway to witness against", "warn"); return; }
  HANDLERS.witnessOpen(d.scope || "", d.vfId)
    .then((r: string) => { if (!gateHint(r)) reported("witnessing opened — peers see it in their inbox")(r); });
}

/** Open the capture sheet on a planned count, with the commitment it fulfils. */
export function countPlanned(d: DayEvent, planned: PlannedCount): void {
  if (!d.vfId) { hint("this count has no planner key yet", "warn"); return; }
  if (!openCapturePlanned(planned.target, d.vfId, planned.blind))
    hint("the stock this count is of is not on hand here", "warn");
}

export function actionsFor(d: DayEvent): Action[] {
  // the LIVED record answers nothing — its one verb is asking peers to
  // co-sign it, which strengthens the scope's word into k-of-n evidence
  if (d.tier === "lived")
    return (d.action === "work" && d.vfId && HANDLERS.witnessOpen)
      ? [{ c: "r-willing", l: "⚭ witness",
           t: "ask peers to co-sign this work — at quorum its credential strengthens to k-of-n",
           f: () => witnessWork(d) }]
      : [];
  if (d.tier === "open")
    return [{ c: "r-willing", t: "raise your hand — eligible, offering",
              l: isWilling(d) ? "↩ withdraw willingness" : "✋ offer willingness",
              f: () => offerWillingness(d) }];
  // a SCHEDULE row — the solve's own cell, addressed to the scope rather than
  // to you. Its one verb is its means of observation: a material row records
  // the flow that realises it; a work row confirms through acceptance
  // (commit → record), so it offers nothing here.
  if (d.proc && !d.vfId)
    return (d.action === "work" || d.recorded) ? []
      : [recVerb(d, "record what happened — the EconomicEvent that moves the stock",
                 recordFlow)];
  if (d.status === "proposed")
    // willingness is the skill rail's act: it needs a planner key — the
    // (skill, cell) pair — to raise a hand INTO. A social invite or a
    // spec-less row answers with commit/decline alone; a willing button
    // whose only outcome is a warn toast would be an offer of nothing.
    return [...(d.spec && !d.social
      ? [{ c: "r-willing", t: "an option, not a bind",
           l: isWilling(d) ? "↩ withdraw willingness" : "✋ willing", f: () => willing(d) }]
      : []),
            { c: "r-commit",  t: "accept — form the Commitment",          l: "✓ commit",  f: () => commit(d) },
            { c: "r-decline", t: "decline — a gated re-solve skips you",  l: "✕ decline", f: () => decline(d) }];
  if (d.status === "declined")
    return [{ c: "r-willing", t: "undo decline — back to a proposal",
              l: "↩ reconsider", f: () => reconsider(d) }];
  // THE COMMITTED DAY. A proposal accepted here carries status "committed"; a
  // commitment straight off the wire carries none — both are the day's own,
  // and a work commitment's one further verb is its means of observation.
  const out: Action[] = [];
  // a PLANNED COUNT's means of observation is the count: the capture sheet
  // opens on what is to be counted, and the count lands its hours beside its
  // figure (docs/observation/capture.md §10)
  const planned = plannedCount(d.proc);
  if (planned && d.vfId && !d.recorded && remainingOf(d) > 0)
    out.push({ c: "r-commit", l: "◉ count it",
               t: planned.blind ? "count it — a blind count: say the figure, then see the ledger's"
                                : "count it — say how much is there",
               f: () => countPlanned(d, planned) });
  else if (d.vfId && d.action === "work" && !d.social && !d.recorded && remainingOf(d) > 0)
    out.push(recVerb(d, `record the work — the EconomicEvent fulfilling this commitment${
                          (d.done as number) ? ` (${d.done} h already recorded)` : ""}`,
                     recordWork));
  if (d.status === "committed")
    out.push({ c: "r-decline", t: "release the commitment — frees the slot to re-match",
               l: "↩ release", f: () => release(d) });
  return out;
}

/**
 * What this item IS in the ValueFlows vocabulary, in its own state's words.
 *
 * Exported alongside actionsFor, and for the same reason: the grid's card and
 * the dial's card are documented as mirrors, so they read from one sentence.
 */
export function vfLine(d: DayEvent): Fragment {
  if (d.tier === "lived")
    return html`VF: <b>EconomicEvent</b> — the lived record · action <b>${d.action}</b>${
      d.from ? html` · by <b>${d.from}</b>` : ""}`;
  if (d.proc && !d.vfId)
    return html`VF: the solve's <b>${d.action}</b> at its own space-time cell${
      d.action === "work" ? html` — confirms through acceptance (commit, then record)`
        : html` — "it happened" records the EconomicEvent that moves the stock`}`;
  if (d.tier === "open")
    return html`VF: work-intent you are <b>eligible</b> for (skill ∧ window ∧ catchment) — not assigned; offer willingness to be matched${
      d.serves ? html` → <b>${d.serves}</b>` : ""}`;
  if (d.status === "proposed")
    return html`VF: proposed Intent from <b>${d.from}</b> — accept to form a <b>Commitment</b>${
      d.serves ? html`, satisfying → <b>${d.serves}</b>` : ""}`;
  return html`VF: ${d.status === "committed" ? "Commitment — becomes an " : ""}EconomicEvent · action <b>${d.action}</b>${
      d.serves ? html` · satisfies → <b>${d.serves}</b> (standing intent)` : ""}`;
}

// ── drawing ─────────────────────────────────────────────────────────────────

/**
 * The day's list, the proposals, and the detail card.
 *
 * A row's identity across redraws is the event's own key — the SAME key the
 * map's markers persist under, which is why a card and its dot can never
 * disagree about which event they are.
 */
export function drawCal(): void {
  list("#cal", pick("plan", evs), evKey, (d: DayEvent) => html`
    <li class="${evCls(d)}" onclick=${() => selectEvent(selectedEv.peek() === d ? null : d)}>
      <span class="chip" style="background:${d.kind === "work" ? cWarm : cYea}"></span>
      <span class="when">${fmtClock(d.t0)}–${fmtClock(d.t1)}</span>
      <span class="what">${d.label}</span>
      <span class="tau">${fmtTau(d.t0)}</span>
    </li>`);
  // the proposals: the phase handshakes awaiting your yes
  list("#props", pick("props", pending()), evKey, (d: DayEvent) => html`
    <li class="${evCls(d)}" onclick=${() => selectEvent(selectedEv.peek() === d ? null : d)}>
      <span class="chip" style="background:#fff; border:1.5px dashed ${d.kind === "work" ? cWarm : cYea}"></span>
      <span class="when">${fmtClock(d.t0)}–${fmtClock(d.t1)}</span>
      <span class="what"><i>${d.label}</i> <span style="color:#999">· ${d.from}</span></span>
      <span class="yes" title="accept — commit"
            onclick=${(e: Event) => { e.stopPropagation(); commit(d); }}>✓</span>
      <span class="no" title="decline"
            onclick=${(e: Event) => { e.stopPropagation(); decline(d); }}>✕</span>
    </li>`);
  drawDetail();
}

/** What an act asks of you, in the visual language the recipe face already uses. */
const NEED_EMOJI: Record<string, string> = {
  consume: "\u{1F4E6}", use: "\u{1F527}", work: "\u{1F4AA}",
  "obtain-entity": "\u{1F4DC}", "obtain-person": "\u{1F194}",
  pay: "\u{1F4B6}", tell: "\u{1F4E3}",
};

/**
 * One requirement as a chip. `rc-flow rc-<kind>` is the recipe face's own class
 * vocabulary — reused rather than reinvented, so a means and a permit read the
 * same way here as they do there. What is NEW is the met state, which a recipe
 * flow does not have: a flow says what an act is made of, a requirement also
 * says whether you have it.
 */
function needChip(nd: EventNeed): Fragment {
  const q = nd.qty != null && nd.qty > 0
    ? `${+(+nd.qty).toFixed(2)}${nd.unit ? (nd.unit === "hours" ? "h" : " " + nd.unit) : ""}` : "";
  // held is unremarkable, so it is quiet; missing is the thing you came to
  // learn; unknown says nobody checked, which is not the same as absent
  const st = nd.met === "held" ? { o: 0.55, mark: "", col: "" }
           : nd.met === "missing" ? { o: 1, mark: " \u2717", col: STATUS.unmet }
           : { o: 0.8, mark: " ?", col: "" };
  return html`<span class="rc-flow rc-${nd.kind}"
                    style="opacity:${String(st.o)}${st.col ? `;color:${st.col}` : ""}"
                    title="${nd.kind}${nd.met === "missing" ? " — you do not hold this"
                                     : nd.met === "held" ? " — held" : " — nobody has checked"}"
              ><span class="rc-emoji">${NEED_EMOJI[nd.kind] || "\u2022"}</span>${
                q ? html`<span class="rc-q">${q}</span>` : ""
              }<span class="rc-spec">${nd.label}${st.mark}</span></span>`;
}

/**
 * WHAT THIS ACT NEEDS, HERE — and, when it cannot happen, why.
 *
 * Three states, and they are three because collapsing the last two is how an
 * absence comes to read as an answer:
 *   a list        the solve published what this act needs
 *   an EMPTY list it needs nothing here — a real answer, said plainly
 *   undefined     no row was found, so nothing is claimed either way
 * Rides and lived events have no row by construction, and this draws nothing
 * for them rather than telling you they ask for nothing.
 */
export function needsBlock(d: DayEvent): Fragment | string {
  if (!d.needs) return d.why ? whyLine(d) : "";
  if (!d.needs.length) return html`<div class="ev-needs"><span class="ev-needs-h">asks nothing here</span></div>`;
  const missing = d.needs.filter(n => n.met === "missing");
  return html`<div class="ev-needs">
    <span class="ev-needs-h">what this needs, here${
      missing.length ? html` — <span style="color:${STATUS.unmet}">${
        String(missing.length)} you do not hold</span>` : ""}</span>
    <div class="rc-flows">${d.needs.map(needChip)}</div>${d.why ? whyLine(d) : ""}</div>`;
}

/** Why an act the plan considered is not in it. */
function whyLine(d: DayEvent): Fragment | string {
  if (!d.why) return "";
  const REASON: Record<string, string> = {
    "licence-not-held": "a licence nobody holds",
    "skill-absent": "no one here has the competence",
    forbidden: "the law forbids it here",
    "raw-unreachable": "the materials cannot reach this place in time",
    "lead-does-not-fit": "it cannot finish inside the horizon",
    "outlasts-horizon": "it runs past the end of the plan",
    "branch-off": "this branch is switched off",
  };
  const det = (d.why.detail || []).filter(Boolean);
  return html`<div class="ev-why">\u26A0 ${REASON[d.why.reason] || d.why.reason}${
    det.length ? `: ${det.join(", ")}` : ""}</div>`;
}

/**
 * The one card under the dial, for whatever is selected.
 *
 * Your OWN event and an availability arc EDIT here rather than describing
 * themselves — the same surface, no popover — which is what makes the rim and
 * the rings one thing to a reader instead of two.
 */
function drawDetail(): void {
  const det = d3.select("#evdetail");
  const own = eventRing.editItem();
  if (own) {
    det.style("border-left-color", cYea).html("");
    eventRing.renderEditorBody(det); showChat(null); return;
  }
  const av = availRing.editItem();
  if (av) {
    det.style("border-left-color", "#9fd0ea").html("");
    availRing.renderEditorBody(det); showChat(null); return;
  }
  const d = selectedEv();
  if (!d) {
    det.style("border-left-color", "#ddd")
       .html("select an event — on the rim, or in the calendar");
    showChat(null); return;
  }
  const col = d.kind === "work" ? cWarm : cYea;
  const acts = actionsFor(d);
  // a double-booking is FLAGGED, not blocked — life double-books, and release
  // or reconsider is the resolution
  const clash = (d.status !== "proposed" && d.status !== "declined")
    ? eventConflicts(d) : [];

  det.style("border-left-color", col);
  render(det.node(), html`
    <b>${d.label}</b>${d.from ? html` <span style="color:#999">· with ${d.from}</span>` : ""}<br>
    ${fmtClock(d.t0)} – ${fmtClock(d.t1)} · ${fmtDur(d.t0, d.t1)} ·
    ${fmtTau(d.t0)} → ${fmtTau(d.t1)}<br>${
      d.place ? html`<span class="cal-loc" onclick=${() => showEventOnMap(d)}>📍 ${d.place}</span><br>` : ""}
    <span class="${d.kind === "work" ? "kw" : "kf"}">${d.kind === "work" ? "labour time" : "free time"}</span>
    — τ∕${(24 / (d.t1 - d.t0)).toFixed(1)} of the turn<br>
    <span style="color:#999">${vfLine(d)}</span>${needsBlock(d)}${
      clash.length
        ? html`<div style="color:${STATUS.unmet};font-size:11px;margin-top:5px">⚠ overlaps ${
                 clash.join(", ")} — release one to resolve</div>`
        : ""}${
      acts.length
        ? html`<div class="respond">${acts.map(a => a.amt != null
                 // a recording verb carries its adjustable amount: the input
                 // holds the remainder, the verb records what it says
                 ? html`<span class="r-amtwrap"><input class="r-amt" type="number"
                          min="0.25" step="0.25" value="${String(a.amt)}"><span
                          class="${a.c}" title="${a.t}" onclick=${(e: Event) => {
                            const w = (e.target as HTMLElement).parentElement;
                            const i = w && w.querySelector("input");
                            a.fa!(i ? parseFloat((i as HTMLInputElement).value) || a.amt! : a.amt!);
                          }}>${a.l}</span></span>`
                 : html`<span class="${a.c}" title="${a.t}" onclick=${a.f}>${a.l}</span>`)}</div>`
        : ""}`);
  showChat(d);           // the event's conversation rides along under the detail
}
