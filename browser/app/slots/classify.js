// app/slots/classify.ts — the classify pass: one slot's words → folksonomy terms.
//
// The AI half of the match ring's classification affinity, on the log tab's
// suggest() shape: a deterministic floor first (the slot's spec/name matched
// against the spine's own labels — works standalone), then the gateway's AI
// asked to file the slot into the taxonomy the citizen already sees (S.root,
// the commons' cut). Gateway-only, like every AI path: no key ever lives in
// the page, and a signed-out dial simply keeps the floor.
//
// The reply is 2–4 term-ids from specific to general — the specific-to-general
// ladder that lets two cousins meet inside the affinity scorer's distance cap
// (matching/affinity.scm), exactly as the match prototype's multi-level
// expressions did. A term the taxonomy lacks may come back too (lowercase,
// hyphenated, with its nearest existing ancestor alongside): both sides of a
// future match receive the same fresh term, so it matches by identity before
// anyone has filed it — and filing it is the spine editor's republish arm.
import { S } from '../state.js';
import { HANDLERS } from '../core.js';
// the spine, flattened to "id — label" lines the prompt can quote
function termLines() {
    const lines = [];
    const walk = (n) => {
        if (n && n.id && n.id !== "all" && n !== S.root)
            lines.push(`${n.id} — ${n.name || n.id}`);
        (n?.children || []).forEach(walk);
    };
    walk(S.root);
    return lines;
}
// the floor: spine terms whose label/id already appear in the slot's words
function scanTerms(text) {
    const low = ` ${String(text).toLowerCase()} `;
    const hits = [];
    const walk = (n) => {
        if (n && n.id && n !== S.root) {
            const label = String(n.name || "").toLowerCase();
            if (label.length > 2 && low.includes(label))
                hits.push(n.id);
        }
        (n?.children || []).forEach(walk);
    };
    walk(S.root);
    return hits.slice(0, 4);
}
const CLASSIFY_PROMPT = `You classify one need or one offer for a commons' matching ring, against ` +
    `the commons' own taxonomy. Reply with EXACTLY one JSON object, no prose, ` +
    `no fences:\n{"cats":["<term-id>", "<term-id>", …]}\n` +
    `2 to 4 term-ids from the provided taxonomy, MOST SPECIFIC FIRST, then its ` +
    `broader ancestors — a match needs the ladder, not just the leaf. Use the ` +
    `ids verbatim. Only when nothing provided fits, coin ONE new lowercase ` +
    `hyphenated term for the specific thing and still include the nearest ` +
    `existing term as its general neighbour.`;
// classify KIND ("need" | "capacity") SLOT → Promise<[termId…]>; the scan
// floor always rides in the result, AI or not.
export async function classifySlot(kind, slot) {
    const text = [slot.name, slot.spec, slot.note].filter(Boolean).join(" · ");
    const floor = scanTerms(text);
    if (!HANDLERS.ai)
        return floor;
    try {
        const reply = (await HANDLERS.ai(CLASSIFY_PROMPT, `taxonomy:\n${termLines().join("\n")}\n` +
            `kind: ${kind === "need" ? "need (someone asks)" : "offer (someone provides)"}\n` +
            `slot: ${text} (${slot.qty || 1} ${slot.unit || "each"})`, "")) || "";
        const a = reply.indexOf("{"), b = reply.lastIndexOf("}");
        if (a < 0 || b <= a)
            return floor;
        const got = JSON.parse(reply.slice(a, b + 1));
        const cats = (Array.isArray(got.cats) ? got.cats : [])
            .filter((c) => typeof c === "string" && Boolean(c.trim()))
            .map((c) => c.trim())
            .slice(0, 4);
        floor.forEach(t => { if (!cats.includes(t))
            cats.push(t); }); // floor stays
        return cats;
    }
    catch (_) {
        return floor;
    }
}
