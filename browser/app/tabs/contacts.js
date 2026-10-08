// app/tabs/contacts.ts — the Contacts view: one row per person, and the row is
// the relationship.
//
// A row says who the person is, whether they are here, whether they are a
// recognised person, the kind you know them as, and what the two of you have
// signed about each other. Opened, it holds how to reach them (the card they
// gave you) and every act between you: the kind you tag them with, your vouch
// and its withdrawal, your signature on their ask to be recognised, an
// introduction, an invitation, your own card for them, a place among your
// recovery friends, and forgetting them.
//
// The book and what stands in it come from contact-book.ts (the spine's
// contacts push, or the demo book while no seat is taken). A tag is the
// person's own label; a vouch is its own deliberate tap.
import { HANDLERS, hint } from '../core.js';
import { ev_viewedDoy } from '../events.js';
import { eventRing } from '../day/mytime.js';
import { paleCol } from '../geom.js';
import { dateOf } from '../timefmt.js';
import { signal, effect } from '../reactive.js';
import { html, list, raw, render } from '../template.js';
import { STATUS } from '../palette.js';
import { gateHint } from '../day/respond.js';
import { book, bookIsDemo, kindOf, setRel, invite, recoveryPicks, toggleRecoveryPick } from '../contact-book.js';
import { REL_KINDS, DEFAULT_REL } from '../rel-catalogue.js';
import { recognised, rereadStanding } from './social/id.js';
import { proposal, accept, decline, myLink } from '../connect.js';
import { canScan } from '../scan.js';
import { openCaptureLook } from '../capture.js';
import { armer } from '../arm.js';
import { reach, kindOfReach, linkOf, cardText, readCard } from '../reach.js';
import { openSettings } from '../settings.js';
import { idHint } from './social/id.js';
// ── the view's own state ────────────────────────────────────────────────────
const contactFilter = signal("all");
/** The AID of the one open row. */
const openRow = signal(null);
/** The two-tap acts: "<aid>|withdraw", "<aid>|uncard", "<aid>|forget". */
const { armed, arm } = armer();
/** The AID whose card is being put together, and the points left off it. */
const carding = signal(null);
const leftOff = signal(new Set());
const pointKey = (p) => `${p.kind}|${p.value}`;
// the panel's own mounts, set once when the panel is built
let connectEl = null;
let filtersEl = null;
let rowsEl = null;
let detailEl = null;
let demoEl = null;
// the bar's typed words (share.ts's F.query), handed in by contactsPanel
let typed = () => "";
const standingOf = (c) => c.mine && c.theirs ? "mutual" : c.mine ? "mine" : c.theirs ? "theirs" : "none";
/** The row's one line: their ask while it is open, else what is signed. */
function lineOf(c) {
    if (c.ask)
        return `asking to be recognised · ${c.ask.count} of ${c.ask.quorum}`;
    switch (standingOf(c)) {
        case "mutual": return "you vouch for each other";
        case "mine": return "you vouch for them";
        case "theirs": return "vouches for you";
        default: return "";
    }
}
const as = (kind) => kind === "commons" || kind === "family" ? `as ${kind}` : `as ${/^[aeiou]/.test(kind) ? "an" : "a"} ${kind}`;
/** The open row's sentences: the tag, then each signature that stands. */
function storyOf(c) {
    const told = [`You know ${c.alias || "them"} ${as(c.rel || DEFAULT_REL)}.`];
    if (c.mine)
        told.push(`You vouch for them ${as(c.mine)}.`);
    if (c.theirs)
        told.push(`They vouch for you ${as(c.theirs)}.`);
    if (!c.mine && !c.theirs)
        told.push("Nothing is signed between you.");
    return told.join(" ");
}
// ── the acts ────────────────────────────────────────────────────────────────
// every act answers "ok" (or "ok:…") or "err:…"; the spine reads the book
// again after each, so the row redraws from what the gateway now holds
const offline = () => Promise.resolve("err:offline");
function demoSays() {
    if (!bookIsDemo())
        return false;
    hint("a demo book — sign in and these are yours to do.", "notice");
    return true;
}
function report(r, done) {
    const s = String(r ?? "err:offline");
    if (gateHint(s))
        return;
    // the commune is the judge of who may vouch; its refusal is said as the way forward
    if (/recognised person to vouch/.test(s)) {
        hint("once you are recognised you can vouch — tap your name (top-right) to request recognition.", "warn");
        return;
    }
    const ok = s === "ok" || s.startsWith("ok:");
    hint(ok ? done : s.replace(/^err:/, ""), ok ? "success" : "error");
}
function vouch(c) {
    if (demoSays())
        return;
    const kind = c.rel || DEFAULT_REL;
    (HANDLERS.fpVouch ? HANDLERS.fpVouch(c.aid, kind) : offline())
        .then(r => report(r, `you vouch for ${c.alias || "them"} ${as(kind)}`));
}
const withdraw = (c) => HANDLERS.fpWithdrawVouch ? HANDLERS.fpWithdrawVouch(c.aid) : offline();
function witness(c) {
    if (demoSays() || !c.ask)
        return;
    (HANDLERS.witnessAttest ? HANDLERS.witnessAttest(c.ask.said) : offline())
        .then(r => report(r, r === "ok:finalized" ? `${c.alias || "they"} — recognised` : "signed — you have met them"));
}
function introduce(c) {
    if (demoSays())
        return;
    (HANDLERS.fpOpenCeremony ? HANDLERS.fpOpenCeremony(c.aid) : offline())
        .then(r => {
        report(r, `${c.alias || "their"} ask is open — recognised people can sign it`);
        HANDLERS.contactsRefresh?.();
    });
}
// invite a contact to the currently-selected OWN event. The event's date is the
// viewed day; t0/t1 are hours into it.
function inviteToSelected(c) {
    const ev = eventRing.items().find(x => x.id === eventRing.selId());
    if (!ev) {
        hint("select one of your own events first, then invite", "warn");
        return;
    }
    if (demoSays())
        return;
    // ev_viewedDoy() answers null if the turn anchor cannot be read; 0 is Jan 1.
    const at = (hr) => new Date(dateOf(ev_viewedDoy() ?? 0).getTime() + hr * 3600000);
    invite(c, ev.title || "event", at(ev.t0), at(ev.t1));
}
// your card for them: the points left on, under the name you go by, sealed to
// them by the spine and kept by the commune as ciphertext
function giveCard(c) {
    if (demoSays())
        return;
    const points = reach().filter(p => !leftOff.peek().has(pointKey(p)));
    if (!points.length) {
        hint("a card says at least one way to reach you", "warn");
        return;
    }
    (HANDLERS.cardGive ? HANDLERS.cardGive(c.aid, cardText({ name: idHint()?.name || "", points })) : offline())
        .then(r => {
        if (r === "ok")
            carding.set(null);
        report(r, `${c.alias || "they"} now ${c.given ? "hold your new card" : "hold your card"}`);
    });
}
const uncard = (c) => HANDLERS.cardWithdraw ? HANDLERS.cardWithdraw(c.aid) : offline();
// forgetting takes the person out of the book, and with them a vouch and a
// card of yours: what you can no longer see is what you can no longer take back
function forget(c) {
    if (demoSays())
        return;
    const gone = () => {
        (HANDLERS.contactForget ? HANDLERS.contactForget(c.aid) : offline())
            .then(r => { if (r === "ok")
            openRow.set(null); report(r, `${c.alias || "they"} left your contacts`); });
    };
    Promise.all([c.mine ? withdraw(c) : null, c.given ? uncard(c) : null]).then(gone);
}
// ── the row ─────────────────────────────────────────────────────────────────
const act = (label, title, fn, cls = "") => html `<button type="button" class="slot-btn${cls}" title="${title}" onclick=${fn}>${label}</button>`;
// how to reach them: the card they gave, each point a link where its kind has one.
// A card is its giver's words, so every field lands in the page escaped.
function theirCard(c) {
    if (c.card === undefined)
        return "";
    const card = readCard(c.card);
    if (!card)
        return html `<p class="crow-reach-none">they gave you a card this device cannot open — it opens where you signed in with your passcode.</p>`;
    return html `
    <div class="crow-reach" role="group" aria-label="how to reach them">
      <div class="crow-reach-h">how to reach ${card.name || c.alias || "them"}</div>
      ${card.points.map(p => {
        const link = linkOf(p);
        return html `<div class="crow-point"><span class="reach-kind">${kindOfReach(p.kind)?.label || p.kind}</span>
            ${link ? html `<a href="${link}" target="_blank" rel="noopener noreferrer">${p.value}</a>`
            : html `<span>${p.value}</span>`}</div>`;
    })}
    </div>`;
}
// your card for them, put together: every point on your list, each to leave on or off
function cardPicker(c) {
    const points = reach();
    if (!points.length)
        return html `<div class="crow-card">
      <p class="crow-story">Your list of ways to be reached is empty. A card is a selection of it.</p>
      <div class="crow-acts">
        ${act("add ways to reach you → settings", "your addresses, handles and numbers, kept on this device", () => openSettings("reach"))}
        ${act("not now", "put this down", () => carding.set(null))}
      </div></div>`;
    const off = leftOff();
    return html `<div class="crow-card" role="group" aria-label="your card for them">
      <p class="crow-story">Your card for ${c.alias || "them"}: only they can read it. Leave on what they should have.</p>
      <div class="crow-points">
        ${points.map(p => {
        const key = pointKey(p), on = !off.has(key);
        return html `<label class="crow-pick"><input type="checkbox" ${on ? "checked" : ""}
                onchange=${() => { const next = new Set(leftOff.peek()); if (!next.delete(key))
            next.add(key); leftOff.set(next); }}>
              <span class="reach-kind">${kindOfReach(p.kind)?.label || p.kind}</span><span>${p.value}</span></label>`;
    })}
      </div>
      <div class="crow-acts">
        ${act(c.given ? "give this card in place of the last" : "give this card", "seal it to them and sign it", () => giveCard(c), " on")}
        ${act("not now", "put this down", () => carding.set(null))}
      </div></div>`;
}
function bodyOf(c) {
    const kind = c.rel || DEFAULT_REL;
    const listed = REL_KINDS.map(k => k.id);
    const kinds = listed.includes(kind) ? listed : [...listed, kind];
    const me = bookIsDemo() || recognised() === true;
    const wKey = `${c.aid}|withdraw`, fKey = `${c.aid}|forget`, uKey = `${c.aid}|uncard`;
    const picked = recoveryPicks().has(c.aid);
    return html `
    <div class="crow-body">
      <p class="crow-story">${storyOf(c)}</p>
      ${theirCard(c)}
      <div class="sl-people crow-kinds" role="group" aria-label="the kind you know them as">
        ${kinds.map(k => html `<a class="sl-chip${k === kind ? " on" : ""}" title="know them ${as(k)} — your own label"
                                 onclick=${() => setRel(c, k)}>${k}</a>`)}
      </div>
      <div class="crow-acts">
        ${c.mine && c.mine === kind ? "" : act(c.mine ? `✍ vouch ${as(kind)} instead` : `✍ vouch ${as(kind)}`, "sign that you know this person — your own signature, yours to withdraw", () => vouch(c))}
        ${c.mine ? act(armed() === wKey ? "withdraw?" : `✓ vouched ${as(c.mine)} · withdraw`, "end your vouch — tap twice", () => arm(wKey, () => { if (!demoSays())
        withdraw(c).then(r => report(r, "your vouch is withdrawn")); }), armed() === wKey ? " arm" : " on") : ""}
        ${c.ask ? (c.ask.signed
        ? html `<span class="crow-done">✓ you signed their ask</span>`
        : act("✍ witness", "sign that you have met this person — your signature becomes an edge on their personhood credential", () => witness(c))) : ""}
        ${!c.recognised && !c.ask && me
        ? act("🌱 introduce", "open their ask to be recognised, with you as the one who introduces them", () => introduce(c)) : ""}
        ${act("✉ invite", "invite to your selected event", () => inviteToSelected(c))}
        ${act(c.given ? "📇 your card · change" : "📇 share my card", "how to reach you, for them alone: sealed to them, yours to change or take back", () => { leftOff.set(new Set()); carding.set(carding.peek() === c.aid ? null : c.aid); }, carding() === c.aid ? " on" : "")}
        ${c.given ? act(armed() === uKey ? "take it back?" : "take my card back", "erase your card for them — tap twice", () => arm(uKey, () => { if (!demoSays())
        uncard(c).then(r => report(r, "your card is taken back")); }), armed() === uKey ? " arm" : "") : ""}
        ${act(picked ? "🔑 recovery friend ✓" : "🔑 recovery friend", "someone you would ask to help bring your passcode back — the pieces are made in settings", () => toggleRecoveryPick(c.aid), picked ? " on" : "")}
        ${act(armed() === fKey ? (c.mine || c.given ? "forget, and take back what you gave?" : "forget?") : "forget", "take them out of your contacts — tap twice", () => arm(fKey, () => forget(c)), armed() === fKey ? " slot-btn-delete arm" : " slot-btn-delete")}
      </div>
      ${carding() === c.aid ? cardPicker(c) : ""}
      <div class="crow-id"><span class="caid">${c.aid}</span>${c.verified ? html `<span class="crow-done">key checked ✓</span>` : ""}</div>
    </div>`;
}
function rowOf(c) {
    const k = kindOf(c.rel);
    const open = false;
    // an alias and an AID are a PEER's text: they arrive over the wire from
    // whoever that contact is, so they land in the page escaped, as content.
    const name = c.alias || c.aid;
    return html `
    <li class="crow crow-${standingOf(c)}${open ? " open" : ""}">
      <button type="button" class="crow-head" aria-expanded="${open ? "true" : "false"}"
              title="${c.online ? "reachable now" : "offline"}"
              onclick=${() => openRow.set(c.aid)}>
        <span class="cav" style="background:${paleCol(k.colour, 0.78)}; color:${k.colour}">${name.trim().charAt(0).toUpperCase() || "·"}<span class="cdot" style="background:${c.online ? STATUS.sound : "#cfcfcf"}"></span></span>
        <span class="ctext">
          <span class="cnameline"><span class="calias">${name}</span>
            ${c.recognised ? html `<span class="cmark" title="recognised person">✓</span>` : ""}
            ${c.card !== undefined ? html `<span class="cmark ccard" title="you hold their card">📇</span>` : ""}</span>
          <span class="cline${c.ask ? " asking" : ""}">${lineOf(c)}</span>
        </span>
        <span class="crel" style="background:${paleCol(k.colour, 0.78)}; color:${k.colour}">${k.id}</span>
      </button>
    </li>`;
}
// ── connect: your own link to show, theirs to read, and the card that asks ──
const connectOpen = signal(false);
/** The name the card's field holds; kept outside the signals so typing redraws nothing. */
let aliasDraft = "";
let draftFor = "";
function copyLink(link) {
    if (!navigator.clipboard) {
        hint("copy the link from the box.", "notice");
        return;
    }
    navigator.clipboard.writeText(link).then(() => hint("link copied — send it to them.", "success"), () => hint("copy the link from the box.", "notice"));
}
function drawConnect() {
    if (!connectEl)
        return;
    const p = proposal();
    if (p && draftFor !== p.aid) {
        draftFor = p.aid;
        aliasDraft = p.name;
    }
    if (!p)
        draftFor = "";
    const open = connectOpen();
    const mine = open ? myLink() : null;
    render(connectEl, html `
    ${p ? html `
      <div class="cask" role="group" aria-label="connect with someone">
        <div class="cask-q">${p.back ? "They connected with you. Connect back?" : "Connect with this person?"}</div>
        <input class="cask-name" type="text" maxlength="60" placeholder="what you call them" aria-label="what you call them"
               value="${aliasDraft}" oninput=${(e) => { aliasDraft = e.currentTarget.value; }}>
        <div class="cask-key${p.checked ? " ok" : ""}">${p.asking ? "checking their key…"
        : p.checked === null ? "key not checked yet — sign in and the commune checks it"
            : p.checked ? "key checked ✓ — this commune holds their key log"
                : "key not checked — this commune holds no key log for them"}</div>
        <div class="caid">${p.aid}</div>
        <div class="crow-acts">
          ${act("connect", "add them to your contacts", () => accept(aliasDraft), " on")}
          ${act("not now", "put this down", decline)}
        </div>
      </div>` : ""}
    <div class="crow-acts">
      ${act(open ? "＋ connect ▾" : "＋ connect", "your own link to show, or theirs to read", () => connectOpen.set(!open), open ? " on" : "")}
    </div>
    ${open ? html `
      <div class="cconnect">
        ${mine ? html `
          ${mine.qr ? html `<div class="cqr" role="img" aria-label="your link as a QR code">${raw(mine.qr)}</div>` : ""}
          <div class="cconnect-say">
            <p>Show this to someone, or send them your link. They scan it, or paste it into the bar.</p>
            <input class="cask-name" type="text" readonly aria-label="your link" value="${mine.link}"
                   onfocus=${(e) => e.currentTarget.select()}>
            <div class="crow-acts">
              ${act("copy my link", "copy your link to send", () => copyLink(mine.link))}
              ${canScan() ? act("📷 scan theirs", "read someone's QR with the camera", openCaptureLook) : ""}
            </div>
            <p>Someone sent you theirs? Paste it into the bar above, then ➕.</p>
          </div>`
        : html `<div class="cconnect-say"><p>Create your identity (tap your name, top-right) and you have a link of your own to show.
               A link someone sent you goes into the bar above, then ➕.</p></div>`}
      </div>` : ""}`);
}
/** One person's own page: a hero (face, name, kind, standing) over the acts — in place of the book while it is open. */
function drawDetail(c) {
    if (!detailEl)
        return;
    const k = kindOf(c.rel);
    const name = c.alias || c.aid;
    render(detailEl, html `
    <div class="cdetail">
      <button type="button" class="cback" onclick=${() => openRow.set(null)}>← contacts</button>
      <div class="chero">
        <span class="cav cav-lg" style="background:${paleCol(k.colour, 0.78)}; color:${k.colour}">${name.trim().charAt(0).toUpperCase() || "·"}<span class="cdot" style="background:${c.online ? STATUS.sound : "#cfcfcf"}"></span></span>
        <div class="chero-text">
          <div class="cnameline"><span class="calias">${name}</span>
            ${c.recognised ? html `<span class="cmark" title="recognised person">✓</span>` : ""}
            ${c.card !== undefined ? html `<span class="cmark ccard" title="you hold their card">📇</span>` : ""}</div>
          <div class="cline${c.ask ? " asking" : ""}">${c.online ? "reachable now" : "offline"} · ${lineOf(c)}</div>
        </div>
        <span class="crel" style="background:${paleCol(k.colour, 0.78)}; color:${k.colour}">${k.id}</span>
      </div>
      ${bodyOf(c)}
    </div>`);
}
function drawContacts() {
    if (!filtersEl || !rowsEl || !demoEl)
        return;
    const all = book();
    // a person opened: their page replaces the book until you go back
    const openId = openRow();
    const person = openId ? all.find(c => (c.aid || c.alias) === openId) ?? null : null;
    panelEl?.classList.toggle("has-detail", !!person);
    if (person) {
        drawDetail(person);
        return;
    }
    if (detailEl)
        detailEl.replaceChildren();
    // filters: all · online · asking (while anyone is), then each kind the book uses
    const kinds = [...new Set(all.map(c => c.rel || DEFAULT_REL))];
    const asking = all.filter(c => c.ask).length;
    const filters = ["all", "online", ...(asking ? ["asking"] : []), ...kinds];
    const count = (f) => f === "all" ? all.length
        : f === "online" ? all.filter(c => c.online).length
            : f === "asking" ? asking
                : all.filter(c => (c.rel || DEFAULT_REL) === f).length;
    const label = (f) => f === "all" || f === "online" || f === "asking" ? f : kindOf(f).plural;
    const filter = filters.includes(contactFilter()) ? contactFilter() : "all";
    list(filtersEl, filters, f => f, f => html `<button type="button" class="cfilter${f === filter ? " on" : ""}"
                 onclick=${() => contactFilter.set(f)}>${label(f)} ${count(f)}</button>`);
    const q = typed().trim().toLowerCase();
    const shown = all.filter(c => (!q || c.alias.toLowerCase().includes(q) || (c.aid || "").toLowerCase().includes(q)) &&
        (filter === "all" ? true :
            filter === "online" ? c.online :
                filter === "asking" ? !!c.ask :
                    (c.rel || DEFAULT_REL) === filter))
        // an open ask first, then who is here, then by name
        .sort((x, y) => (+!!y.ask - +!!x.ask) || (+y.online - +x.online) || x.alias.localeCompare(y.alias));
    list(rowsEl, shown.length ? shown : [{ empty: all.length ? "no one here" : "no contacts yet" }], c => c.empty ? "·empty" : (c.aid || c.alias), c => c.empty ? html `<li class="empty">${c.empty}</li>` : rowOf(c));
    demoEl.style.display = bookIsDemo() ? "" : "none";
}
// the drawer's Contacts view: built once, cached, with its own effect keeping
// the rows in sync with the book, the filter and the open row. Each time the
// view is shown the spine reads the book and your own standing again (at most
// once in ten seconds), so a vouch someone signed for you, or your own
// recognition, arrives without a reload.
let panelEl = null;
let readAt = 0;
export function contactsPanel(query) {
    if (!panelEl) {
        typed = query;
        panelEl = document.createElement("div");
        panelEl.className = "share-contacts";
        connectEl = document.createElement("div");
        connectEl.className = "cconnect-strip";
        filtersEl = document.createElement("div");
        filtersEl.className = "contactfilters";
        rowsEl = document.createElement("ul");
        rowsEl.className = "contacts";
        detailEl = document.createElement("div");
        detailEl.className = "cdetail-host";
        demoEl = document.createElement("div");
        demoEl.className = "opt";
        demoEl.textContent = "a demo book, kept on this device — sign in and the commons keeps yours.";
        panelEl.append(connectEl, filtersEl, rowsEl, demoEl, detailEl);
        effect(drawConnect);
        effect(drawContacts);
    }
    if (Date.now() - readAt > 10000) {
        readAt = Date.now();
        HANDLERS.contactsRefresh?.();
        rereadStanding();
    }
    return panelEl;
}
