// tests/browser/rpc-test.mjs — app/rpc.ts: a question asked of a worker always ends.
//
// The claims: each answer reaches the question with its id, whatever order
// they come back in; a message with no open id goes to `other`; a worker that
// errors rejects EVERY open question and the next ask starts a fresh worker;
// a worker that cannot start rejects the ask.
//
// Run: node tests/browser/rpc-test.mjs

import { workerRpc } from '../../browser/app/rpc.js';

import { harness } from './assert.mjs';
const { ok, done } = harness();

// a stand-in Worker: records what it is sent, and the test plays its side
class FakeWorker {
  constructor() { this.sent = []; this.dead = false; }
  postMessage(m, transfer) { this.sent.push({ m, transfer }); }
  terminate() { this.dead = true; }
  say(data) { this.onmessage({ data }); }
  crash(message) { this.onerror({ message }); }
}

const made = [], others = [];
const rpc = workerRpc({ spawn: () => { const w = new FakeWorker(); made.push(w); return w; }, other: d => others.push(d) });

console.log('\n── asking ──');
ok('no worker exists before the first ask', made.length === 0);
const a = rpc.ask({ q: 'a' }), b = rpc.ask({ q: 'b' }, ['a-transferable']);
const w = made[0];
ok('the first ask starts one worker, the second reuses it', made.length === 1);
ok('each request is posted with an id of its own', w.sent[0].m.id !== w.sent[1].m.id && w.sent[0].m.q === 'a');
ok('the transfer list rides along', w.sent[1].transfer[0] === 'a-transferable');
w.say({ id: w.sent[1].m.id, v: 'B' }); w.say({ id: w.sent[0].m.id, v: 'A' });
ok('answers reach their own questions, in any order', (await a).v === 'A' && (await b).v === 'B');

console.log('\n── other messages ──');
w.say({ progress: 0.5 }); w.say({ id: 9999, v: 'late' });
ok('a message with no open id goes to other', others.length === 2 && others[0].progress === 0.5);

console.log('\n── a worker that dies ──');
const c = rpc.ask({ q: 'c' }), d = rpc.ask({ q: 'd' });
w.crash('out of memory');
const [rc, rd] = await Promise.all([c, d].map(p => p.then(() => null, e => e.message)));
ok('every open question is rejected with the reason', rc === 'out of memory' && rd === 'out of memory');
ok('the dead worker is let go', w.dead === true);
const e = rpc.ask({ q: 'e' });
ok('the next ask starts a fresh worker', made.length === 2);
made[1].say({ id: made[1].sent[0].m.id, v: 'E' });
ok('and is answered by it', (await e).v === 'E');

console.log('\n── stop ──');
const f = rpc.ask({ q: 'f' });
rpc.stop('closing');
ok('stop ends the open questions', (await f.then(() => null, x => x.message)) === 'closing');

console.log('\n── no worker to start ──');
const none = workerRpc({ spawn: () => { throw new Error('Worker is not defined'); } });
ok('the ask rejects with why', (await none.ask({}).then(() => null, x => x.message)) === 'Worker is not defined');

done();
