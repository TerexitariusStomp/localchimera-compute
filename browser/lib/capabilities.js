// SPDX-License-Identifier: AGPL-3.0-or-later
// browser/lib/capabilities.js — does this browser run localchimera's wasm?
//
// The spine (day-boot.wasm) and the planner (family.wasm) are compiled by Hoot
// into WebAssembly that leans on a few engine features. A browser without one of
// them cannot even compile the module, and the page quietly stays on the demo day.
// This module asks the engine itself — each probe is a few bytes of wasm that use
// ONE feature, and `WebAssembly.validate` says whether the engine accepts them —
// so the answer follows the browser a person has, in both directions: a browser
// that gains a feature passes, and nothing here names a browser or a version.
//
// The table below is the whole policy. A toolchain that needs another feature
// adds a probe; one that stops needing a feature deletes its probe.
//
//   check()        -> { ok, missing: [{ id, label }] }
//   describe(r)    -> { title, detail }   the words, for any report
//   showNotice(r)  -> the banner element, or null when there is nothing to say
//
// A banner never replaces the demo day: it says why the live features are off, and
// the page underneath carries on.

const HEADER = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
const wasm = (...sections) => new Uint8Array([...HEADER, ...sections.flat()]);

// type section: one function type  () -> ()
const FUNC_TYPE = [0x01, 0x04, 0x01, 0x60, 0x00, 0x00];
// function section: one function of type 0
const ONE_FUNC = [0x03, 0x02, 0x01, 0x00];

export const PROBES = [
  {
    id: "gc",
    label: "garbage-collected data (WasmGC)",
    // (type (struct (field i32)))
    bytes: wasm([0x01, 0x05, 0x01, 0x5f, 0x01, 0x7f, 0x00]),
  },
  {
    id: "tail-calls",
    label: "tail calls",
    // (func (return_call 0))
    bytes: wasm(FUNC_TYPE, ONE_FUNC, [0x0a, 0x06, 0x01, 0x04, 0x00, 0x12, 0x00, 0x0b]),
  },
  {
    id: "exceptions",
    label: "standard exception handling (exnref)",
    // (func (block (try_table (catch_all 0))))
    bytes: wasm(FUNC_TYPE, ONE_FUNC,
                [0x0a, 0x0d, 0x01, 0x0b, 0x00, 0x02, 0x40, 0x1f, 0x40, 0x01, 0x02, 0x00, 0x0b, 0x0b, 0x0b]),
  },
];

/** The probes this engine rejects. `validate` is injectable for tests. */
export function check({ validate, probes = PROBES } = {}) {
  const ask = validate || ((bytes) => typeof WebAssembly !== "undefined" && WebAssembly.validate(bytes));
  const missing = [];
  for (const p of probes) {
    let ok = false;
    try { ok = !!ask(p.bytes); } catch (_) { ok = false; }
    if (!ok) missing.push({ id: p.id, label: p.label });
  }
  return { ok: missing.length === 0, missing };
}

/**
 * The words for a report: { missing } when the engine lacks features,
 * { failed } when the wasm was refused or stopped for a reason the probes did not
 * foresee (the message is shown as given, trimmed).
 */
export function describe(report) {
  const missing = (report && report.missing) || [];
  if (missing.length) {
    const what = missing.map((m) => m.label).join(", ");
    return {
      title: "This browser is too old for localchimera's live features",
      detail: `It cannot run: ${what}. You are seeing the demo day. A current version of Chrome, Firefox or Safari turns the live features on.`,
    };
  }
  const why = String((report && report.failed) || "").replace(/\s+/g, " ").trim().slice(0, 160);
  return {
    title: "localchimera's live features did not start in this browser",
    detail: `You are seeing the demo day.${why ? " Reason: " + why + "." : ""} Reloading, or a current browser, may help.`,
  };
}

const KEY = "pn.capNotice.dismissed";
const tryStorage = (storage, f) => { try { return f(storage); } catch (_) { return null; } };

/** The banner for REPORT, once per distinct reason a person has not dismissed. */
export function showNotice(report, { document: doc = globalThis.document, storage = globalThis.localStorage } = {}) {
  if (!doc || !doc.body) return null;
  const missing = (report && report.missing) || [];
  if (!missing.length && !(report && report.failed)) return null;
  const reason = missing.length ? "missing:" + missing.map((m) => m.id).sort().join(",") : "failed";
  if (tryStorage(storage, (s) => s.getItem(KEY)) === reason) return null;
  const old = doc.getElementById("capNotice");
  if (old) old.remove();

  const { title, detail } = describe(report);
  const bar = doc.createElement("div");
  bar.id = "capNotice";
  bar.setAttribute("role", "status");
  bar.setAttribute("aria-live", "polite");
  bar.dataset.reason = reason;
  // system colours follow the person's light or dark theme with no tokens of ours
  bar.style.cssText =
    "position:fixed;left:8px;right:8px;bottom:8px;z-index:2147483000;box-sizing:border-box;" +
    "display:flex;gap:12px;align-items:flex-start;padding:10px 12px;border-radius:8px;" +
    "background:Canvas;color:CanvasText;border:1px solid GrayText;" +
    "font:14px/1.35 system-ui,-apple-system,'Segoe UI',sans-serif;box-shadow:0 2px 12px rgb(0 0 0 / .25);";
  const text = doc.createElement("div");
  text.style.cssText = "flex:1;min-width:0";
  const strong = doc.createElement("strong");
  strong.style.cssText = "display:block";
  strong.textContent = title;
  const rest = doc.createElement("div");
  rest.textContent = detail;
  text.append(strong, rest);
  const close = doc.createElement("button");
  close.type = "button";
  close.setAttribute("aria-label", "Dismiss");
  close.textContent = "×";
  close.style.cssText = "flex:none;border:0;background:transparent;color:inherit;font-size:20px;line-height:1;cursor:pointer;padding:0 4px";
  close.addEventListener("click", () => {
    tryStorage(storage, (s) => s.setItem(KEY, reason));
    bar.remove();
  });
  bar.append(text, close);
  doc.body.appendChild(bar);
  return bar;
}
