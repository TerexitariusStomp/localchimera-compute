// tests/browser/push-test.mjs — app/push.ts: this device's browser notifications.
//
// The module keeps three parties in step (the browser's permission and
// subscription, the commune's record of it, this device's id). The claims:
// enabling asks the permission, subscribes with the commune's key and tells
// the commune under this device's id; a refusal is said and nothing is told;
// the commune is told again each time the page is seated, and when the worker
// reports a replaced subscription; disabling takes it back on both sides.
//
// Run: node tests/browser/push-test.mjs

import { harness } from './assert.mjs';
import { installDomStub } from './dom-stub.mjs';
const { check, section, done } = harness();

// ── the browser, as far as push goes ───────────────────────────────────────
let permission = 'default', grant = 'granted', held = null, subscribedWith = null;
const mkSub = (endpoint) => ({ endpoint, toJSON: () => ({ endpoint, keys: { p256dh: 'p', auth: 'a' } }),
                               unsubscribe: async () => { held = null; return true; } });
const swListeners = [];
installDomStub();
globalThis.location = { search: '', hash: '', href: 'https://playnet.example/', hostname: 'playnet.example', protocol: 'https:' };
globalThis.window.PushManager = function () {};
globalThis.Notification = { get permission() { return permission; },
  requestPermission: async () => { permission = grant; return permission; } };
// node defines `navigator` with a getter only
Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { serviceWorker: {
  ready: Promise.resolve({ pushManager: {
    getSubscription: async () => held,
    subscribe: async (opts) => { subscribedWith = opts; held = mkSub('https://push.example/1'); return held; } } }),
  addEventListener: (type, fn) => { if (type === 'message') swListeners.push(fn); } } } });

const { HANDLERS } = await import('../../browser/app/core.js');
const { emit } = await import('../../browser/app/bus.js');
const told = [];
HANDLERS.pushKey = async () => 'AQID';                                  // bytes 1,2,3
HANDLERS.pushRegister = async (id, json) => { told.push(['register', id, JSON.parse(json).endpoint]); return 'ok'; };
HANDLERS.pushUnregister = async (id) => { told.push(['unregister', id]); return 'ok'; };

const { pushState, enablePush, disablePush, deviceId } = await import('../../browser/app/push.js');
const settle = () => new Promise(r => setTimeout(r, 10));

section('the device');
const id = deviceId();
check('the device has an id, minted once', typeof id === 'string' && id.length > 8 && deviceId() === id);
check('…kept on the device', localStorage.getItem('pn.device.id') === id);
check('before anything is asked, notifications are off', pushState() === 'off');

section('a refusal');
grant = 'denied';
const refused = await enablePush();
check('the refusal is said', refused.startsWith('err:'));
check('the state says blocked', pushState() === 'blocked');
check('and the commune is told nothing', told.length === 0);

section('enabling');
permission = 'default'; grant = 'granted';
const r = await enablePush();
check('enabling answers ok', r === 'ok', r);
check('the browser subscribed with the commune’s key, as bytes',
      subscribedWith.userVisibleOnly === true && [...subscribedWith.applicationServerKey].join() === '1,2,3');
check('the commune was told the subscription under this device’s id',
      told.length === 1 && told[0][0] === 'register' && told[0][1] === id && told[0][2] === 'https://push.example/1');
check('the state says on', pushState() === 'on');

section('keeping the commune in step');
emit('status', 'ok:EAid');
await settle();
check('a seat taken tells the commune again (it holds subscriptions in memory)', told.length === 2 && told[1][0] === 'register');
emit('status', 'connecting');
await settle();
check('a status that is no seat tells it nothing', told.length === 2);
held = mkSub('https://push.example/2');
swListeners.forEach(fn => fn({ data: { type: 'push-subscription' } }));
await settle();
check('a subscription the browser replaced is told', told.length === 3 && told[2][2] === 'https://push.example/2');

section('a commune that sends no push');
held = null; HANDLERS.pushKey = async () => '';
const none = await enablePush();
check('enabling says so, and subscribes nothing', none.startsWith('err:') && held === null);

section('disabling');
held = mkSub('https://push.example/2');
const off = await disablePush();
check('disabling answers ok', off === 'ok');
check('the commune was asked to forget this device', told.at(-1)[0] === 'unregister' && told.at(-1)[1] === id);
check('the browser’s subscription is ended', held === null);
check('the state says off', pushState() === 'off');

done();
