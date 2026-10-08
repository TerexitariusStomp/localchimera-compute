// app/capture-look.ts — the capture sheet's camera: shots of a scene, read into rows.
//
// The camera screen shows what the camera sees, reads the symbols in view (a
// label opens its container, a product's barcode its stock) and takes shots into
// a tray: up to SHOTS_PER_READ of one scene, read together or kept to be read
// later (queue.ts). A read goes through the gateway's vision door and the conform
// loop (conform.ts, look.ts); the model proposes, and each row lands only when a
// person has confirmed it, as a count of a thing held (technique photo, the hash
// of the picture as evidence) or as a first sighting declared as the person's own.
// With no model, or no reads left this week, the pictures are kept as the
// evidence of a count the person states.
import { HANDLERS, EXT } from "./core.js";
import { emit } from "./bus.js";
import { html } from "./template.js";
import { currentPlace } from "./tabs/social/location.js";
import { parseFigure, readReply, refused, verdict, quantity, figure, planRange, planVerdict, farOff, shortfall } from "./count.js";
import { MARK_GLYPHS } from "./signs.js";
import { armer } from "./arm.js";
import { declare, myNeeds } from "./tabs/social/share.js";
import { codeIn } from "./labels.js";
import { pickPhotos, keepShot, proofOf, previewOf, shotOf, firstTaken, SHOTS_PER_READ, readEvidence, toBase64 } from "./photo.js";
import { lookSystem, lookUser, lookCheck, rowsOf, corrected, landingOf, meansId, markOf, looksRight, zeroRow } from "./look.js";
import { conform, readFirstJSONObject } from "./conform.js";
import { lendControl, grants } from "./lend.js";
import { effect } from "./reactive.js";
import { idHint } from "./tabs/social/id.js";
import { askReads, canRead, readsLine, whyNotRead } from "./allotment.js";
import { canScan } from "./scan.js";
import { classify, formatName } from "./symbols.js";
import { boundTo } from "./barcodes.js";
import { canStream } from "./camera.js";
import { Viewfinder } from "./viewfinder.js";
import { enqueue, dequeue, listQueued, queuedLine, waiting } from "./queue.js";
import { lotDate } from "./stock.js";
import { sheet, topOf, say, settle, push, replaceTop, back, head, q, qa, host } from "./sheet.js";
import { find, fromStock, screenOf, countOf } from "./capture-stock.js";
import { close as closeSheet } from "./sheet.js";
import { propose } from "./connect.js";
import { lookTop, aiming, sceneOf, lookScreen } from "./capture-scene.js";
// the camera screen's live camera: made when the screen waits for a shot, kept
// across its redraws, and let go the moment a shot is taken or the screen is left
let viewfinder = null;
let typed = ""; // the code being typed, kept across the card's redraws
// the ids of the specs the library knows, as a photo read is told them
const specIds = () => (EXT.inventory?.specs ?? []).map(sp => String(sp.id ?? ""));
export function releaseCamera() {
    viewfinder?.stop();
    viewfinder = null;
}
function aimCamera() {
    viewfinder ??= new Viewfinder(seen, () => { const scr = lookTop(); if (scr)
        replaceTop({ ...scr }); });
    const video = q(".cap-video");
    if (video)
        void viewfinder.follow(video);
}
// SOURCE camera: the frame on show (or the device's camera app where there is no
// live camera); file: pictures the person already has
async function shoot(source) {
    const scr = lookTop(), s0 = sheet.peek();
    if (!scr || !s0 || s0.busy || scr.shots.length >= SHOTS_PER_READ)
        return;
    let blobs;
    if (source === "file")
        blobs = await pickPhotos(false, true);
    else if (viewfinder?.live) {
        const frame = await viewfinder.frame();
        if (!frame) {
            say("the camera is not showing yet");
            return;
        }
        blobs = [frame];
    }
    else
        blobs = await pickPhotos(true, false);
    if (!blobs.length || lookTop() !== scr)
        return;
    sheet.set({ ...s0, busy: true, says: "preparing…" });
    const taken = [];
    let why = "";
    for (const blob of blobs.slice(0, SHOTS_PER_READ - scr.shots.length)) {
        const shot = await keepShot(blob);
        if (typeof shot === "string")
            why = shot;
        else
            taken.push(shot);
    }
    const now = lookTop();
    if (!now || now !== scr)
        return; // the sheet moved on
    if (!taken.length) {
        settle(why);
        return;
    }
    const shots = [...scr.shots, ...taken];
    replaceTop({ ...now, shots }, why || (shots.length >= SHOTS_PER_READ ? `${shots.length} shots: the most one read takes` : `${shots.length} of ${SHOTS_PER_READ} shots`));
}
function unshot(i) {
    const scr = lookTop();
    if (!scr)
        return;
    const shots = scr.shots.filter((_, j) => j !== i);
    replaceTop({ ...scr, shots }, shots.length ? `${shots.length} of ${SHOTS_PER_READ} shots` : "");
}
// the tray kept to be read later: the camera stays up for the next scene. A queued
// scene is read from the evidence store, so the store must hold its shots.
async function later() {
    const scr = lookTop();
    if (!scr || !scr.shots.length)
        return;
    const held = await Promise.all(scr.shots.map(x => readEvidence(x.hash)));
    if (lookTop() !== scr)
        return;
    if (held.some(b => !b)) {
        say("this device cannot keep pictures for later; read them now");
        return;
    }
    const c = scr.scene.container;
    enqueue({
        at: firstTaken(scr.shots), shots: scr.shots.map(x => x.hash), place: scr.scene.place || currentPlace() || "",
        container: c?.id ?? "", plan: scr.scene.plan, label: c?.name ?? (scr.scene.where.split(" › ").pop() || "a scene"),
    });
    replaceTop({ ...scr, shots: [] }, `kept to read later · ${listQueued().length} waiting`);
}
// the shots read: the pictures as kept, one to the model or all of them, and the
// picture a count of the reading names (the shot itself, or the sheet of them)
async function readShots(scr) {
    const s0 = sheet.peek();
    if (!s0 || s0.busy || !scr.shots.length)
        return;
    sheet.set({ ...s0, busy: true, says: "preparing…" });
    const proof = await proofOf(scr.shots);
    if (typeof proof === "string") {
        settle(proof);
        return;
    }
    const { blobs } = proof;
    const reads = scr.reads ?? await askReads(HANDLERS.allotment);
    const planned = !!scr.scene.plan?.fulfills;
    const can = !!HANDLERS.see && (planned ? !!reads?.sees : canRead(reads));
    if (!can) {
        byHand(scr, proof.hash, reads);
        return;
    }
    const reading = { ...scr, phase: "reading", hash: proof.hash, reads };
    replaceTop(reading, blobs.length > 1 ? `reading ${blobs.length} pictures…` : "reading the picture…");
    sheet.set({ ...sheet.peek(), busy: true });
    let why = "";
    const ctx = { place: scr.scene.where, container: scr.scene.container?.name ?? "", held: scr.scene.held };
    const specs = specIds();
    const b64s = await Promise.all(blobs.map(toBase64));
    const rows = await conform({
        ask: async (system, user) => {
            const r = await HANDLERS.see(b64s, system, user, scr.scene.plan?.fulfills ?? "");
            if (typeof r === "string" && r.startsWith("err:")) {
                why = r.slice(4) || "refused";
                throw new Error(why);
            }
            return r;
        },
        system: lookSystem(specs), user: lookUser(ctx),
        read: readFirstJSONObject, check: lookCheck,
        accept: got => rowsOf(got, ctx, specs),
        floor: last => (last ? rowsOf(last, ctx, specs) : []),
    }).catch(() => []);
    const after = await askReads(HANDLERS.allotment) ?? reads;
    const now = lookTop();
    if (!now || now.hash !== proof.hash)
        return; // the sheet moved on
    const lines = rows.map(row => ({ row, state: "open", says: "" }));
    replaceTop({ ...now, phase: lines.length ? "rows" : "unread", lines, reads: after }, lines.length ? "" : why || "nothing in the pictures read as a thing; closer, or count by hand");
}
export async function loadQueue() {
    const reads = await askReads(HANDLERS.allotment);
    const items = await Promise.all(listQueued().map(async (entry) => {
        const first = await readEvidence(entry.shots[0]);
        return { entry, thumb: first ? await previewOf(first, 160) : "" };
    }));
    const now = topOf("queue");
    if (now)
        replaceTop({ ...now, items, loaded: true, reads }, sheet.peek()?.says ?? "");
}
function discard(id) {
    dequeue(id);
    void loadQueue();
}
// a queued scene read as it was taken: its pictures as kept, its container and plan,
// the books as they are now; its counts land with the instant of its first shot
async function readQueued(entry) {
    const s = sheet.peek();
    if (!s || s.busy)
        return;
    sheet.set({ ...s, busy: true, says: "opening…" });
    const found = entry.container ? fromStock(entry.container) : null;
    const scene = sceneOf(found?.bin, found?.contents, entry.plan, entry.place);
    const shots = [];
    for (const hash of entry.shots) {
        const blob = await readEvidence(hash);
        if (blob)
            shots.push(await shotOf(hash, blob, entry.at));
    }
    if (!shots.length) {
        dequeue(entry.id);
        await loadQueue();
        settle("those pictures are no longer on this device");
        return;
    }
    push({ ...lookScreen(scene), shots, queued: entry.id, typing: false });
    const now = lookTop();
    if (now)
        void readShots(now);
}
// a photograph the model will not read: kept as the evidence of a stated count
function byHand(scr, hash, reads) {
    const why = reads && !reads.sees ? "no vision model reads pictures here yet"
        : reads && reads.remaining <= 0 ? "this week's photo reads are spent"
            : "the picture could not be read here";
    const c = scr.scene.container;
    if (!c) {
        replaceTop({ ...scr, phase: "unread" }, `${why}; the photograph is kept. Point the camera at a label or a barcode to count what is there.`);
        return;
    }
    replaceTop({ kind: "count", done: false,
        target: { ...countOf(c, c, "stated", scr.scene.plan), evidence: hash } }, `${why}; the photograph is kept as evidence — count by hand`);
}
// the rows as the inputs now hold them: a person's typing and the mic's words
// are corrections, read back before a row changes state
function synced(scr) {
    const specs = specIds();
    return scr.lines.map((l, i) => {
        if (l.state !== "open")
            return l;
        const name = q(`.cap-rname[data-i="${i}"]`)?.value;
        const qty = parseFigure(q(`.cap-qty[data-i="${i}"]`)?.value ?? "");
        const unit = q(`.cap-runit[data-i="${i}"]`)?.value;
        return { ...l, row: corrected(l.row, { name, qty: qty ?? undefined, unit }, scr.scene.held, specs) };
    });
}
function setLine(scr, lines, i, patch, says = "") {
    const next = lines.map((l, j) => (j === i ? { ...l, ...patch } : l));
    const allDone = next.every(l => l.state !== "open");
    replaceTop({ ...scr, lines: next }, says || (allDone ? "every row is settled" : ""));
}
/** Land row I through its door; whether it landed. */
async function land(i) {
    const scr = lookTop(), s = sheet.peek();
    if (!scr || !s || s.busy)
        return false;
    const lines = synced(scr), line = lines[i];
    if (!line || line.state !== "open")
        return false;
    const l = landingOf(line.row), where = scr.scene.place || currentPlace() || "";
    sheet.set({ ...s, busy: true, says: "landing…" });
    const stale = () => lookTop() !== scr;
    if (l.door === "count") {
        if (!HANDLERS.countStock) {
            setLine(scr, lines, i, {}, "sign in to count");
            return false;
        }
        const planned = scr.scene.plan && scr.scene.container?.id === l.resource ? scr.scene.plan.fulfills : "";
        const r = readReply(await HANDLERS.countStock(l.resource, l.qty, l.unit, "photo", where, firstTaken(scr.shots), planned, scr.hash, "").catch(() => ""));
        if (stale())
            return false;
        if (refused(r)) {
            setLine(scr, lines, i, {}, r.err || "the gateway did not answer");
            return false;
        }
        // the ledger's word, and the plan's where a flow of it bears on the stock
        const plan = r.expected ? ` · ${planVerdict(l.qty, r.expected, l.unit)}` : "";
        setLine(scr, lines, i, { state: "landed", says: verdict(r, l.unit) + plan });
        emit("counted", l.resource);
        return true;
    }
    if (!HANDLERS.declareMeans) {
        setLine(scr, lines, i, {}, "sign in to declare it");
        return false;
    }
    const reply = await HANDLERS.declareMeans(l.spec, l.qty, l.unit, where, "", l.note, "", l.name, "", "").catch(() => "err:the gateway did not answer");
    if (stale())
        return false;
    if (reply !== "ok") {
        setLine(scr, lines, i, {}, String(reply).replace(/^err:/, "") || "the declaration did not go through");
        return false;
    }
    const aid = (idHint() || {}).aid;
    setLine(scr, lines, i, { state: "landed", says: `declared as yours: ${l.name}, ${quantity(l.qty, l.unit)}`, rid: aid ? meansId(aid, l.spec) : undefined });
    return true;
}
function strike(i) {
    const scr = lookTop();
    if (!scr)
        return;
    const lines = synced(scr);
    setLine(scr, lines, i, { state: "struck", says: "" });
}
// ── the walk-up count: what looks right lands in one tap ─────────────────────
// A row whose figure is the ledger's, or inside what the plan expects, is landed
// with its like by one button; a row under or over, and a first sighting, each
// wait for a tap of their own. A figure far from what is held lands on a second
// tap, and so does leaving rows unsettled. A blind count shows no mark and lands
// row by row, since its marks would say what the ledger reads.
const twice = armer();
// the armed act shows on its own button: the card is drawn again as it arms and as it lapses
effect(() => { twice.armed(); resync(); });
/** The rows one tap lands: open, and looking right. None for a blind count. */
const rightRows = (scr, lines) => scr.scene.plan?.blind ? [] : lines.flatMap((l, i) => (l.state === "open" && looksRight(l.row) ? [i] : []));
async function landAll() {
    const scr = lookTop();
    if (!scr)
        return;
    // each landing redraws the card; a row keeps its index, so the list read once stands
    for (const i of rightRows(scr, synced(scr)))
        if (!(await land(i)))
            return;
}
/** The row's own tap: at once, or asked twice when its figure is far from what is held. */
function landOne(i) {
    const scr = lookTop();
    const row = scr && synced(scr)[i]?.row;
    if (!scr || !row)
        return;
    if (row.match && !scr.scene.plan?.blind && farOff(row.qty, row.match))
        twice.arm(`far:${i}`, () => { void land(i); });
    else
        void land(i);
}
/** The typed figures, read back onto the rows, so each mark follows its figure. */
function resync() {
    const scr = lookTop(), s = sheet.peek();
    if (scr && s && !s.busy)
        replaceTop({ ...scr, lines: synced(scr) }, s.says);
}
// "we need more": the person asks for what the shelf is short of, on top of what
// they already asked for (a need is declared whole, so the sum is stated)
function needMore(i) {
    const scr = lookTop();
    if (!scr)
        return;
    const lines = synced(scr), line = lines[i], m = line?.row.match;
    if (!line || !m)
        return;
    const more = shortfall(line.row.qty, m);
    if (more <= 0)
        return;
    const had = myNeeds().find(n => n.spec === m.spec)?.qty ?? 0;
    declare("need", { id: null, spec: m.spec, name: m.name, emoji: "", note: "", qty: had + more, unit: m.unit || "each",
        where: scr.scene.place || currentPlace() || "", arcs: [] });
    setLine(scr, lines, i, { asked: more }, `asked for ${quantity(more, m.unit)} more ${m.name}`);
}
/** A thing held of which the picture shows none: its row, a count of nothing, joins the rows. */
function addZero(h) {
    const scr = lookTop();
    if (!scr)
        return;
    const lines = scr.phase === "rows" ? synced(scr) : [];
    replaceTop({ ...scr, phase: "rows", lines: [...lines, { row: zeroRow(h, specIds()), state: "open", says: "" }] });
}
// a first sighting declared as one's own carries its lend right on its row: the
// one lend control (app/lend.ts) over the thing just declared, the resource
// named so the title gate engages. The row holds a slot for it; the control is
// mounted when the card is shown and again when a grant lands or ends.
const declared = (row) => {
    const l = landingOf(row);
    return l.door === "declare" ? l : { spec: "", name: row.name, unit: row.unit, qty: Number(row.qty) || 1 };
};
function mountLends() {
    for (const slot of qa(".cap-lend")) {
        const d = slot.dataset;
        slot.replaceChildren(lendControl({ spec: d.spec || "", name: d.name || "", unit: d.unit || "",
            qty: Number(d.qty) || 1, resource: d.rid || "" }));
    }
}
effect(() => { grants(); mountLends(); });
// the box the mic's figure lands in: the quantity of the row last touched
let qtyBox = null;
// a symbol the camera read: a label opens its container, a product's barcode
// opens the stock it was paired with (or asks which stock it is), anything else
// is reported and left alone
function seen(sym) {
    const s = sheet.peek(), scr = lookTop();
    if (!s || s.busy || !aiming(scr))
        return;
    const r = classify(sym);
    if (r.kind === "label") {
        find(r.code);
        return;
    }
    // a person's link: the sheet closes and Contacts opens on their card
    if (r.kind === "person") {
        closeSheet();
        propose(r.link);
        return;
    }
    if (r.kind === "product") {
        const rid = boundTo(r.value), found = rid ? fromStock(rid) : null;
        if (found)
            replaceTop(screenOf(found, "label"));
        else
            push({ kind: "product", seen: { format: r.format, value: r.value } });
        return;
    }
    say(`read ${formatName(r.format)} “${r.value.slice(0, 60)}”: not a playnet label or a product code`);
}
// …and while the camera waits for a shot
const LOOK_PROMPT = canScan() ? "hold a label or a barcode in view, or take a photograph" : "take a photograph, or type a code";
export const resetTyped = () => { typed = ""; };
/** Keep the code being typed, as the mic heard it. */
export const setTyped = (v) => { typed = v; };
/** The row quantity box last touched, while it is on the card. */
export const focusedQty = () => (qtyBox && host.el?.contains(qtyBox) ? qtyBox : null);
/** The queue on top of the camera, from the chip that says how many wait. */
function openQueueHere() {
    push(queueScreen());
    void loadQueue();
}
/** A screen of the scenes waiting to be read, to be loaded (loadQueue). */
export const queueScreen = () => ({ kind: "queue", items: [], loaded: false, reads: null });
function renderLook(scr, deep) {
    const { scene, phase, lines } = scr;
    const aimed = aiming(scr);
    const again = () => { const now = lookTop(); if (now)
        replaceTop({ ...now, phase: "idle", hash: "", lines: [], shots: [] }); };
    const finish = () => { if (scr.queued)
        dequeue(scr.queued); back(); if (topOf("queue"))
        void loadQueue(); };
    const readTray = () => { const now = lookTop(); if (now)
        void readShots(now); };
    const full = scr.shots.length >= SHOTS_PER_READ;
    const typing = () => { const now = lookTop(); if (now)
        replaceTop({ ...now, typing: !now.typing }); };
    const sub = [scene.container?.name ?? "", scene.where].filter(Boolean).join(" · ");
    const known = (r) => {
        const m = r.match;
        if (!m)
            return "a first sighting: not on the ledger yet";
        const ledger = scene.plan?.blind ? "" : `, the ledger reads ${quantity(m.onhand, m.unit)}`;
        const plan = !scene.plan?.blind && m.expected ? ` · the plan expects ${planRange(m.expected, m.unit)}` : "";
        const unit = r.unitDiffers ? ` · the ledger holds it in ${m.unit}` : "";
        return `counts ${m.name}${ledger}${plan}${unit}`;
    };
    const blind = !!scene.plan?.blind;
    const mark = (r) => {
        if (blind)
            return "";
        const k = markOf(r), [glyph, word] = MARK_GLYPHS[k];
        return html `<span class="cap-mark m-${k}" title="${word}" aria-label="${word}">${glyph}</span>`;
    };
    // the things held here that no row counts: a tap adds a count of nothing
    const counted = new Set(lines.flatMap(l => (l.row.match ? [l.row.match.id] : [])));
    const absent = blind || !scene.here || !(phase === "rows" || phase === "unread") ? [] : scene.held.filter(h => !counted.has(h.id)).slice(0, 12);
    const right = phase === "rows" ? rightRows(scr, lines) : [];
    const open = lines.filter(l => l.state === "open").length;
    const armed = twice.armed();
    const dated = (r) => [r.lot ? `lot ${r.lot}` : "", r.expires ? lotDate(r.expires, r.expiresKind) : ""].filter(Boolean).map(x => ` · ${x}`).join("");
    const row = (l, i) => {
        if (l.state === "struck")
            return html `<li class="cap-look struck"><span class="cap-lname">${l.row.name}</span><span class="cap-lsub">struck</span></li>`;
        if (l.state === "landed")
            return html `
        <li class="cap-look done"><div class="cap-lname">✓ ${l.row.name}</div><div class="cap-lsub">${l.says}</div>
          ${l.rid ? html `<div class="cap-lend" data-rid="${l.rid}" data-spec="${declared(l.row).spec}" data-name="${declared(l.row).name}" data-unit="${declared(l.row).unit}" data-qty="${String(declared(l.row).qty)}"></div>` : ""}
        </li>`;
        return html `
        <li class="cap-look">
          <div class="cap-rtop">${mark(l.row)}<input class="cap-rname" data-i="${i}" value="${l.row.name}" aria-label="what it is" onchange=${resync}><input class="cap-qty" data-i="${i}" inputmode="decimal" value="${String(l.row.qty)}" aria-label="how many" onfocus=${(e) => { qtyBox = e.target; }} onchange=${resync}><input class="cap-runit" data-i="${i}" value="${l.row.unit}" aria-label="unit" onchange=${resync}></div>
          <div class="cap-lsub">${known(l.row)}${dated(l.row)}${l.asked ? ` · asked for ${quantity(l.asked, l.row.unit)} more` : ""}</div>
          <div class="cap-tools"><button class="cap-mini${armed === `far:${i}` ? " armed" : ""}" onclick=${() => landOne(i)}>${armed === `far:${i}` && l.row.match ? `really ${figure(l.row.qty)}? the ledger reads ${figure(l.row.match.onhand)}` : l.row.match ? "count it" : "declare it"}</button>${!blind && l.row.match && !l.asked && markOf(l.row) === "under" ? html `<button class="cap-mini cap-more" title="ask for what the shelf is short of" onclick=${() => needMore(i)}>we need more</button>` : ""}<button class="cap-mini" onclick=${() => strike(i)}>strike</button></div>
        </li>`;
    };
    return html `
      <div class="cap-card" role="dialog" aria-modal="true" aria-label="${aimed ? "camera" : "read a photograph"}">
        ${head("📷", aimed ? "camera" : "read a photograph", deep)}
        <div class="cap-sub">${sub}</div>
        <div class="cap-sub cap-reads">${readsLine(scr.reads)}</div>
        ${phase === "rows" && lines.length ? html `<div class="cap-sub cap-ai-note">an AI's reading, proposed from the photo — check each row before you confirm it. It can misname what it sees, including a food or a plant: never eat or use anything because it named it.</div>` : ""}
        ${aimed && !blind && scene.here && scene.held.length ? html `<div class="cap-held" aria-label="held here">${scene.held.slice(0, 8).map(h => html `<span class="cap-chip">${h.name}</span>`)}${scene.held.length > 8 ? html `<span class="cap-chip more">+${scene.held.length - 8}</span>` : ""}</div>` : ""}
        ${phase === "rows" ? html `<ul class="cap-lines cap-looks">${lines.map(row)}</ul>` : ""}
        ${absent.length ? html `<div class="cap-held cap-absent"><span class="cap-held-lbl">none of these in the picture?</span>${absent.map(h => html `<button class="cap-chip" title="count none of it" onclick=${() => addZero(h)}>${h.name} · 0</button>`)}</div>` : ""}
        ${aimed && canStream() && !viewfinder?.note ? html `<video class="cap-video" muted playsinline></video>` : ""}
        ${(phase === "reading" || phase === "unread") && scr.shots.length ? html `<div class="cap-stills n${scr.shots.length}">${scr.shots.map((x, i) => html `<img class="cap-still" alt="shot ${i + 1}" src="${x.preview}">`)}</div>` : ""}
        ${aimed && viewfinder?.note ? html `<div class="cap-sub cap-cam">${viewfinder.note}</div>` : ""}
        ${aimed && scr.shots.length ? html `<div class="cap-tray">${scr.shots.map((x, i) => html `<span class="cap-shot"><img src="${x.preview}" alt="shot ${i + 1}"><button class="cap-unshot" title="remove this shot" aria-label="remove shot ${i + 1}" onclick=${() => unshot(i)}>✕</button></span>`)}<span class="cap-count">${scr.shots.length} of ${SHOTS_PER_READ}</span></div>` : ""}
        <div class="cap-says"></div>
        ${aimed ? html `
          <div class="cap-shoot">
            <button class="cap-mini cap-pick" data-off="${full ? "1" : ""}" onclick=${() => { void shoot("file"); }}>🖼 a photo you have</button>
            <button class="cap-go cap-shutter" data-off="${full ? "1" : ""}" onclick=${() => { void shoot("camera"); }} aria-label="take a photograph"><span class="cap-sr">take a photograph</span></button>
            <button class="cap-mini cap-type" onclick=${typing}>⌨ type a code</button>
          </div>
          ${scr.shots.length ? html `<div class="cap-acts"><button class="cap-mini cap-later" onclick=${() => { void later(); }}>read later</button><button class="cap-go cap-read" onclick=${readTray}>read ${scr.shots.length === 1 ? "the photo" : `${scr.shots.length} photos`}</button></div>` : ""}
          ${waiting() ? html `<button class="cap-mini cap-queued" onclick=${openQueueHere}>📥 ${waiting()} waiting to be read</button>` : ""}
          ${scr.typing ? html `<div class="cap-row"><input class="cap-code" autocapitalize="characters" autocomplete="off" spellcheck="false"
                 placeholder="the code beneath the symbol" value="${typed}"
                 oninput=${(e) => { typed = e.target.value; if (sheet.peek()?.says)
        say(""); }}
                 onkeydown=${(e) => { if (e.key === "Enter")
        find(codeIn(typed)); }}><button class="cap-mini cap-find" onclick=${() => find(codeIn(typed))}>find it</button></div>` : ""}` : ""}
        ${phase === "unread" ? html `<div class="cap-shoot"><span></span><button class="cap-go" onclick=${again}>take another</button><span></span></div>` : ""}
        ${phase === "rows" ? html `<div class="cap-acts cap-end">${right.length ? html `<button class="cap-all" onclick=${() => { void landAll(); }}>looks right · count ${right.length}</button>` : html `<span></span>`}<button class="cap-go${armed === "finish" ? " armed" : ""}" onclick=${() => { if (open)
        twice.arm("finish", finish);
    else
        finish(); }}>${armed === "finish" ? `leave ${open} unsettled?` : "done"}</button></div>` : ""}
      </div>`;
}
function renderQueue(scr, deep) {
    return html `
      <div class="cap-card" role="dialog" aria-modal="true" aria-label="photographs waiting">
        ${head("📥", "waiting to be read", deep)}
        <div class="cap-sub">${scr.loaded ? readsLine(scr.reads) : "looking…"}</div>
        ${scr.items.length ? html `<ul class="cap-lines cap-queue">${scr.items.map(({ entry, thumb }) => {
        const reason = whyNotRead(scr.reads, !!entry.plan?.fulfills);
        return html `<li>${thumb ? html `<img class="cap-qthumb" src="${thumb}" alt="">` : ""}<div class="cap-line"><span class="cap-lname">${queuedLine(entry)}</span><span class="cap-lsub">${reason || (entry.plan ? "a planned count" : "")}</span></div><button class="cap-mini cap-qread" data-off="${reason ? "1" : ""}" title="${reason}" onclick=${() => { void readQueued(entry); }}>read</button><button class="cap-mini cap-qdrop" onclick=${() => discard(entry.id)}>discard</button></li>`;
    })}</ul>` : scr.loaded ? html `<div class="cap-sub">nothing is waiting</div>` : ""}
        <div class="cap-says"></div>
      </div>`;
}
export const lookKind = {
    render: renderLook,
    shown: scr => {
        queueMicrotask(mountLends);
        if (!aiming(scr))
            return;
        queueMicrotask(aimCamera);
        if (scr.typing)
            queueMicrotask(() => q(".cap-code")?.focus());
    },
    prompt: scr => (aiming(scr) ? LOOK_PROMPT : ""),
    ready: (_scr, busy) => { for (const i of qa(".cap-look input"))
        i.disabled = busy; },
};
export const queueKind = { render: renderQueue };
