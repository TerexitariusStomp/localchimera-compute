// app/connect-link.ts — the one grammar of a person's link.
//
// A person is named by their identifier, and a link carries it: the page's own
// address with `?connect=<identifier>` (and the name they go by), a key-log
// address `/oobi/<identifier>`, or the bare identifier. A QR a camera reads, a
// link pasted into the bar, the address the page was opened with and an
// identifier typed by hand are all read here, purely, the same way.
// a KERI identifier: one code letter, then 43 base64url characters
const AID = /^[A-Z][A-Za-z0-9_-]{43}$/;
/** Whether TEXT has the shape of a person's identifier. */
export const isAid = (text) => AID.test(text);
/** The person a text names, or null when it names no one. */
export function connectIn(read) {
    const s = String(read ?? "").trim();
    if (isAid(s))
        return { aid: s, origin: "", name: "" };
    let url;
    try {
        url = new URL(s);
    }
    catch (_) {
        return null;
    }
    if (url.protocol !== "http:" && url.protocol !== "https:")
        return null;
    const asked = url.searchParams.get("connect");
    if (asked && isAid(asked))
        return { aid: asked, origin: url.origin, name: (url.searchParams.get("name") || "").slice(0, 60) };
    const log = /\/oobi\/([^/?#]+)$/.exec(url.pathname);
    if (log && isAid(log[1]))
        return { aid: log[1], origin: url.origin, name: "" };
    return null;
}
/** The link that names AID under NAME, opening the page at BASE (its address without a query). */
export const connectLink = (base, aid, name = "") => `${base}?connect=${aid}${name ? `&name=${encodeURIComponent(name)}` : ""}`;
