// app/compute-executor.ts — the browser IS the node.
//
// A job envelope arrives as the fetch door returns it
// ({bridgeJobId, image, entrypoint, inputHash, caps, network}); runEnvelope
// runs the entrypoint inside a Worker it cannot escape, meters the wall-clock,
// and returns the receipt wire body — the object session/compute-receipt
// accepts. The digest is computed over the same canonical bytes the Scheme
// verifier recomputes (tests/compute/test-receipt.scm carries the vectors):
// sha256("naoms-compute-receipt/v1" + NUL + canonical JSON), field order IS
// the format, absent optionals drop, missing engine/usage/repro emit null.
//
// Sandbox: the worker's globals are stripped — no fetch/XHR/WebSocket/
// sendBeacon/EventSource/importScripts — unless the envelope's network flag
// is true AND its caps name "fetch". A timeout kills the worker; the lender
// owes a receipt by the claim's deadline or the claim expires.
//
// The lender's signature is NOT produced here: a did:key↔AID binding is a
// spec-open question (§1), so v1 emits lenderSig:null — the door answers
// 'unverifiable for it, never a silent pass.

export interface JobEnvelope {
  bridgeJobId: string;
  image: string;
  entrypoint: string;
  inputHash: string;
  caps: string[];
  network: boolean;
}

export interface ReceiptBody {
  bridgeJobId: string;
  lenderDid: string;
  inputHash: string;
  outputHash: string;
  engine: string | null;
  usage: { unit: string; amount: number } | null;
  repro: { mode: string; seed?: number; decoding?: string; engineVersion?: string } | null;
  executedAt: number;
  lenderSig: string | null;
  borrowerSig: string | null;
  digest: string;
}

const RECEIPT_DOMAIN = "naoms-compute-receipt/v1\0";

const hex = (buf: ArrayBuffer) =>
  [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, "0")).join("");

const sha256hex = async (s: string) =>
  hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));

// Canonical JSON — the Scheme side emits exactly what JSON.stringify emits
// for this literal: insertion-ordered keys, no spaces, undefined dropped.
const receiptCanonical = (b: Omit<ReceiptBody, "lenderSig" | "borrowerSig" | "digest">) =>
  JSON.stringify({
    bridgeJobId: b.bridgeJobId,
    lenderDid: b.lenderDid,
    inputHash: b.inputHash,
    outputHash: b.outputHash,
    engine: b.engine ?? null,
    usage: b.usage ?? null,
    repro: b.repro ?? null,
    executedAt: b.executedAt,
  });

export const digestReceiptBody = async (
  b: Omit<ReceiptBody, "lenderSig" | "borrowerSig" | "digest">,
) => sha256hex(RECEIPT_DOMAIN + receiptCanonical(b));

// ── the worker ────────────────────────────────────────────────────────────
// The blob prelude evaluates ENVELOPE.entrypoint — a JS expression evaluating
// to (input) => output — applies it, posts the result back. Everything that
// could reach off the sandbox is renamed away before the code runs; the cap
// grant restores it when the envelope allows.

const WORKER_PRELUDE = `
const __grant = (self.__caps || []).includes("fetch") && self.__net === true;
if (!__grant) {
  self.fetch = undefined; self.XMLHttpRequest = undefined;
  self.WebSocket = undefined; self.EventSource = undefined;
  self.sendBeacon = undefined; self.importScripts = undefined;
}
self.onmessage = async (e) => {
  try {
    const fn = eval("(" + e.data.entrypoint + ")");
    if (typeof fn !== "function") throw new Error("entrypoint is not a function");
    const out = await fn(e.data.input);
    self.postMessage({ ok: true, out: out === undefined ? null : out });
  } catch (err) {
    self.postMessage({ ok: false, err: String(err && err.message || err) });
  }
};
`;

export const runEnvelope = (
  env: JobEnvelope,
  input: unknown,
  opts: { timeoutMs?: number } = {},
): Promise<{ result: unknown; seconds: number }> =>
  new Promise((resolve, reject) => {
    const timeoutMs = opts.timeoutMs ?? 5 * 60 * 1000;
    const blob = new Blob(
      [`self.__caps = ${JSON.stringify(env.caps || [])};`,
       `self.__net = ${env.network === true};`,
       WORKER_PRELUDE],
      { type: "text/javascript" });
    const url = URL.createObjectURL(blob);
    const w = new Worker(url);
    const started = Date.now();
    const timer = setTimeout(() => {
      w.terminate(); URL.revokeObjectURL(url);
      reject(new Error(`compute-executor: timeout after ${timeoutMs}ms`));
    }, timeoutMs);
    w.onerror = (e) => {
      clearTimeout(timer); w.terminate(); URL.revokeObjectURL(url);
      reject(new Error(`compute-executor: ${e.message || "worker error"}`));
    };
    w.onmessage = (e) => {
      clearTimeout(timer); w.terminate(); URL.revokeObjectURL(url);
      const seconds = (Date.now() - started) / 1000;
      if (e.data && e.data.ok) resolve({ result: e.data.out, seconds });
      else reject(new Error(`compute-executor: ${e.data && e.data.err || "failed"}`));
    };
    w.postMessage({ entrypoint: env.entrypoint, input: input ?? null });
  });

// ── the receipt ───────────────────────────────────────────────────────────
// The body compute-receipt verifies: digest recomputed here matches what the
// door recomputes there, or the receipt is refused. Unsigned — 'unverifiable
// is an honest verdict, 'bad would not be.

export const emitReceipt = async (args: {
  env: JobEnvelope;
  lenderDid: string;
  input: unknown;
  result: unknown;
  seconds: number;
  reproMode?: string;
  seed?: number;
}): Promise<ReceiptBody> => {
  const { env, lenderDid, result, seconds } = args;
  const body = {
    bridgeJobId: env.bridgeJobId,
    lenderDid,
    inputHash: env.inputHash,
    outputHash: await sha256hex(JSON.stringify(result ?? null)),
    engine: env.image || null,
    usage: { unit: "seconds", amount: Math.round(seconds * 1000) / 1000 },
    repro: args.reproMode
      ? {
          mode: args.reproMode,
          ...(args.seed !== undefined ? { seed: args.seed } : {}),
        }
      : null,
    executedAt: Date.now(),
  };
  return { ...body, lenderSig: null, borrowerSig: null,
           digest: await digestReceiptBody(body) };
};

// ── the loop, one claim at a time ─────────────────────────────────────────
// fetch the envelope → run it → land the receipt. SEAM is the browser's
// session bridge (computeFetchEnvelope, computeReceipt). The claim's
// deadline is the timeout — no countersigned receipt by the deadline means
// no payment; the registry's expiry already knows that.

export const runClaim = async (
  seam: {
    computeFetchEnvelope?: (commune: string, claimId: string) => Promise<unknown>;
    computeReceipt?: (commune: string, wireJson: string) => Promise<unknown>;
  },
  commune: string,
  claimId: string,
  lenderDid: string,
  input: unknown,
  opts: { timeoutMs?: number; reproMode?: string; seed?: number } = {},
): Promise<unknown> => {
  const raw = await seam.computeFetchEnvelope!(commune, claimId);
  if (typeof raw === "string" && raw.startsWith("err:"))
    throw new Error(`compute-executor: ${raw}`);
  const env = (typeof raw === "string" ? JSON.parse(raw) : raw) as JobEnvelope;
  const { result, seconds } = await runEnvelope(env, input, opts);
  const receipt = await emitReceipt({
    env, lenderDid, input, result, seconds,
    reproMode: opts.reproMode, seed: opts.seed,
  });
  return seam.computeReceipt!(commune, JSON.stringify(receipt));
};
