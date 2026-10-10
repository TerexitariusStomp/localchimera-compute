// tools/lint/lint-sw.mjs — the service worker's lists against the tree.
//
// browser/sw.js names what it fetches at install in PRECACHE, and install is
// all-or-nothing over that list: one path the server answers 404 for and the
// worker never installs. This reads the list out of the file and asks the
// tree for each path (a path git ignores is a build product, present once built). It also holds the two lines tools/emit/sw-stamp.sh rewrites
// (CACHE, CORE, SHELL, ROOTS) in the form the script expects, asks the same
// of every file the two pages' own tags name, and stamps a scratch tree to
// see the result parse.
//
// Run: node tools/lint/lint-sw.mjs   (make lint-sw)

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const ROOT = path.resolve('browser');
const src = fs.readFileSync(path.join(ROOT, 'sw.js'), 'utf8');
let bad = 0;
const fail = (msg) => { bad++; console.log(`  ✗ ${msg}`); };
let unbuilt = 0;
const ignored = (file) => {
  try { execFileSync('git', ['check-ignore', '-q', file]); return true; } catch { return false; }
};

const block = src.match(/const PRECACHE = \[([\s\S]*?)\];/);
if (!block) fail('sw.js has no PRECACHE list');
const paths = block ? [...block[1].matchAll(/^\s*'([^']+)'/gm)].map((m) => m[1]) : [];
for (const p of paths) {
  // '/' is the host's default page, which the server answers with a document
  const file = p === '/' ? 'index.html' : p.slice(1);
  if (fs.existsSync(path.join(ROOT, file))) continue;
  // a build product (repl.wasm) is absent from a fresh checkout and ignored by
  // git; the tree that is served has built it
  if (ignored(`browser/${file}`)) { unbuilt++; continue; }
  fail(`PRECACHE names ${p}, and browser/${file} is absent`);
}
if (new Set(paths).size !== paths.length) fail('PRECACHE names a path twice');

if (!/^const CACHE = 'playnet-[^']+';$/m.test(src)) fail("sw.js lacks the line `const CACHE = 'playnet-…';`");
for (const name of ['CORE', 'SHELL', 'ROOTS'])
  if (!new RegExp(`^const ${name} = \\[\\];$`, 'm').test(src)) fail(`sw.js lacks the unstamped line \`const ${name} = [];\``);
if (!/^const PASS = \['\/[^\]]+\];$/m.test(src)) fail('sw.js lacks the line `const PASS = [ … ];`');

// every same-origin file a page's own tags name is a file: CORE is read from
// app.html's tags, so a tag naming nothing would fail every install
const refs = (page) => [...fs.readFileSync(path.join(ROOT, page), 'utf8')
    .matchAll(/<(?:script|link|img)[^>]*\s(?:src|href)="([^"#?]+)"/g)]
  .map((m) => m[1]).filter((u) => !/^([a-z]+:)?\/\/|^data:/.test(u));
for (const page of ['app.html', 'index.html'])
  for (const u of refs(page)) {
    const file = u.replace(/^\.?\//, '');
    if (!fs.existsSync(path.join(ROOT, file)) && !ignored(`browser/${file}`)) fail(`${page} names ${u}, which is absent`);
  }

// every icon the worker shows in a notification is a file
for (const m of src.matchAll(/icon: (?:n\.icon \|\| )?'([^']+)'/g))
  if (!fs.existsSync(path.join(ROOT, m[1].slice(1)))) fail(`a notification names ${m[1]}, which is absent`);

// the stamp: same tree, same stamp; the lists are the tree's; a sub-app's
// bytes are outside the fingerprint
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-sw-'));
try {
  const put = (f, body = f) => { fs.mkdirSync(path.dirname(path.join(tmp, f)), { recursive: true }); fs.writeFileSync(path.join(tmp, f), body); };
  for (const f of ['app/a.js', 'app/tabs/b.js', 'lib/c.js', 'x-worker.js', 'repl.js', 'assets/css/d.css',
                   'vendor/v.js', 'boards/index.html', '.hidden', 'index.html']) put(f);
  put('app.html', '<script src="vendor/v.js"></script><script type="module" src="app/a.js"></script>'
                + '<link rel="stylesheet" href="https://elsewhere.example/x.css"><a href="docs/big.pdf">pdf</a>');
  const stamp = () => execFileSync('bash', ['tools/emit/sw-stamp.sh', tmp, path.join(ROOT, 'sw.js')], { encoding: 'utf8' }).trim();
  const h1 = stamp(), h2 = stamp();
  if (h1 !== h2) fail(`two stamps of one tree differ: ${h1} ${h2}`);
  const out = fs.readFileSync(path.join(tmp, 'sw.js'), 'utf8');
  const line = (name) => (out.match(new RegExp(`^const ${name} = (.*);$`, 'm')) || [])[1];
  const want = {
    CACHE: `'playnet-${h1}'`,
    CORE: "['/app/a.js','/vendor/v.js']",
    SHELL: "['/app/tabs/b.js','/assets/css/d.css','/lib/c.js','/x-worker.js']",
    ROOTS: "['/app.html','/app/','/assets/','/index.html','/lib/','/repl.js','/vendor/','/x-worker.js']",
  };
  for (const [name, w] of Object.entries(want))
    if (line(name) !== w) fail(`the stamped ${name} is ${line(name)}, and the tree says ${w}`);
  execFileSync('node', ['--check', path.join(tmp, 'sw.js')]);
  put('boards/index.html', 'a sub-app changed'); put('.hidden', 'so did a dot-file');
  if (stamp() !== h1) fail('a change in a pass-through sub-app or a dot-file moves the stamp');
  put('app/a.js', 'changed');
  if (stamp() === h1) fail('a changed file of the dial leaves the stamp unchanged');
} catch (e) { fail(`stamping a scratch tree: ${e.message}`); }
finally { fs.rmSync(tmp, { recursive: true, force: true }); }

console.log(bad ? `lint-sw: ${bad} problem(s)`
                : `lint-sw: ${paths.length} precache paths accounted for${unbuilt ? ` (${unbuilt} a build product, unbuilt here)` : ''}, stamp deterministic`);
process.exit(bad ? 1 : 0);
