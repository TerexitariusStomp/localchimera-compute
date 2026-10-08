// app/outbox.ts — what a person did with no gateway in reach, kept until one is.
//
// A person works the same way connected or not (docs/planning/faces/offline-outbox.md).
// An act that is theirs alone to make, and that nobody else can invalidate (a
// count, an observation, a need, an offer), is sent to the gateway; when the
// gateway is out of reach the act lands on the device's copy of the scope
// (scope-local.ts) and waits here, in order, until a gateway is reached.
//
// What makes waiting safe is the act's own identity. A count and an observation
// are of their instant: stated at an instant, each is the same act wherever and
// however often it lands (count-door.scm names it by who, what, when and the
// figure), so `stamp` gives a queued act the instant it was made. A need and an
// offer are named by who and what, and declaring one again restates it. So an
// act flushed twice lands once, and the gateway's answer is the one that stands.
//
// An act that depends on others (a claim, a vote, accepting an offer, a key
// event) is never queued: it waits for a connection.

/** A door whose act waits for a gateway: the index of its instant among its arguments, or null where its ids name it. */
export const QUEUED: Readonly<Record<string, number | null>> = {
  countStock: 5,      // resource counted unit technique place WHEN fulfills evidence note
  logObserve: 5,      // action spec qty unit note WHEN
  declareNeed: null,
  declareMeans: null,
};

/** An act waiting for a gateway. */
export interface Waiting {
  door: string;
  args: string[];
  /** When it was made, as the act itself states it. */
  at: string;
  /** What a gateway refused it with, once one has; it is kept for the person to see. */
  refused?: string;
}

/** Where the waiting acts are kept, in the order they were made. */
export interface Box {
  add(act: Waiting): Promise<void>;
  /** Each waiting act with the key it is kept under, oldest first. */
  all(): Promise<Array<[IDBValidKey, Waiting]>>;
  drop(key: IDBValidKey): Promise<void>;
  /** Keep ACT under KEY in place of what was there. */
  keep(key: IDBValidKey, act: Waiting): Promise<void>;
}

/**
 * A reply that says no gateway answered, as against a gateway's own refusal:
 * the spine is not there, the planner did not answer, or the seat is not held
 * (the spine's words for a door asked with no session or no scope).
 */
export const unreached = (reply: string): boolean =>
  /^err:(offline|spine down|planner unreachable|no planner service|unavailable|sign in first|no scope yet)/.test(reply);

/** An instant as the doors state one: UTC to the second. */
export const instant = (t: Date): string => t.toISOString().slice(0, 19) + "Z";

/** DOOR's arguments, every one a string, with the act's instant stated where the door takes one and none was. */
export function stamp(door: string, args: readonly unknown[], now: Date): string[] {
  const out = args.map(a => (a == null ? "" : String(a)));
  const at = QUEUED[door];
  if (typeof at === "number") {
    while (out.length <= at) out.push("");
    if (!out[at]) out[at] = instant(now);
  }
  return out;
}

/** What a flush did: how many acts landed, how many a gateway refused, how many still wait. */
export interface Flushed { landed: number; refused: number; waiting: number }

/**
 * Send what waits, oldest first. An act a gateway answers is dropped, or kept
 * with the refusal where it refused it; the first act no gateway answers ends
 * the flush, and it and the rest wait on.
 */
export async function flush(box: Box, send: (door: string, args: string[]) => Promise<string>): Promise<Flushed> {
  const waiting = await box.all();
  let landed = 0, refused = 0;
  for (let i = 0; i < waiting.length; i++) {
    const [key, act] = waiting[i]!;
    if (act.refused) { refused++; continue; }            // seen and refused already: it is the person's to drop or restate
    const reply = await send(act.door, act.args);
    if (unreached(reply)) return { landed, refused, waiting: waiting.length - landed - refused };
    if (reply.startsWith("err:")) { await box.keep(key, { ...act, refused: reply.slice(4) }); refused++; }
    else { await box.drop(key); landed++; }
  }
  return { landed, refused, waiting: 0 };
}

/** The two ends a door may be asked at, and where an act waits between them. */
export interface Ends {
  /** The gateway's door, asked as the face asked it: answers an `unreached` reply where no gateway is in reach. */
  gateway(door: string, args: readonly unknown[]): Promise<string>;
  /** The device's copy of the scope. */
  device(door: string, args: string[]): Promise<string>;
  /** Where an act waits for a gateway; absent where the copy is of no scope a gateway holds (the demo's). */
  box?: Box;
  now(): Date;
}

/**
 * Ask DOOR. A gateway in reach answers, asked exactly as the face asked. Where
 * none is, the device's copy answers, and an act that may wait is stated at its
 * instant, landed on the copy and kept in the box for the next flush; an act
 * that may not wait is told so.
 */
export async function ask(ends: Ends, door: string, args: readonly unknown[], reads: ReadonlySet<string>): Promise<string> {
  const reply = await ends.gateway(door, args);
  if (!unreached(reply)) return reply;
  if (door in QUEUED) {
    // the act is now of the instant it was made: the copy lands it so, and so will the gateway
    const act = stamp(door, args, ends.now());
    const landed = await ends.device(door, act);
    if (!landed.startsWith("err:")) await ends.box?.add({ door, args: act, at: instant(ends.now()) });
    return landed;
  }
  if (reads.has(door)) return ends.device(door, args.map(a => (a == null ? "" : String(a))));
  return "err:this waits for a connection";
}
