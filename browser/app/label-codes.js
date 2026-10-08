// app/label-codes.ts — every thing on a print is known by a code.
//
// A label sheet, name cards and a checklist print a code for each thing; a
// thing that has none is given one on the way (session/label-stock), and the
// gateway answers the same code on every later asking. The codes learned here
// are kept by id, so a second print of the same shelf asks nothing.
import { HANDLERS } from "./core.js";
import { parseReply, refused } from "./count.js";
const known = new Map();
/**
 * THINGS with their codes, in order: a thing that carries one keeps it, one the
 * gateway has coded takes it, and a thing the gateway cannot code (signed out,
 * not the signer's to label) is left off.
 */
export async function withCodes(things) {
    const out = [];
    for (const t of things) {
        if (!t.id)
            continue;
        if (t.code)
            known.set(t.id, t.code);
        let code = known.get(t.id) ?? "";
        if (!code && HANDLERS.labelStock) {
            const r = parseReply(await HANDLERS.labelStock(t.id).catch(() => ""));
            code = refused(r) ? "" : String(r.code ?? "");
            if (code)
                known.set(t.id, code);
        }
        if (code)
            out.push({ ...t, code });
    }
    return out;
}
