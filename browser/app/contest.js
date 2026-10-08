// app/contest.ts — the counts of a stock, and the contests of them.
//
// A count is a person's word that so much is there. The record says it
// happened; a member of the scope may say it did not, through the one door work
// is contested through (docs/observation/capture.md §8), and the scope's
// franchise decides. This module reads the two replies the contest screen is
// made of — the counts of a stock and the contests open — and says each count in
// a sentence. Pure, so the capture sheet and a unit test read them the same way.
import { replyRows, finite, quantity } from "./count.js";
import { humanDate } from "./slots/model.js";
import { CONTEST_PREFIX, COUNT_PREFIX, COUNT_TECHNIQUES, COUNT_TECHNIQUE_PREFIX } from "./count-catalogue.js";
/** The counts a reply holds, newest first as sent; none when it is a refusal or unreadable. */
export function readHistory(raw) {
    return replyRows(raw).map(r => ({
        id: String(r.id ?? ""), ...(r.ballot ? { ballot: String(r.ballot) } : {}),
        counted: finite(r.counted),
        at: String(r.at ?? ""), delta: finite(r.delta) ?? 0, unit: String(r.unit ?? ""),
        counter: String(r.counter ?? ""), technique: String(r.technique ?? ""),
        evidence: String(r.evidence ?? ""), mine: r.mine === true,
    })).filter(c => c.id);
}
/** The contests a reply holds. */
export function readContests(raw) {
    return replyRows(raw).map((r) => ({
        id: String(r.id ?? ""), eventId: String(r.eventId ?? ""), kind: String(r.kind ?? ""), resource: String(r.resource ?? ""),
        worker: String(r.worker ?? ""), by: String(r.by ?? ""), reason: String(r.reason ?? ""),
        role: r.role === "attach" || r.role === "vote" ? r.role : "none",
    })).filter(c => c.id);
}
/** The contests of this person's own counts, by the stock each is of: the ones they may attach a picture to. */
export function contestedBy(entries) {
    return new Map(entries.filter(c => c.role === "attach" && c.resource).map(c => [c.resource, c]));
}
/** The ballot a count's contest is. */
export const ballotOf = (c) => c.ballot || `${CONTEST_PREFIX}${c.id}`;
/** The open contest of a count, if there is one. */
export const contestOf = (c, open) => open.find(o => o.id === ballotOf(c));
const HOW = {
    stated: "by their word", label: "off a label", photo: "from a photograph",
};
/** How a count was come by, in a word. */
export function howCounted(technique) {
    const named = COUNT_TECHNIQUES.find(t => technique === COUNT_TECHNIQUE_PREFIX + t);
    if (named)
        return HOW[named];
    return technique.startsWith(COUNT_PREFIX) ? "on a planned count" : "";
}
/** What a count found, in a sentence: "counted 8 kg, found 2 kg fewer than the ledger read, by their word". */
export function countLine(c) {
    const size = quantity(Math.abs(c.delta), c.unit);
    const how = howCounted(c.technique);
    const found = c.delta < 0 ? `found ${size} fewer than the ledger read`
        : c.delta > 0 ? `found ${size} more than the ledger read`
            : "found the ledger right";
    const said = typeof c.counted === "number" ? `counted ${quantity(c.counted, c.unit)}, ${found}` : found;
    return how ? `${said}, ${how}` : said;
}
/** The date of a count, as a face says it: the day, as a person reads one (slots/model.ts humanDate). */
export const countDay = (at) => (at ? humanDate(at.slice(0, 10)) || at.slice(0, 10) : "");
/** What leads a count's row: the figure it found where it states one, who counted, and the day. */
export function countHead(c, who) {
    return { figure: typeof c.counted === "number" ? quantity(c.counted, c.unit) : "", rest: [who, countDay(c.at)].filter(Boolean).join(" · ") };
}
/** What a count found, without the figure its row already leads with: "3 kg fewer than the ledger read, by their word". */
export function foundLine(c) {
    const size = quantity(Math.abs(c.delta), c.unit);
    const how = howCounted(c.technique);
    const found = c.delta < 0 ? `${size} fewer than the ledger read` : c.delta > 0 ? `${size} more than the ledger read` : "the ledger was right";
    return how ? `${found}, ${how}` : found;
}
/** A counter's AID, shortened for a line. */
export const shortAid = (aid) => (aid.length > 10 ? `${aid.slice(0, 6)}…` : aid);
/** An image URL for a picture held as base64 JPEG; empty for none. */
export const pictureUrl = (b64) => (b64 ? `data:image/jpeg;base64,${b64}` : "");
