// app/diag.ts — the last N things the page said about itself.
//
// A bug report is worth what it lets someone reproduce, and the single most
// useful thing a browser knows is the error it already threw. So this keeps a
// bounded ring of the console and of uncaught failures, for the feedback lane
// to offer alongside what a person types.
//
// It runs everywhere the dial does — desktop, phone, over the onion — because
// it is nothing but the page watching itself. No API, no permission, no
// service: the same reason the feedback pool needs no account.
//
// INSTALLED FIRST, and that is the whole reason this is its own module rather
// than part of the lane: the errors most worth capturing happen during boot,
// long before anyone opens a feedback panel, so the ring has to already be
// running by then. main.ts imports it above everything else.
//
// BOUNDED, twice over. The ring keeps a fixed number of entries so a page left
// open all day costs the same as one just loaded, and each entry is truncated
// so a single enormous object cannot fill it alone.
//
// It never sends anything. What leaves the page is chosen in the panel, by the
// person, who can read it first — console output can carry names, places and
// identifiers this pool deliberately does not ask for, and a diagnostic
// attached without being read would be exactly the surprise the lane promises
// not to be.
const RING = 120; // entries kept
const LINE = 400; // characters per entry
const ring = [];
const t0 = Date.now();
// ── what must never reach the ring ──────────────────────────────────
//
// The dial says a great deal about itself while it boots, and some of it is
// SECRET in the strict sense: an OCapN sturdyref is a bearer capability, so
// the swiss-num inside one grants whatever it names to whoever holds it. The
// gateway's own sref is logged on every connect. Attaching that to anonymous
// feedback would publish a live capability, and no visitor reading the
// preview could be expected to recognise which of those characters mattered.
//
// So the scrub happens at CAPTURE, not at send: the ring never holds the
// secret at all, and no later path — a new caller, a copied line, a future
// place these entries get shown — can leak what was never kept. The real
// console still receives every call untouched, so a developer with devtools
// open loses nothing.
//
// Best effort by construction. It is the last line of defence, not the only
// one: the lane still shows the person exactly what would be sent.
const REDACTIONS = [
    // an OCapN sturdyref: keep the shape and the host, drop what it grants
    [/(ocapn:\/\/[^/\s"']+)\/[^\s"']*/gi, '$1/…redacted…'],
    // a URL's query string can carry the same thing by another route
    [/([?&](?:url|sref|token|key|bran|passcode|secret)=)[^\s&"']+/gi, '$1…redacted…'],
    // a long base64url run standing on its own is a swiss-num, an AID, or a key
    [/\b[A-Za-z0-9_-]{32,}\b/g, '…redacted…'],
];
const redact = (s) => REDACTIONS.reduce((acc, [re, to]) => acc.replace(re, to), s);
const say = (kind, parts) => {
    let text;
    try {
        text = parts.map(p => typeof p === "string" ? p
            : p instanceof Error ? `${p.name}: ${p.message}`
                : JSON.stringify(p)).join(" ");
    }
    catch {
        // a circular or getter-throwing object must not take the page down for
        // the sake of a diagnostic
        text = parts.map(p => String(p)).join(" ");
    }
    ring.push({ t: Date.now() - t0, kind, text: redact(text).slice(0, LINE) });
    if (ring.length > RING)
        ring.shift();
};
let installed = false;
/** Start watching. Idempotent — a second call is a no-op, not a second wrapper. */
export function initDiag() {
    if (installed)
        return;
    installed = true;
    for (const kind of ["log", "warn", "error"]) {
        const original = console[kind].bind(console);
        // the page keeps its own console exactly as it was: this observes, and
        // hands every call straight on, so nothing a developer relies on moves
        console[kind] = (...parts) => { say(kind, parts); original(...parts); };
    }
    window.addEventListener("error", e => say("throw", [`${e.message} (${e.filename}:${e.lineno}:${e.colno})`]));
    window.addEventListener("unhandledrejection", e => say("reject", [e.reason instanceof Error ? e.reason : String(e.reason)]));
}
// Installed as this module's own side effect, which is what makes "first"
// achievable: main.ts imports it above everything else, and an import's body
// runs before the imports below it. Guarded so a node test can import the
// module for its pure parts without wrapping the test runner's console.
if (typeof window !== "undefined" && typeof document !== "undefined")
    initDiag();
/**
 * What the spine's boot said, in its own words.
 *
 * day-boot.js keeps its own breadcrumbs in a hidden #bootTrace element for
 * headless debugging; reading that back is how a boot failure — the kind that
 * leaves the app blank and is hardest to describe in words — reaches the
 * report at all.
 */
export function bootTrace() {
    const el = typeof document !== "undefined" ? document.getElementById("bootTrace") : null;
    // day-boot's breadcrumbs carry the gateway sref verbatim, so this needs the
    // same scrub the ring gets — it is the same secret by a different road
    return redact((el?.textContent || "").trim());
}
/**
 * Scrub secret-shaped text.
 *
 * Exported because the ring is not the only thing that carries page state into
 * a report: the URL does too, and the dial's own local flow puts a sturdyref
 * in a query parameter (`?gateway=…`). Anything free-form on its way out goes
 * through here, so the defence lives in one place rather than at each door.
 */
export { redact };
/** Everything the ring holds, oldest first. */
export const diagLines = () => ring.slice();
/** How many of those are failures rather than chatter. */
export const diagFaults = () => ring.filter(l => l.kind === "error" || l.kind === "throw" || l.kind === "reject").length;
/**
 * The ring as text, newest last, capped in BYTES so it can be budgeted
 * against the pool's body limit rather than hoped about.
 */
export function diagText(maxBytes) {
    const lines = ring.map(l => `${(l.t / 1000).toFixed(1)}s ${l.kind}: ${l.text}`);
    // drop from the FRONT: the newest lines are the ones nearest what the
    // person is describing
    let out = lines.join("\n");
    while (out.length > maxBytes && lines.length) {
        lines.shift();
        out = lines.join("\n");
    }
    return out;
}
