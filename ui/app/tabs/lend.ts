// app/tabs/lend.ts — the "lend" face: this tab IS the compute node.
//
// Three readings of the compute registry for the scope you're standing in:
// what you OFFER (lanes you lend on, the task classes and headroom you
// declared), what is ASKED (open jobs you could claim against one of those
// offers), and what you RUN (your claims: claimed → run → receipted). The
// "stay lent" switch arms lendLoop — the poll that takes each live claim as
// it lands, runs it in a worker it cannot escape, and countersigns the
// receipt back. Close the tab and the lending stops: that is the whole
// participation model.
//
// Rows read the registry's wire shape: offers carry `lender`, `lane`,
// `taskClasses`, `headroom`, `reproMode`; jobs carry `taskClass`, `lane`,
// `state`; claims carry `lender`, `state`, `deadline`. Every act goes
// through HANDLERS (session/compute-*); standalone, the face is empty.

import { HANDLERS, askJSON } from '../core.js';
import { html, render } from '../template.js';
import { signal, effect } from '../reactive.js';
import { scopeSig } from '../scope.js';
import { identity } from './social/id.js';
import { lendLoop } from '../compute-executor.js';
import type { ClaimRow } from '../compute-executor.js';

interface OfferRow {
  id: string; lender: string; lane: string;
  taskClasses: string[]; headroom: number; reproMode: string; usageUnit: string;
}
interface JobRow {
  id: string; borrower: string; taskClass: string; lane: string;
  reproMode: string; state: string; inputHash: string;
}
interface DisputeChallenge {
  receiptDigest: string; reproduced: boolean;
  attestationHash: string; counterHash: string;
}
interface DisputeRow {
  id: string; claimId: string; challenger: string; kind: string;
  state: string; raisedAt: number; reviewers: string[];
  verdicts: Record<string, string>[] | Record<string, string>;
  outcome: string | null; challenge: DisputeChallenge | null;
}

const offers = signal<OfferRow[] | null>(null);
const jobs = signal<JobRow[] | null>(null);
const claims = signal<ClaimRow[] | null>(null);
const disputes = signal<DisputeRow[] | null>(null);
const lent = signal(false);          // "stay lent" — the poll loop armed
const busy = signal<Record<string, string>>({}); // claimId → running|done|err:…

let stopLend: (() => void) | null = null;

const me = (): string => {
  try { return String(identity()?.aid ?? ""); } catch { return ""; }
};

const mine = <T extends { lender?: string }>(rows: T[] | null): T[] =>
  (rows || []).filter(r => r.lender === me());

const openJobs = () =>
  (jobs() || []).filter(j => j.state === "open");

const myLanes = () => new Set(mine(offers()).map(o => o.lane));

// jobs on lanes I actually offer — what the matcher would hand me
const claimable = () => {
  const lanes = myLanes();
  return openJobs().filter(j => lanes.size === 0 || lanes.has(j.lane));
};

const seam = () => HANDLERS as unknown as Parameters<typeof lendLoop>[0] & {
  computeOffer?: (commune: string, lane: string, classes: string, headroom: number, repro: string, opts: string) => Promise<unknown>;
  computeClaim?: (commune: string, jobId: string, offerId: string, opts: string) => Promise<unknown>;
  computeRetract?: (commune: string, offerId: string) => Promise<unknown>;
  computeDispute?: (commune: string, claimId: string, kind: string) => Promise<unknown>;
  computeDisputeVerdict?: (commune: string, disputeId: string, verdict: string) => Promise<unknown>;
  computeDisputeClose?: (commune: string, disputeId: string) => Promise<unknown>;
};

async function refresh() {
  const c = scopeSig();
  if (!c) { offers.set(null); jobs.set(null); claims.set(null); disputes.set(null); return; }
  offers.set(await askJSON(() => HANDLERS.computeOffers?.(c), [] as OfferRow[]));
  jobs.set(await askJSON(() => HANDLERS.computeJobs?.(c), [] as JobRow[]));
  claims.set(await askJSON(() => HANDLERS.computeClaims?.(c), [] as ClaimRow[]));
  disputes.set(await askJSON(() => HANDLERS.computeDisputes?.(c), [] as DisputeRow[]));
}

function arm(on: boolean) {
  const c = scopeSig(), aid = me();
  stopLend?.(); stopLend = null; lent.set(false);
  if (!on || !c || !aid) return;
  stopLend = lendLoop(seam(), c, aid, null, {
    onRow: (id, st) => busy.set({ ...busy(), [id]: st }),
  });
  lent.set(true);
}

export function initLend() {
  void refresh();

  const disputesOn = (claimId: string) =>
    (disputes() || []).filter(d => d.claimId === claimId);
  const relevant = () => {
    const aid = me(), claimIds = new Set(mine(claims()).map(c2 => String(c2.id)));
    return (disputes() || []).filter(d =>
      d.challenger === aid || claimIds.has(d.claimId) ||
      (d.reviewers || []).includes(aid));
  };
  const verdictCount = (d: DisputeRow) => {
    const v = d.verdicts;
    if (Array.isArray(v)) return v.length;
    if (v && typeof v === "object") return Object.keys(v).length;
    return 0;
  };

  effect(() => {
    const o = mine(offers()), j = claimable(), cl = mine(claims());
    const ds = relevant();
    const b = busy(), on = lent(), aid = me();
    render("#lendstage", html`
      <div class="lend">
        <h2>lend compute</h2>
        ${!aid ? html`<p class="ln-note">sign in to lend this tab's compute.</p>` : ""}
        <section>
          <h3>what you offer ${o.length ? html`<small>(${o.length})</small>` : ""}</h3>
          <form onsubmit=${(e: Event) => {
            e.preventDefault();
            const f = e.target as HTMLFormElement;
            const d = new FormData(f);
            const c = scopeSig();
            if (!c || !seam().computeOffer) return;
            void seam().computeOffer!(c, String(d.get("lane") || "member"),
              String(d.get("classes") || "compute"),
              Number(d.get("headroom") || 1), "exact", "").then(refresh);
          }}>
            <input name="lane" placeholder="lane — member | browser | gpu" value="member" />
            <input name="classes" placeholder="task classes — compute,inference" value="compute" />
            <input name="headroom" type="number" min="1" value="1" title="concurrent slots" />
            <button type="submit">offer</button>
          </form>
          ${o.map(of => html`
            <div class="ln-row">
              <b>${of.lane}</b> · ${(of.taskClasses || []).join(", ")} ·
              ${of.headroom} slot${of.headroom === 1 ? "" : "s"} · ${of.reproMode}
              <button onclick=${() => scopeSig() && seam().computeRetract &&
                void seam().computeRetract!(scopeSig()!, of.id).then(refresh)}>retract</button>
            </div>`)}
          ${o.length === 0 ? html`<p class="ln-note">no lanes offered yet.</p>` : ""}
        </section>
        <section>
          <h3>asked ${j.length ? html`<small>(${j.length} on your lanes)</small>` : ""}</h3>
          ${j.map(job => html`
            <div class="ln-row">
              <b>${job.taskClass}</b> · ${job.lane} · ${job.reproMode} ·
              <span class="ln-hash">${job.inputHash}</span>
              ${o.map(of => of.lane === job.lane ? html`
                <button onclick=${() => scopeSig() && seam().computeClaim &&
                  void seam().computeClaim!(scopeSig()!, job.id, of.id, "").then(refresh)}
                >claim → ${of.id.slice(0, 12)}…</button>` : null)}
            </div>`)}
          ${j.length === 0 ? html`<p class="ln-note">nothing asked on your lanes.</p>` : ""}
        </section>
        <section>
          <h3>what you run ${cl.length ? html`<small>(${cl.length})</small>` : ""}</h3>
          <label class="ln-stay">
            <input type="checkbox" ${on ? "checked" : ""}
              onchange=${(e: Event) => arm((e.target as HTMLInputElement).checked)} />
            stay lent — run each claim as it lands
          </label>
          ${cl.map(c2 => {
            const cid = String(c2.id ?? "");
            const open = disputesOn(cid).filter(d => d.state !== "closed" && !d.outcome);
            return html`
            <div class="ln-row">
              <span class="ln-hash">${cid.slice(0, 18)}…</span> ·
              <b>${c2.state}</b>${b[cid] ? html` · ${b[cid]}` : ""}
              ${open.length ? html` · <span class="ln-flag">disputed</span>` : html`
                <button title="the countersign deadline passed with no receipt"
                  onclick=${() => scopeSig() && seam().computeDispute &&
                    void seam().computeDispute!(scopeSig()!, cid, "non-delivery").then(refresh)}
                >dispute · no receipt</button>
                <button title="the receipt doesn't reproduce — PoI replay decides"
                  onclick=${() => scopeSig() && seam().computeDispute &&
                    void seam().computeDispute!(scopeSig()!, cid, "wrong-result").then(refresh)}
                >dispute · wrong result</button>`}
            </div>`;
          })}
          ${cl.length === 0 ? html`<p class="ln-note">no claims yet — offer a lane, claim a job.</p>` : ""}
        </section>
        <section>
          <h3>disputes ${ds.length ? html`<small>(${ds.length})</small>` : ""}</h3>
          ${ds.map(d => {
            const reviewing = d.state === "review" && (d.reviewers || []).includes(aid);
            return html`
            <div class="ln-row">
              <span class="ln-hash">${String(d.id).slice(0, 18)}…</span> ·
              <b>${d.kind}</b> · ${d.state}${d.outcome ? html` → ${d.outcome}` : ""} ·
              ${verdictCount(d)}/3 votes
              ${d.challenge ? html` · replay: ${d.challenge.reproduced ? "reproduced" : "mismatch"}` : ""}
              ${reviewing ? html`
                <button onclick=${() => scopeSig() && seam().computeDisputeVerdict &&
                  void seam().computeDisputeVerdict!(scopeSig()!, d.id, "upheld").then(refresh)}>uphold</button>
                <button onclick=${() => scopeSig() && seam().computeDisputeVerdict &&
                  void seam().computeDisputeVerdict!(scopeSig()!, d.id, "dismissed").then(refresh)}>dismiss</button>` : ""}
              ${d.state === "review" || d.state === "open" ? html`
                <button title="prod the clock — a review past its window lapses"
                  onclick=${() => scopeSig() && seam().computeDisputeClose &&
                    void seam().computeDisputeClose!(scopeSig()!, d.id).then(refresh)}>close</button>` : ""}
            </div>`;
          })}
          ${ds.length === 0 ? html`<p class="ln-note">no disputes touch your claims.</p>` : ""}
        </section>
      </div>`);
  });
}
