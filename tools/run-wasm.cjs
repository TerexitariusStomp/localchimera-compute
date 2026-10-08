#!/usr/bin/env node
// run-wasm.cjs — run a Hoot-compiled program under node and print what it logs.
//
//   node tools/run-wasm.cjs <program.wasm>
//
// Loads browser/reflect.js (the page's own runtime) and gives the program the
// imports a probe needs: performance.now and console.log. Any other import the
// program declares (goblins' crypto, uint8Array) is stubbed to throw if called,
// so a solve that reaches for one fails loudly instead of returning nothing.
// Hoot 0.9 emits the standard wasm exception encoding (try_table / exnref); Node 22
// compiles it behind this V8 flag, which must be set before the first compile.
try { require('v8').setFlagsFromString('--experimental-wasm-exnref'); } catch {}
const fs = require('fs');
const path = require('path');
const browser = path.join(__dirname, '..', 'browser');
const src = fs.readFileSync(path.join(browser, 'reflect.js'), 'utf8');
const Scheme = new Function('require', src + '\n;return Scheme;')(require);

(async () => {
  const file = process.argv[2];
  if (!file) { console.error('usage: run-wasm.cjs <program.wasm>'); process.exit(2); }
  const m = await WebAssembly.compile(fs.readFileSync(file));
  const user = {
    performance: { now: () => performance.now() },
    console: { log: (x) => console.log('wasm:', x) },
  };
  for (const i of WebAssembly.Module.imports(m)) {
    if (['rt', 'ffi', 'debug', 'io', 'finalization'].includes(i.module)) continue;
    user[i.module] = user[i.module] || {};
    if (!user[i.module][i.name]) {
      user[i.module][i.name] = () => { throw new Error('unstubbed import ' + i.module + '.' + i.name); };
    }
  }
  await Scheme.load_main(path.resolve(file), { reflect_wasm_dir: browser, user_imports: user });
})().catch((e) => { console.error('ERR', (e && e.message) || e); process.exit(1); });
