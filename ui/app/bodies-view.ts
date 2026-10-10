// app/bodies-view.ts — settings › "legal bodies", and the `?face=bodies` face:
// the bodies you steward, the one you are declaring, and one read whole.
//
// The declaration is a sentence whose bold words are its pickers (the lend
// control's idiom): «name», a «kind» acting as «role» in «jurisdiction»,
// assets «locked», register «closed». Its stewards are picked from the
// contact book (the audience picker). A declared body shows its ceremony —
// "k of n signed" and one button to sign from this seat — its holdings with
// the law's reading of each and a row to present one, the scope's admission
// findings, and the admission a governor may give. Every refusal the commune
// states arrives as one hint.
import { hint } from './core.js';
import { effect } from './reactive.js';
import { mk as el } from './dom.js';
import { attached } from './books.js';
import { scopeName } from './scope.js';
import { nameOf } from './contact-book.js';
import { audiencePicker } from './slots/criteria.js';
import { audienceOf, ruleOf } from './lend-core.js';
import { bodies, current, draft, setDraft, draftFault, declare, readBody, closeBody, addSteward,
         openCeremony, sign, hold, admit, tagValue, provisional, ceremonyWords, jurisdictions,
         jurisdictionOf, jurisdictionName, jurisdictionPlace,
         KINDS, ROLES, leiValid, legalIdsOf, type Body, type BodyHolding, type Finding } from './bodies.js';
// a body stands in a place the law face reads: its jurisdiction opens there, and
// the law's stance on it wears the map's own words and paint
import { lawDeepLink, lawStancePaint } from './tabs/law.js';
import { setFace } from './faces.js';

type Picker = "name" | "kind" | "role" | "jurisdiction" | "assetLock" | "register" | "stewards" | "lei" | null;
let openPicker: Picker = null;
let kDraft = 2;
let pickingSteward = false;
const holdDraft = { kind: "", name: "", issuer: "", validUntil: "", ref: "" };

const said = (r: string, done: string): void =>
  hint(r.startsWith("ok") ? done : r.replace(/^err:/, ""), r.startsWith("ok") ? "success" : "error");
const btn = (label: string, title: string, fn: () => void, cls = ""): HTMLElement => {
  const b = el("button", "slot-btn" + cls, label);
  b.type = "button"; b.title = title;
  b.addEventListener("click", fn);
  return b;
};
const short = (aid: string): string => nameOf(aid);

// ── the declaration ─────────────────────────────────────────────────────────
function declareSentence(redraw: () => void): HTMLElement {
  const d = draft();
  jurisdictions();              // the snapshot's places: read here so the sentence names them once they are in
  const box = el("div", "sl-soc ld bd-declare");
  const tok = (k: Picker, text: string): HTMLElement => {
    const a = el("a", "ld-tok" + (openPicker === k ? " on" : ""), text);
    a.addEventListener("click", () => { openPicker = openPicker === k ? null : k; redraw(); });
    return a;
  };
  const txt = (s: string): Text => document.createTextNode(s);
  const say = el("div", "sl-soc-say bd-say");
  say.append(txt("Declare "), tok("name", d.name.trim() ? `«${d.name.trim()}»` : "«a name»"),
             txt(", a "), tok("kind", d.kind), txt(" acting as "), tok("role", d.role),
             txt(" in "), tok("jurisdiction", jurisdictionName(d.jurisdiction)),
             txt(", assets "), tok("assetLock", d.assetLock ? "locked" : "free"),
             txt(", register "), tok("register", d.register),
             txt(`, in ${scopeName()}; stewarded by `),
             tok("stewards", d.stewards.length ? d.stewards.map(short).join(", ") : "you alone"),
             txt("; registered as "), tok("lei", d.lei ? "LEI " + d.lei : "no LEI"), txt("."));
  box.appendChild(say);
  const body = el("div", "sl-soc-body");
  const chips = (key: "kind" | "role" | "jurisdiction", opts: string[]): void => {
    const row = el("div", "sl-presets");
    for (const o of opts) {
      const c = el("a", "sl-chip" + (d[key] === o ? " on" : ""), o);
      c.addEventListener("click", () => { setDraft({ [key]: o }); openPicker = null; });
      row.appendChild(c);
    }
    body.appendChild(row);
  };
  if (openPicker === "name") {
    const i = el("input", "bd-name");
    i.type = "text"; i.maxLength = 80; i.placeholder = "the body's name"; i.value = d.name;
    i.setAttribute("aria-label", "the body's name");
    i.addEventListener("input", () => setDraft({ name: i.value }));
    i.addEventListener("keydown", (e: KeyboardEvent) => { if (e.key === "Enter") { openPicker = null; redraw(); } });
    body.appendChild(i);
    queueMicrotask(() => i.focus());
  } else if (openPicker === "lei") {
    // the Legal Entity Identifier, when the body has one: twenty characters, ISO 7064 check digits
    const i = el("input", "bd-lei");
    i.type = "text"; i.maxLength = 20; i.placeholder = "LEI, if the body has one (20 characters)"; i.value = d.lei;
    i.setAttribute("aria-label", "the body's Legal Entity Identifier");
    i.addEventListener("input", () => setDraft({ lei: i.value }));
    i.addEventListener("keydown", (e: KeyboardEvent) => { if (e.key === "Enter") { openPicker = null; redraw(); } });
    body.appendChild(i);
    if (d.lei && !leiValid(d.lei)) body.appendChild(el("div", "reach-note bd-warn", "not a valid LEI yet"));
    queueMicrotask(() => i.focus());
  } else if (openPicker === "kind") chips("kind", KINDS);
  else if (openPicker === "role") chips("role", ROLES);
  else if (openPicker === "jurisdiction") {
    // the snapshot's nations and regions, by name; the id is what the draft keeps
    const row = el("div", "sl-presets bd-juris");
    for (const j of jurisdictions()) {
      const c = el("a", "sl-chip" + (jurisdictionPlace(d.jurisdiction) === j.id ? " on" : ""), j.name);
      c.title = j.id;
      c.addEventListener("click", () => { setDraft({ jurisdiction: j.id }); openPicker = null; });
      row.appendChild(c);
    }
    body.appendChild(row);
  }
  else if (openPicker === "assetLock") {
    const row = el("div", "sl-presets");
    for (const [v, label, title] of [[true, "locked", "its assets cannot be shared out to members"], [false, "free", "its assets may be shared out"]] as const) {
      const c = el("a", "sl-chip" + (d.assetLock === v ? " on" : ""), label);
      c.title = title;
      c.addEventListener("click", () => { setDraft({ assetLock: v }); openPicker = null; });
      row.appendChild(c);
    }
    body.appendChild(row);
  } else if (openPicker === "register") {
    const row = el("div", "sl-presets");
    for (const [v, title] of [["inspectable", "anyone in the scope may read who its members are"], ["closed", "its members are read by its stewards alone"]] as const) {
      const c = el("a", "sl-chip" + (d.register === v ? " on" : ""), v);
      c.title = title;
      c.addEventListener("click", () => { setDraft({ register: v }); openPicker = null; });
      row.appendChild(c);
    }
    body.appendChild(row);
  } else if (openPicker === "stewards") {
    // the audience picker over the contact book: the people picked are the stewards
    const rule = ruleOf({ vouched: false, kinds: new Set(), people: new Set(d.stewards) });
    body.appendChild(audiencePicker(rule, r => {
      const a = audienceOf(r);
      setDraft({ stewards: a ? [...a.people] : [] });
    }));
  }
  box.appendChild(body);
  const act = el("div", "sl-soc-row bd-act");
  const fault = draftFault(d);
  act.appendChild(btn("declare", fault || "declare this body in the scope; you are its first steward",
    () => { if (fault) { hint(fault, "warn"); return; } void declare().then(r => said(r, "declared — now its stewards sign the inception")); },
    fault ? "" : " on"));
  box.appendChild(act);
  return box;
}

// ── one body, whole ─────────────────────────────────────────────────────────
const statusChip = (h: BodyHolding): HTMLElement => {
  const c = el("span", "sl-chip bd-status bd-" + h.status.replace(/[^a-z-]/g, "") + (h.status === "satisfied" ? " on" : ""), h.status);
  c.title = h.validUntil ? `valid until ${h.validUntil}` : "no end date";
  return c;
};

function findingRow(f: Finding): HTMLElement {
  const li = el("li", "reach-row bd-finding bd-" + f.severity);
  li.append(el("span", "reach-kind", f.severity), el("span", "reach-value", `${f.kind}: ${f.detail}`));
  return li;
}

/** "the law here: <stance>" in the law face's paint, and what the body still owes or is forbidden. */
function lawLine(b: Body): HTMLElement {
  const x = b.exposure || {};
  const row = el("div", "reach-row bd-law");
  const [colour, word] = lawStancePaint(x.stance);
  const value = el("span", "reach-value");
  const stance = el("b", "bd-stance " + (x.stance || "unread"), word);
  stance.style.color = colour;
  value.append(document.createTextNode("the law here: "), stance);
  if (x.owes?.length) value.append(el("span", "bd-owes", " · owes " + x.owes.join(", ")));
  if (x.forbidden?.length) {
    const f = el("span", "bd-forbidden", " · forbidden: " + x.forbidden.join(", "));
    f.style.color = lawStancePaint("off")[0];
    value.appendChild(f);
  }
  if (x.doubted?.length) value.append(el("span", "bd-doubted", " · doubted: " + x.doubted.join(", ")));
  row.append(el("span", "reach-kind", "exposure"), value);
  return row;
}

function bodyPanel(b: Body, redraw: () => void): HTMLElement {
  const box = el("div", "bd-body");
  const head = el("div", "reach-row bd-head");
  const where = el("span", "reach-value");
  where.append(document.createTextNode(`${tagValue(b, "kind") || "body"} · ${tagValue(b, "role") || ""} · `));
  const j = jurisdictionOf(b);
  if (j) {
    // the jurisdiction opens the law face on that place
    const a = el("a", "bd-juris", jurisdictionName(j));
    a.title = "read the law of " + jurisdictionName(j);
    a.addEventListener("click", () => { lawDeepLink(jurisdictionPlace(j)); setFace("law"); });
    where.appendChild(a);
  }
  head.append(el("span", "reach-kind", b.name), where, btn("close", "put this body down", () => closeBody()));
  box.appendChild(head);
  box.appendChild(el("div", "reach-note bd-id", provisional(b) ? "provisional — the identifier comes with the inception" : b.id));
  // its registry identifiers, and the credential the commune issued on admission
  const ids = legalIdsOf(b);
  const idRow = el("div", "reach-row bd-legal");
  idRow.append(el("span", "reach-kind", "registered"),
               el("span", "reach-value", Object.keys(ids).length
                  ? Object.entries(ids).map(([k, v]) => k.toUpperCase() + " " + v).join(" · ")
                  : "no registry identifier"));
  box.appendChild(idRow);
  const credRow = el("div", "reach-row bd-cred");
  credRow.append(el("span", "reach-kind", "credential"),
                 el("span", "reach-value", b.credential ? "admitted — " + b.credential.slice(0, 12) + "…" : "not yet admitted"));
  credRow.title = b.credential || "the body credential the commune issues when a governor admits it";
  box.appendChild(credRow);
  box.appendChild(lawLine(b));

  // the stewards, and the ceremony that makes the body's identifier
  const stew = el("ul", "reach-list bd-stewards");
  for (const aid of b.stewards || []) {
    const li = el("li", "reach-row");
    li.append(el("span", "reach-kind", "steward"), el("span", "reach-value", short(aid)));
    stew.appendChild(li);
  }
  // another steward, while the inception is not yet signed: picked from the book
  if (!b.ceremony) {
    const li = el("li", "reach-row bd-add-steward");
    li.appendChild(btn(pickingSteward ? "done" : "name a steward", "a steward of the body you steward too — from your contacts",
                       () => { pickingSteward = !pickingSteward; redraw(); }));
    stew.appendChild(li);
    if (pickingSteward) {
      const have = new Set(b.stewards || []);
      stew.appendChild(audiencePicker(ruleOf({ vouched: false, kinds: new Set(), people: new Set(have) }), r => {
        const a = audienceOf(r);
        for (const aid of a ? a.people : []) if (!have.has(aid)) void addSteward(b.id, aid).then(x => said(x, `${short(aid)} is a steward`));
      }));
    }
  }
  box.appendChild(stew);
  const cer = el("div", "reach-row bd-ceremony");
  cer.append(el("span", "reach-kind", "inception"), el("span", "reach-value bd-signed", ceremonyWords(b.ceremony)));
  if (!b.ceremony) {
    const k = el("input", "reach-code bd-k");
    k.type = "number"; k.min = "1"; k.max = String((b.stewards || []).length || 1); k.value = String(Math.min(kDraft, (b.stewards || []).length || 1));
    k.setAttribute("aria-label", "how many stewards must sign");
    k.addEventListener("input", () => { kDraft = Number(k.value) || 1; });
    cer.append(k, btn("open the ceremony", "k of the stewards must sign the inception from their own seats",
                      () => void openCeremony(b.id, Number(k.value) || 1).then(r => said(r, "the ceremony is open — each steward signs from their seat")), " on"));
  } else if (!b.ceremony.published) {
    cer.appendChild(btn("sign", "sign the inception with this seat's own key", () => void sign(b.id).then(r => said(r, "signed")), " on"));
  }
  box.appendChild(cer);

  // holdings: what the body holds, each with the law's reading of it
  box.appendChild(el("div", "set-h bd-h", "holdings"));
  const hl = el("ul", "reach-list bd-holdings");
  for (const h of b.holdings || []) {
    const li = el("li", "reach-row bd-holding");
    li.append(el("span", "reach-kind", h.spec), el("span", "reach-value", h.name || ""), statusChip(h));
    hl.appendChild(li);
  }
  if (!(b.holdings || []).length) hl.appendChild(el("li", "reach-note", "nothing presented yet"));
  box.appendChild(hl);
  const add = el("div", "reach-add bd-hold");
  const field = (key: keyof typeof holdDraft, placeholder: string, type = "text"): HTMLInputElement => {
    const i = el("input"); i.type = type; i.placeholder = placeholder; i.value = holdDraft[key];
    i.setAttribute("aria-label", placeholder);
    i.addEventListener("input", () => { holdDraft[key] = i.value; });
    return i;
  };
  add.append(field("kind", "what it is (fr/rc-auto)"), field("name", "its name"), field("issuer", "issued by"), field("validUntil", "valid until", "date"),
             btn("present", "present this holding; the law reads it against the bill",
                 () => {
                   if (!holdDraft.kind.trim()) { hint("say what kind of holding it is", "warn"); return; }
                   void hold(b.id, { ...holdDraft, kind: holdDraft.kind.trim() }).then(r => {
                     if (r.startsWith("ok")) { holdDraft.kind = holdDraft.name = holdDraft.issuer = holdDraft.validUntil = holdDraft.ref = ""; redraw(); }
                     said(r, "presented");
                   });
                 }, " on"));
  box.appendChild(add);

  // the scope's admission tests, and the act
  box.appendChild(el("div", "set-h bd-h", "admission"));
  const fl = el("ul", "reach-list bd-findings");
  for (const f of b.findings || []) fl.appendChild(findingRow(f));
  if (!(b.findings || []).length) fl.appendChild(el("li", "reach-note", "the admission tests say nothing against it"));
  box.appendChild(fl);
  const adm = el("div", "sl-soc-row bd-admit");
  adm.appendChild(btn("admit to " + scopeName(), "a governor's act; the commune refuses anyone else",
                      () => void admit(b.id).then(r => said(r, "admitted"))));
  box.appendChild(adm);
  return box;
}

// ── the block ───────────────────────────────────────────────────────────────
function draw(root: HTMLElement): void {
  const redraw = (): void => draw(root);
  root.replaceChildren();
  root.className = "bodies";
  const list = bodies();
  const b = current();
  if (b) { root.appendChild(bodyPanel(b, redraw)); return; }
  if (!attached()) root.appendChild(el("p", "reach-note", "sign in, and the bodies you steward show here"));
  if (list.length) {
    const ul = el("ul", "reach-list bd-list");
    for (const x of list) {
      const li = el("li", "reach-row bd-row");
      li.append(el("span", "reach-kind", x.name),
                el("span", "reach-value", `${tagValue(x, "kind") || "body"} · ${ceremonyWords(x.ceremony)}`),
                btn("open", "read the body whole", () => void readBody(x.id).then(r => { if (!r.startsWith("ok")) said(r, ""); })));
      ul.appendChild(li);
    }
    root.appendChild(ul);
  } else if (attached()) root.appendChild(el("p", "reach-note", "you steward no body yet — declare one below."));
  root.appendChild(declareSentence(redraw));
}

let block: HTMLElement | null = null;
/** The settings block: one element for the life of the page, redrawn by its own effect. */
export function bodiesBlock(): HTMLElement {
  if (!block) {
    const root = el("div", "bodies");
    block = root;
    effect(() => draw(root));
  }
  return block;
}

// ── the face: `?face=bodies` ────────────────────────────────────────────────
// The overlay is made here, beside the other faces' own, so the page carries
// no markup for it until it is asked for.
let face: HTMLElement | null = null;
/** Mount the bodies face on the stage. */
export function bodiesEnter(): void {
  if (!face) {
    const style = el("style");
    style.textContent = "#bodiesface{position:absolute;inset:0;display:none;overflow-y:auto;overscroll-behavior:contain;padding:16px}"
                      + "#bodiesface.on{display:block}#bodiesface .bodies{max-width:720px;margin:0 auto}";
    document.head.appendChild(style);
    face = el("div"); face.id = "bodiesface";
    const stage = el("div"); stage.id = "bodiesstage";
    stage.appendChild(el("div", "set-h", "legal bodies"));
    stage.appendChild(bodiesBlock());
    face.appendChild(stage);
    const beside = document.getElementById("onboardface");
    (beside?.parentElement || document.getElementById("main") || document.body).insertBefore(face, beside?.nextSibling || null);
  }
  face.classList.add("on");
}
