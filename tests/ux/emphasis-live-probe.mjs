/// tests/ux/emphasis-live-probe.mjs — LIVE probe: EMPHASIS IS A STANDING.
///
/// Against a running gateway (make dev): a citizen states a want with a
/// voice, reads what it displaces, is refused a `held` kind until the scope ratifies it,
/// ratifies it, restates it, and reads the burn-meter — the whole
/// truth-telling stage 0–2 loop on the wire.
///
/// Run via:  GATEWAY_SREF_FILE=.dev-data/gateway-sref.txt GATEWAY_PORT=9099 \
///           guix shell -m deploy/manifests/browser-test-manifest.scm -- \
///             sh tests/ux/ux-run.sh tests/ux/emphasis-live-probe.mjs
import { harness, launch, newPage, sleep, summarize } from './ux-harness.mjs';
import { connectDial, createIdentity } from './probe-lib.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';
const h = harness();
const browser = await launch();
const page = await newPage(browser, h);

const H = (name, ...args) => page.evaluate(async ({ name, args }) => {
  const r = await window.__seam.handlers[name](...args).catch(e => 'threw:' + e);
  return String(r);
}, { name, args });
const parse = s => { try { return JSON.parse(s); } catch { return s; } };
const need = (spec, qty, tension, voice) =>
  H('declareNeed', spec, qty, 'each', '', '', '', '', '', '', spec, '', '', tension, voice);

try {
  await connectDial(page, BASE);
  await createIdentity(page, h);
  await sleep(3000);

  // a want with a voice — accepted bare
  const w = await need('probe-lamp', 2, 'des', 46);
  h.rec('a want with a voice is accepted bare', w === 'ok', w.slice(0, 160));
  const solve0 = await H('solve', '{}');
  h.rec('the scope still solves with the want in it', !/^err/.test(solve0), solve0.slice(0, 200));

  // held before ratification — refused, and says why
  const held0 = await need('probe-lamp', 2, 'held', 46);
  h.rec('held before ratification is refused with the rite named', /ratif/.test(held0), held0.slice(0, 160));

  // the rite, then held again — accepted
  const rk = await H('ratifyKind', 'probe-lamp', 'held');
  h.info('ratifyKind: ' + rk.slice(0, 100));
  const grants = parse(await H('ratifiedKinds'));
  h.rec('ratifiedKinds lists the grant under this AID',
        Array.isArray(grants) && grants.some(g => g.spec === 'probe-lamp' && g.kind === 'held' && g.by),
        JSON.stringify(grants).slice(0, 200));
  const held1 = await need('probe-lamp', 2, 'held', 100);
  h.rec('held after ratification is accepted', held1 === 'ok', held1.slice(0, 160));

  // my-slots carries the voice back (no level field anywhere)
  const mine = parse(await H('mySlots'));
  const row = (Array.isArray(mine) ? mine : (mine.needs || [])).find(r => (r.spec || r.name) === 'probe-lamp');
  h.rec('my-slots reads the row back with voice, no level',
        !!row && Number(row.voice) === 100 && !('level' in row), 'voice=' + JSON.stringify(row?.voice) + ' tension=' + row?.tension + ' keys=' + Object.keys(row || {}).join(','));

  // a want on a good the scope MAKES (bread), so the solve has duals to read
  h.info('bread: ' + await need('bread', 3, 'des', 22));
  // the displacement chip: read or honestly unread, plus the burn-meter's lately
  const solve = await H('solve', '{}');
  h.rec('the scope still solves with a held row in it', !/^err/.test(solve), solve.slice(0, 300));
  const moved = parse(await H('needDisplacement', 'bread', 1));
  h.rec('need-displacement answers with the lately clause', moved && typeof moved === 'object' && 'lately' in moved,
        JSON.stringify(moved).slice(0, 200));
  const hist = parse(await H('externalityHistory'));
  h.rec('the burn-meter recorded the solve, bread among the moved', hist && hist.solves >= 1 && hist.specs.some(x => (x.spec || x) === 'bread' || JSON.stringify(x).includes('bread')),
        JSON.stringify(hist).slice(0, 200));

  // stage 3: the audit — nothing was taken since the grant, so the held row
  // is padded and loses its grant through the same ratification door
  const audit = parse(await H('auditKinds'));
  h.rec('the audit examines the held row and finds it padded',
        audit && audit.examined >= 1 && audit.padded >= 1
        && (audit.findings || []).some(f => f.spec === 'probe-lamp' && f.verdict === 'padded'),
        JSON.stringify(audit).slice(0, 220));
  const g2 = parse(await H('ratifiedKinds'));
  h.rec('…and the padded grant is withdrawn', Array.isArray(g2) && !g2.some(g => g.spec === 'probe-lamp'),
        JSON.stringify(g2).slice(0, 120));
  const rec = parse(await H('audits'));
  h.rec('the record keeps the finding under the auditor\'s AID',
        Array.isArray(rec) && rec.some(f => f.spec === 'probe-lamp' && f.by && f.verdict === 'padded'),
        JSON.stringify(rec).slice(0, 200));

  // des withdraws the grant
  await H('ratifyKind', 'probe-lamp', 'held');
  await H('ratifyKind', 'probe-lamp', 'des');
  const after = parse(await H('ratifiedKinds'));
  h.rec('ratifying des withdraws the grant', Array.isArray(after) && !after.some(g => g.spec === 'probe-lamp'),
        JSON.stringify(after).slice(0, 120));
} finally {
  await browser.close();
}

summarize(h, ['a want with a voice is accepted bare',
              'held before ratification is refused with the rite named',
              'held after ratification is accepted',
              'my-slots reads the row back with voice, no level']);
