// app/recognition-view.ts — keys and devices › "recognised person": where the
// commune says you stand as a person, and the newcomers who ask to be
// recognised.
//
// Recognition keeps out spam: recognised people who have met you sign that
// they have. Ask, and every recognised member sees it; once enough have signed
// the credential issues. A recognised member answers other people's asks here
// with the one act the calendar rail also offers — their signature over the
// statement. The ceremony is the truth; nothing on this device is.
import { html } from './template.js';
import { signal } from './reactive.js';
import { identityState, recognised, askSaying, readStanding, requestRecognition, recogniseMyself, pendingAsks, witness } from './tabs/social/id.js';
const standing = signal(null);
const asks = signal([]);
/** What each act last said, by its key: the button shows it in place of its label. */
const said = signal({});
const say = (key, d) => said.update(s => ({ ...s, [key]: d }));
let readFor = "";
/** Read once per door state; a state that changes (seated, recognised) reads again. */
function load() {
    const key = `${identityState.peek()}|${recognised()}`;
    if (key === readFor)
        return;
    readFor = key;
    void readStanding().then(async (s) => { standing.set(s); asks.set(await pendingAsks()); });
}
const act = (key, label, run, cls = "") => {
    const d = said()[key];
    return html `<button type="button" class="ob-chip${d?.ok ? " on" : ""}${cls}" onclick=${() => void run().then(r => say(key, r))}>${d ? d.said : label}</button>`;
};
/** The settings block: a Fragment over signals. Mount it once (settings-sections.ts mountFragment). */
export function recognitionBlock() {
    if (identityState() !== "authed")
        return html `<p class="ob-note">recognition is asked of the commune you sit at — sign in, and it is here.</p>`;
    load();
    const st = standing();
    if (!st)
        return html `<p class="ob-note">checking standing…</p>`;
    const list = asks();
    const body = st.person
        ? html `<p class="ob-state">✓ recognised person</p>
        ${st.carried ? html `<small class="ob-hint">credential ${st.carried.d.slice(0, 14)}… · issued by ${st.carried.i.slice(0, 12)}… — carried, presentable to other communes</small>` : ""}`
        : (() => {
            const a = st.ask, collecting = a?.state === "collecting", nobody = !st.bootstrapped;
            return html `
          <p class="ob-state">${collecting ? `pending · ${a.count} of ${a.quorum}` : "provisional"}</p>
          <small class="ob-hint">${nobody
                ? "no one is recognised here yet — the founder's first act makes the first person."
                : collecting
                    ? askSaying(a) + (a.vouchers.length
                        ? ` ${a.vouchers.length === 1 ? "one of them" : `${a.vouchers.length} of them`} already vouch${a.vouchers.length === 1 ? "es" : ""} for you.`
                        : "")
                    : "recognition keeps out spam: recognised people who have met you sign that they have. Ask, and every recognised member sees it."}</small>
          ${!collecting && !nobody ? html `<div class="ob-opts">${act("ask", "request recognition", requestRecognition)}</div>` : ""}
          ${nobody && st.governor ? html `<div class="ob-opts">${act("self", "recognise myself — the first person", recogniseMyself)}</div>` : ""}`;
        })();
    return html `
    <div class="recognition ob-expand" style="border:0;padding:0">
      ${body}
      ${list.length ? html `
        <div class="ob-field"><span>asking to be recognised</span></div>
        <ul class="ob-skills">${list.map(row => html `
          <li><span class="ob-skname">${row.candidate.slice(0, 18)}…</span>
            <span class="ob-opt">${row.count} of ${row.quorum}</span>
            ${act(`w:${row.said}`, "✍ witness", () => witness(row.said))}</li>`)}</ul>` : ""}
    </div>`;
}
