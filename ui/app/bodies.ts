// app/bodies.ts — the legal bodies you steward or belong to, and the one you
// are declaring.
//
// A body — an association, a cooperative, the operator — is declared in a
// scope by a recognised person, stewarded by the people it names, and given
// its identifier by k of its stewards signing the group inception from their
// own seats (docs/legal/bodies.md). Here is the model: what this commune
// says of your bodies (read on every seat taken), the one body open for
// reading, and the declaration drafted on this device. The view is
// bodies-view.ts; the doors are identity/body-doors.scm, reached through the
// seam's body handlers.
import { HANDLERS } from './core.js';
import { on } from './bus.js';
import { signal } from './reactive.js';
import { readJSON, writeJSON } from './store.js';
import { scopeSig } from './scope.js';
import { K } from './keys.js';
import type { Stance } from './legal-product.js';

/** What a body holds — a permit, a policy, a registration — and the law's reading of it. */
export interface BodyHolding { id: string; spec: string; name: string; issuer?: string; validUntil?: string | null; status: string }
/** The inception (or a rotation) under signature: how many of how many, and the AID once published. */
export interface BodyCeremony { have: number; need: number; published: string | null; what: string }
/** One line a lint says of the scope's bodies. */
export interface Finding { severity: string; kind: string; subject: string; detail: string }
/**
 * What the law in force at the body's jurisdiction means for it: the stance the
 * fold read off its bill, the doors it trips, each demand against what it holds,
 * and the demands it still owes, is forbidden, or stands doubted on. `{}` until
 * the commune has read it.
 */
export interface BodyExposure {
  stance?: Stance; doors?: string[];
  holds?: { demand: string; status: string }[];
  owes?: string[]; forbidden?: string[]; doubted?: string[];
}
/** A body as the commune states it; the whole read fills the optional parts. */
export interface Body {
  id: string; name: string; tags: string[];
  steward?: boolean; ceremony?: BodyCeremony | null;
  /** The place it is declared in — a law-snapshot place id, or one of the older codes. */
  jurisdiction?: string | null;
  stewards?: string[]; members?: string[]; crossings?: string[];
  holdings?: BodyHolding[]; findings?: Finding[]; exposure?: BodyExposure;
}

/** The value of a `key:value` tag on a body, or "". */
export const tagValue = (b: Body, key: string): string =>
  (b.tags.find(t => t.startsWith(key + ":")) || "").slice(key.length + 1);
/** Where a body is declared: the field, or the tag a body declared earlier carries. */
export const jurisdictionOf = (b: Body): string => b.jurisdiction || tagValue(b, "jurisdiction");
/** Whether a body's identifier is still the provisional one its declaration minted. */
export const provisional = (b: Body): boolean => b.id.startsWith("body:");

// ── reading ─────────────────────────────────────────────────────────────────
const list = signal<Body[]>([]);
const open = signal<Body | null>(null);
/** Your bodies, as last read. A tracked read. */
export const bodies = (): Body[] => list();
/** The body open for reading, whole, or null. A tracked read. */
export const current = (): Body | null => open();

const asBody = (o: unknown): Body | null => {
  const b = o as Body;
  if (!b || typeof b.id !== "string" || typeof b.name !== "string") return null;
  return { ...b, tags: Array.isArray(b.tags) ? b.tags.map(String) : [] };
};
/** Read your bodies again from the commune. */
export function readBodies(): Promise<void> {
  const scope = scopeSig();
  if (!HANDLERS.bodiesRead || !scope) return Promise.resolve();
  return HANDLERS.bodiesRead(scope).then(r => {
    try {
      const rows = JSON.parse(String(r));
      list.set(Array.isArray(rows) ? rows.map(asBody).filter((b): b is Body => !!b) : []);
    } catch (_) { /* signed out, or no commune: what was read stands */ }
  }, () => { /* unreachable: what was read stands */ });
}
/** Read one body whole; "ok" or the commune's refusal. */
export function readBody(id: string): Promise<string> {
  if (!HANDLERS.bodyRead) return Promise.resolve("err:offline");
  return HANDLERS.bodyRead(id).then(r => {
    const s = String(r ?? "err:offline");
    if (s.startsWith("err:")) return s;
    try {
      const b = asBody(JSON.parse(s));
      if (!b) return "err:the body could not be read";
      open.set(b);
      return "ok";
    } catch (_) { return "err:the body could not be read"; }
  }, () => "err:offline");
}
/** Put the open body down. */
export const closeBody = (): void => open.set(null);
// a seat taken is when the commune can first be asked
on("status", (s: string) => { if (typeof s === "string" && s.startsWith("ok:")) void readBodies(); });

// ── acting ──────────────────────────────────────────────────────────────────
/** A reply as the commune's word: "ok", "ok:…" or "err:…" — and the bodies read again after an act. */
const said = (r: Promise<unknown> | undefined): Promise<string> =>
  (r ?? Promise.resolve("err:offline")).then(v => String(v ?? "err:offline"), () => "err:offline")
    .then(s => { if (s.startsWith("ok")) { void readBodies(); const b = open.peek(); if (b) void readBody(b.id); } return s; });
/** The JSON an "ok:…" reply carries, or null. */
export function okJSON<T>(r: string): T | null {
  if (!r.startsWith("ok:")) return null;
  try { return JSON.parse(r.slice(3)) as T; } catch (_) { return null; }
}

/** The declaration drafted here. */
export interface BodyDraft {
  name: string; kind: string; role: string; jurisdiction: string;
  assetLock: boolean; register: "closed" | "inspectable"; stewards: string[];
}
export const KINDS = ["association", "cooperative", "company", "foundation", "operator"];
export const ROLES = ["provider", "seller", "employer", "adapter", "custodian"];
// ── jurisdictions: the law snapshot's places ────────────────────────────────
// A body is declared in a place the law face reads — a nation or a region of
// data/snapshots/law-snapshot.json, by its id. The codes below are what bodies
// declared before the snapshot was the list carry, and what the picker offers
// while the snapshot is not in: each names the snapshot place it stands for.
export interface Jurisdiction { id: string; name: string }
const JURISDICTION_CODES: Record<string, string> =
  { fr: "france", de: "germany", us: "us", ca: "canada", mx: "mexico", uk: "uk", es: "es", it: "it", be: "be", ch: "ch" };
/** The picker's list while the snapshot is not in: the codes, each its own name. */
export const JURISDICTIONS = Object.keys(JURISDICTION_CODES);
const jurisSig = signal<Jurisdiction[]>(JURISDICTIONS.map(id => ({ id, name: id })));
const placeNames = new Map<string, string>();
let jurisLoad: Promise<void> | null = null;
/** Read the snapshot once; the list and the names stand on what it says. Offline, the codes stand. */
function loadJurisdictions(): Promise<void> {
  if (jurisLoad) return jurisLoad;
  jurisLoad = (typeof fetch === "function" ? fetch("data/snapshots/law-snapshot.json").then(r => r.json()) : Promise.reject(new Error("no fetch")))
    .then((snap: { nations?: { id: string; name: string }[]; places?: Record<string, { name: string; kind?: string }> }) => {
      const places = snap.places || {};
      for (const [id, p] of Object.entries(places)) placeNames.set(id, p.name);
      const nations = (snap.nations || []).map(n => ({ id: n.id, name: n.name }));
      const seen = new Set(nations.map(n => n.id));
      const regions = Object.entries(places).filter(([id, p]) => !seen.has(id) && (p.kind === "nation" || p.kind === "region"))
        .map(([id, p]) => ({ id, name: p.name }));
      if (nations.length) jurisSig.set([...nations, ...regions]);
    }, () => { /* offline: the codes stand */ });
  return jurisLoad;
}
/** The places a body can be declared in. A tracked read; the first one reads the snapshot. */
export function jurisdictions(): Jurisdiction[] { void loadJurisdictions(); return jurisSig(); }
/** The snapshot place a jurisdiction names: the id itself, or the place its code stands for. */
export const jurisdictionPlace = (j: string): string => placeNames.has(j) ? j : JURISDICTION_CODES[j] || j;
/** How the law face names it, or the jurisdiction as given. */
export const jurisdictionName = (j: string): string => placeNames.get(jurisdictionPlace(j)) || j;
const DRAFT = K.bodiesDraft;
const blank = (): BodyDraft => ({ name: "", kind: KINDS[0]!, role: ROLES[0]!, jurisdiction: JURISDICTIONS[0]!, assetLock: true, register: "inspectable", stewards: [] });
const cleanDraft = (raw: unknown): BodyDraft => {
  const d = { ...blank(), ...(raw && typeof raw === "object" ? raw as Partial<BodyDraft> : {}) };
  d.name = typeof d.name === "string" ? d.name.slice(0, 80) : "";
  d.stewards = Array.isArray(d.stewards) ? d.stewards.filter((s): s is string => typeof s === "string") : [];
  d.register = d.register === "closed" ? "closed" : "inspectable";
  d.assetLock = !!d.assetLock;
  return d;
};
const draftSig = signal<BodyDraft>(cleanDraft(readJSON<unknown>(DRAFT, null)));
/** The draft. A tracked read. */
export const draft = (): BodyDraft => draftSig();
/** Change the draft; it is kept on this device until declared. */
export function setDraft(patch: Partial<BodyDraft>): void {
  const next = cleanDraft({ ...draftSig.peek(), ...patch });
  draftSig.set(next); writeJSON(DRAFT, next);
}
/** What is wrong with the draft, or null when it can be declared. */
export const draftFault = (d: BodyDraft): string | null =>
  !d.name.trim() ? "give the body a name" : d.name.length > 80 ? "a name is one short line" : null;

/** Declare the drafted body in this scope, then name its stewards; "ok" | "err:…". */
export async function declare(): Promise<string> {
  const d = draftSig.peek();
  const fault = draftFault(d);
  if (fault) return "err:" + fault;
  const scope = scopeSig();
  if (!scope) return "err:no scope yet";
  const r = await said(HANDLERS.bodyDeclare?.(scope, JSON.stringify({
    name: d.name.trim(), kind: d.kind, role: d.role, jurisdiction: d.jurisdiction,
    assetLock: d.assetLock, register: d.register })));
  const b = okJSON<Body>(r);
  if (!b) return r;
  for (const aid of d.stewards) await said(HANDLERS.bodyAddSteward?.(b.id, aid));
  setDraft({ ...blank() });
  await readBodies();
  return "ok";
}
/** Name a steward of a body you steward. */
export const addSteward = (id: string, aid: string): Promise<string> => said(HANDLERS.bodyAddSteward?.(id, aid));
/** Open the inception: k of the stewards must sign. */
export const openCeremony = (id: string, k: number): Promise<string> => said(HANDLERS.bodyOpenCeremony?.(id, k));
/** Sign the open statement here, with this seat's own key. */
export const sign = (id: string, what = "inception"): Promise<string> => said(HANDLERS.bodySign?.(id, what));
/** Present what a body holds. */
export const hold = (id: string, h: { kind: string; name: string; issuer: string; validUntil: string; ref: string }): Promise<string> =>
  said(HANDLERS.bodyHold?.(id, JSON.stringify(h)));
/** Admit a body to this scope — a governor's act; the commune refuses anyone else. */
export function admit(id: string): Promise<string> {
  const scope = scopeSig();
  return scope ? said(HANDLERS.bodyAdmit?.(scope, id)) : Promise.resolve("err:no scope yet");
}
/** The ceremony's standing in words: "2 of 3 signed", or the AID once published. */
export function ceremonyWords(c: BodyCeremony | null | undefined): string {
  if (!c) return "not yet incepted";
  if (c.published) return "incepted — " + c.published.slice(0, 12) + "…";
  return `${c.have} of ${c.need} signed`;
}
