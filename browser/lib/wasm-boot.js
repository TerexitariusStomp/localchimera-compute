// browser/lib/wasm-boot.js — boot a planner wasm and give its handlers a promise face.
//
//   const { call } = await bootHandlers(Scheme, "family.wasm", { module: "family", what: "the household solve" });
//   const json = await call("split", 6, needsJson, purse, …);
//
// A planner build for the page (hoot/family-worker.scm, hoot/scope-worker.scm)
// registers its handlers through two imports of its own module, `setHandler` and
// `callCallback`, and answers each call with one string through a callback: the
// shape of the spine's handlers. The planner is linked against Goblins, whose
// crypto imports such a build never reaches; they are declared here as doors
// that refuse, so a call that did reach one fails by name.
//
// One module for the page's workers and for their node checks: all boot the same way.

const OWN = new Set(["rt", "abi", "debug", "io", "ffi", "finalization"]);

export async function bootHandlers(Scheme, source, { module, what, imports, ...opts }) {
  const bytes = typeof source === "string" ? await (await fetch(source)).arrayBuffer() : source;
  const handlers = {};
  const user = { [module]: { setHandler(name, fn) { handlers[name] = fn; },
                             callCallback(cb, s) { cb(s); } } };
  for (const i of WebAssembly.Module.imports(await WebAssembly.compile(bytes))) {
    if (OWN.has(i.module) || (user[i.module] && user[i.module][i.name])) continue;
    (user[i.module] = user[i.module] || {})[i.name] = () => {
      throw new Error(what + " reached " + i.module + "." + i.name);
    };
  }
  Object.assign(user, imports || {});
  await Scheme.load_main(bytes, { ...opts, user_imports: user });
  // the handlers are arity-strict (procedure->external): every argument goes as a string
  const call = (name, arity, ...args) => new Promise((resolve, reject) => {
    if (!handlers[name]) return reject(new Error(what + " has no door " + name));
    handlers[name](...Array.from({ length: arity }, (_, i) => args[i] == null ? "" : String(args[i])), resolve);
  });
  return { call };
}
