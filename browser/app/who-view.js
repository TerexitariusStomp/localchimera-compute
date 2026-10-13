// app/who-view.ts — your profile › "name and identifier": what people call you,
// the identifier that names you, and the notices you accepted.
//
// The name is optional, kept on this device first and told to the commune at
// the next seat; it is not used for recovery. The identifier names the identity
// and is not secret — the passcode is the key.
import { html } from './template.js';
import { signal } from './reactive.js';
import { hint } from './core.js';
import { identity, identityState, setMyName, consentRecord, DOCUMENT_VERSION } from './tabs/social/id.js';
import { TERMS_HREF, PRIVACY_HREF } from './legal-product.js';
/** The save in flight: the block says so and keeps its field. */
const saving = signal(false);
async function save(e) {
    const row = e.currentTarget.closest(".who-name");
    const name = row.querySelector("input[name=name]").value.trim();
    saving.set(true);
    try {
        // the email the member record holds stays as it is
        const r = await setMyName(name, identity.peek()?.email || "");
        if (r === "ok")
            hint(name ? `called ${name}` : "no name set", "success");
        // a name set with no seat is kept here and goes to the commune at the next one
        else if (identityState.peek() !== "authed")
            hint("kept on this device — the commune hears it at your next seat", "notice");
        else
            hint(r.replace(/^err:/, ""), "error");
    }
    finally {
        saving.set(false);
    }
}
/** The settings block: a Fragment over signals. Mount it once (settings-sections.ts mountFragment). */
export function whoBlock() {
    const me = identity();
    if (!me)
        return html `<p class="ob-note">nobody is signed in on this device — make an identity, or sign in, from the person button.</p>`;
    const c = consentRecord();
    return html `
    <div class="who-view ob-expand" style="border:0;padding:0">
      <label class="ob-field who-name"><span>name</span>
        <div class="ob-pass"><input type="text" name="name" autocomplete="nickname" spellcheck="false"
               placeholder="name — so others can find you" value="${me.name}">
          <button type="button" class="ob-chip" ${saving() ? html `disabled` : ""} onclick=${save}>save</button></div>
        <small>optional, and not used for recovery — please do not use your legal name while this is a demo.</small></label>
      <div class="ob-field"><span>identifier (names you — not secret)</span>
        <div class="ob-pass"><input class="ob-code ob-aid" type="text" readonly spellcheck="false" aria-label="your identifier" value="${me.aid}">
          <button type="button" class="ob-chip" onclick=${(e) => {
        if (navigator.clipboard)
            void navigator.clipboard.writeText(me.aid);
        const b = e.target;
        b.textContent = "✓ copied";
        setTimeout(() => { b.textContent = "copy"; }, 1500);
    }}>copy</button></div></div>
      <small class="ob-hint"><a href="${TERMS_HREF}" target="_blank" rel="noopener">terms of use</a> ·
        <a href="${PRIVACY_HREF}" target="_blank" rel="noopener">privacy notice</a>${c && c.at
        ? html `<br>accepted v${DOCUMENT_VERSION} (effective ${c.v}) on ${String(c.at).slice(0, 10)}` : ""}</small>
    </div>`;
}
