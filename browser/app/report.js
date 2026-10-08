// app/report.ts — "report a concern": the in-product way to tell the operator
// about unlawful or harmful content or conduct, or a child at risk (terms
// §7.2, privacy §11). A report is one JSON body to /report, the operator's
// report pool — a pool of its own, never the feedback pool, with its own file,
// admin token and size bound (server/serve-static.scm). Nothing about the
// reporter is sent unless they choose to give a way back. The operator's own
// contact (/operator.json: abuse, falling back to contact, as legal-operator.js
// does for the notices) is shown beside the form: a direct route that needs no
// gateway to be up.
import { signal } from './reactive.js';
import { html, panel } from './template.js';
import { chip } from './chips.js';
import { toast } from './toast.js';
import { stage } from './stage.js';
import { REPORT_MAX_BYTES } from './limits-catalogue.js';
const CATEGORIES = [
    { id: "child", label: "a child at risk", hint: "a child in danger, or sexual content involving a minor" },
    { id: "unlawful", label: "unlawful content", hint: "content or conduct you consider against the law" },
    { id: "harassment", label: "harassment or threats", hint: "someone threatening, stalking or targeting a person" },
    { id: "rights", label: "infringes someone's rights", hint: "copyright, privacy or another right" },
    { id: "other", label: "something else", hint: "anything else the operator should look at" },
];
const category = signal("unlawful");
// The three text fields are plain variables, not signals: the panel redraws
// on every signal it reads, and a redraw on each keystroke would replace the
// input under the typist's cursor. A chip pick or a send redraws; typing does not.
let whereV = "", saidV = "", backV = "";
const state = signal("idle");
const operator = signal(null);
let loaded = false;
function loadOperator() {
    if (loaded)
        return;
    loaded = true;
    window.fetch("operator.json")
        .then(r => r.ok ? r.json() : null)
        .then((op0) => {
        const op = op0 ?? {};
        const v = (op.abuse || op.contact || "").trim();
        if (v)
            operator.set(v);
    })
        .catch(() => { });
}
/** `mailto:` for an address, the text as-is for a URL or anything else the operator wrote. */
function contactLink(v) {
    const href = /^[a-z][a-z0-9+.-]*:/i.test(v) ? v : /@/.test(v) ? `mailto:${v}` : null;
    return href ? html `<a href="${href}" target="_blank" rel="noopener">${v}</a>` : html `<b>${v}</b>`;
}
function body() {
    return JSON.stringify({
        v: 1, kind: "report", category: category(),
        where: whereV.trim(), text: saidV.trim(), back: backV.trim() || undefined,
        face: stage.face, at: new Date().toISOString(),
    });
}
function send() {
    if (!saidV.trim()) {
        toast("say what you are reporting first", "notice");
        return;
    }
    const b = body();
    if (b.length > REPORT_MAX_BYTES) {
        toast("this report is too long — shorten it", "warn");
        return;
    }
    state.set("sending");
    window.fetch("/report", { method: "POST", headers: { "Content-Type": "application/json" }, body: b })
        .then(r => r.ok ? r.json() : Promise.reject(r.status))
        .then(() => { whereV = saidV = backV = ""; state.set("sent"); })
        .catch(() => state.set("failed"));
}
/** The report form, one element for the page's life. */
export const reportBlock = panel(() => {
    loadOperator();
    const cat = CATEGORIES.find(c => c.id === category());
    const op = operator();
    return html `
    <p class="ob-note">This goes to the operator of this gateway, who reads it and decides what to do
      (terms §7.2). It cannot erase signed records held by witnesses or other gateways, and we say so
      rather than imply otherwise.</p>
    <div class="ob-field"><span>what is it about</span>
      <div class="ob-opts">${CATEGORIES.map(c => chip(category() === c.id, c.label, () => category.set(c.id), c.hint))}</div>
      <small>${cat.hint}</small></div>
    ${category() === "child" ? html `<p class="ob-state">If a child is in immediate danger, call your local emergency number first.
      Do not collect, copy or forward the material yourself — say where it is and we will act.</p>` : ""}
    <label class="ob-field"><span>where is it</span>
      <input type="text" placeholder="an AID, a credential, or a place in the interface" value="${whereV}"
             oninput=${(e) => { whereV = e.target.value; }}></label>
    <label class="ob-field"><span>what you are reporting</span>
      <textarea rows="5" placeholder="what happened, and why you consider it unlawful or harmful"
                oninput=${(e) => { saidV = e.target.value; }}>${saidV}</textarea></label>
    <label class="ob-field"><span>a way back to you <span class="ob-opt">optional</span></span>
      <input type="text" placeholder="an address or handle, only if you want an answer" value="${backV}"
             oninput=${(e) => { backV = e.target.value; }}>
      <small>Left empty, the report is anonymous. A good-faith statement that it is accurate and complete helps us act.</small></label>
    <button class="ob-next ob-wide" ${state() === "sending" ? "disabled" : ""} onclick=${send}>${state() === "sending" ? "sending…" : "send the report"}</button>
    ${state() === "sent" ? html `<p class="ob-state">sent — the operator will read it. Thank you.</p>` : ""}
    ${state() === "failed" ? html `<p class="ob-err">could not send. Try again, or write to the operator directly${op ? html `: ${contactLink(op)}` : ""}.</p>` : ""}
    <p class="ob-note">${op ? html `To write to the operator directly: ${contactLink(op)}.`
        : html `This gateway's operator has not published a contact yet.`}</p>`;
}, "attr");
