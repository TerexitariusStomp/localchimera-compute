import { html } from '../template.js';
import { CLASS_TITLE, TOPICS, classOfDomain, domainOf, statusOf, pct, shortAid, resolvedFor, keptIn } from './model.js';
import { viewClassChip } from './views.js';
const delegateIndex = (dels, to) => {
    const names = Array.from(new Set(dels.map(d => String(d.to))));
    return Math.max(0, names.indexOf(String(to))) % 3;
};
/** One cell of the map: your weight in this franchise and class, split into
 *  what you keep and what each delegate carries. */
function viewCell(v, weight, dels, cls, title) {
    if (weight == null)
        return html `<div class="fo-cell fo-cell-none" title="${title}"><span class="fo-none">—</span></div>`;
    const kept = Math.max(0, 1 - dels.reduce((s, d) => s + (d.fraction || 0), 0));
    const idx = (d) => delegateIndex(v.delegations, d.to);
    return html `<div class="fo-cell fo-cls-${cls}" title="${title}">
    <div class="fo-cellnum"><b>${pct(weight)}%</b></div>
    <div class="fo-cellbar" style="width:${Math.max(6, Math.min(100, weight * 300))}%">
      ${kept > 0 && html `<div class="fo-flowseg fo-kept" style="flex:${kept}" title="you act directly · ${pct(kept)}% of it"></div>`}
      ${dels.map(d => html `<div class="fo-flowseg fo-deleg${idx(d)}" style="flex:${d.fraction || 0}"
        title="${shortAid(d.to)} carries ${pct(d.fraction || 0)}% of it${d.mandated ? " · mandated" : ""}"></div>`)}
    </div>
    ${dels.length > 0 && html `<div class="fo-cellnote">${pct(kept)}% yours · ${dels.map(d => html `<i class="fo-dot fo-deleg${idx(d)}"></i>${shortAid(d.to)} ${pct(d.fraction || 0)}%`)}</div>`}
  </div>`;
}
export function viewVoice(v) {
    const { scopes, delegations: dels } = v;
    const byDomain = (d, st) => v.proposals.filter(p => domainOf(p) === d && statusOf(p) === st).length;
    const fedKept = keptIn(dels, null);
    const delegate = (ev) => {
        const btn = ev.currentTarget;
        const form = btn.closest(".fo-delegform");
        const to = String(form.querySelector(".fo-dto").value || "").trim();
        const frac = Number(form.querySelector(".fo-dfrac").value) / 100;
        btn.setAttribute("disabled", "true");
        v.onDelegate(to, frac);
    };
    return html `<div class="fo-voice">
    <div class="fo-card">
      <div class="fo-dischead">the voice map <span class="fo-count">franchise × class</span></div>
      <div class="fo-hint fo-hint-top">Producer voice is yours <b>per commune</b> — your share of the labour done there — and speaks on
        how the work is done. Consumer voice is <b>one number over the federation</b> and speaks on what the community needs.
        Each cell shows what you keep and what a delegate carries there.</div>
      <div class="fo-map" style="--cols:${scopes.length + 1}">
        <div class="fo-maphead"></div>
        <div class="fo-maphead fo-map-fed">federation</div>
        ${scopes.map(s => html `<div class="fo-maphead ${s.id === v.currentScope ? "fo-map-here" : ""}" title="${(s.path || []).map(p => p.name).join(" › ")}">${s.name}</div>`)}
        <div class="fo-maprow fo-cls-production">production<small>${CLASS_TITLE.production}</small></div>
        <div class="fo-cell fo-cell-none" title="production is decided where the work is done — per commune"><span class="fo-none">per commune</span></div>
        ${scopes.map(s => viewCell(v, v.producerIn(s.id), resolvedFor(dels, s.id), "production", `your producer voice in ${s.name}`))}
        <div class="fo-maprow fo-cls-consumption">consumption<small>${CLASS_TITLE.consumption}</small></div>
        ${viewCell(v, v.consumer, resolvedFor(dels, null), "consumption", "your consumer voice over the federation")}
        ${scopes.map(() => html `<div class="fo-cell fo-cell-span" title="consumer voice is federation-wide"><span class="fo-none">↤ federation</span></div>`)}
      </div>
    </div>
    <div class="fo-card">
      <div class="fo-dischead">across topics <span class="fo-count">${v.proposals.length} threads</span></div>
      <div class="fo-topics">${TOPICS.map(t => {
        const cls = classOfDomain(t.d), open = byDomain(t.d, "open"), done = byDomain(t.d, "closed"), w = v.weightFor(cls);
        return html `<a class="fo-topic fo-cls-${cls}" onclick=${() => v.onTopic(open ? "open" : "decided", t.d)}>
          <div class="fo-topic-l">${t.label}</div>
          <div class="fo-topic-w">${viewClassChip(cls)}${w != null && html `<b>${pct(w)}%</b>`}</div>
          <div class="fo-topic-n">${open ? html `<span class="fo-status open">${open} open</span>` : ""}${done ? html `<span class="fo-status closed">${done} decided</span>` : ""}${!open && !done ? html `<span class="fo-none">quiet</span>` : ""}</div>
        </a>`;
    })}</div>
    </div>
    <div class="fo-card">
      <div class="fo-dischead">where it goes</div>
      <div class="fo-deleglist">
        <div class="fo-delegrow"><i class="fo-dot fo-kept"></i>you act directly · <b>${pct(fedKept)}%</b> <span class="fo-domain">federation default</span></div>
        ${dels.map(d => html `<div class="fo-delegrow">
          <i class="fo-dot fo-deleg${delegateIndex(dels, d.to)}"></i>→ <span title="${d.to || ""}">${shortAid(d.to)}</span> · <b>${pct(d.fraction || 0)}%</b>
          ${d.mandated && html `<span class="fo-mand">mandated</span>`}
          <span class="fo-domain">${d.scope ? `in ${scopes.find(s => s.id === d.scope)?.name || shortAid(d.scope)}` : "everywhere"}</span>
          ${v.canDelegate && d.to &&
        html `<button class="fo-revoke" title="take this share back" onclick=${() => v.onRevoke(d)}>revoke</button>`}
        </div>`)}
      </div>
      ${v.canDelegate
        ? html `<div class="fo-form fo-delegform">
            <input class="fo-dto" placeholder="a delegate — their AID, or a name here in the demo">
            <input class="fo-dfrac" type="number" min="1" max="100" step="1" value="${Math.max(1, pct(fedKept))}" title="the share of your voice, in %">
            <span class="fo-unit">%</span>
            <button class="fo-go" onclick=${delegate}>delegate</button>
          </div>
          <div class="fo-hint">a delegate carries that share of your voice on every decision until you take it back —
            revocation is the accountability rail.</div>`
        : html `<div class="fo-hint">sign in to delegate your voice</div>`}
    </div>
  </div>`;
}
