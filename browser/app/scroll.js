// app/scroll.ts — the playnet scroll, and the keep inside it.
//
// A paper popup over whatever face is up: about, the code, the chat, and the
// two ways to keep the server running. It touches NO dial state — not the
// focus, not the turn, not the map — which is why it is a leaf module and why
// the wordmark can open it from anywhere by importing one function.
//
// ── THE KEEP ────────────────────────────────────────────────────────────────
// The same two paths the REPL's donate panel offers (hoot/repl.scm), on the
// scroll's paper: a coin-agnostic swap, and the wallet's own address.
//
// The QR beside the address is pre-generated AT BUILD TIME
// (`qrencode -t SVG -l M -m 2 monero:<address>?recipient_name=playnet` →
// browser/assets/icons/donate-monero.svg, precached by sw.js). So no QR library
// ships, and the direct path works with no network at all — which is the point
// of having a direct path. Regenerate it on key rotation.
import { ATTRIBUTION, LICENCE_LINE, TERMS_HREF, PRIVACY_HREF, ACCESSIBILITY_HREF } from './legal-product.js';
import { SHOW_SOURCE } from './source.js';
/** The server wallet's address. The SVG beside it is generated from this. */
const GIVE_ADDR = "49AS5K3BKdw8mGrTkP4psGd8CsaSWE6aQ6QsPW45xQBPDBzCZjAopGBPLibwtut86HaiZiPyyc5YcSQ1ydysdqMSADmVCJR";
// Trocador AnonPay: USD-denominated, ETH→XMR by default, $50 preset. Trocador's
// form declines to combine `is_donation=True` with `fiat_equiv`, so its own
// button reads "Pay" — the USD denomination and the coin picker are worth more
// here than the wording.
//
// AnonPay answers with `X-Frame-Options: DENY` — it refuses to be framed — so
// this is a link OUT rather than the REPL's embedded widget. The address above
// is the path that needs nobody: a local SVG and a string.
const GIVE_SWAP_URL = "https://trocador.app/anonpay/?ticker_to=xmr&network_to=Mainnet" +
    "&address=" + GIVE_ADDR +
    "&simple_mode=True&fiat_equiv=USD&amount=50.0" +
    "&name=Playnet&description=Donation" +
    "&ticker_from=eth&network_from=ERC20&bgcolor=00000000";
const wrap = () => document.getElementById("scrollwrap");
/** The scroll's foot: the attribution the licence asks every deployment to
 *  show, the licence in one line, and the way to the terms and the privacy
 *  notice — the product's own notices (legal-product.ts), said here once. */
function initNotices() {
    const foot = document.querySelector("#scrollpaper .scroll-foot");
    if (!foot)
        return;
    const line = (text) => { const d = document.createElement("div"); d.textContent = text; return d; };
    const link = (text, href) => {
        const a = document.createElement("a");
        a.textContent = text;
        a.href = href;
        a.target = "_blank";
        a.rel = "noopener";
        return a;
    };
    const ways = document.createElement("div");
    ways.append(link("terms", TERMS_HREF), " · ", link("privacy", PRIVACY_HREF), " · ", link("accessibility", ACCESSIBILITY_HREF));
    const attribution = SHOW_SOURCE ? ATTRIBUTION : ATTRIBUTION.replace(/ \(rad:[^)]*\)$/, "");
    foot.replaceChildren(line(attribution), line(LICENCE_LINE), ways);
}
/** The code row, hidden with the same switch as the attribution's repository id. */
function initSource() {
    document.querySelectorAll("[data-source]").forEach(el => { el.hidden = !SHOW_SOURCE; });
}
/** Open the scroll. The wordmark in the crumb is its one door. */
export function openScroll() {
    const w = wrap();
    if (w) {
        w.classList.add("on");
        w.setAttribute("aria-hidden", "false");
    }
}
/** Close it — the ✕, the backdrop and Escape all land here. */
export function closeScroll() {
    const w = wrap();
    if (w) {
        w.classList.remove("on");
        w.setAttribute("aria-hidden", "true");
    }
}
/** The keep's disclosure row, the swap link, the address and its copy button. */
function initGive() {
    const row = document.getElementById("scrollgiverow");
    const panel = document.getElementById("scrollgive");
    if (!row || !panel)
        return;
    const swap = document.getElementById("giveswap");
    const addr = document.getElementById("giveaddr");
    const copy = document.getElementById("givecopy");
    if (addr)
        addr.textContent = GIVE_ADDR;
    if (swap)
        swap.href = GIVE_SWAP_URL;
    row.onclick = () => {
        const open = panel.hidden;
        panel.hidden = !open;
        row.setAttribute("aria-expanded", open ? "true" : "false");
    };
    if (copy)
        copy.onclick = async () => {
            try {
                await navigator.clipboard.writeText(GIVE_ADDR);
                copy.textContent = "copied";
            }
            catch (_) {
                copy.textContent = "select it and copy";
            }
            setTimeout(() => { copy.textContent = "copy address"; }, 2200);
        };
}
/** Wire the scroll's three ways out, and the keep inside it. */
export function initScroll() {
    const w = wrap();
    if (w) {
        const x = document.getElementById("scrollclose");
        if (x)
            x.onclick = closeScroll;
        w.addEventListener("click", e => { if (e.target === w)
            closeScroll(); }); // backdrop
        document.addEventListener("keydown", e => { if (e.key === "Escape" && w.classList.contains("on"))
            closeScroll(); });
    }
    initGive();
    initNotices();
    initSource();
}
