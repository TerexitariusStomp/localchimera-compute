#!/usr/bin/env node
// check-scope-worker.cjs — boot browser/scope.wasm the way the page's worker does, and ask its doors.
//
//   node tools/test/check-scope-worker.cjs        (make check-scope-worker builds the wasm first)
//
// Runs browser/lib/scope-boot.js — the module browser/scope-worker.js boots
// through — under node, with browser/reflect.js as the Scheme runtime. The scope
// is stood on the day the demo's recording was made, so its doors can be held
// to the recording (ui/app/demo/recording.ts, what the native planner service
// answered of the same acts): the same stock on the books, the same counts of
// each stock, ids aside. A difference here means the page's build and the
// gateway's no longer answer a door alike.
// Hoot 0.9 emits the standard wasm exception encoding (try_table / exnref); Node 22
// compiles it behind this V8 flag, which must be set before the first compile.
try { require('v8').setFlagsFromString('--experimental-wasm-exnref'); } catch {}
const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');
const browser = path.join(__dirname, '..', '..', 'browser');
const Scheme = new Function('require', fs.readFileSync(path.join(browser, 'reflect.js'), 'utf8') + '\n;return Scheme;')(require);

let failed = 0;
const check = (ok, what, detail) => { console.log((ok ? '  ✓ ' : '  ✗ ') + what + (detail ? '   ' + detail : '')); if (!ok) failed++; };
// a count's row without the ids the two sides mint for themselves
const plain = (rows) => rows.map(({ id, ballot, ...rest }) => rest);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

(async () => {
  const { bootScope } = await import(pathToFileURL(path.join(browser, 'lib', 'scope-boot.js')).href);
  const { RECORDING } = await import(pathToFileURL(path.join(browser, 'app', 'demo', 'recording.js')).href);
  const today = Date.parse(RECORDING.day + 'T12:00:00Z') / 1000;

  const t0 = performance.now();
  const scope = await bootScope(Scheme, fs.readFileSync(path.join(browser, 'scope.wasm')), { reflect_wasm_dir: browser });
  console.log('  booted in ' + Math.round(performance.now() - t0) + ' ms');
  let t1 = performance.now();
  const { doors } = JSON.parse(await scope.ask('open', [today]));
  console.log('  the neighbourhood stood in ' + Math.round(performance.now() - t1) + ' ms');
  check(Object.keys(doors).length >= 8 && doors.countStock === 9, 'the scope names its doors and their arities', Object.keys(doors).join(' '));

  let t = performance.now();
  const snap = JSON.parse(await scope.ask('snapshot'));
  console.log('  snapshot in ' + Math.round(performance.now() - t) + ' ms');
  // the commons' stock, your own, and what people offer, as the recording's books hold them
  const mine = new Map(snap.inventory.resources.map((r) => [r.id, r]));
  const recorded = RECORDING.snapshot.inventory.resources;
  const off = recorded.filter((r) => !mine.has(r.id) || Number(mine.get(r.id).onhand) !== Number(r.onhand) || mine.get(r.id).location !== r.location);
  check(recorded.length > 10 && off.length === 0, 'the books read what the recording reads, stock by stock', off.map((r) => r.id).join());
  check(snap.locations.length === RECORDING.snapshot.locations.length, 'the same places', `${snap.locations.length} / ${RECORDING.snapshot.locations.length}`);

  const counted = Object.entries(RECORDING.replies.countHistory).filter(([, v]) => v.rows.length);
  const differ = [];
  for (const [stock, v] of counted) {
    const rows = JSON.parse(await scope.ask('countHistory', [stock, ''])).rows;
    if (!same(plain(rows), plain(v.rows))) differ.push(stock);
  }
  check(counted.length >= 4 && differ.length === 0, 'each stock\'s counts are the recording\'s, ids aside', differ.join());

  const sched = JSON.parse(await scope.ask('countSchedule', [''])).rows.map((r) => r.id).sort();
  const want = RECORDING.replies.countSchedule.rows.map((r) => r.id).sort();
  check(want.every((id) => sched.includes(id)), 'the schedule lists the stocks the recording\'s lists');

  // the two builds list a store in their own order; the slots are held to each other by id
  const byId = (slots) => ({ needs: [...slots.needs].sort((a, b) => a.id.localeCompare(b.id)), means: [...slots.means].sort((a, b) => a.id.localeCompare(b.id)) });
  check(same(byId(JSON.parse(await scope.ask('mySlots'))), byId(RECORDING.replies.mySlots)), 'your needs and offers are the recording\'s');
  const pool = JSON.parse(await scope.ask('slotsAt'));
  check(same(pool.needs.map((n) => n.id).sort(), RECORDING.replies.slotsAt.needs.map((n) => n.id).sort()), 'the pool holds the needs the recording\'s holds');

  t = performance.now();
  const landed = JSON.parse(await scope.ask('countStock', ['demo:tea', '7', 'box', 'stated', 'place:teahouse']));
  console.log('  a count in ' + Math.round(performance.now() - t) + ' ms');
  check(landed.delta === -2 && landed.onhand === 7, 'a count through the door answers the difference and the ledger after', JSON.stringify(landed).slice(0, 90));
  const after = JSON.parse(await scope.ask('countHistory', ['demo:tea', ''])).rows;
  check(after.length === 1 && after[0].counted === 7 && after[0].mine === true, 'it heads the stock\'s history, as the person\'s own');
  const tea = JSON.parse(await scope.ask('snapshot')).inventory.resources.find((r) => r.id === 'demo:tea');
  check(Number(tea.onhand) === 7, 'the books read it');
  // an act stated at an instant is that act however often it lands
  const at = RECORDING.day + 'T09:00:00Z';
  const once = JSON.parse(await scope.ask('countStock', ['demo:coats', '2', 'item', 'stated', '', at]));
  const twice = JSON.parse(await scope.ask('countStock', ['demo:coats', '2', 'item', 'stated', '', at]));
  const coats = JSON.parse(await scope.ask('countHistory', ['demo:coats', ''])).rows;
  check(once.record === twice.record && twice.again === true && coats.length === 1, 'a count stated at an instant, landed twice, is one count', once.record);
  const seen = await scope.ask('logObserve', ['work', 'spec-bike-repair', '2', 'hours', 'fixed a flat', at]);
  check(seen.startsWith('ok:evt-log-') && seen === await scope.ask('logObserve', ['work', 'spec-bike-repair', '2', 'hours', 'fixed a flat', at]), 'an observation likewise', seen);
  check(await scope.ask('declareNeed', ['spec-tea', '2', 'box', '', '', 'for the weekend', '', '', '', 'tea']) === 'ok'
        && JSON.parse(await scope.ask('mySlots')).needs.some((n) => n.spec === 'spec-tea'), 'a need declared through the door stands among your own');
  const refused = await scope.ask('countStock', ['demo:tea', '3', 'kg', 'stated']);
  check(refused === "err:count in the stock's unit: box", 'a count in another unit is refused in the door\'s words', refused);
  const none = await scope.ask('noSuchDoor');
  check(none.startsWith('err:unavailable'), 'a door this scope does not take says so');
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error('ERR', (e && e.stack) || e); process.exit(1); });
