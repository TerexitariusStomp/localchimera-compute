// app/reach.ts — your ways to be reached, and who you have told.
//
// The list is yours and is kept on this device. An entry of it is disclosed
// twice over, each time by your own act and each yours to take back: to this
// commune, so it notifies you there (a contact-point credential the spine
// builds and signs; the commune sends a code to the address and delivers once
// the code is said back), and to a person, on a card (the Contacts row). The
// settings view (reach-view.ts) and the card picker (tabs/contacts.ts) both
// read here.
import { HANDLERS } from './core.js';
import { on } from './bus.js';
import { signal } from './reactive.js';
import { readJSON, writeJSON } from './store.js';
import { REACH_KINDS, REACH_VALUE_MAX, type ReachKind } from './reach-catalogue.js';
import { K } from "./keys.js";

/** One way to reach a person: a kind from the catalogue, and its value. */
export interface ReachPoint { kind: string; value: string }

const KEY = K.reach;
const clean = (raw: unknown): ReachPoint[] =>
  (Array.isArray(raw) ? raw : [])
    .filter((p): p is ReachPoint => !!p && typeof p.kind === "string" && typeof p.value === "string"
                                   && !!kindOfReach(p.kind) && !faultOf(p.kind, p.value));

/** The catalogue row of a kind, or undefined for a kind the catalogue does not name. */
export function kindOfReach(kind: string): ReachKind | undefined {
  return REACH_KINDS.find(k => k.id === kind);
}
/** What is wrong with VALUE as a KIND, in words, or null when it stands. The commune judges an address's shape itself. */
export function faultOf(kind: string, value: string): string | null {
  if (!kindOfReach(kind)) return "choose a kind";
  if (!value.trim()) return "say where";
  if (value.length > REACH_VALUE_MAX) return "one short line";
  if (/[\u0000-\u001f\u007f]/.test(value)) return "one line";
  return null;
}
/** The link a point opens with, or "" when its kind opens nothing. */
export function linkOf(p: ReachPoint): string {
  const k = kindOfReach(p.kind);
  if (!k) return "";
  if (k.link) return k.link + encodeURI(p.value.replace(/^@(?=[^:]*$)/, ""));
  return p.kind === "web" && /^https?:\/\//i.test(p.value) ? p.value : "";
}
const same = (a: ReachPoint, b: ReachPoint): boolean => a.kind === b.kind && a.value === b.value;

// ── the list ────────────────────────────────────────────────────────────────
const list = signal<ReachPoint[]>(clean(readJSON<unknown>(KEY, [])));
const keep = (next: ReachPoint[]): void => { list.set(next); writeJSON(KEY, next); };
/** Your ways to be reached. A tracked read. */
export const reach = (): ReachPoint[] => list();
/** Add a point; answers what is wrong with it, or null once it is on the list. */
export function addReach(kind: string, value: string): string | null {
  const p = { kind, value: value.trim() };
  const fault = faultOf(p.kind, p.value);
  if (fault) return fault;
  if (!list.peek().some(q => same(p, q))) keep([...list.peek(), p]);
  return null;
}
/** Take a point off the list, and back from the commune if it was told. */
export function removeReach(p: ReachPoint): void {
  if (toldState(p)) void untell(p);
  keep(list.peek().filter(q => !same(p, q)));
}

// ── told to this commune ────────────────────────────────────────────────────
interface Told { kind: string; value: string; state: string }
const delivered = signal<string[]>([]);
const told = signal<Told[]>([]);
/** Read again what this commune delivers on and which of your points it holds. */
export function readCommune(): void {
  if (!HANDLERS.reachRead) return;
  HANDLERS.reachRead().then(r => {
    try {
      const o = JSON.parse(String(r)) as { delivers?: unknown; points?: unknown };
      delivered.set(Array.isArray(o.delivers) ? o.delivers.map(String) : []);
      told.set(Array.isArray(o.points) ? (o.points as Told[]).filter(t => t && typeof t.kind === "string") : []);
    } catch (_) { /* signed out, or no commune: what was read stands */ }
  });
}
// a seat taken is when the commune can first be asked
on("status", (s: string) => { if (typeof s === "string" && s.startsWith("ok:")) readCommune(); });

/** Whether this commune delivers on a kind. A tracked read. */
export const delivers = (kind: string): boolean => delivered().includes(kind);
/** What this commune holds of a point: "bound" (it notifies you there), "pending" (its code is on its way), or null. A tracked read. */
export function toldState(p: ReachPoint): "bound" | "pending" | null {
  const t = told().find(t => t.kind === p.kind && t.value === p.value);
  return t ? (t.state === "bound" ? "bound" : "pending") : null;
}
const ask = (r: Promise<unknown> | undefined): Promise<string> =>
  (r ?? Promise.resolve("err:offline")).then(v => { readCommune(); return String(v ?? "err:offline"); });
/** Tell the commune a point: it sends a code to the address. "ok:pending" | "err:…". */
export const tell = (p: ReachPoint): Promise<string> => ask(HANDLERS.reachPresent?.(p.kind, p.value));
/** Say back the code that arrived at the address. "ok" | "err:…". */
export const confirm = (p: ReachPoint, code: string): Promise<string> => ask(HANDLERS.reachConfirm?.(p.kind, p.value, code));
/** Take a point back from the commune. "ok" | "err:…". */
export const untell = (p: ReachPoint): Promise<string> => ask(HANDLERS.reachWithdraw?.(p.kind, p.value));

// ── a card: a selection of the list, for one person ─────────────────────────
/** What a card says: the name its giver goes by, and how to reach them. */
export interface Card { name: string; points: ReachPoint[] }
/** A card's content as the text that is sealed. */
export const cardText = (c: Card): string => JSON.stringify({ name: c.name, points: c.points });
/** The card a text opens to, or null when it is no card. A card is its giver's words: every field is read as text and shown escaped. */
export function readCard(text: string | undefined): Card | null {
  if (!text) return null;
  try {
    const o = JSON.parse(text) as { name?: unknown; points?: unknown };
    const points = (Array.isArray(o.points) ? o.points : [])
      .filter((p): p is ReachPoint => !!p && typeof p.kind === "string" && typeof p.value === "string")
      .map(p => ({ kind: p.kind.slice(0, 24), value: p.value.slice(0, REACH_VALUE_MAX) }))
      .slice(0, 24);
    return { name: typeof o.name === "string" ? o.name.slice(0, 60) : "", points };
  } catch (_) { return null; }
}
