// tests/browser/keys-test.mjs — app/keys.ts: the key table and its migration.
//
// A key is a promise to the person's own past, so three things are held:
//   • the migration moves every value kept under a former name to its present
//     one, copy first, and can be interrupted and run again;
//   • the table keeps its convention and names nothing twice;
//   • the readers that cannot import the table — the two Scheme bundles and
//     app.html's pre-paint script — spell the names as the table has them,
//     and no module under ui/ passes the store a name of its own.
//
// Run: node tests/browser/keys-test.mjs

import fs from 'node:fs';
import path from 'node:path';
import { harness } from './assert.mjs';
import { memStorage } from './fakes.mjs';
const { check, section, done } = harness();

// a Storage with length and key(i), which the family migration walks
const store = (seed = {}, { failOn = null } = {}) => {
  const s = memStorage();
  for (const [k, v] of Object.entries(seed)) s.setItem(k, v);
  const proto = Object.getPrototypeOf(s);
  Object.defineProperty(proto, 'length', { get() { return Object.keys(this).length; } });
  proto.key = function (i) { return Object.keys(this)[i] ?? null; };
  if (failOn) { const set = proto.setItem; proto.setItem = function (k, v) { if (k === failOn) throw new DOMException('quota', 'QuotaExceededError'); return set.call(this, k, v); }; }
  return s;
};

const { K, KEY_TABLE, KEY_FAMILIES, migrateKeys } = await import('../../browser/app/keys.js');

section('the migration');
const s = store({ 'playnet-keri-kel': 'KEL', 'playnet-keri-id': 'aid|ana||k0', 'dial-log': '[1]', 'pn.theme': 'night',
                  'playnet-avail-EAid': '[a]', 'playnet-events-local': '[e]', 'playnet.panel.shut.face.time': '1',
                  'playnet-acme': 'an organisation’s store' });
const moved = migrateKeys(s);
check('every former name is moved', moved === 6, `${moved} moved`);
check('the KEL is under its present name', s.getItem(K.idKel) === 'KEL' && s.getItem('playnet-keri-kel') === null);
check('the identity hint too', s.getItem(K.idHint) === 'aid|ana||k0');
check('a family moves with its id', s.getItem(K.ringAvail + 'EAid') === '[a]' && s.getItem(K.ringEvents + 'local') === '[e]'
                                    && s.getItem(K.panelShutFace + 'time') === '1');
check('a key that kept its name is untouched', s.getItem(K.theme) === 'night');
check('an organisation’s store is left alone', s.getItem('playnet-acme') === 'an organisation’s store');
check('a second run moves nothing', migrateKeys(s) === 0);

const both = store({ 'playnet-keri-kel': 'OLD', [K.idKel]: 'NEW' });
migrateKeys(both);
check('where both names hold a value, the present name’s stands', both.getItem(K.idKel) === 'NEW' && both.getItem('playnet-keri-kel') === null);

const full = store({ 'playnet-keri-kel': 'KEL', 'dial-log': '[1]' }, { failOn: K.idKel });
let threw = false;
try { migrateKeys(full); } catch { threw = true; }
check('a store that refuses the copy keeps the former name', threw && full.getItem('playnet-keri-kel') === 'KEL');

section('the table');
const all = [...KEY_TABLE, ...KEY_FAMILIES];
const names = all.map(e => e.key);
check('no name appears twice', new Set(names).size === names.length);
check('every key follows pn.<area>.<name>', KEY_TABLE.every(e => /^pn\.[a-zA-Z0-9]+([.-][a-zA-Z0-9]+)*$/.test(e.key)),
      KEY_TABLE.filter(e => !/^pn\.[a-zA-Z0-9]+([.-][a-zA-Z0-9]+)*$/.test(e.key)).map(e => e.key).join(' '));
check('every family ends where its id begins', KEY_FAMILIES.every(e => /^pn\.[a-z0-9.-]+[:.]$/.test(e.key)));
check('no former name is a present one', all.every(e => !e.was || !names.includes(e.was)));
check('no former name is claimed twice', (w => new Set(w).size === w.length)(all.filter(e => e.was).map(e => e.was)));
check('every entry says what it holds', all.every(e => e.holds.length > 8));
check('no key sits under the organisations’ prefix', names.every(n => !n.startsWith('playnet-')));

section('the readers that spell the names themselves');
const read = (f) => fs.readFileSync(path.resolve(f), 'utf8');
const spine = read('hoot/day-boot.scm'), repl = read('hoot/repl.scm'), page = read('browser/app.html');
const quoted = (text, key) => text.includes(`"${key}"`);
check('the spine: the KEL, the device wire, the mesh seed',
      [K.idKel, K.deviceWire, K.deviceMesh].every(k => quoted(spine, k)));
check('the REPL page: the hint, the KEL, the device id and its own keys',
      [K.idHint, K.idKel, K.deviceId, K.replCredentials, K.replContacts, K.replOrgs, K.replPriorities,
       K.replCalEvents, K.replCalPeople, K.replSyntax].every(k => quoted(repl, k)),
      [K.idHint, K.idKel, K.deviceId, K.replCredentials, K.replContacts, K.replOrgs, K.replPriorities,
       K.replCalEvents, K.replCalPeople, K.replSyntax].filter(k => !quoted(repl, k)).join(' '));
check('the pre-paint script: the three theme keys', [K.theme, K.themeBg, K.themeCss].every(k => quoted(page, k)));
const former = all.filter(e => e.was).map(e => e.was);
const stale = (text) => former.filter(w => text.includes(`"${w}"`));
check('neither Scheme bundle spells a former name', stale(spine).length + stale(repl).length === 0,
      [...stale(spine), ...stale(repl)].join(' '));

section('the door is handed names from the table');
const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap(e =>
  e.isDirectory() ? walk(path.join(d, e.name)) : e.name.endsWith('.ts') ? [path.join(d, e.name)] : []);
const own = walk('ui').filter(f => !f.endsWith('keys.ts')).flatMap(f =>
  [...read(f).matchAll(/\b(?:readStr|writeStr|readJSON|writeJSON|forget)(?:<[^>]*>)?\(\s*["'`]([^"'`]*)/g)].map(m => `${f}: ${m[1]}`));
check('no module under ui/ passes the store a name of its own', own.length === 0, own.slice(0, 4).join(' | '));

done();
