// app/capture-contest.ts — the capture sheet's counts of a stock, and the contests of them.
//
// A count a member doubts is contested through the one door work is contested
// through (docs/observation/capture.md §8); the counter whose count it was
// attaches the photograph it names, and the franchise sees it.
import { HANDLERS } from "./core.js";
import { html } from "./template.js";
import { readEvidence, toBase64 } from "./photo.js";
import { refreshContests } from "./contests.js";
import { readHistory, ballotOf, contestOf, countHead, foundLine, shortAid, pictureUrl } from "./contest.js";
import { sheet, topOf, say, settle, replaceTop, back, head, q } from "./sheet.js";
const contestTop = () => topOf("contest");
export async function loadContests() {
    const scr = contestTop();
    if (!scr)
        return;
    const [counts, open] = await Promise.all([
        Promise.resolve(HANDLERS.countHistory?.(scr.stock.id, 5)).then(readHistory).catch(() => []),
        refreshContests(),
    ]);
    const now = contestTop();
    if (!now || now.stock.id !== scr.stock.id)
        return;
    replaceTop({ ...now, loaded: true, counts, open }, sheet.peek()?.says ?? "");
}
const reloaded = async (says) => {
    await loadContests();
    say(says);
};
function ask(c) {
    const scr = contestTop();
    if (scr)
        replaceTop({ ...scr, asking: scr.asking === c.id ? "" : c.id, picture: null });
}
async function contestIt(c) {
    const scr = contestTop(), s = sheet.peek();
    if (!scr || !s || s.busy)
        return;
    if (!HANDLERS.contestWork) {
        say("sign in to contest a count");
        return;
    }
    const reason = (q(".cap-reason")?.value ?? "").trim();
    sheet.set({ ...s, busy: true, says: "opening the contest…" });
    // the door answers the ballot's id, or "err:…" in the gateway's words
    const r = String(await HANDLERS.contestWork("", c.id, reason).catch(() => "err:the gateway did not answer"));
    if (contestTop()?.stock.id !== scr.stock.id)
        return;
    if (r.startsWith("err:")) {
        settle(r.slice(4) || "the contest did not open");
        return;
    }
    const now = contestTop();
    replaceTop({ ...now, asking: "" });
    await reloaded("contested: the scope's members vote on it");
}
async function attach(c) {
    const scr = contestTop(), s = sheet.peek();
    if (!scr || !s || s.busy)
        return;
    if (!HANDLERS.attachEvidence) {
        say("sign in to attach a photograph");
        return;
    }
    sheet.set({ ...s, busy: true, says: "attaching…" });
    const blob = await readEvidence(c.evidence);
    if (!blob) {
        settle("that photograph is not on this device");
        return;
    }
    const r = await HANDLERS.attachEvidence(ballotOf(c), c.evidence, await toBase64(blob)).catch(() => "err:the gateway did not answer");
    settle(r === "ok" ? "your photograph is attached: the franchise sees it with the question" : String(r).replace(/^err:/, ""));
}
async function seePicture(c) {
    const scr = contestTop(), s = sheet.peek();
    if (!scr || !s || s.busy)
        return;
    if (!HANDLERS.contestEvidence) {
        say("sign in to see the photograph");
        return;
    }
    sheet.set({ ...s, busy: true, says: "fetching the photograph…" });
    const b64 = await HANDLERS.contestEvidence(ballotOf(c)).catch(() => "");
    const now = contestTop();
    if (!now)
        return;
    replaceTop({ ...now, picture: b64 ? { ballot: ballotOf(c), url: pictureUrl(b64) } : null }, b64 ? "" : "no photograph is attached to this contest yet");
}
function renderContest(scr, deep) {
    const row = (c) => {
        const k = contestOf(c, scr.open);
        const lead = countHead(c, c.mine ? "you" : shortAid(c.counter));
        const sub = `${foundLine(c)}${c.evidence ? " · with a photograph" : ""}${k ? ` · contested${k.reason ? `: ${k.reason}` : ""} — vote in the forum` : ""}`;
        const tools = [
            !k && !c.mine ? html `<button class="cap-mini" onclick=${() => ask(c)}>${scr.asking === c.id ? "never mind" : "contest"}</button>` : "",
            k && k.role === "attach" && c.evidence ? html `<button class="cap-mini" onclick=${() => { void attach(c); }}>attach my photograph</button>` : "",
            k && c.evidence ? html `<button class="cap-mini" onclick=${() => { void seePicture(c); }}>see the photograph</button>` : "",
        ];
        return html `
        <li class="cap-hist"><div class="cap-line"><span class="cap-lname">${lead.figure ? html `<b>${lead.figure}</b> · ` : ""}${lead.rest}</span><span class="cap-lsub">${sub}</span>${scr.asking === c.id ? html `<input class="cap-reason cap-note" placeholder="why do you say it was not done?"><button class="cap-mini" onclick=${() => { void contestIt(c); }}>open the contest</button>` : ""}</div><div class="cap-tools">${tools}</div></li>`;
    };
    return html `
      <div class="cap-card" role="dialog" aria-modal="true" aria-label="the counts of ${scr.stock.name}">
        ${head("✋", `the counts of ${scr.stock.name}`, deep)}
        ${scr.picture ? html `<img class="cap-picture" src="${scr.picture.url}" alt="the photograph attached to the contest">` : ""}
        ${scr.loaded ? (scr.counts.length ? html `<ul class="cap-lines cap-counts">${scr.counts.map(row)}</ul>` : html `<div class="cap-sub">this stock has no count on the ledger yet</div>`) : html `<div class="cap-sub">reading the counts…</div>`}
        <div class="cap-says"></div>
        <button class="cap-go" onclick=${back}>done</button>
      </div>`;
}
export const contestScreen = { render: renderContest };
